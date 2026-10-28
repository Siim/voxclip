#pragma warning disable CS1591 // Patch geometry members follow voice-lab.md §8.3-§8.4 and §10.5 and match the Swift Core.
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Patch-mode constants, voice-lab.md §8.3. Seconds unless the name says otherwise; the Mac Core uses the same names.</summary>
public static class VoiceLabPatchConstants
{
    public const double SEAM_MIN_GAP = 0.12;
    public const int SEAM_SEARCH_WORDS = 3;
    public const double SEAM_FADE = 0.020;
    public const double HARD_SEAM_FADE = 0.012;
    public const double TTS_TRIM_LEAD = 0.03;
    public const double TTS_TRIM_TAIL = 0.06;
    public const double PAUSE_SLACK_KEEP = 0.15;
    /// <summary>The silence-fit limits and the length aim (§8.9.1, §8.9.2).</summary>
    public const double SEAM_PAD_MAX = 0.3;
    public const double HARD_SEAM_PAD_MAX = 0.060;
    public const double PAUSE_FLOOR_PHRASE = 0.060;
    public const double PAUSE_FLOOR_PUNCT = 0.150;
    public const double PAUSE_GROWTH_MAX = 0.25;
    public const double LENGTH_AIM_MIN = 0.92;
    public const double LENGTH_AIM_MAX = 0.97;
    /// <summary>dBFS of a 10 ms RMS frame.</summary>
    public const double VOICED_FRAME = -45.0;
    /// <summary>10^(VOICED_FRAME / 20) rounded to binary64, so no platform pow decides whether a frame is voiced.</summary>
    public const double VOICED_FRAME_LEVEL = 0.005623413251903491;
    /// <summary>Seconds in one frame of the 10 ms RMS envelope: the frames VOICED_FRAME measures and seams are placed on.</summary>
    public const double RMS_FRAME = 0.010;
    public const double ROOM_TONE_MIN_RUN = 0.5;
}

public enum VoiceLabGeometryErrorCode
{
    InvalidInput, UnknownWord, ReversedWords, InsertionUnsupported, WindowCrossesWord, SeamFadeOutsideTake, SeamFadeCrossesCut,
    WindowTooShort, OverlapsReplacement, AdjacentReplacement, InsufficientHandle, AlignmentUnavailable, AlignmentMismatch,
    InvalidWordTiming, NoVoicedAudio, RoomToneUnavailable,
    /// <summary>A fit plan would edit voiced audio or lose count of its frames. The planner checks every plan before it
    /// returns it (§8.9.2), so this is a planner fault, never a property of the take.</summary>
    FitTouchesVoice
}

/// <summary>Typed refusals from the patch geometry. Nothing here shortens a fade or substitutes a fallback. SegmentId names
/// the enabled replacement an OverlapsReplacement or AdjacentReplacement window would overlap, touch or starve of kept
/// source. With InvalidInput it names a replacement whose own seam prepare refuses even without the window, so the scope
/// does not render as it stands (§8.4 step 6).</summary>
public sealed class VoiceLabGeometryException(VoiceLabGeometryErrorCode code, string? wordId = null, bool? incoming = null,
    long? needed = null, long? available = null, string? segmentId = null) : Exception(code.ToString())
{
    public VoiceLabGeometryErrorCode Code { get; } = code;
    public string? WordId { get; } = wordId;
    public bool? Incoming { get; } = incoming;
    public long? Needed { get; } = needed;
    public long? Available { get; } = available;
    public string? SegmentId { get; } = segmentId;
    public bool? TakeEdgeIsStart { get; init; }
}

/// <summary>One window edge. Time and sample agree under jsRound; None is a real take edge with no fade.</summary>
public sealed record VoiceLabSeamPlacement(VoiceLabSeamKind Kind, double Time, long Sample, long FadeSamples);

/// <summary>A replace window with its bridge words, in source seconds and on the source sample grid (§8.4).</summary>
public sealed record VoiceLabWindow(string FirstWordId, string LastWordId, IReadOnlyList<string> LeftBridgeWordIds,
    IReadOnlyList<string> RightBridgeWordIds, double Start, double End, long StartSample, long EndSample,
    VoiceLabSeamPlacement LeftSeam, VoiceLabSeamPlacement RightSeam);

