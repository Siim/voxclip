using System.Text;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.Share;

/// <summary>The Voice Lab disclosure line in post text; voice-lab §11.3–11.4. The line itself comes only from
/// <see cref="VoiceLab.VoiceLabDisclosurePlan.PostText"/>.</summary>
public static class ShareDisclosure
{
    /// <summary>Shown before sharing when the caption no longer contains the line; voice-lab §11.3.</summary>
    public const string RemovedWarning = "Your post no longer says the video contains AI-modified parts.";

    /// <summary>The warning's button that shares the caption as it is.</summary>
    public const string ShareAnyway = "Share anyway";

    /// <summary>The warning's button that puts the line back with <c>SharePostText.FieldText</c>.</summary>
    public const string RestoreLine = "Restore line";

    /// <summary>The Open X checklist tip while disclosure is required; voice-lab §11.4.</summary>
    public const string XMadeWithAiTip = "Turn on 'Made with AI' in the post's content disclosure before posting.";

    /// <summary>True when the caption contains the line once both are NFC, every White_Space run is one space and the ends
    /// are trimmed. Any other edit to the line counts as removing it. An empty line counts as present.</summary>
    public static bool IsPresent(string caption, string line)
    {
        ArgumentNullException.ThrowIfNull(caption);
        ArgumentNullException.ThrowIfNull(line);
        var needle = CaptionTextRules.Raw(line);
        return needle.Length == 0 || CaptionTextRules.Raw(caption).Contains(needle, StringComparison.Ordinal);
    }

    /// <summary>The caption field text: the line after a blank line when it is not present, the caption cut so the text stays
    /// within the 3,000 scalars of <c>share.captions</c>; voice-lab §11.3. <c>SharePostText.FieldText</c> passes the loaded
    /// rules.</summary>
    internal static string FieldText(string savedOrDefault, string? line, ShareTextRules rules)
    {
        if (line is null || IsPresent(savedOrDefault, line)) return savedOrDefault;
        return rules.Fit(TrimEnd(EditingAlgorithms.WellFormed(savedOrDefault)), line, ShareDestination.LinkedIn);
    }

    /// <summary>The UTF-16 span of the line's last occurrence in NFC caption text, White_Space runs comparing equal.</summary>
    internal static (int Start, int End)? LastSpan(string line, string caption)
    {
        var needle = CaptionTextRules.Raw(line);
        if (needle.Length == 0) return null;
        var collapsed = new StringBuilder(caption.Length);
        var spans = new List<(int Start, int End)>(caption.Length);
        for (var index = 0; index < caption.Length;)
        {
            var end = index + 1;
            if (CaptionTextRules.White(caption[index]))
            {
                while (end < caption.Length && CaptionTextRules.White(caption[end])) end++;
                collapsed.Append(' ');
            }
            else collapsed.Append(caption[index]);
            spans.Add((index, end));
            index = end;
        }
        var found = collapsed.ToString().LastIndexOf(needle, StringComparison.Ordinal);
        return found < 0 ? null : (spans[found].Start, spans[found + needle.Length - 1].End);
    }

    internal static string TrimEnd(string text)
    {
        var end = text.Length;
        while (end > 0 && CaptionTextRules.White(text[end - 1])) end--;
        return text[..end];
    }

    internal static string TrimStart(string text)
    {
        var start = 0;
        while (start < text.Length && CaptionTextRules.White(text[start])) start++;
        return text[start..];
    }

}
