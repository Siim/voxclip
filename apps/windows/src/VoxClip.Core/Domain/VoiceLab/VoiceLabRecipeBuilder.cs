using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public sealed record VoiceLabPublishedTake(IReadOnlyList<VoiceLabAsset> Assets, VoiceLabAudio Audio, double OutDuration,
    IReadOnlyList<VoiceLabWord> Words, IReadOnlyList<VoiceLabChunk> Chunks);
public sealed record VoiceLabZoomCover(double FaceX, double FaceY);

/// <summary>The changed-duration video choices one take allows (voice-lab.md ADR-R38): keep the source duration, cut the
/// video at quiet source boundaries, or match the video to the take with a centered 1.12× crop. Mirrors Mac
/// VoiceLabVideoDurationOptions.</summary>
public sealed class VoiceLabVideoDurationOptions
{
    public const double MinimumRetime = 0.80, MaximumRetime = 1.25, MatchZoom = 1.12;
    public IReadOnlyList<VoiceLabVideoCut> Cuts { get; } = [];
    public double AddedPauseSeconds { get; }
    public double RemovedVideoSeconds { get; }
    public long? OutputSamples { get; }
    public double? RetimeFactor { get; }
    public string? UnchangedUnavailableReason { get; }
    public string? ChangedUnavailableReason { get; }
    public string? CutUnavailableReason => Cuts.Count == 0
        ? "No pair of quiet source boundaries can make this video cut clear of the window edges." : null;

    public VoiceLabVideoDurationOptions(VoiceLabTakeRow row, int sourceSampleRate)
        : this(row.Selectable ? row.Audio?.Fit : null, sourceSampleRate, row.Audio?.SampleRate ?? 0) { }

    public VoiceLabVideoDurationOptions(VoiceLabFitResult? fit, int sourceSampleRate, int assetSampleRate)
    {
        if (fit is null || sourceSampleRate <= 0 || assetSampleRate <= 0 || fit.Plan.OutputFrames <= 0 ||
            fit.Plan.WindowStartSample < 0 || fit.Plan.WindowEndSample <= fit.Plan.WindowStartSample)
        {
            UnchangedUnavailableReason = ChangedUnavailableReason = "Choose a take that passed all speech checks first.";
            return;
        }
        var plan = fit.Plan;
        var duration = plan.WindowEnd - plan.WindowStart + (fit is VoiceLabFitResult.ChangedDuration changed ? changed.ResidualSeconds : 0);
        var rounded = EditingMath.Round(duration * sourceSampleRate);
        if (!double.IsFinite(plan.WindowStart) || plan.WindowStart < 0 || !double.IsFinite(plan.WindowEnd) || plan.WindowEnd <= plan.WindowStart ||
            EditingMath.Round(plan.WindowStart * sourceSampleRate) != plan.WindowStartSample ||
            EditingMath.Round(plan.WindowEnd * sourceSampleRate) != plan.WindowEndSample ||
            !double.IsFinite(duration) || duration <= 0 || EditingMath.Round(duration * assetSampleRate) != plan.OutputFrames ||
            !double.IsFinite(rounded) || rounded <= 0 || rounded >= (double)long.MaxValue)
        {
            UnchangedUnavailableReason = ChangedUnavailableReason = "The take's duration cannot be mapped safely to the source video.";
            return;
        }
        var output = (long)rounded;
        var source = plan.WindowEndSample - plan.WindowStartSample;
        AddedPauseSeconds = plan.Edits.Where(edit => edit.Kind == VoiceLabFitEditKind.Insert).Sum(edit => edit.Count) / (double)assetSampleRate;
        var cutVideo = new VoiceLabVideoRecipe(VoiceLabVideoMode.Cut, plan.WindowStartSample, plan.WindowEndSample, output,
            null, VoiceLabNaturalPacing.CUT_PUNCH_IN, 0.5, 0.5, null, null, null, null, null, null, null) { Cuts = plan.VideoCuts };
        if (VoiceLabNaturalPacing.ValidCuts(cutVideo, sourceSampleRate))
        {
            Cuts = plan.VideoCuts;
            RemovedVideoSeconds = (source - output) / (double)sourceSampleRate;
        }
        OutputSamples = output;
        var factor = (double)source / output;
        RetimeFactor = factor;
        UnchangedUnavailableReason = fit is VoiceLabFitResult.Exact && source == output ? null
            : output > source ? "This take is longer than the source window. Its pauses cannot be shortened enough without cutting or stretching speech."
            : output < source ? "This take is shorter than the source window. The permitted silence and room-tone padding cannot fill the remaining time."
            : "An exact silence-only fit was not verified for this take.";
        ChangedUnavailableReason = factor is >= MinimumRetime and <= MaximumRetime ? null :
            "Matching this take would put source-video speed outside 0.80×–1.25×. Choose another take or re-record the sentence.";
    }

