using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace MusicRoom
{
    internal sealed partial class WindowsMediaService
    {
        sealed class OfflineItem
        {
            public string id { get; set; }
            public string title { get; set; }
            public string detail { get; set; }
            public string kind { get; set; }
            public List<OfflineFile> files { get; set; }
        }

        sealed class OfflineFile
        {
            public string name { get; set; }
            public string title { get; set; }
            public double? durationSeconds { get; set; }
        }

        sealed class OfflineRequest
        {
            public string id { get; set; }
            public string title { get; set; }
            public string error { get; set; }
            internal string Action;
            internal string ServerID;
            internal string Section;
            internal Dictionary<string, object> Body;
        }

        CancellationTokenSource offlineJob;
        readonly List<OfflineRequest> offlinePending = new List<OfflineRequest>();
        readonly List<OfflineRequest> offlineFailures = new List<OfflineRequest>();
        double? offlineProgress;
        string offlineMessage = "";
        string OfflineRoot { get { return Path.Combine(root, "Offline Media"); } }

        IEnumerable<OfflineItem> OfflineItems()
        {
            if (!Directory.Exists(OfflineRoot)) yield break;
            foreach (string folder in Directory.EnumerateDirectories(OfflineRoot))
            {
                string id = Path.GetFileName(folder);
                Guid parsed;
                if (!Guid.TryParseExact(id, "N", out parsed)) continue;
                OfflineItem item;
                try
                {
                    string manifest = Path.Combine(folder, "media.json");
                    if (!RealFile(manifest) || new FileInfo(manifest).Length > 8 * 1024 * 1024) continue;
                    item = Json().Deserialize<OfflineItem>(File.ReadAllText(manifest));
                    if (item == null || item.id != id || item.files == null || item.files.Count == 0 ||
                        (item.kind != "music" && item.kind != "movie" && item.kind != "episode") ||
                        item.files.Any(file => file == null || file.name == null ||
                            !Regex.IsMatch(file.name, @"^[0-9]+\.[a-z0-9]{2,10}\z") ||
                            !RealFile(Path.Combine(folder, file.name)))) continue;
                }
                catch (Exception) { continue; }
                yield return item;
            }
        }

        void PublishOffline()
        {
            Send("offlineState", new { items = OfflineItems().OrderBy(row => row.title).Select(row => new {
                row.id, row.title, row.detail, row.kind, tracks = row.files.Count,
                resume = row.kind != "music" ? OfflinePosition(row.id) : 0
            }).ToArray(), busy = offlineJob != null, message = offlineMessage, progress = offlineProgress, pending = offlinePending.ToArray(), failed = offlineFailures.ToArray() });
        }

        internal void RefreshOffline() { PublishOffline(); }

        internal Uri OfflineVideo(string id)
        {
            OfflineItem item = OfflineItems().FirstOrDefault(row => row.id == id && row.kind != "music");
            return item == null ? null : new Uri(Path.Combine(OfflineRoot, item.id, item.files[0].name));
        }

        internal double OfflinePosition(string id)
        {
            Guid parsed;
            if (!Guid.TryParseExact(id, "N", out parsed)) return 0;
            try
            {
                string file = Path.Combine(OfflineRoot, id, "position.txt");
                if (!File.Exists(file)) return 0;
                double value;
                if (Double.TryParse(File.ReadAllText(file), System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture, out value) && value >= 5 && value < 2592000) return value;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return 0;
        }

        internal void RememberOfflinePosition(string id, double seconds, bool finished)
        {
            Guid parsed;
            if (!Guid.TryParseExact(id, "N", out parsed) || Double.IsNaN(seconds) || Double.IsInfinity(seconds)) return;
            try
            {
                File.WriteAllText(Path.Combine(OfflineRoot, id, "position.txt"),
                    (finished ? 0 : seconds).ToString(System.Globalization.CultureInfo.InvariantCulture));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            if (finished) PublishOffline();
        }

        async Task HandleOffline(string action, Dictionary<string, object> body)
        {
            if (action == "offlineList") { PublishOffline(); return; }
            if (action == "offlineCancel") { if (offlineJob != null) offlineJob.Cancel(); return; }
            if (action == "offlineRetry" || action == "offlineDismiss")
            {
                string jobID = Str(body, "job");
                OfflineRequest failed = offlineFailures.FirstOrDefault(row => row.id == jobID);
                if (failed != null) offlineFailures.Remove(failed);
                if (action == "offlineRetry" && failed != null)
                {
                    failed.error = null;
                    offlinePending.Add(failed);
                }
                if (action == "offlineDismiss") offlinePending.RemoveAll(row => row.id == jobID);
                PublishOffline();
                await StartNextOffline();
                return;
            }
            if (action == "offlinePlay" || action == "offlineRemove")
            {
                OfflineItem item = OfflineItems().FirstOrDefault(row => row.id == Str(body, "media"));
                if (item == null) return;
                if (action == "offlineRemove")
                {
                    try { Directory.Delete(Path.Combine(OfflineRoot, item.id), true); offlineMessage = "Removed " + item.title + "."; }
                    catch (IOException) { offlineMessage = "Could not remove " + item.title + "."; }
                    catch (UnauthorizedAccessException) { offlineMessage = "Could not remove " + item.title + "."; }
                    PublishOffline();
                }
                else if (item.kind == "music")
                {
                    var tracks = item.files.Select(file =>
                    {
                        string mime;
                        if (!Mime.TryGetValue(Path.GetExtension(file.name), out mime)) mime = "application/octet-stream";
                        return new MediaTrack { title = file.title, album = item.title, artist = item.detail,
                            durationSeconds = file.durationSeconds, mime = mime, localPath = Path.Combine(OfflineRoot, item.id, file.name) };
                    }).ToList();
                    Send("offlineQueue", new { title = item.title, artist = item.detail, context = item.title,
                        origin = "offline", startIndex = 0, tracks = QueueEntries(tracks, item.id, true) });
                }
                return;
            }
            offlinePending.Add(new OfflineRequest { id = Guid.NewGuid().ToString("N"),
                title = String.Concat(Str(body, "title").Take(400)), Action = action, ServerID = selectedServer,
                Section = selectedSection, Body = new Dictionary<string, object>(body) });
            PublishOffline();
            await StartNextOffline();
        }

        async Task StartNextOffline()
        {
            while (offlineJob == null && offlinePending.Count > 0 && !shutdown.IsCancellationRequested)
            {
                OfflineRequest request = offlinePending[0];
                offlinePending.RemoveAt(0);
                await TransferOffline(request);
            }
        }

        async Task TransferOffline(OfflineRequest queued)
        {
            string action = queued.Action;
            Dictionary<string, object> body = queued.Body;
            string id = queued.id;
            string stage = Path.Combine(OfflineRoot, "." + id + ".partial");
            using (var job = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token))
            {
                offlineJob = job;
                offlineProgress = null;
                offlineMessage = "Preparing " + queued.title + "…";
                PublishOffline();
                try
                {
                    Server server;
                    if (!servers.TryGetValue(queued.ServerID, out server)) throw Problem("The Plex server is unavailable.");
                    string key = Str(body, "item");
                    if (!ItemID.IsMatch(key)) throw Problem("Invalid download selection.");
                    var item = new OfflineItem { id = id, title = Str(body, "title"), detail = Str(body, "detail"), files = new List<OfflineFile>() };
                    item.title = String.Concat(item.title.Take(400));
                    item.detail = String.Concat(item.detail.Take(400));
                    List<MediaTrack> sources;
                    if (action == "offlineDownloadMusic")
                    {
                        string kind = Str(body, "kind");
                        if (queued.Section.Length == 0 || (kind != "album" && kind != "track" && kind != "playlist"))
                            throw Problem("Invalid music download.");
                        sources = await LoadAlbumTracks(server, queued.Section, key, kind, job.Token);
                        item.kind = "music";
                    }
                    else
                    {
                        string section = Str(body, "library"), kind = Str(body, "kind");
                        if ((kind != "movie" && kind != "episode") || !videoSections.Any(row =>
                            row.id == section && row.type == (kind == "movie" ? "movie" : "show")))
                            throw Problem("Invalid video download.");
                        sources = await WithServer(server, async basis => {
                            var payload = await FetchPlex(HttpMethod.Get, new Uri(basis, "/library/metadata/" + key),
                                server.Token, job.Token, 8 * 1024 * 1024);
                            var row = Metadata(payload, section).FirstOrDefault(match => Str(match, "type") == kind && Str(match, "ratingKey") == key);
                            if (row == null) throw Problem("The video is unavailable.");
                            var versions = Rows(Get(row, "Media")).Take(16).ToArray();
                            long index;
                            string requested = Str(body, "version");
                            if (Int64.TryParse(requested, out index) && index >= 0)
                                versions = versions.Where((_, offset) => offset == index).ToArray();
                            foreach (var version in versions)
                            {
                                var parts = Rows(Get(version, "Part")).Take(2).ToArray();
                                if (parts.Length != 1) continue;
                                string path = Str(parts[0], "key");
                                if (PartPath(path))
                                    return new List<MediaTrack> { new MediaTrack { title = Str(row, "title"), remote = new Uri(basis, path), token = server.Token } };
                            }
                            return new List<MediaTrack>();
                        }, job.Token);
                        item.kind = kind;
                    }
                    if (sources.Count == 0) throw Problem("No original files are available.");
                    if (String.IsNullOrWhiteSpace(item.title)) item.title = sources[0].title;
                    Directory.CreateDirectory(stage);
                    foreach (var track in sources)
                    {
                        job.Token.ThrowIfCancellationRequested();
                        int number = item.files.Count + 1;
                        offlineMessage = "Downloading " + item.title + " · " + number + " of " + sources.Count;
                        PublishOffline();
                        string extension = Path.GetExtension(track.remote.AbsolutePath).ToLowerInvariant();
                        if (!Regex.IsMatch(extension, @"^\.[a-z0-9]{2,10}\z")) throw Problem("Unknown media file type.");
                        string name = number + extension;
                        using (var request = PlexRequest(HttpMethod.Get, track.remote, track.token))
                        {
                            request.Headers.Remove("Accept");
                            using (var reply = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, job.Token))
                            {
                                string mime = reply.Content.Headers.ContentType == null ? "" : reply.Content.Headers.ContentType.MediaType;
                                if (reply.StatusCode != System.Net.HttpStatusCode.OK || mime == "text/html" || mime == "application/json")
                                    throw Problem("Plex did not return a complete media file.");
                                long? totalBytes = reply.Content.Headers.ContentLength;
                                using (var source = await reply.Content.ReadAsStreamAsync())
                                using (var destination = new FileStream(Path.Combine(stage, name), FileMode.CreateNew, FileAccess.Write,
                                    FileShare.None, 65536, true))
                                {
                                    var buffer = new byte[65536];
                                    int length;
                                    var clock = System.Diagnostics.Stopwatch.StartNew();
                                    while ((length = await source.ReadAsync(buffer, 0, buffer.Length, job.Token)) > 0)
                                    {
                                        await destination.WriteAsync(buffer, 0, length, job.Token);
                                        if (!totalBytes.HasValue || totalBytes.Value <= 0 || clock.ElapsedMilliseconds < 300) continue;
                                        offlineProgress = (number - 1 + Math.Min(1, (double)destination.Length / totalBytes.Value)) / sources.Count;
                                        PublishOffline();
                                        clock.Restart();
                                    }
                                    if (destination.Length == 0) throw Problem("The downloaded media file was empty.");
                                }
                            }
                        }
                        item.files.Add(new OfflineFile { name = name, title = track.title, durationSeconds = track.durationSeconds });
                    }
                    job.Token.ThrowIfCancellationRequested();
                    File.WriteAllText(Path.Combine(stage, "media.json"), Json().Serialize(item));
                    Directory.Move(stage, Path.Combine(OfflineRoot, id));
                    offlineMessage = "Saved " + item.title + ".";
                }
                catch (OperationCanceledException) { offlineMessage = "Download canceled."; }
                catch (Exception)
                {
                    queued.error = "Check your Plex connection and available storage.";
                    offlineFailures.Add(queued);
                    offlineMessage = "Could not download " + queued.title + ".";
                }
                finally { Clean(stage); offlineJob = null; offlineProgress = null; PublishOffline(); }
            }
        }
    }
}
