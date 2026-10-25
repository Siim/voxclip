#pragma warning disable CS1591 // Output-piece API fields are documented together in editing.md §7.
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

public sealed record VoiceLabOutputScope(string? ClipId)
{
    public static VoiceLabOutputScope Full { get; } = new((string?)null);
    public static VoiceLabOutputScope Clip(string id) => new(id);
}
public enum VoiceLabOutputPieceKind { Source, Synth }
public sealed record VoiceLabOutputPiece(VoiceLabOutputPieceKind Kind, long SourceStartSample, long SourceEndSample,
    long OutputStartSample, long OutputEndSample, string? SegmentId, string? AssetId, VoiceLabAudio? Audio);
/// <summary>Media-free composition instructions. Legacy EditPlan cannot represent synthetic output length.</summary>
public sealed record VoiceLabOutputPlan(double SampleRate, long TotalSourceSamples, IReadOnlyList<VoiceLabOutputPiece> Pieces,
    IReadOnlyList<CaptionWord> Captions, VoiceLabOutputScope Scope)
{
    public long OutputSamples => Pieces.Count == 0 ? 0 : Pieces[^1].OutputEndSample;
    public double Duration => OutputSamples / SampleRate;
    public bool RequiresSyntheticRendering => Pieces.Any(piece => piece.Kind == VoiceLabOutputPieceKind.Synth);
    public void RequireLegacyRendering()
    {
        if (RequiresSyntheticRendering) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.UnsupportedRendering);
    }
    public double MapTime(double source)
    {
        var sample = (long)Math.Clamp(EditingMath.Round(double.IsFinite(source) ? source * SampleRate : 0), 0, TotalSourceSamples);
        long prior = 0;
        foreach (var piece in Pieces)
        {
            if (sample < piece.SourceStartSample) return prior / SampleRate;
            if (sample <= piece.SourceEndSample)
            {
                var fraction = (double)(sample - piece.SourceStartSample) / (piece.SourceEndSample - piece.SourceStartSample);
                return (piece.OutputStartSample + fraction * (piece.OutputEndSample - piece.OutputStartSample)) / SampleRate;
            }
            prior = piece.OutputEndSample;
        }
        return Duration;
    }
    public double SourceTime(double edited)
    {
        var sample = Math.Clamp(EditingMath.Round(double.IsFinite(edited) ? edited * SampleRate : 0), 0, OutputSamples);
        foreach (var piece in Pieces)
        {
            if (sample >= piece.OutputEndSample) continue;
            var fraction = (sample - piece.OutputStartSample) / (piece.OutputEndSample - piece.OutputStartSample);
            return (piece.SourceStartSample + fraction * (piece.SourceEndSample - piece.SourceStartSample)) / SampleRate;
        }
        // Match EditPlan's endpoint convention, including when the chosen clip ends earlier.
        return TotalSourceSamples / SampleRate;
    }
}

