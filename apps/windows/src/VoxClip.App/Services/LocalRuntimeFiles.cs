using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace VoxClip.App.Services;

internal static class LocalRuntimeFiles
{
    internal static Version? ReadVersion(string name)
    {
        var module = GetModuleHandle(name);
        var borrowed = module != 0;
        if (!borrowed) module = LoadLibraryEx(name, 0, 0x1000);
        if (module == 0) return null;
        try
        {
            var filename = new StringBuilder(32768);
            if (GetModuleFileName(module, filename, filename.Capacity) == 0) return null;
            var version = FileVersionInfo.GetVersionInfo(filename.ToString());
            return new(version.FileMajorPart, version.FileMinorPart, version.FileBuildPart, version.FilePrivatePart);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
        finally { if (!borrowed) FreeLibrary(module); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetModuleHandleW")]
    private static extern nint GetModuleHandle(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "LoadLibraryExW")]
    private static extern nint LoadLibraryEx(string name, nint file, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetModuleFileNameW")]
    private static extern uint GetModuleFileName(nint module, StringBuilder filename, int size);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeLibrary(nint module);
}
