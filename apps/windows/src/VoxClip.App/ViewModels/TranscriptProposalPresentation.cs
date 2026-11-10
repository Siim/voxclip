using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>A change's review (design.md §6.3.5; Mac <c>TranscriptChange.State</c>): waiting, left out (its original words), or kept. A kept
/// change is included for takes and Use, priced and voiced as a waiting one, and has no thread. Windows applies every change at Use, so a
/// kept change still shows its words.</summary>
internal enum TranscriptChangeState { Pending, Excluded, Kept }

internal sealed record TranscriptProposalHunk(int Ordinal, VoiceLabDiffHunk Hunk, int First, int Last,
    int Anchor, bool Before, TranscriptChangeState State)
{
    internal string NewText => string.Join(" ", Hunk.NewTokens);
    internal int Priority => Hunk.Kind switch { VoiceLabDiffHunkKind.Voice => 3, VoiceLabDiffHunkKind.TextOnly => 2, _ => 1 };
    /// <summary>Its words show as the change makes them: waiting or kept, not left out.</summary>
    internal bool ShowsNewWords => State != TranscriptChangeState.Excluded;
    /// <summary>", kept" or ", left out" after a review, as the Mac's change description ends.</summary>
    internal string Reviewed => State switch { TranscriptChangeState.Kept => ", kept", TranscriptChangeState.Excluded => ", left out", _ => "" };
}

internal sealed record TranscriptProposalInsertion(TranscriptProposalHunk Change, string Text);

internal sealed class TranscriptProposalPresentation
{
    internal static readonly TranscriptProposalPresentation Empty = new([], new Dictionary<int, TranscriptProposalHunk>(),
        new Dictionary<(int, bool), IReadOnlyList<TranscriptProposalInsertion>>());
    internal IReadOnlyList<TranscriptProposalHunk> Hunks { get; }
    internal int TotalCount { get; }
    private readonly IReadOnlyDictionary<int, TranscriptProposalHunk> source;
    private readonly IReadOnlyDictionary<(int, bool), IReadOnlyList<TranscriptProposalInsertion>> insertions;

    private TranscriptProposalPresentation(IReadOnlyList<TranscriptProposalHunk> hunks,
        IReadOnlyDictionary<int, TranscriptProposalHunk> source,
        IReadOnlyDictionary<(int, bool), IReadOnlyList<TranscriptProposalInsertion>> insertions, int totalCount = 0)
    {
        Hunks = hunks;
        TotalCount = totalCount;
        this.source = source;
        this.insertions = insertions;
    }

    internal TranscriptProposalHunk? At(int index) => source.GetValueOrDefault(index);
    internal IReadOnlyList<TranscriptProposalInsertion> Insertions(int index, bool before) => insertions.GetValueOrDefault((index, before)) ?? [];

