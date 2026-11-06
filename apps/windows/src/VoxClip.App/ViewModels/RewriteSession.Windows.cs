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
    /// <summary>Every phrase is ready, kept as recorded or blocked by the guard, and at least one take or text fix applies. Use keeps a
    /// blocked phrase's original audio with no click first (Mac <c>canAccept</c> over the selected phrases, <c>blockedUseLine</c>).</summary>
    internal bool CanAcceptAll => GenerationIsCurrent && !IsGeneratingBatch && !applyingBatch && AutoFix.Work is null && generationWindows.Count > 0 && Collision is null &&
        generationWindows.Count == PricedVoiceHunks.Count && generationWindows.All(window => window.LeftOut || window.WaitsOnBlock || window.ReadyToAccept) &&
        (generationWindows.Any(window => !window.LeftOut && !window.WaitsOnBlock) || LocalOperations().Count > 0);
    /// <summary>Beside Use (Mac <c>blockedUseLine</c>): what it does with the blocked phrases still waiting; null when none waits.</summary>
    internal string? BlockedUseLine
    {
        get
        {
            var waiting = generationWindows.Select((window, index) => (window, index)).Where(item => item.window.WaitsOnBlock).Select(item => item.index + 1).ToArray();
            return waiting.Length == 0 ? null : $"Use keeps {PhraseList(waiting)}'s original audio.";
        }
    }
    /// <summary>Phrases whose selected take waits on a video duration (Mac <c>acceptanceBlocker</c>'s undecided phrases), in order.</summary>
    private IEnumerable<int> UndecidedDurations() => generationWindows.Select((window, index) => (window, index))
        .Where(item => !item.window.LeftOut && item.window.Phase == RewriteGenerationPhase.LengthChanged &&
            item.window.Selected is { Selectable: true, RequiresJoinAdvisoryAcceptance: false, Fits: false } && item.window.VideoChoice is null)
        .Select(item => item.index);
    /// <summary>The footer's next step while selected takes cannot be used yet because a changed-duration phrase has no
    /// video choice (Mac ClipTakePlan.acceptanceBlocker); null otherwise. A duration is asked for only when one is allowed (the
    /// footer's primary makes it); a take no duration can carry is named as such, and Rewrite keeps that phrase as recorded
    /// (<see cref="RewriteGeneration.FitsNoDuration"/>).</summary>
    internal string? AcceptanceBlocker
    {
        get
        {
            if (!GenerationIsCurrent || IsGeneratingBatch || applyingBatch || CanAcceptAll) return null;
            var undecided = UndecidedDurations().ToArray();
            var missing = undecided.Where(index => generationWindows[index].ValidVideoChoices.Count > 0).Select(index => index + 1).ToArray();
            if (missing.Length > 0) return $"Choose the video duration for {PhraseList(missing)}.";
            return undecided.Length == 0 ? null : NoDurationCopy(undecided.Select(index => index + 1).ToArray(), kept: false);
        }
    }
    /// <summary>The footer's primary under <see cref="AcceptanceBlocker"/> (Mac <c>acceptanceForward</c>): the first duration a waiting
    /// take allows (<c>chooseDuration.N</c>), else Keep Original Audio for a take no duration carries.</summary>
    private RewriteFooterStep AcceptanceForward(string blocker)
    {
        var undecided = UndecidedDurations().ToArray();
        if (undecided.FirstOrDefault(index => generationWindows[index].ValidVideoChoices.Count > 0, -1) is var phrase and >= 0)
            return new(blocker, DurationTitle(generationWindows[phrase].ValidVideoChoices[0], phrase), RewriteFooterAction.ChooseDuration, phrase);
        var first = undecided.Length > 0 ? undecided[0] : 0;
        return new(blocker, $"Keep Original Audio for Phrase {first + 1}", RewriteFooterAction.KeepOriginal, first);
    }
    /// <summary>The footer's title for a duration choice the take allows (the phrase card's radio, as a primary; Mac
    /// <c>durationTitle</c>).</summary>
    internal static string DurationTitle(VoiceLabVideoMode choice, int phrase) => choice switch
    {
        VoiceLabVideoMode.Source => "Keep Source Duration",
        VoiceLabVideoMode.Cut => "Cut the Video",
        _ => "Match the Video"
    } + $" for Phrase {phrase + 1}";
    /// <summary>[Keep Source Duration / Cut the Video / Match the Video for Phrase N] (Mac <c>chooseDuration.N</c>): what the phrase
    /// card's duration radio does with the first valid choice; [Change] on the card still picks another.</summary>
    internal bool ChooseDuration(int phrase)
    {
        if (generationWindows.ElementAtOrDefault(phrase) is not { LeftOut: false, VideoChoice: null } window || window.ValidVideoChoices.Count == 0 ||
            !window.ChooseVideo(window.ValidVideoChoices[0])) return false;
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }
    /// <summary>design.md R2 "A take that can't fit its place" (Mac <c>noDurationCopy</c>): the one line for phrases kept as recorded
    /// because no video duration (keep source, cut or match) can carry their take. <paramref name="kept"/> false: the reason alone,
    /// while the phrase still waits (the footer's Keep Original Audio keeps it).</summary>
    internal static string NoDurationCopy(IReadOnlyList<int> numbers, bool kept = true)
    {
        var list = PhraseList(numbers);
        var one = numbers.Count == 1;
        var reason = one ? "P" + list[1..] + "'s take can't fit its place in the video" : $"The takes of {list} can't fit their places in the video";
        return reason + (kept ? one ? ", so it keeps your original audio." : ", so they keep your original audio." : ".");
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
            if (!reusable) { ApplyRememberedBlock(window, desired.ElementAtOrDefault(index)); window.Changed += GenerationChanged; }
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

    /// <summary>Get Price (Mac <c>ClipTakePlan.prepareQuote</c>): every phrase is discovered and quoted, then the guard screens them all
    /// before a price is shown (<see cref="ScreenWindowsAsync"/>). No price is shown or approvable while the screen runs.</summary>
    internal async Task DiscoverWindowsAsync()
    {
        var windows = generationWindows.ToArray();
        ScreeningVoice = windows.Length > 0;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            foreach (var window in windows)
            {
                if (!GenerationIsCurrent || !generationWindows.SequenceEqual(windows)) return;
                await window.DiscoverAsync();
                if (!window.HasDiscovered) return;
            }
            foreach (var window in windows) if (window.IsPreparing) await window.PendingUpdate;
            if (GenerationIsCurrent && generationWindows.SequenceEqual(windows)) await ScreenWindowsAsync(windows);
        }
        finally
        {
            ScreeningVoice = false;
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>"Checking it's your voice…" while the guard screens the phrases at Get Price (Mac <c>preparationStep</c>).</summary>
    internal const string ScreeningCopy = "Checking it's your voice…";
    /// <summary>The guard is screening the phrases: nothing is priced or approvable until it is done.</summary>
    internal bool ScreeningVoice { get; private set; }
    /// <summary>A phrase passed through the reference this video taught (Mac <c>learnedFromThisVideo</c>): the spend line says so.</summary>
    internal bool LearnedFromThisVideo { get; private set; }

    /// <summary>The guard runs first, free and on this PC (voice-lab.md §6.9, ADR-R41): a phrase it blocks is settled before any price, so
    /// Get Price never prices, and never asks approval for, a phrase that would be blocked. Phrases that pass against the record's own
    /// embedding teach this project's reference first, so the rest are judged with it. A phrase the screen can't check is unchecked, and
    /// the run's own guard decides at dispatch. Inert while <see cref="VoxClip.Core.Services.VoiceLab.VoiceSpeakerCheck.WindowsNativeParityVerified"/>
    /// is false: the production runner has no speaker check, so every phrase is unchecked.</summary>
    private async Task ScreenWindowsAsync(IReadOnlyList<RewriteGeneration> windows)
    {
        var identity = ReviewIdentity;
        var inputs = windows.Select(window => window.PreparedWindow?.Input).ToArray();
        var screened = inputs.Select((input, index) => (input, index)).Where(item => item.input is not null).ToArray();
        LearnedFromThisVideo = false;
        if (screened.Length == 0) return;
        IReadOnlyList<VoxClip.Core.Services.VoiceLab.VoiceGuardVerdict> verdicts;
        try { verdicts = await windows[0].ScreenGuardAsync(screened.Select(item => item.input!).ToArray(), lifetime.Token); }
        catch (Exception error) when (error is not OutOfMemoryException) { return; }
        if (!GenerationIsCurrent || identity != ReviewIdentity || !generationWindows.SequenceEqual(windows) || verdicts.Count != screened.Length) return;
        var blocked = false;
        for (var item = 0; item < screened.Length; item++)
        {
            var (input, index) = screened[item];
            var verdict = verdicts[item];
            if (verdict.Blocker is { } reason && windows[index].Blocked is null)
            {
                windows[index].Block(BlockedCopy(new VoiceConsentException(reason)));
                blocked = true;
            }
            else if (verdict.Match is { ContentKey: { } key } && key == input!.ContentKey) LearnedFromThisVideo = true;
        }
        if (blocked) RememberBlocked();
    }

    internal async Task ChooseVoiceForWindowsAsync(string? id)
    {
        foreach (var generation in generationWindows.ToArray()) await generation.ChooseVoiceAsync(id);
    }

    internal string TakeSendLine => RewriteGeneration.SendLine + string.Concat(generationWindows.Select((window, index) =>
        window.NextPace is { } pace && pace != 1 ? " Phrase " + (index + 1) + " at " + pace.ToString("F2", System.Globalization.CultureInfo.InvariantCulture) + "× pace." : ""));

    /// <summary>The phrases a price and a run cover (Mac <c>voiceableIndices</c>): every phrase not settled as blocked, in order.</summary>
    internal IReadOnlyList<RewriteGeneration> PricedWindows => generationWindows.Where(window => window.Blocked is null).ToArray();
    /// <summary>The whole run's one price (Mac <c>ClipTakePlan</c> parts): every phrase's quote, in parts of at most
    /// <see cref="VoiceLabTakeBatch.MaximumWindows"/>, approved once. A phrase the guard settled earlier in this Rewrite is left out of it
    /// (<see cref="PricedWindows"/>): nothing is sent for it, so nothing is priced.</summary>
    internal VoiceLabTakeRunParts? PreparedBatch
    {
        get
        {
            if (ScreeningVoice || Review is null || generationWindows.Count != PricedVoiceHunks.Count || generationWindows.Count == 0) return null;
            var windows = PricedWindows.Select(window => window.PreparedWindow).ToArray();
            if (windows.Length == 0 || windows.Any(window => window is null)) return null;
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

    /// <summary>A phrase the guard settled is skipped by the run (nothing is sent for it); a run of only settled phrases is not offered.</summary>
    internal bool CanGenerateAll => GenerationIsCurrent && !IsGeneratingBatch && PreparedBatch is not null &&
        generationWindows.All(window => window.CanExecute || window.Blocked is not null && !window.IsRunning && !window.IsPreparing) &&
        generationWindows.Any(window => window.Blocked is null && !window.LeftOut);
    internal void MarkBatchEstimateShown(VoiceLabTakeRunParts batch)
    {
        var priced = PricedWindows;
        if (batch.Windows.Count != priced.Count) return;
        for (var index = 0; index < priced.Count; index++) priced[index].MarkEstimateShown(batch.Windows[index].Quote);
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
        var all = generationWindows.ToArray();
        // The run covers the priced phrases only; a phrase settled earlier in this Rewrite sends nothing (ADR-R40).
        var windows = PricedWindows.ToArray();
        var quotes = run.Windows.Select(window => window.Quote).ToArray();
        var started = -1;
        var partEnd = Math.Min(VoiceLabTakeBatch.MaximumWindows, windows.Length);
        VoxClip.Media.VoiceLab.VoiceLabShortTakePool? pool = null;
        bool Same() => GenerationIsCurrent && identity == ReviewIdentity && generationWindows.SequenceEqual(all);
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
                if (windows[index].Blocked is not null)
                {
                    // Settled earlier in this Rewrite: nothing is sent for it, and the run goes on (ADR-R40).
                    progress.Finish(index % VoiceLabTakeBatch.MaximumWindows, new VoiceLabTakeRunResult([], VoiceLabTakeRunEnd.Blocked));
                    started = index;
                    continue;
                }
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
                // The guard settled this phrase before anything was sent for it; the other phrases go on (voice-lab.md §6.9).
                if (result.End == VoiceLabTakeRunEnd.Blocked) { RememberBlocked(); continue; }
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

    /// <summary>Use (Mac <c>acceptTakes(settling:)</c>): a phrase whose take can't be made part of the video keeps its original audio, with
    /// one line, and Use goes on with the rest, at most once per phrase; never a footer that repeats the failure.</summary>
    private async Task<bool> ApplyReviewedWindowsAsync()
    {
        if (!CanAcceptAll) return false;
        var settled = new HashSet<int>();
        while (true)
        {
            if (await TryApplyReviewedWindowsAsync(settled) is { } done) return done;
            if (!CanAcceptAll) return false;
        }
    }

    /// <summary>True or false when Use finished; null when it settled a phrase and should run again.</summary>
    private async Task<bool?> TryApplyReviewedWindowsAsync(HashSet<int> settled)
    {
        applyingBatch = true;
        var identity = ReviewIdentity;
        var windows = generationWindows.ToArray();
        var operations = LocalOperations();
        List<(int Index, RewriteAcceptance Accepted)> prepared = [];
        try
        {
            // A phrase kept as recorded, or one the guard blocked that still waits, adds no segment: it keeps its original audio (Mac
            // `blockedUseLine`); its text fixes still apply.
            if (windows.All(window => window.LeftOut || window.WaitsOnBlock)) return operations.Count > 0 && Editor.ApplyBatch(operations);
            for (var index = 0; index < windows.Length; index++)
            {
                var generation = windows[index];
                if (generation.LeftOut || generation.WaitsOnBlock) continue;
                var accepted = await generation.PrepareAcceptanceAsync(Editor, Project, operations);
                if (!GenerationIsCurrent || ReviewIdentity != identity || !generationWindows.SequenceEqual(windows)) return false;
                if (accepted is null)
                {
                    // Mac `logFailure(stage: "use")`: why Use failed is in the log, by type and case only.
                    if (generation.LastAcceptanceError is { } error) LogFailure(error, "use");
                    return generation.LastAcceptanceUnusable && SettleUnusable(index, settled) ? null : false;
                }
                prepared.Add((index, accepted));
            }
            // Generated phrases share one voice; the user's own recorded takes carry none.
            var voices = prepared.Select(item => item.Accepted.Voice).OfType<VoiceLabVoiceReference>().Distinct().ToArray();
            if (prepared.Any(item => !item.Accepted.IsCurrent()) || voices.Length > 1) return false;
            var assets = prepared.SelectMany(item => item.Accepted.Assets).ToArray();
            if (assets.GroupBy(asset => asset.Id).Any(group => group.Distinct().Count() != 1)) return false;
            if (Editor.ApplyVoiceLab(prepared.Select(item => item.Accepted.Segment).ToArray(), assets.DistinctBy(asset => asset.Id).ToArray(),
                voices.FirstOrDefault(), Scope, RewriteActionName, Project, operations, CalibratedRates())) return true;
            Log?.Write(VoxClip.Core.Services.Logging.LogLevel.Warn, "rewrite", "rewrite failure stage=use type=EditorViewModel case=applyVoiceLabRefused");
            // The project refused the takes together: the phrases it refuses alone can't go into the video (leave-one-out, Mac
            // `unusablePhrases`); the others are used on the next pass.
            if (!GenerationIsCurrent || ReviewIdentity != identity || !generationWindows.SequenceEqual(windows) || prepared.Count < 1) return false;
            var unusable = prepared.Where(item => !Editor.AcceptsVoiceLab([item.Accepted.Segment], item.Accepted.Assets, item.Accepted.Voice, Scope,
                RewriteActionName, operations)).Select(item => item.Index).ToArray();
            var any = false;
            foreach (var index in unusable) any |= SettleUnusable(index, settled);
            return any ? null : false;
        }
        finally { applyingBatch = false; Changed?.Invoke(this, EventArgs.Empty); }
    }

    /// <summary>Phrase <paramref name="index"/> keeps its original audio because its take can't be made part of the video (Mac
    /// <c>keepUnusable</c>/<c>noteUnusable</c>), announced once.</summary>
    private bool SettleUnusable(int index, HashSet<int> settled)
    {
        if (!settled.Add(index) || generationWindows.ElementAtOrDefault(index) is not { } window || !window.LeaveOut()) return false;
        var note = UnusableNote(index + 1);
        AutoFix.Notes.Add(note);
        AutoFix.Announcement = note;
        return true;
    }
    /// <summary>Where the session writes why a step failed (Mac <c>logFailure</c>); the App's log, none in tests.</summary>
    internal VoxClip.Core.Services.Logging.ILog? Log { get; set; }
    /// <summary>Mac <c>logFailure</c>: one line "rewrite failure stage={stage} type=… case=…" with no provider text.</summary>
    internal void LogFailure(Exception error, string stage)
    {
        if (error is OperationCanceledException) return;
        Log?.Write(VoxClip.Core.Services.Logging.LogLevel.Warn, "rewrite", $"rewrite failure stage={stage} " + FailureKind(error));
    }
    /// <summary>An error's type and case, with no associated text (Mac <c>failureKind</c>): "type=VoiceLabProjectException case=VideoModeUnsupported".</summary>
    internal static string FailureKind(Exception error) => "type=" + error.GetType().Name + error switch
    {
        VoiceLabProjectException project => " case=" + project.Code,
        VoiceLabGeometryException geometry => " case=" + geometry.Code,
        VoiceLabException voiceLab => " case=" + voiceLab.Kind,
        VoiceConsentException consent => " case=" + consent.Kind,
        _ => ""
    };
    internal static string UnusableNote(int phrase) => $"Phrase {phrase} couldn't be made part of the video, so it keeps your original audio.";
}
