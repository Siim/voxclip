using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Typed failures before any paid call.</summary>
public enum VoiceLabLengthBudgetErrorCode
{
    /// <summary>Malformed geometry, rate, span or unrepresentable character range.</summary>
    InvalidInput,
    /// <summary>No positive text length and voiced duration are available.</summary>
    RateUnavailable
}
/// <summary>A length-budget refusal.</summary>
public sealed class VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode code) : Exception(code.ToString())
{
    /// <summary>The refusal code.</summary>
    public VoiceLabLengthBudgetErrorCode Code { get; } = code;
}
/// <summary>The project-local source of a rate for one voice/model/language key.</summary>
public enum VoiceLabSpeechRateSource
{
    /// <summary>Original take's voiced word spans.</summary>
    Transcript,
    /// <summary>Stored candidates' aligned spans.</summary>
    Candidates
}
/// <summary>A stored candidate for the caller-selected voice/model/language key.</summary>
public sealed record VoiceLabRateCandidate(string Text, double FirstCharStart, double LastCharEnd);
/// <summary>Letters/digits per second and the totals that produced it.</summary>
public sealed record VoiceLabSpeechRate(double CharactersPerSecond, VoiceLabSpeechRateSource Source, int TextLength, double VoicedSeconds);
/// <summary>The request's target and character range; full-take ranges are advisory.</summary>
public sealed record VoiceLabLengthRange(double TargetSeconds, double EdgePadSeconds, int BridgeLength, int MinChars, int MaxChars, bool Advisory);

