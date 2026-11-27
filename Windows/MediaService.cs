using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace MusicRoom
{
    internal sealed partial class WindowsMediaService : IDisposable
    {
        readonly string root;
        readonly Action<string, object> emit;
        readonly HttpClient http;
        readonly CancellationTokenSource shutdown = new CancellationTokenSource();
        readonly Dictionary<string, MediaTrack> handles = new Dictionary<string, MediaTrack>();
        bool disposed;

        public WindowsMediaService(string root, Action<string, object> emit)
        {
            this.root = root;
            this.emit = emit;
            Directory.CreateDirectory(root);
            videoWatch = new VideoWatchStore(root);
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false });
            http.Timeout = Timeout.InfiniteTimeSpan;
        }

        internal sealed class MediaTrack
        {
            public long ratingCount;
            public int number;
            public string plexID, playlistItemID, codec, container;
            public long sampleRate, bitDepth, bitrate, channels;
            public string title, localPath, token, mime, artwork, artist, album;
            public double? durationSeconds;
            public Uri remote;
            public bool directMp4;
            public long readerGeneration;
            public MediaTrack CopyForQueue() { return (MediaTrack)MemberwiseClone(); }
        }

        internal static JavaScriptSerializer Json()
        {
            return new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024, RecursionLimit = 64 };
        }
        internal static Dictionary<string, object> Map(object value)
        {
            return value as Dictionary<string, object> ?? new Dictionary<string, object>();
        }
        static object Get(Dictionary<string, object> value, string key)
        {
            object field;
            return value.TryGetValue(key, out field) ? field : null;
        }
        internal static string Str(Dictionary<string, object> value, string key)
        {
            return Convert.ToString(Get(value, key), CultureInfo.InvariantCulture) ?? "";
        }
        internal static long Num(Dictionary<string, object> value, string key)
        {
            long number;
            return Int64.TryParse(Str(value, key), NumberStyles.Integer, CultureInfo.InvariantCulture, out number) ? number : 0;
        }
        internal static IEnumerable<Dictionary<string, object>> Rows(object value)
        {
            var items = value as IEnumerable;
            return items == null || value is string ? Enumerable.Empty<Dictionary<string, object>>() : items.Cast<object>().OfType<Dictionary<string, object>>();
        }
        static InvalidDataException Problem(string message) { return new InvalidDataException(message); }
        void Send(string name, object data) { if (!disposed) emit(name, data); }
        static void OpenSignIn(string url) { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }

        async Task<string> TextAsync(HttpRequestMessage request, int limit, CancellationToken token, int seconds)
        {
            return System.Text.Encoding.UTF8.GetString(await FetchBytes(request, limit, token, seconds));
        }

        async Task<byte[]> FetchBytes(HttpRequestMessage request, int limit, CancellationToken token, int seconds)
        {
            using (request)
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                timeout.CancelAfter(TimeSpan.FromSeconds(seconds));
                using (var reply = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false))
                {
                    if (!reply.IsSuccessStatusCode) throw Problem("The service returned HTTP " + (int)reply.StatusCode + ".");
                    if (reply.Content.Headers.ContentLength > limit) throw Problem("The server response is too large.");
                    using (var stream = await reply.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    using (var bytes = new MemoryStream())
                    {
                        var buffer = new byte[32768];
                        int length;
                        while ((length = await stream.ReadAsync(buffer, 0, buffer.Length, timeout.Token).ConfigureAwait(false)) > 0)
                        {
                            if (bytes.Length + length > limit) throw Problem("The server response is too large.");
                            bytes.Write(buffer, 0, length);
                        }
                        return bytes.ToArray();
                    }
                }
            }
        }

        static bool RealFile(string path)
        {
            return File.Exists(path) && (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0;
        }
        static void Clean(string path)
        {
            try { if (Directory.Exists(path)) Directory.Delete(path, true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        static async Task CopyBounded(Stream input, string file, long limit, CancellationToken token)
        {
            using (var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                var buffer = new byte[65536];
                long total = 0;
                int length;
                while ((length = await input.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false)) > 0)
                {
                    total += length;
                    if (total > limit) throw Problem("This track exceeds the playback cache limit.");
                    await output.WriteAsync(buffer, 0, length, token).ConfigureAwait(false);
                }
                if (total == 0) throw Problem("The audio file was empty.");
            }
        }

        public void Dispose()
        {
            disposed = true;
            videoWatch.Dispose();
            shutdown.Cancel();
            http.Dispose();
            ReleaseHandles();
        }
    }
}
