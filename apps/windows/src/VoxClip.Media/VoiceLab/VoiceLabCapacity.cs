using System.Runtime.InteropServices;
using System.Text;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

/// <summary>Checks the peak temporary and output bytes before any paid snapshot is copied.</summary>
internal static class VoiceLabCapacity
{
    // Scoped to the calling async flow so tests can reject at the real preparation boundary.
    internal static readonly AsyncLocal<Func<string, long>?> AvailableBytes = new();
    internal static readonly AsyncLocal<Func<string, string>?> VolumeIdentity = new();
    internal readonly record struct Allocation(string Path, long Bytes);

    internal static long Bytes(long count, long multiplier, long overhead = 0)
    {
        try { return checked(count * multiplier + overhead); }
        catch (OverflowException)
        {
            throw new VoxClipException(VoxClipErrorCode.DiskFull, "The Voice Lab output is too large for this volume. Your edits are saved.");
        }
    }

    internal static Allocation Rollback(string destination)
        => new(destination, File.Exists(destination) ? new FileInfo(destination).Length : 0);

    internal static void VerifySource(ComposeSnapshot snapshot)
    {
        if (snapshot.VoiceLab is not { } input) return;
        var reference = input.IsolatedProject().Media.Source;
        if (File.Exists(snapshot.Media.Path) && new FileInfo(snapshot.Media.Path).Length != reference.SizeBytes)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
    }

    internal static void Require(ComposeSnapshot snapshot, params Allocation[] outputs)
        => Require(snapshot, Path.GetTempPath(), outputs);

    internal static void Require(ComposeSnapshot snapshot, string scratchRoot, params Allocation[] outputs)
    {
        if (snapshot.VoiceLab is not { Prepared.OutputPlan.RequiresSyntheticRendering: true } input) return;
        VerifySource(snapshot);
        var project = input.IsolatedProject();
        var allocations = new List<Allocation>(outputs);
        var temporary = scratchRoot;
        foreach (var item in input.Prepared.SelectedSegmentRecipes)
        {
            var asset = project.VoiceLab.Assets!.Single(asset => asset.Id == item.Recipe.Audio.AssetId);
            var path = Path.Combine(input.PaidRoot, project.Id, Path.GetFileName(asset.File));
            if (File.Exists(path)) allocations.Add(new(temporary, new FileInfo(path).Length));
            if (!VoiceLabTempo.RequiresFit(item.Recipe.Audio.Stretch)) continue;
            var audio = item.Recipe.Audio;
            var frames = (audio.TrimEnd - audio.TrimStart) * asset.SampleRate +
                item.Recipe.Seams.In.AssetHandleFrames + item.Recipe.Seams.Out.AssetHandleFrames;
            // A tempo graph can flush a bounded window beyond the nominal fitted count.
            var fitted = Math.Ceiling(frames * audio.Stretch) + 4096;
            if (!double.IsFinite(fitted) || fitted <= 0 || fitted > (long.MaxValue / 8d))
                throw new VoxClipException(VoxClipErrorCode.DiskFull, "The Voice Lab audio stage is too large for this volume. Your edits are saved.");
            allocations.Add(new(temporary, checked((long)fitted * 8)));
        }
        Require(allocations);
    }

    internal static void Require(IEnumerable<Allocation> allocations)
    {
        var grouped = new Dictionary<string, long>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        try
        {
            foreach (var allocation in allocations)
            {
                if (allocation.Bytes < 0) throw new OverflowException();
                var root = Volume(allocation.Path);
                grouped[root] = checked(grouped.GetValueOrDefault(root) + allocation.Bytes);
            }
        }
        catch (OverflowException)
        {
            throw new VoxClipException(VoxClipErrorCode.DiskFull, "The Voice Lab output is too large for this volume. Your edits are saved.");
        }
        foreach (var (root, bytes) in grouped)
            if ((AvailableBytes.Value?.Invoke(root) ?? FreeSpace(root)) < bytes)
                throw new VoxClipException(VoxClipErrorCode.DiskFull,
                    "There is not enough free space for the Voice Lab audio and output stages. Your edits are saved.");
    }

    private static long FreeSpace(string root)
    {
        if (!OperatingSystem.IsWindows()) return new DriveInfo(root).AvailableFreeSpace;
        if (!GetDiskFreeSpaceEx(root, out var available, out _, out _))
            throw new IOException("The output volume is unavailable.");
        return (long)Math.Min(available, long.MaxValue);
    }

    private static string Volume(string path)
    {
        var full = Path.GetFullPath(path);
        if (VolumeIdentity.Value is { } overrideIdentity) return overrideIdentity(full);
        if (OperatingSystem.IsWindows())
        {
            var name = new StringBuilder(32768);
            if (!GetVolumePathName(full, name, name.Capacity))
                throw new IOException("The output volume is unavailable.");
            var mount = name.ToString();
            // A drive letter and a mounted folder can name the same filesystem.
            // The volume GUID groups their allocations against one free-space pool.
            if (mount.StartsWith(@"\\", StringComparison.Ordinal)) return mount;
            var identity = new StringBuilder(64);
            if (!GetVolumeNameForVolumeMountPoint(mount, identity, identity.Capacity))
                throw new IOException("The output volume identity is unavailable.");
            return identity.ToString();
        }
        var comparison = OperatingSystem.IsMacOS() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return DriveInfo.GetDrives().Select(drive => drive.Name).Where(name =>
            full.Equals(name.TrimEnd(Path.DirectorySeparatorChar), comparison) ||
            full.StartsWith(name.EndsWith(Path.DirectorySeparatorChar) ? name : name + Path.DirectorySeparatorChar,
                comparison)).OrderByDescending(name => name.Length).FirstOrDefault()
            ?? throw new IOException("The output volume is unavailable.");
    }

    [DllImport("kernel32.dll", EntryPoint = "GetVolumePathNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumePathName(string fileName, StringBuilder volumeName, int length);

    [DllImport("kernel32.dll", EntryPoint = "GetVolumeNameForVolumeMountPointW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeNameForVolumeMountPoint(string mountPoint, StringBuilder volumeName, int length);

    [DllImport("kernel32.dll", EntryPoint = "GetDiskFreeSpaceExW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetDiskFreeSpaceEx(string directory, out ulong available, out ulong total,
        out ulong free);
}