    internal static TranscriptProposalPresentation From(VoiceLabWordDiffResult diff, IReadOnlyList<TimedWord> sourceWords,
        IReadOnlyList<TimedWord> transcript, int? insertionAfter = null, IReadOnlyDictionary<int, TranscriptChangeState>? states = null)
    {
        var positions = transcript.Select((word, index) => (word.Id, index)).ToDictionary(pair => pair.Id, pair => pair.index, StringComparer.Ordinal);
        var owners = sourceWords.Where(word => word.Kind == WordKind.Word)
            .SelectMany(word => VoxClip.Core.Domain.Editing.EditingAlgorithms.SplitWords(word.Text).Select(_ => word.Id)).ToArray();
        List<TranscriptProposalHunk> hunks = [];
        Dictionary<int, TranscriptProposalHunk> bySource = [];
        for (var offset = 0; offset < diff.Hunks.Count; offset++)
        {
            var hunk = diff.Hunks[offset];
            var ordinal = offset + 1;
            var state = states?.GetValueOrDefault(ordinal) ?? TranscriptChangeState.Pending;
            var ids = hunk.SourceWordIds.Concat(hunk.AbsorbedItemIds).Distinct(StringComparer.Ordinal).ToArray();
            if (ids.Any(id => !positions.ContainsKey(id))) continue;
            var indices = ids.Select(id => positions[id]).Order().ToArray();
            var first = indices.FirstOrDefault(-1);
            var last = indices.LastOrDefault(-1);
            var before = first < 0 && hunk.SourceStartIndex >= 0 && hunk.SourceStartIndex < owners.Length;
            var anchor = first >= 0 ? last : before ? positions.GetValueOrDefault(owners[hunk.SourceStartIndex], -1)
                : insertionAfter ?? (owners.Length > 0 ? positions.GetValueOrDefault(owners[^1], -1) : -1);
            if (anchor < 0 || anchor >= transcript.Count) continue;
            if (hunk.Kind == VoiceLabDiffHunkKind.TextOnly && OnlyPunctuationChanges(hunk, transcript, positions)) continue;
            var presented = new TranscriptProposalHunk(ordinal, hunk, first, last, anchor, before, state);
            hunks.Add(presented);
            foreach (var index in indices) bySource[index] = presented;
        }
        Dictionary<(int Anchor, bool Before, int Ordinal), List<string>> addedTokens = [];
        Dictionary<int, List<string>> resultingWords = [];
        var cursor = 0;
        foreach (var operation in diff.Ops)
        {
            var tokenIndex = cursor;
            if (operation.SourceWordId is not null) cursor++;
            if (operation.Kind == VoiceLabDiffOpKind.Equal && operation.SourceWordId is { } sourceId && operation.NewToken is { } equalToken && positions.TryGetValue(sourceId, out var sourceIndex))
            {
                if (!resultingWords.TryGetValue(sourceIndex, out var surface)) resultingWords[sourceIndex] = surface = [];
                surface.Add(equalToken);
            }
            var adds = operation.Kind == VoiceLabDiffOpKind.Insert || operation.Kind == VoiceLabDiffOpKind.Equal && operation.SourceToken != operation.NewToken;
            if (!adds || operation.NewToken is null) continue;
            var change = hunks.FirstOrDefault(hunk => hunk.ShowsNewWords &&
                tokenIndex >= hunk.Hunk.SourceStartIndex && (operation.Kind == VoiceLabDiffOpKind.Insert
                    ? tokenIndex <= hunk.Hunk.SourceEndIndex : tokenIndex < hunk.Hunk.SourceEndIndex));
            if (change is null) continue;
            var before = operation.Kind == VoiceLabDiffOpKind.Insert && tokenIndex == change.Hunk.SourceStartIndex && change.First < 0 && change.Before;
            var anchor = before ? change.Anchor : operation.SourceWordId is { } owner ? positions.GetValueOrDefault(owner, -1)
                : tokenIndex > 0 && tokenIndex <= owners.Length ? positions.GetValueOrDefault(owners[tokenIndex - 1], -1) : change.Anchor;
            if (anchor < 0) continue;
            var key = (anchor, before, change.Ordinal);
            if (!addedTokens.TryGetValue(key, out var tokens)) addedTokens[key] = tokens = [];
            tokens.Add(operation.NewToken);
            if (operation.Kind == VoiceLabDiffOpKind.Insert && !before)
            {
                if (!resultingWords.TryGetValue(anchor, out var surface)) resultingWords[anchor] = surface = [];
                surface.Add(operation.NewToken);
            }
        }
        foreach (var pair in addedTokens)
            if (!pair.Key.Before && bySource.TryGetValue(pair.Key.Anchor, out var owner) && owner.Ordinal == pair.Key.Ordinal &&
                VoxClip.Core.Domain.Editing.EditingAlgorithms.SplitWords(transcript[pair.Key.Anchor].Text).Count > 1 && resultingWords.TryGetValue(pair.Key.Anchor, out var surface))
            {
                pair.Value.Clear();
                pair.Value.AddRange(surface);
            }
        var additions = addedTokens.GroupBy(pair => (pair.Key.Anchor, pair.Key.Before)).ToDictionary(group => group.Key,
            group => (IReadOnlyList<TranscriptProposalInsertion>)group.Select(pair =>
                new TranscriptProposalInsertion(hunks.First(hunk => hunk.Ordinal == pair.Key.Ordinal), string.Join(" ", pair.Value))).ToArray());
        return new(hunks, bySource, additions, diff.Hunks.Count);
    }

    private static bool OnlyPunctuationChanges(VoiceLabDiffHunk hunk, IReadOnlyList<TimedWord> words, IReadOnlyDictionary<string, int> positions)
    {
        static string Letters(string text) => string.Concat(text.Where(character => !char.IsPunctuation(character) && !char.IsWhiteSpace(character)));
        return Letters(string.Join(" ", hunk.SourceWordIds.Select(id => words[positions[id]].Text))) == Letters(string.Join(" ", hunk.NewTokens));
    }
}
