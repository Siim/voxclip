using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Pipeline;

internal static class OutputSafety
{
    internal static readonly AsyncLocal<Action<string>?> BeforePartialOpen = new();
    internal static bool SameFile(string first, string second)
    {
        var comparison = OperatingSystem.IsWindows() || OperatingSystem.IsMacOS()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (string.Equals(Resolve(first), Resolve(second), comparison)) return true;
        if (!OperatingSystem.IsWindows() || !File.Exists(first) || !File.Exists(second)) return false;
        using var firstHandle = File.OpenHandle(first, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var secondHandle = File.OpenHandle(second, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (!GetFileInformationByHandle(firstHandle, out var firstInfo) || !GetFileInformationByHandle(secondHandle, out var secondInfo))
            throw new IOException("The output file identity could not be verified.");
        return firstInfo.Volume == secondInfo.Volume && firstInfo.IndexHigh == secondInfo.IndexHigh && firstInfo.IndexLow == secondInfo.IndexLow;
    }

    internal static void Validate(IEnumerable<string> protectedPaths, IEnumerable<string> destinations)
    {
        var originals = protectedPaths.ToArray();
        var outputs = destinations.Select(Resolve).SelectMany(path => new[] { path, path + ".partial" }).ToArray();
        foreach (var destination in outputs.Where((_, index) => index % 2 == 0)) ValidateDestination(destination);
        foreach (var partial in outputs.Where((_, index) => index % 2 == 1)) ValidatePartial(partial);
        for (var index = 0; index < outputs.Length; index++)
            if (originals.Any(path => SameFile(path, outputs[index])) || outputs.Take(index).Any(path => SameFile(path, outputs[index])))
                throw new VoxClipException(VoxClipErrorCode.ExportFailed,
                    "Output paths must not overwrite inputs or each other");
    }

    private static void ValidateDestination(string destination)
    {
        var fileName = Path.GetFileNameWithoutExtension(destination).TrimEnd(' ', '.');
        var reserved = OperatingSystem.IsWindows() && (destination.StartsWith(@"\\.\", StringComparison.OrdinalIgnoreCase) ||
            fileName.Equals("CON", StringComparison.OrdinalIgnoreCase) ||
            fileName.Equals("PRN", StringComparison.OrdinalIgnoreCase) || fileName.Equals("AUX", StringComparison.OrdinalIgnoreCase) ||
            fileName.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
            fileName.Length == 4 && (fileName.StartsWith("COM", StringComparison.OrdinalIgnoreCase) || fileName.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) && fileName[3] is >= '1' and <= '9');
        if (reserved || Directory.Exists(destination) || File.Exists(destination) && !IsRegularFile(destination))
            throw new VoxClipException(VoxClipErrorCode.ExportFailed, "An output must be a file path, not a folder or special file");
        if (!Directory.Exists(Path.GetDirectoryName(destination)))
            throw new VoxClipException(VoxClipErrorCode.ExportFailed, $"The output folder does not exist for {destination}");
    }

    private static unsafe bool IsRegularFile(string path)
    {
        if (!OperatingSystem.IsMacOS()) return (File.GetAttributes(path) & FileAttributes.Device) == 0;
        var status = stackalloc byte[144];
        if (MacStat(path, status) != 0) throw new IOException("The output file type could not be verified.");
        return (*(ushort*)(status + 4) & 0xf000) == 0x8000;
    }

    [DllImport("libc", EntryPoint = "stat", SetLastError = true)]
    private static extern unsafe int MacStat([MarshalAs(UnmanagedType.LPUTF8Str)] string path, byte* status);

    internal static FileStream CreatePartial(string path)
    {
        ValidatePartial(path);
        File.Delete(path);
        BeforePartialOpen.Value?.Invoke(path);
        return new(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    }

    internal static void RequireCapacity(string destination, long additionalBytes, IEnumerable<string> rollbackDestinations)
    {
        if (additionalBytes < 0) throw new ArgumentOutOfRangeException(nameof(additionalBytes));
        var rollbackBytes = rollbackDestinations.Where(File.Exists).Sum(path => new FileInfo(path).Length);
        var needed = checked(additionalBytes + rollbackBytes);
        var root = Path.GetPathRoot(Resolve(destination)) ?? throw new IOException("The output volume is unavailable.");
        if (new DriveInfo(root).AvailableFreeSpace < needed)
            throw new VoxClipException(VoxClipErrorCode.ExportFailed,
                "Export stopped: there is not enough free space for the marked MP4 and its rollback copy. Your edits are saved.");
    }

    private static void ValidatePartial(string path)
    {
        if (Directory.Exists(path) || new FileInfo(path).LinkTarget is not null)
            throw new VoxClipException(VoxClipErrorCode.ExportFailed, "Choose a regular file for each .partial output; directories and links are not allowed.");
    }

    internal static void Publish(IReadOnlyList<string> destinations, Action<string, string>? move = null, CancellationToken ct = default,
        Action<string, string>? restore = null)
    {
        var backups = new Dictionary<string, string>();
        var retained = new HashSet<string>();
        var published = new List<string>();
        try
        {
            foreach (var destination in destinations)
            {
                ct.ThrowIfCancellationRequested();
                if (Directory.Exists(destination)) throw new IOException("The output destination is a directory.");
                if (!File.Exists(destination)) continue;
                var backup = destination + ".rollback-" + Guid.NewGuid().ToString("N");
                File.Copy(destination, backup);
                backups.Add(destination, backup);
            }
            foreach (var destination in destinations)
            {
                ct.ThrowIfCancellationRequested();
                if (File.Exists(destination) && (File.GetAttributes(destination) & FileAttributes.ReadOnly) != 0)
                    throw new UnauthorizedAccessException("The output destination is read-only.");
                if (move is null) File.Move(destination + ".partial", destination, true);
                else move(destination + ".partial", destination);
                published.Add(destination);
            }
        }
        catch (Exception publicationError)
        {
            var failures = new List<Exception>();
            var messages = new List<string>();
            foreach (var destination in published.AsEnumerable().Reverse())
            {
                backups.TryGetValue(destination, out var backup);
                try
                {
                    if (backup is null) File.Delete(destination);
                    else if (restore is null) File.Move(backup, destination, true);
                    else restore(backup, destination);
                    backups.Remove(destination);
                }
                catch (Exception restoreError)
                {
                    failures.Add(restoreError);
                    if (backup is not null)
                    {
                        retained.Add(backup);
                        messages.Add($"Couldn't put back {Path.GetFileName(destination)}. The previous version is saved as {Path.GetFileName(backup)}.");
                    }
                }
            }
            if (failures.Count > 0)
                throw new VoxClipException(VoxClipErrorCode.ExportFailed,
                    messages.Count > 0 ? string.Join(" ", messages) : "Export stopped: an output could not be removed. Your edits are saved.",
                    new AggregateException(new[] { publicationError }.Concat(failures)));
            throw;
        }
        finally
        {
            foreach (var backup in backups.Values.Where(backup => !retained.Contains(backup)))
            {
                try
                {
                    File.SetAttributes(backup, File.GetAttributes(backup) & ~FileAttributes.ReadOnly);
                    File.Delete(backup);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
            foreach (var destination in destinations) DeletePartial(destination + ".partial");
        }
    }

    internal static void DeletePartial(string path)
    {
        try { File.Delete(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    internal static string Resolve(string path)
    {
        var full = Path.GetFullPath(path);
        var resolved = Path.GetPathRoot(full)!;
        foreach (var component in full[resolved.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            resolved = Path.Combine(resolved, component);
            FileSystemInfo entry = Directory.Exists(resolved) ? new DirectoryInfo(resolved) : new FileInfo(resolved);
            if (entry.LinkTarget is not null)
                resolved = Resolve(entry.ResolveLinkTarget(true)?.FullName ?? throw new IOException("The output link could not be resolved."));
        }
        return Path.TrimEndingDirectorySeparator(resolved);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        internal uint Attributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Created;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Accessed;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Written;
        internal uint Volume;
        internal uint SizeHigh;
        internal uint SizeLow;
        internal uint Links;
        internal uint IndexHigh;
        internal uint IndexLow;
    }
}
