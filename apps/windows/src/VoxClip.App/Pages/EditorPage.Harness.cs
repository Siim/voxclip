using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Music;
using VoxClip.Core.Services.Project;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    private DispatcherQueueTimer? harnessTimer;
    private bool readingHarness;
    private int harnessActionVersion;
    private HarnessProposal? harnessPending;
    private HarnessReviewDetails? harnessDetails;
    private string? harnessPath;
    private Project? harnessCheckedProject;
    private string? harnessReadIssue;
    private HarnessMusicAction? harnessMusic;
    private (MusicCandidate Candidate, Project Project, DateTimeOffset Expires)? harnessQuote;
    private bool harnessPricing;
    private bool harnessSubmitted;
    private string? harnessPriceIssue;

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
            harnessDetails = pending is null ? null : ViewModel.DescribeHarnessProposal(pending, App.Services.SharedRoot);
            if (newProposal) HarnessChanges.IsExpanded = false;
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

    private string? HarnessBlock => harnessDetails?.Blocked ?? ViewModel.HarnessKeepBlocked ??
        (harnessMusic is null ? null : "Finish or dismiss the music action first.");

    private void UpdateHarnessButtons()
    {
        var blocked = HarnessBlock;
        HarnessKeep.IsEnabled = blocked is null;
        HarnessUndo.IsEnabled = !ViewModel.IsLeaving;
        HarnessKeepReason.Text = blocked ?? "";
        HarnessKeepReason.Visibility = blocked is null ? Visibility.Collapsed : Visibility.Visible;
        ShowHarnessMusic();
    }

    private bool IsHarnessPath(string path) => string.Equals(owner.ProjectPath, path, StringComparison.OrdinalIgnoreCase);

    private void HarnessKeepClicked(object sender, RoutedEventArgs args) => ReviewHarness(keep: true);
    private void HarnessUndoClicked(object sender, RoutedEventArgs args) => ReviewHarness(keep: false);

    private void ReviewHarness(bool keep)
    {
        if (disposed || harnessPending is not { } pending || harnessPath is not { } path) return;
        ++harnessActionVersion;
        try
        {
            if (!IsHarnessPath(path)) throw new HarnessException("The pending timeline changed. Review it again.");
            if (keep)
            {
                if (HarnessBlock is not null || App.Services.SharedRoot is not { } root) return;
                harnessMusic = ViewModel.KeepHarnessProposal(pending, path, root);
            }
            else ViewModel.DismissHarnessProposal(pending, path);
            harnessPending = null;
            harnessDetails = null;
            HarnessNotice.IsOpen = false;
            ShowHarnessDetails();
            UpdateHarnessButtons();
        }
        catch (HarnessException exception) { Ui.Show(HarnessNotice, exception.Message, InfoBarSeverity.Warning); }
        catch (Exception exception) when (HarnessFileError(exception))
        { Ui.Show(HarnessNotice, "VoxClip couldn't finish this review. Your project is unchanged.", InfoBarSeverity.Warning); }
        _ = RefreshHarnessAsync();
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
        var making = ViewModel.Music.UseAsync(candidate, forClipId: action.ClipId);
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
