using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal enum TranscriptPieceKind { Source, Pause, Fold, Inserted, Comma }

internal sealed record TranscriptPiece(TranscriptPieceKind Kind, string Text, int First, int Last, bool Outside = false,
    bool Removed = false, bool Ai = false, TranscriptProposalHunk? Change = null,
    IReadOnlyList<string>? WordIds = null, IReadOnlyList<string>? PauseIds = null, bool Filler = false)
{
    internal bool Selectable => Kind == TranscriptPieceKind.Source;
    internal string FoldName => $"{WordIds?.Count ?? 0} cut: {Text}";
}

internal static class TranscriptParagraphPresentation
{
    internal static IReadOnlyList<TranscriptPiece> Build(IReadOnlyList<TimedWord> words, int start, int count,
        Func<int, TranscriptSpeechWord> speech, IReadOnlySet<string> cuts, IReadOnlySet<string> cutPauses,
        IReadOnlyDictionary<int, Pause> pauses, int clipFirst, int clipLast, bool showCuts, bool showPauses,
        IReadOnlySet<string> expanded, TranscriptProposalPresentation proposal, int selectionFirst = -1, int selectionLast = -1)
    {
        List<TranscriptPiece> pieces = [];
        var end = Math.Min(words.Count, checked(start + count));
        for (var index = start; index < end; index++)
        {
            var presented = speech(index);
            if (!presented.Visible) continue;
            var word = words[index];
            var outside = presented.LastSourceIndex < clipFirst || index > clipLast;
            var change = outside ? null : proposal.At(index);
            var pending = change?.State == TranscriptChangeState.Pending;
            if (!outside) AddInsertions(index, true);
            var cut = !presented.AiModified && cuts.Contains(word.Id);
            var bridge = change?.Hunk.BridgeWordIds.Contains(word.Id) == true;
            pieces.Add(new(TranscriptPieceKind.Source, presented.Text + " ", index, presented.LastSourceIndex, outside,
                !outside && (cut || pending && !bridge), presented.AiModified, change, [word.Id], [], EditingAlgorithms.IsFillerText(presented.Text)));
            if (!outside) AddInsertions(index, false);
            if (!outside && showPauses && pauses.TryGetValue(presented.LastSourceIndex, out var pause))
                pieces.Add(new(TranscriptPieceKind.Pause, TranscriptWordDecoration.VisiblePause(pause.Label), index,
                    presented.LastSourceIndex, Removed: cutPauses.Contains(pause.Id), PauseIds: [pause.Id]));

            void AddInsertions(int sourceIndex, bool before)
            {
                foreach (var insertion in proposal.Insertions(sourceIndex, before))
                    pieces.Add(new(TranscriptPieceKind.Inserted, insertion.Text + " ", -1, -1, Change: insertion.Change));
            }
        }
        if (showCuts) return OpenCommas(pieces);
        List<TranscriptPiece> folded = [];
        for (var index = 0; index < pieces.Count; index++)
        {
            var piece = pieces[index];
            if (!CanFold(piece)) { folded.Add(piece); continue; }
            List<TranscriptPiece> removed = [piece];
            while (index + 1 < pieces.Count && CanFold(pieces[index + 1])) removed.Add(pieces[++index]);
            var previous = folded.LastOrDefault();
            var wordsRemoved = removed.Where(item => item.Kind == TranscriptPieceKind.Source).ToArray();
            if (previous is { Kind: TranscriptPieceKind.Source, Outside: false })
            {
                var previousText = previous.Text.TrimEnd();
                if (wordsRemoved.Length > 0 && wordsRemoved.All(item => item.Filler)) previousText = previousText.TrimEnd(',');
                folded[^1] = previous with { Text = previousText };
            }
            folded.Add(new(TranscriptPieceKind.Fold, string.Join(" ", removed.Select(item => item.Kind == TranscriptPieceKind.Pause
                ? "pause " + item.Text.TrimEnd().TrimEnd('s').Trim() + " seconds" : item.Text.Trim())), removed[0].First, removed[^1].Last,
                WordIds: removed.SelectMany(item => item.WordIds ?? []).ToArray(),
                PauseIds: removed.SelectMany(item => item.PauseIds ?? []).ToArray()));
        }
        return OpenCommas(folded);

        bool CanFold(TranscriptPiece piece) => !piece.Outside && piece.Removed && piece.Change is null &&
            (piece.Kind is TranscriptPieceKind.Source or TranscriptPieceKind.Pause) &&
            !(selectionFirst >= 0 && piece.Last >= selectionFirst && piece.First <= selectionLast) &&
            !(piece.WordIds ?? []).Concat(piece.PauseIds ?? []).Any(expanded.Contains);
    }

    private static IReadOnlyList<TranscriptPiece> OpenCommas(List<TranscriptPiece> pieces)
    {
        for (var index = 0; index + 1 < pieces.Count; index++)
        {
            var previous = pieces[index];
            if (previous is not { Kind: TranscriptPieceKind.Source, Removed: false, Outside: false } || !previous.Text.TrimEnd().EndsWith(',')) continue;
            var end = index + 1;
            while (end < pieces.Count && pieces[end] is { Removed: true, Change: null } && pieces[end].Kind is TranscriptPieceKind.Source or TranscriptPieceKind.Pause) end++;
            var removedWords = pieces.Skip(index + 1).Take(end - index - 1).Where(piece => piece.Kind == TranscriptPieceKind.Source).ToArray();
            if (removedWords.Length == 0 || removedWords.Any(piece => !piece.Filler)) continue;
            pieces[index] = previous with { Text = previous.Text.TrimEnd().TrimEnd(',') };
            pieces.Insert(index + 1, new(TranscriptPieceKind.Comma, ", ", previous.First, previous.Last, Removed: true));
            index = end;
        }
        return pieces;
    }
}
