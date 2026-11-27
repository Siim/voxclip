using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record TimelinePartBand(ClipPartRow Part, TimeRange Range);
internal sealed record TimelinePartSeam(double Position, double TakeTime, int PartNumber, bool Backward, string? Recording = null)
{
    internal const int Stroke = 3;
    internal int Width => Stroke;
    internal string Label => Recording is { } label ? $"→ {label} {EditorViewModel.Duration(TakeTime)}" : $"{(Backward ? "↶" : "↷")} {EditorViewModel.Duration(TakeTime)}";
    internal string Description => $"Seam to part {PartNumber}, " + (Recording is { } label ? $"recording {label} at " : $"jumps {(Backward ? "back" : "ahead")} to ") +
        $"{EditorViewModel.Duration(TakeTime)}, fades over 5 ms";
}
internal sealed record RecordingOverviewRow(ProjectClock.Region Recording, double Duration, IReadOnlyList<TimelinePartBand> Parts);

internal sealed class TimelineStory
{
    private readonly RenderTimeline rendering;
    private readonly TimeRange[] sources;
    private readonly TimeRange[] editedSources;
    private readonly TimelinePartBand[] open;
    private readonly TimelinePartBand[] edited;
    private readonly TimelinePartSeam[] openSeams;
    private readonly TimelinePartSeam[] editedSeams;
    internal TimelinePieces EditedPieces { get; }
    internal TimelinePieces OpenPieces { get; }
    internal IReadOnlyList<TimelinePartBand> Overview { get; }
    internal IReadOnlyList<RecordingOverviewRow> RecordingOverview { get; }
    internal IReadOnlyList<TimeRange> OpenCuts { get; }
    internal double Duration(bool closesCuts) => closesCuts ? rendering.Duration : open.LastOrDefault()?.Range.End ?? 0;
    internal IReadOnlyList<TimelinePartBand> Bands(bool closesCuts) => closesCuts ? edited : open;
    internal IReadOnlyList<TimelinePartSeam> Seams(bool closesCuts) => closesCuts ? editedSeams : openSeams;

    internal TimelineStory(EditorViewModel model, EditPlan plan, RenderTimeline? rendering = null)
    {
        var legacy = new RenderTimeline.Legacy(plan);
        this.rendering = rendering ?? legacy;
        var parts = model.ClipParts;
        Overview = parts.Select(part => new TimelinePartBand(part, new(part.Start, part.End))).ToArray();
        RecordingOverview = model.HasSeveralRecordings && model.RecordingClock is { } clock ? clock.Regions.Select(region =>
            new RecordingOverviewRow(region, (double)region.DurationSamples / clock.SampleRate, parts.Where(part => part.Recording == region)
                .Select(part => new TimelinePartBand(part, new(part.Start - part.RecordingOffset, part.End - part.RecordingOffset))).ToArray())).ToArray() : [];
        sources = parts.Select((part, index) =>
        {
            var range = EditingAlgorithms.ClipTimes(model.Words, part.First, part.Last, index == 0 ? model.ActiveClip?.LeadInSeconds : null);
            return new TimeRange(range.Start, Math.Min(range.End, plan.TotalSamples / plan.SampleRate));
        }).ToArray();
        double cursor = 0;
        open = parts.Select((part, index) => new TimelinePartBand(part, new(cursor, cursor += sources[index].End - sources[index].Start))).ToArray();
        openSeams = open.Skip(1).Select((band, index) => Seam(band.Range.Start, band.Part.Start, band.Part, open[index].Part, open[index].Part.End)).ToArray();

        EditedPieces = new(this.rendering);
        var bands = new List<TimelinePartBand>();
        var renderedSources = new List<TimeRange>();
        var seams = new List<TimelinePartSeam>();
        for (var index = 0; index < EditedPieces.Pieces.Count; index++)
        {
            var piece = EditedPieces.Pieces[index];
            var section = PartIndex(piece);
            if (section < 0) continue;
            var part = parts[section];
            if (index > 0 && EditedPieces.IsPartSeam(index))
            {
                var before = EditedPieces.Pieces[index - 1];
                var previous = PartIndex(before);
                seams.Add(Seam(piece.Edited.Start, piece.Source.Start, part, previous < 0 ? part : parts[previous], before.Source.End));
            }
            if (bands.Count > 0 && bands[^1].Part.Id == part.Id)
            {
                bands[^1] = bands[^1] with { Range = new(bands[^1].Range.Start, piece.Edited.End) };
                renderedSources[^1] = new(renderedSources[^1].Start, piece.Source.End);
            }
            else
            {
                bands.Add(new(part, piece.Edited));
                renderedSources.Add(piece.Source);
            }
        }
        edited = bands.ToArray();
        editedSources = renderedSources.ToArray();
        editedSeams = seams.ToArray();
        OpenPieces = new(new TimelinePieces(legacy).Pieces.Select(piece => (Piece: piece, Section: PartIndex(piece)))
            .Where(item => item.Section >= 0).Select(item =>
            {
                var offset = open[item.Section].Range.Start - sources[item.Section].Start;
                return item.Piece with { Edited = new(item.Piece.Source.Start + offset, item.Piece.Source.End + offset) };
            }));
        var cuts = new List<TimeRange>();
        for (var index = 0; index < sources.Length; index++)
        {
            var source = sources[index];
            var offset = open[index].Range.Start - source.Start;
            foreach (var cut in plan.Cuts)
            {
                var start = Math.Max(source.Start, cut.StartSample / plan.SampleRate);
                var end = Math.Min(source.End, cut.EndSample / plan.SampleRate);
                if (start < end) cuts.Add(new(start + offset, end + offset));
            }
        }
        OpenCuts = cuts;

        int PartIndex(TimelinePiece piece) => Array.FindIndex(sources, source =>
            source.Start <= piece.Source.Start && source.End > piece.Source.Start ||
            source.Start < piece.Source.End && source.End > piece.Source.Start);
    }

