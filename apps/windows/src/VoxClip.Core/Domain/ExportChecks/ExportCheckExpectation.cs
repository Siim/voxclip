using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.ExportChecks;

/// <summary>What a render puts in its export, in output seconds (the edited time at the clip's speed): the words to hear, the
/// phrases Voice Lab speaks, the cuts and the caption cards. The export check (ADR-R49) compares the exported file with these, so
/// they come from the same snapshot and layout the renderer used, never from the file's pixels. Twin of the Mac
/// <c>ExportCheckExpectation</c>.</summary>
public static class ExportCheckExpectation
{
    /// <summary>The render's words, phrases and cuts, and its rendered length in seconds.</summary>
    public sealed record Edit(IReadOnlyList<ExportCheckWord> Words, IReadOnlyList<ExportCheckPhrase> Phrases, IReadOnlyList<double> Cuts, double Duration)
    {
        /// <summary>Only the cuts that switch the recording, in rendered time.</summary>
        public IReadOnlyList<ExportCheckRecordingSeam> RecordingSeams { get; init; } = [];
    }

    /// <summary>The words of the render <paramref name="snapshot"/> describes: on the Voice Lab path the output plan's own words (each
    /// Rewrite's or revoiced phrase's words at their placed times, the kept source words mapped around them); otherwise the kept
    /// source words of <paramref name="state"/>'s active clip through the snapshot's plan, corrections applied, as the captions read
    /// them. A bleeped or muted word isn't heard and isn't expected; a kept filler is optional. A null <paramref name="state"/> (no
    /// transcript) expects no source words.</summary>
    public static Edit Make(ComposeSnapshot snapshot, EditState? state)
    {
        var edit = Make(snapshot.Timeline, snapshot.Speed, snapshot.Clip?.Effects?.Effects ?? [], state, snapshot.RenderedDuration);
        if (snapshot.SpanSources.Count == 0) return edit;
        return edit with { RecordingSeams = RecordingSeams(snapshot.Timeline, snapshot.Speed, sample =>
            snapshot.RecordingAt(sample) is { } source ? (source.ContentKey, source.Label) : null) };
    }

    /// <summary><see cref="Make(ComposeSnapshot, EditState?)"/> from its parts: the render's timeline, the clip's speed, its effects
    /// and its rendered length.</summary>
    public static Edit Make(RenderTimeline timeline, ClipSpeedTiming speed, IReadOnlyList<ClipEffect> effects, EditState? state, double duration)
    {
        var bleeped = effects.Where(effect => effect.UsesWords).SelectMany(effect => effect.WordIds).ToHashSet(StringComparer.Ordinal);
        ExportCheckWord Word(CaptionWord caption, string? phrase = null) =>
            new(caption.Text, speed.Rendered(caption.Start), speed.Rendered(caption.End), EditingAlgorithms.IsFillerText(caption.Text), phrase);
        var recordings = state?.ProjectClock is { Regions.Count: > 1 } clock
            ? RecordingSeams(timeline, speed, sample => clock.RegionAt(sample) is { } region ? (region.Key, region.Label) : null) : [];
        switch (timeline)
        {
            case RenderTimeline.VoiceLab voiceLab:
            {
                var plan = voiceLab.Plan;
                var rate = plan.SampleRate;
                var phrases = new List<ExportCheckPhrase>();
                foreach (var piece in plan.Pieces.Where(piece => piece.Kind == VoiceLabOutputPieceKind.Synth))
                {
                    if (piece.SegmentId is not { } id) continue;
                    var start = speed.Rendered(piece.OutputStartSample / rate);
                    var end = speed.Rendered(piece.OutputEndSample / rate);
                    var index = phrases.FindIndex(phrase => phrase.Id == id);
                    if (index >= 0) phrases[index] = phrases[index] with { Start = Math.Min(phrases[index].Start, start), End = Math.Max(phrases[index].End, end) };
                    else phrases.Add(new(id, start, end));
                }
                var words = plan.Captions.Where(caption => !bleeped.Contains(caption.Id)).Select(caption =>
                {
                    var start = speed.Rendered(caption.Start);
                    return Word(caption, phrases.FirstOrDefault(phrase => start >= phrase.Start && start < phrase.End)?.Id);
                }).ToArray();
                // A seam wherever the next piece doesn't continue the previous one's source, or is generated.
                var cuts = new List<double>();
                for (var index = 1; index < plan.Pieces.Count; index++)
                {
                    var (previous, next) = (plan.Pieces[index - 1], plan.Pieces[index]);
                    if (plan.PartSeams.Contains(next.OutputStartSample) || previous.Kind != next.Kind || next.Kind == VoiceLabOutputPieceKind.Synth || next.SourceStartSample != previous.SourceEndSample)
                        cuts.Add(speed.Rendered(next.OutputStartSample / rate));
                }
                return new(words, phrases, cuts, duration) { RecordingSeams = recordings };
            }
            case RenderTimeline.Legacy legacy:
            {
                var plan = legacy.Plan;
                var cuts = new List<double>();
                long position = 0;
                foreach (var interval in plan.Kept.SkipLast(1))
                {
                    position += interval.EndSample - interval.StartSample;
                    cuts.Add(speed.Rendered(position / plan.SampleRate));
                }
                if (state is null || state.Transcript.Words.Count == 0) return new([], [], cuts, duration) { RecordingSeams = recordings };
                var captions = EditingEngine.CaptionWords(state, plan);
                return new(captions.Where(caption => !bleeped.Contains(caption.Id)).Select(caption => Word(caption)).ToArray(), [], cuts, duration)
                { RecordingSeams = recordings };
            }
            default: throw new InvalidOperationException("Unknown render timeline.");
        }
    }

