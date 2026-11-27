using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed record RecordingClipLine(TakeMatch.Beat Beat, int Number, ClipPartRow Part, TakeMatch.Take Take,
    string FirstId, string LastId)
{
    internal string Id => Beat.Id;
    internal TakeMatch.AlignedSpan? Span(string key) => Beat.Spans.FirstOrDefault(span => span.FromKey == Take.Key && span.ToKey == key);
    internal IReadOnlyList<TakeMatch.Take> Alternatives => Beat.Takes.Where(take => Span(take.Key) is not null).ToArray();
}

internal sealed record RecordingAudition(Project Project, string FirstId, string LastId);
internal enum RecordingVersionKey { Up, Down, Play, Use, Close }

public sealed partial class EditorViewModel
{
    private (Project Project, string ClipId, IReadOnlyList<RecordingClipLine> Lines)? cachedRecordingLines;
    private (Project Project, string ClipId)? openRecordingVersions;
    internal string? OpenRecordingLineId { get; private set; }
    internal string? SelectedRecordingVersionKey { get; private set; }
    internal bool OtherRecordingLinesExpanded { get; private set; }

    internal IReadOnlyList<RecordingClipLine> RecordingClipLines
    {
        get
        {
            if (ActiveClip is not { } clip || RecordingMatches() is not { } matches) return [];
            if (cachedRecordingLines is { } cached && ReferenceEquals(cached.Project, project) && cached.ClipId == clip.Id) return cached.Lines;
            var lines = new List<RecordingClipLine>();
            var seen = new HashSet<string>();
            foreach (var part in ClipParts)
            {
                if (part.Recording is not { } recording) continue;
                var candidates = new List<(TakeMatch.Beat Beat, TakeMatch.Take Take, int First, int Last)>();
                foreach (var beat in matches.Beats)
                {
                    if (seen.Contains(beat.Id) || beat.Takes.FirstOrDefault(take => take.Key == recording.Key) is not { } take) continue;
                    var range = new[] { (take.StartWordId, take.EndWordId) }.Concat(beat.Spans.Where(span => span.ToKey == take.Key)
                        .Select(span => (span.StartWordId, span.EndWordId))).Select(span => (First: Index(span.StartWordId), Last: Index(span.EndWordId)))
                        .FirstOrDefault(range => range.Item1 >= part.First && range.Item2 >= range.Item1 && range.Item2 <= part.Last, (-1, -1));
                    if (range.Item1 >= 0) candidates.Add((beat, take, range.Item1, range.Item2));
                }
                foreach (var (beat, take, first, last) in candidates.OrderBy(candidate => candidate.First))
                {
                    seen.Add(beat.Id);
                    lines.Add(new(beat, lines.Count + 1, part, take, Words[first].Id, Words[last].Id));
                }
            }
            cachedRecordingLines = (project, clip.Id, lines);
            return lines;
        }
    }

    internal string RecordingVersionsName(RecordingClipLine line)
    {
        var labels = line.Alternatives.Select(take => RecordingRegions.First(region => region.Key == take.Key).Label).ToArray();
        var list = labels.Length < 2 ? string.Join("", labels) : string.Join(", ", labels[..^1]) + " and " + labels[^1];
        return $"Line {line.Number}, {labels.Length} other version{(labels.Length == 1 ? "" : "s")}, in {list}";
    }

    internal bool OpenRecordingVersions(RecordingClipLine line)
    {
        if (ActiveClip is not { } clip || line.Alternatives.FirstOrDefault() is not { } alternative) return false;
        openRecordingVersions = (project, clip.Id);
        OpenRecordingLineId = line.Id;
        SelectedRecordingVersionKey = alternative.Key;
        Announce(RecordingVersionsName(line));
        return true;
    }

    internal RecordingClipLine? OpenRecordingLine => openRecordingVersions is { } opened &&
        ReferenceEquals(opened.Project, project) && opened.ClipId == ActiveClip?.Id && TranscriptRecordingView.Kind == RecordingViewKind.PlayOrder
            ? RecordingClipLines.FirstOrDefault(line => line.Id == OpenRecordingLineId) : null;

    internal void CloseRecordingVersions()
    {
        openRecordingVersions = null;
        OpenRecordingLineId = null;
        SelectedRecordingVersionKey = null;
    }

    internal void SelectRecordingVersion(string key) => SelectedRecordingVersionKey = key;

    internal RecordingClipLine? RecordingLineAt(int word) => TranscriptRecordingView.Kind == RecordingViewKind.PlayOrder
        ? RecordingClipLines.FirstOrDefault(line => line.Alternatives.Count > 0 && Index(line.FirstId) <= word && word <= Index(line.LastId)) : null;

    internal bool HandleRecordingVersionKey(RecordingVersionKey key, Action<RecordingAudition> play, Action stop)
    {
        if (OpenRecordingLine is not { } line) return false;
        var takes = new[] { line.Take }.Concat(line.Alternatives).ToArray();
        var index = Math.Max(0, Array.FindIndex(takes, take => take.Key == SelectedRecordingVersionKey));
        switch (key)
        {
            case RecordingVersionKey.Up: SelectedRecordingVersionKey = takes[Math.Max(0, index - 1)].Key; break;
            case RecordingVersionKey.Down: SelectedRecordingVersionKey = takes[Math.Min(takes.Length - 1, index + 1)].Key; break;
            case RecordingVersionKey.Play:
                if (RecordingLineAudition(line, takes[index].Key) is { } audition) play(audition);
                break;
            case RecordingVersionKey.Use: UseRecordingLineVersion(line, takes[index].Key); break;
            case RecordingVersionKey.Close: CloseRecordingVersions(); stop(); break;
        }
        return true;
    }

