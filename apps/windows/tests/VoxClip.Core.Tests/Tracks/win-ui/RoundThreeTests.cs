#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Thumbnails;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class RoundThreeTests
{
    internal static Project Fixture()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var file = Path.Combine(directory.FullName, "shared", "fixtures", "projects", "interview-take.voxclip");
            if (File.Exists(file)) return ProjectSerialization.Deserialize(File.ReadAllText(file));
        }
        throw new FileNotFoundException("Shared project fixture not found.");
    }
    [Fact]
    public async Task MediaFaultBeforeAutosaveStillFlushesAcceptedEditsOnLeave()
    {
        var project = Fixture();
        var model = new EditorViewModel(project);
        var pending = new PendingProjectSave(project);
        model.Select(0); model.CutSelection(); pending.Mark(model.Project);
        model.SetMediaUnavailable(true);
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-save-fault-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var file = Path.Combine(directory, "take.voxclip");
        try
        {
            var store = new ProjectStore();
            var leave = new ProjectLeaveBoundary(model);
            await leave.BeginAsync(() => pending.FlushAsync((snapshot, ct) => store.SaveAsync(snapshot, file, ct), CancellationToken.None));
            var saved = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(file, TestContext.Current.CancellationToken));
            Assert.Contains(model.Words[0].Id, saved.Edits.CutWordIds);
            Assert.False(pending.HasChanges);
            Assert.True(leave.IsLeaving);
        }
        finally { Directory.Delete(directory, true); }
    }
    [Fact]
    public async Task FailedFaultedEditorSaveBlocksLeavingAndRetainsDirtyState()
    {
        var project = Fixture();
        var model = new EditorViewModel(project);
        var pending = new PendingProjectSave(project);
        model.Select(0); model.CutSelection(); pending.Mark(model.Project);
        model.SetMediaUnavailable(true);
        var leave = new ProjectLeaveBoundary(model);
        await Assert.ThrowsAsync<IOException>(() => leave.BeginAsync(() => pending.FlushAsync((_, _) => throw new IOException("Read-only test folder."), CancellationToken.None)));
        Assert.False(leave.IsLeaving);
        Assert.False(model.IsLeaving);
        Assert.True(pending.HasChanges);
    }
    [Fact]
    public async Task CompletingAnOlderSaveDoesNotAcknowledgeANewerEdit()
    {
        var project = Fixture(); var model = new EditorViewModel(project); var pending = new PendingProjectSave(project);
        model.Select(0); model.CutSelection(); pending.Mark(model.Project);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var saving = pending.FlushAsync(async (_, _) => await release.Task, TestContext.Current.CancellationToken);
        model.Select(2); model.CutSelection(); pending.Mark(model.Project);
        release.SetResult(); await saving;
        Assert.True(pending.HasChanges);
        Project? written = null;
        await pending.FlushAsync((snapshot, _) => { written = snapshot; return Task.CompletedTask; }, TestContext.Current.CancellationToken);
        Assert.Same(model.Project, written); Assert.False(pending.HasChanges);
    }
    [Theory]
    [InlineData("button")]
    [InlineData("Ctrl+E")]
    [InlineData("clip-row")]
    public void PlaybackFaultBlocksEveryExportEntryPointAfterSuccessfulProbe(string entry)
    {
        var model = new EditorViewModel(Fixture());
        model.Select(0); model.Select(3, true);
        var clip = model.MakeClip();
        var target = entry == "clip-row" ? clip : null;
        Assert.Null(model.ExportBlocked(false, false, target));
        model.SetMediaUnavailable(true);
        Assert.Equal("Locate the video to export.", model.ExportBlocked(false, false, target));
        Assert.False(model.CanExport);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void NineThousandWordTimelineHasABoundedRetainedScene(bool waveform)
    {
        var project = Fixture();
        var words = Enumerable.Range(0, 9000).Select(index => project.Transcript!.Words[0] with
            { Id = "long-" + index, Text = "word", Start = index * 0.4, End = index * 0.4 + 0.3 }).ToArray();
        var model = new EditorViewModel(project with
        {
            Transcript = project.Transcript! with { Words = words, DurationSeconds = 3600 },
            Media = new(project.Media.Source with { DurationSeconds = 3600 }),
            Edits = project.Edits with { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() }
        });
        var creates = 0;
        var pool = new TimelineRetainedPool<object>(_ => { creates++; return new object(); });
        var nodes = pool.Nodes.ToArray();
        var scene = new TimelineScene();
        var plan = TimelineLayout.Plan(model);
        scene.Build(model, plan, new(0, 3600), waveform ? Enumerable.Repeat(0.2f, 72000).ToArray() : [], 1200, false);
        Assert.True(creates + TimelineRetainedPool<object>.Badges * 2 + 16 <= TimelineRetainedPool<object>.ElementBound);
        Assert.True(scene.Layers.Sum(layer => layer.Count) < 9000);
        var version = scene.BuildVersion;
        pool.Move(new(100, 200)); pool.Move(new(101, 199));
        Assert.Equal(version, scene.BuildVersion);
        Assert.Equal(nodes.Length, creates);
        for (var index = 0; index < nodes.Length; index++) Assert.Same(nodes[index], pool.Nodes[index]);
        scene.Build(model, plan, new(2000, 2030), [], 1200, false);
        Assert.InRange(scene.VisitedWords, 1, 100);
        Assert.Equal(nodes.Length, creates);
    }
    [Fact]
    public void CurrentGalleryFramePreservesOpaqueBlackContent()
    {
        var bytes = new byte[16 * 9 * 4];
        for (var index = 3; index < bytes.Length; index += 4) bytes[index] = 255;
        var frame = CurrentFrames.Transform(new(bytes, 16, 9, 64), 0, new(9, 16));
        Assert.Equal(9, frame.Width); Assert.Equal(16, frame.Height);
        for (var index = 0; index < frame.Pixels.Length; index++) Assert.Equal(index % 4 == 3 ? (byte)255 : (byte)0, frame.Pixels.Span[index]);
    }
    [Theory]
    [InlineData(0, 9, 16, false)]
    [InlineData(0, 16, 16, false)]
    [InlineData(90, 9, 16, true)]
    public void CurrentGalleryFrameUsesOrientedExportCrop(int rotation, int width, int height, bool rotated)
    {
        var bytes = new byte[192 * 108 * 4];
        for (var row = 0; row < 108; row++)
            for (var column = 0; column < 192; column++)
            {
                var offset = (row * 192 + column) * 4;
                bytes[offset + (column < 42 ? 2 : column >= 150 ? 0 : 1)] = 255;
                bytes[offset + 3] = 255;
            }
        var frame = CurrentFrames.Transform(new(bytes, 192, 108, 768), rotation, new(width, height));
        var center = (height / 2 * frame.Stride) + width / 2 * 4;
        Assert.Equal(255, frame.Pixels.Span[center + 1]);
        if (rotated)
        {
            Assert.Equal(255, frame.Pixels.Span[width / 2 * 4 + 2]);
            Assert.Equal(255, frame.Pixels.Span[(height - 1) * frame.Stride + width / 2 * 4]);
        }
        else
            for (var row = 0; row < height; row++)
                for (var column = 0; column < width; column++) Assert.Equal(255, frame.Pixels.Span[row * frame.Stride + column * 4 + 1]);
    }
    [Theory]
    [InlineData(0.512, 0.34, 0.5, 1.0 / 3)]
    [InlineData(-0.1, 1.2, 0, 1)]
    [InlineData(0.36, 0.65, 0.36, 2.0 / 3)]
    public void CaptionDragSnapsAndClampsExactlyLikeTheMac(double horizontal, double vertical, double expectedX, double expectedY)
    {
        Assert.Equal(new CaptionPosition(expectedX, expectedY), CaptionDragGeometry.Snap(horizontal, vertical));
    }
    [Fact]
    public void CaptionDragStoresPerAspectOutsideOverridesAndUndoesOnce()
    {
        var model = new EditorViewModel(Fixture());
        var original = model.Project.Captions;
        var anchor = CaptionDragGeometry.Snap(0.512, 0.34);
        model.MoveCaptionAnchor(anchor);
        var preset = CaptionFineTune.Preset(model.Project)!;
        Assert.Equal(anchor, model.Project.Captions.PositionByAspect[preset]);
        Assert.Equal(original.Overrides.GetRawText(), model.Project.Captions.Overrides.GetRawText());
        var saved = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(model.Project));
        Assert.Equal(anchor, saved.Captions.PositionByAspect[preset]);
        model.Undo(); Assert.Equal(original, model.Project.Captions); Assert.False(model.CanUndo);
        model.Redo(); Assert.Equal(anchor, model.Project.Captions.PositionByAspect[preset]);
        var zones = CaptionDragGeometry.Zones(1080, 1920);
        Assert.Equal(0.12, zones[0].Height); Assert.Equal(0.22, zones[1].Height);
    }
    [Theory]
    [InlineData(false, "Video not found", "Can't find take.mp4. Edits are saved.", "video not found")]
    [InlineData(true, "Can't read this video", "Can't read take.mp4. Edits are saved.", "video can't be read")]
    public void MissingAndCorruptStagesUseExactCopyAndStatefulAccessibleNames(bool corrupt, string title, string notice, string suffix)
    {
        var state = corrupt ? EditorMediaState.Corrupt : EditorMediaState.Missing;
        Assert.Equal(title, EditorMediaPresentation.Title(state));
        Assert.Equal(notice, EditorMediaPresentation.Notice(state, "take.mp4"));
        Assert.Equal("Video preview, clip 2, contains AI-modified speech, " + suffix, EditorMediaPresentation.Accessible(state, 2, true));
        Assert.Equal("take.mp4", EditorMediaPresentation.FileName("C:" + (char)92 + "take.mp4"));
        Assert.Equal(0.38, EditorMediaPresentation.MessageFraction(true));
        Assert.Equal(0.36, EditorMediaPresentation.MessageFraction(false));
    }
    [Fact]
    public void MissingMediaRetainsTheExplicitCaptionPositionExceptionToReadOnly()
    {
        var model = new EditorViewModel(Fixture());
        model.SetMediaUnavailable(true);
        var before = model.Project.Captions;
        model.MoveCaptionAnchor(new(0.5, 1.0 / 3));
        Assert.NotEqual(before, model.Project.Captions);
        model.Undo(); Assert.Equal(before, model.Project.Captions);
        Assert.False(model.CanExport);
    }
    [Fact]
    public void KeyboardPositionUsesTheSameUndoableAnchorTargetWithMissingMedia()
    {
        var model = new EditorViewModel(Fixture()); model.SetMediaUnavailable(true);
        var before = model.Project.Captions;
        model.MoveCaptionPosition(0);
        Assert.Equal(new CaptionPosition(0.5, 0.2), CaptionFineTune.StoredPosition(model.Project));
        model.Undo(); Assert.Equal(before, model.Project.Captions);
        var project = Fixture();
        var untranscribed = new EditorViewModel(project with { Transcript = null });
        untranscribed.MoveCaptionPosition(1);
        Assert.Equal(new CaptionPosition(0.5, 0.5), CaptionFineTune.StoredPosition(untranscribed.Project));
        untranscribed.Undo(); Assert.Equal(project.Captions, untranscribed.Project.Captions);
    }
    [Fact]
    public void SelectedNextLineCorrectionIsNotDroppedByPlatformWhitespaceRules()
    {
        var model = new EditorViewModel(Fixture()); model.Select(0);
        model.Correct(((char)0x0085).ToString());
        Assert.Equal(((char)0x0085).ToString(), model.State!.Corrections[model.Words[0].Id]);
    }
    [Fact]
    public void TranscriptDecorationStatesAreIndependentAndCutWinsOutsideScope()
    {
        var state = TranscriptWordDecoration.For(true, true, true, true, true, "um");
        Assert.Equal("VcWordCutBrush", state.Foreground);
        Assert.True(state.Filler && state.LowConfidence && state.Corrected);
        Assert.Contains("Heard as: um", state.Tooltip); Assert.Contains("Filler · Delete to cut", state.Tooltip);
        Assert.Equal(" ‖ 1.8s ", TranscriptWordDecoration.VisiblePause("pause 1.8s"));
        Assert.Equal("pause 1.8 seconds, cut", TranscriptWordDecoration.PauseName("pause 1.8s", true));
        Assert.Equal("Demo project with no video. Changes aren't saved to the fixture.", EditorMediaPresentation.Notice(EditorMediaState.Demo, ""));
    }
    [Theory]
    [InlineData(320)] [InlineData(360)] [InlineData(388)]
    public void CaptionTileColumnsExactlyFillTheInnerWidth(double column)
    {
        var inner = column - 33;
        var tile = CaptionFineTune.TileWidth(inner);
        Assert.Equal(inner, tile * 2 + 8);
    }
    [Fact]
    public void PreviewThisCutHasTwoSecondsOfContextAndRequiresPlayableSelection()
    {
        var model = new EditorViewModel(Fixture());
        Assert.False(model.CanPreviewCut);
        model.Select(2); model.Select(4, true);
        Assert.True(model.CanPreviewCut);
        Assert.Equal(Math.Max(0, model.Words[2].Start - 2), model.PreviewCutRange()!.Value.Start);
        Assert.Equal(Math.Min(model.Project.Media.Source.DurationSeconds, model.Words[4].End + 2), model.PreviewCutRange()!.Value.End);
        model.SetMediaUnavailable(true); Assert.False(model.CanPreviewCut);
    }
    [Fact]
    public void FocusCycleHasTheRequiredOrderAndWrapsBothWays()
    {
        Assert.Equal(new[] { EditorFocusRegion.Pane, EditorFocusRegion.CommandBar, EditorFocusRegion.Transcript, EditorFocusRegion.Viewer, EditorFocusRegion.Captions, EditorFocusRegion.Timeline }, FocusCycle.Regions(true));
        Assert.Equal(new[] { 1, 2, 3, 4, 5, 0 }, FocusCycle.NextIndices(0, 6, false));
        Assert.Equal(new[] { 5, 4, 3, 2, 1, 0 }, FocusCycle.NextIndices(0, 6, true));
        Assert.DoesNotContain(EditorFocusRegion.Viewer, FocusCycle.Regions(false));
        Assert.DoesNotContain(EditorFocusRegion.Captions, FocusCycle.Regions(false));
        Assert.True(ShortcutPolicy.PaneForwards("Ctrl+R"));
        foreach (var key in new[] { "Ctrl+K", "Ctrl+Shift+K", "Ctrl+Shift+I", "Ctrl+Enter", "F2", "Shift+F6", "[ / ]", "P  Preview This Cut" }) Assert.Contains(key, KeyboardHelp.Text);
        Assert.Equal(RewriteEntryPolicy.BuildEnabled, KeyboardHelp.Text.Contains("Ctrl+R  Rewrite", StringComparison.Ordinal));
    }
}
#endif
