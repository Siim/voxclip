using Microsoft.UI.Xaml;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

internal static class VoiceLabDialogs
{
    internal static async Task<bool> TurnOnAsync(XamlRoot root, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var turnOn = VoiceLabSettingsState.TurnOn(App.Services.Settings.GetBool("voiceLab.betaNoticeAccepted") == true);
        var confirmed = !turnOn.ShowNotice || await Ui.ConfirmAsync(root, "Turn on Voice Lab?", VoiceLabCopy.BetaNotice, "Turn on", ct);
        foreach (var write in turnOn.WritesAfterNotice(confirmed)) await App.Services.SetAsync(write.Key, write.Value, ct);
        return confirmed;
    }
}
