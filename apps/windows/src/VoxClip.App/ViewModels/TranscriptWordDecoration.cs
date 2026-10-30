namespace VoxClip.App.ViewModels;

internal readonly record struct TranscriptWordDecoration(string Foreground, bool Filler, bool LowConfidence, bool Corrected, string Tooltip)
{
    internal static IReadOnlyList<TranscriptSpeechWord> Speech(VoxClip.Core.Domain.Shared.Project project,
        IReadOnlyList<VoxClip.Core.Domain.Shared.TimedWord> words, IReadOnlyDictionary<string, string>? corrections)
    {
        var positions = words.Select((word, index) => (word.Id, Index: index)).ToDictionary(item => item.Id, item => item.Index, StringComparer.Ordinal);
        var presented = words.Select((word, index) => new TranscriptSpeechWord(corrections?.GetValueOrDefault(word.Id) ?? word.Text,
            false, false, true, index)).ToArray();
        foreach (var segment in project.VoiceLab.Segments.Where(segment => segment.Enabled))
        {
            if (!positions.TryGetValue(segment.Replace.FirstWordId, out var first) ||
                !positions.TryGetValue(segment.Replace.LastWordId, out var last) || last < first) continue;
            var replacement = segment.Words is { Count: > 0 } changed ? string.Join(" ", changed.Select(word => word.Text)) : null;
            for (var index = first; index <= last; index++)
            {
                presented[index] = new(replacement is null ? presented[index].Text : index == first ? replacement : "",
                    true, index == first, replacement is null || index == first, replacement is null ? index : last);
            }
        }
        return presented;
    }
    internal static TranscriptWordDecoration For(bool cut, bool outside, bool filler, bool lowConfidence, bool corrected, string original) =>
        new(cut ? "VcWordCutBrush" : outside ? "VcTextSecondaryBrush" : "VcTextPrimaryBrush", filler, lowConfidence, corrected,
            string.Join(" · ", new[] { corrected ? "Heard as: " + original : null, filler ? "Filler · Delete to cut" : null, lowConfidence ? "Low confidence" : null }.Where(value => value is not null)));
    internal static string PauseDuration(string label) => label.StartsWith("pause ", StringComparison.Ordinal) ? label[6..] : label;
    internal static string VisiblePause(string label) => " ‖ " + PauseDuration(label) + " ";
    internal static string PauseName(string label, bool cut) => "pause " + PauseDuration(label).TrimEnd('s') + " seconds" + (cut ? ", cut" : "");
}

internal readonly record struct TranscriptSpeechWord(string Text, bool AiModified, bool StartsSegment, bool Visible, int LastSourceIndex);
