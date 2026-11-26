using System.Text.Json;

namespace VoxClip.Core.Services.Project;

/// <summary>The one pending timeline sidecar beside a saved project.</summary>
public static class HarnessInbox
{
    /// <summary>Reads and validates the sidecar envelope without changing either file.</summary>
    public static HarnessProposal? Read(string projectPath)
    {
        var full = Path.GetFullPath(projectPath);
        if (OperatingSystem.IsWindows() && !IsLocalWindowsPath(full)) return null;
        try { return ReadSidecar(CanonicalLocalPath(full, allowLinks: true) + ".proposal.json"); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    private static HarnessProposal? ReadSidecar(string path)
    {
        try
        {
            if ((File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) != 0)
                throw new HarnessException("This timeline proposal can't be read.");
            using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            if (stream.Length > HarnessProposal.MaximumBytes) throw new HarnessException("This timeline proposal is too large.");
            var bytes = new byte[checked((int)stream.Length + 1)];
            var count = stream.ReadAtLeast(bytes, bytes.Length, false);
            if (count == bytes.Length) throw new HarnessException("This timeline proposal changed while VoxClip was reading it.");
            using var json = JsonDocument.Parse(bytes.AsMemory(0, count));
            return HarnessProposal.Read(json.RootElement);
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or FormatException)
        { throw new HarnessException("This timeline proposal can't be read."); }
    }

    /// <summary>Consumes only the proposal the editor actually reviewed.</summary>
    public static void Dismiss(HarnessProposal proposal, string projectPath) => Resolve(proposal, null, projectPath);

    /// <summary>Atomically replace the reviewed sidecar with the timelines still pending, or dismiss it.</summary>
    public static void Resolve(HarnessProposal proposal, HarnessProposal? remaining, string projectPath)
    {
        var path = CanonicalLocalPath(projectPath, allowLinks: true) + ".proposal.json";
        if (!proposal.Matches(ReadSidecar(path))) throw new HarnessException("The pending timeline changed. Review it again.");
        if (remaining is null) { File.Delete(path); return; }
        var temporary = path + $".{Guid.NewGuid():N}.tmp";
        try
        {
            var options = new FileStreamOptions { Access = FileAccess.Write, Mode = FileMode.CreateNew };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var stream = new FileStream(temporary, options))
            using (var writer = new Utf8JsonWriter(stream)) remaining.ToJson().WriteTo(writer);
            if (!proposal.Matches(ReadSidecar(path))) throw new HarnessException("The pending timeline changed. Review it again.");
            File.Move(temporary, path, overwrite: true);
        }
        finally { File.Delete(temporary); }
    }

    /// <summary>Resolve the local project or source path, rejecting links when rechecking a previously pinned path.</summary>
    public static string CanonicalLocalPath(string path, bool allowLinks) => Resolve(path, allowLinks, 32);

    private static string Resolve(string path, bool allowLinks, int remainingLinks)
    {
        var full = Path.GetFullPath(path);
        if (OperatingSystem.IsWindows() && !IsLocalWindowsPath(full))
            throw new HarnessException("Choose a local path for the project and its source video.");
        var root = Path.GetPathRoot(full)!;
        var current = root;
        foreach (var component in full[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Join(current, component);
            var attributes = File.GetAttributes(current);
            if ((attributes & FileAttributes.ReparsePoint) == 0) continue;
            if (!allowLinks || remainingLinks == 0)
                throw new HarnessException("The selected file changed. Restart the connection or relink the source.");
            FileSystemInfo info = (attributes & FileAttributes.Directory) != 0 ? new DirectoryInfo(current) : new FileInfo(current);
            current = info.ResolveLinkTarget(returnFinalTarget: false) is { } target
                ? Resolve(target.FullName, allowLinks, --remainingLinks) : throw new HarnessException("Choose a saved .voxclip project file.");
        }
        return current;
    }

    private static bool IsLocalWindowsPath(string full) => Path.GetPathRoot(full) is { Length: 3 } root &&
        char.IsAsciiLetter(root[0]) && root[1] == ':' && !full.AsSpan(2).Contains(':') &&
        new DriveInfo(root).DriveType is DriveType.Fixed or DriveType.Removable or DriveType.Ram;
}
