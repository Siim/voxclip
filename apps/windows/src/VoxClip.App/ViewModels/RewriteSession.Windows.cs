using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed partial class RewriteSession
{
    private readonly List<RewriteGeneration> generationWindows = [];
    private readonly List<Task> retiredGenerations = [];
    private Func<int, RewriteGeneration>? generationFactory;
    private RewriteReview? generatedReview;
    private bool applyingBatch;
    internal IReadOnlyList<RewriteGeneration> GenerationWindows => generationWindows;
    internal int ActiveWindow { get; private set; }
    internal bool IsGeneratingBatch { get; private set; }
    internal bool CanAcceptAll => GenerationIsCurrent && !IsGeneratingBatch && !applyingBatch && generationWindows.Count > 0 &&
        generationWindows.Count == Review?.VoiceHunks.Count && generationWindows.All(window => window.ReadyToAccept);
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

    private void ReconcileGenerationWindows()
    {
        if (generationFactory is null || ReferenceEquals(generatedReview, Review)) return;
        RetireGenerationWindows();
        generatedReview = Review;
        var count = Math.Max(1, Math.Min(VoiceLabTakeBatch.MaximumWindows, Review?.VoiceHunks.Count ?? 0));
        for (var index = 0; index < count; index++)
        {
            var window = generationFactory(index);
            generationWindows.Add(window);
            window.Changed += GenerationChanged;
        }
        ActiveWindow = 0;
        Generation = generationWindows[0];
        Editor.SelectionChanged -= GenerationSelectionChanged;
        Editor.SelectionChanged += GenerationSelectionChanged;
    }

    private void RetireGenerationWindows()
    {
        foreach (var generation in generationWindows)
        {
            generation.Changed -= GenerationChanged;
            generation.Dispose();
            retiredGenerations.Add(DrainGenerationAsync(generation));
        }
        generationWindows.Clear();
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
        foreach (var generation in generationWindows.ToArray()) await generation.ChooseModelAsync(id);
    }

    internal VoiceLabTakeBatch? PreparedBatch
    {
        get
        {
            if (Review is null || generationWindows.Count != Review.VoiceHunks.Count || generationWindows.Count == 0) return null;
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
