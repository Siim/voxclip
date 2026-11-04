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
    public VoiceLabPauseProfile? PauseProfile { get; init; }
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
    /// <summary>ADR-R37: the take's voice could not be measured (its pool held under three seconds of voiced speech), so it
    /// carries no speaker score; only the take row's own-clone evidence lets it be chosen, and never automatically.</summary>
    public bool SpeakerUnmeasured { get; init; }
    public VoiceLabTakeQaVerdict Verdict => TranscriptMatch is not { } match || !double.IsFinite(match) ||
        LufsJumpLu is not { } jump || !double.IsFinite(jump) || PeakDbfs is not { } peak || !double.IsFinite(peak) ||
        (SpeakerScore is not { } score ? !SpeakerUnmeasured : !double.IsFinite(score) || SpeakerUnmeasured) ||
        Failures.Any(failure => failure != VoiceLabTakeQaFailure.Loudness)
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
    /// <summary>The Soundex key of a lowercase word of letters only (the first letter, then up to three consonant-class
    /// digits), or null for anything else: digits, apostrophes and words under three letters never sound alike here.</summary>
    public static string? SoundKey(string word)
    {
        var letters = word.ToLowerInvariant();
        if (letters.Length < 3 || letters.Any(letter => letter is < 'a' or > 'z')) return null;
        static char? Code(char letter) => letter switch
        {
            'b' or 'f' or 'p' or 'v' => '1',
            'c' or 'g' or 'j' or 'k' or 'q' or 's' or 'x' or 'z' => '2',
            'd' or 't' => '3',
            'l' => '4',
            'm' or 'n' => '5',
            'r' => '6',
            _ => null,
        };
        var key = new StringBuilder().Append(char.ToUpperInvariant(letters[0]));
        var last = Code(letters[0]);
        foreach (var letter in letters.AsSpan(1))
        {
            var digit = Code(letter);
            if (digit is { } value && digit != last) key.Append(value);
            // h and w do not separate equal codes; vowels do.
            if (letter is not ('h' or 'w')) last = digit;
            if (key.Length == 4) break;
        }
        return key.ToString();
    }
    /// <summary>Whether the recognizer's <paramref name="heard"/> is a near-homophone of <paramref name="word"/>: the same
    /// Soundex key and at most two letters longer or shorter ("Claude" heard as "cloud").</summary>
    public static bool SoundsAlike(string word, string heard) =>
        !string.Equals(word, heard, StringComparison.Ordinal) && Math.Abs(word.Length - heard.Length) <= 2 &&
        SoundKey(word) is { } key && SoundKey(heard) == key;
    /// <summary>The recognized tokens with each near-homophone of one of <paramref name="replacementWords"/> (the new words
    /// the user asked for, normalized like <see cref="Tokens"/>) written as that word. A recognizer spells a brand name it
    /// does not know as the common word it sounds like ("Claude Code" as "cloud code"); the take said what it was asked
    /// to, so the word check must not fail it for that (voice-lab §8.11). A token that is itself expected is never
    /// rewritten.</summary>
    public static string[] NormalizingHomophones(IReadOnlyList<string> recognized, IReadOnlyList<string> expected, IReadOnlySet<string> replacementWords)
    {
        if (replacementWords.Count == 0) return recognized.ToArray();
        var expectedSet = expected.ToHashSet(StringComparer.Ordinal);
        var candidates = replacementWords.Where(expectedSet.Contains).Order(StringComparer.Ordinal).ToArray();
        return recognized.Select(heard => expectedSet.Contains(heard) ? heard
            : candidates.FirstOrDefault(word => SoundsAlike(word, heard)) ?? heard).ToArray();
    }
    /// <summary>The words of <paramref name="text"/> the window's recorded words do not already say: the user's own
    /// replacement words, normalized like <see cref="Tokens"/>. Without the window's words, every word of the text.</summary>
    public static IReadOnlySet<string> ReplacementWords(string text, IReadOnlyList<TimedWord> items, VoiceLabWindow window)
    {
        var asked = Tokens(VoiceLabAudioTags.StrippingTags(text)).ToHashSet(StringComparer.Ordinal);
        int first = -1, last = -1;
        for (var index = 0; index < items.Count; index++)
        {
            if (first < 0 && items[index].Id == window.FirstWordId) first = index;
            if (last < 0 && items[index].Id == window.LastWordId) last = index;
        }
        if (first < 0 || last < 0 || first > last) return asked;
        asked.ExceptWith(items.Skip(first).Take(last - first + 1).SelectMany(item => Tokens(VoiceLabAudioTags.StrippingTags(item.Text))));
        return asked;
    }
    public static VoiceLabTakeQaResult Evaluate(string expected, IReadOnlyList<string> recognized, float[] mixed, int sampleRate,
        IReadOnlyList<int> seams, double? speakerScore, double threshold, IReadOnlyList<bool>? generatedAfter = null, IReadOnlyList<double>? seamExcesses = null, bool hasTags = false,
        IReadOnlySet<string>? replacementWords = null)
    {
        // A null score: a short take whose voice waits for its run's pooled check (ADR-R37); its words and acoustics are checked now.
        if (speakerScore is { } given && (!double.IsFinite(given) || given is < -1 or > 1) || !double.IsFinite(threshold) || threshold is < 0 or > 1)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var expectedTokens = Tokens(VoiceLabAudioTags.StrippingTags(expected));
        var filtered = VoiceLabAudioTags.FilterScribeEvents(expectedTokens, recognized.SelectMany(Tokens).ToArray(), hasTags);
        // A near-homophone of the user's own new word is that word (§8.11); the stored match is the normalized one.
        var recognizedTokens = NormalizingHomophones(filtered, expectedTokens, replacementWords ?? new HashSet<string>(StringComparer.Ordinal));
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
        if (speakerScore is { } measured && measured < threshold) failures.Add(VoiceLabTakeQaFailure.Speaker);
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
    public bool Selectable => VoiceCheck.Complete && Failure is null && Qa is { Verdict: not VoiceLabTakeQaVerdict.Failed } && Audio is not null;
    public bool Fits => Audio?.Fit is VoiceLabFitResult.Exact;
    /// <summary>How this take's voice was checked (ADR-R37); a short take waits for its run's pooled check.</summary>
    public VoiceLabTakeVoiceCheck VoiceCheck { get; init; } = VoiceLabTakeVoiceCheck.PerTake;
    /// <summary>A waiting short take whose words, acoustics and fit already pass: its run needs no further candidate.</summary>
    public bool PassesBeforeVoiceCheck => VoiceCheck is VoiceLabTakeVoiceCheck.WaitingCheck && Failure is null && Audio is not null && Fits &&
        Qa is { Failures.Count: 0, TranscriptMatch: not null, LufsJumpLu: not null, PeakDbfs: not null };
    /// <summary>The row's short-phrase line (Mac <c>shortPhraseCopy</c>); null for a take checked on its own speech.</summary>
    public string? ShortPhraseCopy => VoiceCheck switch
    {
        VoiceLabTakeVoiceCheck.WaitingCheck => "waiting for the voice check",
        VoiceLabTakeVoiceCheck.ShortSpeechCheck { Pool: { Usable: true } evidence } => evidence.Mode == VoiceLabShortSpeechMode.Unmeasured
            ? "voice couldn't be measured (under 3 s of speech)"
            : Selectable && Qa?.SpeakerScore is { } score && double.IsFinite(score)
                ? "Short phrase · words checked · voice checked across " + evidence.TakeCount.ToString(System.Globalization.CultureInfo.InvariantCulture) + " takes" : null,
        _ => null
    };
    /// <summary>The run's pooled voice check applied to this waiting take (Mac <c>checkingVoice</c>): its score (none when
    /// unmeasured), an added speaker failure, or a consent/provider failure that replaces the row's. A separate words failure stays.</summary>
    public VoiceLabTakeRow CheckingVoice(VoiceLabTakeVoiceCheck check, double? score = null, bool speakerFailed = false, Exception? failure = null)
    {
        var qa = Qa is null ? null : Qa with
        {
            SpeakerScore = score,
            SpeakerUnmeasured = check.Evidence?.Mode == VoiceLabShortSpeechMode.Unmeasured && score is null,
            Failures = Array.AsReadOnly(speakerFailed && !Qa.Failures.Contains(VoiceLabTakeQaFailure.Speaker)
                ? Qa.Failures.Append(VoiceLabTakeQaFailure.Speaker).ToArray() : Qa.Failures.ToArray())
        };
        return this with { Qa = qa, VoiceCheck = check, Failure = failure ?? Failure };
    }
}
public enum VoiceLabTakeRunEnd { Completed, EarlyStop, Cancelled, Invalidated, Fatal }
public sealed record VoiceLabTakeRunResult(IReadOnlyList<VoiceLabTakeRow> Rows, VoiceLabTakeRunEnd End)
{
    public IReadOnlyList<VoiceLabTakeRow> Ranked => Rows.Where(row => row.Selectable).OrderBy(row => row.HasJoinAdvisory).ThenByDescending(row => row.Score).ThenBy(row => row.Index).ToArray();
    public VoiceLabTakeRow? Best => Ranked.FirstOrDefault();
    public VoiceLabTakeRow? BestAutomatic => Ranked.FirstOrDefault(row => row.AutomaticallySelectable);
}
