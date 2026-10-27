using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using ProjectModel = VoxClip.Core.Domain.Shared.Project;
using TranscriptModel = VoxClip.Core.Domain.Transcript.Transcript;
namespace VoxClip.Core.Services.Project;

/// <summary>Project load plus cleaned-reference warnings; editing §10.4.</summary>
public sealed record ProjectOpenResult(ProjectModel Project, string? ResolvedMediaPath, bool IsReadOnly, IReadOnlyList<string> Warnings);
/// <summary>Atomic project persistence and relinking boundary; editing §10.</summary>
public interface IProjectStore
{
    /// <summary>Load and validate; missing media never discards saved edits.</summary>
    Task<ProjectOpenResult> LoadAsync(string path, CancellationToken ct);
    /// <summary>Atomic UTF8 save, recomputing relativePath and writer identity.</summary>
    Task SaveAsync(ProjectModel project, string path, CancellationToken ct);
    /// <summary>Resolve source by absolute path, relative path, then explicit user relink.</summary>
    Task<string?> ResolveMediaAsync(MediaReference source, string projectPath, CancellationToken ct);
    /// <summary>Compute the shared content key, not a whole-file SHA256; architecture §8.1.</summary>
    Task<string> ComputeContentKeyAsync(string mediaPath, IProgress<double>? progress, CancellationToken ct);
}
/// <summary>Schema-v1 validation, reference cleanup, source resolution and atomic storage, editing §10.</summary>
public sealed class ProjectStore : IProjectStore
{
    private readonly SemaphoreSlim writer = new(1, 1);

    /// <summary>After consumer confirmation, replace words and clear transcript-dependent project data, editing §10.5.</summary>
    public static ProjectModel ReplaceTranscript(ProjectModel project, TranscriptModel transcript)
        => project with { Transcript = transcript, Edits = new(transcript.Refined ? 0.8 : 1.0, project.Edits.PauseKeepSeconds, [], [],
            new Dictionary<string, string>(StringComparer.Ordinal), [], null), Ai = new([]), Share = new(new Dictionary<string, string>(StringComparer.Ordinal)),
            VoiceLab = project.VoiceLab with { Segments = [] } };

