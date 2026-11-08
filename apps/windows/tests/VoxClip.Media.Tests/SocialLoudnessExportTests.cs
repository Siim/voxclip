using System.Text.Json;
using VoxClip.Cli;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Social loudness at export (ADR-R47), the parts that need no FFmpeg: the exporter's measuring pre-pass over a reader,
/// the edited WAV's gain, and the CLI's flag and JSON.</summary>
public sealed class SocialLoudnessExportTests
{
    private static JsonElement Signal(string id) => FixtureLoader.ReadJson("fixtures/loudness/social-loudness-cases.json").RootElement
        .GetProperty("cases").EnumerateArray().Single(item => item.GetProperty("id").GetString() == id).Clone();

    // A reader over a vector signal that would go on past the export's end, so the pre-pass must stop where the encoder stops.
    private static StereoRead Reader(float[] samples, int extraFrames, Action<int>? requested = null)
    {
        var padded = samples.Concat(new float[extraFrames * 2]).ToArray();
        var position = 0;
        return (target, frames, _) =>
        {
            requested?.Invoke(frames);
            var count = Math.Min(frames, (padded.Length - position) / 2);
            padded.AsSpan(position, count * 2).CopyTo(target);
            position += count * 2;
            return count;
        };
    }

    [Theory]
    [InlineData("speech-bursts-typical")]
    [InlineData("speech-clicks-peak-cap")]
    [InlineData("speech-bursts-quiet-boost-limit")]
    [InlineData("digital-silence")]
    public void ThePrePassMeasuresWhatTheEncoderGetsInItsFrameSize(string id)
    {
        var item = Signal(id);
        var samples = SocialLoudnessVectors.Interleaved(item);
        var frames = samples.Length / 2;
        var sizes = new HashSet<int>();
        // Loud audio past the export's end must not count.
        var tail = Enumerable.Repeat(0.9f, 48_000 * 2).ToArray();
        // A prime frame size, so the last read is always short of a whole frame.
        var report = Exporter.Measure(Reader([.. samples, .. tail], 0, size => sizes.Add(size)), frames, 1031, TestContext.Current.CancellationToken);
        var expected = item.GetProperty("expected");
        Assert.Equal(expected.GetProperty("gainDb").GetDouble(), report.GainDb, 6);
        Assert.Equal(expected.GetProperty("capped").GetBoolean(), report.Capped);
        static double? Value(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : Math.Round(value.GetDouble(), 6);
        static double? Rounded(double? value) => value is { } number ? Math.Round(number, 6) : null;
        Assert.Equal(Value(expected.GetProperty("measuredLufs")), Rounded(report.MeasuredLufs));
        Assert.Equal(Value(expected.GetProperty("outputLufs")), Rounded(report.OutputLufs));
        Assert.Equal(Value(expected.GetProperty("outputTruePeakDbtp")), Rounded(report.TruePeakDbtp));
        Assert.True(sizes.Max() <= 1031);
    }

    [Fact]
    public void ThePrePassStopsWhereTheReaderEnds()
    {
        var samples = SocialLoudnessVectors.Interleaved(Signal("speech-bursts-typical"));
        var whole = Exporter.Measure(Reader(samples, 0), samples.Length / 2, 1024, TestContext.Current.CancellationToken);
        var asked = Exporter.Measure(Reader(samples, 0), samples.Length / 2 + 96_000, 1024, TestContext.Current.CancellationToken);
        Assert.Equal(whole, asked);
    }

    [Fact]
    public void TheEditedWaveCarriesTheGainSampleForSample()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-wave-gain-").FullName;
        try
        {
            var path = Path.Combine(directory, "edited.wav");
            var samples = Enumerable.Range(0, 4_801 * 2).Select(index => (float)Math.Sin(index * 0.01) * 0.25f).ToArray();
            using (var writer = new WaveWriter(path, 48_000, 2, true)) writer.Write(samples);
            var before = File.ReadAllBytes(path);
            WaveGain.Apply(path, 1f, TestContext.Current.CancellationToken);
            Assert.Equal(before, File.ReadAllBytes(path));
            var gain = SocialLoudness.LinearGain(6.5);
            WaveGain.Apply(path, gain, TestContext.Current.CancellationToken);
            var after = File.ReadAllBytes(path);
            Assert.Equal(before.Length, after.Length);
            Assert.Equal(before.AsSpan(0, 44).ToArray(), after.AsSpan(0, 44).ToArray());
            for (var index = 0; index < samples.Length; index++)
                Assert.Equal(BitConverter.SingleToInt32Bits(samples[index] * gain), BitConverter.ToInt32(after, 44 + index * 4));
            using (var writer = new WaveWriter(path, 48_000, 2, false)) writer.Write(samples);
            Assert.Equal(VoxClipErrorCode.ExportFailed, Assert.Throws<VoxClipException>(() => WaveGain.Apply(path, gain, TestContext.Current.CancellationToken)).Code);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData(null, ExportLoudness.Social)]
    [InlineData("social", ExportLoudness.Social)]
    [InlineData("off", ExportLoudness.Off)]
    public async Task TheCliPassesItsLoudnessAndReportsIt(string? flag, ExportLoudness expected)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-cli-loudness-").FullName;
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            var source = Path.Combine(directory, "source.mp4");
            File.WriteAllText(source, "probed media");
            var media = new MediaInfo(source, 7, new(640, 360, 30, 0), new(48_000, 1), new(640, 360), "h264", "aac", false, 0, 1, 0);
            var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "interview-take.voxclip")));
            var transcript = Path.Combine(directory, "transcript.json");
            File.WriteAllText(transcript, JsonSerializer.Serialize(project.Transcript, CliDataJson.Default.Transcript));
            ExportJob? prepared = null;
            var report = expected == ExportLoudness.Social ? new SocialLoudnessReport(-20.7, 6.7, -14, -3.1, false) : null;
            Task<ExportResult> Prepare(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct)
            {
                prepared = job;
                File.WriteAllText(job.OutputPath + ".partial", "prepared video");
                var plan = job.Snapshot.Plan;
                return Task.FromResult(new ExportResult(job.OutputPath, null, plan.Duration, 640, 360, 30,
                    (long)Math.Ceiling(plan.Duration * 30), 48_000, plan.OutputSamples, "h264", "test", 0) { Loudness = report });
            }
            var arguments = new List<string> { "--open", source, "--export", Path.Combine(directory, "out.mp4"), "--style", "off",
                "--transcript", transcript, "--json" };
            if (flag is not null) arguments.AddRange(["--loudness", flag]);
            Console.SetOut(output); Console.SetError(errors);
            Assert.Equal(0, await AcceptedCli.RunAsync(arguments.ToArray(), TestContext.Current.CancellationToken,
                (_, _) => Task.FromResult<(Project?, MediaInfo)>((null, media)), Prepare));
            Assert.Equal(expected, prepared!.Loudness);
            using var json = JsonDocument.Parse(output.ToString());
            var loudness = json.RootElement.GetProperty("loudness");
            if (report is null) Assert.Equal(JsonValueKind.Null, loudness.ValueKind);
            else
            {
                Assert.Equal(["measuredLufs", "gainDb", "outputLufs", "truePeakDbtp", "capped"], loudness.EnumerateObject().Select(property => property.Name));
                Assert.Equal(6.7, loudness.GetProperty("gainDb").GetDouble());
                Assert.False(loudness.GetProperty("capped").GetBoolean());
            }
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task AnUnknownLoudnessIsAUsageError()
    {
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            Console.SetOut(output); Console.SetError(errors);
            Assert.Equal(2, await AcceptedCli.RunAsync(["--open", "missing.mp4", "--export", "unused.mp4", "--loudness", "loud", "--json"],
                TestContext.Current.CancellationToken));
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); }
    }
}

