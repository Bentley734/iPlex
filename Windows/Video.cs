using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace MusicRoom
{
    internal sealed partial class WindowsMediaService
    {
        const string VideoPrefix = "/video/:/transcode/universal/";
        const string VideoOrigin = "https://media.musicroom.invalid/video/";
        readonly VideoWatchStore videoWatch;
        List<Section> videoSections = new List<Section>();
        readonly Dictionary<string, Tuple<Server, string, string>> videoArt = new Dictionary<string, Tuple<Server, string, string>>();
        readonly Dictionary<string, string> videoArtIds = new Dictionary<string, string>();
        readonly Dictionary<string, VideoResource> videoResources = new Dictionary<string, VideoResource>();
        readonly Dictionary<Uri, string> videoAliases = new Dictionary<Uri, string>();
        CancellationTokenSource videoJob;
        string activeVideoServer, activeVideoLibrary, activeVideoKey, activeVideoShow;

        sealed class VideoResource
        {
            public Server Server;
            public Uri Target;
            public string Mime;
            public bool Matroska, Started;
        }

        static readonly Dictionary<string, string> VideoMimes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
            { ".mp4", "video/mp4" }, { ".m4v", "video/mp4" }, { ".mov", "video/quicktime" },
            { ".webm", "video/webm" }, { ".mkv", "video/x-matroska" }, { ".avi", "video/x-msvideo" },
            { ".mpg", "video/mpeg" }, { ".mpeg", "video/mpeg" }, { ".ts", "video/mp2t" },
            { ".m2ts", "video/mp2t" }, { ".ogv", "video/ogg" }, { ".wmv", "video/x-ms-wmv" },
            { ".3gp", "video/3gpp" }, { ".3g2", "video/3gpp2" }, { ".asf", "video/x-ms-asf" },
            { ".vob", "video/mpeg" }, { ".flv", "video/x-flv" }
        };

        string RegisterVideoArt(Server server, string library, string path)
        {
            if (path == null) return "";
            string id;
            string key = library + "/" + path;
            if (!videoArtIds.TryGetValue(key, out id))
            {
                if (videoArt.Count >= 2400) { videoArt.Clear(); videoArtIds.Clear(); }
                id = Guid.NewGuid().ToString("N");
                videoArtIds.Add(key, id);
                videoArt.Add(id, Tuple.Create(server, library, path));
            }
            return "/art/" + id;
        }

        async Task<WindowsMediaResponse> VideoPoster(Server server, string library, string path, string method)
        {
            await artSlots.WaitAsync(shutdown.Token);
            try
            {
                var target = CoverCachePath(server.Id, library, path);
                var bytes = File.Exists(target) ? File.ReadAllBytes(target) : await FetchArtwork(server, path, shutdown.Token);
                string mime = ArtworkMime(bytes);
                return mime == null ? Response(415, "Unsupported image") :
                    Response(200, "OK", "Content-Type: " + mime + "\r\n", method == "HEAD" ? null : new MemoryStream(bytes, false));
            }
            catch (Exception) { return Response(503, "Artwork unavailable"); }
            finally { artSlots.Release(); }
        }

        void ResetVideoLibraries()
        {
            videoSections.Clear();
            videoArt.Clear();
            videoArtIds.Clear();
            ReleaseVideoPlayback();
        }

        void ReleaseVideoPlayback()
        {
            if (videoJob != null) videoJob.Cancel();
            var sessions = videoResources.Values.Where(value => value.Started).ToArray();
            activeVideoServer = activeVideoLibrary = activeVideoKey = activeVideoShow = null;
            videoAliases.Clear();
            videoResources.Clear();
            foreach (var session in sessions) StopVideo(session);
        }

        async void StopVideo(VideoResource resource)
        {
            try
            {
                var query = resource.Target.Query.TrimStart('?').Split('&')
                    .FirstOrDefault(s => s.StartsWith("session=", StringComparison.Ordinal));
                if (query == null) return;
                var url = new Uri(resource.Target, VideoPrefix + "stop?" + query);
                await FetchBytes(PlexRequest(HttpMethod.Get, url, resource.Server.Token), 64 * 1024, shutdown.Token, 10);
            }
            catch (Exception) { }
        }

        string RegisterVideoResource(Server server, Uri target, string mime, bool matroska = false)
        {
            string alias;
            if (videoAliases.TryGetValue(target, out alias)) return VideoOrigin + alias;
            if (videoResources.Count >= 30000) throw Problem("The Plex video playlist is too large.");
            alias = Guid.NewGuid().ToString("N");
            videoAliases.Add(target, alias);
            videoResources.Add(alias, new VideoResource { Server = server, Target = target, Mime = mime, Matroska = matroska });
            return VideoOrigin + alias;
        }

        static string VideoQuery(IEnumerable<KeyValuePair<string, string>> fields)
        {
            return String.Join("&", fields.Select(pair =>
                Uri.EscapeDataString(pair.Key) + "=" + Uri.EscapeDataString(pair.Value)));
        }

        async Task VideoAction(Dictionary<string, object> request, string action, long id)
        {
            if (action == "videoClose") { ReleaseVideoPlayback(); return; }
            string kind = Str(request, "kind"), library = Str(request, "library"), key = Str(request, "item");
            string expected = Str(request, "type");
            Server server;
            if (!servers.TryGetValue(selectedServer, out server) ||
                !videoSections.Any(s => s.id == library && s.type == kind))
            {
                Send("plexVideoError", new { id, message = "Choose a video library first." });
                return;
            }
            if (action == "videoNext" && (Str(request, "server") != server.Id || kind != "show"
                || activeVideoServer != server.Id || activeVideoLibrary != library || activeVideoKey != key)) return;
            bool watchAction = action == "videoWatchState" || action == "videoWatchUpdate" || action == "videoWatchClear";
            if (watchAction && Str(request, "server") != server.Id) return;
            if (action == "videoWatchState")
            {
                SendVideoWatchState(server, library, id);
                return;
            }
            if (action == "videoWatchUpdate" || action == "videoWatchClear")
            {
                if (!ItemID.IsMatch(key) || expected != (kind == "movie" ? "movie" : "episode")) return;
                if (action == "videoWatchClear") videoWatch.Clear(server.Id, library, key);
                else
                {
                    double seconds;
                    bool watched = Object.Equals(Get(request, "watched"), true);
                    if (!Double.TryParse(Str(request, "seconds"), NumberStyles.Float, CultureInfo.InvariantCulture, out seconds)
                        || Double.IsNaN(seconds) || Double.IsInfinity(seconds) || seconds > 2592000 || (!watched && seconds < 5)) return;
                    var artwork = Str(request, "artwork");
                    var title = Str(request, "title");
                    var subtitle = Str(request, "subtitle");
                    string payload = Json().Serialize(new {
                        key, type = expected, title = title.Substring(0, Math.Min(200, title.Length)),
                        subtitle = subtitle.Substring(0, Math.Min(120, subtitle.Length)),
                        artwork = artwork.Length < 180 && ArtPath.IsMatch(artwork) ? artwork : "",
                        watched, seconds = watched ? 0 : seconds
                    });
                    videoWatch.Save(server.Id, library, key, watched, payload);
                    if (id == 0) return;
                }
                SendVideoWatchState(server, library, id);
                return;
            }
            if (action == "videoPlay") ReleaseVideoPlayback();
            else if (videoJob != null) videoJob.Cancel();

            var job = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            videoJob = job;
            try
            {
                if (action == "videoBrowse")
                {
                    long offset = Num(request, "offset");
                    if (offset < 0 || offset > Int32.MaxValue - 2000) throw Problem("Invalid video listing.");
                    string path;
                    if (key.Length == 0)
                    {
                        expected = kind;
                        string filter = Str(request, "query").Trim();
                        path = "/library/sections/" + library + "/all?type=" + (kind == "movie" ? "1" : "2") +
                            (filter.Length == 0 ? "" : "&title=" + Uri.EscapeDataString(filter.Substring(0, Math.Min(120, filter.Length))));
                    }
                    else
                    {
                        if (kind != "show" || !ItemID.IsMatch(key) || (expected != "season" && expected != "episode"))
                            throw Problem("Invalid TV listing.");
                        path = "/library/metadata/" + key + "/children?";
                    }
                    path += (path.EndsWith("?") ? "" : "&") + "X-Plex-Container-Start=" +
                        offset.ToString(CultureInfo.InvariantCulture) + "&X-Plex-Container-Size=60";
                    var result = await WithServer(server, url => FetchPlex(HttpMethod.Get, new Uri(url, path),
                        server.Token, job.Token, 8 * 1024 * 1024), job.Token);
                    var container = Map(Get(Map(result), "MediaContainer"));
                    var rows = Metadata(result, library).Where(row => Str(row, "type") == expected &&
                        ItemID.IsMatch(Str(row, "ratingKey")) && Str(row, "title").Length > 0 &&
                        (key.Length == 0 || !row.ContainsKey("parentRatingKey") || Str(row, "parentRatingKey") == key))
                        .GroupBy(row => Str(row, "ratingKey")).Select(group => group.First()).ToArray();
                    var items = rows.Select(row => new {
                        key = Str(row, "ratingKey"), type = expected, title = Str(row, "title"),
                        summary = Str(row, "summary"), subtitle = expected == "episode" && Num(row, "index") > 0 ?
                            "Episode " + Str(row, "index") : Str(row, "year"),
                        thumb = ArtworkPath(row, "thumb"), artwork = RegisterVideoArt(server, library, ArtworkPath(row, "thumb"))
                    }).ToArray();
                    int count = Rows(Get(container, "Metadata")).Count();
                    long end = offset + count, total = Num(container, "totalSize");
                    Send("plexVideoListing", new { id, items, next = items.Length > 0 && (total > 0 ? end < total : count >= 60)
                        ? (long?)end : null });
                }
                else if (action == "videoPlay")
                {
                    if (!ItemID.IsMatch(key) || expected != (kind == "movie" ? "movie" : "episode"))
                        throw Problem("Invalid video selection.");
                    string path = "/library/metadata/" + key;
                    var result = await WithServer(server, async url => new {
                        Base = url,
                        Data = await FetchPlex(HttpMethod.Get, new Uri(url, path), server.Token, job.Token, 8 * 1024 * 1024)
                    }, job.Token);
                    var item = Metadata(result.Data, library).FirstOrDefault(row =>
                        Str(row, "type") == expected && Str(row, "ratingKey") == key);
                    if (item == null) throw Problem("This video is unavailable in the selected library.");
                    var versions = Rows(Get(item, "Media")).Take(16).Select((media, index) =>
                        DescribeVideoVersion(media, index, server, result.Base)).ToArray();
                    long requested = -1;
                    var requestVersion = Str(request, "version");
                    if (requestVersion.Length != 0 && (!Int64.TryParse(requestVersion, out requested) ||
                        requested < -1 || (requested >= 0 && requested >= versions.Length)))
                        throw Problem("That video version is no longer available.");
                    var options = requested < 0 ? versions : versions.Where(option => option.index == requested).ToArray();
                    var direct = options.Where(option => option.url.Length != 0).ToArray();
                    var fallbackIndices = options.Select(option => option.index).DefaultIfEmpty(0);
                    var fallbacks = fallbackIndices.ToDictionary(index => index,
                        index => RegisterVideoFallback(server, result.Base, path, index));
                    var showID = Str(item, "grandparentRatingKey");
                    activeVideoServer = server.Id;
                    activeVideoLibrary = library;
                    activeVideoKey = key;
                    activeVideoShow = expected == "episode" && ItemID.IsMatch(showID) ? showID : null;
                    Send("plexVideoSource", new {
                        id, direct, hls = fallbacks[options.Length > 0 ? options[0].index : 0], fallbacks = fallbacks.ToDictionary(
                            pair => pair.Key.ToString(CultureInfo.InvariantCulture), pair => pair.Value),
                        versions = versions.Select(option => new { option.index, option.label }).ToArray(),
                        canAdvance = activeVideoShow != null
                    });
                }
                else if (action == "videoNext")
                {
                    var advance = activeVideoShow == null ? null :
                        await FindNextEpisode(server, library, activeVideoShow, key, job.Token);
                    job.Token.ThrowIfCancellationRequested();
                    Send("plexVideoNext", new { id, item = advance });
                }
            }
            catch (Exception error)
            {
                if (!job.IsCancellationRequested)
                {
                    if (action == "videoNext") Send("plexVideoNext", new { id, error = true });
                    else Send("plexVideoError", new { id, message = error is InvalidDataException ?
                        error.Message : "Couldn’t load video from Plex." });
                }
            }
            finally
            {
                if (videoJob == job) videoJob = null;
                job.Dispose();
            }
        }

        sealed class VideoVersion
        {
            public int index { get; set; }
            public string label { get; set; }
            public string url { get; set; }
            public string mime { get; set; }
            public bool native { get; set; }
            public string video { get; set; }
            public string audio { get; set; }
        }

        static string MediaLabel(string value)
        { return value.Length > 24 ? "" : value.Trim().ToUpperInvariant(); }

        VideoVersion DescribeVideoVersion(Dictionary<string, object> media, int index, Server server, Uri basis)
        {
            string container = Str(media, "container").ToLowerInvariant();
            string resolution = MediaLabel(Str(media, "videoResolution"));
            long height = Num(media, "height"), pixels;
            if (resolution.Length == 0 && height > 0) resolution = height.ToString(CultureInfo.InvariantCulture);
            if (Int64.TryParse(resolution, out pixels)) resolution += "p";
            long bitrate = Num(media, "bitrate");
            string label = String.Join(" · ", new[] { "Version " + (index + 1), resolution,
                MediaLabel(Str(media, "videoCodec")), MediaLabel(container), MediaLabel(Str(media, "audioCodec")),
                bitrate > 0 ? bitrate.ToString(CultureInfo.InvariantCulture) + " kbps" : "" }
                .Where(value => value.Length > 0));
            var parts = Rows(Get(media, "Part")).Take(2).ToArray();
            string part = parts.Length == 1 ? Str(parts[0], "key") : "", mime = "application/octet-stream", url = "";
            string matchedMime;
            bool direct = PartPath(part);
            if (direct && VideoMimes.TryGetValue(Path.GetExtension(part), out matchedMime)) mime = matchedMime;
            bool native = mime == "video/x-matroska" || mime == "video/webm" ||
                          container == "mkv" || container == "matroska" || container == "webm";
            if (direct) url = RegisterVideoResource(server, new Uri(basis, part), mime, native);
            return new VideoVersion { index = index, label = label, url = url, mime = mime, native = native,
                video = Str(media, "videoCodec").ToLowerInvariant(), audio = Str(media, "audioCodec").ToLowerInvariant() };
        }

        string RegisterVideoFallback(Server server, Uri basis, string path, int index)
        {
            var query = VideoQuery(new Dictionary<string, string> {
                { "path", path }, { "protocol", "hls" }, { "directPlay", "0" }, { "directStream", "0" },
                { "mediaIndex", index.ToString(CultureInfo.InvariantCulture) }, { "session", Guid.NewGuid().ToString("N") },
                { "subtitles", "burn" }, { "videoQuality", "100" }, { "videoResolution", "1920x1080" },
                { "maxVideoBitrate", "20000" }, { "X-Plex-Client-Profile-Name", "iOS" },
                { "X-Plex-Client-Profile-Extra", "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)" }
            });
            return RegisterVideoResource(server, new Uri(basis, VideoPrefix + "start.m3u8?" + query), "application/vnd.apple.mpegurl");
        }

        static long EpisodeOrder(Dictionary<string, object> row, string key)
        {
            long value;
            return Int64.TryParse(Str(row, key), out value) && value >= 0 ? value : Int64.MaxValue;
        }

        internal static Dictionary<string, object> NextEpisodeRow(IEnumerable<Dictionary<string, object>> rows,
            string current, HashSet<string> watched)
        {
            var ordered = rows.OrderBy(row => EpisodeOrder(row, "parentIndex")).ThenBy(row => EpisodeOrder(row, "index")).ToArray();
            int start = Array.FindIndex(ordered, row => Str(row, "ratingKey") == current);
            return start < 0 ? null : ordered.Skip(start + 1).FirstOrDefault(row =>
                Num(row, "viewCount") <= 0 && !watched.Contains(Str(row, "ratingKey")));
        }

        async Task<object> FindNextEpisode(Server server, string library, string show, string current, CancellationToken token)
        {
            var watched = videoWatch.WatchedIds(server.Id, library);
            var candidate = await WithServer(server, async basis =>
            {
                var episodes = new List<Dictionary<string, object>>();
                var seen = new HashSet<string>();
                const int size = 100;
                int offset = 0;
                while (offset < 20000)
                {
                    string path = "/library/metadata/" + show + "/allLeaves?X-Plex-Container-Size=" + size +
                        "&X-Plex-Container-Start=" + offset.ToString(CultureInfo.InvariantCulture);
                    var result = await FetchPlex(HttpMethod.Get, new Uri(basis, path), server.Token, token, 8 * 1024 * 1024);
                    var container = Map(Get(Map(result), "MediaContainer"));
                    var rows = Metadata(result, library).Where(row => Str(row, "type") == "episode"
                        && ItemID.IsMatch(Str(row, "ratingKey")) && Str(row, "title").Length > 0
                        && (!row.ContainsKey("grandparentRatingKey") || Str(row, "grandparentRatingKey") == show)
                        && seen.Add(Str(row, "ratingKey"))).ToArray();
                    episodes.AddRange(rows);
                    int count = Rows(Get(container, "Metadata")).Count();
                    offset += count;
                    long total = Num(container, "totalSize");
                    if (count == 0 || rows.Length == 0 || (total > 0 ? offset >= total : count < size)) break;
                }
                return NextEpisodeRow(episodes, current, watched);
            }, token);
            if (candidate == null) return null;
            string thumb = ArtworkPath(candidate, "thumb");
            var index = EpisodeOrder(candidate, "index");
            var season = EpisodeOrder(candidate, "parentIndex");
            return new {
                key = Str(candidate, "ratingKey"), type = "episode", title = Str(candidate, "title"),
                summary = Str(candidate, "summary"), subtitle = index != Int64.MaxValue && season != Int64.MaxValue ?
                    "Season " + season + " · Episode " + index : "",
                thumb, artwork = RegisterVideoArt(server, library, thumb)
            };
        }

        void SendVideoWatchState(Server server, string library, long id)
        {
            var records = videoWatch.Records(server.Id, library).Select(value => {
                var row = Map(value);
                var path = Str(row, "artwork");
                row["thumb"] = path;
                row["artwork"] = path.Length < 180 && ArtPath.IsMatch(path) ? RegisterVideoArt(server, library, path) : "";
                return row;
            }).ToArray();
            Send("plexVideoWatchState", new { id, records });
        }

        static readonly Regex ManifestAttribute = new Regex("(?:^|[:,])(?:URI|SERVER-URI|X-ASSET-URI|X-ASSET-LIST)=\"([^\"]+)\"");
        static readonly Regex ManifestPath = new Regex(@"^/video/:/transcode/universal/[A-Za-z0-9_.~/-]+\z");
        internal static Uri VideoManifestTarget(Uri origin, string value)
        {
            Uri resolved;
            if (!Uri.TryCreate(origin, value, out resolved) || resolved.Scheme != origin.Scheme ||
                resolved.Host != origin.Host || resolved.Port != origin.Port || resolved.UserInfo.Length != 0 ||
                resolved.Fragment.Length != 0 || !ManifestPath.IsMatch(resolved.AbsolutePath))
                throw Problem("Plex returned an invalid video playlist.");
            return resolved;
        }

        string RewriteVideoManifest(string text, VideoResource resource)
        {
            if (!text.StartsWith("#EXTM3U", StringComparison.Ordinal))
                throw Problem("Plex returned an invalid video playlist.");
            Func<string, string> link = value =>
            {
                Uri resolved = VideoManifestTarget(resource.Target, value);
                string mime;
                switch (Path.GetExtension(resolved.AbsolutePath).ToLowerInvariant())
                {
                    case ".m3u8": mime = "application/vnd.apple.mpegurl"; break;
                    case ".ts": mime = "video/mp2t"; break;
                    case ".mp4": case ".m4s": mime = "video/mp4"; break;
                    case ".vtt": mime = "text/vtt"; break;
                    default: mime = "application/octet-stream"; break;
                }
                return RegisterVideoResource(resource.Server, resolved, mime);
            };
            return String.Join("\n", text.Replace("\r", "").Split('\n').Select(line =>
            {
                if (line.Length == 0) return line;
                if (line[0] != '#') return link(line);
                return ManifestAttribute.Replace(line, match => {
                    Group value = match.Groups[1];
                    return match.Value.Substring(0, value.Index - match.Index) + link(value.Value) + "\"";
                });
            }));
        }

        internal Uri NativeVideoSource(string value)
        {
            Uri url;
            VideoResource resource;
            if (!Uri.TryCreate(value, UriKind.Absolute, out url) || url.GetLeftPart(UriPartial.Authority) != "https://media.musicroom.invalid" ||
                !Regex.IsMatch(url.AbsolutePath, @"^/video/[a-f0-9]{32}\z") || url.Query.Length != 0 || url.Fragment.Length != 0 ||
                !videoResources.TryGetValue(url.AbsolutePath.Substring(7), out resource) || !resource.Matroska)
                return null;
            return new UriBuilder(resource.Target) {
                Query = "X-Plex-Token=" + Uri.EscapeDataString(resource.Server.Token)
            }.Uri;
        }

        async Task<WindowsMediaResponse> OpenVideo(string handle, string method, string range)
        {
            VideoResource resource;
            if (!videoResources.TryGetValue(handle, out resource)) return Response(404, "Not Found");
            if (method == "OPTIONS") return Response(204, "No Content");
            if (method != "GET" && method != "HEAD") return Response(405, "Method Not Allowed");
            if (resource.Mime != "application/vnd.apple.mpegurl")
                return await ReadMediaAsync(handle, new MediaTrack { remote = resource.Target,
                    token = resource.Server.Token, mime = resource.Mime }, method, range);

            try
            {
                if (resource.Target.AbsolutePath == VideoPrefix + "start.m3u8") resource.Started = true;
                var req = PlexRequest(HttpMethod.Get, resource.Target, resource.Server.Token);
                req.Headers.Remove("Accept");
                req.Headers.Add("Accept", resource.Mime);
                string text = await TextAsync(req, 4 * 1024 * 1024, shutdown.Token, 35);
                if (!videoResources.ContainsKey(handle)) return Response(404, "Not Found");
                var data = Encoding.UTF8.GetBytes(RewriteVideoManifest(text, resource));
                return Response(200, "OK", "Content-Type: " + resource.Mime + "\r\n",
                    method == "HEAD" ? null : new MemoryStream(data, false));
            }
            catch (Exception) { return Response(502, "Video transcoding unavailable"); }
        }
    }
}
