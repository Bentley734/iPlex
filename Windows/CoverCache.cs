using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace MusicRoom
{
    internal sealed partial class WindowsMediaService
    {
        CancellationTokenSource coverCacheJob;

        string CoverCachePath(string server, string library, string relative)
        {
            using (var sha = SHA256.Create())
            {
                var key = sha.ComputeHash(Encoding.UTF8.GetBytes(server + "|" + library + "|" + relative));
                return Path.Combine(root, "PlexAlbumCovers", BitConverter.ToString(key).Replace("-", "") + ".jpg");
            }
        }

        Task<byte[]> FetchArtwork(Server server, string relative, CancellationToken token)
        {
            return WithServer(server, url => FetchCover(url, relative, server.Token, token, 10, 8 * 1024 * 1024), token);
        }

        Task<byte[]> FetchCover(Uri server, string endpoint, string plexToken, CancellationToken token, int timeout, int limit)
        {
            var request = PlexRequest(HttpMethod.Get, new Uri(server, endpoint), plexToken);
            request.Headers.Remove("Accept");
            request.Headers.Add("Accept", "image/*");
            return FetchBytes(request, limit, token, timeout);
        }

        async Task<byte[]> FetchCacheThumbnail(Uri server, string relative, string plexToken, CancellationToken token)
        {
            string endpoint = "/photo/:/transcode?width=420&height=420&upscale=0&format=jpg&url=" +
                              Uri.EscapeDataString(relative);
            try { return await FetchCover(server, endpoint, plexToken, token, 5, 2 * 1024 * 1024).ConfigureAwait(false); }
            catch (InvalidDataException error)
            {
                if (!new[] { 400, 404, 405, 422, 501 }.Any(code => CoverHttpError(error, code))) throw;
            }
            return await FetchCover(server, relative, plexToken, token, 5, 8 * 1024 * 1024).ConfigureAwait(false);
        }

        static bool CoverHttpError(Exception error, int code)
        {
            return error is InvalidDataException && error.Message == "The service returned HTTP " + code + ".";
        }

        static void SaveCover(byte[] data, string target)
        {
            using (var stream = new MemoryStream(data, false))
            using (var source = Image.FromStream(stream))
            {
                var ratio = Math.Min(1.0, 420.0 / Math.Max(source.Width, source.Height));
                using (var bitmap = new Bitmap(Math.Max(1, (int)(source.Width * ratio)),
                                                Math.Max(1, (int)(source.Height * ratio)), PixelFormat.Format24bppRgb))
                using (var graphics = Graphics.FromImage(bitmap))
                using (var jpeg = new MemoryStream())
                {
                    graphics.Clear(Color.Black);
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.DrawImage(source, 0, 0, bitmap.Width, bitmap.Height);
                    bitmap.Save(jpeg, ImageFormat.Jpeg);
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    Atomic(target, jpeg.ToArray());
                }
            }
        }

        void CoverCacheState(bool running, string message)
        {
            Send("musicCoverCache", new { running, message });
        }

        bool notifyCoverCancellation;

        void StopCoverCache(bool notify)
        {
            var job = coverCacheJob;
            if (job == null) return;
            notifyCoverCancellation = notify;
            job.Cancel();
            if (notify) CoverCacheState(true, "Stopping…");
        }

        static long ReadCoverCheckpoint(string path, string revision)
        {
            if (revision.Length == 0 || !File.Exists(path)) return 0;
            try
            {
                var fields = File.ReadAllLines(path);
                long offset;
                return fields.Length == 2 && fields[0] == revision &&
                    Int64.TryParse(fields[1], NumberStyles.None, CultureInfo.InvariantCulture, out offset) &&
                    offset > 0 && offset < Int32.MaxValue ? offset : 0;
            }
            catch (IOException) { return 0; }
            catch (UnauthorizedAccessException) { return 0; }
        }

        async Task CacheLibraryArtwork(Dictionary<string, object> request)
        {
            Server server;
            if (coverCacheJob != null || !servers.TryGetValue(selectedServer, out server))
                return;
            var selections = new List<Tuple<string, string, string, string>>();
            if (selectedSection.Length > 0)
            {
                selections.Add(Tuple.Create(selectedSection, "album", "9", "Albums"));
                selections.Add(Tuple.Create(selectedSection, "artist", "8", "Artists"));
            }
            foreach (var kind in new[] { Tuple.Create("movie", "1", "Movies"), Tuple.Create("show", "2", "TV Shows") })
            {
                var available = videoSections.Where(section => section.type == kind.Item1).ToArray();
                var preferred = Str(request, kind.Item1);
                var selected = available.FirstOrDefault(section => section.id == preferred) ?? available.FirstOrDefault();
                if (selected != null) selections.Add(Tuple.Create(selected.id, kind.Item1, kind.Item2, kind.Item3));
            }
            if (selections.Count == 0)
            {
                CoverCacheState(false, "Choose a library to cache its artwork.");
                return;
            }
            var job = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            var token = job.Token;
            coverCacheJob = job;
            notifyCoverCancellation = false;
            CoverCacheState(true, "Checking selected libraries…");
            int downloaded = 0, cached = 0, unavailable = 0;
            string message = "";
            var incomplete = new List<string>();
            Func<string> summary = () => downloaded + " downloaded · " + cached + " already saved" +
                (unavailable == 0 ? "" : " · " + unavailable + " unavailable");
            try
            {
                var directories = await WithServer(server, url => FetchPlex(HttpMethod.Get,
                    new Uri(url, "/library/sections"), server.Token, token, 2 * 1024 * 1024, 8), token);
                var sections = Rows(Get(Map(Get(Map(directories), "MediaContainer")), "Directory")).ToArray();
                foreach (var selection in selections)
                {
                    token.ThrowIfCancellationRequested();
                    string section = selection.Item1, kind = selection.Item2, label = selection.Item4;
                    var directory = sections.FirstOrDefault(row => Str(row, "key") == section);
                    string revision = directory == null || Num(directory, "updatedAt") <= 0 ? "" :
                        Str(directory, "updatedAt") + ":" + Num(directory, "scannedAt");
                    var checkpoint = Path.ChangeExtension(CoverCachePath(server.Id, section, "scan-" + kind), "txt");
                    long offset = await Task.Run(() => ReadCoverCheckpoint(checkpoint, revision), token);
                    var seen = new HashSet<string>();
                    bool failed = false;
                    int consecutiveFailures = 0;
                    var lastReport = System.Diagnostics.Stopwatch.StartNew();
                    try
                    {
                        do
                        {
                            CoverCacheState(true, label + " · Checking from item " + (offset + 1) + " · " + summary());
                            string endpoint = "/library/sections/" + section + "/all?type=" + selection.Item3 + "&sort=titleSort%3Aasc" +
                                              "&X-Plex-Container-Size=60&X-Plex-Container-Start=" + offset;
                            var page = await WithServer(server, async url => new {
                                Base = url, Data = await FetchPlex(HttpMethod.Get,
                                    new Uri(url, endpoint), server.Token, token, 8 * 1024 * 1024, 8)
                            }, token);
                            var container = Map(Get(Map(page.Data), "MediaContainer"));
                            int count = Rows(Get(container, "Metadata")).Count();
                            var rows = Metadata(page.Data, section).Where(row => Str(row, "type") == kind &&
                                ItemID.IsMatch(Str(row, "ratingKey"))).ToArray();
                            var items = rows.Where(row => seen.Add(Str(row, "ratingKey"))).ToArray();
                            if (rows.Length > 0 && items.Length == 0) throw Problem("Plex stopped advancing through the artwork list.");
                            foreach (var item in items)
                            {
                                token.ThrowIfCancellationRequested();
                                var relative = Str(item, "thumb");
                                if (relative.Length >= 180 || !ArtPath.IsMatch(relative)) unavailable++;
                                else
                                {
                                    var target = CoverCachePath(server.Id, section, relative);
                                    try
                                    {
                                        if (await Task.Run(() => File.Exists(target), token)) cached++;
                                        else
                                        {
                                            await artSlots.WaitAsync(token);
                                            try
                                            {
                                                var bytes = await FetchCacheThumbnail(page.Base, relative, server.Token, token);
                                                await Task.Run(() => SaveCover(bytes, target), token);
                                            }
                                            finally { artSlots.Release(); }
                                            downloaded++;
                                        }
                                        consecutiveFailures = 0;
                                    }
                                    catch (Exception error)
                                    {
                                        token.ThrowIfCancellationRequested();
                                        unavailable++;
                                        if (CoverHttpError(error, 404)) consecutiveFailures = 0;
                                        else
                                        {
                                            failed = true;
                                            consecutiveFailures++;
                                        }
                                    }
                                }
                                if (lastReport.ElapsedMilliseconds >= 350 || downloaded + cached + unavailable == 1)
                                {
                                    CoverCacheState(true, label + " · " + summary());
                                    lastReport.Restart();
                                }
                                if (consecutiveFailures >= 3) break;
                            }
                            token.ThrowIfCancellationRequested();
                            if (consecutiveFailures >= 3)
                            {
                                incomplete.Add(label);
                                break;
                            }
                            offset += count;
                            long total = Num(container, "totalSize");
                            if (count == 0 || (total > 0 ? offset >= total : count < 60))
                            {
                                if (!failed) await Task.Run(() => { if (File.Exists(checkpoint)) File.Delete(checkpoint); }, token);
                                break;
                            }
                            if (!failed && revision.Length > 0)
                            {
                                string contents = revision + "\n" + offset.ToString(CultureInfo.InvariantCulture);
                                await Task.Run(() => {
                                    Directory.CreateDirectory(Path.GetDirectoryName(checkpoint));
                                    Atomic(checkpoint, Encoding.UTF8.GetBytes(contents));
                                }, token);
                            }
                        } while (true);
                    }
                    catch (Exception)
                    {
                        token.ThrowIfCancellationRequested();
                        incomplete.Add(label);
                    }
                }
                message = summary() + (incomplete.Count == 0 ? "" : " · Couldn't finish " + String.Join(", ", incomplete));
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                message = error is InvalidDataException ? error.Message : "Couldn’t finish caching library artwork.";
            }
            finally
            {
                coverCacheJob = null;
                if (!token.IsCancellationRequested) CoverCacheState(false, message);
                else if (notifyCoverCancellation) CoverCacheState(false, "Canceled. Downloaded artwork was kept.");
                job.Dispose();
            }
        }
    }
}
