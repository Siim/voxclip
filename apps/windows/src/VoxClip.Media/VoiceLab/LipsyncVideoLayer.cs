using System.Security.Cryptography;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.VoiceLab;

internal sealed class LipsyncVideoLayer : IDisposable
{
    private sealed record Span(string Id, long Origin, long Start, long End);
    private readonly string folder;
    private readonly double rate;
    private readonly IReadOnlyList<Span> regions;
    private readonly IReadOnlyDictionary<string, string> files;
    private VideoDecoder? decoder;
    private string? current;

    private LipsyncVideoLayer(string folder, double rate, IReadOnlyList<Span> regions, IReadOnlyDictionary<string, string> files)
    { this.folder = folder; this.rate = rate; this.regions = regions; this.files = files; }

    internal static async Task<LipsyncVideoLayer?> PrepareAsync(VoiceLabRenderInput input, Project project, string scratchRoot, CancellationToken ct)
    {
        var synced = input.Prepared.SelectedSegmentRecipes.Where(item => item.Recipe.Video.Mode == VoiceLabVideoMode.Lipsync).ToArray();
        if (synced.Length == 0) return null;
        var plan = input.Prepared.OutputPlan;
        var story = plan.Scope.ClipId is { } id && project.Edits.Clips.Any(clip => clip.Id == id && clip.Parts is not null);
        var root = Path.Combine(scratchRoot, "lipsync-render-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(scratchRoot);
        VoiceConsentPrivacy.CreateDirectory(root);
        Dictionary<string, string> files = new(StringComparer.Ordinal);
        List<Span> spans = [];
        try
        {
            foreach (var item in synced)
            {
                var recipe = item.Recipe.Video;
                var asset = project.VoiceLab.VideoAssets?.SingleOrDefault(asset => asset.Id == recipe.AssetId) ?? throw Invalid();
                var range = LipsyncRenderWindow.SavedOutputRange(recipe.WindowStartSample!.Value, recipe.WindowEndSample!.Value, item.Piece, plan, story);
                if (range is null && story) continue;
                if (range is not { } mapped || Math.Abs((mapped.End - mapped.Start) / plan.SampleRate - asset.DurationSeconds) > 1 / asset.FrameRate + 1e-6)
                    throw Invalid();
                var (first, last) = mapped;
                var handle = (long)Math.Round(0.2 * plan.SampleRate, MidpointRounding.AwayFromZero);
                spans.Add(new(asset.Id, first, Math.Max(first, item.Piece.OutputStartSample - handle), Math.Min(last, item.Piece.OutputEndSample + handle)));
                if (files.ContainsKey(asset.Id)) continue;
                var source = Path.Combine(input.PaidRoot, asset.File);
                var destination = Path.Combine(root, files.Count + ".mp4");
                if ((File.GetAttributes(source) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw Invalid();
                await using (var read = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true))
                {
                    VoiceLabAssets.RequireWithinRoot(input.PaidRoot, source, read.SafeFileHandle, asset.File);
                    if (read.Length is < 1 or > FalLipsyncProvider.MaximumVideoBytes) throw Invalid();
                    await using var write = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true);
                    await read.CopyToAsync(write, ct).ConfigureAwait(false);
                }
                await using (var read = File.OpenRead(destination))
                    if (!string.Equals(Convert.ToHexStringLower(await SHA256.HashDataAsync(read, ct).ConfigureAwait(false)), asset.Sha256, StringComparison.Ordinal))
                        throw Invalid();
                files.Add(asset.Id, destination);
            }
            return new(root, plan.SampleRate, spans, files);
        }
        catch { Directory.Delete(root, true); throw; }
    }

    internal PixelBuffer? Read(double edited, CancellationToken ct)
    {
        var sample = edited * rate;
        var span = regions.FirstOrDefault(candidate => sample >= candidate.Start && sample < candidate.End);
        if (span is null) return null;
        if (current != span.Id || decoder is null)
        {
            decoder?.Dispose(); decoder = null;
            decoder = new VideoDecoder(files[span.Id], hardware: false);
            current = span.Id;
        }
        return decoder.ReadAt((sample - span.Origin) / rate, false, ct);
    }

    private static VoxClipException Invalid() => new(VoxClipErrorCode.DecodeFailed, "The saved lip-sync video couldn't be verified. Your edits and paid work are saved.");
    public void Dispose()
    {
        decoder?.Dispose();
        try { Directory.Delete(folder, true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
