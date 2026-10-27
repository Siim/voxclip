#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Media.Captions;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class ExportEquivalenceTests
{
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
