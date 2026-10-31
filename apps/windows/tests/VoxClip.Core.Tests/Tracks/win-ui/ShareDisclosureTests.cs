#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Share;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Share;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The Export dialog's share text for exports with AI-modified speech (voice-lab §11.3–11.4), window-free.</summary>
public sealed class ShareDisclosureTests
{
    private const string Line = "Some words in this video were re-voiced with an AI copy of my own voice.";

    private static VoiceLabDisclosurePlan Plan(bool required, string? postText = Line) =>
        new(required, required ? ["tts"] : [], required ? 1.5 : 0, false, [], 0.25, VoiceLabLabelPosition.TopLeft, postText);

    [Fact]
    public void OnlyARequiredDisclosureCarriesAPostTextLine()
    {
        Assert.Equal(Line, ShareDisclosurePresentation.Line(Plan(true)));
        Assert.Null(ShareDisclosurePresentation.Line(Plan(false)));
        Assert.Null(ShareDisclosurePresentation.Line(Plan(true, null)));
        Assert.Null(ShareDisclosurePresentation.Line(null));
    }

    [Fact]
    public void TheCaptionFieldOpensWithTheLineAfterABlankLine()
    {
        var field = ShareDisclosurePresentation.FieldText("Clip one\n\nWe cut the long pause.  ", Line);
        Assert.Equal("Clip one\n\nWe cut the long pause.\n\n" + Line, field);
        Assert.Equal(field, ShareDisclosurePresentation.FieldText(field, Line));
        Assert.Equal("No AI here.", ShareDisclosurePresentation.FieldText("No AI here.", null));
        Assert.True(SharePostText.LinkedInLength(ShareDisclosurePresentation.FieldText(new string('a', 3000), Line)) <= 3000);
        Assert.EndsWith(Line, ShareDisclosurePresentation.FieldText(new string('a', 3000), Line));
    }

    [Fact]
    public void RemovingTheLineWarnsBeforeSharingAndRestoreLinePutsItBack()
    {
        var field = ShareDisclosurePresentation.FieldText("We cut the long pause.", Line);
        Assert.False(ShareDisclosurePresentation.NeedsWarning(field, Line));
        Assert.False(ShareDisclosurePresentation.NeedsWarning(field.Replace("\n\n", "   "), Line));
        var edited = "We cut the long pause. Some words were re-voiced.";
        Assert.True(ShareDisclosurePresentation.NeedsWarning(edited, Line));
        Assert.False(ShareDisclosurePresentation.NeedsWarning(edited, null));
        Assert.False(ShareDisclosurePresentation.NeedsWarning(ShareDisclosurePresentation.FieldText(edited, Line), Line));
        Assert.Equal("Your post no longer says the video contains AI-modified parts.", ShareDisclosure.RemovedWarning);
        Assert.Equal(("Share anyway", "Restore line"), (ShareDisclosure.ShareAnyway, ShareDisclosure.RestoreLine));
    }

    [Fact]
    public void OpenXKeepsTheLineLastAndShowsTheMadeWithAiTip()
    {
        var caption = ShareDisclosurePresentation.FieldText(string.Join(' ', Enumerable.Repeat("words", 80)), Line);
        var x = ShareDisclosurePresentation.ComposerText(ShareDisclosurePresentation.X, caption, Line);
        Assert.True(SharePostText.XWeight(x) <= 280);
        Assert.EndsWith("…\n\n" + Line, x);
        Assert.Equal(caption, ShareDisclosurePresentation.ComposerText(ShareDisclosurePresentation.LinkedIn, caption, Line));
        Assert.Equal("Turn on 'Made with AI' in the post's content disclosure before posting.", ShareDisclosurePresentation.Tip(ShareDisclosurePresentation.X, Line));
        Assert.Null(ShareDisclosurePresentation.Tip(ShareDisclosurePresentation.LinkedIn, Line));
        Assert.Null(ShareDisclosurePresentation.Tip(ShareDisclosurePresentation.X, null));
    }

