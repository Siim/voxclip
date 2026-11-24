using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Controls;

internal sealed partial class RewritePanel
{
    private readonly StackPanel wholeClipBody = Ui.Stack(8);
    private readonly TextBlock wholeClipLine = Ui.Text("");
    private readonly TextBlock wholeClipKept = Ui.Text("");
    private readonly TextBlock wholeClipReasons = Ui.Text("");
    private readonly RadioButton wholeClipPhrasesChoice = new() { Content = "Only the changed phrases", GroupName = "RewriteVoiceChoice" };
    private readonly RadioButton wholeClipWholeChoice = new() { Content = "The whole take in your voice, lip-synced", GroupName = "RewriteVoiceChoice" };
    private readonly TextBlock wholeClipTransfer = Ui.Text("");
    private readonly TextBlock wholeClipScript = Ui.Text("");
    private readonly Expander wholeClipScriptView = new() { Header = "Full script" };
    private readonly Button wholeClipPrice = new();
    private readonly Button wholeClipRestore = new() { Content = "Recover saved whole-clip voice" };
    private readonly Button wholeClipApprove = new();
    private readonly Button wholeClipCancel = new() { Content = "Stop" };
    private readonly Button wholeClipVoice = new() { Content = "Play saved voice" };
    private readonly Button wholeClipOriginal = new() { Content = "Play original" };
    private readonly Button wholeClipCompare = new() { Content = "Compare with Your Recording" };
    private readonly Button wholeClipUse = new() { Content = "Use whole take" };
    private readonly Button wholeClipVoiceOnly = new() { Content = "Use voice without lip sync" };
    private readonly Button wholeClipSharper = new() { Content = "Sharper Lip Sync" };
    private readonly Button wholeClipRedoVoice = new() { Content = "Redo Voice and Lip Sync" };
    private readonly Button wholeClipRedoPicture = new() { Content = "Redo Lip Sync Only" };
    private readonly Button wholeClipOriginalRestore = new() { Content = "Back to My Recording" };
    private string announcedWholeClip = "";

    private void BuildWholeClip()
    {
        wholeClipBody.Children.Add(Ui.Text("How should it sound?", "BodyStrongTextBlockStyle"));
        wholeClipBody.Children.Add(wholeClipPhrasesChoice);
        wholeClipBody.Children.Add(wholeClipWholeChoice);
        wholeClipScriptView.Content = wholeClipScript;
        foreach (var element in new FrameworkElement[] { wholeClipKept, wholeClipLine, wholeClipPrice, wholeClipRedoVoice, wholeClipRedoPicture,
            wholeClipSharper, wholeClipOriginalRestore, wholeClipRestore, wholeClipScriptView, wholeClipTransfer, wholeClipApprove,
            wholeClipCancel, wholeClipVoice, wholeClipOriginal, wholeClipCompare, wholeClipUse, wholeClipVoiceOnly, wholeClipReasons })
            wholeClipBody.Children.Add(element);
        wholeClipPhrasesChoice.Click += (_, _) => session.SelectWholeClipIntent(null);
        wholeClipWholeChoice.Click += async (_, _) => await SelectAndPriceWholeClipAsync(WholeClipIntent.Revoice);
        wholeClipPrice.Click += async (_, _) => await SelectAndPriceWholeClipAsync(WholeClipIntent.Revoice);
        wholeClipRedoVoice.Click += async (_, _) => await SelectAndPriceWholeClipAsync(WholeClipIntent.RedoVoice);
        wholeClipRedoPicture.Click += async (_, _) => await SelectAndPriceWholeClipAsync(WholeClipIntent.RedoLipSync);
        wholeClipOriginalRestore.Click += (_, _) => session.BackToMyRecording();
        wholeClipRestore.Click += async (_, _) => await session.RestoreWholeClipAsync();
        wholeClipApprove.Click += async (_, _) => await session.MakeWholeClipAsync();
        wholeClipCancel.Click += (_, _) => session.InvalidateWholeClip();
        wholeClipVoice.Click += async (_, _) => await session.PlayWholeClipAsync(original: false, voiceOnly: true);
        wholeClipOriginal.Click += async (_, _) => await session.PlayWholeClipAsync(original: true);
        wholeClipCompare.Click += async (_, _) => await session.PlayWholeClipAsync(original: false);
        wholeClipUse.Click += (_, _) => session.ApplyWholeClip(voiceOnly: false);
        wholeClipVoiceOnly.Click += (_, _) => session.ApplyWholeClip(voiceOnly: true);
        wholeClipSharper.Click += async (_, _) => await SelectAndPriceWholeClipAsync(WholeClipIntent.Sharper);
    }

    private async Task SelectAndPriceWholeClipAsync(WholeClipIntent intent)
    {
        session.SelectWholeClipIntent(intent);
        await session.PriceWholeClipAsync(intent);
    }

    internal void FocusWholeClip(WholeClipIntent intent)
    {
        session.SelectWholeClipIntent(intent);
        wholeClipBody.StartBringIntoView();
        Control action = intent == WholeClipIntent.RedoVoice ? wholeClipRedoVoice : wholeClipWholeChoice;
        if (!action.Focus(FocusState.Programmatic) && !wholeClipCompare.Focus(FocusState.Programmatic)) FocusTarget.Focus(FocusState.Programmatic);
    }