/// <summary>Source-grid arithmetic shared by the patch geometry. Every second-to-sample conversion is editing §4.1 jsRound.</summary>
internal static class VoiceLabGeometry
{
    /// <summary>Sample counts below 2^53 stay exact in binary64.</summary>
    internal const double SampleLimit = 9007199254740992.0;
    internal static long Samples(double seconds, double rate) => (long)EditingMath.Round(seconds * rate);
    /// <summary>AudioEnvelopeBuilder's 10 ms frame: frame i covers samples [i·size, (i+1)·size).</summary>
    internal static long FrameSize(double rate) => (long)Math.Max(1, EditingMath.Round(rate * VoiceLabPatchConstants.RMS_FRAME));
    internal static VoiceLabGeometryException Error(VoiceLabGeometryErrorCode code, string? wordId = null) => new(code, wordId);
    /// <summary>Items follow the project transcript rule (ProjectSerialization): unique IDs, finite times, 0 &lt;= start &lt; end
    /// and starts in transcript order. An envelope, when given, is on the source rate with finite, non-negative levels.</summary>
    internal static void Check(double rate, long totalSamples, AudioEnvelope? envelope, IReadOnlyList<TimedWord> items)
    {
        if (!double.IsFinite(rate) || rate <= 0 || totalSamples <= 0 || totalSamples >= SampleLimit ||
            envelope is not null && (envelope.SampleRate != rate || envelope.Rms.Count == 0 || envelope.Rms.Any(level => !float.IsFinite(level) || level < 0)) ||
            items.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != items.Count)
            throw Error(VoiceLabGeometryErrorCode.InvalidInput);
        var previous = 0.0;
        foreach (var item in items)
        {
            if (!double.IsFinite(item.Start) || !double.IsFinite(item.End) || !(previous <= item.Start) || !(item.Start < item.End) ||
                item.End * rate >= SampleLimit) throw Error(VoiceLabGeometryErrorCode.InvalidInput);
            previous = item.Start;
        }
    }
    /// <summary>The parts of sorted, disjoint sample intervals that lie outside every range.</summary>
    internal static IReadOnlyList<MediaInterval> Subtract(IEnumerable<MediaInterval> intervals, IEnumerable<MediaInterval> ranges)
    {
        var removed = ranges.ToArray();
        var result = new List<MediaInterval>();
        foreach (var interval in intervals)
        {
            var parts = new List<MediaInterval> { interval };
            foreach (var range in removed)
                parts = parts.SelectMany(part => new[] { new MediaInterval(part.StartSample, Math.Min(part.EndSample, range.StartSample)),
                    new MediaInterval(Math.Max(part.StartSample, range.EndSample), part.EndSample) }).Where(part => part.EndSample > part.StartSample).ToList();
            result.AddRange(parts);
        }
        return result;
    }
}

/// <summary>§8.4 join placement for a replace hunk [a..b]. Insertion stays reserved by §10.1.</summary>
public static class VoiceLabWindowPlanner
{
    /// <summary>§8.4: a hard seam sits min(0.03, gap / 2) outside the replaced word.</summary>
    const double HardSeamReach = 0.03;

    /// <summary>A synth piece of the output plan: an enabled replacement in the scope, with its selected recipe's seams, or
    /// the window being placed.</summary>
    sealed record SynthPiece(string Id, bool IsWindow, double Start, double End, MediaInterval Range,
        VoiceLabSeamKind InKind, long InFade, VoiceLabSeamKind OutKind, long OutFade);

    /// <summary>The synth pieces of an output plan in source order and the kept source pieces around them, in samples
    /// (§10.5).</summary>
    sealed class SeamLayout(SynthPiece[] elements, IReadOnlyList<MediaInterval> pieces, long total)
    {
        public SynthPiece[] Elements { get; } = elements;

