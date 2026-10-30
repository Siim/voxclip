using System.Security.Cryptography;
using VoxClip.Core.Domain.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public sealed record VoiceLabFittedPublication(IReadOnlyList<VoiceLabAsset> Assets, VoiceLabAudio Audio, double OutDuration,
    IReadOnlyList<VoiceLabWord> Words, IReadOnlyList<VoiceLabChunk> Chunks, long SourceStartSample, long SourceEndSample)
{
    public VoiceLabRenderRecipe ApplyingTo(VoiceLabRenderRecipe recipe) => recipe with { Audio = Audio, OutDuration = OutDuration, Words = Words, Chunks = Chunks };
}
public sealed class VoiceLabFittedAudio
{
    public VoiceLabAsset PaidAsset { get; }
    public PreparedVoiceLabAsset Snapshot { get; }
    public VoiceLabFitResult Fit { get; }
    public long IncomingHandleFrames { get; }
    public long OutgoingHandleFrames { get; }
    public long TrimStartFrame { get; }
    public long TrimEndFrame { get; }
    public bool IsDerived { get; }
    internal VoiceLabWavePcm Wave { get; }
    public double OutDuration => Fit.Plan.WindowEnd - Fit.Plan.WindowStart + (Fit is VoiceLabFitResult.ChangedDuration changed ? changed.ResidualSeconds : 0);
    internal VoiceLabFittedAudio(VoiceLabAsset paid, PreparedVoiceLabAsset snapshot, VoiceLabFitResult fit, long incoming, long outgoing,
        long trimStart, long trimEnd, bool derived, VoiceLabWavePcm wave)
    {
        PaidAsset = paid; Snapshot = snapshot; Fit = fit; IncomingHandleFrames = incoming; OutgoingHandleFrames = outgoing;
        TrimStartFrame = trimStart; TrimEndFrame = trimEnd; IsDerived = derived; Wave = wave;
    }
    public VoiceLabFittedPublication Publish(string projectId, string assetId, string paidRoot, DateTimeOffset createdAt,
        string requestId, uint seed, double gainDb, CancellationToken ct = default)
    {
        if (!Snapshot.IsValid || string.IsNullOrEmpty(requestId) || !double.IsFinite(gainDb) || !double.IsFinite(OutDuration) || OutDuration <= 0 ||
            VoiceLabAssetNaming.File(projectId, PaidAsset.Id, "wav") != PaidAsset.File) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var asset = IsDerived ? VoiceLabAssetStore.WriteWave(Wave.Pcm, Wave.Rate, Wave.Channels, Wave.Bits, Wave.Floating, projectId, assetId, paidRoot, createdAt, ct) : PaidAsset;
        var audio = new VoiceLabAudio(asset.Id, TrimStartFrame / (double)Wave.Rate, TrimEndFrame / (double)Wave.Rate, 1, gainDb);
        if ((long)Math.Floor(audio.TrimEnd * Wave.Rate + 0.5) - (long)Math.Floor(audio.TrimStart * Wave.Rate + 0.5) != Fit.Plan.OutputFrames)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var chunk = new VoiceLabChunk(Fit.Plan.WindowStartSample, Fit.Plan.WindowEndSample, requestId, seed, PaidAsset.Id, PaidAsset.Sha256, TrimStartFrame, TrimEndFrame);
        return new(Array.AsReadOnly(IsDerived ? new[] { PaidAsset, asset } : [PaidAsset]), audio, OutDuration, Fit.Plan.Words, [chunk], Fit.Plan.WindowStartSample, Fit.Plan.WindowEndSample);
    }
}
public static class VoiceLabSilenceFit
{
    public static VoiceLabFittedAudio Prepare(PreparedVoiceLabAsset snapshot, VoiceLabAsset paidAsset, VoiceLabFitResult fit,
        VoiceLabWindow window, int sourceSampleRate, CancellationToken ct = default)
    {
        if (!snapshot.IsValid || snapshot.AssetId != paidAsset.Id || snapshot.Sha256 != paidAsset.Sha256 || snapshot.SampleRate != paidAsset.SampleRate ||
            sourceSampleRate is < 8000 or > 192000 || snapshot.FrameCount > (long)snapshot.SampleRate * 290 || new FileInfo(snapshot.Path).Length > 256 * 1024 * 1024)
            throw Invalid();
        var bytes = File.ReadAllBytes(snapshot.Path);
        if (Convert.ToHexStringLower(SHA256.HashData(bytes)) != snapshot.Sha256) throw new VoiceLabAssetException(VoiceLabAssetErrorCode.Altered, paidAsset.File);
        var original = VoiceLabWavePcm.Parse(bytes);
        var plan = fit.Plan with { Edits = Array.AsReadOnly(fit.Plan.Edits.ToArray()), Words = Array.AsReadOnly(fit.Plan.Words.ToArray()) };
        fit = fit is VoiceLabFitResult.ChangedDuration changed ? new VoiceLabFitResult.ChangedDuration(plan, changed.NaturalOut, changed.ResidualSeconds) : new VoiceLabFitResult.Exact(plan);
        if (original.Rate != snapshot.SampleRate || original.Channels != snapshot.Channels || original.Frames != snapshot.FrameCount ||
            plan.TrimStartFrame < 0 || plan.TrimEndFrame > original.Frames || plan.TrimEndFrame <= plan.TrimStartFrame ||
            !double.IsFinite(plan.WindowStart) || !double.IsFinite(plan.WindowEnd) || plan.WindowStart < 0 || plan.WindowEnd <= plan.WindowStart ||
            plan.WindowStartSample < 0 || plan.WindowEndSample <= plan.WindowStartSample || plan.Incoming.PadFrames < 0 || plan.Outgoing.PadFrames < 0 ||
            plan.Incoming.PadFrames > plan.OutputFrames || plan.Outgoing.PadFrames > plan.OutputFrames || plan.OutputFrames <= 0 || plan.OutputFrames > (long)original.Rate * 290) throw Invalid();
        long Handle(VoiceLabSeamPlacement seam, bool incoming)
        {
            if (seam.FadeSamples < 0 || seam.FadeSamples > sourceSampleRate) throw Invalid();
            if (seam.Kind == VoiceLabSeamKind.None)
            {
                if (seam.FadeSamples != 0) throw Invalid();
                return 0;
            }
            var half = incoming ? seam.FadeSamples / 2 : seam.FadeSamples - seam.FadeSamples / 2;
            return (long)Math.Ceiling(half * (double)original.Rate / sourceSampleRate);
        }
        var incoming = Handle(window.LeftSeam, true);
        var outgoing = Handle(window.RightSeam, false);
        if ((incoming + plan.OutputFrames + outgoing) * original.Stride > 256 * 1024 * 1024) throw Invalid();
        var derived = plan.Edits.Count > 0 || plan.Incoming.PadFrames > 0 || plan.Outgoing.PadFrames > 0;
        if (!derived)
        {
            if (plan.TrimStartFrame < incoming || plan.TrimEndFrame + outgoing > original.Frames || plan.TrimEndFrame - plan.TrimStartFrame != plan.OutputFrames) throw Invalid();
            return new(paidAsset, snapshot, fit, incoming, outgoing, plan.TrimStartFrame, plan.TrimEndFrame, false, original);
        }
        using var pcm = new MemoryStream();
        void Copy(long start, long end)
        {
            if (start < 0 || end < start || end > original.Frames) throw Invalid();
            pcm.Write(original.Pcm.AsSpan(checked((int)(start * original.Stride)), checked((int)((end - start) * original.Stride))));
        }
        void Silence(long frames)
        {
            if (frames < 0 || frames > 256 * 1024 * 1024 / original.Stride) throw Invalid();
            pcm.Write(new byte[checked((int)(frames * original.Stride))]);
        }
        if (plan.Incoming.PadFrames > 0) Silence(incoming);
        else Copy(plan.TrimStartFrame - incoming, plan.TrimStartFrame);
        Silence(plan.Incoming.PadFrames);
        var cursor = plan.TrimStartFrame;
        var joins = new List<(long Output, long Left, long Right)>();
        var fade = (long)Math.Floor(VoiceLabPatchConstants.SEAM_FADE * original.Rate + 0.5);
        var previousEnd = plan.TrimStartFrame;
        foreach (var edit in plan.Edits)
        {
            ct.ThrowIfCancellationRequested();
            if (!Enum.IsDefined(edit.Kind) || edit.Start < cursor || edit.Start > plan.TrimEndFrame || edit.Count <= 0 || edit.Count > plan.TrimEndFrame - edit.Start) throw Invalid();
            var end = edit.Start + edit.Count;
            if (edit.Start - fade / 2 < previousEnd || end + fade - fade / 2 > plan.TrimEndFrame)
                throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.FitTouchesVoice);
            Copy(cursor, edit.Start);
            if (edit.Kind == VoiceLabFitEditKind.Insert) Copy(edit.Start, end);
            joins.Add((pcm.Length / original.Stride, edit.Kind == VoiceLabFitEditKind.Insert ? end : edit.Start, edit.Kind == VoiceLabFitEditKind.Insert ? edit.Start : end));
            if (edit.Kind == VoiceLabFitEditKind.Insert) Copy(edit.Start, end);
            cursor = end;
            previousEnd = end + fade - fade / 2;
        }
        Copy(cursor, plan.TrimEndFrame);
        Silence(plan.Outgoing.PadFrames);
        if (pcm.Length / original.Stride != incoming + plan.OutputFrames) throw Invalid();
        if (plan.Outgoing.PadFrames > 0) Silence(outgoing);
        else Copy(plan.TrimEndFrame, plan.TrimEndFrame + outgoing);
        var wave = new VoiceLabWavePcm(original.Rate, original.Channels, original.Bits, original.Floating, pcm.ToArray());
        foreach (var join in joins)
            for (var offset = 0; offset < fade; offset++)
            {
                var local = offset - fade / 2;
                var phase = offset / (double)(fade - 1);
                for (var channel = 0; channel < original.Channels; channel++)
                {
                    var left = original.Sample(join.Left + local, channel) * Math.Cos(Math.PI * phase / 2);
                    var right = original.Sample(join.Right + local, channel) * Math.Sin(Math.PI * phase / 2);
                    wave.SetSample(left + right, join.Output + local, channel);
                }
            }
        ct.ThrowIfCancellationRequested();
        return new(paidAsset, snapshot, fit, incoming, outgoing, incoming, incoming + plan.OutputFrames, true, wave);
    }
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidAudio);
}
