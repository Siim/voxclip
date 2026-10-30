using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace VoxClip.Media.VoiceLab;

internal sealed record VoiceLabFileIdentity(string Platform, ulong Device, ulong Index, long BirthSeconds, uint BirthNanoseconds);

internal static class VoiceLabPartialFiles
{
    internal static SafeFileHandle Open(string path, bool delete = false)
    {
        SafeFileHandle handle;
        if (OperatingSystem.IsWindows())
            handle = CreateFileW(path, delete ? 0x10080u : 0x80000000u, FileShare.Read | FileShare.Write,
                IntPtr.Zero, FileMode.Open, 0x00200000, IntPtr.Zero);
        else
        {
            var descriptor = OpenUnix(path, OperatingSystem.IsMacOS() ? 0x1000104 : 0xA0800);
            handle = new SafeFileHandle((IntPtr)descriptor, true);
        }
        if (handle.IsInvalid) { handle.Dispose(); throw Failure(); }
        try { _ = Identity(handle); return handle; }
        catch { handle.Dispose(); throw; }
    }

    internal static VoiceLabFileIdentity Identity(SafeFileHandle handle)
    {
        if (OperatingSystem.IsWindows())
        {
            if (!GetFileInformationByHandle(handle, out var value)) throw Failure();
            if ((value.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || value.Links != 1)
                throw new IOException("Voice Lab partial is not a regular, unlinked file");
            return new("windows", value.Volume, ((ulong)value.IndexHigh << 32) | value.IndexLow, 0, 0);
        }
        if (OperatingSystem.IsMacOS())
        {
            var result = RuntimeInformation.ProcessArchitecture == Architecture.X64
                ? FStatDarwin64(handle, out var value) : FStatDarwin(handle, out value);
            if (result != 0) throw Failure();
            RequireRegular(value.Mode, value.Links);
            return new("darwin", value.Device, value.Index, value.BirthSeconds, checked((uint)value.BirthNanoseconds));
        }
        if (OperatingSystem.IsLinux())
        {
            if (StatX(handle, "", 0x1000, 0xFFF, out var value) != 0 || (value.Mask & 0x800) == 0) throw Failure();
            RequireRegular(value.Mode, value.Links);
            return new("linux", ((ulong)value.DeviceMajor << 32) | value.DeviceMinor, value.Index, value.BirthSeconds, value.BirthNanoseconds);
        }
        throw new PlatformNotSupportedException("Voice Lab partial identity is unavailable");
    }

    private static void RequireRegular(ushort mode, uint links)
    {
        if ((mode & 0xF000) != 0x8000 || links != 1) throw new IOException("Voice Lab partial is not a regular, unlinked file");
    }

    internal static bool Delete(string path, VoiceLabFileIdentity expected)
    {
        if (!OperatingSystem.IsWindows()) return false;
        using var handle = Open(path, delete: true);
        if (Identity(handle) != expected) return false;
        byte disposition = 1;
        if (!SetFileInformationByHandle(handle, 4, ref disposition, sizeof(byte))) throw Failure();
        return true;
    }

    private static IOException Failure() => new("Cannot inspect or reclaim Voice Lab partial", new Win32Exception(Marshal.GetLastPInvokeError()));

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowsInformation
    {
        internal FileAttributes Attributes;
        internal uint CreatedLow, CreatedHigh, AccessedLow, AccessedHigh, WrittenLow, WrittenHigh;
        internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    [StructLayout(LayoutKind.Explicit, Size = 144)]
    private struct DarwinInformation
    {
        [FieldOffset(0)] internal uint Device;
        [FieldOffset(4)] internal ushort Mode;
        [FieldOffset(6)] internal ushort Links;
        [FieldOffset(8)] internal ulong Index;
        [FieldOffset(80)] internal long BirthSeconds;
        [FieldOffset(88)] internal long BirthNanoseconds;
    }

    [StructLayout(LayoutKind.Explicit, Size = 256)]
    private struct LinuxInformation
    {
        [FieldOffset(0)] internal uint Mask;
        [FieldOffset(16)] internal uint Links;
        [FieldOffset(28)] internal ushort Mode;
        [FieldOffset(32)] internal ulong Index;
        [FieldOffset(80)] internal long BirthSeconds;
        [FieldOffset(88)] internal uint BirthNanoseconds;
        [FieldOffset(136)] internal uint DeviceMajor;
        [FieldOffset(140)] internal uint DeviceMinor;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, FileShare share, IntPtr security, FileMode disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out WindowsInformation information);
    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, ref byte information, int size);
    [DllImport("libc", EntryPoint = "open", SetLastError = true)]
    private static extern int OpenUnix([MarshalAs(UnmanagedType.LPUTF8Str)] string path, int flags);
    [DllImport("libc", EntryPoint = "fstat", SetLastError = true)]
    private static extern int FStatDarwin(SafeFileHandle handle, out DarwinInformation information);
    [DllImport("libc", EntryPoint = "fstat$INODE64", SetLastError = true)]
    private static extern int FStatDarwin64(SafeFileHandle handle, out DarwinInformation information);
    [DllImport("libc", EntryPoint = "statx", SetLastError = true)]
    private static extern int StatX(SafeFileHandle handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, int flags, uint mask, out LinuxInformation information);
}
