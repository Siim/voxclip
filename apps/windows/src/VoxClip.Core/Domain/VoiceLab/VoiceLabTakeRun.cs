using System.Text;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>What a take run needs. <paramref name="Source"/> holds the source frames the run reads at
/// <paramref name="SourceSampleRate"/>, and <paramref name="SourceEnvelope"/> is the whole source's 10 ms RMS envelope
/// (<see cref="VoiceLabTakeProcessing.Envelope"/>), which the room-tone search reads.</summary>
public sealed record VoiceLabTakeInput(string Text, string ModelId, string RecordId, string Language, uint Seed, string ContentKey,
    VoiceLabSourceExcerpt Source, AudioEnvelope SourceEnvelope, int SourceSampleRate, IReadOnlyList<TimedWord> Items, IReadOnlySet<string> CutWordIds,
    VoiceLabWindow Window, double? IncomingSilence, double? OutgoingSilence, bool CleanAudioOn, bool ProviderConsent, double? Pace = null, bool HardJoinSmoothing = true)
{
    public IReadOnlyList<VoiceLabAudioTag> AudioTags { get; init; } = [];
    public string RequestText => VoiceLabAudioTags.RequestText(Text, AudioTags, ModelId);
    public bool HasRequestTags => AudioTags.Count > 0 && VoiceLabAudioTags.Supports(ModelId) && VoiceLabAudioTags.Validated(AudioTags, Text).Count > 0;
    /// <summary>A source held whole, as short sources and tests pass it; the envelope is computed from it.</summary>
    public VoiceLabTakeInput(string Text, string ModelId, string RecordId, string Language, uint Seed, string ContentKey,
        float[] Source, int SourceSampleRate, IReadOnlyList<TimedWord> Items, IReadOnlySet<string> CutWordIds, VoiceLabWindow Window,
        double? IncomingSilence, double? OutgoingSilence, bool CleanAudioOn, bool ProviderConsent, double? Pace = null, bool HardJoinSmoothing = true)
        : this(Text, ModelId, RecordId, Language, Seed, ContentKey, VoiceLabSourceExcerpt.Whole(Source),
            VoiceLabTakeProcessing.Envelope(Source, SourceSampleRate), SourceSampleRate, Items, CutWordIds, Window,
            IncomingSilence, OutgoingSilence, CleanAudioOn, ProviderConsent, Pace, HardJoinSmoothing) { }
    public VoiceLabSpeechOptions Options(int take)
    {
        var kept = Items.Where(word => word.Kind == WordKind.Word && !CutWordIds.Contains(word.Id)).ToArray();
        return new(unchecked(Seed + (uint)take), string.Join(" ", kept.Where(word => word.End <= Window.Start).Select(word => word.Text)),
            string.Join(" ", kept.Where(word => word.Start >= Window.End).Select(word => word.Text)), Pace);
    }
    /// <summary>A copy that later changes to the caller's lists cannot reach. The excerpt never changes, so it is shared.</summary>
    public VoiceLabTakeInput Snapshot() => this with { SourceEnvelope = SourceEnvelope with { Rms = Array.AsReadOnly(SourceEnvelope.Rms.ToArray()) },
        AudioTags = Array.AsReadOnly(AudioTags.ToArray()),
        Items = Array.AsReadOnly(Items.ToArray()),
        CutWordIds = System.Collections.Frozen.FrozenSet.ToFrozenSet(CutWordIds, StringComparer.Ordinal),
        Window = Window with { LeftBridgeWordIds = Array.AsReadOnly(Window.LeftBridgeWordIds.ToArray()), RightBridgeWordIds = Array.AsReadOnly(Window.RightBridgeWordIds.ToArray()) } };
}
public sealed record VoiceLabTakeQuote(int Index, uint Seed, VoiceLabPreparedAction Synthesis, VoiceLabPreparedAction Qa);
public sealed class VoiceLabTakeRunQuote
{
    public Guid Id { get; }
    public IReadOnlyList<VoiceLabTakeQuote> Takes { get; }
    public IReadOnlyList<VoiceLabPreparedAction> Actions { get; }
    public DateTimeOffset ExpiresAt { get; }
    public CostEstimate Estimate { get; }
    public VoiceLabTakeRunQuote(Guid id, IReadOnlyList<VoiceLabTakeQuote> takes)
    {
        if (id == Guid.Empty || takes.Count is < 1 or > 3) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        Id = id;
        Takes = Array.AsReadOnly(takes.ToArray());
        Actions = Array.AsReadOnly(Takes.SelectMany(take => new[] { take.Synthesis, take.Qa }).ToArray());
        ExpiresAt = Actions.Min(action => action.ExpiresAt);
        Estimate = Total(Actions.Select(action => action.Estimate.ToCostEstimate()), takes.Count);
    }
    internal static CostEstimate Total(IEnumerable<CostEstimate> values, int takes)
    {
        var estimates = values.ToArray();
        return new("elevenlabs", "takeRun", takes, "take", estimates.All(value => value.Usd.HasValue) ? estimates.Sum(value => value.Usd!.Value) : null,
            estimates.All(value => value.Credits.HasValue) ? estimates.Sum(value => value.Credits!.Value) : null,
            estimates.All(value => value.Usd.HasValue) ? "bounded-tts-and-scribe" : "unknown");
    }
}

