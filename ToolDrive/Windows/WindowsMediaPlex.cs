using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ToolDriveOffline
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
        sealed class PlexMatch
        {
            public string Id, Title;
            public int Version;
            public List<MediaTrack> Tracks;
        }
        sealed class Candidate
        {
            public string album, parentID, identity;
            public int version, disc, evidence;
            public MediaTrack track;
        }
        readonly Dictionary<string, Server> servers = new Dictionary<string, Server>();
        List<Section> sections = new List<Section>();
        readonly List<PlexMatch> matches = new List<PlexMatch>();
        Dictionary<string, string> plexPrefs;
        CancellationTokenSource plexJob;
        string account = "", selectedServer = "", selectedSection = "", plexMessage = "", phase = "",
               clientID = "";
        bool searching, loadingSections;
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
        string Pref(string k)
        {
            string v;
            return plexPrefs.TryGetValue(k, out v) ? v : "";
        }
        void ReadPlexSettings()
        {
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
            var savedClient = Pref("client");
            Guid id;
            if (Guid.TryParse(savedClient, out id)) clientID = savedClient;
            else if (clientID.Length == 0) clientID = Guid.NewGuid().ToString();

            string previousAccount = account;
            account = "";
            if (File.Exists(TokenFile))
            {
                try
                {
                    account = Encoding.UTF8.GetString(ProtectedData.Unprotect(
                        File.ReadAllBytes(TokenFile), null, DataProtectionScope.CurrentUser));
                }
                catch (CryptographicException)
                {
                    plexMessage = "Connect Plex again to authorize this Windows account.";
                }
            }
            if (account != previousAccount || selectedServer != Pref("server") ||
                selectedSection != Pref("toolDriveLibrary." + selectedServer))
            {
                selectedServer = selectedSection = "";
                servers.Clear();
                sections.Clear();
                matches.Clear();
            }
        }
        static bool ValidToken(string s)
        {
            return !String.IsNullOrEmpty(s) && s.Length <= 8192 && s.All(c => c >= 33 && c <= 126);
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
                                             : "Connect your Plex account to find original recordings.";
            Server server;
            servers.TryGetValue(selectedServer, out server);
            Send("macPlexState", new {
                status, message, searching, loadingLibraries = loadingSections, libraryMessage = "",
                serverId = selectedServer, serverName = server != null ? server.Name : "",
                libraryId = selectedSection,
                servers =
                    servers.Values.OrderBy(s => s.Name)
                        .Select(s => new { id = s.Id, name = s.Name, selected = s.Id == selectedServer })
                        .ToArray(),
                libraries =
                    sections.Select(s => new { s.id, s.name, selected = s.id == selectedSection }).ToArray(),
                matches =
                    matches
                        .Select(m => new { id = m.Id, title = m.Title,
                                           subtitle = m.Tracks.Count + " tracks · archive v" + m.Version,
                                           durationSeconds = m.Tracks.Sum(t => t.durationSeconds ?? 0) })
                        .ToArray()
            });
        }
        HttpRequestMessage PlexRequest(HttpMethod method, Uri uri, string token)
        {
            var req = new HttpRequestMessage(method, uri);
            req.Headers.Add("Accept", "application/json");
            req.Headers.Add("X-Plex-Product", "iPlex");
            req.Headers.Add("X-Plex-Version", typeof(WindowsMediaService).Assembly.GetName().Version.ToString(3));
            req.Headers.Add("X-Plex-Platform", "Windows");
            req.Headers.Add("X-Plex-Client-Identifier", clientID);
            req.Headers.Add("X-Plex-Device", "Windows");
            req.Headers.Add("X-Plex-Device-Name", "iPlex");
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
                previousServer.Length == 0 && servers.Count == 1 ? servers.Keys.Single() : "";
            sections.Clear();
            matches.Clear();
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
            var previous = Pref("toolDriveLibrary." + server.Id);
            selectedSection = list.Any(s => s.id == previous) ? previous : "";
            loadingSections = false;
            plexMessage = list.Count == 0         ? "No music libraries found on this server."
                          : selectedSection == "" ? "Choose a Tool Drive library in iPlex Settings."
                                                  : "Connected to your music library.";
            PlexState();
        }
        static IEnumerable<Dictionary<string, object>> Metadata(object result, string section)
        {
            var c = Map(Get(Map(result), "MediaContainer"));
            Func<Dictionary<string, object>, bool> belongs = r =>
                !r.ContainsKey("librarySectionID") || Str(r, "librarySectionID") == section;
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
        // Match dates as complete tokens, including the compact form in archive filenames.
        static readonly Regex DateMarker = new Regex(
            @"(?<![0-9])(?:((?:19|20)\d\d)[._/ -]?(0[1-9]|1[0-2])[._/ -]?(0[1-9]|[12]\d|3[01])" +
            @"|(0[1-9]|1[0-2])[._/ -](0[1-9]|[12]\d|3[01])[._/ -]((?:19|20)\d\d))(?![0-9])");
        static bool MatchesDate(string text, string date)
        {
            var matches = DateMarker.Matches(text).Cast<Match>();
            var dates = matches.Select(m => m.Groups[1].Success
                ? m.Groups[1].Value + "-" + m.Groups[2].Value + "-" + m.Groups[3].Value
                : m.Groups[6].Value + "-" + m.Groups[4].Value + "-" + m.Groups[5].Value).Distinct();
            return dates.SequenceEqual(new[] { date });
        }
        static readonly Regex VersionMarker =
            new Regex(@"(?<![A-Za-z0-9])(?:ver(?:sion)?\.?|v\.?)\s*(\d{1,3})(?![A-Za-z0-9])", RegexOptions.IgnoreCase);
        static readonly Regex ArchiveFile = new Regex(
            @"^tool(\d{4}-\d{2}-\d{2})\.v(\d{1,3})\.t(\d{1,3})\.[a-z0-9]{2,8}\z", RegexOptions.IgnoreCase);
        static readonly Regex DiscFolder = new Regex(@"^(?:cd|disc|disk)[ _.-]*\d+\z", RegexOptions.IgnoreCase);
        static readonly Regex NumericID = new Regex(@"^[0-9]{1,20}\z");

        static IEnumerable<Candidate> Candidates(IEnumerable<Dictionary<string, object>> rows, string date,
            int? version, bool automatic, bool unversioned, Dictionary<string, object> parent,
            Uri baseUri, string secret)
        {
            foreach (var row in rows.Where(r => Str(r, "type") == "track"))
            {
                string id = Str(row, "ratingKey"), albumId = Str(row, "parentRatingKey"),
                       album = Str(row, "parentTitle"), title = Str(row, "title");
                if (!NumericID.IsMatch(id) || String.IsNullOrWhiteSpace(title))
                    continue;
                string parentArtist = "";
                if (parent != null)
                {
                    if (albumId != "" && albumId != Str(parent, "ratingKey")) continue;
                    albumId = Str(parent, "ratingKey");
                    if (album == "") album = Str(parent, "title");
                    parentArtist = Str(parent, "parentTitle");
                }
                string[] artists = { Str(row, "grandparentTitle"), Str(row, "originalTitle"), Str(row, "artist"), parentArtist };
                bool toolArtist = artists.Any(a => a.Trim().Equals("TOOL", StringComparison.OrdinalIgnoreCase));
                foreach (var item in Rows(Get(row, "Media")).Take(16).SelectMany(media =>
                             Rows(Get(media, "Part")).Take(16).Select(part => new { media, part })))
                {
                    string key = Str(item.part, "key");
                    if (!PartPath(key)) continue;
                    string path = Str(item.part, "file").Replace('\\', '/');
                    string[] parts = path.Split('/');
                    string folderPath = String.Join("/", parts.Take(parts.Length - 1));
                    string folder = folderPath.Split('/').Last();
                    if (DiscFolder.IsMatch(folder))
                    {
                        folderPath = String.Join("/", parts.Take(Math.Max(0, parts.Length - 2)));
                        folder = folderPath.Split('/').Last();
                    }
                    string filename = path.Length > 0 ? parts.Last() : Uri.UnescapeDataString(key.Split('/').Last());
                    string extension = Path.GetExtension(filename);
                    if (String.IsNullOrEmpty(extension))
                        extension = "." + Str(item.media, "container");
                    string mime;
                    Types.TryGetValue(extension, out mime);
                    string labels = album + " " + folder;
                    bool tagged = toolArtist && MatchesDate(labels, date);
                    var versions = VersionMarker.Matches(labels).Cast<Match>()
                        .Select(m => Int32.Parse(m.Groups[1].Value)).Distinct().ToArray();
                    int matchedVersion, track, disc, evidence;
                    var canonical = ArchiveFile.Match(filename);
                    if (canonical.Success)
                    {
                        matchedVersion = Int32.Parse(canonical.Groups[2].Value);
                        track = Int32.Parse(canonical.Groups[3].Value);
                        bool archiveFolder = parts.Length >= 3 && parts[parts.Length - 3] == date.Substring(0, 4) &&
                            folder.Equals("tool" + date + ".v" + canonical.Groups[2].Value, StringComparison.OrdinalIgnoreCase);
                        if (canonical.Groups[1].Value != date || (!tagged && !archiveFolder) ||
                            (version.HasValue && matchedVersion != version.Value) ||
                            (automatic && versions.Any(v => v != matchedVersion))) continue;
                        evidence = 3;
                        disc = 1;
                    }
                    else
                    {
                        if (!automatic || !tagged || !version.HasValue || versions.Length > 1 ||
                            (versions.Length == 1 ? versions[0] != version.Value : !unversioned)) continue;
                        long number = Num(row, "index"), discNumber = Num(row, "parentIndex");
                        track = number >= 1 && number <= 999 ? (int)number : 0;
                        disc = discNumber >= 0 && discNumber <= 999 ? (int)Math.Max(1, discNumber) : 0;
                        evidence = versions.Length == 1 ? 2 : 1;
                        matchedVersion = version.Value;
                    }
                    if (!NumericID.IsMatch(albumId) && String.IsNullOrEmpty(folderPath)) continue;
                    string codec = Str(item.media, "audioCodec").ToLowerInvariant();
                    yield return new Candidate {
                        album = albumId + "|" + folderPath, parentID = albumId, identity = id, version = matchedVersion,
                        disc = disc, evidence = evidence,
                        track = new MediaTrack { number = track, title = title, mime = mime,
                            durationSeconds = Num(row, "duration") > 0 ? (double?)Num(row, "duration") / 1000 : null,
                            remote = new Uri(baseUri, key), token = secret,
                            directMp4 = mime == "audio/mp4" && new[] { "aac", "mp3", "flac", "opus" }.Contains(codec) }
                    };
                    break;
                }
            }
        }
        static PlexMatch Best(List<Candidate> candidates, string date, bool automatic)
        {
            var groups = candidates.GroupBy(c => new { c.album, c.version })
                .Select(g => g.GroupBy(c => new { c.identity, c.track.remote }).Select(tracks => tracks.First()).ToList())
                .OrderByDescending(g => g.Max(c => c.evidence)).ThenByDescending(g => g.Count)
                .ThenBy(g => g[0].version).ToList();
            if (groups.Count == 0) return null;
            var chosen = groups[0];
            if (automatic && groups.Skip(1).Any(g => g.Max(c => c.evidence) == chosen.Max(c => c.evidence)))
                throw Problem("More than one Plex album matches this recording. Check the concert date and source version in your music library.");
            if (chosen.Count > 250 || chosen.Any(c => c.disc < 1 || c.track.number < 1) ||
                chosen.Select(c => c.identity).Distinct().Count() != chosen.Count ||
                chosen.Select(c => new { c.disc, c.track.number }).Distinct().Count() != chosen.Count)
                throw Problem("Plex returned an incomplete or conflicting track list for this recording.");
            if (chosen.Any(c => c.track.mime == null))
                throw Problem("This Plex recording contains an unsupported audio format.");
            return new PlexMatch { Id = Guid.NewGuid().ToString("N"), Title = "TOOL " + date + " · v" + chosen[0].version,
                Version = chosen[0].version, Tracks = chosen.OrderBy(c => c.disc).ThenBy(c => c.track.number)
                                                             .Select(c => c.track).ToList() };
        }
        async Task<List<Dictionary<string, object>>> ReadPlexPages(Uri uri, string path, Server server,
            string section, CancellationToken token)
        {
            var items = new List<Dictionary<string, object>>();
            const int pageSize = 250;
            for (int offset = 0; offset < 20000;)
            {
                string paging = (path.Contains("?") ? "&" : "?") + "X-Plex-Container-Start=" + offset +
                                "&X-Plex-Container-Size=" + pageSize;
                var response = await FetchPlex(HttpMethod.Get, new Uri(uri, path + paging), server.Token,
                                               token, 8 * 1024 * 1024, 12);
                var container = Map(Get(Map(response), "MediaContainer"));
                if (container.ContainsKey("offset") && Num(container, "offset") != offset)
                    throw Problem("Plex returned an incomplete music library listing.");
                var rows = Metadata(response, section).ToList();
                items.AddRange(rows);
                int size = Rows(Get(container, "Metadata")).Count();
                offset += size;
                if (container.ContainsKey("totalSize") ? offset >= Num(container, "totalSize") : size < pageSize)
                    return items;
                if (size == 0) break;
            }
            throw Problem("Plex returned an incomplete music library listing.");
        }
        async Task<PlexMatch> FindPlex(string date, int? version, SourceRef source, CancellationToken token)
        {
            Server server;
            string section = selectedSection;
            if (!servers.TryGetValue(selectedServer, out server) || !sections.Any(s => s.id == section))
                throw Problem("Choose a Tool Drive library in iPlex Settings.");
            bool automatic = source != null;
            bool unversioned = automatic && sources.Values.Count(s => s.date == date) == 1;
            return await WithServer(server, async uri =>
            {
                string path = "/library/sections/" + section + "/all?";
                var albums = await ReadPlexPages(uri, path + "type=9&title=" + date.Substring(0, 4), server, section, token);
                var found = albums.Where(a => Str(a, "type") == "album" && MatchesDate(Str(a, "title"), date) &&
                                         NumericID.IsMatch(Str(a, "ratingKey"))).GroupBy(a => Str(a, "ratingKey")).ToList();
                var candidates = new List<Candidate>();
                foreach (var album in found)
                {
                    var rows = await ReadPlexPages(uri, "/library/metadata/" + album.Key + "/children", server, section, token);
                    candidates.AddRange(Candidates(rows, date, version, automatic, unversioned, album.First(), uri, server.Token));
                }
                // A dated but unversioned album can wait until the archive filename search is complete.
                var match = Best(candidates.Where(c => c.evidence > 1).ToList(), date, automatic);
                if (match != null) return match;
                var tracks = await ReadPlexPages(uri, path + "type=10&title=" + date, server, section, token);
                var hits = Candidates(tracks, date, version, automatic, unversioned, null, uri, server.Token).ToList();
                candidates.AddRange(hits);
                // A track title search may find just one song from an album.
                // Load its siblings before queuing the source.
                var extraAlbums = hits.Select(c => c.parentID).Where(id => NumericID.IsMatch(id)).Distinct().Except(found.Select(a => a.Key));
                foreach (string id in extraAlbums)
                {
                    var rows = await ReadPlexPages(uri, "/library/metadata/" + id + "/children", server, section, token);
                    candidates.AddRange(Candidates(rows, date, version, automatic, unversioned, null, uri, server.Token));
                }
                match = Best(candidates, date, automatic);
                if (match == null)
                    throw Problem("Plex did not find the exact TOOL recording for " + date +
                                  (version.HasValue ? " v" + version : "") + " in your selected music library.");
                return match;
            }, token);
        }
        async Task PlexAction(Dictionary<string, object> p, long request)
        {
            string action = Str(p, "action");
            if (action != "status" && action != "play" && action != "search" && action != "playMatch") return;
            ReadPlexSettings();
            if (plexJob != null)
                plexJob.Cancel();
            var job = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            plexJob = job;
            var token = job.Token;
            try
            {
                searching = false;
                loadingSections = false;
                phase = "";
                if (action == "status")
                {
                    if (account.Length > 0 && servers.Count == 0) await LoadServers(token);
                    else PlexState();
                }
                else if (action == "playMatch")
                {
                    var match = matches.FirstOrDefault(x => x.Id == Str(p, "matchId"));
                    if (match == null)
                        throw Problem("Search again to play this recording.");
                    Queue(request, match.Title, "plex", match.Tracks, 0);
                }
                else if (action == "play" || action == "search")
                {
                    if (account.Length == 0 || Pref("toolDriveLibrary." + Pref("server")).Length == 0)
                        throw Problem("Choose a Tool Drive library in iPlex Settings.");
                    if (servers.Count == 0) await LoadServers(token);
                    string date;
                    int? version;
                    SourceRef source = null;
                    if (action == "play")
                    {
                        source = Source(Num(p, "sourceId"), Num(p, "showId"));
                        if (sources.Values.Count(s => s.date == source.date && s.version == source.version) > 1)
                            throw Problem("Two archive recordings share this date and source version. Plex cannot distinguish them.");
                        date = source.date;
                        version = source.version;
                    }
                    else
                    {
                        string query = Str(p, "query").Trim();
                        if (query.Length < 1 || query.Length > 300)
                            throw Problem("Enter a date or venue.");
                        var dateMatch = Regex.Match(query, @"\d{4}-\d{2}-\d{2}");
                        date = dateMatch.Value;
                        if (!ValidDate(date))
                        {
                            RefreshCatalog();
                            var dates =
                                shows.Values
                                    .Where(s => String
                                                    .Join(" ", new[] { "venue", "city", "state", "country" }
                                                                   .Select(k => Str(s, k)))
                                                    .IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0)
                                    .Select(s => Str(s, "date"))
                                    .Distinct()
                                    .Take(2)
                                    .ToList();
                            date = dates.Count == 1 ? dates[0] : "";
                        }
                        if (!ValidDate(date))
                            throw Problem(
                                "Enter a show date (YYYY-MM-DD) or a venue that identifies one show.");
                        var v = Regex.Match(query, @"(?:\.v|\bv\.?|version\s*)(\d{1,3})",
                                            RegexOptions.IgnoreCase);
                        version = v.Success ? (int?)Int32.Parse(v.Groups[1].Value) : null;
                    }
                    searching = true;
                    plexMessage = "Searching your Plex music library…";
                    PlexState();
                    var match = await FindPlex(date, version, source, token);
                    token.ThrowIfCancellationRequested();
                    if (action == "play" && request != latestRequest)
                    {
                        searching = false;
                        plexMessage = "";
                        PlexState();
                        return;
                    }
                    matches.Insert(0, match);
                    if (matches.Count > 20)
                        matches.RemoveAt(20);
                    searching = false;
                    plexMessage = "Found the exact archive recording.";
                    PlexState();
                    if (action == "play")
                        Queue(request, source.Title, "plex", match.Tracks, 0);
                }
            }
            catch (OperationCanceledException)
            {
                if (!job.IsCancellationRequested)
                    throw;
                if (request != 0 && request == latestRequest)
                    Send("windowsMediaReply", new { request, error = "Plex playback was canceled." });
            }
            catch (Exception)
            {
                if (job.IsCancellationRequested)
                    return;
                phase = "error";
                loadingSections = searching = false;
                throw;
            }
            finally
            {
                if (plexJob == job)
                    plexJob = null;
                job.Dispose();
            }
        }
    }
}
