#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The clip style card on Windows (design §6.9): shown once when the project has clips, folded by a choice and
/// reopened from the status bar item; a choice is one undo step; a caption style the user picks fixes the clip style's
/// captions so no AI pick replaces it.</summary>
public sealed class ClipStyleViewModelTests
{
    private static string SharedRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, "shared");
            if (File.Exists(Path.Combine(path, "data", "clip-styles.json"))) return path;
        }
        throw new DirectoryNotFoundException("shared");
    }

    private static (EditorViewModel Model, ClipStyleCatalog Catalog, IReadOnlySet<string> Library) Open()
    {
        var root = SharedRoot();
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(root, "fixtures", "projects", "clip-from-long-take.voxclip")));
        var words = project.Transcript!.Words;
        ClipRange[] clips = [new("clip-a", words[0].Id, words[3].Id, "Hook", ClipOrigin.Manual, null, null, true),
                             new("clip-b", words[4].Id, words[8].Id, "Story", ClipOrigin.Manual, null, null, true)];
        var model = new EditorViewModel(project with { ClipStyle = null, Captions = project.Captions with { StyleId = "box-highlight" },
            Edits = project.Edits with { Clips = clips, ActiveClipId = "clip-b" } });
        return (model, ClipStyleCatalog.Load(root), CaptionStyleLibrary.Load(root).Styles.Select(style => style.Id).ToHashSet(StringComparer.Ordinal));
    }

    [Fact]
    public void TheCardShowsOnceFoldsOnAChoiceAndReopensFromTheStatusItem()
    {
        var (model, catalog, library) = Open();
        Assert.True(model.ShowsClipStyleCard);
        Assert.Null(ClipStyleCard.StatusText(model.Project, catalog));
        model.ChooseClipStyle(catalog.Find("auto").Style, library, collapse: true);
        Assert.False(model.ShowsClipStyleCard);
        Assert.Equal("Style: Auto · ≤60 s · 16:9+9:16", ClipStyleCard.StatusText(model.Project, catalog));
        Assert.True(model.CanUndo);
        model.ClipStyleReopened = true;
        Assert.True(model.ShowsClipStyleCard);
        model.ChooseClipStyle(catalog.Find("punchy").Style, library, collapse: true);
        Assert.Equal(("punch-in", false), (model.Project.Captions.StyleId, model.ShowsClipStyleCard));
        model.Undo();
        Assert.Equal(("auto", "box-highlight"), (model.Project.ClipStyle!.Preset, model.Project.Captions.StyleId));
    }

    [Fact]
    public void AutoAppliesTheActiveClipsPickAndAChosenStyleIsNeverOverridden()
    {
        var (model, catalog, library) = Open();
        var picks = new Dictionary<string, ClipCaptionPick> { ["clip-b"] = new("minimal", "Quiet story.") };
        model.ChooseClipStyle(catalog.Find("auto").Style.Recording(picks), library, collapse: true);
        Assert.Equal("minimal", model.Project.Captions.StyleId);
        model.SetCaptionStyle("marker");
        Assert.Equal(("marker", "marker", "mine"), (model.Project.Captions.StyleId, model.Project.ClipStyle!.Captions, model.Project.ClipStyle.Preset));
        model.ApplyCaptionPick(library);
        Assert.Equal("marker", model.Project.Captions.StyleId);
    }
}
#endif
