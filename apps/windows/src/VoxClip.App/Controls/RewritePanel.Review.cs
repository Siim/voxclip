using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Controls;

internal sealed partial class RewritePanel
{
    private readonly ComboBox windowPicker = new() { Header = "Changed passage", HorizontalAlignment = HorizontalAlignment.Stretch };
    private RewriteReview? renderedReview;
    private int renderedFocus = -1;
    private bool renderedEditable;
    private int renderedPending;
    /// <summary>The reviews the rows show: Keep changes no review, only a row's "kept".</summary>
    private string renderedStates = "";
    private readonly HashSet<DependencyObject> reviewElements = [];
    private readonly StackPanel sentenceReview = Ui.Stack(8);
    private readonly StackPanel paidReviewChange = Ui.Stack(8);

    private void RenderPaidReviewChange()
    {
        paidReviewChange.Children.Clear();
        paidReviewChange.Visibility = session.PendingPaidReviewChange is null ? Visibility.Collapsed : Visibility.Visible;
        if (session.PendingPaidReviewChange is not { } pending || session.PaidReviewQuestion is not { } question)
        {
            SetName(paidReviewChange, RewritePaidReviewQuestion.Review.Name);
            return;
        }
        SetName(paidReviewChange, question.Name);
        paidReviewChange.Children.Add(Ui.Text(question.Question));
        paidReviewChange.Children.Add(Ui.Text(RewritePaidReviewQuestion.Detail));
        var cancel = Ui.Button(question.Cancel, session.CancelPaidReviewChange);
        var confirm = new Button { Content = question.Confirm, IsEnabled = session.ReviewIsCurrent &&
            !session.GenerationWindows.Any(window => window.IsRunning || window.IsPreparing) };
        SetName(cancel, question.Cancel); SetName(confirm, question.Confirm);
        AutomationProperties.SetAutomationId(cancel, "Rewrite.CancelPaidReviewChange");
        AutomationProperties.SetAutomationId(confirm, "Rewrite.ConfirmPaidReviewChange");
        confirm.Click += async (_, _) =>
        {
            if (!await session.ConfirmPaidReviewChangeAsync(pending) || !pending.Shorter || session.Prepared is not { } action) return;
            session.MarkEstimateShown(action);
            await SendProposalAsync();
        };
        paidReviewChange.Children.Add(cancel); paidReviewChange.Children.Add(confirm);
    }

