using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record RewriteConnector(ILlmConnector Connector, string Model, string Name, string Group, string Plan);

/// <summary>What a take run reads from the source track (voice-lab.md §8.7–8.9): a track of <paramref name="Frames"/> frames at
/// <paramref name="SampleRate"/>, the window, its §8.9.2 lendable silences, which the fit can borrow, and the transcript the
/// room-tone search reads. <see cref="VoiceLabSourceAudio.RewriteSourceAsync"/> answers it at any length.</summary>
internal sealed record RewriteSourceRequest(long Frames, int SampleRate, VoiceLabWindow Window, double? IncomingSilence, double? OutgoingSilence,
    IReadOnlyList<TimedWord> Items)
{
    /// <summary>A reader that hands each request's fields to <paramref name="decode"/> in their places, for the media at
    /// <paramref name="source"/> when the request is read. The Editor passes <see cref="VoiceLabSourceAudio.RewriteSourceAsync"/>.</summary>
    internal static RewriteSourceReader Reader(Func<string> source, RewriteSourceDecoder decode) => (request, ct) =>
        decode(source(), request.Frames, request.SampleRate, request.Window, request.IncomingSilence, request.OutgoingSilence, request.Items, ct);
}

/// <summary>Reads a <see cref="RewriteSourceRequest"/>: the regions a take run reads, at absolute frames, and the whole track's envelope.</summary>
internal delegate Task<(VoiceLabSourceExcerpt Excerpt, AudioEnvelope Envelope)> RewriteSourceReader(RewriteSourceRequest request, CancellationToken ct);

/// <summary>The parameters of <see cref="VoiceLabSourceAudio.RewriteSourceAsync"/>, by name and in order.</summary>
internal delegate Task<(VoiceLabSourceExcerpt Excerpt, AudioEnvelope Envelope)> RewriteSourceDecoder(string source, long frames, int sampleRate,
    VoiceLabWindow window, double? incomingSilence, double? outgoingSilence, IReadOnlyList<TimedWord> items, CancellationToken ct);