public static class VoiceLabOutputPlanner
{
    public static VoiceLabOutputPlan Build(Project project, VoiceLabOutputScope scope)
    {
        VoiceLabProject.Validate(project);
        if (project.Transcript is not { } transcript) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
        var duration = project.Media.Source.DurationSeconds;
        var rate = (double)(project.Media.Source.Audio?.SampleRate ?? 48000);
        var total = (long)Math.Max(0, EditingMath.Round(duration * rate));
        var state = EditingEngine.FromProject(project) ?? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
        state = state with { ActiveClipId = scope.ClipId };
        TimeRange? clipRange = null;
        if (scope.ClipId is { } clipId)
        {
            var clip = state.Clips.FirstOrDefault(item => item.Id == clipId);
            if (clip is null) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
            var words = transcript.Words;
            var first = -1; var last = -1;
            for (var i = 0; i < words.Count; i++)
            {
                if (words[i].Id == clip.StartWordId) first = i;
                if (words[i].Id == clip.EndWordId) last = i;
            }
            if (first < 0 || last < first) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
            clipRange = EditingAlgorithms.ClipTimes(words, first, last);
        }
        var enabled = project.VoiceLab.Segments.Where(segment => segment.Enabled &&
            (clipRange is null || segment.Replace.End > clipRange.Value.Start && segment.Replace.Start < clipRange.Value.End))
            .OrderBy(segment => segment.Replace.Start).ToArray();
        if (clipRange is { } range && enabled.Any(segment => segment.Replace.Start < range.Start || segment.Replace.End > range.End))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
        bool Inside(double start, double end) => enabled.Any(segment => start >= segment.Replace.Start && end <= segment.Replace.End);
        var segments = EditingEngine.BuildSegments(state, duration).Where(item =>
            item.Kind is not (EditSegmentKind.Word or EditSegmentKind.Pause) || !Inside(item.Start, item.End)).ToArray();
        var basePlan = EditingEngine.BuildEditPlan(segments, duration, rate, state.PauseKeepSeconds);
        var synthRanges = enabled.Select(segment => (segment, interval: new MediaInterval(
            (long)EditingMath.Round(segment.Replace.Start * rate), (long)EditingMath.Round(segment.Replace.End * rate)))).ToArray();
        if (synthRanges.Any(pair => pair.interval.EndSample <= pair.interval.StartSample))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidRange);
        var cuts = basePlan.Cuts.ToList();
        foreach (var pair in synthRanges)
        {
            var synth = pair.interval;
            var next = new List<MediaInterval>();
            foreach (var cut in cuts)
            {
                if (cut.EndSample <= synth.StartSample || cut.StartSample >= synth.EndSample) next.Add(cut);
                else
                {
                    if (cut.StartSample < synth.StartSample) next.Add(new(cut.StartSample, synth.StartSample));
                    if (cut.EndSample > synth.EndSample) next.Add(new(synth.EndSample, cut.EndSample));
                }
            }
            cuts = next;
        }
        var kept = new List<MediaInterval>();
        long cursor = 0;
        foreach (var cut in cuts)
        {
            if (cut.StartSample > cursor) kept.Add(new(cursor, cut.StartSample));
            cursor = cut.EndSample;
        }
        if (cursor < total) kept.Add(new(cursor, total));
        var pieces = new List<VoiceLabOutputPiece>();
        long output = 0;
        void Append(VoiceLabOutputPieceKind kind, long start, long end, long length, string? segmentId = null, VoiceLabAudio? audio = null)
        {
            if (end <= start || length <= 0) return;
            if (output > long.MaxValue - length) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidRange);
            pieces.Add(new(kind, start, end, output, output + length, segmentId, audio?.AssetId, audio));
            output += length;
        }
        foreach (var interval in kept)
        {
            var position = interval.StartSample;
            foreach (var (segment, synth) in synthRanges.Where(pair => pair.interval.EndSample > position && pair.interval.StartSample < interval.EndSample))
            {
                if (synth.StartSample < position || synth.EndSample > interval.EndSample)
                    throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidRange);
                Append(VoiceLabOutputPieceKind.Source, position, synth.StartSample, synth.StartSample - position);
                var generated = (long)EditingMath.Round(segment.OutDuration * rate);
                if (generated <= 0) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidRange);
                Append(VoiceLabOutputPieceKind.Synth, synth.StartSample, synth.EndSample, generated, segment.Id, segment.Audio);
                position = synth.EndSample;
            }
            Append(VoiceLabOutputPieceKind.Source, position, interval.EndSample, interval.EndSample - position);
        }
        var plan = new VoiceLabOutputPlan(rate, total, pieces, [], scope);
        if (enabled.Length == 0) return plan with { Captions = EditingEngine.CaptionCopy(segments, basePlan) };
        var captions = new List<CaptionWord>();
        foreach (var word in transcript.Words.Where(word => word.Kind == WordKind.Word))
        {
            var covered = enabled.FirstOrDefault(segment => word.Start >= segment.Replace.Start && word.End <= segment.Replace.End);
            if (covered is not null)
            {
                if (covered.Kind != VoiceLabSegmentKind.VoiceChanger) continue;
                var start = plan.MapTime(word.Start); var end = plan.MapTime(word.End);
                if (end > start) captions.Add(new(word.Id, word.Text, start, end));
            }
            else if (segments.Any(item => item.Kind == EditSegmentKind.Word && item.Id == word.Id && !item.Cut))
            {
                var start = plan.MapTime(word.Start); var end = plan.MapTime(word.End);
                if (end > start) captions.Add(new(word.Id, state.Corrections.GetValueOrDefault(word.Id, word.Text), start, end));
            }
        }
        foreach (var (segment, _) in synthRanges.Where(pair => pair.segment.Kind == VoiceLabSegmentKind.Tts))
        {
            var piece = pieces.FirstOrDefault(item => item.SegmentId == segment.Id);
            if (piece is null) continue;
            foreach (var (word, index) in segment.Words!.Select((word, index) => (word, index)))
            {
                var start = (piece.OutputStartSample + EditingMath.Round(word.Start * rate)) / rate;
                var end = (piece.OutputStartSample + EditingMath.Round(word.End * rate)) / rate;
                if (end > start) captions.Add(new($"{segment.Id}:word:{index}", word.Text, start, end));
            }
        }
        captions.Sort((left, right) => left.Start == right.Start ? StringComparer.Ordinal.Compare(left.Id, right.Id) : left.Start.CompareTo(right.Start));
        return plan with { Captions = captions };
    }
}
