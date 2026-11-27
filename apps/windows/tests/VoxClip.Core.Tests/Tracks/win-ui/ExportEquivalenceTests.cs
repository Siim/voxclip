#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
#if !EXPORT_BASELINE
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
#endif
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Media.Captions;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class ExportEquivalenceTests
{
#if !EXPORT_BASELINE
    [Fact]
    [Trait("Category", "RequiresWindows")]
    public async Task PreviewMatchesDialogExportAcrossRecordings()
    {
        var destination = Environment.GetEnvironmentVariable("VOXCLIP_EXPORT_EQ_RECORDINGS");
        if (!OperatingSystem.IsWindows() || string.IsNullOrEmpty(destination)) Assert.Skip("Run export-equivalence.py --recordings-only on Windows.");
        var ct = TestContext.Current.CancellationToken;
        var input = await RecordingStoryFixture.CreateAsync(destination!, ct);
        var clipId = input.Project.Edits.ActiveClipId!;
        var model = new EditorViewModel(input.Project);
        var route = new ExportDialogRouting(model, clipId, ExportDialogRouting.Scopes(clipId).ToList().IndexOf(ExportScopeKind.ThisClip),
            EditorLayout.Frames.ToList().IndexOf(ExportAspect.Source), 0, false, destination!, "recordings");
        var shared = FixtureLoader.SharedRoot;
        var style = CaptionStyleLibrary.Load(shared).Styles.First(style => style.Id == "vox-highlight");
        var job = await route.JobAsync(Assert.Single(route.Targets), async (project, state, cancellation) =>
        {
            var media = ExportRenderInput.Media(project);
            var plan = ExportRenderInput.Plan(media, state);
            var clip = ClipRenderInput.Resolve(project, clipId, Path.Combine(destination!, "data"), shared);
            var output = ExportRenderInput.Output(media, project.Export, clip?.Controls);
            var settings = ClipCaptionStyles.Settings(project, clipId) with { StyleId = style.Id };
            var captions = await CaptionEngine.BuildAsync(new(style, settings, output.Size,
                ExportRenderInput.CaptionWords(project, state!, plan, null, clip?.Effects?.Effects), state!.Transcript.Language, plan.Duration),
                new HarfBuzzGlyphShaper(), null, cancellation);
            var snapshot = new ComposeSnapshot(media, plan, captions, output) { Clip = clip };
            return await RecordingRendering.BindAsync(project, snapshot, new ProjectStore(), input.Path, cancellation);
        }, ct);
        var snapshot = job.Snapshot;
        var result = await new Exporter().ExportAsync(job with { Loudness = ExportLoudness.Off }, null, ct);
        await using var preview = new PreviewEngine();
        await preview.LoadAsync(snapshot, null, ct);
        await using var frames = preview.ReadFramesAsync(ct).GetAsyncEnumerator(ct);
        var samples = new List<object>();
        var fps = snapshot.Output.FrameRate;
        var times = new[] { 0.0 }.Concat(snapshot.Plan.PartSeams.Select(sample => sample / snapshot.Plan.SampleRate));
        foreach (var start in times)
        {
            var frame = (int)Math.Ceiling(snapshot.Speed.Rendered(start + .12) * fps);
            await preview.SeekAsync(snapshot.Speed.Edited(frame / fps), true, ct);
            Assert.True(await frames.MoveNextAsync());
            var picture = frames.Current.Buffer;
            var file = $"preview-{frame}.bgra";
            await File.WriteAllBytesAsync(Path.Combine(destination!, file), picture.Pixels.ToArray(), ct);
            samples.Add(new { frame, file, picture.Width, picture.Height });
        }
        Assert.Equal(5, samples.Count);
        await File.WriteAllTextAsync(Path.Combine(destination!, "recordings.json"), JsonSerializer.Serialize(new { result.Output, samples }), ct);
    }

    [Fact]
    [Trait("Category", "RequiresWindows")]
    public async Task ExportTimelineMusicThroughTheDialogRouting()
    {
        var destination = Environment.GetEnvironmentVariable("VOXCLIP_EXPORT_EQ_TIMELINE");
        if (!OperatingSystem.IsWindows() || string.IsNullOrEmpty(destination)) Assert.Skip("Run export-equivalence.py --timeline-only on Windows.");
        var shared = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
        var source = Environment.GetEnvironmentVariable("VOXCLIP_EXPORT_EQ_SOURCE")!;
        var data = Path.Combine(destination!, "data");
        var ct = TestContext.Current.CancellationToken;
        var project = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(Path.Combine(shared, "fixtures", "projects", "interview-take.voxclip"), ct));
        var media = await new FfmpegMediaProbe().ProbeAsync(source, ct);
        project = project with
        {
            Media = new(project.Media.Source with { AbsolutePath = source, RelativePath = Path.GetFileName(source), SizeBytes = new FileInfo(source).Length }),
            Edits = project.Edits with { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [] },
            Export = project.Export with { Aspect = ExportAspect.Source, Srt = false }
        };
        var track = await File.ReadAllBytesAsync(Path.Combine(destination!, "music-timeline.flac"), ct);
        var asset = new MusicAsset(project.Id + "/music-timeline.flac", Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(track)), 4);
        var musicPath = MusicRenderInput.PathFor(asset, data);
        Directory.CreateDirectory(Path.GetDirectoryName(musicPath)!);
        await File.WriteAllBytesAsync(musicPath, track, ct);
        var original = new MusicSegment("whole", .5, 2, .5, false, FadeInSeconds: .4, FadeOutSeconds: .4);
        foreach (var split in new[] { false, true })
        {
            var segments = split ? new[] { original with { Id = "left", LengthSeconds = 1, FadeOutSeconds = 0 },
                original with { Id = "right", AnchorSeconds = 1.5, SongFromSeconds = 1.5, LengthSeconds = 1, FadeInSeconds = 0 } } : [original];
            var music = new ProjectMusic("timeline", null, asset, MusicSource.File, "Timeline", null, MusicLicense.Own,
                null, null, null, -12, false, 0, 0, 0, Segments: segments);
            var saved = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project with { Music = [music] }));
            Assert.Equal(6, saved.SchemaVersion);
            var model = new EditorViewModel(saved);
            var route = new ExportDialogRouting(model, null, ExportDialogRouting.Scopes(null).ToList().IndexOf(ExportScopeKind.FullVideo),
                EditorLayout.Frames.ToList().IndexOf(ExportAspect.Source), 0, false, destination!, split ? "split" : "unsplit");
            var target = Assert.Single(route.Targets);
            var job = await route.JobAsync(target, (captured, scopedState, cancellation) =>
                Task.FromResult(new ComposeSnapshot(media, ExportRenderInput.Plan(media, scopedState), null,
                    ExportRenderInput.Output(media, captured.Export))
                { Clip = ClipRenderInput.Resolve(captured, captured.Edits.ActiveClipId, data, shared) }), ct);
            Assert.Equal(segments.Length, job.Snapshot.Clip!.Music!.Entry.Segments!.Count);
            var result = await new Exporter().ExportAsync(job with { Loudness = ExportLoudness.Off }, null, ct);
            Assert.True(result.AudioSamples > 0);
            Assert.Equal(split ? "split.mp4" : "unsplit.mp4", Path.GetFileName(result.Output));
        }
    }
