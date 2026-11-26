using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace MusicRoom
{
    internal sealed class VideoWatchStore : IDisposable
    {
        internal const string Dll = "iPlexSQLite3.dll";

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr LoadLibraryEx(string path, IntPtr reserved, uint flags);

        internal static void Load(string path)
        {
            if (LoadLibraryEx(path, IntPtr.Zero, 0x0100 | 0x0800) == IntPtr.Zero)
                throw new InvalidOperationException("The video library database engine could not load.");
        }
        static readonly IntPtr Transient = new IntPtr(-1);
        IntPtr db;

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_open(byte[] path, out IntPtr db);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_close(IntPtr db);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr callback, IntPtr context, IntPtr error);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int bytes, out IntPtr statement, IntPtr tail);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_bind_text(IntPtr statement, int index, byte[] value, int bytes, IntPtr destructor);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_step(IntPtr statement);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_finalize(IntPtr statement);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_column_bytes(IntPtr statement, int column);

        internal VideoWatchStore(string folder)
        {
            try
            {
                if (sqlite3_open(Utf8(Path.Combine(folder, "VideoLibrary.sqlite")), out db) != 0 ||
                    sqlite3_exec(db, Utf8("CREATE TABLE IF NOT EXISTS watch_state (" +
                        "server_id TEXT NOT NULL, library_id TEXT NOT NULL, item_id TEXT NOT NULL, " +
                        "updated_at INTEGER NOT NULL, watched INTEGER NOT NULL, payload TEXT NOT NULL, " +
                        "PRIMARY KEY(server_id, library_id, item_id));"), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0)
                    Dispose();
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        }

        static byte[] Utf8(string value) { return Encoding.UTF8.GetBytes(value + "\0"); }

        void Statement(string sql, Action<IntPtr> action, params string[] parameters)
        {
            if (db == IntPtr.Zero) return;
            IntPtr statement;
            if (sqlite3_prepare_v2(db, Utf8(sql), -1, out statement, IntPtr.Zero) != 0) return;
            try
            {
                for (int index = 0; index < parameters.Length; index++)
                {
                    if (sqlite3_bind_text(statement, index + 1, Utf8(parameters[index]), -1, Transient) != 0) return;
                }
                action(statement);
            }
            finally { sqlite3_finalize(statement); }
        }

        internal void Save(string server, string library, string item, bool watched, string payload)
        {
            Statement("INSERT OR REPLACE INTO watch_state SELECT ?, ?, ?, strftime('%s','now'), ?, ? " +
                "WHERE ? = '1' OR NOT EXISTS (SELECT 1 FROM watch_state WHERE server_id = ? AND library_id = ? AND item_id = ? AND watched = 1)",
                statement => sqlite3_step(statement),
                server, library, item, watched ? "1" : "0", payload, watched ? "1" : "0", server, library, item);
        }

        internal void Clear(string server, string library, string item)
        {
            Statement("DELETE FROM watch_state WHERE server_id = ? AND library_id = ? AND item_id = ?",
                statement => sqlite3_step(statement), server, library, item);
        }

        internal HashSet<string> WatchedIds(string server, string library)
        {
            var result = new HashSet<string>();
            Statement("SELECT item_id FROM watch_state WHERE server_id = ? AND library_id = ? AND watched = 1",
                statement =>
                {
                    while (sqlite3_step(statement) == 100)
                    {
                        var pointer = sqlite3_column_text(statement, 0);
                        if (pointer != IntPtr.Zero) result.Add(Marshal.PtrToStringAnsi(pointer));
                    }
                }, server, library);
            return result;
        }

        internal List<object> Records(string server, string library)
        {
            var result = new List<object>();
            Statement("SELECT payload FROM watch_state WHERE server_id = ? AND library_id = ? ORDER BY updated_at DESC, rowid DESC LIMIT 2000",
                statement =>
                {
                    while (sqlite3_step(statement) == 100)
                    {
                        var pointer = sqlite3_column_text(statement, 0);
                        int length = sqlite3_column_bytes(statement, 0);
                        if (length <= 0 || length > 8192 || pointer == IntPtr.Zero) continue;
                        var bytes = new byte[length];
                        Marshal.Copy(pointer, bytes, 0, length);
                        try { result.Add(WindowsMediaService.Json().DeserializeObject(Encoding.UTF8.GetString(bytes))); }
                        catch (ArgumentException) { }
                    }
                }, server, library);
            return result;
        }

        public void Dispose()
        {
            if (db != IntPtr.Zero)
            {
                sqlite3_close(db);
                db = IntPtr.Zero;
            }
        }
    }
}
