using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Settings;

namespace VoxClip.App.ViewModels;

internal sealed record VoiceLabSettingWrite(string Key, bool Value);
internal sealed record VoiceLabTurnOn(bool ShowNotice, IReadOnlyList<VoiceLabSettingWrite> Writes)
{
    internal IReadOnlyList<VoiceLabSettingWrite> WritesAfterNotice(bool confirmed) => confirmed ? Writes : [];
}
internal sealed record VoiceLabLabelChoice(string Key, string Label);
internal sealed record VoiceLabCapInput(decimal? Amount, string? Canonical, string? Error);

internal static class VoiceLabSettingsState
{
    internal static bool PaneVisible => true;
    internal static VoiceLabTurnOn TurnOn(bool accepted) => new(!accepted,
        [new("voiceLab.betaNoticeAccepted", true), new("voiceLab.enabled", true)]);
    internal static IReadOnlyList<VoiceLabLabelChoice> LabelChoices { get; } = Array.AsReadOnly<VoiceLabLabelChoice>(
        [new("top-right", "Top right"), new("top-left", "Top left"), new("bottom-right", "Bottom right"), new("bottom-left", "Bottom left")]);
    internal static VoiceLabLabelPosition LabelPosition(string? value) => value switch
    {
        "top-left" => VoiceLabLabelPosition.TopLeft,
        "bottom-right" => VoiceLabLabelPosition.BottomRight,
        "bottom-left" => VoiceLabLabelPosition.BottomLeft,
        _ => VoiceLabLabelPosition.TopRight
    };
    internal static VoiceLabCapInput MonthlyCap(string text)
    {
        if (text.Length == 0) return new(null, null, null);
        if (!AppSettings.TryParseVoiceLabMonthlyCap(text, out var amount)) return new(null, null, VoiceLabCopy.CapError);
        var settings = new AppSettings("voxclip-settings/1");
        settings.SetVoiceLabMonthlyCap("elevenlabs", amount);
        return new(amount, settings.GetString("voiceLab.monthlyCapUsd.elevenlabs"), null);
    }
}
