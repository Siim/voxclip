using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Music;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Audio;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    private DispatcherQueueTimer? harnessTimer;
    private bool readingHarness;
    private int harnessActionVersion;
    private bool keepingHarnessRecording;
    private HarnessProposal? harnessPending;
    private HarnessReviewDetails? harnessDetails;
    private bool fillingHarnessTimelines;
    private int harnessTimelineIndex;
    private string? harnessPath;
    private Project? harnessCheckedProject;
    private string? harnessReadIssue;
    private HarnessMusicAction? harnessMusic;
    private (MusicCandidate Candidate, Project Project, DateTimeOffset Expires)? harnessQuote;
    private bool harnessPricing;
    private bool harnessSubmitted;
    private string? harnessPriceIssue;
    private readonly List<ClipAutopilotAction.Asset> harnessAssets = [];
    private readonly List<ClipAutopilotOperation> harnessRewrites = [];
    private string? harnessRewriteClipId;
    private bool harnessRewriteOpening;
    private (int Count, bool Opening, string? Blocked)? harnessRewriteDisplay;
    private Project? harnessAssetProject;
    private bool harnessAssetWorking;
    private bool? harnessIllustrationReady;
    private (int Count, bool Working, bool? Ready, string? Blocked)? harnessAssetDisplay;

    private void StartHarnessReview()
    {
        if (demo) return;
        harnessTimer = DispatcherQueue.CreateTimer();
        harnessTimer.Interval = TimeSpan.FromSeconds(1);
        harnessTimer.Tick += (_, _) => _ = RefreshHarnessAsync();
        harnessTimer.Start();
        _ = RefreshHarnessAsync();
    }

    private async Task RefreshHarnessAsync()
    {
        if (disposed || readingHarness || owner.ProjectPath is not { } path) return;
        readingHarness = true;
        var version = harnessActionVersion;
        HarnessProposal? pending = null;
        string? issue = null;
        try { pending = await Task.Run(() => ViewModel.ReadHarnessProposal(path)); }
        catch (HarnessException exception) { issue = exception.Message; }
        catch (Exception exception) when (HarnessFileError(exception))
        { issue = "VoxClip can't read this timeline proposal. Your project is unchanged."; }
        finally { readingHarness = false; }
        if (disposed || version != harnessActionVersion || !IsHarnessPath(path)) return;

        var newProposal = !string.Equals(harnessPath, path, StringComparison.OrdinalIgnoreCase) ||
            (harnessPending is null ? pending is not null : !harnessPending.Matches(pending));
        if (newProposal || !ReferenceEquals(harnessCheckedProject, ViewModel.Project))
        {
            harnessPending = pending;
            harnessPath = path;
            harnessCheckedProject = ViewModel.Project;
            if (newProposal)
            {
                fillingHarnessTimelines = true;
                harnessTimelineIndex = 0;
                var timelines = pending?.Timelines ?? [];
                HarnessTimelinePicker.ItemsSource = timelines.Select((timeline, index) =>
                    $"{index + 1}. {timeline.Target.New?.Title ?? ViewModel.Project.Edits.Clips.FirstOrDefault(clip => clip.Id == timeline.Target.ClipId)?.Title ?? "Clip"}").ToArray();
                HarnessTimelinePicker.SelectedIndex = timelines.Count == 0 ? -1 : 0;
                HarnessTimelinePicker.Visibility = timelines.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
                fillingHarnessTimelines = false;
                HarnessChanges.IsExpanded = false;
            }
            harnessDetails = pending is null ? null : ViewModel.DescribeHarnessProposal(pending, App.Services.SharedRoot, harnessTimelineIndex, App.Services.Data.Cache);
            ShowHarnessDetails();
        }
        if (harnessReadIssue != issue)
        {
            harnessReadIssue = issue;
            if (issue is null) HarnessNotice.IsOpen = false;
            else Ui.Show(HarnessNotice, issue, InfoBarSeverity.Warning);
        }
        UpdateHarnessButtons();
    }

    private void ShowHarnessDetails()
    {
        HarnessReviewCard.Visibility = harnessDetails is null ? Visibility.Collapsed : Visibility.Visible;
        if (harnessDetails is not { } details) return;
        HarnessReviewTitle.Text = $"Timeline proposal · {details.ClipTitle}";
        HarnessReviewReason.Text = details.Reason;
        HarnessChangeRows.Children.Clear();
        foreach (var row in details.Changes) HarnessChangeRows.Children.Add(Ui.Text(row));
        HarnessChanges.Visibility = details.Changes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        HarnessMusicBrief.Visibility = HarnessReviewEstimate.Visibility = details.MusicPrompt is null ? Visibility.Collapsed : Visibility.Visible;
        HarnessMusicBrief.Text = $"Music: {details.MusicPrompt}";
        HarnessReviewEstimate.Text = details.MusicEstimate is { } estimate
            ? $"About {estimate} to generate music. Keeping the timeline doesn't send anything."
            : "Keeping the timeline doesn't generate music.";
    }

    private string? HarnessBlock => keepingHarnessRecording ? "Transcribing on this PC." : harnessDetails?.Blocked ?? ViewModel.HarnessKeepBlocked ??
        (harnessMusic is not null || harnessAssets.Count > 0 || harnessRewrites.Count > 0 ? "Finish or dismiss the previous asset actions first." : null);

    private void UpdateHarnessButtons()
    {
        var blocked = HarnessBlock;
        HarnessKeep.IsEnabled = blocked is null;
        HarnessUndo.IsEnabled = !ViewModel.IsLeaving && !keepingHarnessRecording;
        HarnessTimelinePicker.IsEnabled = !keepingHarnessRecording;
        HarnessKeepReason.Text = blocked ?? "";
        HarnessKeepReason.Visibility = blocked is null ? Visibility.Collapsed : Visibility.Visible;
        ShowHarnessMusic();
        ShowHarnessAssets();
        ShowHarnessRewrites();
    }

    private void HarnessTimelineSelected(object sender, SelectionChangedEventArgs args)
    {
        if (fillingHarnessTimelines || harnessPending is not { } pending || HarnessTimelinePicker.SelectedIndex < 0) return;
        harnessTimelineIndex = HarnessTimelinePicker.SelectedIndex;
        harnessDetails = ViewModel.DescribeHarnessProposal(pending, App.Services.SharedRoot, harnessTimelineIndex, App.Services.Data.Cache);
        ShowHarnessDetails();
        UpdateHarnessButtons();
    }

    private bool IsHarnessPath(string path) => string.Equals(owner.ProjectPath, path, StringComparison.OrdinalIgnoreCase);

    private async void HarnessKeepClicked(object sender, RoutedEventArgs args) => await ReviewHarnessAsync(keep: true);
    private async void HarnessUndoClicked(object sender, RoutedEventArgs args) => await ReviewHarnessAsync(keep: false);

    private static async Task<Core.Domain.Transcript.Transcript> TranscribeHarnessRecordingAsync(MediaReference source, string projectPath,
        Core.Domain.Transcript.TranscriptionPlan plan,
        CancellationToken ct)
    {
        var path = await App.Services.Projects.ResolveMediaAsync(source, projectPath, ct) ?? throw HarnessRecording.Refusal(source);
        var media = await App.Services.Probe.ProbeAsync(path, ct);
        var audio = await App.Services.Cache.ExtractAudioAsync(App.Services.Audio, media, source.ContentKey, null, ct);
        return await App.Services.Transcription.TranscribeAsync(new(plan, audio.Audio, source.ContentKey), audio.Envelope, null, ct);
    }

    private async Task ReviewHarnessAsync(bool keep)
    {
        if (disposed || keepingHarnessRecording || harnessPending is not { } pending || harnessPath is not { } path) return;
        ++harnessActionVersion;
        var index = harnessTimelineIndex;
        try
        {
            if (!IsHarnessPath(path)) throw new HarnessException("The pending timeline changed. Review it again.");
            if (keep)
            {
                if (HarnessBlock is not null || App.Services.SharedRoot is not { } root) return;
                var recordingKey = pending.RecordingKeyAt(index);
                keepingHarnessRecording = recordingKey is not null;
                if (keepingHarnessRecording) UpdateHarnessButtons();
                var original = ViewModel.Project;
                var transcript = await ViewModel.PrepareHarnessRecordingAsync(pending, index, App.Services.Data.Cache,
                    (source, plan, ct) => TranscribeHarnessRecordingAsync(source, path, plan, ct), lifetime.Token);
                double? recordingGainDb = null;
                if (recordingKey is not null && transcript is not null)
                    recordingGainDb = (await RecordingLevelMatch.MatchOnAddAsync(original, new(recordingKey, transcript), App.Services.Projects,
                        path, lifetime.Token)).GainDb;
                if (disposed || !IsHarnessPath(path)) return;
                if (!ReferenceEquals(original, ViewModel.Project)) throw new HarnessException("The project changed. Ask for a new timeline proposal.");
                harnessMusic = ViewModel.KeepHarnessTimeline(pending, path, root, index, out var assets, out var rewrites, transcript, recordingGainDb);
                harnessAssets.AddRange(assets);
                harnessRewrites.AddRange(rewrites);
                harnessRewriteClipId = pending.ClipIdAt(index);
                harnessAssetProject = ViewModel.Project;
                harnessIllustrationReady = null;
                if (harnessAssets.Any(asset => asset.Kind == "illustration")) _ = CheckHarnessIllustrationKeyAsync();
            }
            else ViewModel.DismissHarnessProposal(pending, path, harnessTimelineIndex);
            harnessPending = null;
            harnessDetails = null;
            HarnessNotice.IsOpen = false;
            ShowHarnessDetails();
            UpdateHarnessButtons();
        }
        catch (OperationCanceledException) { }
        catch (HarnessException exception) { Ui.Show(HarnessNotice, exception.Message, InfoBarSeverity.Warning); }
        catch (Exception exception) when (HarnessFileError(exception))
        { Ui.Show(HarnessNotice, "VoxClip couldn't finish this review. Your project is unchanged.", InfoBarSeverity.Warning); }
        finally { keepingHarnessRecording = false; if (!disposed) UpdateHarnessButtons(); }
        _ = RefreshHarnessAsync();
    }

    private void ShowHarnessRewrites()
    {
        var blocked = ViewModel.HarnessKeepBlocked ?? (!ReferenceEquals(harnessAssetProject, ViewModel.Project)
            ? "The clip changed. Ask for a new rewrite proposal." : rewrite is { IsOpen: true } ? "Finish the open Rewrite first." : null);
        var display = (harnessRewrites.Count, harnessRewriteOpening, blocked);
        if (harnessRewriteDisplay == display) return;
        harnessRewriteDisplay = display;
        HarnessRewriteRows.Children.Clear();
        foreach (var operation in harnessRewrites)
        {
            if (operation.Action is not ClipAutopilotAction.Rewrite words) continue;
            var open = new Button { Content = ViewModel.AskClaudePrice(operation), IsEnabled = blocked is null && !harnessRewriteOpening };
            var dismiss = new Button { Content = "Dismiss", IsEnabled = !harnessRewriteOpening };
            open.Click += (_, _) => _ = RunAsync(() => OpenHarnessRewriteAsync(operation, words), "Rewrite");
            dismiss.Click += (_, _) => { harnessRewrites.Remove(operation); UpdateHarnessButtons(); };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            buttons.Children.Add(open);
            buttons.Children.Add(dismiss);
            HarnessRewriteRows.Children.Add(Ui.Text($"Proposed rewrite: {words.Text}"));
            HarnessRewriteRows.Children.Add(buttons);
            if (blocked is not null) HarnessRewriteRows.Children.Add(Ui.Text(blocked));
        }
    }

    private async Task OpenHarnessRewriteAsync(ClipAutopilotOperation operation, ClipAutopilotAction.Rewrite words)
    {
        if (disposed || harnessRewriteOpening || harnessRewriteClipId is not { } clipId || rewrite is { IsOpen: true } ||
            ViewModel.HarnessKeepBlocked is not null || !ReferenceEquals(harnessAssetProject, ViewModel.Project)) return;
        harnessRewriteOpening = true;
        ShowHarnessRewrites();
        var snapshot = ViewModel.Project;
        try
        {
            var session = await OpenMakeItRewriteAsync(new(words.Words.Start, words.Words.End, words.Text, clipId, null));
            if (session is null) return;
            if (disposed || !ReferenceEquals(snapshot, ViewModel.Project)) { session.Dispose(); return; }
            session.Edit(words.Text);
            if (session.Review is null) { session.Dispose(); return; }
            ShowRewriteSession(session, null);
            harnessRewrites.Remove(operation);
        }
        finally
        {
            harnessRewriteOpening = false;
            if (!disposed) UpdateHarnessButtons();
        }
    }

    private async Task CheckHarnessIllustrationKeyAsync()
    {
        try
        {
            harnessIllustrationReady = ViewModel.AskClaudeServices?.Assets is { } service &&
                await service.Key(lifetime.Token) is { Length: > 0 };
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { return; }
        catch (Exception) { harnessIllustrationReady = false; }
        if (!disposed) ShowHarnessAssets();
    }

    private void ShowHarnessAssets()
    {
        var blocked = !ReferenceEquals(harnessAssetProject, ViewModel.Project)
            ? "The edit changed. Ask for a new timeline proposal." : ViewModel.HarnessKeepBlocked;
        var display = (harnessAssets.Count, harnessAssetWorking, harnessIllustrationReady, blocked);
        if (harnessAssetDisplay == display) return;
        harnessAssetDisplay = display;
        HarnessAssetRows.Children.Clear();
        var services = ViewModel.AskClaudeServices?.Assets;
        foreach (var asset in harnessAssets)
        {
            var illustration = asset.Kind == "illustration";
            var saved = illustration && services?.Saved(asset, ViewModel.Project.Id) is not null;
            var price = illustration && !saved ? services?.Price : null;
            var reason = blocked ?? (harnessAssetWorking ? "Wait for the current asset." :
                services is null ? "This asset source isn't available." : !illustration || saved ? null :
                price is null ? "Illustration pricing isn't available." : harnessIllustrationReady == true ? null :
                harnessIllustrationReady == false ? "Add a fal.ai key in Settings to generate an illustration." : "Checking for a fal.ai key…");
            var title = !illustration ? "Find sound · free" : saved ? "Place saved illustration" : price is { } amount
                ? "Generate illustration · up to " + MakeItController.Dollars(decimal.Ceiling(amount * 100) / 100) : "Generate illustration";
            var action = new Button { Content = title, IsEnabled = reason is null };
            action.Click += async (_, _) => await ApplyHarnessAssetAsync(asset, price);
            var dismiss = new Button { Content = "Dismiss", IsEnabled = !harnessAssetWorking };
            dismiss.Click += (_, _) => { harnessAssets.Remove(asset); UpdateHarnessButtons(); };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            buttons.Children.Add(action);
            buttons.Children.Add(dismiss);
            HarnessAssetRows.Children.Add(new TextBlock { Text = asset.Text, TextWrapping = TextWrapping.Wrap });
            HarnessAssetRows.Children.Add(buttons);
            if (reason is not null) HarnessAssetRows.Children.Add(new TextBlock { Text = reason, TextWrapping = TextWrapping.Wrap });
        }
    }

    private async Task ApplyHarnessAssetAsync(ClipAutopilotAction.Asset asset, decimal? price)
    {
        if (disposed || harnessAssetWorking || !harnessAssets.Contains(asset) || harnessAssetProject is not { } snapshot) return;
        harnessAssetWorking = true;
        UpdateHarnessButtons();
        try
        {
            if (await ViewModel.ApplyHarnessAssetAsync(asset, snapshot, price, lifetime.Token))
            {
                harnessAssets.Remove(asset);
                harnessAssetProject = ViewModel.Project;
            }
            else if (!disposed) Ui.Show(HarnessNotice, "No asset was placed. If the edit changed, ask for a new timeline proposal.", InfoBarSeverity.Warning);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception) { if (!disposed) Ui.Show(HarnessNotice, "Couldn't prepare the asset. Nothing was placed.", InfoBarSeverity.Warning); }
        finally { harnessAssetWorking = false; if (!disposed) UpdateHarnessButtons(); }
    }

    private bool HarnessMusicClipExists(HarnessMusicAction action) => ViewModel.Project.Media.Source.ContentKey == action.SourceKey &&
        ViewModel.Project.Edits.Clips.Any(clip => clip.Id == action.ClipId);

    private MusicCandidate? CurrentHarnessQuote => harnessQuote is { } quote && ReferenceEquals(quote.Project, ViewModel.Project) &&
        DateTimeOffset.UtcNow < quote.Expires ? quote.Candidate : null;

    private void ShowHarnessMusic()
    {
        HarnessMusicCard.Visibility = harnessMusic is null ? Visibility.Collapsed : Visibility.Visible;
        if (harnessMusic is not { } action) return;
        var clipExists = HarnessMusicClipExists(action);
        var inScope = ViewModel.Project.Edits.ActiveClipId == action.ClipId;
        var price = CurrentHarnessQuote?.Estimate is { } estimate ? MusicPricing.Label(estimate) : null;
        var usingMusic = ViewModel.Music.Phase == MusicPanelPhase.Using;
        var blocked = ViewModel.HarnessKeepBlocked;
        HarnessMusicPrompt.Text = action.Prompt;
        HarnessMusicNote.Text = harnessSubmitted
            ? usingMusic ? "Generating music…" : ViewModel.Music.Failure ?? "Review the result in Music."
            : !clipExists ? "The clip changed. Ask for a new music proposal."
            : !inScope ? "Open the proposed clip to confirm the price."
            : harnessPricing ? "Checking the price…"
            : blocked ?? (price is null ? harnessPriceIssue ?? "Confirm a price before generating music." : "This sends the brief to Eleven Music.");
        HarnessGenerateMusic.Content = price is null ? "Generate music" : $"Generate music · {price}";
        HarnessGenerateMusic.IsEnabled = !harnessSubmitted && !harnessPricing && clipExists && inScope && blocked is null && price is not null;
        HarnessGenerateMusic.Visibility = harnessSubmitted ? Visibility.Collapsed : Visibility.Visible;
        HarnessMusicNext.Content = inScope ? "Get price" : "Open clip";
        HarnessMusicNext.Visibility = !harnessSubmitted && clipExists && (!inScope || price is null) ? Visibility.Visible : Visibility.Collapsed;
        HarnessMusicNext.IsEnabled = !harnessPricing && blocked is null && musicSuggestions is not null;
        HarnessMusicDismiss.Content = harnessSubmitted ? "Done" : "Dismiss";
        HarnessMusicDismiss.IsEnabled = !harnessSubmitted || !usingMusic;
    }

    private async void HarnessMusicNextClicked(object sender, RoutedEventArgs args)
    {
        if (disposed || harnessMusic is not { } action || harnessPricing || harnessSubmitted || !HarnessMusicClipExists(action) ||
            ViewModel.HarnessKeepBlocked is not null || musicSuggestions is not { } suggestions) return;
        if (ViewModel.Project.Edits.ActiveClipId != action.ClipId)
        {
            SelectScope(action.ClipId);
            UpdateHarnessButtons();
            return;
        }
        var snapshot = ViewModel.Project;
        var expires = DateTimeOffset.UtcNow + ElevenMusicClient.QuoteLifetime;
        harnessPricing = true;
        ShowHarnessMusic();
        try
        {
            var (candidate, note) = await suggestions.PriceGenerationAsync(new("", Prompt: action.Prompt), ViewModel.Music.ScopeSeconds, lifetime.Token);
            if (!disposed && ReferenceEquals(harnessMusic, action) && ReferenceEquals(snapshot, ViewModel.Project))
            {
                harnessQuote = candidate is null ? null : (candidate, snapshot, expires);
                harnessPriceIssue = note;
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception exception) when (HarnessFileError(exception)) { harnessPriceIssue = "VoxClip couldn't confirm a price. Nothing was sent."; }
        finally { harnessPricing = false; if (!disposed) ShowHarnessMusic(); }
    }

    private async void HarnessGenerateMusicClicked(object sender, RoutedEventArgs args)
    {
        if (disposed || harnessSubmitted || harnessMusic is not { } action || !HarnessMusicClipExists(action) ||
            ViewModel.Project.Edits.ActiveClipId != action.ClipId || ViewModel.HarnessKeepBlocked is not null ||
            CurrentHarnessQuote is not { Estimate: { } estimate } candidate || MusicPricing.Label(estimate) is null) return;
        harnessSubmitted = true;
        var making = ViewModel.Music.UseAsync(candidate, forClipId: action.ClipId, timelineShape: action.TimelineShape);
        ShowHarnessMusic();
        await making;
        if (!disposed) ShowHarnessMusic();
    }

    private void HarnessMusicDismissClicked(object sender, RoutedEventArgs args)
    {
        if (harnessSubmitted && ViewModel.Music.Phase == MusicPanelPhase.Using) return;
        harnessMusic = null;
        harnessQuote = null;
        harnessPriceIssue = null;
        harnessSubmitted = false;
        UpdateHarnessButtons();
    }

    private static bool HarnessFileError(Exception exception) => exception is IOException or UnauthorizedAccessException or
        System.Text.Json.JsonException or ArgumentException or VoxClipException;
}
