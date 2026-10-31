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
    private CancellationTokenSource? confirming;
    private IDisposable? proposalLease;
    private bool dispatched;
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
    internal int ProposalRevision { get; private set; }
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
        _ => $"Choose a connector in Settings → {SettingsSections.ProvidersAndKeys}."
    };
    internal event EventHandler? Changed;
    internal RewriteGeneration? Generation { get; private set; }
    internal bool GenerationIsCurrent => IsOpen && ReferenceEquals(Project, Editor.Project) && !IsProposing &&
        !Editor.Busy && !Editor.IsLeaving && !Editor.IsReadOnly && connectorIsCurrent();
    internal void ConfigureGeneration(RewriteGeneration generation)
    {
        if (Generation is { } previous) previous.Changed -= GenerationChanged;
        Generation?.Dispose();
        Generation = generation;
        Editor.SelectionChanged -= GenerationSelectionChanged;
        Editor.SelectionChanged += GenerationSelectionChanged;
        generation.Changed += GenerationChanged;
        Changed?.Invoke(this, EventArgs.Empty);
    }
    private void GenerationChanged(object? sender, EventArgs args) => Changed?.Invoke(this, EventArgs.Empty);
    private void GenerationSelectionChanged(object? sender, EventArgs args)
    {
        if (Generation is { } generation) _ = generation.SelectionChangedAsync($"source:{Editor.SelectionStart}:{Editor.SelectionEnd}");
    }
    internal async Task<VoiceLabTakeInput?> GenerationInputAsync(string recordId, string modelId, uint seed,
        bool providerConsent, Func<CancellationToken, Task<float[]>> source, CancellationToken ct)
    {
        if (!GenerationIsCurrent || Review is not { } review || review.Budget.Copy is not null || review.VoiceHunks.Count == 0) return null;
        // Only new takes read the source audio; a proposal, Apply Cuts and Apply Correction work at any length (RewriteSourceLimit).
        if (RewriteSourceLimit.Refusal(Project) is { } tooLong) throw new RewriteGenerationException(tooLong);
        if (review.VoiceHunks.Count != 1)
            throw new RewriteGenerationException("Rewrite one passage at a time. Keep one changed passage, then generate takes.");
        var hunk = review.VoiceHunks[0];
        if (hunk.Window is not { } window || hunk.PatchText is not { } text)
            throw new RewriteGenerationException(hunk.Refusal ?? "This change can't be placed in this take. Your edits are saved.");
        var version = revision;
        var samples = await source(ct);
        ct.ThrowIfCancellationRequested();
        if (!GenerationIsCurrent || revision != version) throw new OperationCanceledException(ct);
        var silence = VoiceLabWindowPlanner.LendableSilence(Project, Scope, window);
        return new(text, modelId, recordId, Project.Transcript?.Language ?? "en", seed, Project.Media.Source.ContentKey,
            samples, Project.Media.Source.Audio?.SampleRate ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio),
            Transcript, Editor.State?.CutWordIds ?? new HashSet<string>(), window, silence.Incoming, silence.Outgoing, false, providerConsent);
    }

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
        if (!retainFailure && Generation is { } generation) _ = generation.InputsChangedAsync();
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

    internal async Task<bool> ConfirmCostAsync(VoiceLabPreparedAction action, Func<CancellationToken, Task<bool>> confirm)
    {
        if (!CanPropose || confirming is not null || !ReferenceEquals(Prepared, action)) return false;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        confirming = cancellation;
        try
        {
            return await confirm(cancellation.Token).WaitAsync(cancellation.Token) && !cancellation.IsCancellationRequested &&
                CanPropose && ReferenceEquals(Prepared, action);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return false; }
        finally { if (ReferenceEquals(confirming, cancellation)) confirming = null; }
    }

    internal async Task<bool> ProposeAsync(VoiceLabPreparedAction action, bool affirmative)
    {
        if (!CanPropose || !affirmative || !ReferenceEquals(Prepared, action) || request is null || Connector is null) return false;
        using var run = Editor.LlmRuns.TryAcquire();
        if (run is null) return false;
        proposalLease = run;
        dispatched = false;
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
            if (Connector.Group != "local" && (consent is null || !await consent(cancellation.Token).WaitAsync(cancellation.Token))) return false;
            if (!IsOpen || current != revision || cancellation.IsCancellationRequested || !connectorIsCurrent() ||
                !ReferenceEquals(Project, Editor.Project) || !ReferenceEquals(Prepared, action) || !ReferenceEquals(request, input)) return false;
            dispatched = true;
            var result = await service.ProposeAsync(input, Connector.Connector, Connector.Model, service.Approve(action, true), cancellation.Token);
            if (!IsOpen || revision != current) return false;
            NewWords = result.ProposedText;
            RefreshReview();
            ProposalRevision++;
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
            Interlocked.Exchange(ref proposalLease, null)?.Dispose();
            if (ReferenceEquals(sending, cancellation)) sending = null;
            cancellation.Dispose();
            IsProposing = false;
            if (IsOpen && Generation is { } generation) _ = generation.InputsChangedAsync();
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
        if (Generation is { } generation) _ = generation.InputsChangedAsync();
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
        return Editor.ApplyBatch(LocalOperations());
    }

    private IReadOnlyList<EditOperation> LocalOperations()
    {
        List<EditOperation> operations = [];
        foreach (var hunk in Review?.Diff.Hunks ?? [])
        {
            if (hunk.Kind == VoiceLabDiffHunkKind.Cut) operations.Add(new EditOperation.SetWordCuts(hunk.SourceWordIds, true));
            else if (hunk.Kind == VoiceLabDiffHunkKind.TextOnly)
                for (var index = 0; index < hunk.SourceWordIds.Count; index++)
                    operations.Add(new EditOperation.Correct(hunk.SourceWordIds[index], hunk.CorrectedTexts[index]));
        }
        return operations;
    }
    internal Task<bool> ApplyTakeAsync() => GenerationIsCurrent && Generation is { } generation
        ? generation.AcceptAsync(Editor, LocalOperations()) : Task.FromResult(false);

    private void InvalidateProposal() { revision++; sending?.Cancel(); confirming?.Cancel(); }
    internal void SettingsChanged(bool voiceLabEnabled)
    {
        if (!voiceLabEnabled || !connectorIsCurrent()) Dispose();
        else if (Generation is { IsRequestingConsent: false } generation) _ = generation.InputsChangedAsync();
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
        VoiceLabGeometryException { Code: VoiceLabGeometryErrorCode.RoomToneUnavailable } =>
            "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in. Clean audio is not available in this build. Re-record this sentence instead.",
        VoiceLabGeometryException { Code: VoiceLabGeometryErrorCode.NoVoicedAudio } or
            VoiceLabAudioMathException { Code: VoiceLabAudioMathErrorCode.NoVoicedAudio } =>
            "There isn't enough timed speech to estimate this change. Your edits are saved.",
        RewriteGenerationException problem => problem.Message,
        VoiceLabGeometryException => "This change can't be placed in this take. Your edits are saved.",
        VoiceLabLengthBudgetException => "There isn't enough timed speech to estimate this change. Your edits are saved.",
        _ => UiError.Message(exception, "Rewrite")
    };

    public void Dispose()
    {
        if (!IsOpen) return;
        IsOpen = false;
        Editor.SelectionChanged -= GenerationSelectionChanged;
        if (Generation is { } generation) { generation.Changed -= GenerationChanged; generation.Dispose(); }
        InvalidateProposal();
        lifetime.Cancel();
        if (!dispatched) Interlocked.Exchange(ref proposalLease, null)?.Dispose();
        lifetime.Dispose();
        Editor.Changed -= EditorChanged;
        Editor.PropertyChanged -= EditorPropertyChanged;
        Editor.SetRewriteRange(-1, -1);
        Changed?.Invoke(this, EventArgs.Empty);
    }
}

internal sealed class RewriteAnnouncements
{
    private bool proposing;
    private int proposalRevision;
    private string problem = "";

    internal IReadOnlyList<string> Next(bool busy, int revision, string refusal, string summary)
    {
        var messages = new List<string>();
        if (busy && !proposing) messages.Add("AI request in progress");
        if (revision != proposalRevision) messages.Add("New words ready: " + summary);
        if (refusal.Length > 0 && refusal != problem) messages.Add(refusal);
        proposing = busy;
        proposalRevision = revision;
        problem = refusal;
        return messages;
    }
}
