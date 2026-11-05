using System.Runtime.InteropServices;
using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>The CLI and the preview carry a clip's controls and the scope's effects to the renderer instead of refusing them
/// (design §6.9, ai.md §18.5). No FFmpeg: the CLI's input and encoder are injected, the preview's decoder is a stub.</summary>
[Collection("CLI console")]
public sealed class ClipRenderCliTests
{
    private static Project Fixture()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/clip-controls/clip-controls-project.voxclip"));
        using var bleep = JsonDocument.Parse("""{"id":"fx-bleep-1","clipId":null,"kind":"bleep","start":0.5,"end":1.0,"wordIds":["w3"]}""");
        using var title = JsonDocument.Parse("""{"id":"fx-title-1","clipId":"clip-main","kind":"title","start":0.2,"end":1.2,"text":"Day 1","position":"top"}""");
        return ClipEffects.Adding([bleep.RootElement.Clone(), title.RootElement.Clone()], project);
    }

    private static MediaInfo Media(Project project, string directory)
    {
        var path = Path.Combine(directory, "source.mp4");
        File.WriteAllText(path, "offline injected probe input");
        var source = project.Media.Source;
        return new(path, source.DurationSeconds, source.Video, source.Audio, new(1920, 1080), "h264", "aac", false, 0, 1, 0);
    }

    private static Task<(int Exit, ExportJob? Job, string Output)> ExportAsync(Project project, params string[] extra) =>
        ExportStyledAsync(project, ["--style", "off"], extra);

    /// <summary>Exports through the CLI with <paramref name="style"/> (empty: the project's own caption styles).</summary>
    internal static async Task<(int Exit, ExportJob? Job, string Output)> ExportStyledAsync(Project project, string[] style, string[] extra)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-clip-render-cli-").FullName;
        var oldOutput = Console.Out;
        var oldError = Console.Error;
        using var output = new StringWriter();
        using var errors = new StringWriter();
        try
        {
            var input = Path.Combine(directory, "take.voxclip");
            var destination = Path.Combine(directory, "out.mp4");
            var media = Media(project, directory);
            project = project with { Media = new(project.Media.Source with { AbsolutePath = media.Path, SizeBytes = new FileInfo(media.Path).Length }) };
            File.WriteAllText(input, ProjectSerialization.Serialize(project));
            ExportJob? captured = null;
            Task<ExportResult> Prepare(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct)
            {
                captured = job;
                File.WriteAllText(destination + ".partial", "synthetic test export");
                var (frames, samples) = Exporter.RenderedCounts(job.Snapshot, 30);
                return Task.FromResult(new ExportResult(destination, null, job.Snapshot.RenderedDuration, job.Snapshot.Output.Size.Width,
                    job.Snapshot.Output.Size.Height, 30, frames, 48_000, samples, "h264", "test", 0));
            }
            Console.SetOut(output);
            Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(["--open", input, "--export", destination, .. style, "--json", .. extra],
                TestContext.Current.CancellationToken, (_, _) => Task.FromResult<(Project?, MediaInfo)>((project, media)), Prepare);
            return (exit, captured, output + errors.ToString());
        }
        finally { Console.SetOut(oldOutput); Console.SetError(oldError); Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task AClipExportCarriesItsControlsFrameAndEffectsToTheRenderer()
    {
        var project = Fixture();
        var (exit, job, output) = await ExportAsync(project, "--clip", "clip-main");
        Assert.True(exit == 0, output);
        var snapshot = Assert.IsType<ExportJob>(job).Snapshot;
        var controls = Assert.Single(project.ClipControls);
        Assert.Equal(controls, snapshot.Clip?.Controls);
        // 9:16 is the clip's own shape; 1.25× renders the edited length ÷ 1.25.
        Assert.Equal(new PixelSize(1080, 1920), snapshot.Output.Size);
        Assert.Equal(1.25, snapshot.Speed.Speed);
        Assert.Equal(new ClipSpeedTiming(1.25).RenderedSamples(snapshot.Timeline.OutputSamples), snapshot.RenderedSamples);
        Assert.Equal(["fx-bleep-1", "fx-title-1"], snapshot.Clip!.Effects!.Effects.Select(effect => effect.Id));
        using var result = JsonDocument.Parse(output[..(output.LastIndexOf('}') + 1)]);
        Assert.Equal(snapshot.RenderedDuration, result.RootElement.GetProperty("durationSeconds").GetDouble(), 9);
    }

    [Fact]
    public async Task TheFullVideoRendersWithoutClipControlsAndKeepsOnlyItsEffects()
    {
        var project = Fixture() with { Edits = Fixture().Edits with { ActiveClipId = null } };
        var (exit, job, output) = await ExportAsync(project);
        Assert.True(exit == 0, output);
        var snapshot = Assert.IsType<ExportJob>(job).Snapshot;
        Assert.Null(snapshot.Clip!.Controls);
        Assert.Equal(1, snapshot.Speed.Speed);
        Assert.Equal(["fx-bleep-1"], snapshot.Clip.Effects!.Effects.Select(effect => effect.Id));
        Assert.Equal(snapshot.Timeline.OutputSamples, snapshot.RenderedSamples);
    }

    // MARK: Preview

    private sealed class Worker : IPreviewVideoWorker
    {
        public Task Ready => Task.CompletedTask;
        public double Position { get; private set; }
        public List<double> Reads { get; } = [];
        public Task<PixelBuffer> ReadAsync(double source, bool exact, CancellationToken ct)
        {
            Position = source;
            lock (Reads) Reads.Add(source);
            return Task.FromResult(new PixelBuffer(new byte[16], 2, 2, 8));
        }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class Composer : IFrameComposer
    {
        public void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct)
            => output.Pixels.Span.Clear();
    }

    [Theory]
    [InlineData(1.0)]
    [InlineData(2.0)]
    public async Task PreviewFramesAdvanceTheEditedClockBySpeedPerRenderedFrame(double speed)
    {
        var timeout = TimeSpan.FromSeconds(5);
        var ct = TestContext.Current.CancellationToken;
        var snapshot = new ComposeSnapshot(new("test.mp4", 10, new(2, 2, 30, 0), null, new(2, 2), "h264", null, false, 0, -1, 0),
            TestPlan.FromKept(48_000, 480_000, [new(0, 480_000)]), null, new(new(2, 2), 30, 1_000_000))
        {
            Clip = new(new ProjectClipControls("c", speed, null, ClipLook.Original, 0, 0, 0, false, false, 0),
                new([new ClipEffect("fx-freeze-1", null, "freeze", 3, 4)], new Dictionary<string, string>()))
        };
        double clock = 0;
        var worker = new Worker();
        await using var preview = new PreviewEngine(new Composer(), initialize: _ => { }, createWorker: (_, _) => worker,
            clockOverride: () => Volatile.Read(ref clock));
        await preview.LoadAsync(snapshot, null, ct).WaitAsync(timeout, ct);
        await using var reader = preview.ReadFramesAsync(ct).GetAsyncEnumerator(ct);
        Assert.True(await reader.MoveNextAsync().AsTask().WaitAsync(timeout, ct));
        await preview.PlayAsync(ct).WaitAsync(timeout, ct);
        Volatile.Write(ref clock, 1.0);
        var times = new List<double>();
        while (times.Count < 2)
        {
            Assert.True(await reader.MoveNextAsync().AsTask().WaitAsync(timeout, ct));
            if (reader.Current.EditedPts >= 1) times.Add(reader.Current.EditedPts);
        }
        Assert.Equal(speed / 30, times[1] - times[0], 9);
        // A freeze holds its first frame: the decoder is asked for 3 s while the edited clock is inside it.
        Volatile.Write(ref clock, 3.5);
        while (true)
        {
            Assert.True(await reader.MoveNextAsync().AsTask().WaitAsync(timeout, ct));
            if (reader.Current.EditedPts >= 3.5) break;
        }
        await preview.PauseAsync(ct).WaitAsync(timeout, ct);
        lock (worker.Reads) Assert.Equal(3, worker.Reads[^1], 9);
    }
}