        /// <summary>The kept pieces between element index - 1 (or the take start) and element index (or the take end).</summary>
        public MediaInterval[] Run(int index)
        {
            var lo = index > 0 ? Elements[index - 1].Range.EndSample : 0;
            var hi = index < Elements.Length ? Elements[index].Range.StartSample : total;
            return pieces.Where(piece => lo <= piece.StartSample && piece.EndSample <= hi).ToArray();
        }
        /// <summary>The kept piece that ends at element index's start, or starts at its end, in samples.</summary>
        public long Beside(int index, bool incoming)
        {
            var at = incoming ? Elements[index].Range.StartSample : Elements[index].Range.EndSample;
            return pieces.Where(piece => (incoming ? piece.EndSample : piece.StartSample) == at).Select(piece => piece.EndSample - piece.StartSample).FirstOrDefault();
        }
        /// <summary>§8.4 for one seam of element index: kinds as prepare takes them (None with nothing beside it, SynthToSynth only
        /// between touching pieces that agree), and a fade's outer half in the kept source right beside it.</summary>
        public bool SideHolds(int index, bool incoming)
        {
            var element = Elements[index];
            var other = incoming ? index - 1 : index + 1;
            var (kind, fade) = incoming ? (element.InKind, element.InFade) : (element.OutKind, element.OutFade);
            var beside = Run(incoming ? index : index + 1);
            if (kind == VoiceLabSeamKind.None) return beside.Length == 0 && (other < 0 || other >= Elements.Length);
            if (kind != VoiceLabSeamKind.SynthToSynth) return Beside(index, incoming) >= (incoming ? fade / 2 : fade - fade / 2);
            if (beside.Length != 0 || other < 0 || other >= Elements.Length) return false;
            var (facingKind, facingFade) = incoming ? (Elements[other].OutKind, Elements[other].OutFade) : (Elements[other].InKind, Elements[other].InFade);
            var touching = incoming ? Elements[other].Range.EndSample == element.Range.StartSample : element.Range.EndSample == Elements[other].Range.StartSample;
            return touching && facingKind == VoiceLabSeamKind.SynthToSynth && facingFade == fade;
        }
        /// <summary>Prepare's overlappingFades rule between elements index and index + 1: the kept source between them holds the
        /// outer halves of both fades.</summary>
        public bool FadesFit(int index)
        {
            var outFade = Elements[index].OutFade;
            var inFade = Elements[index + 1].InFade;
            return Run(index + 1).Sum(piece => piece.EndSample - piece.StartSample) >= outFade - outFade / 2 + inFade / 2;
        }
        /// <summary>The fades rule across one kept piece that fills the whole gap between elements index and index + 1.</summary>
        public bool PairHolds(int index)
        {
            var between = Run(index + 1);
            return between.Length != 1 || between[0] != new MediaInterval(Elements[index].Range.EndSample, Elements[index + 1].Range.StartSample) ||
                FadesFit(index);
        }
        /// <summary>Prepare's own rule for one seam of element index, which allows a fade across a cut: the neighbouring output
        /// piece is source and holds the fade's outer half, and the fades on either side of the kept source between this element
        /// and the next one do not overlap.</summary>
        public bool PrepareHolds(int index, bool incoming)
        {
            var (kind, fade) = incoming ? (Elements[index].InKind, Elements[index].InFade) : (Elements[index].OutKind, Elements[index].OutFade);
            if (kind is VoiceLabSeamKind.None or VoiceLabSeamKind.SynthToSynth) return SideHolds(index, incoming);
            var between = Run(incoming ? index : index + 1);
            var other = incoming ? index - 1 : index + 1;
            if (between.Length == 0) return false;
            var piece = incoming ? between[^1] : between[0];
            if (piece.EndSample - piece.StartSample < (incoming ? fade / 2 : fade - fade / 2)) return false;
            return other < 0 || other >= Elements.Length || FadesFit(Math.Min(index, other));
        }
    }

    /// <summary>The take a window is placed in, checked as Place and LendableSilence both read it. It is
    /// media.source.durationSeconds long and ends on sample jsRound(durationSeconds × rate).</summary>
    sealed record Take(IReadOnlyList<TimedWord> Words, double Duration, double Rate, long Total, double PauseKeepSeconds)
    {
        public static Take Of(Project project)
        {
            if (project.Transcript is not { } transcript) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
            var edits = project.Edits;
            var duration = project.Media.Source.DurationSeconds;
            var rate = (double)(project.Media.Source.Audio?.SampleRate ?? 48000);
            if (!double.IsFinite(duration) || duration <= 0 || !double.IsFinite(rate) || rate <= 0 || duration * rate >= VoiceLabGeometry.SampleLimit ||
                !double.IsFinite(edits.PauseThresholdSeconds) || edits.PauseThresholdSeconds <= 0 || !double.IsFinite(edits.PauseKeepSeconds) ||
                edits.PauseKeepSeconds < 0 || edits.PauseKeepSeconds > 1) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
            return new(transcript.Words, duration, rate, VoiceLabGeometry.Samples(duration, rate), edits.PauseKeepSeconds);
        }
    }

    /// <summary>The render scope as VoiceLabOutputPlanner.Build makes it (§8.4): the clip, the scope's enabled replacements, the
    /// editing segments, which items the scope keeps and which are already re-voiced, and its kept source. Place and
    /// LendableSilence both read it.</summary>
    sealed class ScopeSource
    {
        readonly Take take;
        readonly IReadOnlyList<EditSegment> segments;
        public TimeRange? ClipRange { get; }
        public IReadOnlyList<SynthPiece> Replacements { get; }
        public bool[] KeptItem { get; }
        public bool[] Replaced { get; }
        /// <summary>The outer half of each replacement's own fades, which a gap seam beside it must leave free.</summary>
        public MediaInterval[] Reserved { get; }

        public ScopeSource(Project project, VoiceLabOutputScope scope, Take take)
        {
            this.take = take;
            var words = take.Words;
            var state = Editing(() => EditingEngine.FromProject(project)) ?? throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
            state = state with { ActiveClipId = scope.ClipId };
            if (scope.ClipId is { } clipId)
            {
                var clip = state.Clips.FirstOrDefault(item => item.Id == clipId);
                var clipStart = clip is null ? -1 : IndexOf(words, clip.StartWordId);
                var clipEnd = clip is null ? -1 : IndexOf(words, clip.EndWordId);
                if (clipStart < 0 || clipEnd < clipStart) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
                ClipRange = EditingAlgorithms.ClipTimes(words, clipStart, clipEnd);
            }
            var replacements = ScopeReplacements(project, ClipRange, take.Rate, take.Duration);
            Replacements = replacements;
            segments = Editing(() => EditingEngine.BuildSegments(state, take.Duration));
            var cutIds = segments.Where(segment => segment.Kind == EditSegmentKind.Word && segment.Cut).Select(segment => segment.Id).ToHashSet(StringComparer.Ordinal);
            KeptItem = words.Select(word => !cutIds.Contains(word.Id)).ToArray();
            // An item inside an enabled replacement is already re-voiced: it never bridges, and a take edge never absorbs it.
            Replaced = words.Select(word => replacements.Any(piece => piece.Start <= word.Start && word.End <= piece.End)).ToArray();
            Reserved = replacements.Select(piece => new MediaInterval(piece.Range.StartSample - piece.InFade / 2, piece.Range.StartSample))
                .Concat(replacements.Select(piece => new MediaInterval(piece.Range.EndSample, piece.Range.EndSample + piece.OutFade - piece.OutFade / 2)))
                .ToArray();
        }