[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabTakeQaFailure>))]
public enum VoiceLabTakeQaFailure
{
    [JsonStringEnumMemberName("transcript")] Transcript,
    [JsonStringEnumMemberName("clipping")] Clipping,
    [JsonStringEnumMemberName("loudness")] Loudness,
    [JsonStringEnumMemberName("speaker")] Speaker,
    [JsonStringEnumMemberName("insufficientGeneratedSpeech")] InsufficientGeneratedSpeech
}
public sealed class VoiceInsufficientGeneratedSpeechException() : Exception("The generated audio does not contain enough speech for the calibrated speaker check.");
public enum VoiceLabTakeQaVerdict { Passed, PassedWithAdvisory, Failed }
public sealed record VoiceLabTakeQaResult(double? TranscriptMatch, double? LufsJumpLu, double? PeakDbfs, double? SpeakerScore,
    IReadOnlyList<VoiceLabTakeQaFailure> Failures)
{
    public IReadOnlyList<VoiceLabJoinAdvisorySeam> JoinSeams { get; init; } = [];
    public VoiceLabTakeQaVerdict Verdict => TranscriptMatch is not { } match || !double.IsFinite(match) ||
        LufsJumpLu is not { } jump || !double.IsFinite(jump) || PeakDbfs is not { } peak || !double.IsFinite(peak) ||
        SpeakerScore is not { } score || !double.IsFinite(score) || Failures.Any(failure => failure != VoiceLabTakeQaFailure.Loudness)
            ? VoiceLabTakeQaVerdict.Failed
            : Failures.Count == 0 && jump is >= 0 and <= 2 ? VoiceLabTakeQaVerdict.Passed
            : Failures.Count > 0 && jump > 2 ? VoiceLabTakeQaVerdict.PassedWithAdvisory : VoiceLabTakeQaVerdict.Failed;
    public bool Passed => Verdict == VoiceLabTakeQaVerdict.Passed;
}
public sealed record VoiceLabQaTranscript(IReadOnlyList<VoiceLabWord> Words, VoiceLabReceipt Receipt);
public static class VoiceLabTakeQuality
{
    public static string[] Tokens(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
        .Select(token => EditingAlgorithms.NormalizeForMatch(token.Normalize(NormalizationForm.FormC))).Where(token => token.Length > 0).ToArray();
    public static double TranscriptRatio(IReadOnlyList<string> expected, IReadOnlyList<string> recognized)
    {
        if (expected.Count is < 1 or > 5000 || recognized.Count > 5000) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var previous = new int[recognized.Count + 1];
        foreach (var token in expected)
        {
            var next = new int[recognized.Count + 1];
            for (var index = 0; index < recognized.Count; index++)
                next[index + 1] = token == recognized[index] ? previous[index] + 1 : Math.Max(previous[index + 1], next[index]);
            previous = next;
        }
        return 2.0 * previous[^1] / (expected.Count + recognized.Count);
    }
    public static VoiceLabTakeQaResult Evaluate(string expected, IReadOnlyList<string> recognized, float[] mixed, int sampleRate,
        IReadOnlyList<int> seams, double speakerScore, double threshold, IReadOnlyList<bool>? generatedAfter = null, IReadOnlyList<double>? seamExcesses = null, bool hasTags = false)
    {
        if (!double.IsFinite(speakerScore) || speakerScore is < -1 or > 1 || !double.IsFinite(threshold) || threshold is < 0 or > 1)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var expectedTokens = Tokens(VoiceLabAudioTags.StrippingTags(expected));
        var recognizedTokens = VoiceLabAudioTags.FilterScribeEvents(expectedTokens, recognized.SelectMany(Tokens).ToArray(), hasTags);
        var ratio = TranscriptRatio(expectedTokens, recognizedTokens);
        var peak = VoiceLabLoudness.SamplePeakDbfs(mixed);
        if (!double.IsFinite(peak)) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        if (generatedAfter is not null && generatedAfter.Count != seams.Count) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var jumps = seamExcesses?.ToArray() ?? VoiceLabLoudness.SeamJumps(mixed, sampleRate, seams);
        if (jumps.Length != seams.Count || jumps.Any(value => !double.IsFinite(value) || value < 0)) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var jump = jumps.Length == 0 ? 0 : jumps.Max();
        var joinSeams = jumps.Select((excess, index) => new VoiceLabJoinAdvisorySeam(
            (generatedAfter?[index] ?? index == 0) ? "left" : "right", excess)).Where(seam => seam.ExcessLu > 2).ToArray();
        var failures = new List<VoiceLabTakeQaFailure>();
        if (expectedTokens.Length <= 5 ? !expectedTokens.SequenceEqual(recognizedTokens) : ratio < 0.9) failures.Add(VoiceLabTakeQaFailure.Transcript);
        if (peak >= 0) failures.Add(VoiceLabTakeQaFailure.Clipping);
        if (jump > 2) failures.Add(VoiceLabTakeQaFailure.Loudness);
        if (speakerScore < threshold) failures.Add(VoiceLabTakeQaFailure.Speaker);
        return new(ratio, jump, peak, speakerScore, Array.AsReadOnly(failures.ToArray())) { JoinSeams = Array.AsReadOnly(joinSeams) };
    }
    public static double Rank(VoiceLabFitResult fit, double windowSeconds, double matchRatio, double flatness)
    {
        if (!double.IsFinite(windowSeconds) || windowSeconds <= 0 || !double.IsFinite(matchRatio) || matchRatio is < 0 or > 1 ||
            !double.IsFinite(flatness) || flatness is < 0 or > 1) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var cost = fit is VoiceLabFitResult.ChangedDuration changed ? Math.Min(1, Math.Abs(changed.ResidualSeconds) / (0.25 * windowSeconds)) : 0;
        return 0.6 * (1 - cost) + 0.3 * matchRatio + 0.1 * flatness;
    }
}
public sealed record VoiceLabTakeAudio(int SampleRate, float[] Trimmed, float[] Mixed, int PatchStart, int PatchEnd,
    IReadOnlyList<int> Seams, double GainDb, VoiceLabRoomTone? RoomTone, VoiceLabFitResult Fit)
{
    public VoiceLabMicroPause? MicroPauseIn { get; init; }
    public VoiceLabMicroPause? MicroPauseOut { get; init; }
    public VoiceLabEdgeGain? EdgeGain { get; init; }
    public IReadOnlyList<double>? SeamExcesses { get; init; }
}
public sealed record VoiceLabTakeRow(Guid Id, int Index, uint Seed, VoiceLabReceipt? Receipt = null, VoiceLabReceipt? QaReceipt = null,
    VoiceLabAudioResult? Generated = null, VoiceLabTakeQuote? Quote = null, VoiceLabTakeAudio? Audio = null,
    VoiceLabTakeQaResult? Qa = null, double? Score = null, Exception? Failure = null)
{
    public VoiceLabJoinAdvisory? AcceptedJoinAdvisory { get; init; }
    public bool HasJoinAdvisory => Qa?.Verdict == VoiceLabTakeQaVerdict.PassedWithAdvisory;
    public bool RequiresJoinAdvisoryAcceptance => HasJoinAdvisory &&
        (AcceptedJoinAdvisory is not { } accepted || !accepted.Seams.SequenceEqual(Qa!.JoinSeams) ||
            !accepted.Validates(Qa.LufsJumpLu!.Value, accepted.AcceptedAt));
    public bool AutomaticallySelectable => Selectable && !HasJoinAdvisory;
    public VoiceLabTakeRow AcceptingJoinAdvisory(DateTimeOffset acceptedAt)
    {
        if (!Selectable || !HasJoinAdvisory) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.QaRejected);
        var acceptance = new VoiceLabJoinAdvisory(Array.AsReadOnly(Qa!.JoinSeams.ToArray()), acceptedAt);
        if (!acceptance.Validates(Qa.LufsJumpLu!.Value, acceptedAt)) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.QaRejected);
        return this with { AcceptedJoinAdvisory = RequiresJoinAdvisoryAcceptance ? acceptance : AcceptedJoinAdvisory };
    }
    /// <summary>Accepted status lines, including a paid response that failed before producing a receipt.</summary>
    public IReadOnlySet<Guid> Accepted { get; init; } = System.Collections.Frozen.FrozenSet<Guid>.Empty;
    public IReadOnlySet<Guid> AcceptedRequestIds => Accepted.Concat(Receipt is null ? [] : new[] { Receipt.ActionId })
        .Concat(QaReceipt is null ? [] : new[] { QaReceipt.ActionId }).ToHashSet();
    public string DisplayName => "Take " + (Index + 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
    /// <summary>An interrupted take retains paid request IDs without claiming its speech failed QA.</summary>
    public bool Stopped => Failure is OperationCanceledException or VoxClip.Core.Services.VoiceLab.VoiceLabRunInvalidatedException
        or VoiceLabException { Kind: VoiceLabErrorKind.Cancelled };
    public bool Selectable => Failure is null && Qa is { Verdict: not VoiceLabTakeQaVerdict.Failed } && Audio is not null;
    public bool Fits => Audio?.Fit is VoiceLabFitResult.Exact;
}
public enum VoiceLabTakeRunEnd { Completed, EarlyStop, Cancelled, Invalidated, Fatal }
public sealed record VoiceLabTakeRunResult(IReadOnlyList<VoiceLabTakeRow> Rows, VoiceLabTakeRunEnd End)
{
    public IReadOnlyList<VoiceLabTakeRow> Ranked => Rows.Where(row => row.Selectable).OrderBy(row => row.HasJoinAdvisory).ThenByDescending(row => row.Score).ThenBy(row => row.Index).ToArray();
    public VoiceLabTakeRow? Best => Ranked.FirstOrDefault();
    public VoiceLabTakeRow? BestAutomatic => Ranked.FirstOrDefault(row => row.AutomaticallySelectable);
}
