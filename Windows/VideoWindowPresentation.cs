using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace MusicRoom
{
    internal enum VideoWindowMode { Inline, Fullscreen, Floating }

    internal sealed class VideoWindowPresentation
    {
        const int StyleIndex = -16;
        const int WindowFrame = 0x00CF0000;
        const int SystemCommand = 0x0112;
        const int ReturnToPlayer = 0x10A0;
        const int ToggleOnTop = 0x10B0;

        readonly Form window;
        FormWindowState normalState;
        Rectangle normalBounds, floatingBounds;
        Size normalMinimum;
        bool normalTopMost;
        int normalStyle;
        string normalTitle;
        bool keepOnTop = true;

        internal VideoWindowMode Mode { get; private set; }

        internal VideoWindowPresentation(Form window) { this.window = window; }

        internal void SetMode(VideoWindowMode mode)
        {
            if (Mode == mode) return;
            var display = Screen.FromControl(window);
            window.SuspendLayout();
            try
            {
                if (Mode == VideoWindowMode.Inline)
                {
                    normalState = window.WindowState;
                    normalBounds = normalState == FormWindowState.Normal ? window.Bounds : window.RestoreBounds;
                    normalMinimum = window.MinimumSize;
                    normalTopMost = window.TopMost;
                    normalTitle = window.Text;
                    window.WindowState = FormWindowState.Normal;
                    normalStyle = GetWindowLong(window.Handle, StyleIndex);
                }
                if (Mode == VideoWindowMode.Floating)
                {
                    floatingBounds = window.WindowState == FormWindowState.Normal ? window.Bounds : window.RestoreBounds;
                    var menu = GetSystemMenu(window.Handle, false);
                    DeleteMenu(menu, ReturnToPlayer, 0);
                    DeleteMenu(menu, ToggleOnTop, 0);
                }

                Mode = mode;
                window.WindowState = FormWindowState.Normal;
                window.MinimumSize = Size.Empty;
                if (mode == VideoWindowMode.Fullscreen)
                {
                    ApplyStyle(normalStyle & ~WindowFrame);
                    window.TopMost = true;
                    window.Bounds = display.Bounds;
                }
                else if (mode == VideoWindowMode.Floating)
                {
                    ApplyStyle(normalStyle);
                    var area = display.WorkingArea;
                    var scale = window.DeviceDpi / 96.0;
                    int width = Math.Min(area.Width, (int)Math.Ceiling(480 * scale));
                    int height = Math.Min(area.Height, (int)Math.Ceiling(310 * scale));
                    window.MinimumSize = new Size((int)(260 * scale), (int)(170 * scale));
                    window.Bounds = area.Contains(floatingBounds) && !floatingBounds.IsEmpty ? floatingBounds :
                        new Rectangle(area.Right - width - 20, area.Top + 20, width, height);
                    window.TopMost = keepOnTop;
                    window.Text = "iPlex · Picture in Picture";
                    var menu = GetSystemMenu(window.Handle, false);
                    AppendMenu(menu, 0, ReturnToPlayer, "Return to Player");
                    AppendMenu(menu, keepOnTop ? 8u : 0u, ToggleOnTop, "Keep on Top");
                }
                else
                {
                    ApplyStyle(normalStyle);
                    window.MinimumSize = normalMinimum;
                    window.Bounds = normalBounds;
                    window.WindowState = normalState;
                    window.TopMost = normalTopMost;
                    window.Text = normalTitle;
                }
            }
            finally { window.ResumeLayout(); }
        }

        internal bool HandleSystemCommand(Message message, Action restore)
        {
            if (message.Msg != SystemCommand || Mode != VideoWindowMode.Floating) return false;
            int command = message.WParam.ToInt32() & 0xFFF0;
            if (command == ReturnToPlayer) restore();
            else if (command == ToggleOnTop)
            {
                keepOnTop = !keepOnTop;
                window.TopMost = keepOnTop;
                CheckMenuItem(GetSystemMenu(window.Handle, false), ToggleOnTop, keepOnTop ? 8u : 0u);
            }
            else return false;
            return true;
        }

        // Preserve the HWND used by the video surface when removing the window frame.
        void ApplyStyle(int style)
        {
            var handle = window.Handle;
            SetWindowLong(handle, StyleIndex, style);
            SetWindowPos(handle, IntPtr.Zero, 0, 0, 0, 0, 0x0037);
        }

        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        static extern int GetWindowLong(IntPtr handle, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
        static extern int SetWindowLong(IntPtr handle, int index, int value);
        [DllImport("user32.dll")]
        static extern bool SetWindowPos(IntPtr handle, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")]
        static extern IntPtr GetSystemMenu(IntPtr handle, bool revert);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool AppendMenu(IntPtr menu, uint flags, int id, string title);
        [DllImport("user32.dll")]
        static extern bool DeleteMenu(IntPtr menu, int id, uint flags);
        [DllImport("user32.dll")]
        static extern uint CheckMenuItem(IntPtr menu, int id, uint flags);
    }
}
