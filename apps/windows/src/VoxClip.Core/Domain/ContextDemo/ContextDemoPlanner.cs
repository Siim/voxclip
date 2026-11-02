#pragma warning disable CS1591
using System.Collections.Immutable;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.ContextDemo;

public static class ContextDemoPlanner
{
    private static void CheckCancellation(CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested) throw new ContextDemoException(ContextDemoError.Cancelled);
    }

    public static ContextDemoRenderInput Prepare(ContextDemoDocument document, Project project, RenderTimeline timeline,
        TimeRange? scope = null, int? expectedRevision = null, CancellationToken cancellationToken = default)
    {
        CheckCancellation(cancellationToken);
        document.Validate();
        ContextDemoValidation.Require(expectedRevision is null || expectedRevision == document.Revision, ContextDemoError.StaleRevision);
        ContextDemoValidation.Require(document.IsCurrent(project, timeline), ContextDemoError.StaleNarration);
        var selected = scope ?? new TimeRange(0, document.Narration.DurationSeconds);
        ContextDemoValidation.Require(ContextDemoValidation.Range(selected) && ContextDemoValidation.HasSamples(selected, timeline.SampleRate) &&
            selected.End <= document.Narration.DurationSeconds &&
            ContextDemoValidation.OnGrid(selected.Start, timeline.SampleRate) && ContextDemoValidation.OnGrid(selected.End, timeline.SampleRate),
            ContextDemoError.InvalidPlacement);
        var prepared = ImmutableArray.CreateBuilder<ContextDemoPreparedPlacement>();
        var used = new HashSet<string>(StringComparer.Ordinal);
        foreach (var placement in document.Placements)
        {
            CheckCancellation(cancellationToken);
            var start = Math.Max(selected.Start, placement.EditedStartSeconds);
            var end = Math.Min(selected.End, placement.EditedEndSeconds);
            if (start >= end) continue;
            var mappings = ImmutableArray.CreateBuilder<ContextDemoNarrationMapping>();
            foreach (var piece in document.Narration.Pieces)
            {
                CheckCancellation(cancellationToken);
                var intersectionStart = Math.Max(start, piece.Output.Start);
                var intersectionEnd = Math.Min(end, piece.Output.End);
                if (intersectionStart >= intersectionEnd) continue;
                var scale = (piece.Source.End - piece.Source.Start) / (piece.Output.End - piece.Output.Start);
                mappings.Add(new(new(piece.Source.Start + (intersectionStart - piece.Output.Start) * scale,
                                     piece.Source.Start + (intersectionEnd - piece.Output.Start) * scale),
                                 new(intersectionStart - selected.Start, intersectionEnd - selected.Start)));
            }
            prepared.Add(new(placement.Id, placement.AssetId,
                new(placement.Source.Start + start - placement.EditedStartSeconds, placement.Source.Start + end - placement.EditedStartSeconds),
                new(start - selected.Start, end - selected.Start), mappings.ToImmutable()));
            used.Add(placement.AssetId);
        }
        CheckCancellation(cancellationToken);
        return new(document, selected, prepared.ToImmutable(), document.Assets.Where(asset => used.Contains(asset.Id))
            .OrderBy(asset => asset.Id, StringComparer.Ordinal).ToImmutableArray());
    }

    internal static void VerifyRenderedTimeline(ContextDemoRenderInput input, RenderTimeline timeline)
    {
        var actual = ContextDemoNarrationSnapshot.FromTimeline(timeline);
        ContextDemoValidation.Require(actual.SampleRate == input.Narration.SampleRate &&
            Math.Abs(actual.DurationSeconds - (input.Scope.End - input.Scope.Start)) * actual.SampleRate <= .000001, ContextDemoError.StaleNarration);
        var expected = input.Narration.Pieces.Select(piece =>
        {
            var start = Math.Max(input.Scope.Start, piece.Output.Start);
            var end = Math.Min(input.Scope.End, piece.Output.End);
            if (start >= end) return null;
            var scale = (piece.Source.End - piece.Source.Start) / (piece.Output.End - piece.Output.Start);
            return new ContextDemoNarrationPiece(new(piece.Source.Start + (start - piece.Output.Start) * scale,
                piece.Source.Start + (end - piece.Output.Start) * scale), new(start - input.Scope.Start, end - input.Scope.Start), piece.Synthetic);
        }).OfType<ContextDemoNarrationPiece>().ToArray();
        ContextDemoValidation.Require(expected.Length == actual.Pieces.Length, ContextDemoError.StaleNarration);
        for (var index = 0; index < expected.Length; index++)
        {
            var expectedPiece = expected[index];
            var actualPiece = actual.Pieces[index];
            double[] differences = [expectedPiece.Source.Start - actualPiece.Source.Start, expectedPiece.Source.End - actualPiece.Source.End,
                expectedPiece.Output.Start - actualPiece.Output.Start, expectedPiece.Output.End - actualPiece.Output.End];
            ContextDemoValidation.Require(expectedPiece.Synthetic == actualPiece.Synthetic &&
                differences.All(value => Math.Abs(value) * actual.SampleRate <= .000001), ContextDemoError.StaleNarration);
        }
    }
}
