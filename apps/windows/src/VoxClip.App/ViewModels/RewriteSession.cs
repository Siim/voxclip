using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record RewriteConnector(ILlmConnector Connector, string Model, string Name, string Group, string Plan);

internal sealed class RewriteSession : IDisposable
{
    private readonly VoiceRewriteService service = new(new LlmCatalog());
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? sending;
    private VoiceRewriteRequest? request;
    private int revision;
    private bool estimateShown;
    private readonly VoiceLabPriceCatalog? prices;
    private readonly string? synthesisModel;
    internal EditorViewModel Editor { get; }
    internal Project Project { get; }
    internal IReadOnlyList<TimedWord> Transcript { get; }
    internal IReadOnlyList<TimedWord> Source { get; }
    internal VoiceLabOutputScope Scope { get; }
    internal AudioEnvelope? Envelope { get; }
    internal RewriteConnector? Connector { get; }
    internal int? InsertionAfter { get; }
    internal bool IsOpen { get; private set; } = true;
    internal bool IsProposing { get; private set; }
    internal string Instruction { get; private set; } = "";
    internal string NewWords { get; private set; }
    internal string Problem { get; private set; } = "";
    internal VoiceLabPreparedAction? Prepared { get; private set; }
    internal VoiceLabCostPresentationResult? Estimate { get; private set; }
    internal string ProposalButton => Estimate is null ? "Rewrite" : VoiceLabCostPresentation.ButtonTitle("Rewrite", null, Estimate);
    internal string EstimateCopy => Estimate?.Text is { Length: > 0 } text ? text : Prepared is null ? "" : "No charge.";
    internal bool CanPropose => IsOpen && !IsProposing && estimateShown && Prepared is not null;
    internal string Header { get; }
    internal RewriteReview? Review { get; private set; }
    internal string? LocalAction => Review is { Diff.Hunks.Count: > 0 } review &&
        review.Diff.Hunks.All(hunk => hunk.Kind != VoiceLabDiffHunkKind.Voice)
        ? review.Diff.Hunks.Any(hunk => hunk.Kind == VoiceLabDiffHunkKind.TextOnly) ? "Apply Correction" : "Apply Cuts" : null;
    internal string SendLine => Connector?.Group switch
    {
        "apiKey" => $"Sends these {Source.Count(word => word.Kind == WordKind.Word)} words to {Connector.Name} with your key.",
        "cli" => $"Sends these {Source.Count(word => word.Kind == WordKind.Word)} words to {Connector.Name} with your sign-in. Counts toward your {Connector.Plan}.",
        "local" => "Runs on this PC. Nothing leaves it.",
        _ => "Choose a connector in Settings → Providers & Keys."
    };
    internal event EventHandler? Changed;

    internal RewriteSession(EditorViewModel editor, int first, int last, AudioEnvelope? envelope, RewriteConnector? connector,
        int? insertionAfter = null, VoiceLabPriceCatalog? prices = null, string? synthesisModel = null)
    {
        Editor = editor;
        Project = editor.Project;
        Transcript = editor.Words.Select(word => word.Kind == WordKind.Word ? word with { Text = editor.DisplayText(word) } : word).ToArray();
        Source = insertionAfter is null ? Transcript.Skip(first).Take(last - first + 1).ToArray() : [];
        Scope = Project.Edits.ActiveClipId is { } clipId ? VoiceLabOutputScope.Clip(clipId) : VoiceLabOutputScope.Full;
        Envelope = envelope;
        Connector = connector;
        InsertionAfter = insertionAfter;
        this.prices = prices;
        this.synthesisModel = synthesisModel;
        NewWords = string.Join(" ", Source.Where(word => word.Kind == WordKind.Word).Select(word => word.Text));
        var start = insertionAfter is { } after ? Transcript[after].End : Source.FirstOrDefault()?.Start ?? 0;
        Header = $"{Source.Count(word => word.Kind == WordKind.Word)} words at {EditorViewModel.Timecode(start)}";
        editor.SetRewriteRange(insertionAfter ?? first, insertionAfter is null ? last : insertionAfter.Value + 1);
        editor.Changed += EditorChanged;
        RefreshReview();
    }

