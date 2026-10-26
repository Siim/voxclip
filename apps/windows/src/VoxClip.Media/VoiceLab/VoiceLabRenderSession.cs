using FFmpeg.AutoGen;
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
    {
        if (snapshot.VoiceLab is not { } input) return null;
        var project = input.IsolatedProject();
        input.Prepared.Verify(project, input.Prepared.OutputPlan.Scope, input.Prepared.Disclosure.Position);
        VoiceLabCapacity.VerifySource(snapshot);
        if (!input.Prepared.OutputPlan.RequiresSyntheticRendering) return null;
        VoiceLabCapacity.Require(snapshot, outputs);
        if (snapshot.Media.Audio is null)
            throw new VoxClipException(VoxClipErrorCode.DecodeFailed,
                "This generated voice edit needs a source audio track. Your edits are saved.");
        foreach (var item in input.Prepared.SelectedSegmentRecipes)
        {
            var audio = item.Recipe.Audio;
            if (VoiceLabTempo.RequiresFit(audio.Stretch))
            {
                await FfmpegLoader.InitializeAsync(ct).ConfigureAwait(false);
                VoiceLabTempo.RequireCapability(HasTempo);
                VoiceLabTempo.RequireVerifiedPlacement();
            }
        }
        var handles = await VoiceLabAssets.PrepareAsync(project, input.Prepared.OutputPlan, input.PaidRoot, ct).ConfigureAwait(false);
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

    private static unsafe bool HasTempo() => ffmpeg.avfilter_get_by_name("atempo") != null;

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
    "This Windows build cannot apply the required pitch-preserving Voice Lab duration fit. Your generated audio and edits are saved.");
#pragma warning restore CS1591

internal static class VoiceLabTempo
{
    // Decimal duration arithmetic can serialize exact unity as either adjacent
    // binary double. Any wider difference needs the pitch-preserving fit.
    internal static bool RequiresFit(double stretch)
        => !double.IsFinite(stretch) || stretch < Math.BitDecrement(1d) || stretch > Math.BitIncrement(1d);

    internal static void RequireCapability(Func<bool> available)
    { if (!available()) throw new VoiceLabTempoException(); }

    internal static void RequireVerifiedPlacement()
        => throw new VoiceLabTempoException(
            "The pitch-preserving Voice Lab fit has unverified body and seam timing on this Windows build. Your generated audio and edits are saved.");
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
