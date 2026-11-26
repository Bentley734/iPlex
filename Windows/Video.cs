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
        List<Section> videoSections = new List<Section>();
        readonly Dictionary<string, Tuple<Server, string>> videoArt = new Dictionary<string, Tuple<Server, string>>();
        readonly Dictionary<string, string> videoArtIds = new Dictionary<string, string>();
        readonly Dictionary<string, VideoResource> videoResources = new Dictionary<string, VideoResource>();
        readonly Dictionary<Uri, string> videoAliases = new Dictionary<Uri, string>();
        CancellationTokenSource videoJob;

        sealed class VideoResource
        {
            public Server Server;
            public Uri Target;
            public string Mime;
        }

        static readonly Dictionary<string, string> VideoMimes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
            { ".mp4", "video/mp4" }, { ".m4v", "video/mp4" }, { ".mov", "video/quicktime" },
            { ".webm", "video/webm" }, { ".mkv", "video/x-matroska" }, { ".avi", "video/x-msvideo" },
            { ".mpg", "video/mpeg" }, { ".mpeg", "video/mpeg" }, { ".ts", "video/mp2t" },
            { ".m2ts", "video/mp2t" }, { ".ogv", "video/ogg" }, { ".wmv", "video/x-ms-wmv" },
            { ".3gp", "video/3gpp" }, { ".3g2", "video/3gpp2" }, { ".asf", "video/x-ms-asf" },
            { ".vob", "video/mpeg" }, { ".flv", "video/x-flv" }
        };

        string RegisterVideoArt(Server server, string path)
        {
            if (path == null) return "";
            string id;
            if (!videoArtIds.TryGetValue(path, out id))
            {
                if (videoArt.Count >= 2400) { videoArt.Clear(); videoArtIds.Clear(); }
                id = Guid.NewGuid().ToString("N");
                videoArtIds.Add(path, id);
                videoArt.Add(id, Tuple.Create(server, path));
            }
            return "/art/" + id;
        }

        async Task<WindowsMediaResponse> VideoPoster(Server server, string path, string method)
        {
            await artSlots.WaitAsync(shutdown.Token);
            try
            {
                var bytes = await FetchArtwork(server, path, shutdown.Token);
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
            var session = videoResources.Values.FirstOrDefault(value =>
                value.Target.AbsolutePath == VideoPrefix + "start.m3u8");
            videoAliases.Clear();
            videoResources.Clear();
            if (session != null) StopVideo(session);
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

        string RegisterVideoResource(Server server, Uri target, string mime)
        {
            string alias;
            if (videoAliases.TryGetValue(target, out alias)) return VideoOrigin + alias;
            if (videoResources.Count >= 30000) throw Problem("The Plex video playlist is too large.");
            alias = Guid.NewGuid().ToString("N");
            videoAliases.Add(target, alias);
            videoResources.Add(alias, new VideoResource { Server = server, Target = target, Mime = mime });
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
                        artwork = RegisterVideoArt(server, ArtworkPath(row, "thumb"))
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
                    var direct = new List<object>();
                    foreach (var media in Rows(Get(item, "Media")).Take(16))
                    {
                        var parts = Rows(Get(media, "Part")).Take(2).ToArray();
                        if (parts.Length != 1) continue;
                        string part = Str(parts[0], "key"), mime;
                        if (!PartPath(part)) continue;
                        if (!VideoMimes.TryGetValue(Path.GetExtension(part), out mime))
                            mime = "application/octet-stream";
                        direct.Add(new { url = RegisterVideoResource(server, new Uri(result.Base, part), mime), mime,
                            video = Str(media, "videoCodec").ToLowerInvariant(), audio = Str(media, "audioCodec").ToLowerInvariant() });
                    }
                    var query = VideoQuery(new Dictionary<string, string> {
                        { "path", path }, { "protocol", "hls" }, { "directPlay", "0" }, { "directStream", "0" },
                        { "mediaIndex", "0" }, { "session", Guid.NewGuid().ToString("N") }, { "subtitles", "burn" },
                        { "videoQuality", "100" }, { "videoResolution", "1920x1080" }, { "maxVideoBitrate", "20000" },
                        { "X-Plex-Client-Profile-Name", "iOS" },
                        { "X-Plex-Client-Profile-Extra", "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)" }
                    });
                    var hls = RegisterVideoResource(server,
                        new Uri(result.Base, VideoPrefix + "start.m3u8?" + query), "application/vnd.apple.mpegurl");
                    Send("plexVideoSource", new { id, direct, hls });
                }
            }
            catch (Exception error)
            {
                if (!job.IsCancellationRequested)
                    Send("plexVideoError", new { id, message = error is InvalidDataException ?
                        error.Message : "Couldn’t load video from Plex." });
            }
            finally
            {
                if (videoJob == job) videoJob = null;
                job.Dispose();
            }
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
