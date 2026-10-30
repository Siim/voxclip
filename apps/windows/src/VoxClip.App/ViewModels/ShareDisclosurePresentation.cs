using VoxClip.Core.Domain.Share;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Share;

namespace VoxClip.App.ViewModels;

/// <summary>The AI disclosure in the Export dialog's share text; voice-lab §11.3–11.4. An export whose prepared Voice Lab render
/// requires disclosure carries its post-text line: the caption field opens with the line appended, Copy caption, Open X and
/// Open LinkedIn warn before sharing a caption that no longer has it, Open X keeps it last when the post is cut, and Open X shows
/// the "Made with AI" tip. Exports without AI speech have no line and share exactly as before.</summary>
internal static class ShareDisclosurePresentation
{
    /// <summary>The share actions the removal warning can hold back.</summary>
    internal const string Copy = "copy";
    internal const string X = "x";
    internal const string LinkedIn = "linkedin";

    /// <summary>The post-text line of an export's disclosure plan, or null when disclosure is not required.</summary>
    internal static string? Line(VoiceLabDisclosurePlan? plan) =>
        plan is { Required: true, PostText: { Length: > 0 } text } ? text : null;

    /// <summary>The caption field's text for the saved or default caption: the line appended after a blank line when it is
    /// required and missing (<c>SharePostText.FieldText</c>), else the caption unchanged.</summary>
    internal static string FieldText(string savedOrDefault, string? line) => SharePostText.FieldText(savedOrDefault, line);

    /// <summary>True when sharing must first show "Your post no longer says the video contains AI-modified parts." with
    /// [Share anyway] and [Restore line].</summary>
    internal static bool NeedsWarning(string caption, string? line) => line is not null && !ShareDisclosure.IsPresent(caption, line);

    /// <summary>The text a composer receives: X cuts a long caption and keeps the line last; LinkedIn gets the caption as is.</summary>
    internal static string ComposerText(string destination, string caption, string? line) => destination switch
    {
        X => SharePostText.ComposerText(caption, ShareDestination.X, line),
        LinkedIn => caption,
        _ => throw new ArgumentException("Unsupported share destination.", nameof(destination))
    };

    /// <summary>The Open X checklist tip while disclosure is required; null otherwise.</summary>
    internal static string? Tip(string destination, string? line) => destination == X && line is not null ? ShareDisclosure.XMadeWithAiTip : null;
}
