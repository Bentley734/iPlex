using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace MusicRoom
{
    internal sealed partial class WindowsMediaService
    {
        CancellationTokenSource globalSearchJob;
        ToolDriveOffline.Catalog searchCatalog;

        sealed class SearchGroup
        {
            public string kind { get; set; }
            public object[] rows { get; set; }
            internal bool Failed;
        }

        async Task GlobalSearch(Dictionary<string, object> request, long id)
        {
            if (globalSearchJob != null) globalSearchJob.Cancel();
            string term = String.Concat(Str(request, "query").Trim().Take(120));
            string person = Str(request, "person");
            bool byPerson = ItemID.IsMatch(person);
            if (!byPerson && term.Length == 0) return;

            var job = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            globalSearchJob = job;
            try
            {
                var groups = new List<SearchGroup>();
                if (!byPerson)
                {
                    if (searchCatalog == null)
                    {
                        string warning;
                        searchCatalog = ToolDriveOffline.CatalogCache.Load(out warning);
                    }
                    var shows = searchCatalog.Filter(new ToolDriveOffline.FilterOptions { Search = term }, new HashSet<string>());
                    groups.Add(new SearchGroup { kind = "toolDrive", rows = shows.Take(12).Select(match => (object)new {
                        id = match.Show.id, title = match.Show.venue, subtitle = match.Show.date
                    }).ToArray() });
                    groups.Add(new SearchGroup { kind = "downloads", rows = OfflineItems().Where(item =>
                        (item.title + " " + item.detail).IndexOf(term, StringComparison.CurrentCultureIgnoreCase) >= 0)
                        .Take(12).Select(item => (object)new { item.id, item.title, subtitle = item.detail, item.kind }).ToArray() });
                }

                Server server;
                if (servers.TryGetValue(selectedServer, out server))
                {
                    var work = new List<Task<SearchGroup>>();
                    var movies = Str(request, "movies");
                    var shows = Str(request, "shows");
                    string filter = byPerson ? (Str(request, "credit") == "Director" ? "&director=" : "&actor=") + person :
                        "&title=" + Uri.EscapeDataString(term);
                    if (videoSections.Any(section => section.id == movies && section.type == "movie"))
                        work.Add(SearchPlexSection(server, movies, "movie", "1", filter, job.Token));
                    if (videoSections.Any(section => section.id == shows && section.type == "show"))
                    {
                        work.Add(SearchPlexSection(server, shows, "show", "2", filter, job.Token));
                        if (!byPerson) work.Add(SearchPlexSection(server, shows, "episode", "4", filter, job.Token));
                    }
                    if (!byPerson && ItemID.IsMatch(selectedSection))
                    {
                        work.Add(SearchPlexSection(server, selectedSection, "album", "9", filter, job.Token));
                        work.Add(SearchPlexSection(server, selectedSection, "track", "10", filter, job.Token));
                    }
                    groups.InsertRange(0, await Task.WhenAll(work));
                }
                if (!job.IsCancellationRequested)
                    Send("plexGlobalSearch", new { id, groups = groups.Where(group => group.rows.Length > 0).ToArray(),
                        failed = groups.Any(group => group.Failed) });
            }
            catch (Exception)
            {
                if (!job.IsCancellationRequested) Send("plexGlobalSearch", new { id, failed = true });
            }
            finally
            {
                if (globalSearchJob == job) globalSearchJob = null;
                job.Dispose();
            }
        }

        async Task<SearchGroup> SearchPlexSection(Server server, string section, string kind, string type, string filter,
            CancellationToken token)
        {
            var group = new SearchGroup { kind = kind, rows = new object[0] };
            if (!ItemID.IsMatch(section)) return group;
            try
            {
                string path = "/library/sections/" + section + "/all?type=" + type + filter +
                    "&X-Plex-Container-Start=0&X-Plex-Container-Size=15";
                var payload = await WithServer(server, url => FetchPlex(HttpMethod.Get, new Uri(url, path),
                    server.Token, token, 8 * 1024 * 1024), token);
                token.ThrowIfCancellationRequested();
                var rows = new List<object>();
                foreach (var row in Metadata(payload, section).Where(row => Str(row, "type") == kind).Take(15))
                {
                    string key = Str(row, "ratingKey"), title = Str(row, "title");
                    if (!ItemID.IsMatch(key) || title.Length == 0 || title.Length > 400) continue;
                    string thumb = ArtworkPath(row, "thumb", "parentThumb");
                    if (kind == "album" || kind == "track")
                    {
                        string artist = Str(row, kind == "track" ? "grandparentTitle" : "parentTitle");
                        items[key] = new LibraryItem { Kind = kind, Title = title, Artist = artist, Thumb = thumb };
                        rows.Add(new { id = key, kind, title, artist, subtitle = artist, artwork = RegisterArtwork(thumb) });
                    }
                    else
                    {
                        rows.Add(new { key, type = kind, title, summary = Str(row, "summary"), thumb,
                            artwork = RegisterVideoArt(server.Id, section, thumb), duration = Num(row, "duration") / 1000.0,
                            seconds = Num(row, "viewOffset") / 1000.0, watched = Num(row, "viewCount") > 0,
                            subtitle = kind == "episode" ? Str(row, "grandparentTitle") + " · Episode " + Str(row, "index") : Str(row, "year") });
                    }
                }
                group.rows = rows.ToArray();
            }
            catch (Exception) { group.Failed = !token.IsCancellationRequested; }
            return group;
        }
    }
}