    [Fact]
    public void ARemovedLineHoldsTheShareAndRestoreLinePutsItBackThenShares()
    {
        const string copy = ShareDisclosurePresentation.Copy, x = ShareDisclosurePresentation.X, linkedIn = ShareDisclosurePresentation.LinkedIn;
        var flow = new ShareDisclosureFlow();
        flow.Select(Line);
        var field = ShareDisclosurePresentation.FieldText("We cut the long pause.", Line);
        // With the line in place every action shares at once.
        foreach (var action in new[] { copy, x, linkedIn }) Assert.Equal(action, flow.Request(action, field));
        Assert.Null(flow.Pending);
        // Without it the action waits behind the warning; Restore line returns the caption with the line and the same action.
        const string edited = "We cut the long pause.";
        foreach (var action in new[] { copy, x, linkedIn })
        {
            Assert.Null(flow.Request(action, edited));
            Assert.Equal(action, flow.Pending);
            Assert.Equal<(string, string)?>((field, action), flow.RestoreLine(edited));
            Assert.Null(flow.Pending);
            Assert.False(ShareDisclosurePresentation.NeedsWarning(field, flow.Line));
        }
        Assert.Null(flow.RestoreLine(edited));
        // Share anyway shares the caption as it is, once.
        Assert.Null(flow.Request(copy, edited));
        Assert.Equal(copy, flow.ShareAnyway());
        Assert.Null(flow.ShareAnyway());
        // Choosing another export drops the held action; an export without AI-modified speech never warns.
        Assert.Null(flow.Request(linkedIn, edited));
        flow.Select(null);
        Assert.Null(flow.Pending);
        Assert.Equal(linkedIn, flow.Request(linkedIn, edited));
        Assert.Null(flow.Line);
    }

    [Fact]
    public void TheExportDialogUsesTheExportsDisclosureForEveryShareAction()
    {
        var app = Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App");
        var dialog = File.ReadAllText(Path.Combine(app, "Controls/ExportDialog.cs"));
        var helpers = File.ReadAllText(Path.Combine(app, "Services/ShareHelpers.cs"));
        Assert.DoesNotContain("ShareDestination.X, null", helpers);
        Assert.Contains("ShareDisclosurePresentation.ComposerText(destination, caption, disclosureLine)", helpers);
        Assert.Contains("ShareDisclosurePresentation.Line(job.Snapshot.VoiceLab?.Prepared.Disclosure)", dialog);
        Assert.Contains("caption.Text = ShareDisclosurePresentation.FieldText(model.Project.Share.Captions.GetValueOrDefault(shareId) ?? defaultCaption, line)", dialog);
        foreach (var action in new[] { "Copy", "X", "LinkedIn" })
            Assert.Contains($"() => Share(ShareDisclosurePresentation.{action})", dialog);
        Assert.DoesNotContain("ShareHelpers.Copy(caption.Text); Ui.Show(notice, \"Caption copied.\"); }))", dialog);
        Assert.Contains("ShareHelpers.OpenComposerAsync(destination, caption.Text, exported!, line)", dialog);
        // Every share click goes through the warning check before it shares.
        var share = Between(dialog, "private void Share(string action)", "private void ShareNow(string action)");
        Ordered(share, "if (shareFlow.Request(action, caption.Text) is { } now) { ShareNow(now); return; }", "ShareDisclosure.RemovedWarning");
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(share, @"ShareNow\(now\)"));
        // Share anyway shares the held action; Restore line puts the line back in the field, then shares.
        Ordered(share, "ShareDisclosure.ShareAnyway", "if (shareFlow.ShareAnyway() is { } held) ShareNow(held);");
        Ordered(share, "ShareDisclosure.RestoreLine", "shareFlow.RestoreLine(caption.Text) is not { } restored", "caption.Text = restored.Caption;",
            "ShareNow(restored.Action);");
        // Open X shows the "Made with AI" tip after the composer opens, with the export's line.
        Ordered(Between(dialog, "private async Task OpenComposerAsync(string destination)", "private async Task ChooseFolderAsync()"),
            "var line = shareFlow.Line;", "await ShareHelpers.OpenComposerAsync(destination, caption.Text, exported!, line);",
            "if (ShareDisclosurePresentation.Tip(destination, line) is { } tip) Ui.Show(notice, tip);");
        Assert.Contains("shareFlow.Select(line);", dialog);
    }

    private static string Between(string text, string start, string end)
    {
        var from = text.IndexOf(start, StringComparison.Ordinal);
        Assert.True(from >= 0, start);
        var to = text.IndexOf(end, from, StringComparison.Ordinal);
        Assert.True(to > from, end);
        return text[from..to];
    }

    private static void Ordered(string text, params string[] markers)
    {
        var at = 0;
        foreach (var marker in markers)
        {
            var next = text.IndexOf(marker, at, StringComparison.Ordinal);
            Assert.True(next >= 0, "Missing or out of order: " + marker);
            at = next + marker.Length;
        }
    }
}
#endif
