using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Frames;

namespace VoxClip.Cli;

internal sealed class HarnessProject
{
    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
    private readonly string path;
    private readonly string id;

    private HarnessProject(string path, string id) { this.path = path; this.id = id; }

    internal static async Task<HarnessProject> OpenAsync(string path, CancellationToken ct)
    {
        path = HarnessInbox.CanonicalLocalPath(path, allowLinks: true);
        return new(path, (await ReadAsync(path, ct).ConfigureAwait(false)).Id);
    }

    internal async Task<HarnessResult> CallAsync(HarnessTool tool, JsonElement arguments, CancellationToken ct)
    {
        var project = await ReadAsync(path, ct).ConfigureAwait(false);
        if (project.Id != id) throw new HarnessException("The selected project changed. Restart the connection.");
        if (tool == HarnessTool.ProposeTimeline && arguments.ValueKind == JsonValueKind.Object && arguments.TryGetProperty("revises", out _))
            throw new HarnessException("Revising is only for the in-app chat.");
        var result = await HarnessTools.Call(tool, arguments, project, null, path, decodeFrames: HarnessFrameDecoder.Decode, chat: false, ct: ct).ConfigureAwait(false);
        if (result.Proposal is { } proposal) await StageAsync(proposal, ct).ConfigureAwait(false);
        return result;
    }

    private static async Task<Project> ReadAsync(string path, CancellationToken ct)
    {
        if (!string.Equals(Path.GetExtension(path), ".voxclip", StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(path, HarnessInbox.CanonicalLocalPath(path, allowLinks: false), PathComparison) ||
            (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.Device)) != 0)
            throw new HarnessException("Choose a saved .voxclip project file.");
        return ProjectSerialization.Deserialize(await File.ReadAllTextAsync(path, new UTF8Encoding(false, true), ct).ConfigureAwait(false));
    }

    private async Task StageAsync(JsonObject proposal, CancellationToken ct)
    {
        var destination = path + ".proposal.json";
        var bytes = JsonSerializer.SerializeToUtf8Bytes(proposal, HarnessCommands.JsonOptions);
        if (bytes.Length > HarnessProposal.MaximumBytes) throw new HarnessException("This timeline proposal is too large.");
        var temporary = Path.Join(Path.GetDirectoryName(path), $".voxclip-proposal-{Guid.NewGuid():N}");
        var options = new FileStreamOptions { Access = FileAccess.Write, Mode = FileMode.CreateNew, Options = FileOptions.Asynchronous };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        var stream = new FileStream(temporary, options);
        try
        {
            await using (stream.ConfigureAwait(false)) await stream.WriteAsync(bytes, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            if (OperatingSystem.IsWindows()) File.Move(temporary, destination, overwrite: false);
            else if (Link(temporary, destination) != 0)
                throw new IOException("Can't publish the proposal next to the project.");
        }
        catch (IOException) when (Path.Exists(destination))
        {
            throw new HarnessException("Review the pending timeline in VoxClip before sending another.");
        }
        finally { File.Delete(temporary); }
    }

    [DllImport("libc", EntryPoint = "link")]
    private static extern int Link([MarshalAs(UnmanagedType.LPUTF8Str)] string source, [MarshalAs(UnmanagedType.LPUTF8Str)] string destination);
}
