using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace ToolDriveOffline
{
    internal sealed class ArchiveWindow : Form
    {
        private const string Page = "https://archive.tooldrive.invalid/index.html";
        private readonly WebView2 view = new WebView2();
        private readonly Dictionary<string, byte[]> assets = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        private readonly SavedStore saved;
        private readonly WindowsMediaService media;
        private readonly string startupWarning;
        private Catalog catalog;
        private string catalogJson;
        private CancellationTokenSource catalogCheck;
        private bool ready, closing;
        private string appearanceJson;
        private Icon selectedIcon;

        internal Action<object> TransportChanged;

        internal ArchiveWindow(Catalog initialCatalog, string warning)
        {
            catalog = initialCatalog;
            catalogJson = CatalogUpdater.Serializer().Serialize(catalog);
            saved = new SavedStore(catalog.shows);
            startupWarning = warning ?? saved.Warning;
            Text = "Tool Drive Offline";
            TopLevel = false;
            FormBorderStyle = FormBorderStyle.None;
            BackColor = view.DefaultBackgroundColor = Color.FromArgb(19, 19, 23);
            view.Dock = DockStyle.Fill;
            Controls.Add(view);
            using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("Desktop.ToolDrive.site.zip"))
            using (ZipArchive zip = new ZipArchive(source, ZipArchiveMode.Read))
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    if (entry.Name.Length == 0) continue;
                    using (Stream stream = entry.Open())
                    using (MemoryStream buffer = new MemoryStream())
                    {
                        stream.CopyTo(buffer);
                        assets.Add("/" + entry.FullName, buffer.ToArray());
                    }
                }
            SetIcon("multicolor");
            media = new WindowsMediaService(DesktopBootstrap.Profile, () => catalogJson, Emit);
            media.GetLosslessDecoder = () =>
            {
                bool arm = String.Equals(Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE"), "ARM64", StringComparison.OrdinalIgnoreCase)
                    || String.Equals(Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432"), "ARM64", StringComparison.OrdinalIgnoreCase);
                string arch = Environment.Is64BitOperatingSystem && !arm ? "x64" : "x86";
                return DesktopBootstrap.Materialize("Lossless-" + arch + ".exe", "Lossless.exe");
            };
            media.OpenOriginalFolder = (uri, sourceID) => new OriginalDownloadWindow(uri, sourceID, media).Show(this);
            Shown += async delegate { await StartWebView(); };
            FormClosing += delegate { closing = true; if (catalogCheck != null) catalogCheck.Cancel(); };
            FormClosed += delegate { media.Dispose(); if (selectedIcon != null) selectedIcon.Dispose(); };
        }

        private async Task StartWebView()
        {
            try
            {
                CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(DesktopBootstrap.Profile, "WebView"), null);
                if (closing) return;
                await view.EnsureCoreWebView2Async(environment);
                if (closing) return;
                CoreWebView2 core = view.CoreWebView2;
                core.Settings.AreHostObjectsAllowed = false;
                core.Settings.IsStatusBarEnabled = false;
                core.Settings.IsZoomControlEnabled = false;
                core.Settings.AreBrowserAcceleratorKeysEnabled = false;
                core.Settings.AreDefaultContextMenusEnabled = false;
                core.Settings.IsBuiltInErrorPageEnabled = false;
                core.NavigationStarting += (s, e) => { e.Cancel = !IsArchivePage(e.Uri); };
                core.FrameNavigationStarting += (s, e) => { e.Cancel = true; };
                core.NewWindowRequested += (s, e) => { e.Handled = true; };
                core.PermissionRequested += (s, e) => { e.State = CoreWebView2PermissionState.Deny; };
                core.DownloadStarting += (s, e) => { e.Cancel = true; };
                core.Settings.AreDevToolsEnabled = false;
                core.WebMessageReceived += MessageReceived;
                core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
                core.WebResourceRequested += ResourceRequested;
                if (appearanceJson != null)
                    await core.AddScriptToExecuteOnDocumentCreatedAsync("window.initialIPlexArchiveAppearance = " + appearanceJson);
                if (!closing) core.Navigate(Page);
            }
            catch (Exception error)
            {
                if (closing) return;
                string message = "The archive window could not start. Install or repair Microsoft Edge WebView2 Runtime, then reopen the app.";
                if (!(error is WebView2RuntimeNotFoundException)) message += "\r\n\r\n" + error.Message;
                MessageBox.Show(this, message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
                Close();
            }
        }

        internal void PausePlayback()
        {
            Script("window.windowsPlayback?.action({action:'pause'})");
        }

        private static bool IsArchivePage(string value)
        {
            Uri uri;
            return Uri.TryCreate(value, UriKind.Absolute, out uri) && uri.GetLeftPart(UriPartial.Path) == Page && uri.Query.Length == 0;
        }

        private static bool ReduceTransparency()
        {
            if (SystemInformation.HighContrast) return true;
            try { return Object.Equals(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "EnableTransparency", 1), 0); }
            catch (System.Security.SecurityException) { return false; }
        }

        private async void ResourceRequested(object sender, CoreWebView2WebResourceRequestedEventArgs e)
        {
            CoreWebView2Deferral pending = e.GetDeferral();
            try
            {
                Uri uri = new Uri(e.Request.Uri);
                string method = e.Request.Method;
                if (uri.Scheme == "https" && uri.IsDefaultPort && uri.Host == "archive.tooldrive.invalid" && (method == "GET" || method == "HEAD"))
                {
                    byte[] bytes;
                    if (assets.TryGetValue(uri.AbsolutePath, out bytes))
                    {
                        string mime = "application/octet-stream";
                        switch (Path.GetExtension(uri.AbsolutePath))
                        {
                            case ".html": mime = "text/html; charset=utf-8"; break;
                            case ".css": mime = "text/css"; break;
                            case ".js": mime = "text/javascript"; break;
                            case ".jpg": mime = "image/jpeg"; break;
                            case ".png": mime = "image/png"; break;
                            case ".ico": mime = "image/x-icon"; break;
                            case ".json": mime = "application/json"; break;
                        }
                        if (uri.AbsolutePath == "/index.html" && method == "GET")
                        {
                            string layoutWarning;
                            var initial = new { saved = saved.Ids.ToArray(), columnWidths = ColumnLayoutStore.Load(out layoutWarning), catalog = CatalogCache.LastCheckedUtc.HasValue ? catalog : null, reduceTransparency = ReduceTransparency() };
                            string html = System.Text.Encoding.UTF8.GetString(bytes);
                            const string marker = "<!--windows-initial-->";
                            if (!html.Contains(marker)) throw new InvalidDataException("The Windows catalog page is incomplete.");
                            string initialJson = CatalogUpdater.Serializer().Serialize(initial).Replace("<", "\\u003c").Replace(">", "\\u003e").Replace("\u2028", "\\u2028").Replace("\u2029", "\\u2029");
                            bytes = System.Text.Encoding.UTF8.GetBytes(html.Replace(marker, "<script>window.toolWindowsInitial=" + initialJson + ";</script>"));
                        }
                        e.Response = view.CoreWebView2.Environment.CreateWebResourceResponse(method == "HEAD" ? null : new MemoryStream(bytes, false), 200, "OK", "Content-Type: " + mime + "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff");
                        return;
                    }
                }
                if (uri.Scheme == "https" && uri.IsDefaultPort && uri.Host == "media.tooldrive.invalid" && !closing && IsArchivePage(view.Source.AbsoluteUri))
                {
                    string range = e.Request.Headers.Contains("Range") ? e.Request.Headers.GetHeader("Range") : null;
                    WindowsMediaResponse result = await media.OpenAsync(uri, method, range);
                    if (!closing) e.Response = view.CoreWebView2.Environment.CreateWebResourceResponse(result.Content, result.Status, result.Reason, result.Headers);
                    else if (result.Content != null) result.Content.Dispose();
                    return;
                }
                e.Response = view.CoreWebView2.Environment.CreateWebResourceResponse(null, 404, "Not Found", "");
            }
            catch (Exception) { if (!closing) e.Response = view.CoreWebView2.Environment.CreateWebResourceResponse(null, 503, "Unavailable", ""); }
            finally
            {
                try { pending.Complete(); }
                catch (InvalidOperationException) { if (!closing) throw; }
                catch (System.Runtime.InteropServices.COMException) { if (!closing) throw; }
            }
        }

        private async void MessageReceived(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            if (closing || !IsArchivePage(e.Source)) return;
            try
            {
                string json = e.WebMessageAsJson;
                if (json.Length > 1024 * 1024) return;
                var message = CatalogUpdater.Serializer().Deserialize<Dictionary<string, object>>(json);
                object field, body;
                if (message == null || !message.TryGetValue("channel", out field)) return;
                message.TryGetValue("body", out body);
                string channel = field as string;
                switch (channel)
                {
                    case "ready":
                        if (ready) return;
                        ready = true;
                        if (appearanceJson != null) Script("window.applyIPlexArchiveAppearance?.(" + appearanceJson + ")");
                        if (startupWarning != null) Notice(startupWarning);
                        UpdateState("app", "Managed in iPlex Settings.", "Check now", false, false);
                        await UpdateCatalog();
                        break;
                    case "iplexTransport":
                        if (TransportChanged != null) TransportChanged(body);
                        break;
                    case "updates":
                        if (body as string == "app") UpdateState("app", "Check for updates in iPlex Settings.", "Check now", false, false);
                        if (body as string == "catalog") await UpdateCatalog();
                        break;
                    case "saved":
                        var list = body as System.Collections.IList;
                        if (list == null || list.Count > 50000) return;
                        var valid = new HashSet<string>(StringComparer.Ordinal);
                        foreach (object item in list)
                        {
                            long id; if (!Int64.TryParse(item as string, NumberStyles.None, CultureInfo.InvariantCulture, out id) || id < 1) return;
                            valid.Add(id.ToString(CultureInfo.InvariantCulture));
                        }
                        saved.Ids = valid; saved.Persist(); if (saved.Warning != null) Notice(saved.Warning);
                        break;
                    case "columns":
                        var columns = body as Dictionary<string, object>;
                        if (columns == null) return;
                        var widths = new Dictionary<string, int>();
                        foreach (var pair in columns) if (pair.Value is int) widths[pair.Key] = (int)pair.Value;
                        string warning; if (!ColumnLayoutStore.Save(widths, out warning)) Notice(warning);
                        break;
                    case "appIcon": SetIcon(body as string); break;
                    case "live": case "library": case "download": case "player": case "plex":
                        var args = body as Dictionary<string, object>;
                        if (args != null) await media.HandleAsync(channel, args);
                        break;
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception) { Notice("That action could not finish. Please try again."); }
        }

        private void SetIcon(string id)
        {
            byte[] bytes;
            if (String.IsNullOrEmpty(id) || !assets.TryGetValue("/icons/" + id + ".ico", out bytes)) return;
            using (MemoryStream stream = new MemoryStream(bytes))
            using (Icon icon = new Icon(stream, 32, 32))
            {
                Icon previous = selectedIcon;
                Icon = selectedIcon = (Icon)icon.Clone();
                if (previous != null) previous.Dispose();
            }
        }

        internal void TransportAction(Dictionary<string, object> request)
        {
            Script("window.iplexArchiveTransport?.(" + CatalogUpdater.Serializer().Serialize(request) + ")");
        }

        internal void SetAppearance(object settings)
        {
            string json = CatalogUpdater.Serializer().Serialize(settings);
            if (json == appearanceJson) return;
            appearanceJson = json;
            Script("window.applyIPlexArchiveAppearance?.(" + json + ")");
        }

        private async void Script(string script)
        {
            if (closing || !ready) return;
            if (InvokeRequired)
            {
                try { BeginInvoke(new Action<string>(Script), script); } catch (InvalidOperationException) { }
                return;
            }
            if (view.CoreWebView2 == null) return;
            try { await view.CoreWebView2.ExecuteScriptAsync(script); }
            catch (Exception) { /* The page may have closed during dispatch. */ }
        }
        private void Emit(string callback, object state)
        {
            Script("window[" + CatalogUpdater.Serializer().Serialize(callback) + "]?.(" + CatalogUpdater.Serializer().Serialize(state) + ")");
        }
        private void Notice(string text)
        {
            if (!String.IsNullOrEmpty(text)) Script("document.dispatchEvent(new CustomEvent('windowsHostNotice',{detail:" + CatalogUpdater.Serializer().Serialize(text) + "}))");
        }
        private void UpdateState(string kind, string text, string button, bool busy, bool staged)
        {
            Script("window.macUpdateState?.apply(null," + CatalogUpdater.Serializer().Serialize(new object[] {kind, text, button, busy, staged}) + ")");
        }
        private async Task UpdateCatalog()
        {
            if (catalogCheck != null) { catalogCheck.Cancel(); return; }
            using (var cts = catalogCheck = new CancellationTokenSource())
            {
                try
                {
                    UpdateState("catalog", "Checking the public catalog…", "Cancel", true, false);
                    var result = await CatalogUpdater.CheckAsync(catalog, cts.Token);
                    cts.Token.ThrowIfCancellationRequested();
                    if (closing) return;
                    CatalogCache.Save(result.Catalog, result.CheckedAtUtc);
                    catalog = result.Catalog; catalogJson = CatalogUpdater.Serializer().Serialize(catalog);
                    Emit("applyMacCatalog", catalog);
                    UpdateState("catalog", result.Changes.Summary, "Check now", false, false);
                }
                catch (OperationCanceledException) { UpdateState("catalog", "Check canceled.", "Check now", false, false); }
                catch (Exception) { UpdateState("catalog", "Could not update. Your offline catalog is available.", "Try again", false, false); }
                finally { catalogCheck = null; }
            }
        }
    }
}
