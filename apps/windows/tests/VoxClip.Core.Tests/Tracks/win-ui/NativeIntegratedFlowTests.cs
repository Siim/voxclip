#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using VoxClip.Media.Captions;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class NativeIntegratedFlowTests
{
    [Fact]
    [Trait("Category", "RequiresWindows")]
    public async Task SyntheticImportEditCaptionExportSaveAndReopen()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("Native Windows media integration requires a Windows x64 or ARM64 host.");
        var root = Root();
        var source = Environment.GetEnvironmentVariable("VOXCLIP_UI_NATIVE_FIXTURE");
        if (string.IsNullOrWhiteSpace(source)) Assert.Skip("Set VOXCLIP_UI_NATIVE_FIXTURE to the committed synthetic bars video.");
        Assert.True(File.Exists(source));
        var ct = TestContext.Current.CancellationToken;
        var media = await new FfmpegMediaProbe().ProbeAsync(source, ct);
        Assert.NotNull(media.Video);
        var store = new ProjectStore();
        var key = await store.ComputeContentKeyAsync(source, null, ct);
        var template = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(Path.Combine(root, "shared", "fixtures", "projects", "interview-take.voxclip"), ct));
        var imported = template with
        {
            Id = Guid.NewGuid().ToString(),
            Title = "Synthetic bars",
            Media = new(new(source, Path.GetFileName(source), new FileInfo(source).Length, media.DurationSeconds, key, media.Video, media.Audio))
        };
        var words = new[]
        {
            Word("w1", "Your", 0.10, 0.40), Word("w2", "second", 0.52, 0.86),
            Word("w3", "story", 1.00, 1.30), Word("w4", "shines", 1.45, 1.82)
        };
        var transcript = new Transcript(1, words, "en", null, media.DurationSeconds,
            new(TranscriptEngine.Whispercpp, "synthetic-fixture", null, "fixture", "en"), true, false, 1,
            new string('a', 64), DateTimeOffset.UtcNow);
        imported = ProjectStore.ReplaceTranscript(imported, transcript);
        var model = new EditorViewModel(imported);
        model.SetCaptionStyle("vox-bold");
        model.Select(0); model.CutSelection();
        model.Select(2); model.Select(3, true);
        Assert.NotNull(model.MakeClip());
        var clip = Assert.Single(model.Clips);
        model.Apply(new EditOperation.SetActiveClip(clip.Id));
        var directory = Directory.CreateTempSubdirectory("voxclip-ui-native-").FullName;
        try
        {
            var projectPath = Path.Combine(directory, "Synthetic bars.voxclip");
            await store.SaveAsync(model.Project, projectPath, ct);
            var reopened = await store.LoadAsync(projectPath, ct);
            Assert.Equal(source, reopened.ResolvedMediaPath);
            Assert.Equal(clip.Id, reopened.Project.Edits.ActiveClipId);
            Assert.Contains("w1", reopened.Project.Edits.CutWordIds);
            var restored = new EditorViewModel(reopened.Project);
            var style = CaptionStyleLibrary.Load(Path.Combine(root, "shared")).Styles.Single(item => item.Id == "vox-bold");
            var fullTarget = Assert.Single(ExportSelection.Targets(ExportScopeKind.FullVideo, clip.Id, [clip.Id]));
            var selectedTarget = Assert.Single(ExportSelection.Targets(ExportScopeKind.ThisClip, clip.Id, [clip.Id]));
            Assert.Equal(selectedTarget, Assert.Single(ExportSelection.Targets(ExportScopeKind.AllClips, clip.Id, [clip.Id])));
            var full = await Export(restored, media, style, fullTarget, ExportAspect.Source, directory, root, ct);
            var selected = await Export(restored, media, style, selectedTarget, ExportAspect.Portrait, directory, root, ct);
            Assert.True(full.Duration > selected.Duration);
            Assert.True(full.WordCount > selected.WordCount);
            Assert.Contains("second", await File.ReadAllTextAsync(full.Srt, ct));
            Assert.DoesNotContain("second", await File.ReadAllTextAsync(selected.Srt, ct));
            Assert.Equal(clip.Id, restored.State!.ActiveClipId);
            var ledger = new ExportLedger(Path.Combine(directory, "exports.json"));
            await ledger.RecordAsync(restored.Project, selectedTarget, selected.Video, ct);
            restored.SetExportRecords(ledger.Records);
            Assert.Equal(ClipExportState.Exported, restored.ExportStatus(clip.Id).State);
            restored.Select(2); restored.CutSelection();
            Assert.Equal(ClipExportState.ChangedSinceExport, restored.ExportStatus(clip.Id).State);
            restored.Undo();
            Assert.Equal(ClipExportState.Exported, restored.ExportStatus(clip.Id).State);
            var persistedLedger = new ExportLedger(Path.Combine(directory, "exports.json"));
            await persistedLedger.LoadAsync(ct);
            Assert.Equal(selected.Video, Assert.Single(persistedLedger.Records).OutputPath);
            var evidence = Environment.GetEnvironmentVariable("VOXCLIP_UI_EVIDENCE_DIR");
            if (!string.IsNullOrWhiteSpace(evidence))
            {
                Directory.CreateDirectory(evidence);
                await File.WriteAllTextAsync(Path.Combine(evidence, "native-integrated-flow.json"), JsonSerializer.Serialize(new
                {
                    source = Path.GetFileName(source), projectReopened = true, savedCutWords = reopened.Project.Edits.CutWordIds.Count,
                    routes = new[] { "Full video", "This clip", "All clips" }, ledgerReloaded = true, exportedEditedUndo = true,
                    full = new { name = Path.GetFileName(full.Video), aspect = "Original", full.Duration, full.WordCount, bytes = new FileInfo(full.Video).Length, srtBytes = new FileInfo(full.Srt).Length },
                    clip = new { name = Path.GetFileName(selected.Video), aspect = "9:16", selected.Duration, selected.WordCount, bytes = new FileInfo(selected.Video).Length, srtBytes = new FileInfo(selected.Srt).Length }
                }), ct);
            }
        }
        finally { Directory.Delete(directory, true); }
    }

    private static TimedWord Word(string id, string text, double start, double end) =>
        new(id, text, WordKind.Word, start, end, start, end, null, null, TimingSource.Native);

    private static async Task<(string Video, string Srt, double Duration, int WordCount)> Export(EditorViewModel model, MediaInfo media,
        CaptionStyle style, ExportTarget target, ExportAspect aspect, string directory, string root, CancellationToken ct)
    {
        model.SetExport(model.Project.Export with { Aspect = aspect });
        var state = ExportSelection.Scope(model.State, target)!;
        var rate = media.Audio?.SampleRate ?? 48_000;
        var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, media.DurationSeconds), media.DurationSeconds, rate, state.PauseKeepSeconds);
        var words = EditingEngine.CaptionWords(state, plan);
        var size = ExportPresets.OutputSize(media.OrientedSize, aspect);
        var track = await CaptionEngine.BuildAsync(new(style, model.Project.Captions, size, words, "en", plan.Duration),
            new HarfBuzzGlyphShaper(Path.Combine(root, "shared")), null, ct);
        var fps = ExportPresets.OutputFrameRate(media.Video!.FrameRate);
        var snapshot = new ComposeSnapshot(media, plan, track,
            new(size, fps, ExportPresets.VideoBitrate(size, aspect, ExportQuality.Standard, fps)));
        var clipTitle = target is ExportTarget.Clip clip ? model.Clips.Single(item => item.Id == clip.Id).Title : null;
        var (video, sidecar) = ExportSelection.Paths(model.Title, clipTitle, aspect, true, directory, "{project}-{clip}-{aspect}");
        var srt = Assert.IsType<string>(sidecar);
        var result = await new Exporter().ExportAsync(new(snapshot, target, aspect, ExportQuality.Standard, video, srt), null, ct);
        Assert.True(File.Exists(video)); Assert.True(File.Exists(srt));
        Assert.True(result.Frames > 0);
        var probed = await new FfmpegMediaProbe().ProbeAsync(video, ct);
        Assert.NotNull(probed.Video);
        Assert.Equal(size.Width, probed.Video.Width);
        Assert.Equal(size.Height, probed.Video.Height);
        return (video, srt, result.DurationSeconds, words.Count);
    }

    private static string Root()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "shared", "fixtures", "media", "bars-1080p.mp4"))) return directory.FullName;
        throw new FileNotFoundException("Shared synthetic media fixture not found.");
    }
}
#endif
