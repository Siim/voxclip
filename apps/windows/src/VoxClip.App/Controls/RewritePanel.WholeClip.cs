using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Controls;

internal sealed partial class RewritePanel
{
    private readonly StackPanel wholeClipBody = Ui.Stack(8);
    private readonly TextBlock wholeClipLine = Ui.Text("");
    private readonly TextBlock wholeClipTransfer = Ui.Text("");
    private readonly TextBlock wholeClipScript = Ui.Text("");
    private readonly Expander wholeClipScriptView = new() { Header = "Full script" };
    private readonly Button wholeClipPrice = new();
    private readonly Button wholeClipRestore = new() { Content = "Recover saved whole-clip voice" };
    private readonly Button wholeClipApprove = new();
    private readonly Button wholeClipCancel = new() { Content = "Stop" };
    private readonly Button wholeClipVoice = new() { Content = "Play saved voice" };
    private readonly Button wholeClipOriginal = new() { Content = "Play original" };
    private readonly Button wholeClipCompare = new() { Content = "Play lip sync" };
    private readonly Button wholeClipUse = new() { Content = "Use whole clip" };
    private readonly Button wholeClipVoiceOnly = new() { Content = "Use voice without lip sync" };
    private readonly Button wholeClipSharper = new() { Content = "Price sharper lip sync" };
    private string announcedWholeClip = "";

    private void BuildWholeClip()
    {
        wholeClipBody.Children.Add(Ui.Text("Whole-clip revoice", "BodyStrongTextBlockStyle"));
        wholeClipBody.Children.Add(Small("Say the edited clip in one voice, then match the picture to it."));
        wholeClipScriptView.Content = wholeClipScript;
        foreach (var element in new FrameworkElement[] { wholeClipLine, wholeClipPrice, wholeClipRestore, wholeClipScriptView, wholeClipTransfer, wholeClipApprove,
            wholeClipCancel, wholeClipVoice, wholeClipOriginal, wholeClipCompare, wholeClipUse, wholeClipVoiceOnly, wholeClipSharper })
            wholeClipBody.Children.Add(element);
        wholeClipPrice.Click += async (_, _) => await session.PriceWholeClipAsync(session.WholeClipReview is { } review
            ? WholeClipLipsyncValues.FromRawValue(review.Record.LipsyncModel) ?? WholeClipLipsync.Lipsync2 : WholeClipLipsync.Lipsync2);
        wholeClipRestore.Click += async (_, _) => await session.RestoreWholeClipAsync();
        wholeClipApprove.Click += async (_, _) => await session.MakeWholeClipAsync();
        wholeClipCancel.Click += (_, _) => session.InvalidateWholeClip();
        wholeClipVoice.Click += async (_, _) => await session.PlayWholeClipAsync(original: false, voiceOnly: true);
        wholeClipOriginal.Click += async (_, _) => await session.PlayWholeClipAsync(original: true);
        wholeClipCompare.Click += async (_, _) => await session.PlayWholeClipAsync(original: false);
        wholeClipUse.Click += (_, _) => session.ApplyWholeClip(voiceOnly: false);
        wholeClipVoiceOnly.Click += (_, _) => session.ApplyWholeClip(voiceOnly: true);
        wholeClipSharper.Click += async (_, _) => await session.PriceWholeClipAsync(WholeClipLipsync.Sync3);
    }

    private void RenderWholeClip()
    {
        wholeClipBody.Visibility = session.OffersWholeClip || session.CanRestoreWholeClip ? Visibility.Visible : Visibility.Collapsed;
        if (wholeClipBody.Visibility != Visibility.Visible) return;
        var busy = session.WholeClipBusy;
        var saved = session.WholeClipVoice is not null;
        var review = session.WholeClipReview;
        var current = session.WholeClipReviewCurrent;
        var blocked = session.WholeClipBlocked;
        var offer = session.WholeClipPrice is { } prepared && session.WholeClipCurrent(prepared.Selection) ? prepared : null;
        wholeClipPrice.Content = saved ? "Check lip-sync price" : "Check whole-clip price";
        wholeClipPrice.Visibility = session.OffersWholeClip ? Visibility.Visible : Visibility.Collapsed;
        wholeClipPrice.IsEnabled = !busy && blocked is null && offer is null;
        wholeClipRestore.Visibility = session.CanRestoreWholeClip && !saved ? Visibility.Visible : Visibility.Collapsed;
        wholeClipRestore.IsEnabled = !busy;
        wholeClipLine.Text = busy || string.IsNullOrEmpty(session.WholeClipStatus) ? blocked ?? session.WholeClipStatus : session.WholeClipStatus;
        if (busy) wholeClipLine.Text = session.WholeClipStatus;
        wholeClipScript.Text = session.WholeClipScriptText ?? "";
        wholeClipScriptView.Visibility = wholeClipScript.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        wholeClipTransfer.Text = offer?.Disclosure ?? "";
        wholeClipTransfer.Visibility = offer is null ? Visibility.Collapsed : Visibility.Visible;
        wholeClipApprove.Visibility = offer is null ? Visibility.Collapsed : Visibility.Visible;
        wholeClipApprove.IsEnabled = !busy && blocked is null && offer is not null;
        if (offer is not null)
        {
            var total = offer.VoicePrice + offer.Picture.Price;
            var action = !saved ? "Revoice whole clip" : offer.Model == WholeClipLipsync.Sync3 ? "Sharper lip sync" : "Continue lip sync";
            var title = total == 0 ? "Recover lip sync · No new charge" : $"{action} · {VoiceLabCostPresentation.Format(total)}";
            wholeClipApprove.Content = title;
            SetName(wholeClipApprove, title);
        }
        wholeClipCancel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        wholeClipVoice.Visibility = wholeClipOriginal.Visibility = wholeClipVoiceOnly.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
        wholeClipVoice.IsEnabled = wholeClipOriginal.IsEnabled = wholeClipVoiceOnly.IsEnabled = current;
        wholeClipCompare.Visibility = wholeClipUse.Visibility = review is null ? Visibility.Collapsed : Visibility.Visible;
        wholeClipCompare.IsEnabled = wholeClipUse.IsEnabled = current;
        wholeClipSharper.Visibility = review?.Record.LipsyncModel == WholeClipLipsync.Lipsync2.RawValue() ? Visibility.Visible : Visibility.Collapsed;
        wholeClipSharper.IsEnabled = current && blocked is null;
        if (IsLoaded && wholeClipLine.Text != announcedWholeClip)
        {
            announcedWholeClip = wholeClipLine.Text;
            if (announcedWholeClip.Length > 0) Ui.Announce(this, announcedWholeClip, "whole clip", AutomationNotificationProcessing.MostRecent);
        }
    }
}
