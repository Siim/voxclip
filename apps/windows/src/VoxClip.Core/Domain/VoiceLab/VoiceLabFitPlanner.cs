#pragma warning disable CS1591 // Fit planner members follow voice-lab.md §8.9.2 and match the Swift Core.
using System.Buffers;
using System.Globalization;
using System.Text;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The trimmed take (§8.7 step 1) on its paid asset, as the fit planner reads it (§8.9.2). AssetFrames counts every
/// frame of the paid asset, fewer than 2^31. The §8.7 trims are in asset seconds; each lands on the frame jsRound gives. Words
/// come from the take's character alignment (§8.8), in asset seconds and in order. Envelope is the paid asset's 10 ms RMS
/// envelope at its own rate: every whole frame from its first sample.</summary>
public sealed record VoiceLabFitTake(long AssetFrames, int AssetSampleRate, double TrimStart, double TrimEnd,
    IReadOnlyList<VoiceLabWord> Words, AudioEnvelope Envelope);

public enum VoiceLabFitEditKind { Remove, Insert }

/// <summary>One pause edit in paid-asset frames. A removal drops frames [Start, Start + Count), and an insertion plays them
/// twice. Either way the playhead jumps once, at Start for a removal and at Start + Count for an insertion, with one
/// equal-power SEAM_FADE join centred on the jump: floor(N/2) frames before it and ceil(N/2) after.</summary>
public sealed record VoiceLabFitEdit(VoiceLabFitEditKind Kind, long Start, long Count);

/// <summary>One seam of a fitted take: silence on the asset grid, a take-edge pad included, and source samples borrowed from
/// its gap.</summary>
public sealed record VoiceLabFitSeam(long PadFrames, long BorrowedSamples);

/// <summary>A fit plan (§8.9.2 Output): the incoming pad, the edited take between the final trims and the outgoing pad. The
/// rounding residual may have moved one trim by a frame. A seam that borrowed sits on the source grid; the other keeps the
/// window's time. OutputFrames counts asset frames between the handles; an exact plan has jsRound(n × assetRate / sourceRate)
/// for its window's n. Words are the aligned words relative to the output start, all synthetic: each keeps its aligned frames
/// and moves by the incoming pad and the edits before it.</summary>
public sealed record VoiceLabFitPlan(IReadOnlyList<VoiceLabFitEdit> Edits, VoiceLabFitSeam Incoming, VoiceLabFitSeam Outgoing,
    long TrimStartFrame, long TrimEndFrame, double WindowStart, double WindowEnd, long WindowStartSample, long WindowEndSample,
    long OutputFrames, IReadOnlyList<VoiceLabWord> Words);

/// <summary>Exact fills the window. ChangedDuration keeps every edit at its limit and lasts duration(W) + ResidualSeconds, with
/// the sign of ρ (§8.9 step 3); NaturalOut is e + D, the take's length before any edit.</summary>
public abstract record VoiceLabFitResult(VoiceLabFitPlan Plan)
{
    public sealed record Exact(VoiceLabFitPlan Plan) : VoiceLabFitResult(Plan);
    public sealed record ChangedDuration(VoiceLabFitPlan Plan, double NaturalOut, double ResidualSeconds) : VoiceLabFitResult(Plan);
}

/// <summary>§8.9.2 silence-only duration fit: pure, deterministic and identical on both platforms (fit-cases.json). It edits
/// only the take's pauses and silence at the seams; every voiced frame is copied, which Plan checks before it returns.</summary>
public static class VoiceLabFitPlanner
{
    /// <summary>Paid-asset frames below this keep every product of the proportional split inside long.</summary>
    internal const long FrameLimit = 1L << 31;
    /// <summary>Source rates the planner accepts: the schema's 1 Hz floor, and a ceiling under which no borrow overflows
    /// long.</summary>
    internal const double MinSourceRate = 1, MaxSourceRate = 1_000_000;

    /// <summary>One internal pause: the editable run after word Word, in paid-asset frames.</summary>
    sealed record Pause(int Word, long Start, long End, bool Punctuation)
    {
        internal long Length => End - Start;
    }

