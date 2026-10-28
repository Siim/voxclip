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
    private readonly Func<CancellationToken, Task<bool>>? consent;
    private readonly Func<bool> connectorIsCurrent;
    private string proposalProblem = "";
    private string reviewProblem = "";
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
    internal string Problem => proposalProblem.Length > 0 ? proposalProblem : reviewProblem;
    internal VoiceLabPreparedAction? Prepared { get; private set; }
    internal VoiceLabCostPresentationResult? Estimate { get; private set; }
    internal string ProposalButton => Estimate is null || Connector?.Group == "cli" ? "Rewrite" :
        Connector?.Group == "local" ? "Rewrite · No charge" : VoiceLabCostPresentation.ButtonTitle("Rewrite", null, Estimate);
    internal string EstimateCopy => Estimate?.Text is { Length: > 0 } text ? text : Prepared is null ? "" : "No charge.";
    internal bool CanPropose => IsOpen && !IsProposing && !Editor.Busy && !Editor.IsLeaving && !Editor.IsReadOnly && estimateShown && Prepared is not null;
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
        _ => "Choose a connector in Settings → AI."
    };
    internal event EventHandler? Changed;

    internal RewriteSession(EditorViewModel editor, int first, int last, AudioEnvelope? envelope, RewriteConnector? connector,
        int? insertionAfter = null, VoiceLabPriceCatalog? prices = null, string? synthesisModel = null,
        Func<CancellationToken, Task<bool>>? consent = null, Func<bool>? connectorIsCurrent = null)
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
        this.consent = consent;
        this.connectorIsCurrent = connectorIsCurrent ?? (() => true);
        NewWords = string.Join(" ", Source.Where(word => word.Kind == WordKind.Word).Select(word => word.Text));
        var start = insertionAfter is { } after ? Transcript[after].End : Source.FirstOrDefault()?.Start ?? 0;
        Header = $"{Source.Count(word => word.Kind == WordKind.Word)} words at {EditorViewModel.Timecode(start)}";
        editor.SetRewriteRange(insertionAfter ?? first, insertionAfter is null ? last : insertionAfter.Value + 1);
        editor.Changed += EditorChanged;
        editor.PropertyChanged += EditorPropertyChanged;
        RefreshReview();
    }

    internal async Task SetInstructionAsync(string text, bool retainFailure = false)
    {
        if (!IsOpen) return;
        InvalidateProposal();
        Instruction = text;
        Prepared = null;
        Estimate = null;
        estimateShown = false;
        if (!retainFailure) proposalProblem = "";
        var current = revision;
        try
        {
            if (Connector is null) return;
            var words = Source.Where(word => word.Kind == WordKind.Word).ToArray();
            if (words.Length == 0 || Envelope is null)
            {
                proposalProblem = InsertionAfter is not null ? Refusal(new VoiceLabGeometryException(VoiceLabGeometryErrorCode.InsertionUnsupported))
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
            if (current == revision) proposalProblem = Refusal(exception);
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
        using var run = Editor.LlmRuns.TryAcquire();
        if (run is null) return false;
        var current = revision;
        var input = request;
        sending = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var cancellation = sending;
        IsProposing = true;
        estimateShown = false;
        proposalProblem = "";
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            if (Connector.Group != "local" && (consent is null || !await consent(cancellation.Token))) return false;
            if (!IsOpen || current != revision || cancellation.IsCancellationRequested || !connectorIsCurrent() ||
                !ReferenceEquals(Project, Editor.Project) || !ReferenceEquals(Prepared, action) || !ReferenceEquals(request, input)) return false;
            var result = await service.ProposeAsync(input, Connector.Connector, Connector.Model, service.Approve(action, true), cancellation.Token);
            if (!IsOpen || revision != current) return false;
            NewWords = result.ProposedText;
            RefreshReview();
            return true;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return false; }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (IsOpen && revision == current) proposalProblem = Refusal(exception);
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
                await SetInstructionAsync(Instruction, retainFailure: true);
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
        reviewProblem = "";
        try { Review = RewriteReview.Build(this, prices, synthesisModel); }
        catch (VoiceLabWordDiffException exception)
        {
            Review = null;
            reviewProblem = exception.Code == VoiceLabWordDiffErrorCode.TokenLimit ? VoiceLabPatchBudget.DisabledCopy : Refusal(exception);
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
    internal void SettingsChanged(bool voiceLabEnabled)
    {
        if (!voiceLabEnabled || !connectorIsCurrent()) Dispose();
    }
    private void EditorChanged(object? sender, EventArgs args) => Dispose();
    private void EditorPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (Editor.IsLeaving || Editor.IsReadOnly) Dispose();
        else if (args.PropertyName == nameof(EditorViewModel.Busy)) Changed?.Invoke(this, EventArgs.Empty);
    }
    internal static string Refusal(Exception exception) => exception switch
    {
        VoiceLabGeometryException { Code: VoiceLabGeometryErrorCode.SeamFadeOutsideTake, TakeEdgeIsStart: bool start } =>
            $"This change is too close to the {(start ? "start" : "end")} of the take to blend in. Re-record this sentence instead.",
        VoiceLabGeometryException { Code: VoiceLabGeometryErrorCode.InsertionUnsupported } =>
            "Inserting words isn't available yet. Your edits are saved.",
        VoiceLabGeometryException => "This change can't be placed in this take. Your edits are saved.",
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
        Editor.PropertyChanged -= EditorPropertyChanged;
        Editor.SetRewriteRange(-1, -1);
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