#endif

    [Fact]
    [Trait("Category", "RequiresWindows")]
    public async Task ExportTheSharedProjectThroughTheDialogRouting()
    {
        var destination = Environment.GetEnvironmentVariable("VOXCLIP_EXPORT_EQ_ROOT");
        if (!OperatingSystem.IsWindows() || string.IsNullOrEmpty(destination)) Assert.Skip("Run export-equivalence.py on Windows with the pinned FFmpeg test tools.");
        var shared = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
        var source = Environment.GetEnvironmentVariable("VOXCLIP_EXPORT_EQ_SOURCE")!;
        var ct = TestContext.Current.CancellationToken;
        var project = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(Path.Combine(shared, "fixtures", "projects", "interview-take.voxclip"), ct));
        var media = await new FfmpegMediaProbe().ProbeAsync(source, ct);
        Assert.Equal(7, media.DurationSeconds, 2);
        Assert.Equal(project.Media.Source.Video, media.Video);
        project = project with
        {
            Media = new(project.Media.Source with { AbsolutePath = source, RelativePath = Path.GetFileName(source), SizeBytes = new FileInfo(source).Length }),
            Edits = project.Edits with { Clips = [new("opening", "w1", "w3", "Opening", ClipOrigin.Manual, null, null, true), new("middle", "w4", "w8", "Middle / story", ClipOrigin.Manual, null, null, true), new("suggestion", "w9", "w9", "Suggested", ClipOrigin.Ai, null, null, false)] }
        };
        var style = CaptionStyleLibrary.Load(shared).Styles.Single(style => style.Id == project.Captions.StyleId);
        var rows = new List<object>();
        foreach (var aspect in new[] { ExportAspect.Source, ExportAspect.Landscape, ExportAspect.Portrait, ExportAspect.Square })
        foreach (var scope in new[] { "full", "all", "this" })
        {
            var folder = Path.Combine(destination!, aspect.ToString(), scope);
            Directory.CreateDirectory(folder);
            var model = new EditorViewModel(project with { Export = project.Export with { Aspect = aspect, Srt = true, Folder = folder } });
#if EXPORT_BASELINE
            var targets = BaselineExportRouting.Targets(model, scope == "this" ? "middle" : null, scope == "full");
#else
            var scopeKind = scope == "full" ? ExportScopeKind.FullVideo : scope == "all" ? ExportScopeKind.AllClips : ExportScopeKind.ThisClip;
            var route = new ExportDialogRouting(model, "middle", ExportDialogRouting.Scopes("middle").ToList().IndexOf(scopeKind),
                EditorLayout.Frames.ToList().IndexOf(aspect), 0, true, folder, "{project}-{clip}-{aspect}");
            var targets = route.Targets;
#endif
            foreach (var target in targets)
            {
                var clip = target is ExportTarget.Clip selected ? model.Clips.Single(clip => clip.Id == selected.Id) : null;
#if EXPORT_BASELINE
                var paths = BaselineExportRouting.Paths(model.Title, clip?.Title, aspect, true, folder, "{project}-{clip}-{aspect}");
                await File.WriteAllBytesAsync(paths.Mp4, [], ct);
                paths = BaselineExportRouting.Paths(model.Title, clip?.Title, aspect, true, folder, "{project}-{clip}-{aspect}");
                var state = ExportSelection.Scope(model.State, target)!;
                var rate = media.Audio!.SampleRate;
                var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, media.DurationSeconds), media.DurationSeconds, rate, state.PauseKeepSeconds);
                var size = ExportPresets.OutputSize(media.OrientedSize, aspect);
                var track = await CaptionEngine.BuildAsync(new(style, model.Project.Captions, size, EditingEngine.CaptionWords(state, plan), state.Transcript.Language, plan.Duration), new HarfBuzzGlyphShaper(shared), null, ct);
                var fps = ExportPresets.OutputFrameRate(media.Video!.FrameRate);
                var snapshot = new ComposeSnapshot(media, plan, track, new(size, fps, ExportPresets.VideoBitrate(size, aspect, ExportQuality.Standard, fps)));
                var job = new ExportJob(snapshot, target, aspect, ExportQuality.Standard, paths.Mp4, paths.Srt);