/// <summary>Pure length budgeting with the binary64 evaluation order of Voice Lab §8.9.1.</summary>
public static class VoiceLabLengthBudget
{
    /// <summary>Use candidates when present; otherwise detect pauses on all transcript items and sum voiced word runs.</summary>
    public static VoiceLabSpeechRate Rate(IReadOnlyList<TimedWord> transcript, double pauseThresholdSeconds = 1,
        IReadOnlyList<VoiceLabRateCandidate>? candidates = null)
    {
        int length = 0;
        double seconds = 0;
        bool useCandidates = candidates is { Count: > 0 };
        if (useCandidates)
        {
            foreach (var candidate in candidates!)
            {
                if (!double.IsFinite(candidate.FirstCharStart) || !double.IsFinite(candidate.LastCharEnd)
                    || candidate.FirstCharStart < 0 || candidate.LastCharEnd <= candidate.FirstCharStart) throw Invalid();
                length += VoiceLabTextLength.Length(candidate.Text);
                seconds += candidate.LastCharEnd - candidate.FirstCharStart;
            }
        }
        else
        {
            Validate(transcript);
            if (!double.IsFinite(pauseThresholdSeconds) || pauseThresholdSeconds <= 0) throw Invalid();
            var pauses = EditingAlgorithms.DetectPauses(transcript, pauseThresholdSeconds);
            var breaks = pauses.Select(pause => pause.AfterIndex).ToHashSet();
            double? spanStart = null;
            double spanEnd = 0;
            for (int index = 0; index < transcript.Count; index++)
            {
                var word = transcript[index];
                if (word.Kind != WordKind.Word || (index > 0 && breaks.Contains(index - 1)))
                {
                    if (spanStart is double start) seconds += spanEnd - start;
                    spanStart = null;
                }
                if (word.Kind == WordKind.Word)
                {
                    length += VoiceLabTextLength.Length(word.Text);
                    spanStart ??= word.Start;
                    spanEnd = word.End;
                }
            }
            if (spanStart is double finalStart) seconds += spanEnd - finalStart;
        }
        if (length <= 0 || !double.IsFinite(seconds) || seconds <= 0)
            throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.RateUnavailable);
        double characters = length;
        double value = characters / seconds;
        if (!double.IsFinite(value) || value <= 0) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.RateUnavailable);
        return new(value, useCandidates ? VoiceLabSpeechRateSource.Candidates : VoiceLabSpeechRateSource.Transcript, length, seconds);
    }

    /// <summary>Trimmed-take duration estimate, including default lead and tail trims.</summary>
    public static double Estimate(string text, double rate)
    {
        if (!double.IsFinite(rate) || rate <= 0) throw Invalid();
        double length = VoiceLabTextLength.Length(text);
        double speech = length / rate;
        double lead = speech + VoiceLabPatchConstants.TTS_TRIM_LEAD;
        double result = lead + VoiceLabPatchConstants.TTS_TRIM_TAIL;
        if (!double.IsFinite(result)) throw Invalid();
        return result;
    }

    /// <summary>Low-level range for a placed window, its lendable-silence pair and the bridge letters/digits.</summary>
    public static VoiceLabLengthRange Calculate(VoiceLabWindow window, double? incomingSilence, double? outgoingSilence, int bridgeLength, double rate)
    {
        var geometry = Geometry(window, incomingSilence, outgoingSilence);
        return Range(geometry.Target, geometry.Edge, bridgeLength, rate, false);
    }

    /// <summary>Passage or Fix-with-AI line range; resolve the placed window's bridge IDs from source words.</summary>
    public static VoiceLabLengthRange Passage(VoiceLabWindow window, IReadOnlyList<TimedWord> transcript,
        double? incomingSilence, double? outgoingSilence, double rate)
    {
        int bridge = 0;
        HashSet<string> seen = [];
        foreach (string id in window.LeftBridgeWordIds.Concat(window.RightBridgeWordIds))
        {
            var word = transcript.FirstOrDefault(word => word.Id == id && word.Kind == WordKind.Word);
            if (!seen.Add(id) || word is null) throw Invalid();
            bridge += VoiceLabTextLength.Length(word.Text);
        }
        return Calculate(window, incomingSilence, outgoingSilence, bridge, rate);
    }

    /// <summary>Advisory first-word-start to last-word-end range, without bridge words or take-edge padding.</summary>
    public static VoiceLabLengthRange FullTake(IReadOnlyList<TimedWord> transcript, double rate)
    {
        Validate(transcript);
        var words = transcript.Where(word => word.Kind == WordKind.Word).ToArray();
        if (words.Length == 0) throw Invalid();
        double target = words[^1].End - words[0].Start;
        return Range(target, 0, 0, rate, true);
    }

    internal static (double Target, double Edge) Geometry(VoiceLabWindow window, double? incomingSilence, double? outgoingSilence)
    {
        if (!double.IsFinite(window.Start) || !double.IsFinite(window.End) || window.Start < 0 || window.End <= window.Start) throw Invalid();
        VoiceLabSeamKind[] kinds = [window.LeftSeam.Kind, window.RightSeam.Kind];
        double?[] silences = [incomingSilence, outgoingSilence];
        for (int index = 0; index < kinds.Length; index++)
        {
            if (kinds[index] == VoiceLabSeamKind.SynthToSynth) throw Invalid();
            if (kinds[index] == VoiceLabSeamKind.Hard)
            {
                if (silences[index] is not null) throw Invalid();
            }
            else if (silences[index] is not double silence || !double.IsFinite(silence) || silence < 0) throw Invalid();
        }
        double incoming = kinds[0] == VoiceLabSeamKind.None ? Math.Max(0, incomingSilence!.Value - VoiceLabPatchConstants.TTS_TRIM_LEAD) : 0;
        double outgoing = kinds[1] == VoiceLabSeamKind.None ? Math.Max(0, outgoingSilence!.Value - VoiceLabPatchConstants.TTS_TRIM_TAIL) : 0;
        double edge = incoming + outgoing;
        double duration = window.End - window.Start;
        double target = duration - edge;
        if (!double.IsFinite(target) || target <= 0) throw Invalid();
        return (target, edge);
    }

    static VoiceLabLengthRange Range(double target, double edge, int bridge, double rate, bool advisory)
    {
        if (!double.IsFinite(target) || target <= 0 || !double.IsFinite(rate) || rate <= 0 || bridge < 0) throw Invalid();
        double lowAim = VoiceLabPatchConstants.LENGTH_AIM_MIN * target;
        double lowLead = lowAim - VoiceLabPatchConstants.TTS_TRIM_LEAD;
        double lowTail = lowLead - VoiceLabPatchConstants.TTS_TRIM_TAIL;
        double lowScaled = lowTail * rate;
        double highAim = VoiceLabPatchConstants.LENGTH_AIM_MAX * target;
        double highLead = highAim - VoiceLabPatchConstants.TTS_TRIM_LEAD;
        double highTail = highLead - VoiceLabPatchConstants.TTS_TRIM_TAIL;
        double highScaled = highTail * rate;
        double bridgeCount = bridge;
        double minimum = Math.Max(1, Math.Floor(lowScaled) - bridgeCount);
        double maximum = Math.Max(minimum, Math.Ceiling(highScaled) - bridgeCount);
        if (!double.IsFinite(minimum) || !double.IsFinite(maximum) || maximum > int.MaxValue) throw Invalid();
        return new(target, edge, bridge, (int)minimum, (int)maximum, advisory);
    }

    static void Validate(IReadOnlyList<TimedWord> transcript)
    {
        double previous = 0;
        foreach (var word in transcript)
        {
            if (!double.IsFinite(word.Start) || !double.IsFinite(word.End) || word.Start < previous || word.End < word.Start) throw Invalid();
            previous = word.Start;
        }
    }

    static VoiceLabLengthBudgetException Invalid() => new(VoiceLabLengthBudgetErrorCode.InvalidInput);
}