    public bool Allows(VoiceLabVideoMode choice) => choice switch
    {
        VoiceLabVideoMode.Source => UnchangedUnavailableReason is null,
        VoiceLabVideoMode.Cut => CutUnavailableReason is null,
        VoiceLabVideoMode.Retimed => ChangedUnavailableReason is null,
        _ => false
    };
}

public static class VoiceLabRecipeBuilder
{
    public static VoiceLabCandidate Candidate(VoiceLabTakeRow row, VoiceLabTakeInput input, VoiceLabPublishedTake published,
        VoiceConsentRecord record, DateTimeOffset createdAt, VoiceLabVideoMode? videoChoice = null, VoiceLabZoomCover? face = null)
    {
        var asset = published.Assets.FirstOrDefault(asset => asset.Id == published.Audio.AssetId);
        if (!row.Selectable || row.RequiresJoinAdvisoryAcceptance || row.Audio is not { } take || row.Qa is not { Verdict: not VoiceLabTakeQaVerdict.Failed } qa || row.Receipt is not { } receipt || row.Quote is not { } quote ||
            qa.TranscriptMatch is not { } match || qa.LufsJumpLu is not { } jump || qa.PeakDbfs is not { } peak ||
            record.Status != VoiceConsentStatus.Active || record.RecordId != input.RecordId || receipt.VoiceId != record.VoiceId || receipt.ModelId != input.ModelId ||
            !published.Words.SequenceEqual(take.Fit.Plan.Words) || published.Audio.Stretch != 1 || !double.IsFinite(published.OutDuration) || published.OutDuration <= 0 ||
            asset is null || record.Attestations.AcceptedAt > createdAt)
            throw Error(VoiceLabProjectErrorCode.QaRejected);
        // ADR-R37: pooled or unmeasured evidence must be this record's; an unmeasured take carries no score, a measured one passed.
        var evidence = row.VoiceCheck.Evidence;
        var unmeasured = evidence?.Mode == VoiceLabShortSpeechMode.Unmeasured;
        var score = qa.SpeakerScore;
        if (evidence is not null && (!evidence.Usable || evidence.RecordId != record.RecordId || evidence.ConsentMethod != record.ConsentMethod) ||
            (unmeasured ? score is not null : score is not { } measured || !double.IsFinite(measured) || measured < record.Speaker.Threshold))
            throw Error(VoiceLabProjectErrorCode.QaRejected);
        if (row.AcceptedJoinAdvisory is { } accepted && (!row.HasJoinAdvisory || !accepted.Seams.SequenceEqual(qa.JoinSeams) || !accepted.Validates(jump, createdAt)))
            throw Error(VoiceLabProjectErrorCode.QaRejected);
        var plan = take.Fit.Plan;
        // A fitting take keeps its source duration. A changed-duration take needs an explicit choice: Cut, Match video
        // (Retimed: centered 1.12× crop) or a ZoomCover with an explicit face position.
        var options = new VoiceLabVideoDurationOptions(row, input.SourceSampleRate);
        var mode = row.Fits ? VoiceLabVideoMode.Source : videoChoice switch
        {
            VoiceLabVideoMode.Cut when options.Allows(VoiceLabVideoMode.Cut) => VoiceLabVideoMode.Cut,
            VoiceLabVideoMode.Retimed when options.Allows(VoiceLabVideoMode.Retimed) => VoiceLabVideoMode.ZoomCover,
            VoiceLabVideoMode.ZoomCover when face is not null && Unit(face.FaceX) && Unit(face.FaceY) => VoiceLabVideoMode.ZoomCover,
            _ => throw Error(VoiceLabProjectErrorCode.VideoModeUnsupported)
        };
        // Match video and Cut are centered, as on Mac; only an explicit ZoomCover stores the caller's face position.
        face = row.Fits ? null : videoChoice == VoiceLabVideoMode.ZoomCover ? face : new(0.5, 0.5);
        var rate = input.SourceSampleRate;
        var rounded = Math.Floor(published.OutDuration * rate + 0.5);
        if (rate <= 0 || asset.SampleRate <= 0 || !double.IsFinite(rounded) || rounded <= 0 || rounded >= (double)long.MaxValue ||
            plan.WindowStartSample < 0 || plan.WindowEndSample <= plan.WindowStartSample) throw Error(VoiceLabProjectErrorCode.InvalidRange);
        var output = (long)rounded;
        if (mode == VoiceLabVideoMode.Cut && output != options.OutputSamples) throw Error(VoiceLabProjectErrorCode.InvalidRange);
        var factor = (double)(plan.WindowEndSample - plan.WindowStartSample) / output;
        if (mode == VoiceLabVideoMode.ZoomCover && factor is not (>= VoiceLabVideoDurationOptions.MinimumRetime and <= VoiceLabVideoDurationOptions.MaximumRetime))
            throw Error(VoiceLabProjectErrorCode.VideoModeUnsupported);
        VoiceLabSeam Seam(VoiceLabSeamPlacement edge, bool incoming)
        {
            if (edge.FadeSamples < 0) throw Error(VoiceLabProjectErrorCode.InvalidFadeHandles);
            var inner = incoming ? edge.FadeSamples / 2 : edge.FadeSamples - edge.FadeSamples / 2;
            var raw = (double)inner * asset.SampleRate / rate;
            var nearest = Math.Round(raw);
            var frames = Math.Abs(raw - nearest) <= 4 * Math.Abs(Math.BitIncrement(raw) - raw) ? nearest : Math.Ceiling(raw);
            if (!double.IsFinite(frames) || frames < 0 || frames >= (double)long.MaxValue) throw Error(VoiceLabProjectErrorCode.InvalidFadeHandles);
            return new(edge.Kind, edge.FadeSamples, edge.FadeSamples - inner, (long)frames, incoming ? take.MicroPauseIn : take.MicroPauseOut);
        }
        var tokens = VoiceLabTakeQuality.Tokens(input.Text).Length;
        var checkedQa = new VoiceLabRenderQa(tokens, tokens <= 5 ? match == 1 : null, match, jump, peak,
            score, record.Speaker.Threshold, record.Speaker.Model, !unmeasured, evidence, JoinAdvisory: row.AcceptedJoinAdvisory);
        var provenance = new VoiceLabProvenance(receipt.Provider, receipt.Endpoint.TrimStart('/'), input.ModelId, record.VoiceId, record.RecordId,
            receipt.ActionId.ToString("D"), row.Seed, createdAt) { Region = receipt.Region.ToString().ToLowerInvariant(), Pace = receipt.Pace };
        var zoomCover = mode == VoiceLabVideoMode.ZoomCover;
        var video = new VoiceLabVideoRecipe(mode, plan.WindowStartSample, plan.WindowEndSample, output,
            zoomCover ? factor : null, zoomCover ? VoiceLabVideoDurationOptions.MatchZoom : mode == VoiceLabVideoMode.Cut ? VoiceLabNaturalPacing.CUT_PUNCH_IN : null,
            face?.FaceX, face?.FaceY, null, null, null, null, null, null, null) { Cuts = mode == VoiceLabVideoMode.Cut ? options.Cuts : null };
        var usd = quote.Synthesis.Estimate.Usd is { } synthesis && quote.Qa.Estimate.Usd is { } transcription ? (double?)(synthesis + transcription) : null;
        var recipe = new VoiceLabRenderRecipe(published.Audio, Array.AsReadOnly(published.Words.ToArray()), published.OutDuration, row.Seed,
            Array.AsReadOnly(published.Chunks.ToArray()), take.RoomTone, new(Seam(input.Window.LeftSeam, true), Seam(input.Window.RightSeam, false)),
            video, checkedQa, provenance, new(quote.Synthesis.Token.ToString("D"), usd), VoiceLabVoiceSource.Own, record.RecordId, record.Attestations.AcceptedAt, take.EdgeGain);
        return new(published.Audio.AssetId, row.Score, null) { Recipe = recipe };
    }
    public static VoiceLabSegment Segment(string id, IReadOnlyList<VoiceLabCandidate> candidates, int selected, VoiceLabTakeInput input, VoiceLabFitPlan plan)
    {
        if (selected < 0 || selected >= candidates.Count || candidates[selected].Rejected is not null || candidates[selected].Recipe is not { } recipe)
            throw Error(VoiceLabProjectErrorCode.InvalidCandidate);
        var original = string.Join(" ", input.Items.Where(word => word.Kind == WordKind.Word && word.End > plan.WindowStart && word.Start < plan.WindowEnd).Select(word => word.Text));
        return new(id, VoiceLabSegmentKind.Tts, true, new(plan.WindowStart, plan.WindowEnd, input.Window.FirstWordId, input.Window.LastWordId), recipe.OutDuration,
            recipe.Audio, new(original, input.Text) { AudioTags = input.HasRequestTags ? VoiceLabAudioTags.Validated(input.AudioTags, input.Text) : null }, recipe.Words, recipe.Provenance, new(recipe.Qa.TranscriptMatch, recipe.Qa.LufsJumpLu, recipe.Qa.PeakDbfs, recipe.Qa.SpeakerScore),
            Array.AsReadOnly(candidates.ToArray()), selected) { Scope = VoiceLabSegmentScope.Passage };
    }
    private static bool Unit(double value) => double.IsFinite(value) && value is >= 0 and <= 1;
    private static VoiceLabProjectException Error(VoiceLabProjectErrorCode code) => new(code);
}
