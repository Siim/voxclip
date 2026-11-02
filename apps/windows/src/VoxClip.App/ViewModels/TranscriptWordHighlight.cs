namespace VoxClip.App.ViewModels;

internal readonly record struct TranscriptWordHighlight(string BackgroundBrush, string ForegroundBrush)
{
    internal static TranscriptWordHighlight? For(bool selected, bool playing, bool highContrast) => selected
        ? new(highContrast ? "VcSelectionTranscriptBrush" : "VcTintSelectionBrush", highContrast ? "SystemColorHighlightTextColor" : "VcTextPrimaryBrush")
        : null;
}