    private RecordingEdit.UseLineVersion? RecordingLineEdit(RecordingClipLine line, string key) =>
        ActiveClip is { } clip && line.Span(key) is not null ? new(clip.Id, line.Id, key) : null;

    internal string? RecordingLineDisabledReason(RecordingClipLine line, string key) => RecordingUnavailable(key) ??
        (RecordingLineEdit(line, key) is { } edit && RecordingEdits.Apply(edit, project) is RecordingEditResult.Refused refused ? refused.Message : null);

    internal string? RecordingLineCopyReason(RecordingClipLine line, string key) => RecordingLineEdit(line, key) is { } edit
        ? RecordingCopyReason(line.Part, edit) : null;

    internal RecordingAudition? RecordingLineAudition(RecordingClipLine line, string key)
    {
        if (RecordingUnavailable(key) is not null) return null;
        if (key == line.Take.Key) return new(project, line.FirstId, line.LastId);
        return RecordingLineEdit(line, key) is { } edit && line.Span(key) is { } span &&
            RecordingEdits.Apply(edit, project) is RecordingEditResult.Applied applied ? new(applied.Project, span.StartWordId, span.EndWordId) : null;
    }

    internal bool UseRecordingLineVersion(RecordingClipLine line, string key)
    {
        if (!CanEditParts || RecordingUnavailable(key) is not null || RecordingLineEdit(line, key) is not { } edit ||
            RecordingRegions.FirstOrDefault(region => region.Key == key) is not { } region) return false;
        if (!ApplyRecordingEdit(edit, feedback: applied => Notice = $"Line {line.Number} now uses {region.Label}'s version" +
            (applied.Details?.SplitPartId is null ? "" : $" · part {line.Part.Number} split"))) return false;
        CloseRecordingVersions();
        ChooseRecordingView(new(RecordingViewKind.PlayOrder), announce: false);
        return true;
    }

    internal IReadOnlyList<TakeMatch.SoloRun> OtherRecordingLines
    {
        get
        {
            if (ActiveClip is null || RecordingMatches() is not { } matches) return [];
            var order = RecordingClipLines.ToDictionary(line => line.Id, line => line.Number);
            return matches.Solo.Where(run => !ClipParts.Any(part => part.First <= Index(run.EndWordId) && Index(run.StartWordId) <= part.Last))
                .OrderBy(run => order.GetValueOrDefault(run.AfterBeatId ?? "", int.MaxValue)).ToArray();
        }
    }

    internal void SetOtherRecordingLinesExpanded(bool expanded) => OtherRecordingLinesExpanded = expanded;

    internal string? RecordingPlacement(TakeMatch.SoloRun run) => RecordingClipLines.FirstOrDefault(line => line.Id == run.AfterBeatId)?.LastId;

    internal string? RecordingPlacementQuote(TakeMatch.SoloRun run)
    {
        var line = RecordingClipLines.FirstOrDefault(line => line.Id == run.AfterBeatId);
        var take = RecordingMatches()?.Beats.FirstOrDefault(beat => beat.Id == run.AfterBeatId)?.Takes.FirstOrDefault(take => take.Key == run.Key);
        if ((line?.FirstId ?? take?.StartWordId) is not { } first || (line?.LastId ?? take?.EndWordId) is not { } last) return null;
        var count = Index(last) - Index(first) + 1;
        var phrase = string.Join(" ", Words.Skip(Math.Max(Index(first), Index(last) - 3)).Take(Math.Min(4, count)).Select(DisplayText));
        return $"“{(count > 4 ? "…" : "")}{phrase.Trim(' ', '.', ',', '!', '?', ':', ';', '…')}”";
    }

    private RecordingEdit.InsertLine? RecordingSoloEdit(TakeMatch.SoloRun run, bool atEnd) =>
        ActiveClip is { } clip && (atEnd || RecordingPlacement(run) is not null)
            ? new(clip.Id, run.Key, run.StartWordId, run.EndWordId, atEnd ? null : RecordingPlacement(run)) : null;

    internal RecordingAudition? RecordingSoloAudition(TakeMatch.SoloRun run) => RecordingUnavailable(run.Key) is null &&
        RecordingSoloEdit(run, false) is { } edit && RecordingEdits.Apply(edit, project) is RecordingEditResult.Applied applied
        ? new(applied.Project, run.StartWordId, run.EndWordId) : null;

    internal string? RecordingSoloDisabledReason(TakeMatch.SoloRun run, bool atEnd = false) => RecordingUnavailable(run.Key) ??
        (!atEnd && RecordingPlacement(run) is null ? (RecordingPlacementQuote(run) is { } quote
            ? $"{quote} isn't in {ActiveClipLabel}. Insert it at the end, then move it."
            : $"This line has no match in {ActiveClipLabel}. Insert it at the end, then move it.") :
        RecordingSoloEdit(run, atEnd) is { } edit && RecordingEdits.Apply(edit, project) is RecordingEditResult.Refused refused ? refused.Message : null);

    internal bool InsertRecordingLine(TakeMatch.SoloRun run, bool atEnd = false)
    {
        if (!CanEditParts || RecordingUnavailable(run.Key) is not null || RecordingSoloEdit(run, atEnd) is not { } edit) return false;
        var quote = RecordingPlacementQuote(run);
        var label = RecordingRegions.FirstOrDefault(region => region.Key == run.Key)?.Label ?? run.Key;
        return ApplyRecordingEdit(edit, feedback: _ =>
        {
            var word = Index(run.StartWordId);
            var number = ClipParts.FirstOrDefault(part => part.First <= word && word <= part.Last)?.Number ?? 1;
            var suffix = atEnd ? "at the end" : quote is not null ? $"after {quote}" : "in place";
            return Notice = $"Part {number} added from {label}, {suffix}";
        });
    }
}
