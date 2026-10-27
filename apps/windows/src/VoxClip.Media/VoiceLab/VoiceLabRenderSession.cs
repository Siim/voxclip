using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.VoiceLab;

/// <summary>The selected private snapshots stay alive until every native reader has stopped.</summary>
internal sealed class VoiceLabRenderSession : IDisposable
{
    private readonly IReadOnlyDictionary<string, PreparedVoiceLabAsset> assets;
    private readonly IReadOnlyDictionary<string, VoiceLabTempoTrack> tracks;
    private bool disposed;
    private VoiceLabRenderSession(VoiceLabPreparedRender prepared, IReadOnlyDictionary<string, PreparedVoiceLabAsset> assets,
        IReadOnlyDictionary<string, VoiceLabTempoTrack> tracks)
    { Prepared = prepared; this.assets = assets; this.tracks = tracks; }
    internal VoiceLabPreparedRender Prepared { get; }

    internal static async Task<VoiceLabRenderSession?> PrepareAsync(ComposeSnapshot snapshot, CancellationToken ct,
        params VoiceLabCapacity.Allocation[] outputs)
        => await PrepareAsync(snapshot, ct, Path.GetTempPath(), outputs).ConfigureAwait(false);

    internal static async Task<VoiceLabRenderSession?> PrepareAsync(ComposeSnapshot snapshot, CancellationToken ct,
        string scratchRoot, params VoiceLabCapacity.Allocation[] outputs)
    {
        if (snapshot.VoiceLab is not { } input) return null;
        var project = input.IsolatedProject();
        input.Prepared.Verify(project, input.Prepared.OutputPlan.Scope, input.Prepared.Disclosure.Position);
        VoiceLabCapacity.VerifySource(snapshot);
        if (!input.Prepared.OutputPlan.RequiresSyntheticRendering) return null;
        VoiceLabCapacity.Require(snapshot, scratchRoot, outputs);
        if (snapshot.Media.Audio is null)
            throw new VoxClipException(VoxClipErrorCode.DecodeFailed,
                "This generated voice edit needs a source audio track. Your edits are saved.");
        // No build stretches voiced speech (ADR-R30), so this refusal needs no FFmpeg capability.
        foreach (var item in input.Prepared.SelectedSegmentRecipes)
            if (VoiceLabTempo.RequiresFit(item.Recipe.Audio.Stretch)) VoiceLabTempo.RefuseNonunityFit();
        var handles = await VoiceLabAssets.PrepareAsync(project, input.Prepared.OutputPlan, input.PaidRoot, scratchRoot, ct).ConfigureAwait(false);
        var tracks = new Dictionary<string, VoiceLabTempoTrack>(StringComparer.Ordinal);
        try
        {
            foreach (var item in input.Prepared.SelectedSegmentRecipes)
            {
                var asset = handles[item.SegmentId];
                var fadeIn = item.Recipe.Seams.In;
                var fadeOut = item.Recipe.Seams.Out;
                if (fadeIn.Kind != VoiceLabSeamKind.None &&
                    asset.TrimStartFrame < fadeIn.AssetHandleFrames ||
                    fadeOut.Kind != VoiceLabSeamKind.None &&
                    asset.FrameCount - asset.TrimEndFrame < fadeOut.AssetHandleFrames)
                    throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidFadeHandles);
                if (VoiceLabTempo.RequiresFit(asset.Stretch))
                    tracks.Add(item.SegmentId, VoiceLabTempoTrack.Create(asset,
                        item.Piece.OutputEndSample - item.Piece.OutputStartSample,
                        input.Prepared.OutputPlan.SampleRate,
                        fadeIn.AssetHandleFrames, fadeOut.AssetHandleFrames,
                        fadeIn.FadeSamples / 2,
                        fadeOut.FadeSamples - fadeOut.FadeSamples / 2, ct));
            }
            return new(input.Prepared, handles, tracks);
        }
        catch
        {
            foreach (var track in tracks.Values) track.Dispose();
            foreach (var asset in handles.Values) asset.Dispose();
            throw;
        }
    }

    internal VoiceLabAudioMixer CreateMixer(IVoiceLabSource source, long startSample = 0, CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        return new(Prepared, assets, source, startSample, tracks, ct);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var track in tracks.Values) track.Dispose();
        foreach (var asset in assets.Values) asset.Dispose();
    }
}

#pragma warning disable CS1591 // The typed render failure is surfaced by the native App and CLI.
public sealed class VoiceLabTempoException(string? reason = null) : Exception(reason ??
    "This Voice Lab take was stretched to fit its window, which VoxClip does not support. Your generated audio and edits are saved.");
#pragma warning restore CS1591

internal static class VoiceLabTempo
{
    // Decimal duration arithmetic can serialize exact unity as either adjacent
    // binary double. Any wider difference is a nonunity fit, which VoxClip refuses.
    internal static bool RequiresFit(double stretch)
        => !double.IsFinite(stretch) || stretch < Math.BitDecrement(1d) || stretch > Math.BitIncrement(1d);

    internal static void RequireCapability(Func<bool> available)
    { if (!available()) throw new VoiceLabTempoException(); }

    // The permanent nonunity refusal (voice-lab.md §10.5). It stays until a later ADR adopts a micro-stretch (§8.9.5).
    internal static void RefuseNonunityFit() => throw new VoiceLabTempoException();
}

internal sealed class NativeVoiceLabSource(AudioDecoder decoder) : IVoiceLabSource
{
    private long next = -1;
    public void Read(long startSample, Span<float> stereo, CancellationToken ct)
    {
        if (next != startSample) decoder.Seek(startSample);
        var frames = stereo.Length / 2;
        decoder.Read(stereo, frames, ct);
        next = startSample + frames;
    }
}
