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
        static readonly Regex BackdropPath = new Regex(@"^/library/metadata/[0-9]+/art(?:/[0-9]+)?\z");
        const string VideoOrigin = "https://media.musicroom.invalid/video/";
        readonly VideoWatchStore videoWatch;
        List<Section> videoSections = new List<Section>();
        readonly Dictionary<string, Tuple<string, string, string, bool>> videoArt = new Dictionary<string, Tuple<string, string, string, bool>>();
        readonly Dictionary<string, string> videoArtIds = new Dictionary<string, string>();
        readonly Dictionary<string, VideoResource> videoResources = new Dictionary<string, VideoResource>();
        readonly Dictionary<Uri, string> videoAliases = new Dictionary<Uri, string>();
        CancellationTokenSource videoJob, movieDetailsJob;
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

        string RegisterVideoArt(string server, string library, string path, bool cache = false)
        {
            if (path == null) return "";
            string id;
            string key = server + "/" + library + "/" + path;
            if (!videoArtIds.TryGetValue(key, out id))
            {
                if (videoArt.Count >= 2400) { videoArt.Clear(); videoArtIds.Clear(); }
                id = Guid.NewGuid().ToString("N");
                videoArtIds.Add(key, id);
            }
            else cache |= videoArt[id].Item4;
            videoArt[id] = Tuple.Create(server, library, path, cache);
            return "/art/" + id;
        }

        async Task<WindowsMediaResponse> VideoPoster(string serverId, string library, string path, bool cache, string method)
        {
            await artSlots.WaitAsync(shutdown.Token);
            try
            {
                var target = CoverCachePath(serverId, library, path);
                var bytes = await Task.Run(() => File.Exists(target) ? File.ReadAllBytes(target) : null, shutdown.Token);
                if (bytes == null)
                {
                    Server server;
                    if (serverId != selectedServer || !servers.TryGetValue(serverId, out server) ||
                        !videoSections.Any(section => section.id == library))
                        return Response(404, "Not Found");
                    bytes = cache
                        ? await WithServer(server, url => FetchCacheThumbnail(url, path, server.Token, shutdown.Token), shutdown.Token)
                        : await FetchArtwork(server, path, shutdown.Token);
                    if (cache)
                    {
                        try { await Task.Run(() => SaveCover(bytes, target), shutdown.Token); }
                        catch (IOException) { }
                        catch (UnauthorizedAccessException) { }
                        catch (ArgumentException) { }
                        catch (System.Runtime.InteropServices.ExternalException) { }
                    }
                }
                string mime = ArtworkMime(bytes);
                return mime == null ? Response(415, "Unsupported image") :
                    Response(200, "OK", "Content-Type: " + mime + "\r\n", method == "HEAD" ? null : new MemoryStream(bytes, false));
            }
            catch (Exception) { return Response(503, "Artwork unavailable"); }
            finally { artSlots.Release(); }
        }

        void SaveLaunchVideo(string server, string library, string kind, IEnumerable<Dictionary<string, object>> rows)
        {
            var section = videoSections.FirstOrDefault(item => item.id == library && item.type == kind);
            if (section == null) return;
            var items = rows.Take(60).Select(row => new {
                key = Str(row, "ratingKey"), type = kind,
                title = String.Concat(Str(row, "title").Take(400)),
                subtitle = String.Concat(Str(row, "year").Take(12)),
                summary = String.Concat(Str(row, "summary").Take(400)),
                thumb = ArtworkPath(row, "thumb")
            }).ToArray();
            plexPrefs["lastVideoLibrary." + kind] = Json().Serialize(new { server, library, name = section.name, items });
            plexPrefs["server"] = server;
            try { SavePrefs(); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        object ReadLaunchVideo(string kind, string server)
        {
            if (server.Length == 0) return null;
            Dictionary<string, object> saved;
            try
            {
                var json = Pref("lastVideoLibrary." + kind);
                if (json.Length == 0) return null;
                saved = Map(Json().DeserializeObject(json));
            }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }

            string library = Str(saved, "library");
            if (Str(saved, "server") != server || !ItemID.IsMatch(library)) return null;
            var items = Rows(Get(saved, "items")).Take(60)
                .Where(row => Str(row, "type") == kind && ItemID.IsMatch(Str(row, "key")))
                .Select(row => {
                    var entry = new Dictionary<string, object>(row);
                    entry["artwork"] = RegisterVideoArt(server, library, ArtworkPath(row, "thumb"), true);
                    return entry;
                }).ToArray();
            return new { library, name = Str(saved, "name"), items };
        }

        void ResetVideoLibraries()
        {
            videoSections.Clear();
            ++matchSearch;
            videoMatches = new VideoMatch[0];
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

        sealed class VideoMatch
        {
            public string key { get; set; }
            public string title { get; set; }
            public string year { get; set; }
        }

        VideoMatch[] videoMatches = new VideoMatch[0];
        string matchServer, matchLibrary, matchItem;
        long matchSearch;
        bool applyingVideoMatch;

        async Task VideoMatchAction(Dictionary<string, object> request, string action, long id)
        {
            bool apply = action == "videoApplyMatch";
            var token = shutdown.Token;
            string library = Str(request, "library"), kind = Str(request, "kind"), item = Str(request, "item");
            string serverID = Str(request, "server");
            var choice = apply && serverID == matchServer && library == matchLibrary && item == matchItem
                ? videoMatches.FirstOrDefault(candidate => candidate.key == Str(request, "choice")) : null;
            if (apply && applyingVideoMatch) return;
            if (apply) applyingVideoMatch = true;
            long search = apply ? matchSearch : ++matchSearch;
            if (!apply) videoMatches = new VideoMatch[0];

            try
            {
                Server server;
                if (serverID != selectedServer || !servers.TryGetValue(serverID, out server) || !ItemID.IsMatch(item) ||
                    !videoSections.Any(section => section.type == kind && section.id == library))
                    throw Problem("Choose a movie or TV show from the connected library.");
                if (apply && choice == null) throw Problem("Search again and choose a match.");
                string title = Str(request, "title").Trim(), year = Str(request, "year").Trim();
                if (!apply && (title.Length == 0 || title.Length > 150 || (year.Length > 0 && !Regex.IsMatch(year, @"^[1-9][0-9]{3}\z"))))
                    throw Problem("Enter a title and an optional four-digit year.");

                string path = "/library/metadata/" + item;
                var basis = await WithServer(server, async url => {
                    var payload = await FetchPlex(HttpMethod.Get, new Uri(url, path), server.Token, token, 4 * 1024 * 1024, 8);
                    if (!Metadata(payload, library).Any(row => Str(row, "type") == kind && Str(row, "ratingKey") == item))
                        throw Problem("This title is no longer available in the selected library.");
                    return url;
                }, token);

                if (selectedServer != serverID || search != matchSearch) return;
                if (apply)
                {
                    var query = new Dictionary<string, string> { { "guid", choice.key }, { "name", choice.title } };
                    if (choice.year.Length > 0) query.Add("year", choice.year);
                    try
                    {
                        await FetchBytes(PlexRequest(HttpMethod.Put, new Uri(basis, path + "/match?" + VideoQuery(query)),
                            server.Token), 2 * 1024 * 1024, token, 20);
                    }
                    catch (InvalidDataException error)
                    {
                        if (error.Message == "The service returned HTTP 401." || error.Message == "The service returned HTTP 403.")
                            throw Problem("Your Plex account doesn’t have permission to change this match.");
                        if (error.Message.StartsWith("The service returned HTTP 4", StringComparison.Ordinal))
                            throw Problem("Plex rejected this match. " + error.Message);
                        throw Problem("Plex didn’t confirm the change. Refresh the library before retrying.");
                    }
                    catch (Exception)
                    {
                        throw Problem("Plex didn’t confirm the change. Refresh the library before retrying.");
                    }
                    videoMatches = new VideoMatch[0];
                    Send("plexVideoMatchResult", new { id, saved = true });
                    return;
                }

                var target = new Uri(basis, path + "/matches?" + VideoQuery(new Dictionary<string, string> {
                    { "manual", "1" }, { "title", title }, { "year", year }
                }));
                object matches = null;
                try { matches = await FetchPlex(HttpMethod.Put, target, server.Token, token, 2 * 1024 * 1024, 16); }
                catch (InvalidDataException error)
                {
                    if (error.Message != "The service returned HTTP 404." && error.Message != "The service returned HTTP 405.") throw;
                }
                if (matches == null) matches = await FetchPlex(HttpMethod.Get, target, server.Token, token, 2 * 1024 * 1024, 16);
                if (selectedServer != serverID || search != matchSearch) return;
                var box = Map(Get(Map(matches), "MediaContainer"));
                videoMatches = Rows(Get(box, "SearchResult") ?? Get(box, "Metadata")).Take(60).Select(row => {
                    var key = Str(row, "guid");
                    var name = Str(row, "name");
                    return new VideoMatch { key = key.Length > 0 ? key : Str(row, "id"),
                        title = name.Length > 0 ? name : Str(row, "title"), year = Str(row, "year") };
                }).Where(row => row.key.Length <= 500 && row.key.Contains("://") && !row.key.Any(Char.IsControl) &&
                    row.title.Length > 0 && row.title.Length <= 300 && !row.title.Any(Char.IsControl))
                    .GroupBy(row => row.key).Select(group => group.First()).ToArray();
                matchServer = serverID;
                matchLibrary = library;
                matchItem = item;
                Send("plexVideoMatchResult", new { id, choices = videoMatches });
            }
            catch (Exception error)
            {
                if (!token.IsCancellationRequested)
                    Send("plexVideoMatchResult", new { id, error = error is InvalidDataException
                        ? error.Message : "Couldn’t search Plex for a match." });
            }
            finally { if (apply) applyingVideoMatch = false; }
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
                if (action == "movieDetails")
                    Send("plexMovieDetails", new { id, key, error = "Choose a video library first." });
                else Send("plexVideoError", new { id, message = "Choose a video library first." });
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
            if (action == "movieDetails")
            {
                if (kind == "movie" && ItemID.IsMatch(key))
                    await LoadMovieDetails(server, library, key, id);
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
                    long requested = Num(request, "pageSize");
                    int size = requested == 30 || requested == 120 ? (int)requested : 60;
                    bool savePreview = key.Length == 0 && offset == 0 && Str(request, "query").Trim().Length == 0;
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
                        offset.ToString(CultureInfo.InvariantCulture) + "&X-Plex-Container-Size=" + size.ToString(CultureInfo.InvariantCulture);
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
                        thumb = ArtworkPath(row, "thumb"), artwork = RegisterVideoArt(server.Id, library, ArtworkPath(row, "thumb"), savePreview)
                    }).ToArray();
                    if (savePreview) SaveLaunchVideo(server.Id, library, kind, rows);
                    int count = Rows(Get(container, "Metadata")).Count();
                    long end = offset + count, total = Num(container, "totalSize");
                    Send("plexVideoListing", new { id, items, next = items.Length > 0 && (total > 0 ? end < total : count >= size)
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
                    bool automaticSubtitles = Str(request, "subtitles") == "automatic";
                    var fallbacks = fallbackIndices.ToDictionary(index => index,
                        index => RegisterVideoFallback(server, result.Base, path, index, automaticSubtitles));
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

        async Task LoadMovieDetails(Server server, string library, string key, long id)
        {
            if (movieDetailsJob != null) movieDetailsJob.Cancel();
            var job = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            movieDetailsJob = job;
            try
            {
                var result = await WithServer(server, url => FetchPlex(HttpMethod.Get,
                    new Uri(url, "/library/metadata/" + key), server.Token, job.Token, 8 * 1024 * 1024), job.Token);
                job.Token.ThrowIfCancellationRequested();
                var row = Metadata(result, library).FirstOrDefault(item => Str(item, "type") == "movie" && Str(item, "ratingKey") == key);
                if (row == null) throw Problem("This movie is no longer available in the selected library.");
                var art = Str(row, "art");
                var duration = Num(row, "duration");
                var credits = Rows(Get(row, "Director")).Take(8).Select(person => new {
                    name = Str(person, "tag"), role = "Director", photo = RegisterVideoArt(server.Id, library, ArtworkPath(person, "thumb"))
                }).Concat(Rows(Get(row, "Role")).Take(24).Select(person => new {
                    name = Str(person, "tag"), role = Str(person, "role"), photo = RegisterVideoArt(server.Id, library, ArtworkPath(person, "thumb"))
                })).Where(person => person.name.Length > 0).ToArray();
                var formats = Rows(Get(row, "Media")).Take(8).Select(media => {
                    string resolution = MediaLabel(Str(media, "videoResolution"));
                    int pixels;
                    if (Int32.TryParse(resolution, out pixels)) resolution += "p";
                    return String.Join(" · ", new[] { resolution, MediaLabel(Str(media, "videoCodec")),
                        MediaLabel(Str(media, "audioCodec")), MediaLabel(Str(media, "container")) }.Where(value => value.Length > 0));
                }).Where(value => value.Length > 0).ToArray();
                Send("plexMovieDetails", new {
                    id, key, summary = String.Concat(Str(row, "summary").Take(8000)), year = Str(row, "year"),
                    minutes = duration > 0 && duration <= 259200000 ? duration / 60000 : 0,
                    classification = MediaLabel(Str(row, "contentRating")),
                    genres = Rows(Get(row, "Genre")).Take(12).Select(genre => Str(genre, "tag")).Where(value => value.Length > 0).ToArray(),
                    backdrop = art.Length < 180 && BackdropPath.IsMatch(art) ? RegisterVideoArt(server.Id, library, art) : "",
                    credits, formats
                });
            }
            catch (Exception error)
            {
                if (!job.IsCancellationRequested)
                    Send("plexMovieDetails", new { id, key, error = error is InvalidDataException
                        ? error.Message : "Plex couldn’t load the full movie details." });
            }
            finally
            {
                if (movieDetailsJob == job) movieDetailsJob = null;
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

        string RegisterVideoFallback(Server server, Uri basis, string path, int index, bool automaticSubtitles)
        {
            var query = VideoQuery(new Dictionary<string, string> {
                { "path", path }, { "protocol", "hls" }, { "directPlay", "0" }, { "directStream", "0" },
                { "mediaIndex", index.ToString(CultureInfo.InvariantCulture) }, { "session", Guid.NewGuid().ToString("N") },
                { "subtitles", automaticSubtitles ? "burn" : "none" }, { "videoQuality", "100" }, { "videoResolution", "1920x1080" },
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
                thumb, artwork = RegisterVideoArt(server.Id, library, thumb)
            };
        }

        void SendVideoWatchState(Server server, string library, long id)
        {
            var records = videoWatch.Records(server.Id, library).Select(value => {
                var row = Map(value);
                var path = Str(row, "artwork");
                row["thumb"] = path;
                row["artwork"] = path.Length < 180 && ArtPath.IsMatch(path) ? RegisterVideoArt(server.Id, library, path) : "";
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