    private static TimelinePartSeam Seam(double position, double source, ClipPartRow part, ClipPartRow previous, double previousEnd) =>
        new(position, source - part.RecordingOffset, part.Number, source < previousEnd, part.Recording != previous.Recording ? part.Recording?.Label : null);

    internal double Display(double source, bool closesCuts)
    {
        var bands = Bands(closesCuts);
        if (bands.Count == 0) return 0;
        var ranges = closesCuts ? editedSources : sources;
        var index = Enumerable.Range(0, ranges.Length).MinBy(index =>
            Math.Max(ranges[index].Start - source, Math.Max(0, source - ranges[index].End)));
        var range = ranges[index];
        var band = bands[index];
        if (closesCuts)
            return source <= range.Start ? band.Range.Start
                : source >= range.End ? band.Range.End : Math.Clamp(rendering.MapTime(source), band.Range.Start, band.Range.End);
        return band.Range.Start + Math.Clamp(source - range.Start, 0, range.End - range.Start);
    }

    internal double SourceAt(double position, bool closesCuts)
    {
        var bands = Bands(closesCuts);
        if (bands.Count == 0) return 0;
        if (position >= Duration(closesCuts)) return closesCuts ? EditedPieces.Pieces[^1].Source.End : sources[^1].End;
        if (closesCuts) return rendering.SourceTime(position);
        var band = bands.First(item => position < item.Range.End);
        return sources[band.Part.Number - 1].Start + Math.Max(0, position - band.Range.Start);
    }

    internal IReadOnlyList<TimelineCue> OpenCaptionCues(IReadOnlyList<TimelineCaptions.Page> pages)
    {
        var cues = new List<TimelineCue>();
        foreach (var band in open)
        {
            var source = sources[band.Part.Number - 1];
            var offset = band.Range.Start - source.Start;
            var projected = pages.Where(page => page.Source.Start < source.End && page.Source.End > source.Start)
                .Select(page => page with { Source = new(Math.Max(page.Source.Start, source.Start) + offset,
                    Math.Min(page.Source.End, source.End) + offset) }).ToArray();
            cues.AddRange(TimelineCaptions.Cues(projected, TimelineAxis.Source, OpenCuts));
        }
        return cues;
    }
}