    /// <inheritdoc />
    public async Task<ProjectOpenResult> LoadAsync(string path, CancellationToken ct)
    {
        try
        {
            var json = await AtomicFile.ReadAllTextAsync(path, new UTF8Encoding(false, true), ct).ConfigureAwait(false);
            ProjectValidation.Validate(json);
            var project = ProjectSerialization.Deserialize(json);
            var warnings = new List<string>();
            project = EditingProject.Clean(project, warnings);
            var resolved = await ResolveMediaAsync(project.Media.Source, path, ct).ConfigureAwait(false);
            if (resolved is not null) project = project with { Media = new(project.Media.Source with { AbsolutePath = resolved }) };
            return new(project, resolved, resolved is null, warnings);
        }
        catch (OperationCanceledException) { throw; }
        catch (VoxClipException) { throw; }
        catch (VoiceLabProjectException) { throw; }
        catch (Exception exception)
        {
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "This project file can't be read. Your media and saved edits are unchanged.", exception);
        }
    }
    /// <inheritdoc />
    public async Task SaveAsync(ProjectModel project, string path, CancellationToken ct)
    {
        await writer.WaitAsync(ct).ConfigureAwait(false);
        try { await SaveSnapshotAsync(project, path, ct).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    private static async Task SaveSnapshotAsync(ProjectModel project, string path, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        var source = project.Media.Source;
        var relative = RelativePath(directory, source.AbsolutePath);
        var assembly = Assembly.GetEntryAssembly() ?? typeof(ProjectStore).Assembly;
        var version = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
            ?? assembly.GetName().Version?.ToString(3) ?? "0.0.0";
        project = EditingProject.Clean(project, []);
        var referenced = project.Edits.Clips.Where(clip => clip.AiResultId is not null).Select(clip => clip.AiResultId).ToHashSet(StringComparer.Ordinal);
        var newest = project.Ai.Results.Select((result, index) => (result, index))
            .OrderByDescending(pair => pair.result.CreatedAt).ThenByDescending(pair => pair.index).Take(10).Select(pair => pair.result.Id).ToHashSet(StringComparer.Ordinal);
        project = project with { ModifiedAt = DateTimeOffset.UtcNow, SavedBy = new("VoxClip", version, OperatingSystem.IsWindows() ? "windows" : "macos"),
            Media = new(source with { RelativePath = relative }), Ai = new(project.Ai.Results.Where(result => referenced.Contains(result.Id) || newest.Contains(result.Id)).ToArray()) };
        var json = ProjectSerialization.Serialize(project);
        ProjectValidation.Validate(json);
        await AtomicFile.WriteAsync(path, json, ct).ConfigureAwait(false);
    }
    /// <inheritdoc />
    public async Task<string?> ResolveMediaAsync(MediaReference source, string projectPath, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        // Classify the project's full path, so a relative --open path probes like the absolute one (editing 10.3).
        string fullProjectPath;
        try { fullProjectPath = Path.GetFullPath(projectPath); }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
        var candidates = new List<string> { source.AbsolutePath };
        if (source.RelativePath is { } relative && RelativeCandidate(Path.GetDirectoryName(fullProjectPath)!, relative) is { } candidatePath)
            candidates.Add(candidatePath);
        foreach (var candidate in candidates)
        {
            ct.ThrowIfCancellationRequested();
            if (OperatingSystem.IsWindows() ? !CanAutoProbeMediaPath(candidate, fullProjectPath) : !Path.IsPathFullyQualified(candidate)) continue;
            try
            {
                var file = new FileInfo(candidate);
                if (file.Exists && file.Length == source.SizeBytes && await ComputeContentKeyAsync(candidate, null, ct).ConfigureAwait(false) == source.ContentKey) return file.FullName;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { }
        }
        return null;
    }
    /// <inheritdoc />
    public async Task<string> ComputeContentKeyAsync(string mediaPath, IProgress<double>? progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        await using var stream = new FileStream(mediaPath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.RandomAccess);
        var length = stream.Length;
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes("voxclip-source-v1\n" + length.ToString(CultureInfo.InvariantCulture) + "\n"));
        var whole = length < 2 * 1048576;
        var toHash = whole ? length : 2 * 1048576;
        long consumed = 0;
        var buffer = new byte[65536];
        progress?.Report(0);
        await Append(whole ? length : 1048576).ConfigureAwait(false);
        if (!whole) { stream.Position = length - 1048576; await Append(1048576).ConfigureAwait(false); }
        ct.ThrowIfCancellationRequested();
        progress?.Report(1);
        return Convert.ToHexStringLower(hash.GetHashAndReset());

        async Task Append(long remaining)
        {
            while (remaining > 0)
            {
                var count = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(remaining, buffer.Length)), ct).ConfigureAwait(false);
                if (count == 0) throw new IOException("The source changed while hashing.");
                hash.AppendData(buffer, 0, count);
                remaining -= count;
                consumed += count;
                progress?.Report((double)consumed / toHash);
            }
        }
    }

    internal static bool CanAutoProbeMediaPath(string candidate, string projectPath)
    {
        var candidateRoot = WindowsAutoProbeRoot(candidate);
        var projectRoot = WindowsAutoProbeRoot(projectPath);
        return candidateRoot is not null && projectRoot is not null &&
            (candidateRoot.Length == 3 || string.Equals(candidateRoot, projectRoot, StringComparison.OrdinalIgnoreCase));
    }

    private static string? WindowsAutoProbeRoot(string path)
    {
        path = path.Replace('/', '\\');
        if (path.Length >= 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '\\') return path[..3];
        if (!path.StartsWith(@"\\", StringComparison.Ordinal) || path.Length < 5 || path[2] is '?' or '.') return null;
        var serverEnd = path.IndexOf('\\', 2);
        if (serverEnd <= 2) return null;
        var shareEnd = path.IndexOf('\\', serverEnd + 1);
        return shareEnd > serverEnd + 1 ? path[..(shareEnd + 1)] : null;
    }

    private static string? RelativePath(string directory, string absolute)
    {
        if (!Path.IsPathFullyQualified(absolute)) return null;
        if (!string.Equals(Path.GetPathRoot(directory), Path.GetPathRoot(absolute), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) return null;
        var relative = Path.GetRelativePath(directory, absolute).Replace(Path.DirectorySeparatorChar, '/');
        return RelativeCandidate(directory, relative) is null ? null : relative;
    }

    private static string? RelativeCandidate(string directory, string relative)
    {
        if (relative.Length == 0 || relative[0] is '/' or '\\' || relative.Contains(':') || relative.Contains('\\') || Path.IsPathRooted(relative)) return null;
        try
        {
            var candidate = Path.GetFullPath(Path.Join(directory, relative.Replace('/', Path.DirectorySeparatorChar)));
            var resolved = Path.GetRelativePath(directory, candidate);
            return Path.IsPathRooted(resolved) ? null : candidate;
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or IOException) { return null; }
    }

}
