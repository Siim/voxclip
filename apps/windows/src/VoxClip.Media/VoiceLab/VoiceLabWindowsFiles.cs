using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace VoxClip.Media.VoiceLab;

internal static class VoiceLabWindowsFiles
{
    internal const uint MoveWriteThrough = 0x00000008;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool MoveFileExW(string existing, string destination, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);

    internal static string FinalPath(SafeFileHandle handle)
    {
        var text = new StringBuilder(32768);
        var length = GetFinalPathNameByHandleW(handle, text, (uint)text.Capacity, 0);
        if (length == 0 || length >= text.Capacity) throw new IOException("Cannot resolve Voice Lab storage path");
        var path = text.ToString();
        if (path.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase)) return "\\\\" + path[8..];
        return path.StartsWith("\\\\?\\", StringComparison.Ordinal) ? path[4..] : path;
    }
}
