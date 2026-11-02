using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed partial class RewriteSession
{
    private readonly PatchRewriteService patchService = new(new LlmCatalog());
    private readonly RewriteScope? requestedScope;
    private ScopeRewritePlan? scopePlan;
    private IReadOnlyList<ScopeRewriteDiff.Hunk>? scopeHunks;
    private readonly Dictionary<int, TranscriptChangeState> changeStates = [];
    internal int FocusedChange { get; private set; }
    internal Action<int>? RevealChange { get; set; }
    internal Action<int>? EditReviewChange { get; set; }
    internal void FocusChange(int ordinal)
    {
        if (Review is null || ordinal < 1 || ordinal > Review.Diff.Hunks.Count || FocusedChange == ordinal) return;
        FocusedChange = ordinal;
        Changed?.Invoke(this, EventArgs.Empty);
    }
    internal Func<CancellationToken, Task<bool>>? VoiceConsent { get; set; }
    internal IReadOnlyDictionary<int, TranscriptChangeState> ChangeStates => changeStates;
    internal IReadOnlyList<ScopeRewriteDiff.Hunk>? ScopeHunks => scopeHunks;
    internal IReadOnlyList<VoiceLabDiffHunk> IncludedHunks => Review?.Diff.Hunks.Where((_, index) =>
        changeStates.GetValueOrDefault(index + 1) != TranscriptChangeState.Excluded).ToArray() ?? [];
    internal bool ReviewIsCurrent => GenerationIsCurrent && !IsProposing && !IsGeneratingBatch;
    internal string ReviewIdentity => System.Text.Json.JsonSerializer.Serialize(new
    {
        Project.Id, Scope, Instruction, NewWords, Diff = Review?.Diff, Metadata = scopeHunks,
        States = changeStates.OrderBy(pair => pair.Key).ToArray(), Local = LocalOperations()
    });

    internal bool SetChangeIncluded(int ordinal, bool included)
    {
        if (!ReviewIsCurrent || Review is null || ordinal <= 0 || ordinal > Review.Diff.Hunks.Count) return false;
        InvalidateProposal();
        changeStates[ordinal] = included ? TranscriptChangeState.Pending : TranscriptChangeState.Excluded;
        RefreshReview();
        InvalidateGenerationInputs();
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    internal bool EditChange(int ordinal, string text)
    {
        if (!ReviewIsCurrent || Review is null || ordinal <= 0 || ordinal > Review.Diff.Hunks.Count) return false;
        var hunk = Review.Diff.Hunks[ordinal - 1];
        try
        {
            var sourceIds = hunk.SourceWordIds.ToHashSet(StringComparer.Ordinal);
            var local = VoiceLabWordDiff.Diff(Source.Where(word => sourceIds.Contains(word.Id)).ToArray(), text);
            var proposals = scopeHunks ?? Review.Diff.Hunks.Select(change => new ScopeRewriteDiff.Hunk(change, null, [], [], false)).ToArray();
            var metadata = proposals[ordinal - 1];
            var replacements = local.Hunks.Select(change => metadata with
            {
                Diff = change with { SourceStartIndex = change.SourceStartIndex + hunk.SourceStartIndex,
                    SourceEndIndex = change.SourceEndIndex + hunk.SourceStartIndex, AnchorSeconds = change.AnchorSeconds ?? hunk.AnchorSeconds }
            }).ToArray();
            var dispositions = changeStates.ToArray();
            InvalidateProposal();
            scopeHunks = proposals.Take(ordinal - 1).Concat(replacements).Concat(proposals.Skip(ordinal)).ToArray();
            changeStates.Clear();
            foreach (var pair in dispositions.Where(pair => pair.Key != ordinal))
                changeStates[pair.Key < ordinal ? pair.Key : pair.Key + replacements.Length - 1] = pair.Value;
            NewWords = string.Join(" ", ReviewDiff().Ops.Where(operation => operation.NewToken is not null).Select(operation => operation.NewToken));
            RefreshReview();
            InvalidateGenerationInputs();
            Changed?.Invoke(this, EventArgs.Empty);
            return true;
        }
        catch (VoiceLabWordDiffException error) { reviewProblem = Refusal(error); Changed?.Invoke(this, EventArgs.Empty); return false; }
    }

    internal VoiceLabWordDiffResult ReviewDiff()
    {
        if (scopeHunks is null) return VoiceLabWordDiff.Diff(Source, NewWords);
        var tokens = Source.Where(word => word.Kind == WordKind.Word).SelectMany(word =>
            EditingAlgorithms.SplitWords(word.Text).Select(token => (Word: word, Token: token))).ToArray();
        List<VoiceLabDiffOp> operations = [];
        var cursor = 0;
        foreach (var proposal in scopeHunks)
        {
            var hunk = proposal.Diff;
            while (cursor < hunk.SourceStartIndex)
            {
                var item = tokens[cursor++];
                operations.Add(new(VoiceLabDiffOpKind.Equal, item.Word.Id, item.Token, item.Token));
            }
            var owners = hunk.SourceWordIds.ToHashSet(StringComparer.Ordinal);
            var local = VoiceLabWordDiff.Diff(Source.Where(word => owners.Contains(word.Id)).ToArray(), string.Join(" ", hunk.NewTokens));
            operations.AddRange(local.Ops);
            cursor = hunk.SourceEndIndex;
        }
        while (cursor < tokens.Length)
        {
            var item = tokens[cursor++];
            operations.Add(new(VoiceLabDiffOpKind.Equal, item.Word.Id, item.Token, item.Token));
        }
        return new(operations, scopeHunks.Select(hunk => hunk.Diff).ToArray());
    }
}
