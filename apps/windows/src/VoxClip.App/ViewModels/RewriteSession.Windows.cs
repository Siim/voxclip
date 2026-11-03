using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed partial class RewriteSession
{
    private readonly List<RewriteGeneration> generationWindows = [];
    private readonly List<Task> retiredGenerations = [];
    private Func<int, RewriteGeneration>? generationFactory;
    private RewriteReview? generatedReview;
    private RewriteHunkReview[] generatedVoiceHunks = [];
    private bool applyingBatch;
    internal IReadOnlyList<RewriteGeneration> GenerationWindows => generationWindows;
    internal int ActiveWindow { get; private set; }
    internal bool IsGeneratingBatch { get; private set; }
    internal bool CanAcceptAll => GenerationIsCurrent && !IsGeneratingBatch && !applyingBatch && generationWindows.Count > 0 &&
        generationWindows.Count == PricedVoiceHunks.Count && generationWindows.All(window => window.ReadyToAccept);
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
        var count = Math.Max(1, Math.Min(VoiceLabTakeBatch.MaximumWindows, PricedVoiceHunks.Count));
        for (var index = 0; index < count; index++)
        {
            var reusable = preserve && index < previous.Length &&
                (index < previousHunks.Length && index < desired.Count && SameVoicePhrase(previousHunks[index], desired[index]) ||
                 index == 0 && previous[index].Rows.Count == 0 && (previousHunks.Length == 0 || desired.Count == 0));
            var window = reusable ? previous[index] : generationFactory(index);
            window.PreferredModelId = synthesisModel;
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

    internal async Task ChooseModelForWindowsAsync(string? id)
    {
        if (IsGeneratingBatch || generationWindows.Any(window => window.IsRunning || window.IsPreparing) ||
            !generationWindows.Any(window => window.Models.Any(model => model.Id == id))) return;
        var discovered = generationWindows.Any(window => window.HasDiscovered);
        if (generationWindows.All(window => window.Rows.Count == 0))
        {
            synthesisModel = id;
            RefreshReview(preserveGenerations: true);
        }
        foreach (var generation in generationWindows.ToArray())
        {
            if (discovered && !generation.HasDiscovered) await generation.DiscoverAsync();
            await generation.ChooseModelAsync(id);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    internal string TakeSendLine => RewriteGeneration.SendLine + string.Concat(generationWindows.Select((window, index) =>
        window.NextPace is { } pace && pace != 1 ? " Phrase " + (index + 1) + " at " + pace.ToString("F2", System.Globalization.CultureInfo.InvariantCulture) + "× pace." : ""));

    internal VoiceLabTakeBatch? PreparedBatch
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

    internal bool CanGenerateAll => GenerationIsCurrent && !IsGeneratingBatch && PreparedBatch is not null && generationWindows.All(window => window.CanExecute);
    internal void MarkBatchEstimateShown(VoiceLabTakeBatch batch)
    {
        if (batch.Windows.Count != generationWindows.Count) return;
        for (var index = 0; index < generationWindows.Count; index++)
            generationWindows[index].MarkEstimateShown(batch.Windows[index].Quote);
    }

    internal async Task GenerateWindowsAsync(Func<object, string, Func<bool>, CancellationToken, Task<bool>> confirm,
        Func<CancellationToken, Task<VoiceLabMonthlyCap?>> readCap)
    {
        if (!CanGenerateAll || PreparedBatch is not { } batch) return;
        var identity = ReviewIdentity;
        var windows = generationWindows.ToArray();
        var started = -1;
        bool Current() => GenerationIsCurrent && identity == ReviewIdentity && generationWindows.SequenceEqual(windows) &&
            windows.Skip(started + 1).Select((window, offset) =>
                ReferenceEquals(window.Quote, batch.Windows[started + 1 + offset].Quote)).All(same => same);
        IsGeneratingBatch = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var approvedCap = await readCap(lifetime.Token);
            if (!Current()) return;
            var decision = batch.Kind(approvedCap);
            var copy = $"Generate up to {batch.TakeCount} takes across {batch.Windows.Count} passages. " +
                (decision.Text.Length == 0 ? "No charge." : decision.Text);
            if (!await confirm(batch, copy, Current, lifetime.Token) || !Current()) return;
            var progress = new VoiceLabTakeBatchProgress(batch);
            for (var index = 0; index < windows.Length; index++)
            {
                if (!Current()) return;
                started = index;
                await windows[index].GenerateAsync(async (changedCost, token) =>
                {
                    var cap = await readCap(token);
                    if (!Current()) return false;
                    if (cap == approvedCap) return true;
                    if (!await confirm(batch, changedCost, Current, token) || !Current()) return false;
                    approvedCap = cap;
                    return true;
                }, batch.Windows[index].Quote, autoplay: false);
                if (!Current() || windows[index].LastRunResult is not { } result) return;
                progress.Finish(index, result);
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
            IsGeneratingBatch = false;
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
            foreach (var generation in windows)
            {
                var accepted = await generation.PrepareAcceptanceAsync(Editor, Project, operations);
                if (accepted is null || !GenerationIsCurrent || ReviewIdentity != identity || !generationWindows.SequenceEqual(windows)) return false;
                prepared.Add(accepted);
            }
            if (prepared.Any(item => !item.IsCurrent()) || prepared.Select(item => item.Voice).Distinct().Count() != 1) return false;
            var assets = prepared.SelectMany(item => item.Assets).ToArray();
            if (assets.GroupBy(asset => asset.Id).Any(group => group.Distinct().Count() != 1)) return false;
            return Editor.ApplyVoiceLab(prepared.Select(item => item.Segment).ToArray(), assets.DistinctBy(asset => asset.Id).ToArray(),
                prepared[0].Voice, Scope, RewriteActionName, Project, operations);
        }
        finally { applyingBatch = false; Changed?.Invoke(this, EventArgs.Empty); }
    }
}
