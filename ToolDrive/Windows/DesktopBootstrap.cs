using System;
using System.IO;

namespace ToolDriveOffline
{
    internal static class DesktopBootstrap
    {
        internal static readonly string Profile = Path.Combine(MusicRoom.DesktopBootstrap.Profile, "Tool Drive");
        internal static string Materialize(string resourceName, string fileName)
        {
            return MusicRoom.DesktopBootstrap.Materialize(resourceName, fileName);
        }
    }
}