    /// <summary>Plans the fit of take into window. incomingSilence and outgoingSilence are the §8.9.2 outside silences in
    /// seconds: for a gap seam the silence it can lend, which VoiceLabWindowPlanner.LendableSilence measures, for a take edge
    /// (None) the silence to the window's nearest word, and null for a hard seam. tokens are the patch tokens, one per
    /// word.</summary>
    public static VoiceLabFitResult Plan(VoiceLabWindow window, double? incomingSilence, double? outgoingSilence,
        VoiceLabFitTake take, IReadOnlyList<string> tokens, double sourceSampleRate)
    {
        var rate = sourceSampleRate;
        VoiceLabSeamKind[] kinds = [window.LeftSeam.Kind, window.RightSeam.Kind];
        double?[] silences = [incomingSilence, outgoingSilence];
        var reach = Validate(window, kinds, silences, take, rate);
        double assetRate = take.AssetSampleRate;
        var total = take.AssetFrames;
        var size = VoiceLabGeometry.FrameSize(assetRate);
        var t0 = VoiceLabGeometry.Samples(take.TrimStart, assetRate);
        var t1 = VoiceLabGeometry.Samples(take.TrimEnd, assetRate);
        var spans = WordSpans(take, tokens, t0, t1, rate);
        var unvoiced = take.Envelope.Rms.Select(level => (double)level < VoiceLabPatchConstants.VOICED_FRAME_LEVEL).ToArray();
        var pauses = FindPauses(spans, unvoiced, size, tokens);

        // The take must fill w = duration(W) − e frames; ρ > 0 means it is too long.
        var fade = VoiceLabGeometry.Samples(VoiceLabPatchConstants.SEAM_FADE, assetRate);
        var leadIn = spans[0].Start - t0;
        var tailOut = t1 - spans[^1].End;
        var edgeIn = kinds[0] == VoiceLabSeamKind.None
            ? Math.Max(0, VoiceLabGeometry.Samples(silences[0] ?? 0, assetRate) - leadIn) : 0;
        var edgeOut = kinds[1] == VoiceLabSeamKind.None
            ? Math.Max(0, VoiceLabGeometry.Samples(silences[1] ?? 0, assetRate) - tailOut) : 0;
        var n = window.EndSample - window.StartSample;
        var target = FramesOf(n, assetRate, rate);
        var natural = edgeIn + edgeOut + t1 - t0;
        var rho = natural - target;
        var shorten = rho > 0;
        var lengths = pauses.Select(pause => pause.Length).ToArray();
        var rooms = RoomsOf(pauses, shorten, assetRate, fade);
        var alloc = new long[pauses.Count];
        var remaining = Math.Abs(rho);
        foreach (var punctuation in new[] { true, false })
        {
            var group = Enumerable.Range(0, pauses.Count).Where(index => pauses[index].Punctuation == punctuation).ToArray();
            remaining = Spread(remaining, group, lengths, rooms, alloc);
        }

        // Seams: borrow source samples into a gap, keeping PAUSE_SLACK_KEEP beside the kept word, or pad silence.
        long[] borrow = [0, 0];
        long[] pad = [edgeIn, edgeOut];
        long[] lend = [0, 0];
        var exact = true;
        if (remaining > 0 && shorten)
        {
            var keep = VoiceLabGeometry.Samples(VoiceLabPatchConstants.PAUSE_SLACK_KEEP, rate);
            long[] caps = [Math.Max(0, reach[0] - keep), Math.Max(0, reach[1] - keep)];
            lend = caps;
            var widest = FramesOf(n + caps[0] + caps[1], assetRate, rate);
            if (target + remaining <= widest)
            {
                var need = (long)EditingMath.Round(remaining * rate / assetRate);
                borrow = Split(need, caps);
            }
            else
            {
                borrow = caps; exact = false;
            }
        }
        else if (remaining > 0)
        {
            var gapPad = VoiceLabGeometry.Samples(VoiceLabPatchConstants.SEAM_PAD_MAX, assetRate);
            var hardPad = VoiceLabGeometry.Samples(VoiceLabPatchConstants.HARD_SEAM_PAD_MAX, assetRate);
            long[] caps = [kinds[0] == VoiceLabSeamKind.Hard ? hardPad : gapPad, kinds[1] == VoiceLabSeamKind.Hard ? hardPad : gapPad];
            var extra = Split(remaining, caps);
            pad = [pad[0] + extra[0], pad[1] + extra[1]];
            exact = extra[0] + extra[1] == remaining;
        }
        var deltas = alloc.Select(count => shorten ? -count : count).ToArray();
        var windowFrames = FramesOf(n + borrow[0] + borrow[1], assetRate, rate);
        var output = pad[0] + t1 - t0 + deltas.Sum() + pad[1];
        if (exact && output != windowFrames)
        {
            // The rounding residual: a gap or edge pad, incoming first, while it stays non-negative; then the tail trim,
            // then the lead trim, each keeping the aligned words inside the trim and the trim inside the asset.
            var residual = windowFrames - output;
            if (kinds[0] != VoiceLabSeamKind.Hard && pad[0] + residual >= 0) pad[0] += residual;
            else if (kinds[1] != VoiceLabSeamKind.Hard && pad[1] + residual >= 0) pad[1] += residual;
            else if (spans[^1].End <= t1 + residual && t1 + residual <= total) t1 += residual;
            else if (0 <= t0 - residual && t0 - residual <= spans[0].Start) t0 -= residual;
            else if (borrow[0] + borrow[1] < lend[0] + lend[1])
            {
                // Nothing can take a negative residual: the seams borrow the fewest more source samples whose widened
                // window holds the planned frames, within their limits and split again, and the residual, now zero or
                // more, pads the gap seam that borrowed, the incoming one first.
                var lent = borrow[0] + borrow[1];
                while (lent < lend[0] + lend[1] && FramesOf(n + lent, assetRate, rate) < output) lent++;
                borrow = Split(lent, lend);
                windowFrames = FramesOf(n + lent, assetRate, rate);
                if (windowFrames < output) throw TouchesVoice();
                pad[borrow[0] > 0 ? 0 : 1] += windowFrames - output;
            }
            else throw TouchesVoice();
            output = windowFrames;
        }

        var edits = new List<VoiceLabFitEdit>();
        var shifts = new long[take.Words.Count];
        for (var index = 0; index < pauses.Count; index++)
        {
            if (alloc[index] <= 0) continue;
            var pause = pauses[index];
            var start = pause.Start + (pause.Length - alloc[index]) / 2;
            edits.Add(new VoiceLabFitEdit(shorten ? VoiceLabFitEditKind.Remove : VoiceLabFitEditKind.Insert, start, alloc[index]));
            for (var word = pause.Word + 1; word < take.Words.Count; word++) shifts[word] += deltas[index];
        }
        var startSample = window.StartSample - borrow[0];
        var endSample = window.EndSample + borrow[1];
        var windowStart = startSample / rate;
        var windowEnd = endSample / rate;
        var residualSeconds = (output - windowFrames) / assetRate;
        // Each word ends inside the output the recipe states (§10.5): the window, plus residualSeconds after a partial fit.
        var duration = exact ? windowEnd - windowStart : windowEnd - windowStart + residualSeconds;
        var lead = pad[0] - t0;
        var words = take.Words.Select((word, index) =>
        {
            var offset = (double)(lead + shifts[index]) / assetRate;
            return new VoiceLabWord(word.Text, Math.Min(word.Start + offset, duration), Math.Min(word.End + offset, duration), true);
        }).ToArray();
        Validate(words, duration, rate);
        var plan = new VoiceLabFitPlan(edits, new VoiceLabFitSeam(pad[0], borrow[0]), new VoiceLabFitSeam(pad[1], borrow[1]), t0, t1,
            windowStart, windowEnd, startSample, endSample, output, words);
        CheckVoice(plan, spans, unvoiced, size, fade);
        if (exact) return new VoiceLabFitResult.Exact(plan);
        return new VoiceLabFitResult.ChangedDuration(plan, natural / assetRate, residualSeconds);
    }

