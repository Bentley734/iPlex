using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace MusicRoom
{
    internal static class AppUpdater
    {
        const string Repository = "https://github.com/Bentley734/iPlex";
        const string Latest = "https://api.github.com/repos/Bentley734/iPlex/releases/latest";
        const string Package = "iPlex.Windows.zip";
        const string Executable = "iPlex.exe";
        const int MaxPackage = 128 * 1024 * 1024;
        static readonly Version Current = Assembly.GetExecutingAssembly().GetName().Version;
        static readonly HttpClient Client = MakeClient();

        internal sealed class Plan
        {
            public string Target { get; set; }
            public string CurrentHash { get; set; }
            public string CandidateHash { get; set; }
            public string Version { get; set; }
            public int Parent { get; set; }
            public long ParentStarted { get; set; }
            public int Helper { get; set; }
            public long HelperStarted { get; set; }
        }

        internal sealed class Release
        {
            public Version Version;
            public Uri Address;
            public string Digest;
            public int Size;
        }

        static HttpClient MakeClient()
        {
            var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false });
            client.Timeout = Timeout.InfiniteTimeSpan;
            client.DefaultRequestHeaders.UserAgent.ParseAdd("iPlex/" + Current.ToString(3));
            return client;
        }

        static async Task<byte[]> Fetch(Uri address, int limit, bool asset, CancellationToken token)
        {
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                timeout.CancelAfter(TimeSpan.FromSeconds(asset ? 150 : 30));
                for (int redirects = 0; redirects <= 5; redirects++)
                {
                    using (var response = await Client.GetAsync(address, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false))
                    using (timeout.Token.Register(response.Dispose))
                    {
                        int code = (int)response.StatusCode;
                        if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308)
                        {
                            if (!asset || response.Headers.Location == null) throw new InvalidDataException("Unexpected release redirect.");
                            address = new Uri(address, response.Headers.Location);
                            if (address.Scheme != "https" || !address.IsDefaultPort || address.UserInfo.Length != 0 ||
                                (address.Host != "release-assets.githubusercontent.com" && address.Host != "objects.githubusercontent.com"))
                                throw new InvalidDataException("The download redirected outside GitHub.");
                            continue;
                        }
                        response.EnsureSuccessStatusCode();
                        if (code != 200 || response.Content.Headers.ContentLength > limit)
                            throw new InvalidDataException("The update response was incomplete or oversized.");
                        using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                        using (var output = new MemoryStream())
                        {
                            byte[] buffer = new byte[65536];
                            int count;
                            while ((count = await input.ReadAsync(buffer, 0, buffer.Length, timeout.Token).ConfigureAwait(false)) != 0)
                            {
                                if (output.Length + count > limit) throw new InvalidDataException("The download exceeded its expected size.");
                                output.Write(buffer, 0, count);
                            }
                            return output.ToArray();
                        }
                    }
                }
            }
            throw new InvalidDataException("Too many GitHub release redirects.");
        }

        internal static Release Parse(string json, Version current)
        {
            var root = WindowsMediaService.Map(WindowsMediaService.Json().DeserializeObject(json));
            object draft, prerelease, assets;
            string tag = WindowsMediaService.Str(root, "tag_name");
            Version version;
            if (!root.TryGetValue("draft", out draft) || !(draft is bool) || (bool)draft ||
                !root.TryGetValue("prerelease", out prerelease) || !(prerelease is bool) || (bool)prerelease ||
                !System.Text.RegularExpressions.Regex.IsMatch(tag, @"^v?[0-9]+\.[0-9]+\.[0-9]+\z") ||
                !Version.TryParse(tag.TrimStart('v') + ".0", out version) ||
                WindowsMediaService.Str(root, "html_url") != Repository + "/releases/tag/" + tag)
                throw new InvalidDataException("Invalid GitHub release metadata.");
            if (version.CompareTo(current) <= 0) return null;
            if (!root.TryGetValue("assets", out assets)) throw new InvalidDataException("The GitHub release has no downloads.");
            var matches = WindowsMediaService.Rows(assets).Where(a => WindowsMediaService.Str(a, "name") == Package).ToArray();
            if (matches.Length != 1) throw new InvalidDataException("The Windows update ZIP is missing or duplicated.");
            var metadata = matches[0];
            string download = WindowsMediaService.Str(metadata, "browser_download_url");
            string digest = WindowsMediaService.Str(metadata, "digest");
            long size = WindowsMediaService.Num(metadata, "size");
            if (download != Repository + "/releases/download/" + tag + "/" + Package || size < 1 || size > MaxPackage ||
                !digest.StartsWith("sha256:", StringComparison.Ordinal) || !HexDigest(digest.Substring(7)))
                throw new InvalidDataException("The Windows update package metadata is invalid.");
            return new Release { Version = version, Address = new Uri(download), Digest = digest.Substring(7), Size = (int)size };
        }

        internal static async Task<Release> Check(CancellationToken token)
        {
            var data = await Fetch(new Uri(Latest), 2 * 1024 * 1024, false, token).ConfigureAwait(false);
            return Parse(System.Text.Encoding.UTF8.GetString(data), Current);
        }

        internal static async Task<byte[]> Download(Release release, CancellationToken token)
        {
            var zip = await Fetch(release.Address, release.Size, true, token).ConfigureAwait(false);
            return Unpack(zip, release);
        }

        internal static byte[] Unpack(byte[] zip, Release release)
        {
            if (zip.Length != release.Size || !String.Equals(Hash(zip), release.Digest, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The update ZIP did not match GitHub’s size or SHA-256 digest.");
            using (var buffer = new MemoryStream(zip, false))
            using (var archive = new ZipArchive(buffer, ZipArchiveMode.Read))
            {
                var entries = archive.Entries.Where(e => e.FullName == Executable).ToArray();
                if (entries.Length != 1 || entries[0].Length < 1 || entries[0].Length > MaxPackage)
                    throw new InvalidDataException("The update did not contain the expected Windows app.");
                var bytes = new byte[entries[0].Length];
                using (var stream = entries[0].Open())
                {
                    int position = 0;
                    while (position < bytes.Length)
                    {
                        int count = stream.Read(bytes, position, bytes.Length - position);
                        if (count == 0) throw new InvalidDataException("The update executable was incomplete.");
                        position += count;
                    }
                }
                return bytes;
            }
        }

        static bool HexDigest(string value)
        {
            return System.Text.RegularExpressions.Regex.IsMatch(value ?? "", @"^[0-9a-fA-F]{64}\z");
        }
        static string Hash(byte[] bytes)
        {
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
        static string HashFile(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path))
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
        static Version Identity(string path)
        {
            var assembly = AssemblyName.GetAssemblyName(path);
            if (assembly.Name != "iPlex") throw new InvalidDataException("The executable was not iPlex.");
            return assembly.Version;
        }
        static string Stage(string id)
        {
            Guid parsed;
            if (!Guid.TryParseExact(id, "N", out parsed)) throw new InvalidDataException("Invalid update identifier.");
            string root = Path.Combine(DesktopBootstrap.Profile, "AppUpdates");
            string folder = Path.Combine(root, id);
            foreach (string path in new[] { root, folder })
                if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("The update folder is a filesystem link.");
            return folder;
        }
        static string ReadyName(string id) { return "Local\\iPlex.Update." + id; }

        internal static void Begin(Release release, byte[] bytes)
        {
            string id = Guid.NewGuid().ToString("N");
            string folder = Stage(id), candidate = Path.Combine(folder, Executable);
            Directory.CreateDirectory(folder);
            Process helper = null;
            try
            {
                using (var parent = Process.GetCurrentProcess())
                {
                    string target = parent.MainModule.FileName;
                    if (Identity(target).CompareTo(release.Version) >= 0) throw new InvalidDataException("iPlex is already up to date.");
                    using (File.Create(Path.Combine(Path.GetDirectoryName(target), ".iplex-" + id),
                                       4096, FileOptions.DeleteOnClose)) { }
                    File.WriteAllBytes(candidate, bytes);
                    if (Identity(candidate) != release.Version) throw new InvalidDataException("The update executable version did not match GitHub.");
                    var plan = new Plan { Target = target, CurrentHash = HashFile(target), CandidateHash = Hash(bytes),
                        Version = release.Version.ToString(), Parent = parent.Id, ParentStarted = parent.StartTime.ToUniversalTime().Ticks };
                    File.WriteAllText(Path.Combine(folder, "plan.json"), new JavaScriptSerializer().Serialize(plan));
                    using (var ready = new EventWaitHandle(false, EventResetMode.ManualReset, ReadyName(id)))
                    {
                        helper = Start(candidate, "--apply-iplex-update " + id);
                        if (!ready.WaitOne(TimeSpan.FromSeconds(12)))
                            throw new IOException("The update helper did not start. iPlex was kept unchanged.");
                    }
                }
            }
            catch
            {
                if (helper != null && !helper.HasExited) helper.Kill();
                DeleteStage(folder);
                throw;
            }
            finally { if (helper != null) helper.Dispose(); }
        }

        static Process Start(string path, string args)
        {
            var process = Process.Start(new ProcessStartInfo(path, args) {
                UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(path), CreateNoWindow = true
            });
            if (process == null) throw new IOException("Windows could not launch iPlex.");
            return process;
        }

        internal static void Apply(string id)
        {
            try
            {
                string folder = Stage(id), own = Process.GetCurrentProcess().MainModule.FileName;
                if (!String.Equals(own, Path.Combine(folder, Executable), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The update helper must be run from its staging folder.");
                var plan = new JavaScriptSerializer().Deserialize<Plan>(File.ReadAllText(Path.Combine(folder, "plan.json")));
                Version version = Version.Parse(plan.Version);
                using (var parent = Process.GetProcessById(plan.Parent))
                {
                    if (parent.StartTime.ToUniversalTime().Ticks != plan.ParentStarted ||
                        !String.Equals(parent.MainModule.FileName, plan.Target, StringComparison.OrdinalIgnoreCase) ||
                        Identity(plan.Target).CompareTo(version) >= 0 || Identity(own) != version ||
                        HashFile(own) != plan.CandidateHash || HashFile(plan.Target) != plan.CurrentHash)
                        throw new InvalidDataException("The running app no longer matched this update.");
                    using (var helper = Process.GetCurrentProcess())
                    {
                        plan.Helper = helper.Id;
                        plan.HelperStarted = helper.StartTime.ToUniversalTime().Ticks;
                        File.WriteAllText(Path.Combine(folder, "plan.json"), new JavaScriptSerializer().Serialize(plan));
                    }
                    using (var ready = EventWaitHandle.OpenExisting(ReadyName(id))) ready.Set();
                    if (!parent.WaitForExit(60000)) throw new IOException("The previous app did not close.");
                }
                Replace(plan, own, id, folder);
            }
            catch (Exception error)
            {
                MessageBox.Show(error.Message, "iPlex Update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        static void Replace(Plan plan, string own, string id, string folder)
        {
            string incoming = plan.Target + ".incoming-" + id;
            string previous = plan.Target + ".previous-" + id;
            bool updated = false;
            try
            {
                File.Copy(own, incoming, false);
                if (HashFile(plan.Target) != plan.CurrentHash || HashFile(incoming) != plan.CandidateHash)
                    throw new InvalidDataException("The executables changed while preparing the update.");
                File.Replace(incoming, plan.Target, previous);
                updated = true;
                using (var launched = Start(plan.Target, "--confirm-iplex-update " + id))
                {
                    DateTime until = DateTime.UtcNow.AddSeconds(45);
                    string ack = Path.Combine(folder, "ready");
                    while (!File.Exists(ack) && !launched.HasExited && DateTime.UtcNow < until) Thread.Sleep(200);
                    if (!File.Exists(ack))
                    {
                        if (!launched.HasExited) { launched.Kill(); launched.WaitForExit(5000); }
                        throw new IOException("The new version did not finish launching. The previous version was restored.");
                    }
                }
                for (int i = 0; i < 20 && !TryDelete(previous); i++) Thread.Sleep(500);
            }
            catch
            {
                if (updated || File.Exists(previous))
                {
                    if (File.Exists(plan.Target)) File.Replace(previous, plan.Target, null);
                    else File.Move(previous, plan.Target);
                    using (Start(plan.Target, "")) { }
                }
                throw;
            }
            finally { TryDelete(incoming); }
        }

        internal static void Confirm(string id)
        {
            if (String.IsNullOrEmpty(id)) return;
            try
            {
                string folder = Stage(id);
                var plan = new JavaScriptSerializer().Deserialize<Plan>(File.ReadAllText(Path.Combine(folder, "plan.json")));
                if (!String.Equals(plan.Target, Process.GetCurrentProcess().MainModule.FileName, StringComparison.OrdinalIgnoreCase) ||
                    plan.Version != Current.ToString()) return;
                File.WriteAllText(Path.Combine(folder, "ready"), "ready");
                Task.Run(() => {
                    try {
                        using (var helper = Process.GetProcessById(plan.Helper))
                            if (helper.StartTime.ToUniversalTime().Ticks == plan.HelperStarted &&
                                !helper.WaitForExit(60000)) return;
                    }
                    catch (ArgumentException) { }
                    catch (InvalidOperationException) { }
                    for (int i = 0; i < 100; i++) {
                        if (DeleteStage(folder)) return;
                        Thread.Sleep(500);
                    }
                });
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (InvalidDataException) { }
            catch (ArgumentException) { }
        }

        static bool DeleteStage(string folder)
        {
            // The copied helper is locked while running; keep the acknowledgment until it exits.
            if (!TryDelete(Path.Combine(folder, Executable))) return false;
            TryDelete(Path.Combine(folder, "plan.json"));
            TryDelete(Path.Combine(folder, "ready"));
            try { Directory.Delete(folder); } catch (IOException) { return false; } catch (UnauthorizedAccessException) { return false; }
            return true;
        }
        static bool TryDelete(string path)
        {
            try { File.Delete(path); return true; }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
    }
}
