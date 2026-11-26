using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace MusicRoom
{
    internal sealed partial class MusicWindow : Form
    {
        const string Page = "https://musicroom.invalid/index.html";
        readonly WebView2 view = new WebView2();
        readonly WindowsMediaService media;
        readonly Dictionary<string, byte[]> assets = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        Icon dockIcon;
        bool closing;

        public MusicWindow()
        {
            Text = "iPlex";
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(1120, 750);
            MinimumSize = new Size(780, 530);
            BackColor = view.DefaultBackgroundColor = Color.FromArgb(19, 19, 23);
            view.Bounds = ClientRectangle;
            Controls.Add(view);
            ClientSizeChanged += (sender, args) => FitLibraryWebView();
            using (var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("Desktop.site.zip"))
            using (var zip = new ZipArchive(source, ZipArchiveMode.Read))
            foreach (var entry in zip.Entries)
            {
                if (entry.Name.Length == 0) continue;
                using (var data = entry.Open())
                using (var buffer = new MemoryStream())
                {
                    data.CopyTo(buffer);
                    assets.Add("/" + entry.FullName, buffer.ToArray());
                }
            }
            UseIcon("groove");
            media = new WindowsMediaService(DesktopBootstrap.Profile, Emit);
            media.GetLosslessDecoder = () =>
            {
                bool arm = String.Equals(Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE"), "ARM64", StringComparison.OrdinalIgnoreCase)
                    || String.Equals(Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432"), "ARM64", StringComparison.OrdinalIgnoreCase);
                string arch = Environment.Is64BitOperatingSystem && !arm ? "x64" : "x86";
                return DesktopBootstrap.Materialize("Lossless-" + arch + ".exe", "Lossless.exe");
            };
            Shown += async delegate { await StartWebView(); };
            FormClosing += (sender, args) =>
            {
                if (args.CloseReason == CloseReason.UserClosing && floatingPlayer)
                {
                    args.Cancel = true;
                    SetFloatingPlayer(false);
                    Emit("closeFloatingPlayer", null);
                    return;
                }
                closing = true;
                media.Dispose();
            };
            FormClosed += delegate { if (dockIcon != null) dockIcon.Dispose(); };
        }

        void FitLibraryWebView()
        {
            if (!floatingPlayer && view.Bounds != ClientRectangle)
                view.Bounds = ClientRectangle;
        }

        void UseIcon(string name)
        {
            byte[] file;
            if (!assets.TryGetValue("/" + name + ".ico", out file)) return;
            using (var stream = new MemoryStream(file)) using (var icon = new Icon(stream))
            {
                var old = dockIcon;
                Icon = dockIcon = (Icon)icon.Clone();
                if (old != null) old.Dispose();
            }
        }

        async Task StartWebView()
        {
            try
            {
                var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(DesktopBootstrap.Profile, "WebView"), null);
                if (closing) return;
                await view.EnsureCoreWebView2Async(environment);
                if (closing) return;
                var core = view.CoreWebView2;
                core.Settings.AreHostObjectsAllowed = false;
                core.Settings.AreDefaultContextMenusEnabled = false;
                core.Settings.AreBrowserAcceleratorKeysEnabled = false;
                core.Settings.AreDevToolsEnabled = false;
                core.Settings.IsStatusBarEnabled = false;
                core.NavigationStarting += (sender, args) => { args.Cancel = args.Uri != Page; };
                core.FrameNavigationStarting += (sender, args) => { args.Cancel = true; };
                core.NewWindowRequested += (sender, args) => { args.Handled = true; };
                core.PermissionRequested += (sender, args) => { args.State = CoreWebView2PermissionState.Deny; };
                core.DownloadStarting += (sender, args) => { args.Cancel = true; };
                core.WebMessageReceived += MessageReceived;
                core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
                core.WebResourceRequested += Resource;
                core.Navigate(Page);
            }
            catch (Exception)
            {
                if (!closing) MessageBox.Show(this, "Install or repair Microsoft Edge WebView2 Runtime and reopen iPlex.",
                                              Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        async void MessageReceived(object sender, CoreWebView2WebMessageReceivedEventArgs args)
        {
            if (closing || args.Source != Page || args.WebMessageAsJson.Length > 16000) return;
            try
            {
                var request = WindowsMediaService.Map(WindowsMediaService.Json().DeserializeObject(args.WebMessageAsJson));
                // The shared Windows player sends only seek/begin/release using the existing envelope.
                object body;
                if (request.TryGetValue("body", out body))
                    request = WindowsMediaService.Map(body);
                string action = WindowsMediaService.Str(request, "action");
                if (action == "icon")
                {
                    string choice = WindowsMediaService.Str(request, "choice");
                    if (choice == "groove" || choice == "prism" || choice == "signal" || choice == "clickwheel")
                        UseIcon(choice);
                }
                else if (action == "openFloatingPlayer" || action == "closeFloatingPlayer")
                    BeginInvoke(new Action(() => { if (!closing) SetFloatingPlayer(action == "openFloatingPlayer"); }));
                else if (action == "dragFloatingPlayer")
                    BeginInvoke(new Action(() => { if (!closing && floatingPlayer) DragFloatingPlayer(); }));
                else await media.Handle(request);
            }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
        }

        static string Type(string path)
        {
            switch (Path.GetExtension(path))
            {
                case ".html": return "text/html; charset=utf-8";
                case ".js": return "text/javascript; charset=utf-8";
                case ".css": return "text/css; charset=utf-8";
                case ".png": return "image/png";
                case ".ico": return "image/x-icon";
                default: return "application/octet-stream";
            }
        }

        async void Resource(object sender, CoreWebView2WebResourceRequestedEventArgs args)
        {
            var pending = args.GetDeferral();
            var environment = view.CoreWebView2.Environment;
            try
            {
                var uri = new Uri(args.Request.Uri);
                var path = uri.AbsolutePath;
                var method = args.Request.Method;
                if (uri.Scheme == "https" && uri.IsDefaultPort && uri.Host == "musicroom.invalid" && uri.Query.Length == 0)
                {
                    byte[] data;
                    if ((method == "GET" || method == "HEAD") && assets.TryGetValue(path, out data))
                    {
                        args.Response = environment.CreateWebResourceResponse(method == "HEAD" ? null : new MemoryStream(data, false),
                            200, "OK", "Content-Type: " + Type(path) + "\r\nX-Content-Type-Options: nosniff");
                        return;
                    }
                    if (path.StartsWith("/art/", StringComparison.Ordinal) && view.Source != null && view.Source.AbsoluteUri == Page)
                    {
                        var cover = await media.Artwork(path.Substring(5), method);
                        if (!closing) args.Response = environment.CreateWebResourceResponse(cover.Content, cover.Status, cover.Reason, cover.Headers);
                        else cover.Content.Dispose();
                        return;
                    }
                }
                if (uri.Host == "media.musicroom.invalid" && view.Source != null && view.Source.AbsoluteUri == Page)
                {
                    string range = args.Request.Headers.Contains("Range") ? args.Request.Headers.GetHeader("Range") : null;
                    var track = await media.OpenAsync(uri, method, range);
                    if (!closing) args.Response = environment.CreateWebResourceResponse(track.Content, track.Status, track.Reason, track.Headers);
                    else track.Content.Dispose();
                    return;
                }
                args.Response = environment.CreateWebResourceResponse(null, 404, "Not Found", "");
            }
            catch (Exception)
            {
                if (!closing) args.Response = environment.CreateWebResourceResponse(null, 503, "Unavailable", "");
            }
            finally
            {
                try { pending.Complete(); }
                catch (InvalidOperationException) { if (!closing) throw; }
                catch (System.Runtime.InteropServices.COMException) { if (!closing) throw; }
            }
        }

        async void Emit(string callback, object data)
        {
            if (closing || callback.IndexOfAny(new[] { '\'', '"', '\\' }) >= 0) return;
            var json = WindowsMediaService.Json();
            try { await view.CoreWebView2.ExecuteScriptAsync("window[" + json.Serialize(callback) + "]?.(" +
                         json.Serialize(data).Replace("\u2028", "\\u2028").Replace("\u2029", "\\u2029") + ")"); }
            catch (Exception) { }
        }
    }
}
