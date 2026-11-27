using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace ToolDriveOffline
{
    internal sealed partial class WindowsMediaService : IDisposable
    {
        readonly string root;
        readonly Func<string> catalogJson;
        readonly Action<string, object> emit;
        readonly HttpClient http;
        readonly CancellationTokenSource shutdown = new CancellationTokenSource();
        readonly Dictionary<long, SourceRef> sources = new Dictionary<long, SourceRef>();
        readonly Dictionary<long, Dictionary<string, object>> shows =
            new Dictionary<long, Dictionary<string, object>>();
        string catalogText;
        Task<Dictionary<long, Uri>> links;
        readonly Dictionary<string, MediaTrack> handles = new Dictionary<string, MediaTrack>();
        long comparisonSession, albumSession;
        Dictionary<long, List<MediaTrack>> comparisonTracks = new Dictionary<long, List<MediaTrack>>();
        List<Dictionary<string, object>> albumTracks = new List<Dictionary<string, object>>();
        string previewHandle;
        readonly Dictionary<long, CancellationTokenSource> transfers =
            new Dictionary<long, CancellationTokenSource>();
        long latestRequest;
        bool disposed;
        internal Action<string> OpenSignIn { get; set; }
        public Action<Uri, long> OpenOriginalFolder { get; set; }

        public WindowsMediaService(string libraryDataRoot, Func<string> catalogJson,
                                   Action<string, object> emit)
            : this(libraryDataRoot, catalogJson, emit,
                   new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
        {
        }
        internal WindowsMediaService(string libraryDataRoot, Func<string> catalogJson,
                                     Action<string, object> emit, HttpMessageHandler handler)
        {
            this.OpenSignIn = Launch;
            this.root = Path.GetFullPath(libraryDataRoot);
            this.catalogJson = catalogJson;
            this.emit = emit;
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            http = new HttpClient(handler);
            http.Timeout = Timeout.InfiniteTimeSpan;
            Directory.CreateDirectory(root);
            RecoverLibrary();
        }
        static JavaScriptSerializer Json()
        {
            return new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024, RecursionLimit = 64 };
        }
        static Dictionary<string, object> Map(object o)
        {
            return o as Dictionary<string, object> ?? new Dictionary<string, object>();
        }
        static object Get(Dictionary<string, object> d, string key)
        {
            object v;
            return d.TryGetValue(key, out v) ? v : null;
        }
        static string Str(Dictionary<string, object> d, string key)
        {
            return Convert.ToString(Get(d, key), CultureInfo.InvariantCulture) ?? "";
        }
        static long Num(Dictionary<string, object> d, string key)
        {
            long n;
            return Int64.TryParse(Str(d, key), out n) ? n : 0;
        }
        static IEnumerable<Dictionary<string, object>> Rows(object o)
        {
            var items = o as IEnumerable;
            return items == null || o is string ? Enumerable.Empty<Dictionary<string, object>>()
                                                : items.Cast<object>().OfType<Dictionary<string, object>>();
        }
        static Exception Problem(string message)
        {
            return new InvalidDataException(message);
        }
        static string Message(Exception e)
        {
            if (e is OperationCanceledException)
                return "The operation was canceled or timed out.";
            return e is InvalidDataException ? e.Message
                                             : "Could not complete the request. Check your connection, " +
                                               "storage, and access, then try again.";
        }
        void Send(string name, object data)
        {
            if (!disposed)
                emit(name, data);
        }
        static async Task<string> ReadText(HttpResponseMessage response, int limit, CancellationToken token)
        {
            if (!response.IsSuccessStatusCode)
                throw Problem("The service returned HTTP " + (int)response.StatusCode + ".");
            if (response.Content.Headers.ContentLength > limit)
                throw Problem("The response exceeded the metadata limit.");
            using (var buffer = new MemoryStream()) using (
                var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
            {
                var bytes = new byte[32768];
                int n;
                while ((n = await stream.ReadAsync(bytes, 0, bytes.Length, token).ConfigureAwait(false)) > 0)
                {
                    if (buffer.Length + n > limit)
                        throw Problem("The response exceeded the metadata limit.");
                    buffer.Write(bytes, 0, n);
                }
                return Encoding.UTF8.GetString(buffer.ToArray());
            }
        }
        async Task<string> TextAsync(HttpRequestMessage req, int limit, CancellationToken token,
                                     int seconds = 25)
        {
            using (req) using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                timeout.CancelAfter(TimeSpan.FromSeconds(seconds));
                using (var response =
                           await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                               .ConfigureAwait(false)) return await ReadText(response, limit, timeout.Token)
                    .ConfigureAwait(false);
            }
        }
        internal sealed class SourceRef
        {
            public long showId, sourceId;
            public int version;
            public string date, venue, versionLabel;
            public string Title
            {
                get {
                    return String.Join(
                        " · ", new[] { date, venue, versionLabel }.Where(s => !String.IsNullOrEmpty(s)));
                }
            }
        }
        internal sealed class MediaTrack
        {
            public int number;
            public string title, localPath, token, mime;
            public double? durationSeconds;
            public Uri remote;
            public bool directMp4;
            public long readerGeneration;
            public string[] songIDs = new string[0];
        }
        static bool ValidDate(string value)
        {
            DateTime result;
            return DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                          DateTimeStyles.None, out result);
        }
        void RefreshCatalog()
        {
            string text = catalogJson();
            if (String.Equals(text, catalogText, StringComparison.Ordinal))
                return;
            var parsed = Map(Json().DeserializeObject(text));
            sources.Clear();
            shows.Clear();
            foreach (var s in Rows(Get(parsed, "shows")))
            {
                var showId = Num(s, "id");
                var date = Str(s, "date");
                if (!ValidDate(date))
                    continue;
                foreach (var raw in Rows(Get(s, "sources")))
                {
                    if (Str(raw, "status") != "OTD")
                        continue;
                    shows[showId] = s;
                    Match m = Regex.Match(Str(raw, "version"), @"\d{1,3}");
                    var id = Num(raw, "id");
                    if (id <= 0 || !m.Success)
                        continue;
                    sources[id] =
                        new SourceRef { showId = showId,
                                        sourceId = id,
                                        date = date,
                                        version = Int32.Parse(m.Value, CultureInfo.InvariantCulture),
                                        versionLabel = Str(raw, "version"),
                                        venue = Str(s, "venue") };
                }
            }
            catalogText = text;
        }
        SourceRef Source(long id, long show = 0)
        {
            RefreshCatalog();
            SourceRef s;
            if (!sources.TryGetValue(id, out s) || (show != 0 && s.showId != show))
                throw Problem("This recording was not found in the catalog.");
            return s;
        }
        internal static List<MediaTrack> ParseTracks(string json, SourceRef s)
        {
            var result = Map(Json().DeserializeObject(json));
            var rows = Rows(Get(Map(Get(result, "data")), "tracks")).ToList();
            if (!Object.Equals(Get(result, "ok"), true) || rows.Count == 0 || rows.Count > 250)
                throw Problem("The archive did not provide a playable track list.");
            var numbers = new HashSet<int>();
            var tracks = new List<MediaTrack>();
            string stem = "tool" + s.date + ".v" + s.version;
            string prefix = "/mp3_2.0/" + s.date.Substring(0, 4) + "/" + stem + "/" + stem + ".t";
            foreach (var row in rows)
            {
                var path = Str(row, "url");
                long num = Num(row, "trackNumber");
                var m = Regex.Match(path, "^" + Regex.Escape(prefix) + @"(\d{1,3})\.mp3\z");
                if (!m.Success || num < 1 || num != Int32.Parse(m.Groups[1].Value) || !numbers.Add((int)num))
                    throw Problem("The archive returned a mismatched track.");
                string t = Str(row, "title");
                if (t.Length > 300)
                    throw Problem("The track title is invalid.");
                double dur;
                tracks.Add(new MediaTrack {
                    number = (int)num, title = t.Trim().Length > 0 ? t.Trim() : "Track " + num,
                    songIDs = (Get(row, "songIds") as IEnumerable ?? new object[0]).Cast<object>().OfType<string>()
                        .Take(16).Where(id => id.Length > 0 && id.Length <= 120).ToArray(),
                    durationSeconds = Double.TryParse(Str(row, "durationSeconds"), NumberStyles.Float,
                                                      CultureInfo.InvariantCulture, out dur) &&
                                              dur >= 0 && dur <= 28800
                                          ? (double?)dur
                                          : null,
                    remote = new Uri("https://tooldriveproject.net" + path), mime = "audio/mpeg"
                });
            }
            return tracks;
        }
        async Task<List<MediaTrack>> Archive(SourceRef source, CancellationToken token)
        {
            var url = "https://tooldriveproject.net/api/stream/resolve.php?date=" + source.date +
                      "&ver=" + source.version;
            return ParseTracks(
                await TextAsync(new HttpRequestMessage(HttpMethod.Get, url), 2 * 1024 * 1024, token), source);
        }
        async Task<Dictionary<long, Uri>> ReadLinks()
        {
            const string url = "https://tooldriveproject.net/data/02-sources.js";
            string text = await TextAsync(new HttpRequestMessage(HttpMethod.Get, url), 16 * 1024 * 1024,
                                          shutdown.Token);
            var m = Regex.Match(text, @"^\s*const\s+SOURCES_DATA\s*=\s*");
            if (!m.Success)
                throw Problem("The archive returned an invalid link index.");
            var data = Map(Json().DeserializeObject(text.Substring(m.Length).Trim().TrimEnd(';')));
            var list = new Dictionary<long, Uri>();
            foreach (var show in data.Values)
                foreach (var source in Rows(show))
                {
                    var raw = Str(source, "driveUrl");
                    Match folder = Regex.Match(
                        raw,
                        @"^https://drive\.google\.com/drive/folders/([a-zA-Z0-9_-]{8,128})/?(?:\?[^#\s]*)?\z",
                        RegexOptions.IgnoreCase);
                    if (folder.Success)
                        list[Num(source, "id")] =
                            new Uri("https://drive.google.com/drive/folders/" + folder.Groups[1].Value);
                }
            return list;
        }
        async Task Live(Dictionary<string, object> p)
        {
            string action = Str(p, "action");
            if (action == "compare" || action == "cancelComparison" || action == "preview" || action == "stopPreview")
            {
                await Compare(p, action);
                return;
            }
            if (action == "album" || action == "cancelAlbum")
            {
                await Album(p, action);
                return;
            }
            if (links == null || links.IsFaulted || links.IsCanceled)
                links = ReadLinks();
            if (Str(p, "action") == "openDownload")
            {
                var s = Source(Num(p, "sourceId"));
                Uri uri;
                if (!(await links).TryGetValue(s.sourceId, out uri))
                    throw Problem("No original download is published.");
                if (OpenOriginalFolder != null)
                    OpenOriginalFolder(uri, s.sourceId);
                else
                    Launch(uri.AbsoluteUri);
                return;
            }
            var showId = Num(p, "showId");
            var ids = Rows(Get(p, "sources")).Select(row => Num(row, "id")).ToArray();
            var results = new List<object>();
            Dictionary<long, Uri> index = null;
            try
            {
                index = await links;
            }
            catch (Exception)
            { /* Allow offline catalog use. */
            }
            RefreshCatalog();
            foreach (long id in ids)
            {
                SourceRef s;
                bool ok = sources.TryGetValue(id, out s) && s.showId == showId && index != null &&
                          index.ContainsKey(id);
                results.Add(new { sourceId = id, downloadAvailable = ok,
                                  message = index == null ? "Live links unavailable offline" : "" });
            }
            Send("macLiveLinks", new { showId, sources = results });
        }
        void ReleasePreview()
        {
            lock (handles)
            {
                if (previewHandle == null) return;
                DropReaders(id => id == previewHandle);
                handles.Remove(previewHandle);
                previewHandle = null;
            }
        }
        async Task<KeyValuePair<long, List<MediaTrack>>> TryArchive(SourceRef source)
        {
            try {
                return new KeyValuePair<long, List<MediaTrack>>(source.sourceId, await Archive(source, shutdown.Token));
            } catch (Exception) {
                return new KeyValuePair<long, List<MediaTrack>>(source.sourceId, null);
            }
        }
        async Task Compare(Dictionary<string, object> body, string action)
        {
            long session = Num(body, "session");
            if (session <= 0) return;
            if (action == "compare")
            {
                ReleasePreview();
                comparisonSession = session;
                comparisonTracks.Clear();
                long show = Num(body, "showId");
                var ids = Get(body, "ids") as IEnumerable;
                if (ids == null || show <= 0) return;
                RefreshCatalog();
                var selected = ids.Cast<object>().Take(24).Select(id => {
                    long n;
                    return Int64.TryParse(Convert.ToString(id, CultureInfo.InvariantCulture), out n) ? n : 0;
                }).Distinct().Where(id => sources.ContainsKey(id) && sources[id].showId == show)
                    .Select(id => sources[id]).ToArray();
                var found = await Task.WhenAll(selected.Select(TryArchive));
                if (comparisonSession != session || disposed) return;
                comparisonTracks = found.Where(entry => entry.Value != null).ToDictionary(entry => entry.Key, entry => entry.Value);
                Send("archiveComparisonTracks", new {session, sources = comparisonTracks.Select(pair => new {
                    sourceId = pair.Key, tracks = pair.Value.Select(track => new {track.number, track.title, track.songIDs}).ToArray()
                }).ToArray()});
            }
            else if (comparisonSession == session)
            {
                ReleasePreview();
                if (action == "cancelComparison")
                {
                    comparisonSession = 0;
                    comparisonTracks.Clear();
                }
                else if (action == "preview")
                {
                    long id = Num(body, "sourceId"), number = Num(body, "trackNumber");
                    long request = Num(body, "previewRequest");
                    List<MediaTrack> tracks;
                    var track = comparisonTracks.TryGetValue(id, out tracks)
                        ? tracks.FirstOrDefault(item => item.number == number) : null;
                    if (track == null)
                    {
                        Send("archivePreviewResult", new {request, ended = true, error = "This preview is unavailable."});
                        return;
                    }
                    lock (handles)
                    {
                        previewHandle = Guid.NewGuid().ToString("N");
                        handles.Add(previewHandle, track);
                    }
                    Send("archivePreviewResult", new {request, url = "https://media.tooldrive.invalid/" + previewHandle});
                }
            }
        }
        async Task Album(Dictionary<string, object> body, string action)
        {
            albumSession = action == "album" ? Num(body, "session") : 0;
            albumTracks.Clear();
            var session = albumSession;
            if (session <= 0) return;
            var id = Str(body, "albumId");
            if (!Regex.IsMatch(id, @"\A(?:opiate|undertow|aenima|salival|lateralus|10000days|fearinoculum|cover)\z")) return;
            try
            {
                var address = "https://tooldriveproject.net/api/albums/live-tracklist.php?albumId=" + id;
                var text = await TextAsync(new HttpRequestMessage(HttpMethod.Get, address), 256 * 1024, shutdown.Token);
                var response = Map(Json().DeserializeObject(text));
                var data = Map(Get(response, "data"));
                if (!Object.Equals(Get(response, "ok"), true)) throw Problem("The archive returned an invalid live album.");
                var tracks = Object.Equals(Get(data, "available"), true)
                    ? Rows(Get(data, "tracks")).OrderBy(row => Num(row, "trackOrder")).Take(250).ToList()
                    : new List<Dictionary<string, object>>();
                if (albumSession != session) return;
                albumTracks = tracks;
                Send("archiveAlbumResult", new {session, refreshedAt = Str(data, "refreshedAt"),
                    tracks = tracks.Select(row => new {title = Str(row, "title"), order = Num(row, "trackOrder"),
                        available = Num(row, "recordingId") > 0, date = Str(row, "showDate"), venue = Str(row, "venue")}).ToArray()});
            }
            catch (Exception)
            {
                if (albumSession == session)
                    Send("archiveAlbumResult", new {session, error = "Couldn’t load the live tracklist. Check your connection and try again."});
            }
        }
        async Task PlayAlbum(Dictionary<string, object> body, long request)
        {
            long session = Num(body, "session");
            if (session <= 0 || albumSession != session) return;
            var rows = albumTracks.ToArray();
            RefreshCatalog();
            var recordings = rows.Where(row => {
                SourceRef source;
                return sources.TryGetValue(Num(row, "recordingId"), out source) && source.date == Str(row, "showDate")
                    && source.version == Num(row, "version");
            }).Select(row => sources[Num(row, "recordingId")]).Distinct().ToArray();
            var found = await Task.WhenAll(recordings.Select(TryArchive));
            if (albumSession != session || latestRequest != request) return;
            var manifests = found.Where(entry => entry.Value != null).ToDictionary(entry => entry.Key, entry => entry.Value);
            int start = Get(body, "order") == null ? 0 : -1;
            long wanted = Num(body, "order");
            var queue = new List<MediaTrack>();
            foreach (var row in rows)
            {
                List<MediaTrack> tracks;
                if (!manifests.TryGetValue(Num(row, "recordingId"), out tracks)) continue;
                var track = tracks.FirstOrDefault(item => item.number == Num(row, "trackNumber"));
                if (track == null || (track.songIDs.Length > 0 && !track.songIDs.Contains(Str(row, "songId")))) continue;
                var order = Num(row, "trackOrder");
                var title = Str(row, "title");
                if (order < 0 || order > 999 || title.Length == 0 || title.Length > 300) continue;
                if (start == -1 && order == wanted) start = queue.Count;
                queue.Add(new MediaTrack { number = (int)order + 1, title = title, durationSeconds = track.durationSeconds,
                    remote = track.remote, mime = track.mime });
            }
            if (queue.Count == 0 || start < 0)
            {
                const string error = "This selection couldn’t be played. Check your connection and catalog updates.";
                Send("archiveAlbumResult", new {session, playError = error});
                throw Problem(error);
            }
            Queue(request, Str(body, "title") + " · The TDP Live Album", "album", queue, start);
            Send("archiveAlbumResult", new {session, started = true});
        }
        static void Launch(string path)
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        void Queue(long request, string label, string origin, List<MediaTrack> tracks, int start)
        {
            if (disposed || request != latestRequest)
                return;
            var entries = new List<object>();
            lock (handles)
            {
                ReleaseHandles();
                foreach (var track in tracks)
                {
                    var id = Guid.NewGuid().ToString("N");
                    handles.Add(id, track);
                    entries.Add(new { track.title, track.durationSeconds,
                                      url = "https://media.tooldrive.invalid/" + id });
                }
            }
            Send("windowsMediaReply",
                 new { request, context = label, origin, tracks = entries, startIndex = start });
        }
        public async Task HandleAsync(string channel, Dictionary<string, object> body)
        {
            if (disposed)
                return;
            long request = Num(body, "request");
            string action = Str(body, "action");
            if (request != 0)
                latestRequest = request;
            try
            {
                switch (channel)
                {
                case "live":
                    await Live(body);
                    break;
                case "player":
                    if (action == "release")
                    {
                        latestRequest = 0;
                        ReleaseHandles();
                    }
                    else if (action == "beginTrack" || action == "seekTrack")
                        PlaybackPosition(action, Str(body, "handle"));
                    else if (action == "load")
                    {
                        var s = Source(Num(body, "sourceId"), Num(body, "showId"));
                        var tracks = await Archive(s, shutdown.Token);
                        long number = Num(body, "trackNumber");
                        var start = number > 0 ? tracks.FindIndex(track => track.number == number) : 0;
                        if (start < 0) throw Problem("This track is no longer available in the recording.");
                        Queue(request, s.Title, "archive", tracks, start);
                    }
                    else if (action == "loadAlbum")
                        await PlayAlbum(body, request);
                    else if (action == "playLibrary")
                        PlayLibrary(body, request);
                    break;
                case "download":
                    await Download(body);
                    break;
                case "library":
                    await Library(body);
                    break;
                case "plex":
                    await PlexAction(body, request);
                    break;
                }
            }
            catch (Exception e)
            {
                if (disposed)
                    return;
                string message = Message(e);
                if (request != 0 && request == latestRequest)
                    Send("windowsMediaReply", new { request, error = message });
                if (channel == "plex")
                {
                    plexMessage = message;
                    PlexState();
                }
                else if (channel == "library")
                    PublishLibrary(message);
                else if (channel == "download")
                    DownloadState(Num(body, "sourceId"), "failed", 0, message, "");
                else if (channel == "live" && action == "openDownload")
                    Send("windowsMediaNotice", message);
            }
        }
        public void Dispose()
        {
            disposed = true;
            shutdown.Cancel();
            http.Dispose();
            ReleaseHandles();
        }
    }
}
