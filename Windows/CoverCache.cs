using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
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
            return WithServer(server, url =>
            {
                var request = PlexRequest(HttpMethod.Get, new Uri(url, relative), server.Token);
                request.Headers.Remove("Accept");
                request.Headers.Add("Accept", "image/*");
                return FetchBytes(request, 8 * 1024 * 1024, token, 10);
            }, token);
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

        void StopCoverCache(bool notify)
        {
            var job = coverCacheJob;
            if (job == null) return;
            coverCacheJob = null;
            job.Cancel();
            if (notify) CoverCacheState(false, "Canceled. Downloaded artwork was kept.");
        }

        async Task CacheLibraryArtwork(Dictionary<string, object> request)
        {
            Server server;
            if (coverCacheJob != null || !servers.TryGetValue(selectedServer, out server))
                return;
            var selections = new List<Tuple<string, string, string>>();
            if (selectedSection.Length > 0)
            {
                selections.Add(Tuple.Create(selectedSection, "album", "9"));
                selections.Add(Tuple.Create(selectedSection, "artist", "8"));
            }
            foreach (var kind in new[] { Tuple.Create("movie", "1"), Tuple.Create("show", "2") })
            {
                var available = videoSections.Where(section => section.type == kind.Item1).ToArray();
                var preferred = Str(request, kind.Item1);
                var selected = available.FirstOrDefault(section => section.id == preferred) ?? available.FirstOrDefault();
                if (selected != null) selections.Add(Tuple.Create(selected.id, kind.Item1, kind.Item2));
            }
            var job = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            var token = job.Token;
            coverCacheJob = job;
            CoverCacheState(true, "Checking selected libraries…");
            int saved = 0, skipped = 0;
            string message = "";
            Func<string> summary = () => saved + (saved == 1 ? " image cached" : " images cached") +
                                          (skipped == 0 ? "" : " · " + skipped + " unavailable");
            try
            {
                foreach (var selection in selections)
                {
                    string section = selection.Item1, kind = selection.Item2;
                    int offset = 0;
                    var seen = new HashSet<string>();
                    while (true)
                    {
                        string endpoint = "/library/sections/" + section + "/all?type=" + selection.Item3 + "&sort=titleSort%3Aasc" +
                                          "&X-Plex-Container-Size=60&X-Plex-Container-Start=" + offset;
                        var rows = await WithServer(server, async url => Metadata(await FetchPlex(HttpMethod.Get,
                            new Uri(url, endpoint), server.Token, token, 8 * 1024 * 1024), section).ToArray(), token);
                        if (rows.Length == 0) break;
                        var items = rows.Where(row => Str(row, "type") == kind &&
                            ItemID.IsMatch(Str(row, "ratingKey")) && seen.Add(Str(row, "ratingKey"))).ToArray();
                        if (items.Length == 0) throw Problem("Plex stopped advancing through the " + kind + " list.");
                        foreach (var item in items)
                        {
                            token.ThrowIfCancellationRequested();
                            try
                            {
                                var relative = Str(item, "thumb");
                                if (relative.Length >= 180 || !ArtPath.IsMatch(relative)) throw Problem("No artwork.");
                                var target = CoverCachePath(server.Id, section, relative);
                                if (!File.Exists(target))
                                {
                                    await artSlots.WaitAsync(token);
                                    try
                                    {
                                        var bytes = await FetchArtwork(server, relative, token);
                                        await Task.Run(() => SaveCover(bytes, target), token);
                                    }
                                    finally { artSlots.Release(); }
                                }
                                saved++;
                            }
                            catch (Exception)
                            {
                                token.ThrowIfCancellationRequested();
                                skipped++;
                            }
                            if ((saved + skipped) % 10 == 0 && coverCacheJob == job) CoverCacheState(true, summary());
                        }
                        offset += rows.Length;
                    }
                }
                message = summary();
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                message = error is InvalidDataException ? error.Message : "Couldn’t finish caching library artwork.";
            }
            finally
            {
                if (coverCacheJob == job)
                {
                    coverCacheJob = null;
                    if (!token.IsCancellationRequested) CoverCacheState(false, message);
                }
                job.Dispose();
            }
        }
    }
}
