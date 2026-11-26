using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace MusicRoom
{
    internal sealed partial class MusicWindow
    {
        bool floatingPlayer;
        bool libraryTopMost;
        int libraryWindowStyle;
        Rectangle libraryBounds, floatingBounds;
        FormWindowState libraryWindowState;

        const int WindowStyleIndex = -16;
        const int LibraryFrame = 0x00CF0000; // Caption, resize frame, system menu, and minimize/maximize buttons.
        const uint FrameChanged = 0x0020;
        const uint KeepPositionSizeAndZOrder = 0x0017;

        void SetFloatingPlayer(bool enabled)
        {
            if (floatingPlayer == enabled) return;
            SuspendLayout();
            try
            {
                if (enabled)
                {
                    libraryWindowState = WindowState;
                    libraryBounds = libraryWindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
                    libraryTopMost = TopMost;
                    var workArea = Screen.FromControl(this).WorkingArea;
                    var scale = DeviceDpi / 96.0;
                    var width = Math.Min(workArea.Width, (int)Math.Ceiling(390 * scale));
                    var height = Math.Min(workArea.Height, (int)Math.Ceiling(454 * scale));
                    var origin = floatingBounds.IntersectsWith(workArea) ? floatingBounds.Location :
                        new Point(workArea.Right - width - 24, workArea.Top + 24);

                    // Clip the existing WebView to the smaller shell without resizing
                    // its browser surface or interrupting its player.
                    floatingPlayer = true;
                    WindowState = FormWindowState.Normal;
                    MinimumSize = Size.Empty;
                    libraryWindowStyle = GetWindowLong(Handle, WindowStyleIndex);
                    ApplyWindowStyle(libraryWindowStyle & ~LibraryFrame);
                    SetBounds(
                        Math.Max(workArea.Left, Math.Min(origin.X, workArea.Right - width)),
                        Math.Max(workArea.Top, Math.Min(origin.Y, workArea.Bottom - height)),
                        width, height);
                    UpdateFloatingRegion();
                    TopMost = true;
                    Text = "iPlex — Now Playing";
                }
                else
                {
                    floatingBounds = Bounds;
                    TopMost = libraryTopMost;
                    ApplyWindowStyle(libraryWindowStyle);
                    MinimumSize = new Size(780, 530);
                    Bounds = libraryBounds;
                    WindowState = libraryWindowState;
                    floatingPlayer = false;
                    Region = null;
                    FitLibraryWebView();
                    Text = "iPlex";
                }
            }
            finally { ResumeLayout(); }
        }

        // Changing FormBorderStyle can recreate the HWND and dispose the WebView2 controller.
        // Refresh only the non-client frame so the existing page and audio session survive.
        void ApplyWindowStyle(int style)
        {
            var window = Handle;
            SetWindowLong(window, WindowStyleIndex, style);
            SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0, FrameChanged | KeepPositionSizeAndZOrder);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (floatingPlayer) UpdateFloatingRegion();
        }

        void UpdateFloatingRegion()
        {
            var diameter = Math.Min(60f * DeviceDpi / 96f, Math.Min(Width, Height));
            if (diameter <= 0) return;
            using (var path = new GraphicsPath())
            {
                path.AddArc(0, 0, diameter, diameter, 180, 90);
                path.AddArc(Width - diameter, 0, diameter, diameter, 270, 90);
                path.AddArc(Width - diameter, Height - diameter, diameter, diameter, 0, 90);
                path.AddArc(0, Height - diameter, diameter, diameter, 90, 90);
                path.CloseFigure();
                Region = new Region(path);
            }
        }

        void DragFloatingPlayer()
        {
            ReleaseCapture();
            SendMessage(Handle, 0x00A1, new IntPtr(2), IntPtr.Zero);
        }

        [DllImport("user32.dll")]
        static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        static extern int GetWindowLong(IntPtr window, int index);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
        static extern int SetWindowLong(IntPtr window, int index, int value);

        [DllImport("user32.dll")]
        static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    }
}
