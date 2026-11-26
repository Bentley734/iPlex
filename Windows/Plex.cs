using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace MusicRoom
{
    internal sealed partial class WindowsMediaService
    {
        sealed class Server
        {
            public string Id, Name, Token;
            public List<Uri> Bases;
            public Uri Working;
        }
        sealed class Section
        {
            public string id { get; set; }
            public string name { get; set; }
        }
        readonly Dictionary<string, Server> servers = new Dictionary<string, Server>();
        List<Section> sections = new List<Section>();
        Dictionary<string, string> plexPrefs;
        CancellationTokenSource plexJob;
        string account = "", selectedServer = "", selectedSection = "", plexMessage = "", phase = "",
               clientID = "";
        bool initialized, loadingSections;
        bool sessionOnly;
        const string PlexProduct = "iPlex";
        string TokenFile
        {
            get {
                return Path.Combine(root, "plex-account.bin");
            }
        }
        string PrefFile
        {
            get {
                return Path.Combine(root, "plex-preferences.json");
            }
        }
        static void Atomic(string path, byte[] bytes)
        {
            var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temp, bytes);
                if (File.Exists(path))
                    File.Replace(temp, path, null);
                else
                    File.Move(temp, path);
            }
            finally
            {
                if (File.Exists(temp))
                    File.Delete(temp);
            }
        }
        void SavePrefs()
        {
            Atomic(PrefFile, Encoding.UTF8.GetBytes(Json().Serialize(plexPrefs)));
        }
        string Pref(string k)
        {
            string v;
            return plexPrefs.TryGetValue(k, out v) ? v : "";
        }
        void InitPlex()
        {
            if (initialized)
                return;
            plexPrefs = new Dictionary<string, string>();
            if (File.Exists(PrefFile))
            {
                try
                {
                    plexPrefs = Json().Deserialize<Dictionary<string, string>>(File.ReadAllText(PrefFile)) ??
                                plexPrefs;
                }
                catch (ArgumentException)
                {
                }
                catch (InvalidOperationException)
                {
                }
            }
            clientID = Pref("client");
            Guid id;
            if (!Guid.TryParse(clientID, out id))
            {
                clientID = Guid.NewGuid().ToString();
                plexPrefs["client"] = clientID;
                SavePrefs();
            }
            if (File.Exists(TokenFile))
            {
                try
                {
                    account = Encoding.UTF8.GetString(ProtectedData.Unprotect(
                        File.ReadAllBytes(TokenFile), null, DataProtectionScope.CurrentUser));
                }
                catch (Exception error)
                {
                    if (!CredentialStorageUnavailable(error)) throw;
                    plexMessage = "Connect Plex again to authorize this Windows account.";
                }
            }
            initialized = true;
        }
        static bool ValidToken(string s)
        {
            return !String.IsNullOrEmpty(s) && s.Length <= 8192 && s.All(c => c >= 33 && c <= 126);
        }
        static bool CredentialStorageUnavailable(Exception error)
        {
            return error is CryptographicException || error is IOException || error is UnauthorizedAccessException ||
                   error is PlatformNotSupportedException;
        }
        void PlexState()
        {
            string status = phase == "connecting" ? "connecting"
                            : account.Length > 0  ? "connected"
                            : phase == "error"    ? "error"
                                                  : "disconnected";
            string message = plexMessage;
            if (String.IsNullOrEmpty(message))
                message = account.Length > 0 ? "Connected to Plex."
                                             : "Connect to your Plex music library.";
            if (sessionOnly && account.Length > 0)
                message += " Windows could not save this sign-in. It will last until iPlex closes.";
            Server server;
            servers.TryGetValue(selectedServer, out server);
            Send("macPlexState", new {
                status, message, loadingLibraries = loadingSections, libraryMessage = "",
                refreshAvailable = status == "connected" && phase != "loading" && !loadingSections && selectedSection.Length == 0,
                serverId = selectedServer, serverName = server != null ? server.Name : "",
                libraryId = selectedSection,
                servers =
                    servers.Values.OrderBy(s => s.Name)
                        .Select(s => new { id = s.Id, name = s.Name, selected = s.Id == selectedServer })
                        .ToArray(),
                libraries =
                    sections.Select(s => new { s.id, s.name, selected = s.id == selectedSection }).ToArray()
            });
        }
        HttpRequestMessage PlexRequest(HttpMethod method, Uri uri, string token)
        {
            var req = new HttpRequestMessage(method, uri);
            req.Headers.Add("Accept", "application/json");
            req.Headers.Add("X-Plex-Product", PlexProduct);
            req.Headers.Add("X-Plex-Version", typeof(WindowsMediaService).Assembly.GetName().Version.ToString(3));
            req.Headers.Add("X-Plex-Platform", "Windows");
            req.Headers.Add("X-Plex-Client-Identifier", clientID);
            req.Headers.Add("X-Plex-Device", "Windows");
            req.Headers.Add("X-Plex-Device-Name", PlexProduct);
            if (uri.Host == "plex.tv" && uri.AbsolutePath.StartsWith("/api/v2/pins", StringComparison.Ordinal))
                req.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
            if (!String.IsNullOrEmpty(token))
                req.Headers.Add("X-Plex-Token", token);
            return req;
        }
        async Task<object> FetchPlex(HttpMethod method, Uri url, string token, CancellationToken ct,
                                     int max = 2 * 1024 * 1024, int seconds = 18)
        {
            var text = await TextAsync(PlexRequest(method, url, token), max, ct, seconds);
            ct.ThrowIfCancellationRequested();
            return Json().DeserializeObject(text);
        }
        async Task Authorize(CancellationToken token)
        {
            phase = "connecting";
            plexMessage = "Complete sign-in in your browser.";
            PlexState();
            var pin = Map(await FetchPlex(HttpMethod.Post, new Uri("https://plex.tv/api/v2/pins?strong=true"),
                                          null, token));
            long id = Num(pin, "id");
            string code = Str(pin, "code");
            if (id <= 0 || !Regex.IsMatch(code, @"^[a-zA-Z0-9_-]{1,200}\z"))
                throw Problem("Plex returned an invalid sign-in code.");
            OpenSignIn("https://app.plex.tv/auth#?clientID=" + Uri.EscapeDataString(clientID) +
                       "&code=" + Uri.EscapeDataString(code) +
                       "&context%5Bdevice%5D%5Bproduct%5D=" + Uri.EscapeDataString(PlexProduct));
            long lifetime = Num(pin, "expiresIn");
            DateTime expires = DateTime.UtcNow.AddSeconds(lifetime > 0 ? Math.Min(lifetime, 900) : 300);
            var address = new Uri("https://plex.tv/api/v2/pins/" + id.ToString(CultureInfo.InvariantCulture));
            while (DateTime.UtcNow < expires)
            {
                await Task.Delay(2000, token);
                Dictionary<string, object> result;
                try
                {
                    result = Map(await FetchPlex(HttpMethod.Get, address, null, token, 256 * 1024, 10));
                }
                catch (OperationCanceledException)
                {
                    token.ThrowIfCancellationRequested();
                    plexMessage = "Plex took too long to reply. Retrying sign-in…";
                    PlexState();
                    continue;
                }
                catch (HttpRequestException)
                {
                    plexMessage = "Could not check the Plex link. Retrying…";
                    PlexState();
                    continue;
                }
                catch (InvalidDataException error)
                {
                    if (error.Message == "The service returned HTTP 404." ||
                        error.Message == "The service returned HTTP 410.") break;
                    throw;
                }
                if (Num(result, "id") != id)
                    throw Problem("Plex returned an unrelated sign-in response. Choose Connect Plex to try again.");
                var secret = Str(result, "authToken");
                if (String.IsNullOrEmpty(secret))
                {
                    if (Get(result, "expiresIn") != null && Num(result, "expiresIn") <= 0) break;
                    plexMessage = "Finish linking in your browser. iPlex checks for approval automatically.";
                    PlexState();
                    continue;
                }
                if (!ValidToken(secret))
                    throw Problem("Plex returned an invalid credential.");
                token.ThrowIfCancellationRequested();
                sessionOnly = false;
                try
                {
                    Atomic(TokenFile, ProtectedData.Protect(Encoding.UTF8.GetBytes(secret), null,
                                                            DataProtectionScope.CurrentUser));
                }
                catch (Exception error)
                {
                    if (!CredentialStorageUnavailable(error)) throw;
                    sessionOnly = true;
                }
                account = secret;
                await LoadServers(token);
                return;
            }
            throw Problem("The Plex sign-in request expired. Choose Connect to retry.");
        }
        static Uri SecureBase(string raw)
        {
            Uri uri;
            if (raw.Length > 2048 || !Uri.TryCreate(raw, UriKind.Absolute, out uri) ||
                uri.Scheme != "https" ||
                !(uri.Host.Equals("plex.direct", StringComparison.OrdinalIgnoreCase) ||
                  uri.Host.EndsWith(".plex.direct", StringComparison.OrdinalIgnoreCase)) ||
                uri.UserInfo != "" || uri.AbsolutePath != "/" || uri.Query != "" || uri.Fragment != "")
                return null;
            return uri;
        }
        async Task LoadServers(CancellationToken token)
        {
            if (!ValidToken(account))
                throw Problem("Connect Plex first.");
            phase = "loading";
            plexMessage = "Finding Plex servers…";
            PlexState();
            var entries = Rows(await FetchPlex(
                HttpMethod.Get,
                new Uri(
                    "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1"),
                account, token));
            var fresh = new Dictionary<string, Server>();
            foreach (var row in entries.Take(100))
            {
                string id = Str(row, "clientIdentifier"), secret = Str(row, "accessToken");
                if (!Str(row, "provides").Split(',').Any(x => x.Trim() == "server") || !ValidToken(secret) ||
                    !Regex.IsMatch(id, @"^[A-Za-z0-9._-]{1,200}\z"))
                    continue;
                var uris = Rows(Get(row, "connections"))
                               .Take(32)
                               .OrderBy(r => Object.Equals(Get(r, "relay"), true)   ? 2
                                             : Object.Equals(Get(r, "local"), true) ? 0
                                                                                    : 1)
                               .Select(r => SecureBase(Str(r, "uri")))
                               .Where(u => u != null)
                               .Distinct()
                               .ToList();
                if (uris.Count > 0)
                    fresh[id] = new Server { Id = id, Name = Str(row, "name"), Token = secret, Bases = uris };
            }
            token.ThrowIfCancellationRequested();
            servers.Clear();
            foreach (var kv in fresh)
                servers[kv.Key] = kv.Value;
            string previousServer = Pref("server");
            selectedServer = servers.ContainsKey(previousServer) ? previousServer :
                servers.Count == 1 ? servers.Keys.Single() : "";
            sections.Clear();
            selectedSection = "";
            phase = "";
            if (selectedServer.Length == 0)
            {
                plexMessage = servers.Count == 0 ? "No secure Plex Media Server is available for this account."
                                                  : "Choose a Plex server.";
                PlexState();
                return;
            }
            await LoadSections(token);
        }
        async Task<T> WithServer<T>(Server server, Func<Uri, Task<T>> attempt, CancellationToken token)
        {
            foreach (Uri uri in server.Bases.OrderBy(b => b == server.Working ? 0 : 1))
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    var value = await attempt(uri);
                    token.ThrowIfCancellationRequested();
                    server.Working = uri;
                    return value;
                }
                catch (HttpRequestException)
                {
                }
                catch (OperationCanceledException)
                {
                    token.ThrowIfCancellationRequested();
                }
                catch (InvalidDataException e)
                {
                    if (!e.Message.StartsWith("The service returned HTTP ", StringComparison.Ordinal))
                        throw;
                }
            }
            throw Problem("Could not reach the selected Plex server over a secure connection.");
        }
        async Task LoadSections(CancellationToken token)
        {
            Server server;
            if (!servers.TryGetValue(selectedServer, out server))
                throw Problem("Choose a Plex server first.");
            loadingSections = true;
            plexMessage = "Finding music libraries…";
            PlexState();
            var list = await WithServer(
                server,
                async uri =>
                {
                    var container =
                        Map(Get(Map(await FetchPlex(HttpMethod.Get, new Uri(uri, "/library/sections"),
                                                    server.Token, token, 2 * 1024 * 1024, 8)),
                                "MediaContainer"));
                    return Rows(Get(container, "Directory"))
                        .Where(r => Str(r, "type") == "artist" &&
                                    Regex.IsMatch(Str(r, "key"), @"^[1-9]\d{0,18}\z"))
                        .Select(r => new Section { id = Str(r, "key"), name = Str(r, "title") })
                        .OrderBy(s => s.name)
                        .ToList();
                },
                token);
            token.ThrowIfCancellationRequested();
            sections = list;
            var previous = Pref("library." + server.Id);
            selectedSection = list.Any(s => s.id == previous) ? previous :
                list.Count == 1 ? list[0].id : "";
            loadingSections = false;
            plexMessage = list.Count == 0         ? "No music libraries found on this server."
                          : selectedSection == "" ? "Choose a music library."
                                                  : "Connected to your music library.";
            PlexState();
        }
        static IEnumerable<Dictionary<string, object>> Metadata(object result, string section)
        {
            var c = Map(Get(Map(result), "MediaContainer"));
            Func<Dictionary<string, object>, bool> belongs = r =>
                section == null || !r.ContainsKey("librarySectionID") || Str(r, "librarySectionID") == section;
            if (!belongs(c))
                return Enumerable.Empty<Dictionary<string, object>>();
            return Rows(Get(c, "Metadata"))
                .Concat(Rows(Get(c, "Hub")).Where(belongs).SelectMany(h => Rows(Get(h, "Metadata"))))
                .Where(belongs)
                .Take(2000);
        }
        static bool PartPath(string key)
        {
            if (String.IsNullOrEmpty(key) || key.Length > 2048 ||
                !Regex.IsMatch(key, @"^/library/parts/[0-9]{1,20}/") ||
                key.IndexOfAny(new[] { '\\', '?', '#' }) >= 0)
                return false;
            string d = Uri.UnescapeDataString(key);
            return !d.Contains("\\") && !d.Contains("//") && !d.Contains("%") &&
                   !d.Split('/').Any(x => x == "." || x == "..");
        }
        static readonly Regex ItemID = new Regex(@"^[1-9][0-9]{0,19}\z");
        static readonly Regex ArtPath = new Regex(@"^(?:/library/metadata/[0-9]+/thumb|/playlists/[0-9]+/composite)(?:/[0-9]+)?\z");
        sealed class LibraryItem
        {
            internal string Kind, Title;
        }
        readonly Dictionary<string, LibraryItem> items = new Dictionary<string, LibraryItem>();
        readonly Dictionary<string, string> art = new Dictionary<string, string>();
        readonly Dictionary<string, string> artIDs = new Dictionary<string, string>();
        readonly SemaphoreSlim artSlots = new SemaphoreSlim(4);
        List<MediaTrack> albumTracks = new List<MediaTrack>();
        string albumID = "", albumTitle = "";

        void ClearMusic()
        {
            StopCoverCache(false);
            items.Clear();
            art.Clear();
            artIDs.Clear();
            albumID = "";
            albumTracks.Clear();
            ReleaseHandles();
        }

        async Task Browse(Dictionary<string, object> request, long id, CancellationToken token)
        {
            Server server;
            if (!servers.TryGetValue(selectedServer, out server) || selectedSection.Length == 0)
                throw Problem("Choose a Plex music library.");
            string category = Str(request, "kind");
            string type, expected;
            switch (category)
            {
                case "artists": type = "8"; expected = "artist"; break;
                case "tracks": type = "10"; expected = "track"; break;
                case "playlists": type = "15"; expected = "playlist"; break;
                case "genres": type = "9"; expected = "genre"; break;
                default: type = "9"; expected = "album"; break;
            }
            long start = Math.Min(Math.Max(0, Num(request, "offset")), 1000000);
            long requestedSize = Num(request, "pageSize");
            int size = requestedSize == 30 || requestedSize == 120 ? (int)requestedSize : 60;
            string group = Str(request, "group");
            string query = Str(request, "query").Trim();
            string section = selectedSection;
            string sectionPath = "/library/sections/" + section;
            bool localPaging = false;
            string endpoint;
            if (group.Length != 0)
            {
                LibraryItem record;
                if (!items.TryGetValue(group, out record) || (record.Kind != "artist" && record.Kind != "genre"))
                    throw Problem("Choose a genre or artist from the library.");
                expected = "album";
                endpoint = record.Kind == "artist" ? "/library/metadata/" + group + "/children?" :
                    sectionPath + "/all?type=9&sort=titleSort%3Aasc&genre=" + group.Substring("genre:".Length);
            }
            else if (category == "genres" || category == "playlists")
            {
                localPaging = true;
                endpoint = category == "genres" ? sectionPath + "/genre?type=9" :
                    "/playlists?type=15&playlistType=audio&sectionID=" + section;
            }
            else
            {
                endpoint = sectionPath + "/all?type=" + type + "&sort=titleSort%3Aasc";
                if (!String.IsNullOrEmpty(query))
                    endpoint += "&title=" + Uri.EscapeDataString(query.Substring(0, Math.Min(query.Length, 120)));
            }
            if (!localPaging) endpoint += "&X-Plex-Container-Start=" + start + "&X-Plex-Container-Size=" + size;
            var payload = await WithServer(server, url =>
                FetchPlex(HttpMethod.Get, new Uri(url, endpoint), server.Token, token, 8 * 1024 * 1024), token);
            token.ThrowIfCancellationRequested();
            var container = Map(Get(Map(payload), "MediaContainer"));
            var rows = (expected == "genre" ? Rows(Get(container, "Directory")) :
                Metadata(payload, expected == "playlist" ? null : section)).ToArray();
            long total = Num(container, "totalSize");
            var results = new List<object>();
            var seen = new HashSet<string>();
            int matches = 0;
            if (localPaging) rows = rows.OrderBy(row => Str(row, "title"), StringComparer.CurrentCultureIgnoreCase).ToArray();
            foreach (var row in rows)
            {
                string key = Str(row, "ratingKey");
                string title = Str(row, "title");
                string kind = Str(row, "type");
                if (expected == "genre")
                {
                    kind = expected;
                    key = Str(row, "key");
                    var path = Regex.Match(key, "^" + sectionPath + @"/all\?(?:[^&]+&)*genre=([0-9]+)(?:&|$)");
                    if (path.Success) key = path.Groups[1].Value;
                }
                if (!ItemID.IsMatch(key) || title.Length == 0 || title.Length > 300 || kind != expected ||
                    (kind == "playlist" && Str(row, "playlistType") != "audio") || !seen.Add(key)) continue;
                if (localPaging)
                {
                    if (title.IndexOf(query, StringComparison.CurrentCultureIgnoreCase) < 0) continue;
                    int position = matches++;
                    if (position < start || results.Count >= size) continue;
                }
                if (kind == "genre") key = "genre:" + key;
                items[key] = new LibraryItem { Kind = kind, Title = title };
                string artwork = RegisterArtwork(ArtworkPath(row, "thumb", "parentThumb", "composite"));
                results.Add(new { id = key, title, kind, artwork, artist = Str(row, kind == "track" ? "grandparentTitle" : "parentTitle"), year = Num(row, "year"),
                    genre = Rows(Get(row, "Genre")).Select(genre => Str(genre, "tag")).FirstOrDefault() ?? "" });
            }
            long next = start + (localPaging ? results.Count : rows.Length);
            bool more = results.Count > 0 && next <= 1000000 &&
                (localPaging ? next < matches : total > 0 ? next < total : rows.Length >= size);
            Send("musicEntries", new { id, entries = results, next, more });
        }

        static string ArtworkPath(Dictionary<string, object> row, params string[] fields)
        {
            return fields.Select(field => Str(row, field))
                .FirstOrDefault(value => value.Length < 180 && ArtPath.IsMatch(value));
        }

        string RegisterArtwork(string thumb)
        {
            if (thumb == null) return "";
            string handle;
            if (!artIDs.TryGetValue(thumb, out handle))
            {
                handle = Guid.NewGuid().ToString("N");
                art[handle] = thumb;
                artIDs[thumb] = handle;
            }
            return "/art/" + handle;
        }

        public async Task<WindowsMediaResponse> Artwork(string handle, string method)
        {
            Server server;
            string relative;
            if ((method != "GET" && method != "HEAD") || !Regex.IsMatch(handle, @"^[a-f0-9]{32}\z") ||
                !servers.TryGetValue(selectedServer, out server) || !art.TryGetValue(handle, out relative))
                return Response(404, "Not Found");
            var target = CoverCachePath(server.Id, selectedSection, relative);
            await artSlots.WaitAsync(shutdown.Token);
            try
            {
                // Retain the server that issued the art ticket for the whole request.
                var bytes = File.Exists(target) ? File.ReadAllBytes(target) :
                    await FetchArtwork(server, relative, shutdown.Token);
                string mime = bytes.Length >= 8 && bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71
                    ? "image/png" : bytes.Length > 2 && bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255
                    ? "image/jpeg" : bytes.Length >= 12 && Encoding.ASCII.GetString(bytes, 0, 4) == "RIFF" &&
                        Encoding.ASCII.GetString(bytes, 8, 4) == "WEBP" ? "image/webp" : null;
                return mime == null ? Response(415, "Unsupported image") :
                    Response(200, "OK", "Content-Type: " + mime + "\r\n", method == "HEAD" ? null : new MemoryStream(bytes, false));
            }
            catch (Exception) { return Response(503, "Artwork unavailable"); }
            finally { artSlots.Release(); }
        }

        static readonly Dictionary<string, string> Mime = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
            {".mp3","audio/mpeg"}, {".flac","audio/flac"}, {".wav","audio/wav"}, {".wave","audio/wav"},
            {".aac","audio/aac"}, {".m4a","audio/mp4"}, {".mp4","audio/mp4"}, {".alac","audio/alac"},
            {".aif","audio/aiff"}, {".aiff","audio/aiff"}, {".caf","audio/x-caf"}
        };

        async Task Album(Dictionary<string, object> request, long id, CancellationToken token)
        {
            string key = Str(request, "album");
            Server server;
            LibraryItem item;
            if (!ItemID.IsMatch(key) || !items.TryGetValue(key, out item) ||
                (item.Kind != "album" && item.Kind != "playlist" && item.Kind != "track") ||
                !servers.TryGetValue(selectedServer, out server) || selectedSection.Length == 0)
                throw Problem("Choose an album, playlist, or track from the library.");
            string section = selectedSection;
            bool playlist = item.Kind == "playlist";
            bool album = item.Kind == "album";
            string path = playlist ? "/playlists/" + key + "/items" :
                "/library/metadata/" + key + (album ? "/children" : "");
            var tracks = await WithServer(server, async url =>
            {
                const int batch = 200, playlistLimit = 10000;
                int start = 0;
                var found = new List<MediaTrack>();
                var seen = new HashSet<string>();
                bool more;
                do
                {
                    string endpoint = playlist ? path + "?X-Plex-Container-Start=" + start + "&X-Plex-Container-Size=" + batch : path;
                    var payload = await FetchPlex(HttpMethod.Get, new Uri(url, endpoint), server.Token, token, 8 * 1024 * 1024);
                    var rows = Metadata(payload, playlist ? null : section).ToArray();
                    var ordered = album ? rows.OrderBy(row => Num(row, "parentIndex")).ThenBy(row => Num(row, "index")) :
                        (IEnumerable<Dictionary<string, object>>)rows;
                    foreach (var row in ordered)
                    {
                        if (album && found.Count >= 250) break;
                        string trackKey = Str(row, "ratingKey");
                        if (Str(row, "type") != "track" || !ItemID.IsMatch(trackKey) ||
                            (album && row.ContainsKey("parentRatingKey") && Str(row, "parentRatingKey") != key) ||
                            (!album && !playlist && trackKey != key) || (!playlist && !seen.Add(trackKey))) continue;
                        var parts = Rows(Get(row, "Media")).Take(16).SelectMany(media => Rows(Get(media, "Part")).Take(16));
                        foreach (var part in parts)
                        {
                            string partPath = Str(part, "key"), mime;
                            if (!PartPath(partPath) || !Mime.TryGetValue(Path.GetExtension(partPath), out mime)) continue;
                            long duration = Num(row, "duration");
                            found.Add(new MediaTrack { number = found.Count + 1, title = Str(row, "title"),
                                durationSeconds = duration > 0 ? (double?)duration / 1000 : null,
                                artwork = ArtworkPath(row, "parentThumb", "thumb"),
                                artist = Str(row, "grandparentTitle"), album = Str(row, "parentTitle"),
                                remote = new Uri(url, partPath), token = server.Token, mime = mime,
                                directMp4 = Str(part, "audioCodec") == "aac" || Str(row, "audioCodec") == "aac" });
                            break;
                        }
                    }
                    start += rows.Length;
                    long total = Num(Map(Get(Map(payload), "MediaContainer")), "totalSize");
                    more = playlist && rows.Length > 0 && (total > 0 ? start < total : rows.Length >= batch);
                    if (playlist && (start > playlistLimit || (more && start >= playlistLimit)))
                        throw Problem("This playlist exceeds the 10,000-track playback limit.");
                } while (more);
                return found;
            }, token);
            token.ThrowIfCancellationRequested();
            albumID = key;
            albumTitle = item.Title;
            albumTracks = tracks;
            Send("musicAlbum", new { id, tracks = tracks.Select(track => new { track.number, track.title, track.durationSeconds }).ToArray() });
        }

        void PlayAlbum(Dictionary<string, object> body, long id)
        {
            long index = Num(body, "index");
            if (Str(body, "album") != albumID || index < 0 || index >= albumTracks.Count)
                throw Problem("Open the library item before playing it.");
            var entries = new List<object>();
            lock (handles)
            {
                ReleaseHandles();
                foreach (var track in albumTracks)
                {
                    string handle = Guid.NewGuid().ToString("N");
                    handles.Add(handle, track);
                    entries.Add(new { track.title, track.durationSeconds, track.artist, track.album,
                        artwork = RegisterArtwork(track.artwork), url = "https://media.musicroom.invalid/" + handle });
                }
            }
            Send("musicQueue", new { id, context = albumTitle, origin = "plex", startIndex = index, tracks = entries });
        }

        public async Task Handle(Dictionary<string, object> body)
        {
            string action = Str(body, "action");
            long id = Num(body, "id");
            if (action == "cacheCovers") { await CacheLibraryArtwork(); return; }
            if (action == "stopCoverCache") { StopCoverCache(true); return; }
            if (action == "beginTrack" || action == "seekTrack")
            {
                PlaybackPosition(action, Str(body, "handle"));
                return;
            }
            if (action == "release") { ReleaseHandles(); return; }
            if (action == "cancel")
            {
                if (plexJob != null) plexJob.Cancel();
                phase = "";
                plexMessage = "Plex sign-in canceled.";
                PlexState();
                return;
            }
            bool first = !initialized;
            InitPlex();
            if (action == "status" && !(first && account.Length > 0)) { PlexState(); return; }
            if (plexJob != null) plexJob.Cancel();
            var job = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            plexJob = job;
            var token = job.Token;
            try
            {
                if (action == "connect") await Authorize(token);
                else if (action == "status" || action == "servers") await LoadServers(token);
                else if (action == "browse") await Browse(body, id, token);
                else if (action == "album") await Album(body, id, token);
                else if (action == "play") PlayAlbum(body, id);
                else if (action == "selectServer")
                {
                    string server = Str(body, "server");
                    if (!servers.ContainsKey(server)) throw Problem("Select a Plex server from the list.");
                    ClearMusic();
                    selectedServer = server;
                    selectedSection = "";
                    sections.Clear();
                    plexPrefs["server"] = server;
                    SavePrefs();
                    await LoadSections(token);
                }
                else if (action == "selectLibrary")
                {
                    string library = Str(body, "library");
                    if (!sections.Any(section => section.id == library)) throw Problem("Select a music library from the list.");
                    ClearMusic();
                    selectedSection = library;
                    plexPrefs["library." + selectedServer] = library;
                    SavePrefs();
                    PlexState();
                }
                else if (action == "disconnect")
                {
                    ClearMusic();
                    if (File.Exists(TokenFile)) File.Delete(TokenFile);
                    account = selectedServer = selectedSection = plexMessage = phase = "";
                    sessionOnly = false;
                    servers.Clear();
                    sections.Clear();
                    PlexState();
                }
            }
            catch (OperationCanceledException)
            {
                if (!token.IsCancellationRequested)
                    ReportPlexError(action, id, "Plex did not respond in time. Try again.");
            }
            catch (Exception error)
            {
                if (token.IsCancellationRequested) return;
                string message = error is InvalidDataException ? error.Message : "Couldn’t reach Plex. Check your connection and try again.";
                ReportPlexError(action, id, message);
            }
            finally
            {
                if (plexJob == job) plexJob = null;
                job.Dispose();
            }
        }

        void ReportPlexError(string action, long id, string message)
        {
            if (action == "browse" || action == "album" || action == "play") Send("musicError", new { id, message });
            else { phase = "error"; plexMessage = message; loadingSections = false; PlexState(); }
        }
    }
}
