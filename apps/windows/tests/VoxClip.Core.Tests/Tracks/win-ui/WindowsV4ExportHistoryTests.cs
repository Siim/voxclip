#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class WindowsV4ExportHistoryTests
{
    private static Project Fixture(string name = "context-demo/v4-project.voxclip") => ProjectSerialization.Deserialize(File.ReadAllText(
        Path.Combine(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!, "fixtures", name)));

    [Fact]
    public void RemoveClipAndItsMotionUseOneUndoAndExactRedo()
    {
        var original = Fixture();
        var editor = new EditorViewModel(original, now: () => original.ModifiedAt);
        var before = ProjectSerialization.Serialize(editor.Project);
        var clip = original.Edits.Clips[0];
        Assert.True(editor.Apply(new EditOperation.RemoveClip(clip.Id)), editor.Notice);
        Assert.Empty(editor.Project.MotionCues);
        Assert.DoesNotContain(editor.Project.Edits.Clips, item => item.Id == clip.Id);
        Assert.Same(original.ContextDemo, editor.Project.ContextDemo);
        var after = ProjectSerialization.Serialize(editor.Project);
        editor.Undo();
        Assert.False(editor.CanUndo);
        Assert.Equal(before, ProjectSerialization.Serialize(editor.Project));
        editor.Redo();
        Assert.False(editor.CanRedo);
        Assert.Equal(after, ProjectSerialization.Serialize(editor.Project));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void SetTranscriptClearsVisualsWithAndWithoutPreviousWords(bool withoutWords)
    {
        var original = Fixture();
        var initial = withoutWords ? ProjectStore.ReplaceTranscript(original, original.Transcript!) with
        {
            Transcript = null, ContextDemo = original.ContextDemo
        } : original;
        var editor = new EditorViewModel(initial);
        editor.SetTranscript(original.Transcript! with { Refined = !original.Transcript!.Refined });
        Assert.Null(editor.Project.ContextDemo);
        Assert.Empty(editor.Project.MotionCues);
        Assert.False(editor.CanUndo);
        Assert.False(editor.CanRedo);
        ProjectSerialization.Deserialize(ProjectSerialization.Serialize(editor.Project));
    }

    [Fact]
    public void UnsupportedVisualIdentityCannotMatchAnOldSourceOnlyExport()
    {
        var original = Fixture();
        var sourceOnly = original with { ContextDemo = null, MotionCues = [] };
        var target = new ExportTarget.FullEdit();
        var baseline = ExportFingerprint.For(sourceOnly, target);
        foreach (var project in new[] { original, original with { MotionCues = [] }, original with { ContextDemo = null } })
        {
            var fingerprint = ExportFingerprint.For(project, target);
            Assert.Equal(64, fingerprint.Length);
            Assert.NotEqual(baseline, fingerprint);
            var editor = new EditorViewModel(project);
            editor.SetExportRecords([new(project.Id, "full", project.ModifiedAt, baseline, project.Captions.StyleId,
                project.Export.Aspect, Path.Combine(Path.GetTempPath(), "old-export.mp4"))]);
            Assert.Equal(ClipExportState.ChangedSinceExport, editor.ExportStatus(null).State);
        }
        var document = original.ContextDemo!;
        var moved = original with { ContextDemo = document with
        {
            Placements = document.Placements.SetItem(0, document.Placements[0] with { EditedStartSeconds = 2 })
        } };
        var changedMotion = original with { MotionCues = [original.MotionCues[0] with { SourceStart = 1.1 }] };
        Assert.NotEqual(ExportFingerprint.For(original, target), ExportFingerprint.For(moved, target));
        Assert.NotEqual(ExportFingerprint.For(original, target), ExportFingerprint.For(changedMotion, target));
        Assert.NotEqual(ExportFingerprint.For(original, target), ExportFingerprint.For(original, new ExportTarget.Clip(original.Edits.Clips[0].Id)));
        Assert.Equal(baseline, ExportFingerprint.For(original with { ContextDemo = original.ContextDemo! with { Placements = [] }, MotionCues = [] }, target));
    }

    [Fact]
    public void V4VoiceIdentityIncludesRecipesAndLabelPositionLikeV3()
    {
        var v3 = Fixture("voice-lab/passage-render-v3.voxclip");
        var v4 = v3 with { SchemaVersion = 4 };
        var target = new ExportTarget.FullEdit();
        Assert.Equal(ExportFingerprint.For(v3, target, VoiceLabLabelPosition.TopLeft), ExportFingerprint.For(v4, target, VoiceLabLabelPosition.TopLeft));
        Assert.NotEqual(ExportFingerprint.For(v4, target, VoiceLabLabelPosition.TopLeft), ExportFingerprint.For(v4, target, VoiceLabLabelPosition.BottomRight));
        Assert.True(VoiceLabDisclosure.Contains(() => v4, null));
        var disabled = VoiceLabProject.SetEnabled(v4, v4.VoiceLab.Segments[0].Id, false);
        Assert.NotEqual(ExportFingerprint.For(v4, target), ExportFingerprint.For(disabled, target));
        Assert.False(VoiceLabDisclosure.Contains(() => disabled, null));
        var clean = disabled with { VoiceLab = disabled.VoiceLab with { Segments = [],
            CleanAudio = new(VoiceLabCleanAudioMode.On, disabled.VoiceLab.Assets![0].Id, 1) } };
        Assert.Equal(VoiceLabProjectErrorCode.CleanAudioUnsupported,
            Assert.Throws<VoiceLabProjectException>(() => ExportFingerprint.For(clean, target)).Code);
        Assert.True(VoiceLabDisclosure.Contains(() => clean, null));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RelinkHistoryCannotRestoreVisualsFromAnInvalidatedSource(bool different)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-v4-relink-history-").FullName;
        try
        {
            var first = Path.Combine(directory, "first.mp4");
            var selected = Path.Combine(directory, "selected.mp4");
            await File.WriteAllTextAsync(first, "same synthetic source", TestContext.Current.CancellationToken);
            await File.WriteAllTextAsync(selected, different ? "different synthetic source" : "same synthetic source", TestContext.Current.CancellationToken);
            var store = new ProjectStore();
            var original = Fixture();
            var key = await store.ComputeContentKeyAsync(first, null, TestContext.Current.CancellationToken);
            original = original with { Media = new(original.Media.Source with { AbsolutePath = first, ContentKey = key, SizeBytes = new FileInfo(first).Length }),
                ContextDemo = original.ContextDemo! with { SourceContentKey = key } };
            var editor = new EditorViewModel(original);
            Assert.True(editor.Apply(new EditOperation.Correct("w1", "Corrected")), editor.Notice);
            Assert.True(editor.CanUndo);
            var picks = new Queue<string?>([selected, null]);
            Assert.True(await editor.RelinkAsync(store, Path.Combine(directory, "take.voxclip"), () => Task.FromResult(picks.Dequeue()),
                path => Task.FromResult(new MediaInfo(path, 7, original.Media.Source.Video, original.Media.Source.Audio,
                    new(1920, 1080), "h264", "aac", false, 0, 1, 0)), () => Task.FromResult(true), TestContext.Current.CancellationToken));
            Assert.True(editor.CanUndo);
            editor.Undo();
            Assert.Equal(different, editor.Project.ContextDemo is null);
            Assert.Equal(different, editor.Project.MotionCues.Count == 0);
            Assert.Equal(Path.GetFullPath(selected), editor.Project.Media.Source.AbsolutePath);
            Assert.Equal(original.Edits.Corrections.OrderBy(pair => pair.Key), editor.Project.Edits.Corrections.OrderBy(pair => pair.Key));
            Assert.True(editor.CanRedo);
            editor.Redo();
            Assert.Equal("Corrected", editor.Project.Edits.Corrections["w1"]);
            Assert.Equal(different, editor.Project.ContextDemo is null);
            Assert.Equal(different, editor.Project.MotionCues.Count == 0);
        }
        finally { Directory.Delete(directory, true); }
    }
}
#endif
