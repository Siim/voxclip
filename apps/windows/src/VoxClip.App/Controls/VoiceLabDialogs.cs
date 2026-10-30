using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

internal static class VoiceLabDialogs
{
    internal static async Task<bool> ConfirmCreationAsync(XamlRoot root, VoiceCreationDialog spec, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var dialog = new ContentDialog { XamlRoot = root, Title = spec.Title, Content = Ui.Text(spec.Message),
            PrimaryButtonText = spec.Primary, CloseButtonText = spec.Close,
            DefaultButton = spec.PrimaryDefault ? ContentDialogButton.Primary : ContentDialogButton.Close };
        AutomationProperties.SetAutomationId(dialog, spec.Title == "Create voice" ? "voice-create-confirmation" : spec.PrimaryDefault ? "voice-verify-confirmation" : "voice-leave-confirmation");
        var showing = dialog.ShowAsync();
        try { return await showing.AsTask().WaitAsync(ct) == ContentDialogResult.Primary; }
        finally { if (ct.IsCancellationRequested) dialog.Hide(); }
    }
    internal static async Task<bool> TurnOnAsync(XamlRoot root, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var turnOn = VoiceLabSettingsState.TurnOn(App.Services.Settings.GetBool("voiceLab.betaNoticeAccepted") == true);
        var confirmed = !turnOn.ShowNotice || await Ui.ConfirmAsync(root, "Turn on Voice Lab?", VoiceLabCopy.BetaNotice, "Turn on", ct);
        foreach (var write in turnOn.WritesAfterNotice(confirmed)) await App.Services.SetAsync(write.Key, write.Value, ct);
        return confirmed;
    }
}