    internal async Task SetInstructionAsync(string text)
    {
        if (!IsOpen) return;
        InvalidateProposal();
        Instruction = text;
        Prepared = null;
        Estimate = null;
        estimateShown = false;
        Problem = "";
        var current = revision;
        try
        {
            if (Connector is null) return;
            var words = Source.Where(word => word.Kind == WordKind.Word).ToArray();
            if (words.Length == 0 || Envelope is null)
            {
                Problem = InsertionAfter is not null ? Refusal(new(VoiceLabGeometryErrorCode.InsertionUnsupported))
                    : "Find the original video before rewriting speech. Your edits are saved.";
                return;
            }
            var window = VoiceLabWindowPlanner.Place(Project, Scope, Envelope, words[0].Id, words[^1].Id);
            var silence = VoiceLabWindowPlanner.LendableSilence(Project, Scope, window);
            var rate = VoiceLabLengthBudget.Rate(Transcript).CharactersPerSecond;
            var range = VoiceLabLengthBudget.Passage(window, Transcript, silence.Incoming, silence.Outgoing, rate);
            var input = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, words, text,
                Editor.State?.Transcript.Language ?? "en", range.TargetSeconds, range.MinChars, range.MaxChars);
            var action = await service.PrepareAsync(input, Connector.Connector, Connector.Model, lifetime.Token);
            if (!IsOpen || current != revision) return;
            request = input;
            Prepared = action;
            Estimate = VoiceLabCostPresentation.Kind(action.Estimate.ToCostEstimate(), false, Connector.Name);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (current == revision) Problem = Refusal(exception);
        }
        finally { if (IsOpen && current == revision) Changed?.Invoke(this, EventArgs.Empty); }
    }

    internal void MarkEstimateShown(VoiceLabPreparedAction action)
    {
        if (!IsOpen || !ReferenceEquals(Prepared, action) || estimateShown) return;
        estimateShown = true;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    internal async Task<bool> ProposeAsync(VoiceLabPreparedAction action, bool affirmative)
    {
        if (!CanPropose || !affirmative || !ReferenceEquals(Prepared, action) || request is null || Connector is null) return false;
        var current = revision;
        var input = request;
        sending = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var cancellation = sending;
        IsProposing = true;
        estimateShown = false;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var result = await service.ProposeAsync(input, Connector.Connector, Connector.Model, service.Approve(action, true), cancellation.Token);
            if (!IsOpen || revision != current) return false;
            NewWords = result.ProposedText;
            RefreshReview();
            return true;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return false; }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (IsOpen && revision == current) Problem = Refusal(exception);
            return false;
        }
        finally
        {
            if (ReferenceEquals(sending, cancellation)) sending = null;
            cancellation.Dispose();
            IsProposing = false;
            if (IsOpen)
            {
                Prepared = null;
                Changed?.Invoke(this, EventArgs.Empty);
                await SetInstructionAsync(Instruction);
            }
        }
    }

    internal void Edit(string text)
    {
        if (!IsOpen) return;
        InvalidateProposal();
        NewWords = text;
        RefreshReview();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void RefreshReview()
    {
        try { Review = RewriteReview.Build(this, prices, synthesisModel); }
        catch (VoiceLabWordDiffException exception)
        {
            Review = null;
            Problem = exception.Code == VoiceLabWordDiffErrorCode.TokenLimit ? VoiceLabPatchBudget.DisabledCopy : Refusal(exception);
        }
    }

    internal bool ApplyLocalChanges()
    {
        if (!IsOpen || LocalAction is null || !ReferenceEquals(Project, Editor.Project) || Editor.Busy || Editor.IsReadOnly || Editor.IsLeaving) return false;
        List<EditOperation> operations = [];
        foreach (var hunk in Review!.Diff.Hunks)
        {
            if (hunk.Kind == VoiceLabDiffHunkKind.Cut) operations.Add(new EditOperation.SetWordCuts(hunk.SourceWordIds, true));
            else if (hunk.Kind == VoiceLabDiffHunkKind.TextOnly)
                for (var index = 0; index < hunk.SourceWordIds.Count; index++)
                    operations.Add(new EditOperation.Correct(hunk.SourceWordIds[index], hunk.CorrectedTexts[index]));
        }
        return Editor.ApplyBatch(operations);
    }

    private void InvalidateProposal() { revision++; sending?.Cancel(); }
    private void EditorChanged(object? sender, EventArgs args) => Dispose();
    internal static string Refusal(Exception exception) => exception switch
    {
        VoiceLabGeometryException { Code: VoiceLabGeometryErrorCode.SeamFadeOutsideTake, Incoming: var incoming } =>
            $"This change is too close to the {(incoming == false ? "end" : "start")} of the take to blend in. Re-record this sentence instead.",
        VoiceLabGeometryException { Code: VoiceLabGeometryErrorCode.InsertionUnsupported } =>
            "Inserting words is not available in this build. Your edits are saved.",
        VoiceLabGeometryException => "This change can't be placed in this take. Your video and edits are still here.",
        VoiceLabLengthBudgetException => "There isn't enough timed speech to estimate this change. Your edits are saved.",
        _ => UiError.Message(exception, "Rewrite")
    };

    public void Dispose()
    {
        if (!IsOpen) return;
        IsOpen = false;
        InvalidateProposal();
        lifetime.Cancel();
        lifetime.Dispose();
        Editor.Changed -= EditorChanged;
        Editor.SetRewriteRange(-1, -1);
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