    private static IReadOnlyList<ExportCheckRecordingSeam> RecordingSeams(RenderTimeline timeline, ClipSpeedTiming speed,
        Func<long, (string Key, string Label)?> recordingAt)
    {
        var seams = new List<ExportCheckRecordingSeam>();
        (string Key, string Label)? previous = null;
        void Visit(long sourceStart, long outputStart)
        {
            var next = recordingAt(sourceStart);
            if (previous is { } before && next is { } after && before.Key != after.Key)
                seams.Add(new(speed.Rendered(outputStart / timeline.SampleRate), before.Label, after.Label));
            previous = next;
        }
        if (timeline is RenderTimeline.VoiceLab voice)
            foreach (var piece in voice.Plan.Pieces) Visit(piece.SourceStartSample, piece.OutputStartSample);
        else if (timeline is RenderTimeline.Legacy legacy)
        {
            long output = 0;
            foreach (var span in legacy.Plan.Kept)
            {
                Visit(span.StartSample, output);
                output += span.EndSample - span.StartSample;
            }
        }
        return seams;
    }

    /// <summary>Each caption card the render draws: the page's visual rect (after the layout's clamp) with its boxes and emoji, top-left
    /// origin, in fractions of the <paramref name="output"/> frame, from the page's first output second. Empty without captions.</summary>
    public static IReadOnlyList<ExportCheckBox> CaptionBoxes(CaptionTrack? captions, PixelSize output, ClipSpeedTiming speed)
    {
        if (captions is null) return [];
        double width = output.Width, height = output.Height;
        if (width <= 0 || height <= 0) return [];
        var boxes = new List<ExportCheckBox>();
        foreach (var page in captions.Pages)
        {
            var rects = new List<RectD> { page.Visual };
            rects.AddRange(page.Boxes.Select(box => new RectD(box.X, box.Y, box.W, box.H)));
            if (page.Emoji is { } emoji) rects.Add(new(emoji.X, emoji.Y, emoji.Size, emoji.Size));
            var drawn = rects.Where(rect => rect.Width > 0 && rect.Height > 0).ToArray();
            if (drawn.Length == 0) continue;
            var minX = drawn.Min(rect => rect.X);
            var minY = drawn.Min(rect => rect.Y);
            var maxX = drawn.Max(rect => rect.X + rect.Width);
            var maxY = drawn.Max(rect => rect.Y + rect.Height);
            boxes.Add(new(ExportCheckBoxKind.Caption, speed.Rendered(page.Start),
                new(minX / width, minY / height, (maxX - minX) / width, (maxY - minY) / height)));
        }
        return boxes;
    }
}