/// <summary>Social loudness on a real export (ADR-R47): the decoded MP4 lands within 0.5 LU of −14 with its true peak at most −1 dBTP,
/// and Off leaves the mix as composed. Needs FFmpeg and the Windows H.264 encoders; generate-fixtures.sh writes speech-bursts.mkv.</summary>
[Trait("Category", "RequiresFFmpeg")]
[Trait("Category", "RequiresWindows")]
public sealed class SocialLoudnessNativeExportTests : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await NativeTest.RequireAsync(windows: true);
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    // The whole test is bounded: a read or an export that never finishes fails with a message instead of holding the run.
    private static readonly TimeSpan Budget = TimeSpan.FromMinutes(3);

    // AudioDecoder pads with silence past the end and never returns 0 (it feeds fixed-length readers), so read the known length.
    private static Task<SocialLoudnessMeasurement> Measure(string path, long frames, CancellationToken ct) => MediaThread.Run("vc-test-loudness", () =>
    {
        using var decoder = new AudioDecoder(path, 2);
        var meter = new SocialLoudnessMeter(48_000, 2);
        var buffer = new float[4096 * 2];
        for (long read = 0; read < frames;)
        {
            var count = decoder.Read(buffer, (int)Math.Min(4096, frames - read), ct);
            meter.Append(buffer.AsSpan(0, count * 2));
            read += count;
        }
        return meter.Finish();
    }, ct);

    [Fact]
    public async Task SocialLandsAtMinus14AndOffLeavesTheMix()
    {
        var outer = TestContext.Current.CancellationToken;
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(outer);
        bounded.CancelAfter(Budget);
        var ct = bounded.Token;
        var directory = Directory.CreateTempSubdirectory("voxclip-loudness-native-").FullName;
        try
        {
            var info = await new FfmpegMediaProbe().ProbeAsync(NativeTest.Fixture("speech-bursts.mkv"), ct);
            var total = (long)Math.Round(info.DurationSeconds * 48_000);
            var snapshot = new ComposeSnapshot(info, TestPlan.FromKept(48_000, total, [new(0, total)]), null, new(new(160, 90), 30, 1_000_000));
            var source = (await Measure(info.Path, total, ct)).IntegratedLufs()!.Value;
            var social = Path.Combine(directory, "social.mp4");
            var result = await new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, social, null),
                null, ct);
            var report = Assert.IsType<SocialLoudnessReport>(result.Loudness);
            Assert.False(report.Capped);
            Assert.Equal(source, report.MeasuredLufs!.Value, 1);
            var exported = await Measure(social, result.AudioSamples, ct);
            Assert.InRange(exported.IntegratedLufs()!.Value, SocialLoudness.TargetLufs - 0.5, SocialLoudness.TargetLufs + 0.5);
            Assert.True(exported.TruePeakDbtp <= SocialLoudness.CeilingDbtp, $"true peak {exported.TruePeakDbtp}");
            var off = Path.Combine(directory, "off.mp4");
            var unchanged = await new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, off, null)
                { Loudness = ExportLoudness.Off }, null, ct);
            Assert.Null(unchanged.Loudness);
            Assert.InRange((await Measure(off, unchanged.AudioSamples, ct)).IntegratedLufs()!.Value, source - 0.5, source + 0.5);
        }
        catch (Exception exception) when (bounded.IsCancellationRequested && !outer.IsCancellationRequested)
        {
            Assert.Fail($"The native social loudness export test did not finish within {Budget.TotalMinutes:0} minutes ({exception.GetType().Name}).");
        }
        finally { Directory.Delete(directory, true); }
    }
}
