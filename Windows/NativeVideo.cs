using System;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

namespace MusicRoom
{
    internal sealed class NativeVideoRuntime
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr LoadLibraryEx(string path, IntPtr reserved, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
        static extern IntPtr GetProcAddress(IntPtr module, string name);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr New(int count, IntPtr args);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Release(IntPtr item);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr CreatePlayer(IntPtr instance);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr CreateMedia(IntPtr instance, IntPtr url);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void SetPointer(IntPtr player, IntPtr value);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int IntValue(IntPtr player);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate long LongValue(IntPtr player);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void SetLong(IntPtr player, long value);

        internal readonly New Create;
        internal readonly Release ReleaseInstance, ReleasePlayer, ReleaseMedia, Pause, Stop;
        internal readonly CreatePlayer Player;
        internal readonly CreateMedia Media;
        internal readonly SetPointer SetMedia, Window;
        internal readonly IntValue Play, State, Seekable;
        internal readonly LongValue Time, Length;
        internal readonly SetLong Seek;
        static NativeVideoRuntime shared;

        internal static NativeVideoRuntime Load()
        {
            if (shared == null) shared = new NativeVideoRuntime();
            return shared;
        }

        NativeVideoRuntime()
        {
            string architecture = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
            string arch = IntPtr.Size == 4 ? "x86" :
                String.Equals(architecture, "ARM64", StringComparison.OrdinalIgnoreCase) ? "arm64" : "x64";
            string root = Extract(arch);
            Environment.SetEnvironmentVariable("VLC_PLUGIN_PATH", Path.Combine(root, "plugins"));
            // Search the DLL's own directory and Windows system directories for native dependencies.
            var module = LoadLibraryEx(Path.Combine(root, "libvlc.dll"), IntPtr.Zero, 0x0100 | 0x0800);
            if (module == IntPtr.Zero) throw new InvalidOperationException("Couldn’t load the native video engine.");
            Create = Bind<New>(module, "libvlc_new");
            ReleaseInstance = Bind<Release>(module, "libvlc_release");
            Player = Bind<CreatePlayer>(module, "libvlc_media_player_new");
            ReleasePlayer = Bind<Release>(module, "libvlc_media_player_release");
            Media = Bind<CreateMedia>(module, "libvlc_media_new_location");
            ReleaseMedia = Bind<Release>(module, "libvlc_media_release");
            SetMedia = Bind<SetPointer>(module, "libvlc_media_player_set_media");
            Window = Bind<SetPointer>(module, "libvlc_media_player_set_hwnd");
            Play = Bind<IntValue>(module, "libvlc_media_player_play");
            Pause = Bind<Release>(module, "libvlc_media_player_pause");
            Stop = Bind<Release>(module, "libvlc_media_player_stop");
            State = Bind<IntValue>(module, "libvlc_media_player_get_state");
            Seekable = Bind<IntValue>(module, "libvlc_media_player_is_seekable");
            Time = Bind<LongValue>(module, "libvlc_media_player_get_time");
            Length = Bind<LongValue>(module, "libvlc_media_player_get_length");
            Seek = Bind<SetLong>(module, "libvlc_media_player_set_time");
        }

        static T Bind<T>(IntPtr module, string name) where T : class
        {
            var symbol = GetProcAddress(module, name);
            if (symbol == IntPtr.Zero) throw new EntryPointNotFoundException(name);
            return (T)(object)Marshal.GetDelegateForFunctionPointer(symbol, typeof(T));
        }

        static string Extract(string arch)
        {
            using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("Desktop.VLC-" + arch + ".zip"))
            using (var sha = SHA256.Create())
            {
                if (resource == null) throw new InvalidOperationException("The native video package is missing.");
                string hash = BitConverter.ToString(sha.ComputeHash(resource)).Replace("-", "");
                string parent = Path.Combine(DesktopBootstrap.Profile, "Runtime");
                string root = Path.Combine(parent, "VLC-" + hash);
                if (Directory.Exists(root)) return root;
                Directory.CreateDirectory(parent);
                string temporary = root + "." + Guid.NewGuid().ToString("N");
                Directory.CreateDirectory(temporary);
                try
                {
                    resource.Position = 0;
                    using (var archive = new ZipArchive(resource, ZipArchiveMode.Read))
                    {
                        foreach (var entry in archive.Entries)
                        {
                            string path = Path.GetFullPath(Path.Combine(temporary, entry.FullName));
                            if (!path.StartsWith(temporary + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                                !path.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                                throw new InvalidDataException("Invalid native video package path.");
                            Directory.CreateDirectory(Path.GetDirectoryName(path));
                            using (var input = entry.Open())
                            using (var output = File.Create(path)) input.CopyTo(output);
                        }
                    }
                    try { Directory.Move(temporary, root); }
                    catch (IOException) { if (!Directory.Exists(root)) throw; }
                }
                finally { if (Directory.Exists(temporary)) Directory.Delete(temporary, true); }
                return root;
            }
        }

        internal static IntPtr Utf8(string value)
        {
            var bytes = Encoding.UTF8.GetBytes(value + "\0");
            var address = Marshal.AllocHGlobal(bytes.Length);
            Marshal.Copy(bytes, 0, address, bytes.Length);
            return address;
        }
    }

    internal sealed class NativeVideoWindow : Form
    {
        readonly Uri source;
        readonly Action<string, double> completion;
        readonly NativeVideoRuntime vlc;
        readonly Panel surface = new Panel { BackColor = Color.Black, Dock = DockStyle.Fill };
        readonly Button toggle = new Button { Text = "Pause", Width = 85 };
        readonly TrackBar timeline = new TrackBar { Maximum = 1000, TickStyle = TickStyle.None, Width = 260, Enabled = false };
        readonly Label elapsed = new Label { AutoSize = true, ForeColor = Color.White, Padding = new Padding(4, 9, 4, 0) };
        readonly Timer clock = new Timer { Interval = 250 };
        IntPtr instance, player;
        DateTime deadline;
        long position, duration;
        bool ready, scrubbing, stopping;
        string result = "closed";

        internal NativeVideoWindow(Uri source, string title, Action<string, double> completion)
        {
            this.source = source;
            this.completion = completion;
            vlc = NativeVideoRuntime.Load();
            Text = title;
            StartPosition = FormStartPosition.CenterParent;
            Size = new Size(1024, 680);
            MinimumSize = new Size(640, 360);
            BackColor = Color.FromArgb(22, 22, 24);
            var controls = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 52, Padding = new Padding(8, 5, 8, 3) };
            var previous = new Button { Text = "−10 s", Width = 65 };
            var next = new Button { Text = "+10 s", Width = 65 };
            var fallback = new Button { Text = "Compatibility Mode", Width = 155 };
            controls.Controls.AddRange(new Control[] { previous, toggle, next, timeline, elapsed, fallback });
            Controls.Add(surface);
            Controls.Add(controls);
            toggle.Click += delegate { TogglePlayback(); };
            previous.Click += delegate { SetPosition(position - 10000); };
            next.Click += delegate { SetPosition(position + 10000); };
            fallback.Click += delegate { result = "fallback"; Close(); };
            timeline.MouseDown += delegate { scrubbing = true; };
            timeline.MouseUp += delegate { scrubbing = false; ApplyTimeline(); };
            timeline.KeyUp += delegate { ApplyTimeline(); };
            clock.Tick += delegate { Poll(); };
            Shown += delegate { Start(); };
        }

        void Start()
        {
            try
            {
                string[] flags = { "--quiet", "--no-interact", "--no-plugins-cache", "--no-video-title-show" };
                var values = Array.ConvertAll(flags, NativeVideoRuntime.Utf8);
                IntPtr argv = Marshal.AllocHGlobal(values.Length * IntPtr.Size);
                try
                {
                    Marshal.Copy(values, 0, argv, values.Length);
                    instance = vlc.Create(values.Length, argv);
                }
                finally
                {
                    Marshal.FreeHGlobal(argv);
                    foreach (var value in values) Marshal.FreeHGlobal(value);
                }
                if (instance == IntPtr.Zero) throw new InvalidOperationException();
                player = vlc.Player(instance);
                if (player == IntPtr.Zero) throw new InvalidOperationException();
                IntPtr url = NativeVideoRuntime.Utf8(source.AbsoluteUri);
                IntPtr media;
                try { media = vlc.Media(instance, url); }
                finally { Marshal.FreeHGlobal(url); }
                if (media == IntPtr.Zero) throw new InvalidOperationException();
                vlc.SetMedia(player, media);
                vlc.ReleaseMedia(media);
                vlc.Window(player, surface.Handle);
                if (vlc.Play(player) != 0) throw new InvalidOperationException();
                deadline = DateTime.UtcNow.AddSeconds(30);
                clock.Start();
            }
            catch (Exception) { result = "failed"; Close(); }
        }

        void Poll()
        {
            int state = vlc.State(player);
            ready = ready || state == 3 || state == 4 || state == 6;
            if (state == 7 || (!ready && DateTime.UtcNow >= deadline))
            {
                result = "failed";
                Close();
                return;
            }
            long time = vlc.Time(player);
            if (time >= 0) position = time;
            duration = Math.Max(0, vlc.Length(player));
            if (state == 6 && duration > 0) position = duration;
            timeline.Enabled = duration > 0 && vlc.Seekable(player) != 0;
            if (!scrubbing && duration > 0)
                timeline.Value = (int)Math.Min(timeline.Maximum, position * timeline.Maximum / duration);
            elapsed.Text = ready ? Format(position) + " / " + Format(duration) : "Opening video…";
            toggle.Text = state == 3 ? "Pause" : "Play";
            toggle.Enabled = ready;
        }

        static string Format(long milliseconds)
        {
            var value = TimeSpan.FromMilliseconds(milliseconds);
            return value.TotalHours >= 1 ? value.ToString(@"h\:mm\:ss") : value.ToString(@"m\:ss");
        }

        void TogglePlayback()
        {
            if (!ready) return;
            if (vlc.State(player) == 3) vlc.Pause(player);
            else vlc.Play(player);
        }

        void ApplyTimeline()
        {
            if (timeline.Enabled) SetPosition(duration * timeline.Value / timeline.Maximum);
        }

        void SetPosition(long value)
        {
            if (timeline.Enabled) vlc.Seek(player, Math.Max(0, Math.Min(duration, value)));
        }

        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            if (keyData == Keys.Escape) { Close(); return true; }
            return base.ProcessCmdKey(ref message, keyData);
        }

        protected override void OnFormClosing(FormClosingEventArgs args)
        {
            ReleasePlayback();
            base.OnFormClosing(args);
        }

        protected override void OnFormClosed(FormClosedEventArgs args)
        {
            base.OnFormClosed(args);
            completion(result, position / 1000.0);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) ReleasePlayback();
            base.Dispose(disposing);
        }

        void ReleasePlayback()
        {
            if (stopping) return;
            stopping = true;
            clock.Dispose();
            if (player != IntPtr.Zero)
            {
                vlc.Stop(player);
                vlc.ReleasePlayer(player);
                player = IntPtr.Zero;
            }
            if (instance != IntPtr.Zero)
            {
                vlc.ReleaseInstance(instance);
                instance = IntPtr.Zero;
            }
        }
    }
}