    /// <summary>jsRound(n × assetRate / sourceRate): asset frames for n source samples.</summary>
    static long FramesOf(long samples, double assetRate, double rate) => (long)EditingMath.Round(samples * assetRate / rate);

    static VoiceLabGeometryException Invalid() => VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);

    /// <summary>The input checks that come before the words, all InvalidInput. Returns the source samples of each gap seam's
    /// outside silence, 0 for the other kinds.</summary>
    static long[] Validate(VoiceLabWindow window, VoiceLabSeamKind[] kinds, double?[] silences, VoiceLabFitTake take, double rate)
    {
        const double limit = VoiceLabGeometry.SampleLimit;
        var total = take.AssetFrames;
        if (!double.IsFinite(rate) || rate < MinSourceRate || rate > MaxSourceRate || take.AssetSampleRate <= 0 || total <= 0 ||
            total >= FrameLimit) throw Invalid();
        double assetRate = take.AssetSampleRate;
        if (kinds.Contains(VoiceLabSeamKind.SynthToSynth) || window.StartSample < 0 || window.StartSample >= window.EndSample ||
            !(window.EndSample < limit) || window.LeftSeam.Sample != window.StartSample || window.RightSeam.Sample != window.EndSample ||
            (kinds[0] == VoiceLabSeamKind.None && window.StartSample != 0) || !double.IsFinite(window.Start) ||
            !double.IsFinite(window.End)) throw Invalid();
        for (var side = 0; side < 2; side++)
        {
            if ((kinds[side] == VoiceLabSeamKind.Hard) != (silences[side] is null)) throw Invalid();
            if (silences[side] is { } silence &&
                !(double.IsFinite(silence) && silence >= 0 && silence * rate < limit && silence * assetRate < limit)) throw Invalid();
        }
        long[] reach = [kinds[0] == VoiceLabSeamKind.Gap ? VoiceLabGeometry.Samples(silences[0] ?? 0, rate) : 0,
            kinds[1] == VoiceLabSeamKind.Gap ? VoiceLabGeometry.Samples(silences[1] ?? 0, rate) : 0];
        if (reach[0] > window.StartSample || !((window.EndSample + reach[1]) * assetRate < limit)) throw Invalid();
        var levels = take.Envelope.Rms;
        var size = VoiceLabGeometry.FrameSize(assetRate);
        if (take.Envelope.SampleRate != take.AssetSampleRate || levels.Count != total / size ||
            levels.Any(level => !float.IsFinite(level) || level < 0)) throw Invalid();
        // The trims are compared in seconds before either becomes frames, so a tail trim far below zero cannot overflow.
        if (!double.IsFinite(take.TrimStart) || !double.IsFinite(take.TrimEnd) || take.TrimStart < 0 || !(take.TrimStart < take.TrimEnd) ||
            !(take.TrimStart * assetRate < limit) || !(take.TrimEnd * assetRate < limit)) throw Invalid();
        var t0 = VoiceLabGeometry.Samples(take.TrimStart, assetRate);
        var t1 = VoiceLabGeometry.Samples(take.TrimEnd, assetRate);
        if (t0 < 0 || t0 >= t1 || t1 > total) throw Invalid();
        return reach;
    }

    /// <summary>The words' frame spans after the word checks: AlignmentUnavailable without words, AlignmentMismatch unless each
    /// word has a non-empty patch token, and InvalidWordTiming for words out of order, empty or outside the trims. A word covers
    /// every paid-asset frame its aligned span touches.</summary>
    static (long Start, long End)[] WordSpans(VoiceLabFitTake take, IReadOnlyList<string> tokens, long t0, long t1, double rate)
    {
        if (take.Words.Count == 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.AlignmentUnavailable);
        if (tokens.Count != take.Words.Count || tokens.Any(string.IsNullOrEmpty) || take.Words.Any(word => string.IsNullOrEmpty(word.Text)))
            throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.AlignmentMismatch);
        double assetRate = take.AssetSampleRate;
        var previous = 0.0;
        foreach (var word in take.Words)
        {
            if (!double.IsFinite(word.Start) || !double.IsFinite(word.End) || !(previous <= word.Start) || !(word.Start < word.End) ||
                (word.End - word.Start) * rate < 1 ||
                !(word.End * assetRate < VoiceLabGeometry.SampleLimit)) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidWordTiming);
            previous = word.End;
        }
        var spans = take.Words.Select(word => (Start: (long)Math.Floor(word.Start * assetRate), End: (long)Math.Ceiling(word.End * assetRate)))
            .ToArray();
        if (spans[0].Start < t0 || spans[^1].End > t1) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidWordTiming);
        return spans;
    }

    static void Validate(IReadOnlyList<VoiceLabWord> words, double duration, double rate)
    {
        double previous = 0;
        var output = VoiceLabGeometry.Samples(duration, rate);
        foreach (var word in words)
        {
            if (word.Start < previous || word.End <= word.Start || word.End > duration ||
                VoiceLabGeometry.Samples(word.End, rate) <= VoiceLabGeometry.Samples(word.Start, rate) ||
                VoiceLabGeometry.Samples(word.End, rate) > output)
                throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidWordTiming);
            previous = word.End;
        }
    }

    /// <summary>The editable run between each pair of words: the longest run of whole envelope frames, counted from the paid
    /// asset's first sample, between the two spans with every frame below VOICED_FRAME. Ties go to the earliest run.</summary>
    static List<Pause> FindPauses((long Start, long End)[] spans, bool[] unvoiced, long size, IReadOnlyList<string> tokens)
    {
        var pauses = new List<Pause>();
        for (var word = 0; word < spans.Length - 1; word++)
        {
            var lo = (spans[word].End + size - 1) / size;
            var hi = Math.Min(spans[word + 1].Start / size, unvoiced.LongLength);
            long best = 0, first = 0, run = 0;
            for (var block = lo; block < hi; block++)
            {
                run = unvoiced[block] ? run + 1 : 0;
                if (run > best) { best = run; first = block + 1 - run; }
            }
            if (best > 0) pauses.Add(new Pause(word, first * size, (first + best) * size, IsPunctuation(tokens[word])));
        }
        return pauses;
    }

    /// <summary>General category P of the token's last scalar: Pc, Pd, Ps, Pe, Pi, Pf or Po.</summary>
    internal static bool IsPunctuation(string token)
        => Rune.DecodeLastFromUtf16(token, out var last, out _) == OperationStatus.Done && Rune.GetUnicodeCategory(last) is
            UnicodeCategory.ConnectorPunctuation or UnicodeCategory.DashPunctuation or UnicodeCategory.OpenPunctuation or
            UnicodeCategory.ClosePunctuation or UnicodeCategory.InitialQuotePunctuation or UnicodeCategory.FinalQuotePunctuation or
            UnicodeCategory.OtherPunctuation;

    /// <summary>How far each pause may change. Shortening stops at the pause's floor. Lengthening repeats frames of the run
    /// once, so the repeated frames and the join fit in it, and stops at PAUSE_GROWTH_MAX; a run no longer than SEAM_FADE has
    /// no room.</summary>
    static long[] RoomsOf(List<Pause> pauses, bool shorten, double assetRate, long fade)
    {
        if (shorten)
        {
            var punctuation = VoiceLabGeometry.Samples(VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, assetRate);
            var phrase = VoiceLabGeometry.Samples(VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE, assetRate);
            return pauses.Select(pause => Math.Max(0, pause.Length - (pause.Punctuation ? punctuation : phrase))).ToArray();
        }
        var growth = VoiceLabGeometry.Samples(VoiceLabPatchConstants.PAUSE_GROWTH_MAX, assetRate);
        return pauses.Select(pause => pause.Length > fade ? Math.Min(growth, pause.Length - fade) : 0).ToArray();
    }

    /// <summary>Distribution steps 1 and 2: amount frames over the pauses in group, in proportion to their lengths. Every pause
    /// whose exact share would pass its room stops at the room, and the rest is spread again over the others. The last spread
    /// is split by the largest-remainder rule: each pause takes the floor of its share, and the frames left over go one each to
    /// the largest remainders, ties to the earlier pause. Returns what the group cannot hold. An amount that covers every room
    /// fills each pause to its room, as the spread would; below that, every product stays under 2^62.</summary>
    internal static long Spread(long amount, IReadOnlyList<int> group, long[] lengths, long[] rooms, long[] alloc)
    {
        var active = group.Where(index => rooms[index] > 0).ToList();
        var capacity = active.Sum(index => rooms[index]);
        if (amount >= capacity)
        {
            foreach (var index in active) alloc[index] = rooms[index];
            return amount - capacity;
        }
        while (amount > 0 && active.Count > 0)
        {
            var total = active.Sum(index => lengths[index]);
            var full = active.Where(index => amount * lengths[index] > rooms[index] * total).ToList();
            if (full.Count > 0)
            {
                foreach (var index in full) { alloc[index] = rooms[index]; amount -= rooms[index]; }
                active.RemoveAll(full.Contains);
                continue;
            }
            var shares = active.Select(index => amount * lengths[index] / total).ToArray();
            var remainders = active.Select(index => amount * lengths[index] % total).ToArray();
            var left = (int)(amount - shares.Sum());
            var order = Enumerable.Range(0, active.Count).OrderByDescending(position => remainders[position]).ThenBy(position => position);
            foreach (var position in order.Take(left)) shares[position]++;
            for (var position = 0; position < active.Count; position++) alloc[active[position]] = shares[position];
            amount = 0;
        }
        return amount;
    }

    /// <summary>Distribution step 3: half at each seam, the incoming seam taking the odd frame or sample. A seam at its limit
    /// passes the rest to the other seam.</summary>
    internal static long[] Split(long amount, long[] caps)
    {
        var first = Math.Min(amount - amount / 2, caps[0]);
        var second = Math.Min(amount / 2, caps[1]);
        var rest = amount - first - second;
        var more = Math.Min(rest, caps[1] - second);
        return [first + Math.Min(rest - more, caps[0] - first), second + more];
    }

    /// <summary>The never-touch-voice invariant (§8.9.2 Edits): every edit and its join lie inside the trim, in order and apart,
    /// clear of every word span and of every envelope frame at or above VOICED_FRAME, so every other output sample is a copy of
    /// its paid frame; and the output length adds up.</summary>
    static void CheckVoice(VoiceLabFitPlan plan, (long Start, long End)[] spans, bool[] unvoiced, long size, long fade)
    {
        if (plan.Incoming.PadFrames < 0 || plan.Outgoing.PadFrames < 0) throw TouchesVoice();
        var cursor = plan.TrimStartFrame;
        var frames = plan.Incoming.PadFrames + plan.TrimEndFrame - plan.TrimStartFrame + plan.Outgoing.PadFrames;
        foreach (var edit in plan.Edits)
        {
            var lo = edit.Start - fade / 2;
            var hi = edit.Start + edit.Count + fade - fade / 2;
            if (edit.Count <= 0 || cursor > lo || hi > plan.TrimEndFrame || spans.Any(span => span.Start < hi && lo < span.End))
                throw TouchesVoice();
            for (var block = lo / size; block * size < hi; block++)
                if (block >= unvoiced.LongLength || !unvoiced[block]) throw TouchesVoice();
            cursor = hi;
            frames += edit.Kind == VoiceLabFitEditKind.Insert ? edit.Count : -edit.Count;
        }
        if (frames != plan.OutputFrames) throw TouchesVoice();
    }

    static VoiceLabGeometryException TouchesVoice() => VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.FitTouchesVoice);
}
