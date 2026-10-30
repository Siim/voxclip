using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32.SafeHandles;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

internal sealed record VoiceLabPartialOwner(int ProcessId, long StartTicks)
{
    internal static VoiceLabPartialOwner Current()
    {
        using var process = Process.GetCurrentProcess();
        return new(process.Id, process.StartTime.ToUniversalTime().Ticks);
    }

    internal bool IsDefinitelyGone()
    {
        try
        {
            using var process = Process.GetProcessById(ProcessId);
            return process.HasExited || process.StartTime.ToUniversalTime().Ticks != StartTicks;
        }
        catch (ArgumentException) { return true; }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or NotSupportedException) { return false; }
    }
}

internal sealed record VoiceLabPartialEntry(int Version, string Name, VoiceLabPartialOwner Owner, VoiceLabFileIdentity Identity);

internal sealed class VoiceLabPartialJournal(string path, VoiceLabPartialEntry entry, string journalPath, VoiceLabFileIdentity journalIdentity)
{
    internal const string Folder = ".asset-partials";

    internal static VoiceLabPartialJournal Register(string path, SafeFileHandle handle, VoiceLabPartialOwner? owner = null)
    {
        var identity = VoiceLabPartialFiles.Identity(handle);
        var directory = Path.Combine(Path.GetDirectoryName(path)!, Folder);
        VoiceLabAssetStore.RequireDirectory(directory, Path.GetFileName(path), true);
        using var lease = VoiceLabAssetStore.HoldDirectory(directory, Path.GetFileName(path));
        var name = Path.GetFileName(path);
        if (!CanonicalName(name, Path.GetFileName(Path.GetDirectoryName(path)!))) throw new IOException("Invalid Voice Lab partial name");
        var entry = new VoiceLabPartialEntry(1, name, owner ?? VoiceLabPartialOwner.Current(), identity);
        var journalPath = Path.Combine(directory, name + ".json");
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.ReadWrite, Share = FileShare.None, Options = FileOptions.WriteThrough };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        VoiceLabFileIdentity journalIdentity;
        using (var stream = new FileStream(journalPath, options))
        {
            journalIdentity = VoiceLabPartialFiles.Identity(stream.SafeFileHandle);
            JsonSerializer.Serialize(stream, entry, VoiceLabPartialJson.Default.VoiceLabPartialEntry);
            stream.Flush(true);
        }
        return new(path, entry, journalPath, journalIdentity);
    }

    internal void Complete(bool deletePartial)
    {
        var directory = Path.GetDirectoryName(journalPath)!;
        VoiceLabAssetStore.RequireDirectory(directory, entry.Name, false);
        using var lease = VoiceLabAssetStore.HoldDirectory(directory, entry.Name);
        if (deletePartial)
        {
            try { _ = VoiceLabPartialFiles.Delete(path, entry.Identity, directory); }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
        _ = VoiceLabPartialFiles.Delete(journalPath, journalIdentity, directory);
    }

    internal static int Sweep(string projectDirectory)
    {
        var directory = Path.Combine(projectDirectory, Folder);
        if (!Directory.Exists(directory) && new DirectoryInfo(directory).LinkTarget is null) return 0;
        VoiceLabAssetStore.RequireDirectory(directory, Folder, false);
        using var lease = VoiceLabAssetStore.HoldDirectory(directory, Folder);
        var removed = 0;
        foreach (var journalPath in Directory.EnumerateFiles(directory, "*.json"))
        {
            try
            {
                VoiceLabPartialEntry? entry;
                VoiceLabFileIdentity journalIdentity;
                using (var handle = VoiceLabPartialFiles.Open(journalPath))
                using (var stream = new FileStream(handle, FileAccess.Read))
                {
                    journalIdentity = VoiceLabPartialFiles.Identity(handle);
                    if (stream.Length > 4096) continue;
                    entry = JsonSerializer.Deserialize(stream, VoiceLabPartialJson.Default.VoiceLabPartialEntry);
                }
                if (entry is null || entry.Version != 1 || entry.Owner is null || entry.Identity is null ||
                    entry.Owner.ProcessId <= 0 || entry.Owner.StartTicks <= 0 || !CanonicalName(entry.Name, Path.GetFileName(projectDirectory)) ||
                    Path.GetFileName(journalPath) != entry.Name + ".json") continue;
                if (!entry.Owner.IsDefinitelyGone()) continue;
                var partial = Path.Combine(projectDirectory, entry.Name);
                var matches = false;
                try
                {
                    using var handle = VoiceLabPartialFiles.Open(partial);
                    matches = VoiceLabPartialFiles.Identity(handle) == entry.Identity;
                }
                catch (IOException) { }
                if (matches)
                {
                    if (VoiceLabPartialFiles.Delete(partial, entry.Identity, directory)) removed++;
                }
                _ = VoiceLabPartialFiles.Delete(journalPath, journalIdentity, directory);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        }
        return removed;
    }

    private static bool CanonicalName(string? name, string projectId)
    {
        if (name is null || !name.StartsWith('.') || !name.EndsWith(".partial", StringComparison.Ordinal) || Path.GetFileName(name) != name) return false;
        var body = name[1..^8];
        var separator = body.LastIndexOf('.');
        if (separator < 0 || !Guid.TryParseExact(body[(separator + 1)..], "N", out _)) return false;
        var target = body[..separator];
        if (!target.EndsWith(".wav", StringComparison.Ordinal)) return false;
        try { return Path.GetFileName(VoiceLabAssetNaming.File(projectId, target[..^4], "wav")) == target; }
        catch (Exception error) when (error is ArgumentException or VoiceLabProjectException) { return false; }
    }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow)]
[JsonSerializable(typeof(VoiceLabPartialEntry))]
internal sealed partial class VoiceLabPartialJson : JsonSerializerContext;
