using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public sealed record VoiceLabPublishedTake(IReadOnlyList<VoiceLabAsset> Assets, VoiceLabAudio Audio, double OutDuration,
    IReadOnlyList<VoiceLabWord> Words, IReadOnlyList<VoiceLabChunk> Chunks);
public sealed record VoiceLabZoomCover(double FaceX, double FaceY);

public static class VoiceLabRecipeBuilder
{
    public static VoiceLabCandidate Candidate(VoiceLabTakeRow row, VoiceLabTakeInput input, VoiceLabPublishedTake published,
        VoiceConsentRecord record, DateTimeOffset createdAt, VoiceLabVideoMode? videoChoice = null, VoiceLabZoomCover? face = null)
    {
        var asset = published.Assets.FirstOrDefault(asset => asset.Id == published.Audio.AssetId);
        if (!row.Selectable || row.Audio is not { } take || row.Qa is not { Passed: true } qa || row.Receipt is not { } receipt || row.Quote is not { } quote ||
            qa.SpeakerScore is not { } score || !double.IsFinite(score) || score < record.Speaker.Threshold ||
            record.Status != VoiceConsentStatus.Active || record.RecordId != input.RecordId || receipt.VoiceId != record.VoiceId || receipt.ModelId != input.ModelId ||
            !published.Words.SequenceEqual(take.Fit.Plan.Words) || published.Audio.Stretch != 1 || !double.IsFinite(published.OutDuration) || published.OutDuration <= 0 ||
            asset is null || record.Attestations.AcceptedAt > createdAt)
            throw Error(VoiceLabProjectErrorCode.QaRejected);
        var plan = take.Fit.Plan;
        var mode = row.Fits ? VoiceLabVideoMode.Source : VoiceLabVideoMode.ZoomCover;
        if (!row.Fits && (videoChoice != VoiceLabVideoMode.ZoomCover || face is null || !Unit(face.FaceX) || !Unit(face.FaceY)))
            throw Error(VoiceLabProjectErrorCode.VideoModeUnsupported);
        var rate = input.SourceSampleRate;
        var rounded = Math.Floor(published.OutDuration * rate + 0.5);
        if (rate <= 0 || asset.SampleRate <= 0 || !double.IsFinite(rounded) || rounded <= 0 || rounded >= (double)long.MaxValue ||
            plan.WindowStartSample < 0 || plan.WindowEndSample <= plan.WindowStartSample) throw Error(VoiceLabProjectErrorCode.InvalidRange);
        var output = (long)rounded;
        var factor = (double)(plan.WindowEndSample - plan.WindowStartSample) / output;
        if (!row.Fits && factor is not (>= 0.80 and <= 1.25)) throw Error(VoiceLabProjectErrorCode.VideoModeUnsupported);
        VoiceLabSeam Seam(VoiceLabSeamPlacement edge, bool incoming)
        {
            if (edge.FadeSamples < 0) throw Error(VoiceLabProjectErrorCode.InvalidFadeHandles);
            var inner = incoming ? edge.FadeSamples / 2 : edge.FadeSamples - edge.FadeSamples / 2;
            var raw = (double)inner * asset.SampleRate / rate;
            var nearest = Math.Round(raw);
            var frames = Math.Abs(raw - nearest) <= 4 * Math.Abs(Math.BitIncrement(raw) - raw) ? nearest : Math.Ceiling(raw);
            if (!double.IsFinite(frames) || frames < 0 || frames >= (double)long.MaxValue) throw Error(VoiceLabProjectErrorCode.InvalidFadeHandles);
            return new(edge.Kind, edge.FadeSamples, edge.FadeSamples - inner, (long)frames);
        }
        var tokens = VoiceLabTakeQuality.Tokens(input.Text).Length;
        var checkedQa = new VoiceLabRenderQa(tokens, tokens <= 5 ? qa.TranscriptMatch == 1 : null, qa.TranscriptMatch, qa.LufsJumpLu, qa.PeakDbfs,
            score, record.Speaker.Threshold, record.Speaker.Model, true);
        var provenance = new VoiceLabProvenance(receipt.Provider, receipt.Endpoint, input.ModelId, record.VoiceId, record.RecordId,
            receipt.ActionId.ToString("D"), row.Seed, createdAt) { Region = receipt.Region.ToString().ToLowerInvariant() };
        var video = new VoiceLabVideoRecipe(mode, plan.WindowStartSample, plan.WindowEndSample, output,
            row.Fits ? null : factor, row.Fits ? null : 1.12, row.Fits ? null : face!.FaceX, row.Fits ? null : face!.FaceY,
            null, null, null, null, null, null, null);
        var usd = quote.Synthesis.Estimate.Usd is { } synthesis && quote.Qa.Estimate.Usd is { } transcription ? (double?)(synthesis + transcription) : null;
        var recipe = new VoiceLabRenderRecipe(published.Audio, Array.AsReadOnly(published.Words.ToArray()), published.OutDuration, row.Seed,
            Array.AsReadOnly(published.Chunks.ToArray()), take.RoomTone, new(Seam(input.Window.LeftSeam, true), Seam(input.Window.RightSeam, false)),
            video, checkedQa, provenance, new(quote.Synthesis.Token.ToString("D"), usd), VoiceLabVoiceSource.Own, record.RecordId, record.Attestations.AcceptedAt);
        return new(published.Audio.AssetId, row.Score, null) { Recipe = recipe };
    }
    public static VoiceLabSegment Segment(string id, IReadOnlyList<VoiceLabCandidate> candidates, int selected, VoiceLabTakeInput input, VoiceLabFitPlan plan)
    {
        if (selected < 0 || selected >= candidates.Count || candidates[selected].Rejected is not null || candidates[selected].Recipe is not { } recipe)
            throw Error(VoiceLabProjectErrorCode.InvalidCandidate);
        var original = string.Join(" ", input.Items.Where(word => word.Kind == WordKind.Word && word.End > plan.WindowStart && word.Start < plan.WindowEnd).Select(word => word.Text));
        return new(id, VoiceLabSegmentKind.Tts, true, new(plan.WindowStart, plan.WindowEnd, input.Window.FirstWordId, input.Window.LastWordId), recipe.OutDuration,
            recipe.Audio, new(original, input.Text), recipe.Words, recipe.Provenance, new(recipe.Qa.TranscriptMatch, recipe.Qa.LufsJumpLu, recipe.Qa.PeakDbfs, recipe.Qa.SpeakerScore),
            Array.AsReadOnly(candidates.ToArray()), selected) { Scope = VoiceLabSegmentScope.Passage };
    }
    private static bool Unit(double value) => double.IsFinite(value) && value is >= 0 and <= 1;
    private static VoiceLabProjectException Error(VoiceLabProjectErrorCode code) => new(code);
}