#else
                await File.WriteAllBytesAsync(route.Paths(target).Mp4, [], ct);
                var job = await route.JobAsync(target, async (captured, scopedState, cancellation) =>
                {
                    var plan = ExportRenderInput.Plan(media, scopedState);
                    var output = ExportRenderInput.Output(media, captured.Export);
                    var track = await CaptionEngine.BuildAsync(new(style, captured.Captions, output.Size,
                        EditingEngine.CaptionWords(scopedState!, plan), scopedState!.Transcript.Language, plan.Duration), new HarfBuzzGlyphShaper(shared), null, cancellation);
                    return new(media, plan, track, output);
                }, ct);
                var paths = (Mp4: job.OutputPath, Srt: job.SrtPath);
#endif
                var result = await new Exporter().ExportAsync(job, null, ct);
                Assert.True(result.Frames > 0);
                rows.Add(new
                {
                    aspect = aspect.ToString(), scope, target = clip?.Id ?? "full",
                    video = Path.GetRelativePath(destination!, paths.Mp4).Replace(Path.DirectorySeparatorChar, '/'),
                    srt = Path.GetRelativePath(destination!, paths.Srt!).Replace(Path.DirectorySeparatorChar, '/'),
                    result.DurationSeconds, result.Width, result.Height, result.Fps, result.Frames, result.AudioSampleRate, result.AudioSamples, result.VideoCodec
                });
            }
        }
        Assert.Equal(16, rows.Count);
        await File.WriteAllTextAsync(Path.Combine(destination!, "manifest.json"), JsonSerializer.Serialize(rows, new JsonSerializerOptions { WriteIndented = true }), ct);
    }
}
#endif