        /// <summary>Kept source pieces as the output plan builds them: the words and pauses inside every replacement and inside
        /// the passage, when given, are dropped, and neither the cuts nor the synth ranges (with window) are source.</summary>
        public IReadOnlyList<MediaInterval> KeptSource((double Start, double End)? passage, MediaInterval? window = null)
        {
            var dropped = new List<(double Start, double End)>(Replacements.Select(piece => (piece.Start, piece.End)));
            if (passage is { } passageRange) dropped.Add(passageRange);
            var remaining = segments.Where(segment => segment.Kind is not (EditSegmentKind.Word or EditSegmentKind.Pause) ||
                !dropped.Any(range => segment.Start >= range.Start && segment.End <= range.End)).ToArray();
            var kept = Editing(() => EditingEngine.BuildEditPlan(remaining, take.Duration, take.Rate, take.PauseKeepSeconds).Kept);
            var synth = Replacements.Select(piece => piece.Range).ToList();
            if (window is { } own) synth.Add(own);
            return VoiceLabGeometry.Subtract(kept, synth);
        }
    }

    /// <summary>Editing failures in the take become InvalidInput.</summary>
    static T Editing<T>(Func<T> body)
    {
        try { return body(); }
        catch (ArgumentException) { throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput); }
    }

    /// <summary>The enabled replacements VoiceLabOutputPlanner.Build renders in this scope, by start. One that crosses the
    /// clip's range, has no synth samples, has no selected recipe or overlaps another leaves the scope unrenderable.</summary>
    static IReadOnlyList<SynthPiece> ScopeReplacements(Project project, TimeRange? clipRange, double rate, double duration)
    {
        var selected = new List<SynthPiece>();
        foreach (var segment in project.VoiceLab.Segments.Where(segment => segment.Enabled))
        {
            var start = segment.Replace.Start;
            var end = segment.Replace.End;
            if (!double.IsFinite(start) || !double.IsFinite(end) || start < 0 || !(start < end) || end > duration)
                throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
            if (clipRange is { } outside && (end <= outside.Start || start >= outside.End)) continue;
            var range = new MediaInterval(VoiceLabGeometry.Samples(start, rate), VoiceLabGeometry.Samples(end, rate));
            var seams = segment.Candidates.ElementAtOrDefault(segment.SelectedCandidateIndex)?.Recipe?.Seams;
            if (clipRange is { } clip && (start < clip.Start || end > clip.End) || range.EndSample <= range.StartSample || seams is null ||
                new[] { seams.In.FadeSamples, seams.Out.FadeSamples }.Any(fade => fade < 0 || fade >= VoiceLabGeometry.SampleLimit))
                throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
            selected.Add(new(segment.Id, false, start, end, range, seams.In.Kind, seams.In.FadeSamples, seams.Out.Kind, seams.Out.FadeSamples));
        }
        var sorted = selected.OrderBy(piece => piece.Start).ToArray();
        for (var index = 1; index < sorted.Length; index++)
            if (sorted[index].Range.StartSample < sorted[index - 1].Range.EndSample) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        return sorted;
    }

    public static VoiceLabWindow Place(Project project, VoiceLabOutputScope scope, AudioEnvelope envelope, string afterWordId)
        => throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InsertionUnsupported);

    /// <summary>Places the window for the render scope, exactly as VoiceLabOutputPlanner.Build receives it, beside the scope's
    /// enabled replacements. The take is media.source.durationSeconds long and ends on sample jsRound(durationSeconds × rate).
    /// Kept source comes from the editing plan the output planner builds, with the words and pauses inside every replacement
    /// and the window dropped and the synth ranges removed. A seam in a gap sits at the centre of its quietest whole 10 ms
    /// frame whose fade lies in kept source clear of a replacement's own fades (ties: nearest the gap centre, then earlier),
    /// and every seam with a fade keeps its outer half in the kept source beside it (§10.5).</summary>
    public static VoiceLabWindow Place(Project project, VoiceLabOutputScope scope, AudioEnvelope envelope, string firstWordId, string lastWordId)
    {
        var take = Take.Of(project);
        var words = take.Words;
        var duration = take.Duration;
        var rate = take.Rate;
        var total = take.Total;
        VoiceLabGeometry.Check(rate, total, envelope, words);
        var a = IndexOf(words, firstWordId);
        if (a < 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.UnknownWord, firstWordId);
        var b = IndexOf(words, lastWordId);
        if (b < 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.UnknownWord, lastWordId);
        if (a > b) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.ReversedWords);

        // The clip, replacements, segments and kept source VoiceLabOutputPlanner builds for this scope.
        var source = new ScopeSource(project, scope, take);
        var clipRange = source.ClipRange;
        var replacements = source.Replacements;
        var keptItem = source.KeptItem;
        var replaced = source.Replaced;
        var reserved = source.Reserved;
        var blocking = keptItem.Zip(replaced, (kept, covered) => kept || covered).ToArray();
        IReadOnlyList<MediaInterval> KeptSource((double Start, double End)? passage, MediaInterval? window = null) => source.KeptSource(passage, window);
        // Where the silence before item index begins: the latest end of the items before it.
        double BeforeEnd(int index) => index > 0 ? words.Take(index).Max(word => word.End) : 0;
        // Where the silence before item index ends: the earliest start of the items from it on.
        double AfterStart(int index) => index < words.Count ? words.Skip(index).Min(word => word.Start) : duration;

        var size = VoiceLabGeometry.FrameSize(rate);
        var minGap = VoiceLabGeometry.Samples(VoiceLabPatchConstants.SEAM_MIN_GAP, rate);
        var gapFade = VoiceLabGeometry.Samples(VoiceLabPatchConstants.SEAM_FADE, rate);
        var hardFade = VoiceLabGeometry.Samples(VoiceLabPatchConstants.HARD_SEAM_FADE, rate);
        bool Bridgeable(int index) => index >= 0 && index < words.Count && words[index].Kind == WordKind.Word && keptItem[index] && !replaced[index];
        long? Quietest(long g0, long g1, IReadOnlyList<MediaInterval> kept)
        {
            var first = (g0 + size - 1) / size;
            var last = Math.Min(g1 / size - 1, envelope.Rms.Count - 1L);
            (double Level, long Distance, long Seam)? best = null;
            for (var index = first; index <= last; index++)
            {
                var seam = index * size + (size + 1) / 2;
                // The whole centred fade lies in kept source, which also keeps it inside the take; §10.5 never shortens it.
                if (!kept.Any(interval => interval.StartSample <= seam - gapFade / 2 && seam + gapFade - gapFade / 2 <= interval.EndSample)) continue;
                var level = (double)envelope.Rms[(int)index];
                var distance = Math.Abs(2 * index * size + size - g0 - g1);
                if (best is not { } current || level < current.Level || level == current.Level && distance < current.Distance) best = (level, distance, seam);
            }
            return best?.Seam;
        }
        VoiceLabSeamPlacement GapSeam(long seam) => new(VoiceLabSeamKind.Gap, seam / rate, seam, gapFade);
        VoiceLabSeamPlacement EdgeSeam(long sample, double time) => new(VoiceLabSeamKind.None, time, sample, 0);
        VoiceLabSeamPlacement HardSeam(double time) => new(VoiceLabSeamKind.Hard, time, VoiceLabGeometry.Samples(time, rate), hardFade);

        // Take edges count kept and replaced items only: earlier or later cut items are absorbed into the window. In a clip
        // scope the window can reach a take edge only when the clip's kept range does.
        var touchesStart = clipRange is not { } head || head.Start <= 0;
        var touchesEnd = clipRange is not { } tail || tail.End >= duration;
        var aMin = a;
        var bMax = b;
        while (a - aMin < VoiceLabPatchConstants.SEAM_SEARCH_WORDS && Bridgeable(aMin - 1)) aMin--;
        while (bMax - b < VoiceLabPatchConstants.SEAM_SEARCH_WORDS && Bridgeable(bMax + 1)) bMax++;
        // Each search measures kept source against the widest window the other side could reach, because a cut's reach
        // depends on which items the window drops. The exact window is checked after placement.
        var widestEnd = touchesEnd && !blocking.Skip(bMax + 1).Contains(true) ? duration : AfterStart(bMax + 1);
        var widestStart = touchesStart && !blocking.Take(aMin).Contains(true) ? 0 : BeforeEnd(aMin);

        VoiceLabSeamPlacement? left = null;
        var firstIndex = a;
        for (var bridge = 0; bridge <= VoiceLabPatchConstants.SEAM_SEARCH_WORDS; bridge++)
        {
            var k = a - bridge;
            if (bridge > 0 && !Bridgeable(k)) break;
            var g0 = VoiceLabGeometry.Samples(BeforeEnd(k), rate);
            var g1 = VoiceLabGeometry.Samples(AfterStart(k), rate);
            if (g1 - g0 < minGap) continue;
            if (Quietest(g0, g1, VoiceLabGeometry.Subtract(KeptSource((AfterStart(k), widestEnd)), reserved)) is not { } seam) continue;
            left = GapSeam(seam);
            firstIndex = k;
            break;
        }
        // A replacement that ends in the silence before the passage keeps its own fade's outer half and this seam's: the
        // silence is measured from where both fit. Overlapping items leave no silence: the reach is clamped at zero, as
        // editing §7.3 clamps a cut's reach.
        var passageStart = AfterStart(a);
        var silenceStart = replacements.Where(piece => piece.End <= passageStart).Aggregate(BeforeEnd(a),
            (latest, piece) => Math.Max(latest, (piece.Range.EndSample + piece.OutFade - piece.OutFade / 2 + hardFade / 2) / rate));
        var leftSeam = left ?? HardSeam(passageStart - Math.Min(HardSeamReach, Math.Max(0, passageStart - silenceStart) / 2));
        if (touchesStart && !blocking.Take(firstIndex).Contains(true)) leftSeam = EdgeSeam(0, 0);

        VoiceLabSeamPlacement? right = null;
        var lastIndex = b;
        for (var bridge = 0; bridge <= VoiceLabPatchConstants.SEAM_SEARCH_WORDS; bridge++)
        {
            var k = b + bridge;
            if (bridge > 0 && !Bridgeable(k)) break;
            var g0 = VoiceLabGeometry.Samples(BeforeEnd(k + 1), rate);
            var g1 = VoiceLabGeometry.Samples(AfterStart(k + 1), rate);
            if (g1 - g0 < minGap) continue;
            if (Quietest(g0, g1, VoiceLabGeometry.Subtract(KeptSource((widestStart, BeforeEnd(k + 1))), reserved)) is not { } seam) continue;
            right = GapSeam(seam);
            lastIndex = k;
            break;
        }
        var passageEnd = BeforeEnd(b + 1);
        var silenceEnd = replacements.Where(piece => piece.Start >= passageEnd).Aggregate(AfterStart(b + 1),
            (earliest, piece) => Math.Min(earliest, (piece.Range.StartSample - piece.InFade / 2 - (hardFade - hardFade / 2)) / rate));
        var rightSeam = right ?? HardSeam(passageEnd + Math.Min(HardSeamReach, Math.Max(0, silenceEnd - passageEnd) / 2));
        if (touchesEnd && !blocking.Skip(lastIndex + 1).Contains(true)) rightSeam = EdgeSeam(total, duration);

        var start = leftSeam.Time;
        var end = rightSeam.Time;
        if (rightSeam.Sample <= leftSeam.Sample) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        if (replacements.FirstOrDefault(piece => piece.Start < end && start < piece.End) is { } overlapped)
            throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.OverlapsReplacement, segmentId: overlapped.Id);
        foreach (var word in words)
            if (word.Start < start && start < word.End || word.Start < end && end < word.End)
                throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.WindowCrossesWord, word.Id);
        // The window holds the passage and its bridges. It absorbs cut items, events and unlabeled speech, but a kept word
        // that is neither a passage nor a bridge word would lose its speech.
        var inside = Enumerable.Range(0, words.Count).Where(index => words[index].Start >= start && words[index].End <= end).ToArray();
        for (var index = firstIndex; index <= lastIndex; index++)
            if (!inside.Contains(index)) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.WindowCrossesWord, words[index].Id);
        foreach (var index in inside)
            if ((index < firstIndex || index > lastIndex) && words[index].Kind == WordKind.Word && keptItem[index])
                throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.WindowCrossesWord, words[index].Id);
        // A hard fade crossing a take edge has a kept item between the passage and that edge.
        var beforeTake = leftSeam.Kind == VoiceLabSeamKind.Hard && leftSeam.Sample - hardFade / 2 < 0;
        if (beforeTake || rightSeam.Kind == VoiceLabSeamKind.Hard && rightSeam.Sample + hardFade - hardFade / 2 > total)
            throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.SeamFadeOutsideTake) { TakeEdgeIsStart = beforeTake };

        // §10.5 on the pieces the output plan builds with the window as one more replacement: a seam with a fade needs the
        // fade's outer half in the kept source right beside it, and two replacements beside one kept piece need room for both
        // outer halves. Seam kinds follow prepare: None only with nothing beside it, SynthToSynth only between two touching
        // replacements, which Place never makes.
        var windowRange = new MediaInterval(leftSeam.Sample, rightSeam.Sample);
        var layout = new SeamLayout(replacements.Append(new SynthPiece("", true, start, end, windowRange, leftSeam.Kind, leftSeam.FadeSamples,
            rightSeam.Kind, rightSeam.FadeSamples)).OrderBy(piece => piece.Range.StartSample).ToArray(), KeptSource((start, end), windowRange), total);
        // The scope as it renders without the window. A replacement's check that already fails there is not the window's doing.
        var alone = new SeamLayout(replacements.ToArray(), KeptSource(null), total);
        var elements = layout.Elements;
        var w = Array.FindIndex(elements, piece => piece.IsWindow);
        static VoiceLabGeometryException Refusal(bool adjacent, string id) =>
            new(adjacent ? VoiceLabGeometryErrorCode.AdjacentReplacement : VoiceLabGeometryErrorCode.InvalidInput, segmentId: id);
        // Throws unless replacement index's seam on that side still renders beside the window. A check that holds without the
        // window and fails with it is the window's doing. A check that already fails is judged by prepare's own rule, and when
        // that fails without the window too, the scope was unrenderable before the window.
        void Judge(int index, bool incoming)
        {
            var before = index > w ? index - 1 : index;
            if (layout.SideHolds(index, incoming)) return;
            if (alone.SideHolds(before, incoming)) throw Refusal(true, elements[index].Id);
            if (layout.PrepareHolds(index, incoming)) return;
            throw Refusal(alone.PrepareHolds(before, incoming), elements[index].Id);
        }
        if (w > 0)
        {
            if (layout.Run(w).Length == 0) throw Refusal(true, elements[w - 1].Id);
            Judge(w - 1, false);
            if (!layout.PairHolds(w - 1)) throw Refusal(true, elements[w - 1].Id);
        }
        if (leftSeam.Kind != VoiceLabSeamKind.None)
        {
            var needed = leftSeam.FadeSamples / 2;
            var available = layout.Beside(w, true);
            if (available < needed)
                throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.SeamFadeCrossesCut, incoming: true, needed: needed, available: available);
        }
        if (w + 1 < elements.Length)
        {
            if (layout.Run(w + 1).Length == 0) throw Refusal(true, elements[w + 1].Id);
            Judge(w + 1, true);
            if (!layout.PairHolds(w)) throw Refusal(true, elements[w + 1].Id);
        }
        if (rightSeam.Kind != VoiceLabSeamKind.None)
        {
            var needed = rightSeam.FadeSamples - rightSeam.FadeSamples / 2;
            var available = layout.Beside(w, false);
            if (available < needed)
                throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.SeamFadeCrossesCut, incoming: false, needed: needed, available: available);
        }
        // The validator's overlappingFades condition: the inner halves of both fades must fit inside the window.
        var inner = leftSeam.FadeSamples - leftSeam.FadeSamples / 2 + rightSeam.FadeSamples / 2;
        if (inner > rightSeam.Sample - leftSeam.Sample)
            throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.WindowTooShort, needed: inner, available: rightSeam.Sample - leftSeam.Sample);
        // Dropping the window's items can lengthen a cut's reach past a replacement further away. Across one kept piece the
        // pair rule is prepare's own, so a pair that already breaks it leaves the scope unrenderable.
        for (var index = 0; index < elements.Length; index++)
        {
            if (index == w) continue;
            Judge(index, true);
            Judge(index, false);
            if (index + 1 != w && index + 1 < elements.Length && !layout.PairHolds(index))
                throw Refusal(alone.PairHolds(index > w ? index - 1 : index), elements[index].Id);
        }
        return new(words[inside[0]].Id, words[inside[^1]].Id, words.Skip(firstIndex).Take(a - firstIndex).Select(word => word.Id).ToArray(),
            words.Skip(b + 1).Take(lastIndex - b).Select(word => word.Id).ToArray(), start, end, leftSeam.Sample, rightSeam.Sample, leftSeam, rightSeam);
    }

    /// <summary>The §8.9.2 lendable silence of each gap seam of window, a window Place returned for this scope, in seconds
    /// (source samples over the source rate). It is the kept source contiguous with the seam on its outer side, measured as
    /// §8.4 step 5 measures it for the final window, with every replacement's outer fade halves taken out, up to the nearest
    /// kept item outside the window. So it stops at that item, a cut item's reach, a cut pause, a clip edge or another
    /// replacement's outer fade half. A take edge returns the silence to the nearest word inside the window, in transcript
    /// seconds; a hard seam returns null. Pass both results directly to VoiceLabFitPlanner.Plan. Only a gap seam can borrow,
    /// at most this less PAUSE_SLACK_KEEP.</summary>
    public static (double? Incoming, double? Outgoing) LendableSilence(Project project, VoiceLabOutputScope scope, VoiceLabWindow window)
    {
        var take = Take.Of(project);
        VoiceLabGeometry.Check(take.Rate, take.Total, null, take.Words);
        if (window.StartSample < 0 || window.StartSample >= window.EndSample || window.EndSample > take.Total ||
            window.LeftSeam.Sample != window.StartSample || window.RightSeam.Sample != window.EndSample)
            throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        var source = new ScopeSource(project, scope, take);
        var kept = VoiceLabGeometry.Subtract(source.KeptSource((window.Start, window.End), new MediaInterval(window.StartSample, window.EndSample)),
            source.Reserved);
        var before = take.Words.Where((word, index) => source.KeptItem[index] && word.End <= window.Start)
            .Select(word => VoiceLabGeometry.Samples(word.End, take.Rate)).ToArray();
        var after = take.Words.Where((word, index) => source.KeptItem[index] && word.Start >= window.End)
            .Select(word => VoiceLabGeometry.Samples(word.Start, take.Rate)).ToArray();
        double? Lend(VoiceLabSeamPlacement seam, bool incoming)
        {
            if (seam.Kind == VoiceLabSeamKind.None)
            {
                var words = take.Words.Where(word => word.Kind == WordKind.Word && word.Start >= window.Start && word.End <= window.End);
                return incoming ? Math.Max(0, words.Select(word => word.Start).DefaultIfEmpty(window.Start).Min() - window.Start)
                    : Math.Max(0, window.End - words.Select(word => word.End).DefaultIfEmpty(window.End).Max());
            }
            if (seam.Kind != VoiceLabSeamKind.Gap) return null;
            var beside = kept.Where(piece => (incoming ? piece.EndSample : piece.StartSample) == seam.Sample).ToArray();
            if (beside.Length == 0) return 0;
            var stop = incoming ? before.Append(beside[0].StartSample).Max() : after.Append(beside[0].EndSample).Min();
            return Math.Max(0, incoming ? seam.Sample - stop : stop - seam.Sample) / take.Rate;
        }
        return (Lend(window.LeftSeam, true), Lend(window.RightSeam, false));
    }

    static int IndexOf(IReadOnlyList<TimedWord> words, string id)
    {
        for (var index = 0; index < words.Count; index++)
            if (words[index].Id == id) return index;
        return -1;
    }
}

