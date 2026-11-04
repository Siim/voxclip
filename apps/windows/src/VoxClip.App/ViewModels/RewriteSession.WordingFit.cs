using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>The measured-length rewording offered after a selected v4 take cannot fit its slot. It is review-only: a new take
/// needs the priced Make Take click.</summary>
internal sealed class RewriteMeasuredWording(int window, Guid take, int number, double measuredSeconds, double slotSeconds)
{
    internal int Window { get; } = window;
    internal Guid Take { get; } = take;
    internal int Number { get; } = number;
    internal double MeasuredSeconds { get; } = measuredSeconds;
    internal double SlotSeconds { get; } = slotSeconds;
    internal bool TooLong => MeasuredSeconds > SlotSeconds;
    /// <summary>The automatic fixes reword from the closest take even when it isn't selected (it may have failed a check).</summary>
    internal bool Unselected { get; init; }
    internal string? Text { get; set; }
    internal bool KeepOriginal { get; set; }
    internal bool Preparing { get; set; } = true;
    internal bool AwaitingApproval { get; set; }
    internal string Problem { get; set; } = "";
    internal string Heading => $"Take {Number} · {EditingFormat.ToFixed1(MeasuredSeconds)} s · slot {EditingFormat.ToFixed1(SlotSeconds)} s · too {(TooLong ? "long" : "short")}";
}

internal sealed partial class RewriteSession
{
    internal const string FitBusy = "Another AI request on this project is still running.";
    private readonly VoiceLabWordingFitService fitService = new(new LlmCatalog());
    private readonly Dictionary<string, IReadOnlyList<VoiceLabRateSample>> sessionRates = new(StringComparer.Ordinal);
    private readonly HashSet<Guid> calibratedTakes = [];
    private readonly HashSet<Guid> measuredTakes = [];
    private readonly Dictionary<int, string> measuredWording = [];
    private readonly Dictionary<int, double> fitInitialEstimates = [];
    private readonly HashSet<int> fitFrozen = [];
    private readonly HashSet<int> fitKept = [];
    private CancellationTokenSource? fitting;
    private CancellationTokenSource? measuring;
    private IDisposable? fitLease;
    private IDisposable? measuredLease;
    private int fitToken;
    private int measuredToken;

