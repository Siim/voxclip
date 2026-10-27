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

    [StructLayout(LayoutKind.Sequential)]
    private struct AttributeTagInformation
    {
        internal FileAttributes Attributes;
        internal uint ReparseTag;
    }

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass,
        out AttributeTagInformation information, uint size);

    internal static FileAttributes Attributes(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandleEx(handle, 9, out var information, (uint)Marshal.SizeOf<AttributeTagInformation>()))
            throw new IOException("Cannot inspect Voice Lab storage directory");
        return information.Attributes;
    }

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
