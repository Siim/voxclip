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

/// <summary>The Export dialog's share actions for the selected export, as on the Mac sheet (voice-lab §11.3): Copy caption,
/// Open X and Open LinkedIn share at once while the caption keeps the disclosure line. When the line was removed or edited the
/// action waits behind "Your post no longer says the video contains AI-modified parts." until [Share anyway] shares the
/// caption as it is or [Restore line] puts the line back and then shares.</summary>
internal sealed class ShareDisclosureFlow
{
    /// <summary>The selected export's post-text line, or null when it has no AI-modified speech.</summary>
    internal string? Line { get; private set; }
    /// <summary>The share action held behind the removal warning, or null.</summary>
    internal string? Pending { get; private set; }

    /// <summary>Select an export and its line. A held action is dropped, because its warning was about the other caption.</summary>
    internal void Select(string? line) { Line = line; Pending = null; }

    /// <summary>A share click: the action to perform now, or null when the removal warning shows first and holds it.</summary>
    internal string? Request(string action, string caption)
    {
        Pending = ShareDisclosurePresentation.NeedsWarning(caption, Line) ? action : null;
        return Pending is null ? action : null;
    }

    /// <summary>[Share anyway]: the held action, shared with the caption as it is; null when nothing is held.</summary>
    internal string? ShareAnyway()
    {
        var action = Pending;
        Pending = null;
        return action;
    }

    /// <summary>[Restore line]: the caption with the line put back (<c>SharePostText.FieldText</c>) and the held action to
    /// perform with it; null when nothing is held.</summary>
    internal (string Caption, string Action)? RestoreLine(string caption)
    {
        if (Pending is not { } action) return null;
        Pending = null;
        return (ShareDisclosurePresentation.FieldText(caption, Line), action);
    }
}
