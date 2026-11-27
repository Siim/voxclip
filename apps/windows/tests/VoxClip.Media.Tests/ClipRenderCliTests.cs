using System.Runtime.InteropServices;
using System.Text.Json;
using VoxClip.Cli;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>The CLI and the preview carry a clip's controls and the scope's effects to the renderer instead of refusing them
/// (design §6.9, ai.md §18.5). No FFmpeg: the CLI's input and encoder are injected, the preview's decoder is a stub.</summary>
[Collection("CLI console")]
public sealed class ClipRenderCliTests
{
    [Fact]
    public async Task ExportRejectsAnUnusedSpokenRecordingAsADestination()
    {
        var ct = TestContext.Current.CancellationToken;
        using var directory = new RecordingTemp();
        var story = await RecordingStoryFixture.CreateAsync(directory.Path, ct);
        var companion = story.Project.Media.AdditionalSources![0];
        var original = await File.ReadAllBytesAsync(companion.AbsolutePath, ct);
        var (code, json, error) = await RecordingCliAsync(["--open", story.Path, "--range", "0:0", "--export", companion.AbsolutePath,
            "--style", "off", "--json"], ct, (_, _) => Task.FromResult<(Project?, MediaInfo)>((story.Project, story.Primary)),
            (_, _, _) => throw new InvalidOperationException("The encoder must not overwrite a recording."));
        Assert.NotEqual(0, code);
        Assert.Contains("overwrite", json + error);
        Assert.DoesNotContain("encoder", json + error);
        Assert.Equal(original, await File.ReadAllBytesAsync(companion.AbsolutePath, ct));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AUsedRecordingThatIsMissingOrChangedStopsCliExport(bool changed)
    {
        var ct = TestContext.Current.CancellationToken;
        using var directory = new RecordingTemp();
        var story = await RecordingStoryFixture.CreateAsync(directory.Path, ct);
        var companion = story.Project.Media.AdditionalSources![0];
        if (changed)
        {
            var bytes = await File.ReadAllBytesAsync(companion.AbsolutePath, ct);
            bytes[bytes.Length / 2] ^= 1;
            await File.WriteAllBytesAsync(companion.AbsolutePath, bytes, ct);
        }
        else File.Delete(companion.AbsolutePath);
        var destination = Path.Combine(directory.Path, "out.mp4");
        var (code, json, error) = await RecordingCliAsync(["--open", story.Path, "--export", destination, "--style", "off", "--json"], ct,
            (_, _) => Task.FromResult<(Project?, MediaInfo)>((story.Project, story.Primary)),
            (_, _, _) => throw new InvalidOperationException("The encoder must not run without both recordings."));
        Assert.NotEqual(0, code);
        Assert.Contains("0010 is missing. Locate it to use its words.", json + error);
        Assert.False(File.Exists(destination));
    }

    [Fact]
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task WindowsCliExportsAndChecksTheSharedFivePartStory()
    {
        await NativeTest.RequireAsync(windows: true);
        var ct = TestContext.Current.CancellationToken;
        using var directory = new RecordingTemp();
        var story = await RecordingStoryFixture.CreateAsync(directory.Path, ct);
        var destination = Path.Combine(directory.Path, "out.mp4");
        var (exportCode, json, exportError) = await RecordingCliAsync(["--open", story.Path, "--export", destination, "--style", "off", "--loudness", "off", "--json"], ct);
        Assert.True(exportCode == 0, json + exportError);
        using var export = JsonDocument.Parse(json);
        var plan = EditingEngine.BuildPlan(EditingEngine.FromProject(story.Project)!, story.Primary.DurationSeconds, 48_000);
        Assert.Equal(plan.Duration, export.RootElement.GetProperty("durationSeconds").GetDouble(), 7);
        var (checkCode, checkedJson, checkError) = await RecordingCliAsync(["check", destination, "--project", story.Path, "--clip", "clip-recordings",
            "--aspect", "source", "--style", "off", "--loudness", "off", "--json"], ct);
        Assert.True(checkCode is 0 or 8, checkedJson + checkError);
        using var checkedReport = JsonDocument.Parse(checkedJson);
        var report = checkedReport.RootElement.GetProperty("check");
        Assert.False(report.TryGetProperty("recordingSeams", out _));
        var sync = report.GetProperty("sync").GetProperty("items");
        Assert.Equal(["0007", "0010", "0007"], sync.EnumerateArray().Where(item => item.GetProperty("kind").GetString() == "recordingSeam")
            .Select(item => item.GetProperty("recordingSeam").GetProperty("to").GetString()));
        Assert.DoesNotContain(sync.EnumerateArray(), item => item.GetProperty("kind").GetString() == "pictureSource");
    }

    /// <summary>Runs the CLI in process. Progress goes to stderr, so only stdout is the JSON document.</summary>
    private static async Task<(int Code, string Json, string Error)> RecordingCliAsync(string[] args, CancellationToken ct,
        VoxClip.Cli.ExportInputReader? open = null, VoxClip.Cli.ExportPreparer? prepare = null)
    {
        var previousOut = Console.Out;
        var previousError = Console.Error;
        using var output = new StringWriter();
        using var error = new StringWriter();
        try
        {
            Console.SetOut(output);
            Console.SetError(error);
            return (await AcceptedCli.RunAsync(args, ct, open, prepare), output.ToString(), error.ToString());
        }
        finally { Console.SetOut(previousOut); Console.SetError(previousError); }
    }

    private sealed class RecordingTemp : IDisposable
    {
        private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("voxclip-recording-cli-");
        internal string Path => directory.FullName;
        public void Dispose() => directory.Delete(true);
    }

    [Fact]
    public async Task HarnessFramesRejectAProjectClockGuardGap()
    {
        var ct = TestContext.Current.CancellationToken;
        using var directory = new RecordingTemp();
        var story = await RecordingStoryFixture.CreateAsync(directory.Path, ct);
        var harness = await HarnessProject.OpenAsync(story.Path, ct);
        var clock = ProjectClock.Build(story.Project);
        var (start, end) = Assert.Single(clock.GuardGaps);
        var arguments = JsonSerializer.SerializeToElement(new { times = new[] { (start + end) / (2.0 * clock.SampleRate) } });
        var error = await Assert.ThrowsAsync<HarnessException>(() => harness.CallAsync(HarnessTool.ReadFrames, arguments, ct));
        Assert.Equal("Give one to four project times inside a recording.", error.Message);
    }

    [Fact]
    [Trait("Category", "RequiresFFmpeg")]
    public async Task HarnessFramesDecodeTheRecordingAtEachProjectClockTime()
    {
        await NativeTest.RequireAsync();
        var ct = TestContext.Current.CancellationToken;
        using var directory = new RecordingTemp();
        var story = await RecordingStoryFixture.CreateAsync(directory.Path, ct);
        var harness = await HarnessProject.OpenAsync(story.Path, ct);
        var offset = Assert.Single(story.Project.Media.SpokenSources!).OffsetSeconds;
        double[] times = [offset, 0, offset];
        var result = await harness.CallAsync(HarnessTool.ReadFrames, JsonSerializer.SerializeToElement(new { times }), ct);
        var frames = Assert.IsAssignableFrom<IReadOnlyList<HarnessFrame>>(result.Frames);
        Assert.Equal(times, frames.Select(frame => frame.Requested));
        Assert.Equal(times, frames.Select(frame => frame.Actual));
        Assert.True(frames[0].Jpeg == frames[2].Jpeg && frames[0].Jpeg != frames[1].Jpeg,
            "Expected distinct thumbnails for distinct recordings.");
    }

    [Fact]
    public async Task CompanionExportOnlyNeedsThePrimaryWhenItIsKept()
    {
        var ct = TestContext.Current.CancellationToken;
        using var directory = new RecordingTemp();
        var story = await RecordingStoryFixture.CreateAsync(directory.Path, ct);
        File.Delete(story.Primary.Path);
        string[] options = ["--open", story.Path, "--export", Path.Combine(directory.Path, "out.mp4"), "--style", "off"];

        var companion = await CliOperations.PrepareExportAsync(CliApplication.Parse([.. options, "--range", "27:28"]), ct, null);
        Assert.NotEmpty(companion.Snapshot.SpanSources);
        Assert.All(companion.Snapshot.SpanSources, source => Assert.Equal("0010", source.Label));

        var error = await Assert.ThrowsAsync<VoxClipException>(() => CliOperations.PrepareExportAsync(
            CliApplication.Parse([.. options, "--clip", "clip-recordings"]), ct, null));
        Assert.Equal(VoxClipErrorCode.MediaMissing, error.Code);
    }

    [Fact]
    public async Task WordRangeUsesTheProjectClockButCannotCrossRecordings()
    {
        var ct = TestContext.Current.CancellationToken;
        using var directory = new RecordingTemp();
        var story = await RecordingStoryFixture.CreateAsync(directory.Path, ct);
        string[] options = ["--open", story.Path, "--export", Path.Combine(directory.Path, "out.mp4"), "--style", "off", "--range"];
        Task<(Project?, MediaInfo)> Open(string _, CancellationToken __) => Task.FromResult<(Project?, MediaInfo)>((story.Project, story.Primary));

        var companion = await CliOperations.PrepareExportAsync(CliApplication.Parse([.. options, "27:28"]), ct, Open);
        Assert.NotEmpty(companion.Snapshot.SpanSources);
        Assert.All(companion.Snapshot.SpanSources, source => Assert.Equal("0010", source.Label));

        var error = await Assert.ThrowsAsync<CliUsageException>(() => CliOperations.PrepareExportAsync(
            CliApplication.Parse([.. options, "26:27"]), ct, Open));
        Assert.Equal("A word range must come from one recording.", error.Message);
    }

    [Fact]
    public async Task StoryPreparedByTheCliSeeksPreviewInEachRecordingsLocalTime()
    {
        var ct = TestContext.Current.CancellationToken;
        var timeout = TimeSpan.FromSeconds(5);
        using var directory = new RecordingTemp();
        var story = await RecordingStoryFixture.CreateAsync(directory.Path, ct);
        var arguments = CliApplication.Parse(["--open", story.Path, "--export", Path.Combine(directory.Path, "out.mp4"), "--style", "off"]);
        var prepared = await CliOperations.PrepareExportAsync(arguments, ct,
            (_, _) => Task.FromResult<(Project?, MediaInfo)>((story.Project, story.Primary)));
        var snapshot = prepared.Snapshot;
        Assert.Equal(["0010", "0007", "0007", "0010", "0007"], snapshot.SpanSources.Select(source => source.Label));
        var workers = new Dictionary<string, Worker>();
        await using var preview = new PreviewEngine(new Composer(), initialize: _ => { }, createWorker: (path, _) => workers[path] = new());
        await preview.LoadAsync(snapshot, null, ct).WaitAsync(timeout, ct);
        long cursor = 0;
        foreach (var (part, source) in snapshot.Plan.Kept.Zip(snapshot.SpanSources))
        {
            var edited = (cursor + 4800) / snapshot.Plan.SampleRate;
            await preview.SeekAsync(edited, true, ct).WaitAsync(timeout, ct);
            Assert.Equal((part.StartSample + 4800 - source.OffsetSamples) / snapshot.Plan.SampleRate, workers[source.Path].Position, 8);
            cursor += part.EndSample - part.StartSample;
        }
        Assert.Equal(2, workers.Count);
    }

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

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FourFiveExportsFromEitherClipShapeOrExplicitAspect(bool explicitAspect)
    {
        var project = Fixture();
        project = project with { ClipControls = [Assert.Single(project.ClipControls) with
            { Shape = explicitAspect ? ClipShape.Portrait : ClipShape.PortraitFourFive }] };
        var (exit, job, output) = await ExportAsync(project, explicitAspect ? ["--clip", "clip-main", "--aspect", "4:5"] : ["--clip", "clip-main"]);
        Assert.True(exit == 0, output);
        Assert.Equal(new PixelSize(1080, 1350), Assert.IsType<ExportJob>(job).Snapshot.Output.Size);
        using var json = JsonDocument.Parse(output[..(output.LastIndexOf('}') + 1)]);
        Assert.Equal("4:5", json.RootElement.GetProperty("aspect").GetString());
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