    private async Task SendProposalAsync()
    {
        if (requestingApproval || session.Prepared is not { } action || !session.CanPropose) return;
        requestingApproval = true;
        App.Services.BusyOperations++;
        try
        {
            if (await ApproveProposalAsync(action) && session.IsOpen) await session.ProposeAsync(action, true);
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        { if (session.IsOpen) problem.Text = UiError.Message(exception, "Rewrite"); }
        finally { requestingApproval = false; App.Services.BusyOperations--; }
    }

    private async Task AskForShorterAsync(int ordinal)
    {
        if (requestingApproval || !await session.PrepareShorterAsync(ordinal) || session.Prepared is not { } action) return;
        session.MarkEstimateShown(action);
        await SendProposalAsync();
    }

    private void BuildWindowPicker()
    {
        AutomationProperties.SetAutomationId(windowPicker, "Rewrite.Passage");
        windowPicker.SelectionChanged += async (_, _) =>
        {
            if (!updating) await session.SelectWindowAsync(windowPicker.SelectedIndex);
        };
        generationBody.Children.Add(windowPicker);
    }

    private void RenderChangeReview()
    {
        var states = string.Join(",", session.ChangeStates.OrderBy(pair => pair.Key).Select(pair => $"{pair.Key}:{pair.Value}"));
        if (ReferenceEquals(renderedReview, session.Review) && renderedFocus == session.FocusedChange && renderedEditable == session.ReviewIsCurrent &&
            renderedPending == session.PendingExpressionCount && renderedStates == states) return;
        renderedPending = session.PendingExpressionCount;
        renderedStates = states;
        renderedReview = session.Review;
        renderedFocus = session.FocusedChange;
        renderedEditable = session.ReviewIsCurrent;
        brushes.RemoveAll(binding => reviewElements.Contains(binding.Target));
        reviewElements.Clear();
        review.Children.Clear();
        changeSummary.Text = session.Review?.ChangeSummary ?? "";
        if (session.Review is not { } current) return;
        review.Children.Add(new RewriteDiffLine(current));
        for (var index = 0; index < current.Diff.Hunks.Count; index++)
        {
            var ordinal = index + 1;
            var hunk = current.Diff.Hunks[index];
            var state = session.ChangeStates.GetValueOrDefault(ordinal);
            var included = state != TranscriptChangeState.Excluded;
            var row = Ui.Stack(6);
            AutomationProperties.SetAutomationId(row, "Rewrite.Change" + ordinal);
            // "kept" once reviewed, as the Mac's row says it (its trailing label).
            var title = new CheckBox { Content = $"Change {ordinal}" + (state == TranscriptChangeState.Kept ? " · kept" : "") + (session.FocusedChange == ordinal ? " · focused" : ""),
                IsChecked = included, IsEnabled = session.ReviewIsCurrent };
            SetName(title, $"Include change {ordinal} of {current.Diff.Hunks.Count}");
            title.Checked += (_, _) => { if (ReferenceEquals(current, session.Review)) { renderedReview = null; session.SetChangeIncluded(ordinal, true); } };
            title.Unchecked += (_, _) => { if (ReferenceEquals(current, session.Review)) { renderedReview = null; session.SetChangeIncluded(ordinal, false); } };
            row.Children.Add(title);
            if (hunk.Kind == VoiceLabDiffHunkKind.Voice)
            {
                var phraseNumber = current.VoiceHunks.ToList().FindIndex(phrase => phrase.Ordinals.Contains(ordinal)) + 1;
                row.Children.Add(ExpressionPhrase(string.Join(" ", hunk.NewTokens), session.ShownAudioTags(ordinal), Math.Max(1, phraseNumber),
                    tagIndex => session.RemoveExpression(ordinal, tagIndex), tag => session.AddExpression(ordinal, tag), ordinal));
            }
            else row.Children.Add(Ui.Text(hunk.Kind == VoiceLabDiffHunkKind.Cut ? "Remove these source words" : string.Join(" ", hunk.NewTokens)));
            if (session.ScopeHunks is { } metadata && index < metadata.Count)
            {
                var reason = Small(string.Join(" · ", metadata[index].Reasons));
                row.Children.Add(reason); reviewElements.Add(reason);
                if (metadata[index].CheckThis)
                {
                    var warning = Small("Check this change against the source.");
                    row.Children.Add(warning); reviewElements.Add(warning);
                }
            }
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var reveal = Ui.Button("Show in transcript", () => session.RevealChange?.Invoke(ordinal));
            var edit = Ui.Button("Edit", () => session.EditReviewChange?.Invoke(ordinal));
            SetName(reveal, $"Show change {ordinal} in transcript"); SetName(edit, $"Edit change {ordinal}");
            edit.IsEnabled = session.ReviewIsCurrent;
            actions.Children.Add(reveal); actions.Children.Add(edit); row.Children.Add(actions);
            var voiceHunk = current.VoiceHunks.FirstOrDefault(voice => voice.Ordinals.Contains(ordinal));
            var fitted = session.FitRowNote(ordinal);
            SetName(row, $"Change {ordinal} of {current.Diff.Hunks.Count}. {fitted ?? voiceHunk?.SpokenTiming}");
            if (fitted is not null)
            {
                var note = Small(fitted);
                AutomationProperties.SetAutomationId(note, "Rewrite.FitNote" + ordinal);
                reviewElements.Add(note); row.Children.Add(note);
            }
            if (included && voiceHunk?.Fit is { } fit && session.ShowsEstimate(ordinal))
            {
                var timing = Small(fit.Copy);
                reviewElements.Add(timing);
                timing.FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"];
                row.Children.Add(timing);
                if (!fit.Fits)
                {
                    row.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning,
                        Message = fit.TooLong ? VoiceLabRewriteFit.TooLongCopy : VoiceLabRewriteFit.TooShortCopy });
                    var shorter = new Button { Content = fit.TooLong ? "Ask for shorter" : "Ask for longer", IsEnabled = session.ReviewIsCurrent && !requestingApproval };
                    AutomationProperties.SetAutomationId(shorter, (fit.TooLong ? "Rewrite.Shorter" : "Rewrite.Longer") + ordinal);
                    shorter.Click += async (_, _) =>
                    {
                        if (!ReferenceEquals(current, session.Review)) return;
                        if (fit.TooLong) await AskForShorterAsync(ordinal);
                        else await session.AskForLongerAsync();
                    };
                    var surrounding = Ui.Button("Use surrounding sentence", () => { if (ReferenceEquals(current, session.Review)) session.ReviewSurroundingSentence(ordinal); });
                    AutomationProperties.SetAutomationId(surrounding, "Rewrite.Surrounding" + ordinal);
                    var keep = Ui.Button("Keep original words", () => { if (ReferenceEquals(current, session.Review)) session.SetChangeIncluded(ordinal, false); });
                    AutomationProperties.SetAutomationId(keep, "Rewrite.KeepOriginal" + ordinal);
                    var anyway = new HyperlinkButton { Content = "Price it anyway" };
                    AutomationProperties.SetAutomationId(anyway, "Rewrite.PriceAnyway" + ordinal);
                    anyway.Click += (_, _) => { if (ReferenceEquals(current, session.Review)) session.PriceItAnyway(ordinal); };
                    keep.IsEnabled = anyway.IsEnabled = surrounding.IsEnabled = session.ReviewIsCurrent;
                    row.Children.Add(shorter); row.Children.Add(surrounding); row.Children.Add(keep); row.Children.Add(anyway);
                }
            }
            else if (included && voiceHunk?.Refusal is { } refusal)
            {
                var refusalText = Small(refusal);
                reviewElements.Add(refusalText); row.Children.Add(refusalText);
            }
            review.Children.Add(row);
        }
        if (current.VoiceHunks.Count > 0)
        {
            review.Children.Add(Small(ExpressionNote));
            if (session.ReviewFooter.Length > 0) review.Children.Add(Small(session.ReviewFooter));
        }
        if (current.Summary is { } summary) review.Children.Add(Small(summary.Copy));
        if (current.VoiceHunks.Count > VoiceLabTakeBatch.MaximumRunPhrases)
            review.Children.Add(Small(RewriteSession.TooManyPhrasesCopy(current.VoiceHunks.Count)));
        foreach (var child in review.Children) reviewElements.Add(child);
    }

    private void RenderSentenceReview()
    {
        sentenceReview.Children.Clear();
        AutomationProperties.SetName(sentenceReview, "Generated speech context review");
        if (session.SentenceReview is { } captured)
        {
            sentenceReview.Children.Add(Ui.Text("Review surrounding sentence"));
            sentenceReview.Children.Add(Ui.Text($"Change {captured.Ordinal} · complete generated replacement"));
            sentenceReview.Children.Add(new TextBlock { Text = "“" + captured.Text + "”", IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });
            sentenceReview.Children.Add(Ui.Text(FormattableString.Invariant($"Source words {captured.Window.FirstWordId}–{captured.Window.LastWordId} · {captured.Window.Start:F3}–{captured.Window.End:F3} s · samples {captured.Window.StartSample}–{captured.Window.EndSample}")));
            sentenceReview.Children.Add(Ui.Text("This replaces the whole sentence, not just the changed word. It is not cropped back to the short phrase. Other changes and takes stay as they are."));
            sentenceReview.Children.Add(Ui.Text("The longer text and source window need a fresh TTS + bounded audio-check quote. Any unsent short-phrase approval is discarded. This review sends nothing and approves no charge; you must approve the new price separately."));
            var keep = Ui.Button("Keep short phrase", session.CancelSurroundingSentence);
            var accept = Ui.Button("Accept sentence for new quote", () => session.AcceptSurroundingSentence(captured));
            AutomationProperties.SetAutomationId(keep, "Rewrite.CancelSentence");
            AutomationProperties.SetAutomationId(accept, "Rewrite.AcceptSentence");
            keep.IsEnabled = accept.IsEnabled = session.ReviewIsCurrent && !session.GenerationWindows.Any(window => window.IsRunning || window.IsPreparing);
            sentenceReview.Children.Add(keep); sentenceReview.Children.Add(accept);
        }
        // A refused sentence is named in its next-steps card, with the chips that act on it.
        if (session.SentenceProblem.Length > 0 && session.SentenceProblem != RewriteSession.SentenceUnavailable)
            sentenceReview.Children.Add(Ui.Text(session.SentenceProblem));
        sentenceReview.Visibility = sentenceReview.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task<bool> ConfirmVoiceActionAsync(object snapshot, string detail, Func<bool> current, CancellationToken token)
    {
        if (approval is not null || !current()) return false;
        using var pending = new InlineApproval(new(Guid.NewGuid(), snapshot, "Generate reviewed takes?", session.TakeSendLine,
            detail, "Continue", true), current, token, Environment.TickCount);
        return await ShowVoiceApprovalAsync(pending);
    }

    private async Task<bool> AuthorizeVoiceAsync(CancellationToken token)
    {
        if (App.Services.Get("voiceLab.providerConsent.elevenlabs", false)) return true;
        if (approval is not null || !session.GenerationIsCurrent) return false;
        using var pending = new InlineApproval(new(Guid.NewGuid(), session.Project, "Use ElevenLabs?", RewriteGeneration.SendLine,
            VoiceLabCopy.ProviderConsent, "Allow", false), () => session.GenerationIsCurrent, token, Environment.TickCount);
        return await ShowVoiceApprovalAsync(pending);
    }

    private async Task<bool> ShowVoiceApprovalAsync(InlineApproval pending)
    {
        approval = pending;
        using var row = new InlineConfirmation(pending, () => RightColumn.RequestSourcePlayback(session.Editor));
        confirmation.Children.Clear(); confirmation.Children.Add(row);
        task.SetApproval(true); taskStatus.Text = task.Snapshot.Status;
        row.FocusTarget.Focus(FocusState.Programmatic);
        try { return await pending.Completion; }
        finally
        {
            if (ReferenceEquals(approval, pending)) { approval = null; confirmation.Children.Clear(); }
            task.SetApproval(false);
            if (session.IsOpen && IsLoaded) instruction.Focus(FocusState.Programmatic);
        }
    }

    private static async Task<VoiceLabMonthlyCap?> ReadVoiceCapAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        await WorkflowSpendCache.RefreshAsync(App.Services.Data);
        token.ThrowIfCancellationRequested();
        var limit = App.Services.Settings.GetVoiceLabMonthlyCap("elevenlabs");
        if (limit is null) return null;
        if (WorkflowSpendCache.Monthly is not { } total) throw new RewriteGenerationException("Monthly spend is unavailable. Nothing has been sent.");
        return new(limit.Value, total.Usd);
    }
}
