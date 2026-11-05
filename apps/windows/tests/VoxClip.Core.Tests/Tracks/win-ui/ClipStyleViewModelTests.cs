#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The clip style card on Windows (design §6.6): shown once when the project has clips, folded by a choice and
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
    public void EachClipKeepsItsOwnStyleAndTheUsersChoiceIsTheActiveClipsPick()
    {
        var (model, catalog, library) = Open();
        var picks = new Dictionary<string, ClipCaptionPick> { ["clip-b"] = new("minimal", "Quiet story.") };
        model.ChooseClipStyle(catalog.Find("auto").Style.Recording(picks), library, collapse: true);
        // Claude's pick shows for clip-b; the project default stays (no more copying the pick into captions.styleId).
        Assert.Equal(("minimal", "box-highlight"), (model.CaptionStyleId, model.Project.Captions.StyleId));
        Assert.Equal("This clip: Minimal · Claude's pick", model.CaptionStyleSource(id => id == "minimal" ? "Minimal" : id));
        // The user's choice with clip-b active is clip-b's own, one undo step; clip-a and the default are unchanged.
        model.SetCaptionStyle("marker");
        Assert.Equal(("marker", "box-highlight", "auto"), (model.CaptionStyleId, model.Project.Captions.StyleId, model.Project.ClipStyle!.Captions));
        Assert.Equal("This clip: marker · your pick", model.CaptionStyleSource(id => id));
        Assert.Equal("box-highlight", ClipCaptionStyles.StyleId(model.Project, "clip-a"));
        Assert.True(model.SetScope("clip-a"));
        Assert.Equal(("box-highlight", "Project default"), (model.CaptionStyleId, model.CaptionStyleSource(id => id)));
        // With no clip active the choice changes the project default, which clips without a pick follow.
        Assert.True(model.SetScope(null));
        model.SetCaptionStyle("glow");
        Assert.Equal(("glow", "glow", "marker"), (ClipCaptionStyles.StyleId(model.Project, "clip-a"), model.Project.ClipStyle!.Captions, ClipCaptionStyles.StyleId(model.Project, "clip-b")));
        model.Undo();
        Assert.Equal(("box-highlight", "marker"), (model.Project.Captions.StyleId, ClipCaptionStyles.StyleId(model.Project, "clip-b")));
        model.Undo();
        Assert.Equal("minimal", ClipCaptionStyles.StyleId(model.Project, "clip-b"));
    }

    [Fact]
    public void ExportAllRoutesThreeClipsToThreeStylesAndFingerprintsEachClipsOwn()
    {
        var root = SharedRoot();
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(root, "fixtures", "projects", "clip-from-long-take.voxclip")));
        var words = project.Transcript!.Words;
        ClipRange[] clips = [new("clip-a", words[0].Id, words[2].Id, "Hook", ClipOrigin.Manual, null, null, true),
                             new("clip-b", words[3].Id, words[5].Id, "Story", ClipOrigin.Manual, null, null, true),
                             new("clip-c", words[6].Id, words[8].Id, "End", ClipOrigin.Manual, null, null, true)];
        var picks = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal) { ["clip-a"] = new("punch-in", "Fast."), ["clip-b"] = new("minimal", "Calm.") };
        var model = new EditorViewModel(project with { ClipStyle = ClipStyleCatalog.Load(root).Find("auto").Style with { CaptionPicks = picks },
            Captions = project.Captions with { StyleId = "box-highlight" }, Edits = project.Edits with { Clips = clips, ActiveClipId = null } });
        var route = new ExportDialogRouting(model, null, ExportDialogRouting.Scopes(null).ToList().IndexOf(ExportScopeKind.AllClips), 0, 0, false, Path.GetTempPath(), "{clip}");
        Assert.Equal(3, route.Targets.Count);
        // Each routed job renders its own clip (EditorPage.SnapshotAsync resolves the scoped project's active clip).
        var styles = route.Targets.Select(target =>
        {
            var scoped = ExportRenderInput.ScopedProject(route.Project, route.State(target));
            return ClipCaptionStyles.StyleId(scoped, scoped.Edits.ActiveClipId);
        }).ToArray();
        Assert.Equal(["punch-in", "minimal", "box-highlight"], styles);
        // A clip's pick is part of its fingerprint only: changing clip-a's style leaves clip-b's export current.
        var a = new VoxClip.Core.Domain.Shared.ExportTarget.Clip("clip-a");
        var b = new VoxClip.Core.Domain.Shared.ExportTarget.Clip("clip-b");
        var before = route.Project;
        var after = ClipCaptionStyles.Choosing(before, "clip-a", "glow");
        Assert.NotEqual(ExportFingerprint.For(before, a), ExportFingerprint.For(after, a));
        Assert.Equal(ExportFingerprint.For(before, b), ExportFingerprint.For(after, b));
        // Without picks the fingerprint is the one an older build recorded.
        var plain = before with { ClipStyle = before.ClipStyle! with { CaptionPicks = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal) } };
        Assert.Equal(ExportFingerprint.For(plain with { ClipStyle = null }, a), ExportFingerprint.For(plain, a));
    }
}
#endif
