using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Windows.Forms;

[assembly: AssemblyVersion("0.1.46.0")]
[assembly: AssemblyFileVersion("0.1.46.0")]
[assembly: AssemblyTitle("iPlex")]
[assembly: AssemblyProduct("iPlex")]

namespace MusicRoom
{
    internal static class DesktopBootstrap
    {
        internal static readonly string Profile = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Music Room");
        private static readonly Dictionary<string, string> Assemblies = new Dictionary<string, string>(StringComparer.Ordinal);

        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (args.Length == 2 && args[0] == "--apply-iplex-update")
            {
                AppUpdater.Apply(args[1]);
                return;
            }
            string updateAcknowledgment = args.Length == 2 && args[0] == "--confirm-iplex-update" ? args[1] : null;
            try
            {
                string machine = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
                string arch = IntPtr.Size == 4 ? "x86" : String.Equals(machine, "ARM64", StringComparison.OrdinalIgnoreCase) ? "arm64" : "x64";
                foreach (string name in new[] { "Microsoft.Web.WebView2.Core", "Microsoft.Web.WebView2.WinForms" })
                    Assemblies[name] = Materialize(name + ".dll", name + ".dll");
                var loader = Materialize(arch + ".WebView2Loader.dll", "WebView2Loader.dll");
                AppDomain.CurrentDomain.AssemblyResolve += delegate(object sender, ResolveEventArgs e)
                {
                    string path;
                    return Assemblies.TryGetValue(new AssemblyName(e.Name).Name, out path) ? Assembly.LoadFrom(path) : null;
                };
                VideoWatchStore.Load(Materialize(arch + ".sqlite3.dll", VideoWatchStore.Dll));
                Run(Path.GetDirectoryName(loader), updateAcknowledgment);
            }
            catch (Exception)
            {
                MessageBox.Show("iPlex couldn’t start. Make sure Microsoft Edge WebView2 Runtime is installed.",
                                "iPlex", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static void Run(string loaderFolder, string updateAcknowledgment)
        {
            Microsoft.Web.WebView2.Core.CoreWebView2Environment.SetLoaderDllFolderPath(loaderFolder);
            using (var window = new MusicWindow(updateAcknowledgment)) Application.Run(window);
        }

        // Each version has its own immutable path so a running app and its updater can coexist.
        internal static string Materialize(string resourceName, string fileName)
        {
            byte[] bytes;
            using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("Desktop." + resourceName))
            using (MemoryStream buffer = new MemoryStream()) { source.CopyTo(buffer); bytes = buffer.ToArray(); }
            using (SHA256 sha = SHA256.Create())
            {
                string hash = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
                string folder = Path.Combine(Profile, "Runtime", hash);
                string path = Path.Combine(folder, fileName);
                Directory.CreateDirectory(folder);
                if (!File.Exists(path))
                {
                    string temporary = path + "." + Guid.NewGuid().ToString("N");
                    try
                    {
                        File.WriteAllBytes(temporary, bytes);
                        try { File.Move(temporary, path); } catch (IOException) { if (!File.Exists(path)) throw; }
                    }
                    finally { if (File.Exists(temporary)) File.Delete(temporary); }
                }
                using (FileStream cached = File.OpenRead(path))
                    if (BitConverter.ToString(sha.ComputeHash(cached)).Replace("-", "") != hash)
                        throw new InvalidDataException("A cached desktop component is damaged. Remove " + folder + " and reopen the app.");
                return path;
            }
        }
    }
}