    internal bool WordingFitRunning { get; private set; }
    internal bool WordingFitAwaitingApproval { get; private set; }
    internal bool WordingFitCompleted { get; private set; }
    internal bool WordingFitStopped { get; private set; }
    internal int WordingFitRound { get; private set; }
    internal IReadOnlyList<VoiceLabFitPhrase> WordingFitPhrases { get; private set; } = [];
    internal string WordingFitProblem { get; private set; } = "";
    internal IReadOnlySet<int> WordingFitKept => fitKept;
    internal Task WordingFitWork { get; private set; } = Task.CompletedTask;
    internal Task MeasuredWork { get; private set; } = Task.CompletedTask;
    internal RewriteMeasuredWording? MeasuredWording { get; private set; }
    /// <summary>While rounds run or wait for their approval the proposal is visible but read-only, and nothing is priced.</summary>
    internal bool WordingIsLocked => WordingFitRunning || WordingFitAwaitingApproval;
    /// <summary>Billed connectors (an API key, or a CLI signed in with one) need one inline approval for this reply's rounds.</summary>
    internal bool FitAsksFirst => Connector is { } connector && VoiceLabCostPresentation.KindForLlmSend(connector.Connector.Id,
        SignIn((connector.Connector as LlmConnector)?.CliDetection), connector.Name).Kind == VoiceLabCostPresentationKind.Confirm;
    internal string FitApprovalLine => "Fit wording automatically · up to 3 requests · price unavailable · billed to your key";
    internal string FitRunningHeadline => $"Fitting wording to the video · round {WordingFitRound} of {VoiceLabWordingFit.MaximumRounds}";
    internal string FitNote => FitAsksFirst ? $"Uses {Connector?.Name}, billed to your key. Making a take still needs your paid click."
        : Connector?.Group == "cli" ? $"Uses {Connector.Name} on your plan; nothing is paid until Get Price."
        : $"Uses {Connector?.Name}; nothing is paid until Get Price.";
    internal string FitFittedFooter => $"{PricedVoiceHunks.Count} phrases fit · {fitKept.Count} kept as recorded";
    internal static string FitPhraseLine(VoiceLabFitPhrase phrase) =>
        $"Phrase {phrase.Ordinal} · ≈ {EditingFormat.ToFixed1(phrase.EstimateSeconds)} s, slot {EditingFormat.ToFixed1(phrase.SlotSeconds)} s · asking for about " +
        $"{VoiceLabWordingFit.DifferenceWords(phrase)} {(phrase.Direction == "longer" ? "more" : "fewer")} words";
    /// <summary>The row note after the rounds: reworded with before/after estimates, or kept as recorded.</summary>
    internal string? FitRowNote(int ordinal)
    {
        if (VoicedOrdinals.Contains(ordinal)) return null;
        if (heldBack.Contains(ordinal) && priceOverrides.Contains(ordinal)) return HeldBackNote(ordinal);
        if (fitKept.Contains(ordinal))
            return $"kept your original words · {EditingFormat.ToFixed1(fitInitialSlots.GetValueOrDefault(ordinal))} s is too short to re-voice";
        if (!fitInitialEstimates.TryGetValue(ordinal, out var before) || Review?.VoiceHunks.FirstOrDefault(hunk => hunk.Ordinals.SequenceEqual([ordinal]))?.Fit is not { Fits: true } fit)
            return null;
        return $"reworded to fit · was ≈ {EditingFormat.ToFixed1(before)} s, now ≈ {EditingFormat.ToFixed1(fit.EstimateSeconds)} s · slot {EditingFormat.ToFixed1(fit.SlotSeconds)} s";
    }
    private readonly Dictionary<int, double> fitInitialSlots = [];
    private readonly HashSet<int> heldBack = [];
    internal static string HeldBackNote(int ordinal) => $"Change {ordinal} is priced as written; once its take is measured, Rewrite rewords it to fit.";
    /// <summary>Mac <c>priceHeldBackChanges</c>: when the automatic fit ends (not after Stop, not with paid takes) with a change still
    /// too long, it is priced as written, so Get Price voices it and the automatic fixes reword it from its measured take.</summary>
    private void PriceHeldBackChanges()
    {
        if (WordingFitStopped || HasPaidTakes || Review is null) return;
        var held = BlockedVoiceHunks.Where(hunk => hunk.Fit is { TooLong: true }).SelectMany(hunk => hunk.Ordinals).ToArray();
        if (held.Length == 0) return;
        heldBack.UnionWith(held);
        priceOverrides.UnionWith(held);
        RefreshReview(preserveGenerations: true);
    }
    private string Language => Project.Transcript?.Language ?? "en";

    /// <summary>This project's (and this session's measured) speaking-rate samples for a model.</summary>
    internal IReadOnlyList<VoiceLabRateSample> RateSamples(string model) => sessionRates.TryGetValue(model, out var measured) ? measured :
        Project.VoiceLab.SpeakingRateSamples?.GetValueOrDefault(model) ?? [];
    /// <summary>The samples to save with accepted takes, or null when nothing was measured here.</summary>
    internal IReadOnlyDictionary<string, IReadOnlyList<VoiceLabRateSample>>? CalibratedRates()
    {
        if (sessionRates.Count == 0) return null;
        var merged = new Dictionary<string, IReadOnlyList<VoiceLabRateSample>>(Project.VoiceLab.SpeakingRateSamples ?? new Dictionary<string, IReadOnlyList<VoiceLabRateSample>>(), StringComparer.Ordinal);
        foreach (var (model, samples) in sessionRates) merged[model] = samples;
        return merged;
    }