/// <summary>§10.5 seam handles with exactly the render validator's arithmetic.</summary>
public static class VoiceLabHandles
{
    /// <summary>An incoming seam needs floor(N/2) output samples of asset before its trim, an outgoing one ceil(N/2) after;
    /// the source keeps the other half inside the window.</summary>
    public static (long AssetFrames, long SourceSamples) Minimum(long fadeSamples, bool incoming, int assetSampleRate,
        double sourceSampleRate, double stretch)
    {
        if (fadeSamples < 0 || fadeSamples >= VoiceLabGeometry.SampleLimit || assetSampleRate <= 0 || !double.IsFinite(sourceSampleRate) ||
            sourceSampleRate <= 0 || !double.IsFinite(stretch) || stretch <= 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        var needed = incoming ? fadeSamples / 2 : fadeSamples - fadeSamples / 2;
        var rawFrames = (double)needed * assetSampleRate / (sourceSampleRate * stretch);
        if (!double.IsFinite(rawFrames) || rawFrames >= VoiceLabGeometry.SampleLimit) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        var nearest = Math.Round(rawFrames);
        // Persisted stretch ratios can put an integral frame one ULP above its exact value.
        return ((long)(Math.Abs(rawFrames - nearest) <= 4 * (Math.BitIncrement(rawFrames) - rawFrames) ? nearest : Math.Ceiling(rawFrames)), fadeSamples - needed);
    }

    /// <summary>The recipe seam with minimum handles. A take edge has none; a synth-to-synth seam has no source handle.</summary>
    public static VoiceLabSeam Seam(VoiceLabSeamKind kind, long fadeSamples, bool incoming, int assetSampleRate, double sourceSampleRate, double stretch)
    {
        if (!Enum.IsDefined(kind)) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        if (kind == VoiceLabSeamKind.None) return new(VoiceLabSeamKind.None, 0, 0, 0);
        var (assetFrames, sourceSamples) = Minimum(fadeSamples, incoming, assetSampleRate, sourceSampleRate, stretch);
        return new(kind, fadeSamples, kind == VoiceLabSeamKind.SynthToSynth ? 0 : sourceSamples, assetFrames);
    }

    /// <summary>Requires the asset frames before trimStart and after trimEnd that the seams declare, on the asset grid.</summary>
    public static void CheckTrim(VoiceLabSeams seams, double trimStart, double trimEnd, double assetDurationSeconds, int assetSampleRate)
    {
        if (!double.IsFinite(trimStart) || !double.IsFinite(trimEnd) || !double.IsFinite(assetDurationSeconds) || trimStart < 0 ||
            trimStart >= trimEnd || trimEnd > assetDurationSeconds || assetSampleRate <= 0 ||
            assetDurationSeconds * assetSampleRate >= VoiceLabGeometry.SampleLimit) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        var before = VoiceLabGeometry.Samples(trimStart, assetSampleRate);
        var after = VoiceLabGeometry.Samples(assetDurationSeconds - trimEnd, assetSampleRate);
        if (seams.In.AssetHandleFrames > before)
            throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.InsufficientHandle, incoming: true, needed: seams.In.AssetHandleFrames, available: before);
        if (seams.Out.AssetHandleFrames > after)
            throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.InsufficientHandle, incoming: false, needed: seams.Out.AssetHandleFrames, available: after);
    }
}
