using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed partial class RewriteSession
{
    private readonly List<RewriteGeneration> generationWindows = [];
    /// <summary>ADR-R37: this Rewrite plan's generated speech and voice mismatches, shared by every phrase's take runs.</summary>
    internal VoxClip.Media.VoiceLab.VoiceLabVoiceCheckSession VoiceChecks { get; } = new();
    private readonly List<Task> retiredGenerations = [];
    private Func<int, RewriteGeneration>? generationFactory;
    private RewriteReview? generatedReview;
    private RewriteHunkReview[] generatedVoiceHunks = [];
    private bool applyingBatch;
    internal IReadOnlyList<RewriteGeneration> GenerationWindows => generationWindows;
    internal int ActiveWindow { get; private set; }
    internal bool IsGeneratingBatch { get; private set; }
    /// <summary>Every phrase is ready or kept as recorded, and at least one take or text fix applies.</summary>
    internal bool CanAcceptAll => GenerationIsCurrent && !IsGeneratingBatch && !applyingBatch && AutoFix.Work is null && generationWindows.Count > 0 && Collision is null &&
        generationWindows.Count == PricedVoiceHunks.Count && generationWindows.All(window => window.LeftOut || window.ReadyToAccept) &&
        (generationWindows.Any(window => !window.LeftOut) || LocalOperations().Count > 0);
    /// <summary>The footer's next step while selected takes cannot be used yet because a changed-duration phrase has no
    /// video choice (Mac ClipTakePlan.acceptanceBlocker); null otherwise.</summary>
    internal string? AcceptanceBlocker
    {
        get
        {
            if (!GenerationIsCurrent || IsGeneratingBatch || applyingBatch || CanAcceptAll) return null;
            var missing = generationWindows.Select((window, index) => (window, number: index + 1))
                .Where(item => !item.window.LeftOut && item.window.Phase == RewriteGenerationPhase.LengthChanged &&
                    item.window.Selected is { Selectable: true, RequiresJoinAdvisoryAcceptance: false, Fits: false } && item.window.VideoChoice is null &&
                    item.window.ValidVideoChoices.Count > 0)
                .Select(item => item.number).ToArray();
            return missing.Length == 0 ? null : $"Choose the video duration for {PhraseList(missing)}.";
        }
    }
    /// <summary>"phrase 2", "phrases 2 and 4", "phrases 1, 2 and 4".</summary>
    internal static string PhraseList(IReadOnlyList<int> numbers) => numbers.Count switch
    {
        0 => "",
        1 => $"phrase {numbers[0]}",
        _ => $"phrases {string.Join(", ", numbers.Take(numbers.Count - 1))} and {numbers[^1]}"
    };
    internal Task GenerationCleanup => Task.WhenAll(retiredGenerations);
    internal string RewriteActionName => requestedScope is null
        ? $"Rewrite {Source.Count(word => word.Kind == Core.Domain.Shared.WordKind.Word)} words"
        : requestedScope.ClipId is { } id ? $"Rewrite clip {Editor.Clips.First(clip => clip.Id == id).Number}" : "Rewrite full take";

    internal void ConfigureGenerationFactory(Func<int, RewriteGeneration> factory)
    {
        generationFactory = factory;
        generatedReview = null;
        ReconcileGenerationWindows();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void ReconcileGenerationWindows(bool preserve = false)
    {
        if (generationFactory is null || ReferenceEquals(generatedReview, Review)) return;
        var previous = generationWindows.ToArray();
        var previousHunks = generatedVoiceHunks;
        var desired = PricedVoiceHunks;
        generationWindows.Clear();
        generatedReview = Review;
        generatedVoiceHunks = desired.ToArray();
        var count = Math.Max(1, Math.Min(VoiceLabTakeBatch.MaximumRunPhrases, PricedVoiceHunks.Count));
        for (var index = 0; index < count; index++)
        {
            var reusable = preserve && index < previous.Length &&
                (index < previousHunks.Length && index < desired.Count && SameVoicePhrase(previousHunks[index], desired[index]) ||
                 index == 0 && previous[index].Rows.Count == 0 && (previousHunks.Length == 0 || desired.Count == 0));
            var window = reusable ? previous[index] : generationFactory(index);
            window.FixedModelId = synthesisModel;
            window.ShareVoiceChecks(VoiceChecks, index);
            if (AutoFix.Armed) window.KeepEveryTake();
            generationWindows.Add(window);
            if (!reusable) window.Changed += GenerationChanged;
            else if (desired.Count == 0 || previousHunks.Length == 0) _ = window.InputsChangedAsync();
        }
        foreach (var retired in previous.Where(window => !generationWindows.Contains(window)))
        {
            retired.Changed -= GenerationChanged;
            retired.Dispose();
            retiredGenerations.Add(DrainGenerationAsync(retired));
        }
        ActiveWindow = 0;
        Generation = generationWindows[0];
        Editor.SelectionChanged -= GenerationSelectionChanged;
        Editor.SelectionChanged += GenerationSelectionChanged;
    }

    private static bool SameVoicePhrase(RewriteHunkReview left, RewriteHunkReview right) =>
        left.PatchText == right.PatchText && left.Ordinals.SequenceEqual(right.Ordinals) && left.Window is { } first && right.Window is { } second &&
        first.StartSample == second.StartSample && first.EndSample == second.EndSample && first.FirstWordId == second.FirstWordId &&
        first.LastWordId == second.LastWordId && first.LeftSeam == second.LeftSeam && first.RightSeam == second.RightSeam &&
        first.LeftBridgeWordIds.SequenceEqual(second.LeftBridgeWordIds) && first.RightBridgeWordIds.SequenceEqual(second.RightBridgeWordIds);

    private void RetireGenerationWindows()
    {
        foreach (var generation in generationWindows)
        {
            generation.Changed -= GenerationChanged;
            generation.Dispose();
            retiredGenerations.Add(DrainGenerationAsync(generation));
        }
        generationWindows.Clear();
        generatedVoiceHunks = [];
        Generation = null;
        AutoFix.Reset();
        VoiceChecks.Reset();
        ResetWordings();
        CancelPhraseMicrophone();
    }

    private static async Task DrainGenerationAsync(RewriteGeneration generation)
    {
        await generation.Cleanup;
        await generation.DeferredCleanup;
    }

    internal async Task SelectWindowAsync(int index)
    {
        if (!GenerationIsCurrent || IsGeneratingBatch || index < 0 || index >= generationWindows.Count || index == ActiveWindow) return;
        await StopCandidatesAsync();
        if (!GenerationIsCurrent || index >= generationWindows.Count) return;
        ActiveWindow = index;
        Generation = generationWindows[index];
        Changed?.Invoke(this, EventArgs.Empty);
    }

    internal async Task StopCandidatesAsync()
    {
        foreach (var generation in generationWindows.ToArray()) await generation.StopForSourceAsync();
    }

    private void InvalidateGenerationInputs()
    {
        foreach (var generation in generationWindows.ToArray()) _ = generation.InputsChangedAsync();
    }

    internal async Task DiscoverWindowsAsync()
    {
        var windows = generationWindows.ToArray();
        foreach (var window in windows)
        {
            if (!GenerationIsCurrent || !generationWindows.SequenceEqual(windows)) return;
            await window.DiscoverAsync();
            if (!window.HasDiscovered) return;
        }
    }

    internal async Task ChooseVoiceForWindowsAsync(string? id)
    {
        foreach (var generation in generationWindows.ToArray()) await generation.ChooseVoiceAsync(id);
    }

    internal string TakeSendLine => RewriteGeneration.SendLine + string.Concat(generationWindows.Select((window, index) =>
        window.NextPace is { } pace && pace != 1 ? " Phrase " + (index + 1) + " at " + pace.ToString("F2", System.Globalization.CultureInfo.InvariantCulture) + "× pace." : ""));

    /// <summary>The whole run's one price (Mac <c>ClipTakePlan</c> parts): every phrase's quote, in parts of at most
    /// <see cref="VoiceLabTakeBatch.MaximumWindows"/>, approved once.</summary>
    internal VoiceLabTakeRunParts? PreparedBatch
    {
        get
        {
            if (Review is null || generationWindows.Count != PricedVoiceHunks.Count || generationWindows.Count == 0) return null;
            var windows = generationWindows.Select(window => window.PreparedWindow).ToArray();
            if (windows.Any(window => window is null)) return null;
            try { return new(windows.Select(window => window!).ToArray()); }
            catch (VoiceLabException) { return null; }
        }
    }
    /// <summary>Mac <c>ClipTakePlan.copy(.tooManyPhrases)</c>: the run limit, with what to do.</summary>
    internal static string TooManyPhrasesCopy(int count) =>
        $"These changes make {count} phrases to voice. Up to {VoiceLabTakeBatch.MaximumRunPhrases} can be voiced in one run: voice the first changes now and rewrite the rest after.";
    /// <summary>Mac <c>ClipTakePlan.copy(.priceChanged)</c>.</summary>
    internal const string PriceChangedCopy =
        "The price of the next phrases changed while takes were made, so nothing more was sent. Finished takes are kept. Get a fresh price for the rest.";

    internal bool CanGenerateAll => GenerationIsCurrent && !IsGeneratingBatch && PreparedBatch is not null && generationWindows.All(window => window.CanExecute);
    internal void MarkBatchEstimateShown(VoiceLabTakeRunParts batch)
    {
        if (batch.Windows.Count != generationWindows.Count) return;
        for (var index = 0; index < generationWindows.Count; index++)
            generationWindows[index].MarkEstimateShown(batch.Windows[index].Quote);
    }

    /// <summary>Makes every phrase's takes under one approval. A run of more than <see cref="VoiceLabTakeBatch.MaximumWindows"/>
    /// phrases runs part by part (Mac <c>ClipTakePlan.continueRun</c>): each later part is quoted again just before it runs and
    /// runs under the approval only when its inputs and estimate equal the priced ones; otherwise nothing more is sent
    /// (<see cref="PriceChangedCopy"/>).</summary>
    internal async Task GenerateWindowsAsync(Func<object, string, Func<bool>, CancellationToken, Task<bool>> confirm,
        Func<CancellationToken, Task<VoiceLabMonthlyCap?>> readCap)
    {
        if (!CanGenerateAll || PreparedBatch is not { } run) return;
        var identity = ReviewIdentity;
        var windows = generationWindows.ToArray();
        var quotes = run.Windows.Select(window => window.Quote).ToArray();
        var started = -1;
        var partEnd = Math.Min(VoiceLabTakeBatch.MaximumWindows, windows.Length);
        VoxClip.Media.VoiceLab.VoiceLabShortTakePool? pool = null;
        bool Same() => GenerationIsCurrent && identity == ReviewIdentity && generationWindows.SequenceEqual(windows);
        // Only the running part's quotes must stay the priced ones; a later part is quoted again before it runs.
        bool Current() => Same() && Enumerable.Range(started + 1, Math.Max(0, partEnd - started - 1))
            .All(index => ReferenceEquals(windows[index].Quote, quotes[index]));
        IsGeneratingBatch = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var approvedCap = await readCap(lifetime.Token);
            if (!Current()) return;
            var decision = run.Kind(approvedCap);
            var copy = $"Generate up to {run.TakeCount} takes across {run.Windows.Count} passages. " +
                (decision.Text.Length == 0 ? "No charge." : decision.Text);
            if (!await confirm(run, copy, Current, lifetime.Token) || !Current()) return;
            // The approved price also covers automatic fixes up to max($0.10, the price) (voice-lab.md §8.2.2).
            ArmAutoFix(run);
            // ADR-R37: the run is one approval; its short takes are voice-checked together after its last phrase.
            if (windows.Any(window => window.PoolsShortTakes))
            {
                pool = new(VoiceChecks);
                foreach (var window in windows) window.UseShortTakePool(pool);
            }
            var progress = new VoiceLabTakeBatchProgress(run.Parts[0]);
            for (var index = 0; index < windows.Length; index++)
            {
                if (index > 0 && index % VoiceLabTakeBatch.MaximumWindows == 0)
                {
                    partEnd = Math.Min(index + VoiceLabTakeBatch.MaximumWindows, windows.Length);
                    List<VoiceLabTakeBatch.Window> requoted = [];
                    for (var later = index; later < partEnd; later++)
                    {
                        var window = await windows[later].RequoteAsync();
                        if (!Same()) return;
                        if (window is null || !VoiceLabTakeRunParts.SamePrice(run.Windows[later], window))
                        {
                            reviewProblem = PriceChangedCopy;
                            return;
                        }
                        quotes[later] = window.Quote;
                        windows[later].MarkEstimateShown(window.Quote);
                        requoted.Add(window);
                    }
                    progress = new VoiceLabTakeBatchProgress(new VoiceLabTakeBatch(requoted));
                }
                if (!Current()) return;
                started = index;
                await windows[index].GenerateAsync(async (changedCost, token) =>
                {
                    var cap = await readCap(token);
                    if (!Current()) return false;
                    if (cap == approvedCap) return true;
                    if (!await confirm(run, changedCost, Current, token) || !Current()) return false;
                    approvedCap = cap;
                    return true;
                }, quotes[index], autoplay: false);
                if (!Current() || windows[index].LastRunResult is not { } result) return;
                progress.Finish(index % VoiceLabTakeBatch.MaximumWindows, result);
                if (result.End is not (VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop)) return;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            if (IsOpen) reviewProblem = Refusal(error);
        }
        finally
        {
            if (pool is not null)
            {
                foreach (var window in windows) window.UseShortTakePool(null);
                var checkedRows = await pool.FinishAsync();
                if (IsOpen) foreach (var window in windows) window.ApplyVoiceChecks(checkedRows);
            }
            IsGeneratingBatch = false;
            AdvanceAutoFix();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    internal async Task CancelWindowsAsync()
    {
        foreach (var generation in generationWindows.ToArray()) await generation.CancelAsync();
    }

    private async Task<bool> ApplyReviewedWindowsAsync()
    {
        if (!CanAcceptAll) return false;
        applyingBatch = true;
        var identity = ReviewIdentity;
        var windows = generationWindows.ToArray();
        var operations = LocalOperations();
        List<RewriteAcceptance> prepared = [];
        try
        {
            // A phrase kept as recorded adds no segment; its text fixes still apply.
            if (windows.All(window => window.LeftOut)) return operations.Count > 0 && Editor.ApplyBatch(operations);
            foreach (var generation in windows.Where(window => !window.LeftOut))
            {
                var accepted = await generation.PrepareAcceptanceAsync(Editor, Project, operations);
                if (accepted is null || !GenerationIsCurrent || ReviewIdentity != identity || !generationWindows.SequenceEqual(windows)) return false;
                prepared.Add(accepted);
            }
            // Generated phrases share one voice; the user's own recorded takes carry none.
            var voices = prepared.Select(item => item.Voice).OfType<VoiceLabVoiceReference>().Distinct().ToArray();
            if (prepared.Any(item => !item.IsCurrent()) || voices.Length > 1) return false;
            var assets = prepared.SelectMany(item => item.Assets).ToArray();
            if (assets.GroupBy(asset => asset.Id).Any(group => group.Distinct().Count() != 1)) return false;
            return Editor.ApplyVoiceLab(prepared.Select(item => item.Segment).ToArray(), assets.DistinctBy(asset => asset.Id).ToArray(),
                voices.FirstOrDefault(), Scope, RewriteActionName, Project, operations, CalibratedRates());
        }
        finally { applyingBatch = false; Changed?.Invoke(this, EventArgs.Empty); }
    }
}
