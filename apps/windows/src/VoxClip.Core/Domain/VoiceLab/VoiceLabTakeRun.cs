using System.Text;
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
    VoiceLabWindow Window, double? IncomingSilence, double? OutgoingSilence, bool CleanAudioOn, bool ProviderConsent)
{
    /// <summary>A source held whole, as short sources and tests pass it; the envelope is computed from it.</summary>
    public VoiceLabTakeInput(string Text, string ModelId, string RecordId, string Language, uint Seed, string ContentKey,
        float[] Source, int SourceSampleRate, IReadOnlyList<TimedWord> Items, IReadOnlySet<string> CutWordIds, VoiceLabWindow Window,
        double? IncomingSilence, double? OutgoingSilence, bool CleanAudioOn, bool ProviderConsent)
        : this(Text, ModelId, RecordId, Language, Seed, ContentKey, VoiceLabSourceExcerpt.Whole(Source),
            VoiceLabTakeProcessing.Envelope(Source, SourceSampleRate), SourceSampleRate, Items, CutWordIds, Window,
            IncomingSilence, OutgoingSilence, CleanAudioOn, ProviderConsent) { }
    public VoiceLabSpeechOptions Options(int take)
    {
        var kept = Items.Where(word => word.Kind == WordKind.Word && !CutWordIds.Contains(word.Id)).ToArray();
        return new(unchecked(Seed + (uint)take), string.Join(" ", kept.Where(word => word.End <= Window.Start).Select(word => word.Text)),
            string.Join(" ", kept.Where(word => word.Start >= Window.End).Select(word => word.Text)));
    }
    /// <summary>A copy that later changes to the caller's lists cannot reach. The excerpt never changes, so it is shared.</summary>
    public VoiceLabTakeInput Snapshot() => this with { SourceEnvelope = SourceEnvelope with { Rms = Array.AsReadOnly(SourceEnvelope.Rms.ToArray()) },
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
        var estimates = Actions.Select(action => action.Estimate).ToArray();
        Estimate = new("elevenlabs", "takeRun", takes.Count, "take", estimates.All(value => value.Usd.HasValue) ? estimates.Sum(value => value.Usd!.Value) : null,
            estimates.All(value => value.Credits.HasValue) ? estimates.Sum(value => value.Credits!.Value) : null,
            estimates.All(value => value.Usd.HasValue) ? "bounded-tts-and-scribe" : "unknown");
    }
}
public enum VoiceLabTakeQaFailure { Transcript, Clipping, Loudness, Speaker }
public sealed record VoiceLabTakeQaResult(double TranscriptMatch, double LufsJumpLu, double PeakDbfs, double? SpeakerScore,
    IReadOnlyList<VoiceLabTakeQaFailure> Failures)
{
    public bool Passed => Failures.Count == 0;
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
        IReadOnlyList<int> seams, double speakerScore, double threshold)
    {
        if (!double.IsFinite(speakerScore) || speakerScore is < -1 or > 1 || !double.IsFinite(threshold) || threshold is < 0 or > 1)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var expectedTokens = Tokens(expected);
        var recognizedTokens = recognized.SelectMany(Tokens).ToArray();
        var ratio = TranscriptRatio(expectedTokens, recognizedTokens);
        var peak = VoiceLabLoudness.SamplePeakDbfs(mixed);
        if (!double.IsFinite(peak)) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var jump = VoiceLabLoudness.LufsJumpLu(mixed, sampleRate, seams);
        var failures = new List<VoiceLabTakeQaFailure>();
        if (expectedTokens.Length <= 5 ? !expectedTokens.SequenceEqual(recognizedTokens) : ratio < 0.9) failures.Add(VoiceLabTakeQaFailure.Transcript);
        if (peak >= 0) failures.Add(VoiceLabTakeQaFailure.Clipping);
        if (jump > 2) failures.Add(VoiceLabTakeQaFailure.Loudness);
        if (speakerScore < threshold) failures.Add(VoiceLabTakeQaFailure.Speaker);
        return new(ratio, jump, peak, speakerScore, Array.AsReadOnly(failures.ToArray()));
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
    IReadOnlyList<int> Seams, double GainDb, VoiceLabRoomTone? RoomTone, VoiceLabFitResult Fit);
public sealed record VoiceLabTakeRow(Guid Id, int Index, uint Seed, VoiceLabReceipt? Receipt = null, VoiceLabReceipt? QaReceipt = null,
    VoiceLabAudioResult? Generated = null, VoiceLabTakeQuote? Quote = null, VoiceLabTakeAudio? Audio = null,
    VoiceLabTakeQaResult? Qa = null, double? Score = null, Exception? Failure = null)
{
    public string DisplayName => "Take " + (Index + 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
    public bool Selectable => Failure is null && Qa?.Passed == true && Audio is not null;
    public bool Fits => Audio?.Fit is VoiceLabFitResult.Exact;
}
public enum VoiceLabTakeRunEnd { Completed, EarlyStop, Cancelled, Invalidated, Fatal }
public sealed record VoiceLabTakeRunResult(IReadOnlyList<VoiceLabTakeRow> Rows, VoiceLabTakeRunEnd End)
{
    public IReadOnlyList<VoiceLabTakeRow> Ranked => Rows.Where(row => row.Selectable).OrderByDescending(row => row.Score).ThenBy(row => row.Index).ToArray();
    public VoiceLabTakeRow? Best => Ranked.FirstOrDefault();
}