    private void RenderWholeClip()
    {
        wholeClipBody.Visibility = session.OffersWholeClip || session.CanRestoreWholeClip ? Visibility.Visible : Visibility.Collapsed;
        if (wholeClipBody.Visibility != Visibility.Visible) return;
        var busy = session.WholeClipBusy;
        var saved = session.WholeClipVoice is not null;
        var kept = session.KeptWholeClip;
        var current = session.WholeClipReviewCurrent;
        var blocked = session.WholeClipBlocked;
        var offer = session.WholeClipPrice is { } prepared && session.WholeClipCurrent(prepared.Selection) ? prepared : null;
        wholeClipPhrasesChoice.IsChecked = session.SelectedWholeClipIntent is null;
        wholeClipWholeChoice.IsChecked = session.SelectedWholeClipIntent is not null;
        wholeClipPhrasesChoice.IsEnabled = !busy;
        wholeClipWholeChoice.IsEnabled = !busy && blocked is null;
        AutomationProperties.SetHelpText(wholeClipWholeChoice, blocked ?? "");
        wholeClipPrice.Content = saved ? "Check lip-sync price" : "Check whole-clip price";
        wholeClipPrice.Visibility = kept is null ? Visibility.Visible : Visibility.Collapsed;
        wholeClipPrice.IsEnabled = !busy && blocked is null && offer is null;
        wholeClipKept.Text = kept is null ? "" : "Your whole take is lip-synced. Redo makes a new version. The one you have stays until you click Use on the new one.";
        wholeClipKept.Visibility = kept is null ? Visibility.Collapsed : Visibility.Visible;
        wholeClipRedoVoice.Visibility = wholeClipRedoPicture.Visibility = wholeClipOriginalRestore.Visibility = kept is null ? Visibility.Collapsed : Visibility.Visible;
        wholeClipRedoVoice.IsEnabled = wholeClipRedoPicture.IsEnabled = !busy && blocked is null;
        wholeClipOriginalRestore.IsEnabled = !busy && session.GenerationIsCurrent;
        wholeClipRestore.Visibility = session.CanRestoreWholeClip && !saved ? Visibility.Visible : Visibility.Collapsed;
        wholeClipRestore.IsEnabled = !busy;
        wholeClipLine.Text = busy || session.WholeClipStatus.Length > 0 ? session.WholeClipStatus : blocked ?? "";
        wholeClipScript.Text = session.WholeClipScriptText ?? "";
        wholeClipScriptView.Visibility = wholeClipScript.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        wholeClipTransfer.Text = offer?.Disclosure ?? "";
        wholeClipTransfer.Visibility = offer is null ? Visibility.Collapsed : Visibility.Visible;
        wholeClipApprove.Visibility = offer is null ? Visibility.Collapsed : Visibility.Visible;
        wholeClipApprove.IsEnabled = !busy && blocked is null && offer is not null;
        if (offer is not null)
        {
            var total = offer.VoicePrice + offer.Picture.Price;
            var action = offer.Selection.Intent switch
            {
                WholeClipIntent.RedoVoice => "Redo Voice and Lip Sync",
                WholeClipIntent.RedoLipSync => "Redo Lip Sync Only",
                WholeClipIntent.Sharper => "Sharper Lip Sync",
                _ => offer.VoicePrice > 0 ? "Revoice Whole Take" : "Continue Lip Sync",
            };
            var title = total == 0 ? "Recover lip sync · No new charge" : $"{action} · {VoiceLabCostPresentation.Format(total)}";
            wholeClipApprove.Content = title;
            SetName(wholeClipApprove, title);
        }
        wholeClipCancel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        wholeClipVoice.Visibility = wholeClipVoiceOnly.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
        wholeClipOriginal.Visibility = saved || kept is not null ? Visibility.Visible : Visibility.Collapsed;
        wholeClipVoice.IsEnabled = wholeClipVoiceOnly.IsEnabled = current;
        wholeClipOriginal.IsEnabled = !busy && session.GenerationIsCurrent;
        var useReason = session.WholeClipUseBlocked;
        var compareReason = session.WholeClipCompareBlocked;
        var sharperReason = session.WholeClipSharperBlocked;
        SetAvailability(wholeClipUse, useReason);
        SetAvailability(wholeClipCompare, compareReason);
        SetAvailability(wholeClipSharper, sharperReason);
        wholeClipReasons.Text = string.Join("\n", new[] { busy ? null : blocked, Reason(wholeClipUse, useReason), Reason(wholeClipCompare, compareReason), Reason(wholeClipSharper, sharperReason) }.OfType<string>().Distinct());
        wholeClipReasons.Visibility = wholeClipReasons.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (IsLoaded && wholeClipLine.Text != announcedWholeClip)
        {
            announcedWholeClip = wholeClipLine.Text;
            if (announcedWholeClip.Length > 0) Ui.Announce(this, announcedWholeClip, "whole clip", AutomationNotificationProcessing.MostRecent);
        }
    }

    private static string? Reason(Button action, string? reason) => reason is null ? null : $"{action.Content}: {reason}";
    private static void SetAvailability(Button action, string? reason)
    {
        action.IsEnabled = reason is null;
        AutomationProperties.SetHelpText(action, reason ?? "");
    }
}
