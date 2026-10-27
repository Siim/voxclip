namespace VoxClip.App.ViewModels;

internal readonly record struct TranscriptWordDecoration(string Foreground, bool Filler, bool LowConfidence, bool Corrected, string Tooltip)
{
    internal static TranscriptWordDecoration For(bool cut, bool outside, bool filler, bool lowConfidence, bool corrected, string original) =>
        new(cut ? "VcWordCutBrush" : outside ? "VcTextSecondaryBrush" : "VcTextPrimaryBrush", filler, lowConfidence, corrected,
            string.Join(" · ", new[] { corrected ? "Heard as: " + original : null, filler ? "Filler · Delete to cut" : null, lowConfidence ? "Low confidence" : null }.Where(value => value is not null)));
    internal static string PauseDuration(string label) => label.StartsWith("pause ", StringComparison.Ordinal) ? label[6..] : label;
    internal static string VisiblePause(string label) => " ‖ " + PauseDuration(label) + " ";
    internal static string PauseName(string label, bool cut) => "pause " + PauseDuration(label).TrimEnd('s') + " seconds" + (cut ? ", cut" : "");
}
