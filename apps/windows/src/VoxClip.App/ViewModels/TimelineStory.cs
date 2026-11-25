using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record TimelinePartBand(ClipPartRow Part, TimeRange Range);
internal sealed record TimelinePartSeam(double Position, double TakeTime, int PartNumber, bool Backward)
{
    internal const int Stroke = 3;
    internal int Width => Stroke;
    internal string Label => $"{(Backward ? "↶" : "↷")} {EditorViewModel.Duration(TakeTime)}";
    internal string Description => $"Seam to part {PartNumber}, jumps {(Backward ? "back" : "ahead")} to {EditorViewModel.Duration(TakeTime)}, fades over 5 ms";
}

internal sealed class TimelineStory
{
    private readonly EditPlan plan;
    private readonly TimeRange[] sources;
    private readonly TimelinePartBand[] open;
    private readonly TimelinePartBand[] edited;
    private readonly TimelinePartSeam[] openSeams;
    private readonly TimelinePartSeam[] editedSeams;
    private readonly TimelinePieces editedPieces;
    internal TimelinePieces OpenPieces { get; }
    internal IReadOnlyList<TimelinePartBand> Overview { get; }
    internal IReadOnlyList<TimeRange> OpenCuts { get; }
    internal double Duration(bool closesCuts) => closesCuts ? plan.Duration : open.LastOrDefault()?.Range.End ?? 0;
    internal IReadOnlyList<TimelinePartBand> Bands(bool closesCuts) => closesCuts ? edited : open;
    internal IReadOnlyList<TimelinePartSeam> Seams(bool closesCuts) => closesCuts ? editedSeams : openSeams;

    internal TimelineStory(EditorViewModel model, EditPlan plan)
    {
        this.plan = plan;
        var parts = model.ClipParts;
        Overview = parts.Select(part => new TimelinePartBand(part, new(part.Start, part.End))).ToArray();
        sources = parts.Select((part, index) =>
        {
            var range = EditingAlgorithms.ClipTimes(model.Words, part.First, part.Last, index == 0 ? model.ActiveClip?.LeadInSeconds : null);
            return new TimeRange(range.Start, Math.Min(range.End, plan.TotalSamples / plan.SampleRate));
        }).ToArray();
        double cursor = 0;
        open = parts.Select((part, index) => new TimelinePartBand(part, new(cursor, cursor += sources[index].End - sources[index].Start))).ToArray();
        openSeams = open.Skip(1).Select((band, index) => new TimelinePartSeam(band.Range.Start, band.Part.Start,
            band.Part.Number, band.Part.Start < open[index].Part.End)).ToArray();

        editedPieces = new(new RenderTimeline.Legacy(plan));
        var bands = new List<TimelinePartBand>();
        var seams = new List<TimelinePartSeam>();
        var openPieces = new List<TimelinePiece>();
        for (var index = 0; index < editedPieces.Pieces.Count; index++)
        {
            var piece = editedPieces.Pieces[index];
            var section = Array.FindIndex(sources, source => source.Start < piece.Source.End && source.End > piece.Source.Start);
            if (section < 0) continue;
            var part = parts[section];
            var offset = open[section].Range.Start - sources[section].Start;
            openPieces.Add(piece with { Edited = new(piece.Source.Start + offset, piece.Source.End + offset) });
            if (editedPieces.IsPartSeam(index))
                seams.Add(new(piece.Edited.Start, piece.Source.Start, part.Number, piece.Source.Start < editedPieces.Pieces[index - 1].Source.End));
            if (bands.Count > 0 && bands[^1].Part.Id == part.Id)
                bands[^1] = bands[^1] with { Range = new(bands[^1].Range.Start, piece.Edited.End) };
            else bands.Add(new(part, piece.Edited));
        }
        edited = bands.ToArray();
        editedSeams = seams.ToArray();
        OpenPieces = new(openPieces);
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
    }

    internal double Display(double source, bool closesCuts)
    {
        var bands = Bands(closesCuts);
        if (bands.Count == 0) return 0;
        var band = bands.MinBy(item => Math.Max(item.Part.Start - source, Math.Max(0, source - item.Part.End)))!;
        if (closesCuts)
            return source <= band.Part.Start && band.Part.Number != 1 ? band.Range.Start
                : source >= band.Part.End ? band.Range.End : Math.Clamp(plan.MapTime(source), band.Range.Start, band.Range.End);
        var range = sources[band.Part.Number - 1];
        return band.Range.Start + Math.Clamp(source - range.Start, 0, range.End - range.Start);
    }

    internal double SourceAt(double position, bool closesCuts)
    {
        var bands = Bands(closesCuts);
        if (bands.Count == 0) return 0;
        if (position >= Duration(closesCuts)) return closesCuts ? editedPieces.Pieces[^1].Source.End : sources[^1].End;
        if (closesCuts) return plan.SourceTime(position);
        var band = bands.First(item => position < item.Range.End);
        return sources[band.Part.Number - 1].Start + Math.Max(0, position - band.Range.Start);
    }
}