internal sealed partial class RewriteSession : IDisposable
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
    private string? synthesisModel;
    private Func<CancellationToken, Task<bool>>? consent;
    private readonly Func<bool> connectorIsCurrent;
    private Func<bool> contextIsCurrent = () => true;
    private bool requireLocalConsent;
    private CliSignIn? preparedSignIn;
    private bool BillingCurrent => Connector?.Group != "cli" || preparedSignIn is not null &&
        preparedSignIn == SignIn((Connector.Connector as LlmConnector)?.CliDetection);
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
    internal bool CanPropose => IsOpen && !IsProposing && !Editor.Busy && !Editor.IsLeaving && !Editor.IsReadOnly &&
        ReferenceEquals(Project, Editor.Project) && connectorIsCurrent() && contextIsCurrent() && BillingCurrent && estimateShown && Prepared is not null;
    internal void ConfigureInlineConsent(Func<CancellationToken, Task<bool>> authorize, Func<bool>? contextCurrent = null, bool localConsent = false)
    { consent = authorize; contextIsCurrent = contextCurrent ?? (() => true); requireLocalConsent = localConsent; }
    internal string Header { get; }
    internal RewriteReview? Review { get; private set; }
    internal string? LocalAction => IncludedHunks.Count > 0 && IncludedHunks.All(hunk => hunk.Kind != VoiceLabDiffHunkKind.Voice)
        ? IncludedHunks.Any(hunk => hunk.Kind == VoiceLabDiffHunkKind.TextOnly) ? "Apply Correction" : "Apply Cuts" : null;
    internal string SendLine => Connector?.Group switch
    {
        "apiKey" => $"Sends these {Source.Count(word => word.Kind == WordKind.Word)} words to {Connector.Name} with your key.",
        "cli" => $"Sends these {Source.Count(word => word.Kind == WordKind.Word)} words through {Connector.Name} with your sign-in. " +
            (SignIn((Connector.Connector as LlmConnector)?.CliDetection) switch
            {
                CliSignIn.Plan => $"Counts toward your {Connector.Plan}.",
                CliSignIn.ApiKey => $"Billed to the API key {Connector.Name} is signed in with.",
                _ => "Check the connector's sign-in method before sending."
            }),
        "local" => "Runs on this PC. Nothing leaves it.",
        _ => $"Choose a connector in Settings → {SettingsSections.ProvidersAndKeys}."
    };
    internal event EventHandler? Changed;
    internal RewriteGeneration? Generation { get; private set; }
    /// <summary>voice-lab.md §6.5.2: the speaker check is calibrated, but not for this project's language, so no voice made from here
    /// could be listed in it (<see cref="VoiceLabSession.VoicesUnavailable"/>). With no voice listed, the voice row explains instead
    /// of offering Create Your Voice… or voice discovery.</summary>
    internal bool VoicesUnavailable { get; }
    internal bool GenerationIsCurrent => IsOpen && ReferenceEquals(Project, Editor.Project) && !IsProposing &&
        !Editor.Busy && !Editor.IsLeaving && !Editor.IsReadOnly && connectorIsCurrent() && contextIsCurrent();
    internal void ConfigureGeneration(RewriteGeneration generation)
    {
        generationFactory = null;
        RetireGenerationWindows();
        generationWindows.Add(generation);
        ActiveWindow = 0;
        Generation = generation;
        Editor.SelectionChanged -= GenerationSelectionChanged;
        Editor.SelectionChanged += GenerationSelectionChanged;
        generation.Changed += GenerationChanged;
        Changed?.Invoke(this, EventArgs.Empty);
    }
    private void GenerationChanged(object? sender, EventArgs args)
    {
        if (ReferenceEquals(sender, Generation) && Generation?.ModelId is { } model && synthesisModel != model)
        {
            synthesisModel = model;
            RefreshReview(preserveGenerations: true);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }
    private void GenerationSelectionChanged(object? sender, EventArgs args)
    {
        foreach (var generation in generationWindows.ToArray())
            _ = generation.SelectionChangedAsync($"source:{Editor.SelectionStart}:{Editor.SelectionEnd}");
    }
    /// <summary>The take run's input for one reviewed voice window. <paramref name="source"/> reads only the regions the run
    /// needs (<see cref="RewriteSourceRequest"/>), so a source of any length works, as on the Mac.</summary>
    internal async Task<VoiceLabTakeInput?> GenerationInputAsync(string recordId, string modelId, uint seed, bool providerConsent,
        RewriteSourceReader source, CancellationToken ct, int windowIndex = 0)
    {
        if (!GenerationIsCurrent || Review is not { } review || review.Budget.Copy is not null || PricedVoiceHunks.Count == 0) return null;
        if (PricedVoiceHunks.Count > VoiceLabTakeBatch.MaximumWindows)
            throw new RewriteGenerationException("Keep fewer changed passages before generating takes. Your edits are saved.");
        if (windowIndex < 0 || windowIndex >= PricedVoiceHunks.Count) return null;
        var hunk = PricedVoiceHunks[windowIndex];
        if (hunk.Window is not { } window || hunk.PatchText is not { } text)
            throw new RewriteGenerationException(hunk.Refusal ?? "This change can't be placed in this take. Your edits are saved.");
        var combined = Editor.ProjectWithLocalOperations(Project, LocalOperations());
        try { VoiceLabRenderContract.ValidatePlacement(combined, Scope, window); }
        catch (VoiceLabProjectException) { throw new RewriteGenerationException("This change can't blend beside the proposed cuts. Keep more of the surrounding speech or re-record this sentence. Your edits are saved."); }
        var rate = Project.Media.Source.Audio?.SampleRate ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var frames = checked((long)Math.Floor(Project.Media.Source.DurationSeconds * rate + 0.5));
        // The fit can borrow this silence, so the decoded source must reach past it.
        var silence = VoiceLabWindowPlanner.LendableSilence(Project, Scope, window);
        var version = revision;
        var read = await source(new(frames, rate, window, silence.Incoming, silence.Outgoing, Transcript), ct);
        ct.ThrowIfCancellationRequested();
        if (!GenerationIsCurrent || revision != version) throw new OperationCanceledException(ct);
        var pauseWords = Transcript;
        if (Scope.ClipId is { } clipId && Project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId) is { } clip)
        {
            var first = Transcript.ToList().FindIndex(word => word.Id == clip.StartWordId);
            var last = Transcript.ToList().FindIndex(word => word.Id == clip.EndWordId);
            if (first >= 0 && last >= first) pauseWords = Transcript.Skip(first).Take(last - first + 1).ToArray();
        }
        return new VoiceLabTakeInput(text, modelId, recordId, Project.Transcript?.Language ?? "en", seed, Project.Media.Source.ContentKey,
            read.Excerpt, read.Envelope, rate, Transcript, Editor.State?.CutWordIds ?? new HashSet<string>(), window,
            silence.Incoming, silence.Outgoing, false, providerConsent,
            RewriteReview.MeasureTiming(this, combined, text, window, modelId).Pace)
            { PauseProfile = VoiceLabPauseProfile.Measure(pauseWords.Where(word => !Project.Edits.CutWordIds.Contains(word.Id)).ToArray(), read.Envelope, 0, double.MaxValue) };
    }

    internal RewriteSession(EditorViewModel editor, int first, int last, AudioEnvelope? envelope, RewriteConnector? connector,
        int? insertionAfter = null, VoiceLabPriceCatalog? prices = null, string? synthesisModel = null,
        Func<CancellationToken, Task<bool>>? consent = null, Func<bool>? connectorIsCurrent = null, Func<string, bool>? speakerCalibrated = null,
        RewriteScope? scope = null)
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
        requestedScope = scope;
        if (scope is not null)
        {
            scopePlan = ScopeRewritePlan.Make(Project, scope, "Fix mistakes", Project.Transcript?.Language ?? "en", envelope);
            Source = scopePlan.Lines.SelectMany(line => line.Items).ToArray();
        }
        VoicesUnavailable = VoiceLabSession.VoicesUnavailable(Project.Transcript?.Language, speakerCalibrated ?? VoiceLabSession.SpeakerCalibrated);
        NewWords = string.Join(" ", Source.Where(word => word.Kind == WordKind.Word).Select(word => word.Text));
        var start = insertionAfter is { } after ? Transcript[after].End : Source.FirstOrDefault()?.Start ?? 0;
        Header = $"{Source.Count(word => word.Kind == WordKind.Word)} words at {EditorViewModel.Timecode(start)}";
        editor.SetRewriteRange(insertionAfter ?? first, insertionAfter is null ? last : insertionAfter.Value + 1);
        editor.Changed += EditorChanged;
        editor.PropertyChanged += EditorPropertyChanged;
        RefreshReview();
    }

    internal async Task SetInstructionAsync(string text, bool retainFailure = false, IReadOnlyList<VoiceRewriteTimingFeedback>? shorterPhrases = null)
    {
        if (!IsOpen) return;
        InvalidateProposal();
        Instruction = text;
        if (!retainFailure) InvalidateGenerationInputs();
        Prepared = null;
        Estimate = null;
        estimateShown = false;
        if (!retainFailure) proposalProblem = "";
        var current = revision;
        try
        {
            if (Connector is null) return;
            preparedSignIn = SignIn((Connector.Connector as LlmConnector)?.CliDetection);
            if (Connector.Group == "cli" && preparedSignIn is null)
            {
                proposalProblem = "Check the connector's sign-in method before sending a request.";
                return;
            }
            var words = Source.Where(word => word.Kind == WordKind.Word).ToArray();
            if (words.Length == 0 || InsertionAfter is not null)
            {
                proposalProblem = InsertionAfter is not null ? Refusal(new VoiceLabGeometryException(VoiceLabGeometryErrorCode.InsertionUnsupported))
                    : "Find the original video before rewriting speech. Your edits are saved.";
                return;
            }
            var targetSeconds = Math.Max(0.01, words[^1].End - words[0].Start);
            if (requestedScope is not null)
            {
                scopePlan = ScopeRewritePlan.Make(Project, requestedScope, string.IsNullOrWhiteSpace(text) ? "Fix mistakes" : text,
                    Project.Transcript?.Language ?? "en", Envelope);
                scopePlan = scopePlan with { Request = scopePlan.Request with { ShorterPhrases = shorterPhrases ?? [] } };
                var scopedAction = await patchService.PrepareAsync(scopePlan.Request, Connector.Connector, Connector.Model, lifetime.Token);
                if (!IsOpen || current != revision) return;
                Prepared = scopedAction;
                Estimate = VoiceLabCostPresentation.KindForLlmSend(Connector.Connector.Id, preparedSignIn,
                    Connector.Connector.Id is ConnectorId.ClaudeCode ? "Anthropic" : Connector.Connector.Id is ConnectorId.Codex ? "OpenAI" : Connector.Name);
                return;
            }
            var input = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, words, text,
                Editor.State?.Transcript.Language ?? "en", targetSeconds, 1, 5000) { ShorterPhrases = shorterPhrases ?? [] };
            var action = await service.PrepareAsync(input, Connector.Connector, Connector.Model, lifetime.Token);
            if (!IsOpen || current != revision) return;
            request = input;
            Prepared = action;
            Estimate = VoiceLabCostPresentation.KindForLlmSend(Connector.Connector.Id,
                preparedSignIn, Connector.Connector.Id switch
                { ConnectorId.ClaudeCode => "Anthropic", ConnectorId.Codex => "OpenAI", _ => Connector.Name });
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (current == revision) proposalProblem = Refusal(exception);
        }
        finally { if (IsOpen && current == revision) Changed?.Invoke(this, EventArgs.Empty); }
    }

    internal static CliSignIn? SignIn(CliDetectionInfo? detection)
    {
        if (detection?.UsesApiKey == true) return CliSignIn.ApiKey;
        return detection?.AuthMethod?.ToLowerInvariant().Replace('-', '_').Replace('.', '_') is
            "oauth" or "oauth_token" or "claudeai" or "claude_ai" or "chatgpt" ? CliSignIn.Plan : null;
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
        if (!CanPropose || !affirmative || !ReferenceEquals(Prepared, action) || request is null && scopePlan is null || Connector is null) return false;
        using var run = Editor.LlmRuns.TryAcquire();
        if (run is null) return false;
        proposalLease = run;
        dispatched = false;
        var current = revision;
        var input = request;
        var scopedInput = scopePlan;
        sending = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var cancellation = sending;
        IsProposing = true;
        estimateShown = false;
        proposalProblem = "";
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            if ((Connector.Group != "local" || requireLocalConsent) && (consent is null || !await consent(cancellation.Token).WaitAsync(cancellation.Token))) return false;
            if (!IsOpen || current != revision || cancellation.IsCancellationRequested || !connectorIsCurrent() || !contextIsCurrent() || !BillingCurrent ||
                !ReferenceEquals(Project, Editor.Project) || !ReferenceEquals(Prepared, action) || !ReferenceEquals(request, input) || !ReferenceEquals(scopePlan, scopedInput)) return false;
            dispatched = true;
            string resultText;
            if (scopedInput is not null)
            {
                var patch = await patchService.ProposeAsync(scopedInput.Request, Connector.Connector, Connector.Model,
                    patchService.Approve(action, true), cancellation.Token);
                if (!IsOpen || revision != current) return false;
                scopeHunks = ScopeRewriteDiff.Hunks(scopedInput, patch);
                var edits = patch.Edits.ToDictionary(edit => edit.Line, StringComparer.Ordinal);
                resultText = string.Join(" ", scopedInput.Lines.Select(line => edits.TryGetValue(line.Label, out var edit)
                    ? edit.Text : string.Join(" ", line.Items.Where(word => word.Kind == WordKind.Word).Select(word => word.Text))));
            }
            else
            {
                var result = await service.ProposeAsync(input!, Connector.Connector, Connector.Model, service.Approve(action, true), cancellation.Token);
                resultText = result.ProposedText;
            }
            if (!IsOpen || revision != current) return false;
            changeStates.Clear();
            priceOverrides.Clear();
            NewWords = resultText;
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
            if (IsOpen) InvalidateGenerationInputs();
            if (IsOpen)
            {
                Prepared = null;
                Changed?.Invoke(this, EventArgs.Empty);
                await SetInstructionAsync(Instruction, retainFailure: true,
                    shorterPhrases: scopedInput?.Request.ShorterPhrases ?? input?.ShorterPhrases);
            }
        }
    }

    internal void Edit(string text)
    {
        if (!IsOpen) return;
        InvalidateProposal();
        scopeHunks = null;
        changeStates.Clear();
        priceOverrides.Clear();
        NewWords = text;
        RefreshReview();
        InvalidateGenerationInputs();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void RefreshReview(bool preserveGenerations = false)
    {
        if (!preserveGenerations) { sentenceReplacements.Clear(); SentenceReview = null; SentenceProblem = ""; }
        reviewProblem = "";
        try { Review = RewriteReview.Build(this, prices, synthesisModel ?? Generation?.ModelId); }
        catch (VoiceLabWordDiffException exception)
        {
            Review = null;
            reviewProblem = exception.Code == VoiceLabWordDiffErrorCode.TokenLimit ? VoiceLabPatchBudget.DisabledCopy : Refusal(exception);
        }
        ReconcileGenerationWindows(preserveGenerations);
    }

    internal bool ApplyLocalChanges()
    {
        if (!IsOpen || LocalAction is null || !ReferenceEquals(Project, Editor.Project) || Editor.Busy || Editor.IsReadOnly || Editor.IsLeaving) return false;
        return Editor.ApplyBatch(LocalOperations());
    }

    private IReadOnlyList<EditOperation> LocalOperations()
    {
        List<EditOperation> operations = [];
        foreach (var hunk in IncludedHunks)
        {
            if (hunk.Kind == VoiceLabDiffHunkKind.Cut) operations.Add(new EditOperation.SetWordCuts(hunk.SourceWordIds, true));
            else if (hunk.Kind == VoiceLabDiffHunkKind.TextOnly)
                for (var index = 0; index < hunk.SourceWordIds.Count; index++)
                    operations.Add(new EditOperation.Correct(hunk.SourceWordIds[index], hunk.CorrectedTexts[index]));
        }
        return operations;
    }
    internal Task<bool> ApplyTakeAsync() => ApplyReviewedWindowsAsync();

    private void InvalidateProposal() { revision++; sending?.Cancel(); confirming?.Cancel(); }
    internal void SettingsChanged(bool voiceLabEnabled)
    {
        if (!connectorIsCurrent() || !contextIsCurrent()) Dispose();
        else if (!voiceLabEnabled && Generation is not null)
        {
            generationFactory = null;
            RetireGenerationWindows();
            Changed?.Invoke(this, EventArgs.Empty);
        }
        else foreach (var generation in generationWindows.Where(window => !window.IsRequestingConsent).ToArray()) _ = generation.InputsChangedAsync();
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
        VoiceLabSourceAudioException source => source.Message + " Your edits are saved.",
        VoiceLabGeometryException => "This change can't be placed in this take. Your edits are saved.",
        VoiceLabLengthBudgetException => "There isn't enough timed speech to estimate this change. Your edits are saved.",
        _ => UiError.Message(exception, "Rewrite")
    };

    public void Dispose()
    {
        if (!IsOpen) return;
        IsOpen = false;
        Editor.SelectionChanged -= GenerationSelectionChanged;
        RetireGenerationWindows();
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