    /// <summary>Single-change voice phrases that can be reworded; a merged window keeps today's recovery row.</summary>
    private IReadOnlyList<int> FitCandidates() => Review?.VoiceHunks.Where(hunk => hunk.Ordinals.Count == 1 && hunk.Fit is not null &&
        hunk.Hunk.SourceWordIds.Count > 0).Select(hunk => hunk.Ordinals[0]).ToArray() ?? [];
    private IReadOnlyList<int> BlockedFitOrdinals() => BlockedVoiceHunks.Where(hunk => hunk.Ordinals.Count == 1 && hunk.Hunk.SourceWordIds.Count > 0)
        .Select(hunk => hunk.Ordinals[0]).ToArray();

    private (double Rate, double WordsPerSecond, IReadOnlyList<Core.Domain.Shared.TimedWord> Spoken) SpeakingRate()
    {
        var spoken = RewriteReview.TimingWords(this, Project);
        var words = spoken.Where(word => word.Kind == Core.Domain.Shared.WordKind.Word).ToArray();
        var characters = words.Sum(word => VoiceLabTextLength.Length(word.Text));
        var rate = VoiceLabRewriteFit.SpeakingRate(spoken);
        if (characters <= 0) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.RateUnavailable);
        return (rate, rate * words.Length / characters, spoken);
    }

    /// <summary>One fit line per ordinal: original and current words, estimate, slot, direction and the shared word target.</summary>
    internal IReadOnlyList<VoiceLabFitPhrase> FitPhrases(IReadOnlyList<int> ordinals)
    {
        if (Review is not { } review) return [];
        var (rate, wordsPerSecond, _) = SpeakingRate();
        var samples = RateSamples(synthesisModel);
        var multiplier = VoiceLabWordingFit.Multiplier(samples);
        return ordinals.Select(ordinal =>
        {
            if (review.VoiceHunks.FirstOrDefault(hunk => hunk.Ordinals.SequenceEqual([ordinal])) is not { Fit: { } fit, Window: { } window, PatchText: { } patch } phrase)
                throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.InvalidInput);
            var allowance = VoiceLabAudioTags.Allowance(phrase.RequestAudioTags, patch, synthesisModel);
            var baseline = VoiceLabRewriteFit.Estimate(patch, rate);
            var speech = VoiceLabTextLength.Length(patch) / (rate * VoiceLabRewriteFit.ProviderSpeechRateMultiplier);
            var lower = fit.MinimumSeconds ?? fit.SlotSeconds;
            var upper = Math.Max(lower, fit.MaximumSeconds ?? fit.SlotSeconds);
            var target = VoiceLabWordingFit.WordTarget(wordsPerSecond, multiplier, lower, upper, Math.Max(0, baseline - speech) * multiplier + allowance,
                window.LeftBridgeWordIds.Count + window.RightBridgeWordIds.Count);
            var original = string.Join(" ", phrase.Hunk.SourceWordIds.Select(id => Transcript.First(word => word.Id == id).Text));
            return new VoiceLabFitPhrase(ordinal, original, string.Join(" ", phrase.Hunk.NewTokens), fit.EstimateSeconds, fit.SlotSeconds,
                fit.EstimateSeconds > (fit.MaximumSeconds ?? fit.SlotSeconds) ? "shorter" : "longer", target, Calibrated: samples.Count >= 2);
        }).ToArray();
    }

    private void ResetWordingFit()
    {
        WordingFitRound = 0; WordingFitCompleted = false; WordingFitStopped = false; WordingFitProblem = "";
        WordingFitPhrases = []; fitInitialEstimates.Clear(); fitInitialSlots.Clear(); fitFrozen.Clear(); fitKept.Clear(); heldBack.Clear();
    }

    /// <summary>After a reply lands: fit every phrase outside its slot, automatically for a no-extra-cost connector and after one
    /// inline Fit approval otherwise. Paid takes, or nothing to fit, leave the review as it is.</summary>
    internal Task BeginAutomaticWordingFitAsync()
    {
        if (!IsOpen || IsProposing || Connector is not { } connector || HasPaidTakes || Review is null) return Task.CompletedTask;
        var blocked = BlockedFitOrdinals();
        if (blocked.Count == 0) return Task.CompletedTask;
        StopWordingFit(markStopped: false);
        ResetWordingFit();
        try
        {
            WordingFitPhrases = FitPhrases(blocked);
            foreach (var phrase in WordingFitPhrases) { fitInitialEstimates[phrase.Ordinal] = phrase.EstimateSeconds; fitInitialSlots[phrase.Ordinal] = phrase.SlotSeconds; }
            _ = fitService.Request(WordingFitPhrases, connector.Connector.Id, Language);
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            WordingFitProblem = Refusal(exception);
            Changed?.Invoke(this, EventArgs.Empty);
            return Task.CompletedTask;
        }
        if (FitAsksFirst)
        {
            WordingFitAwaitingApproval = true;
            Changed?.Invoke(this, EventArgs.Empty);
            return Task.CompletedTask;
        }
        return FitWordingAsync(true);
    }

    /// <summary>Runs up to three rounds, one request each, for the phrases still outside their slots. Fitting phrases are frozen and
    /// never re-sent; Stop, an edit, Ask again or close end the rounds and keep the latest words.</summary>
    internal Task FitWordingAsync(bool approved)
    {
        if (!approved || !IsOpen || WordingFitRunning || Connector is not { } connector) return Task.CompletedTask;
        WordingFitAwaitingApproval = false;
        var lease = Editor.LlmRuns.TryAcquire();
        if (lease is null)
        {
            WordingFitAwaitingApproval = false; WordingFitProblem = FitBusy;
            Changed?.Invoke(this, EventArgs.Empty);
            return Task.CompletedTask;
        }
        fitLease = lease;
        WordingFitAwaitingApproval = false; WordingFitRunning = true; WordingFitStopped = false; WordingFitProblem = "";
        var token = ++fitToken;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        fitting = cancellation;
        Changed?.Invoke(this, EventArgs.Empty);
        return WordingFitWork = RoundsAsync(connector, lease, token, cancellation);
    }

    private async Task RoundsAsync(RewriteConnector connector, IDisposable lease, int token, CancellationTokenSource cancellation)
    {
        try
        {
            while (WordingFitRound < VoiceLabWordingFit.MaximumRounds)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                if (!IsOpen || token != fitToken || Review is null) return;
                var candidates = FitCandidates();
                var blocked = BlockedFitOrdinals().ToHashSet();
                fitFrozen.UnionWith(candidates.Where(ordinal => !blocked.Contains(ordinal)));
                var ordinals = VoiceLabWordingFit.NextOrdinals(WordingFitRound, candidates, fitFrozen, fitKept, WordingFitStopped);
                if (ordinals.Count == 0) break;
                WordingFitPhrases = FitPhrases(ordinals);
                WordingFitRound++;
                Changed?.Invoke(this, EventArgs.Empty);
                var action = fitService.Prepare(WordingFitPhrases, connector.Connector.Id, connector.Model, Language);
                var updates = await fitService.ProposeAsync(WordingFitPhrases, connector.Connector, connector.Model, Language,
                    fitService.Approve(action, true), cancellation.Token);
                if (!IsOpen || token != fitToken || cancellation.IsCancellationRequested) return;
                ApplyWordingFit(updates);
            }
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (IsOpen && token == fitToken && !cancellation.IsCancellationRequested) WordingFitProblem = Refusal(exception);
        }
        finally
        {
            lease.Dispose();
            if (token == fitToken)
            {
                WordingFitRunning = false; WordingFitCompleted = true; fitting = null; fitLease = null;
                if (IsOpen && !cancellation.IsCancellationRequested) PriceHeldBackChanges();
                if (IsOpen) { InvalidateGenerationInputs(); Changed?.Invoke(this, EventArgs.Empty); }
            }
            cancellation.Dispose();
        }
    }

    /// <summary>Replaces only the requested phrases' words; a structured keep-original answer leaves that change as recorded.</summary>
    internal void ApplyWordingFit(IReadOnlyList<VoiceLabFitUpdate> updates)
    {
        if (Review is null) throw new OperationCanceledException();
        var proposals = (scopeHunks ?? Review.Diff.Hunks.Select(change => new ScopeRewriteDiff.Hunk(change, null, [], [], false))).ToArray();
        foreach (var update in updates)
        {
            var index = update.Ordinal - 1;
            if (index < 0 || index >= proposals.Length || proposals[index].Diff.Kind != VoiceLabDiffHunkKind.Voice)
                throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            if (update.KeepOriginal) { changeStates[update.Ordinal] = TranscriptChangeState.Excluded; fitKept.Add(update.Ordinal); }
            else proposals[index] = proposals[index] with { Diff = VoiceLabWordingFit.Reword(proposals[index].Diff, update.Text) };
        }
        scopeHunks = proposals;
        NewWords = string.Join(" ", ReviewDiff().Ops.Where(operation => operation.NewToken is not null).Select(operation => operation.NewToken));
        RefreshReview();
        InvalidateGenerationInputs();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Stop: ends the remaining rounds (and an unsent approval) and keeps the latest proposal.</summary>
    internal void StopWordingFit() => StopWordingFit(markStopped: true);
    private void StopWordingFit(bool markStopped)
    {
        var active = WordingIsLocked;
        fitToken++;
        try { fitting?.Cancel(); } catch (ObjectDisposedException) { }
        fitting = null;
        Interlocked.Exchange(ref fitLease, null)?.Dispose();
        if (MeasuredWording is { Preparing: true }) { CancelMeasuredWording(); MeasuredWording = null; }
        WordingFitRunning = false; WordingFitAwaitingApproval = false;
        if (!active) return;
        if (markStopped) WordingFitStopped = true;
        if (IsOpen) { InvalidateGenerationInputs(); Changed?.Invoke(this, EventArgs.Empty); }
    }

    private void RecordCalibration()
    {
        double rate;
        try { rate = VoiceLabRewriteFit.SpeakingRate(RewriteReview.TimingWords(this, Project)); }
        catch (VoiceLabLengthBudgetException) { return; }
        foreach (var window in generationWindows)
            foreach (var row in window.Rows)
            {
                if (row.Audio is not { } audio || audio.Trimmed.Length == 0 || calibratedTakes.Contains(row.Id) || window.InputFor(row.Id) is not { } input) continue;
                calibratedTakes.Add(row.Id);
                var model = row.Receipt?.ModelId ?? input.ModelId;
                var estimate = VoiceLabRewriteFit.Estimate(input.Text, rate) + VoiceLabAudioTags.Allowance(input.AudioTags, input.Text, model);
                var measured = audio.Trimmed.Length / (double)audio.SampleRate * (row.Receipt?.Pace ?? input.Pace ?? 1);
                var previous = RateSamples(model);
                var next = VoiceLabWordingFit.Recording(previous, row.Id.ToString("D"), measured, estimate);
                if (!ReferenceEquals(next, previous)) sessionRates[model] = next;
            }
    }

    /// <summary>Records each measured take's speaking rate once and, when a selected v4 take cannot fit and nothing else can make it
    /// fit, asks for one measured-length rewording. Nothing is synthesized.</summary>
    private void ObserveMeasuredTakes()
    {
        if (!IsOpen) return;
        RecordCalibration();
        if (MeasuredWording is { } open)
        {
            if (!open.Unselected && generationWindows.ElementAtOrDefault(open.Window)?.SelectedTakeId != open.Take && !open.AwaitingApproval && !open.Preparing && open.Text is null)
            { CancelMeasuredWording(); MeasuredWording = null; }
            return;
        }
        // Once Get Price armed the automatic fixes, they reword from the measured take themselves (RewriteSession.AutoFix).
        if (Connector is null || WordingIsLocked || IsGeneratingBatch || AutoFix.Armed) return;
        for (var index = 0; index < generationWindows.Count; index++)
        {
            var window = generationWindows[index];
            if (window.IsRunning || window.IsPreparing || !window.NeedsShorterWording || window.Selected is not { Audio: { } audio } selected ||
                measuredTakes.Contains(selected.Id) || (selected.Receipt?.ModelId ?? window.InputFor(selected.Id)?.ModelId) != synthesisModel ||
                PricedVoiceHunks.ElementAtOrDefault(index) is not { Fit: { } fit }) continue;
            measuredTakes.Add(selected.Id);
            MeasuredWording = new(index, selected.Id, selected.Index + 1, audio.Fit.Plan.OutputFrames / (double)audio.SampleRate, fit.SlotSeconds);
            MeasuredWork = RewordMeasuredTakeAsync(!FitAsksFirst);
            return;
        }
    }

    internal VoiceLabFitPhrase MeasuredPhrase(RewriteMeasuredWording suggestion)
    {
        if (generationWindows.ElementAtOrDefault(suggestion.Window) is not { } window ||
            PricedVoiceHunks.ElementAtOrDefault(suggestion.Window) is not { Window: { } placed, PatchText: { } patch } hunk)
            throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.InvalidInput);
        var input = window.InputFor(suggestion.Take);
        var text = input?.Text ?? patch;
        var tags = input?.AudioTags ?? hunk.RequestAudioTags;
        var (rate, wordsPerSecond, spoken) = SpeakingRate();
        var calibrated = VoiceLabWordingFit.Multiplier(RateSamples(synthesisModel));
        var baseline = VoiceLabRewriteFit.Estimate(text, rate);
        var silence = VoiceLabWindowPlanner.LendableSilence(Project, Scope, placed);
        var timing = VoiceLabPaceMatching.Measure(text, rate, placed, silence.Incoming, silence.Outgoing, Project.Media.Source.Audio?.SampleRate ?? 48_000,
            hardJoinSmoothing: true, supportsPace: false, sourceItems: spoken, sourceEnvelope: Envelope, audioTags: tags, modelId: synthesisModel, rateMultiplier: calibrated);
        var ratio = suggestion.MeasuredSeconds / baseline;
        var speech = VoiceLabTextLength.Length(text) / (rate * VoiceLabRewriteFit.ProviderSpeechRateMultiplier);
        var lower = timing.MinimumSeconds ?? timing.SlotSeconds;
        var target = VoiceLabWordingFit.WordTarget(wordsPerSecond, ratio, lower, Math.Max(lower, timing.MaximumSeconds ?? timing.SlotSeconds),
            Math.Max(0, baseline - speech) * ratio);
        var original = string.Join(" ", hunk.Hunk.SourceWordIds.Select(id => Transcript.First(word => word.Id == id).Text));
        // The loop's memory (voice-lab.md §8.2.2): every wording this phrase had, with its measured result. The whole phrase is
        // reworded, so the words joining it to the recording are named as required.
        var tried = TriedWordings(suggestion.Window);
        return new(hunk.Ordinals[0], original, text, baseline * calibrated + VoiceLabAudioTags.Allowance(tags, text, synthesisModel),
            suggestion.SlotSeconds, suggestion.TooLong ? "shorter" : "longer", target, suggestion.MeasuredSeconds, Calibrated: true)
            { Tried = tried.Count == 0 ? null : tried, Bridge = BridgeFor(suggestion.Window) };
    }

    /// <summary>Why a reworded phrase is not voiced when the AI dropped its bridge words (voice-lab.md §8.2.2).</summary>
    internal static string DroppedBridgeProblem(string ai, VoiceLabFitBridge bridge, int window) =>
        $"{ai} left out “{bridge.Display}”, the words that join phrase {window + 1} to your recording, so its wording wasn't used.";

    /// <summary>Why an automatic round's wording is not voiced (Mac <c>automaticRefusal</c>): a variant already tried, or one that does
    /// not move toward the slot from the measured take's wording. Null when it may be priced.</summary>
    private string? AutomaticRefusal(string text, RewriteMeasuredWording suggestion, IReadOnlyList<VoiceLabFitTried> tried)
    {
        if (generationWindows.ElementAtOrDefault(suggestion.Window) is not { } window) return null;
        var measured = window.InputFor(suggestion.Take)?.Text ?? PricedVoiceHunks.ElementAtOrDefault(suggestion.Window)?.PatchText ?? "";
        var key = VoiceLabFitTried.Key(text);
        if (key == VoiceLabFitTried.Key(measured) || tried.Any(row => VoiceLabFitTried.Key(row.Text) == key)) return "repeat";
        var rate = SpeakingRate().Rate;
        var before = VoiceLabRewriteFit.Estimate(measured, rate);
        var after = VoiceLabRewriteFit.Estimate(text, rate);
        if (suggestion.TooLong && after >= before) return "notShorter";
        if (!suggestion.TooLong && after <= before) return "notLonger";
        return null;
    }

    private async Task RewordMeasuredTakeAsync(bool approved, bool automatic = false)
    {
        if (MeasuredWording is not { } suggestion || Connector is not { } connector ||
            generationWindows.ElementAtOrDefault(suggestion.Window) is not { } window || !suggestion.Unselected && window.SelectedTakeId != suggestion.Take) return;
        var token = ++measuredToken;
        IDisposable? lease = null;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        measuring = cancellation;
        try
        {
            var request = MeasuredPhrase(suggestion);
            _ = fitService.Request([request], connector.Connector.Id, Language);
            if (!approved)
            {
                suggestion.AwaitingApproval = true; suggestion.Preparing = false;
                Changed?.Invoke(this, EventArgs.Empty);
                return;
            }
            suggestion.AwaitingApproval = false; suggestion.Preparing = true;
            Changed?.Invoke(this, EventArgs.Empty);
            lease = Editor.LlmRuns.TryAcquire() ?? throw new RewriteGenerationException(FitBusy);
            measuredLease = lease;
            bool StillAsked() => IsOpen && token == measuredToken && ReferenceEquals(MeasuredWording, suggestion) &&
                (suggestion.Unselected || window.SelectedTakeId == suggestion.Take);
            var action = fitService.Prepare([request], connector.Connector.Id, connector.Model, Language);
            var updates = await fitService.ProposeAsync([request], connector.Connector, connector.Model, Language, fitService.Approve(action, true), cancellation.Token);
            if (!StillAsked()) return;
            var update = updates[0];
            // A reply that dropped the bridge words can't be priced or placed, so it never counts as a round: an automatic round
            // asks once more, free of speech cost, naming them and listing the dropped wording (voice-lab.md §8.2.2).
            if (!update.KeepOriginal && request.Bridge is { } bridge && !bridge.Keeps(update.Text))
            {
                if (!automatic) { suggestion.Problem = DroppedBridgeProblem(AiName, bridge, suggestion.Window); return; }
                Refuse(suggestion.Window, new(update.Text, "missingBridge"));
                AutoFix.Lines[suggestion.Window] = $"Fixing phrase {suggestion.Window + 1}: asking {AiName} again to keep “{bridge.Display}”…";
                Changed?.Invoke(this, EventArgs.Empty);
                if (!AutoFixChargeSend(suggestion.Window)) { MeasuredWording = null; return; }
                var again = MeasuredPhrase(suggestion);
                var retry = fitService.Prepare([again], connector.Connector.Id, connector.Model, Language);
                updates = await fitService.ProposeAsync([again], connector.Connector, connector.Model, Language, fitService.Approve(retry, true), cancellation.Token);
                if (!StillAsked()) return;
                update = updates[0];
                if (!update.KeepOriginal && !bridge.Keeps(update.Text))
                {
                    // Still without them: this round ends, and the phrase card's "Round k of 3 · tried: …" says why.
                    Refuse(suggestion.Window, new(update.Text, "missingBridge"));
                    suggestion.Problem = DroppedBridgeProblem(AiName, bridge, suggestion.Window);
                    return;
                }
            }
            // The editor is busy while an AI request holds the project; release it before the new wording is quoted.
            lease.Dispose(); lease = null;
            if (token == measuredToken) measuredLease = null;
            suggestion.KeepOriginal = update.KeepOriginal;
            if (!update.KeepOriginal)
            {
                // An automatic round never prices a repeat, or a wording that doesn't move toward the slot; the next round hears
                // why. A suggestion the user reviews is theirs to judge by ear.
                if (automatic && AutomaticRefusal(update.Text, suggestion, request.Tried ?? []) is { } refusal)
                {
                    Refuse(suggestion.Window, new(update.Text, refusal));
                    suggestion.Problem = refusal == "repeat" ? $"{AiName} repeated a wording already tried, so it wasn't used."
                        : $"{AiName}'s wording wasn't {(suggestion.TooLong ? "shorter" : "longer")}, so it wasn't used.";
                    return;
                }
                suggestion.Text = update.Text;
                measuredWording[suggestion.Window] = update.Text;
                await window.InputsChangedAsync(preserveReview: true);
            }
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (IsOpen && token == measuredToken && !cancellation.IsCancellationRequested) suggestion.Problem = Refusal(exception);
        }
        finally
        {
            lease?.Dispose();
            if (token == measuredToken) { measuring = null; measuredLease = null; suggestion.Preparing = false; }
            cancellation.Dispose();
            if (IsOpen) Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>The key-billed measured rewording's inline Fit: one request.</summary>
    internal Task ApproveMeasuredFitAsync()
    {
        if (MeasuredWording is not { AwaitingApproval: true }) return Task.CompletedTask;
        return MeasuredWork = RewordMeasuredTakeAsync(true);
    }

    /// <summary>The priced Make Take action for the reworded phrase: its own fresh quote, approved only by its click.</summary>
    internal RewriteGeneration? MeasuredGeneration => MeasuredWording is { Text: not null } suggestion &&
        generationWindows.ElementAtOrDefault(suggestion.Window) is { } window && measuredWording.ContainsKey(suggestion.Window) ? window : null;

    internal async Task MakeMeasuredTakeAsync(Func<string, CancellationToken, Task<bool>> confirm)
    {
        if (MeasuredGeneration is not { Quote: { } quote } window || !window.CanExecute) return;
        MeasuredWording = null;
        Changed?.Invoke(this, EventArgs.Empty);
        await window.GenerateAsync(confirm, quote, autoplay: false);
    }

    /// <summary>Keep Take n: the selected take's words stay, the rewording's quote is dropped and nothing is sent.</summary>
    internal async Task KeepMeasuredTakeAsync()
    {
        if (MeasuredWording is not { } suggestion) return;
        CancelMeasuredWording();
        MeasuredWording = null;
        if (generationWindows.ElementAtOrDefault(suggestion.Window) is { } window)
        {
            var kept = window.SelectedTakeId is { } selected ? window.InputFor(selected)?.Text : null;
            if (kept is null || kept == PricedVoiceHunks.ElementAtOrDefault(suggestion.Window)?.PatchText) measuredWording.Remove(suggestion.Window);
            else measuredWording[suggestion.Window] = kept;
            await window.InputsChangedAsync(preserveReview: true);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void CancelMeasuredWording()
    {
        measuredToken++;
        try { measuring?.Cancel(); } catch (ObjectDisposedException) { }
        measuring = null;
        Interlocked.Exchange(ref measuredLease, null)?.Dispose();
        if (MeasuredWording is { } suggestion) { suggestion.Preparing = false; suggestion.AwaitingApproval = false; }
    }

    private void ClearMeasuredWording()
    {
        CancelMeasuredWording();
        MeasuredWording = null;
        measuredWording.Clear();
    }
}
