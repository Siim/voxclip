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

/// <summary>Social loudness at export (ADR-R47, amended 2026-11-08), the parts that need no FFmpeg: the exporter's measuring and
/// simulating pre-passes over a reader, the limited stage the encoder reads, the edited WAV's gain and limiter, and the CLI's flag
/// and JSON.</summary>
public sealed class SocialLoudnessExportTests
{
    private static JsonElement Signal(string id) => FixtureLoader.ReadJson("fixtures/loudness/social-loudness-cases.json").RootElement
        .GetProperty("cases").EnumerateArray().Single(item => item.GetProperty("id").GetString() == id).Clone();
    private static JsonElement LimiterCase(string id) => FixtureLoader.ReadJson("fixtures/loudness/social-limiter-cases.json").RootElement
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

    private static double? Value(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : Math.Round(value.GetDouble(), 6);
    private static double? Rounded(double? value) => value is { } number ? Math.Round(number, 6) : null;
    // Loud audio past the export's end must not count.
    private static readonly float[] LoudTail = Enumerable.Repeat(0.9f, 48_000 * 2).ToArray();

    [Theory]
    [InlineData("speech-bursts-typical")]
    [InlineData("speech-clicks-reduction-cap")]
    [InlineData("speech-bursts-quiet-boost-limit")]
    [InlineData("digital-silence")]
    public void ThePrePassMeasuresWhatTheEncoderGetsInItsFrameSize(string id)
    {
        var item = Signal(id);
        var samples = SocialLoudnessVectors.Interleaved(item);
        var frames = samples.Length / 2;
        var sizes = new HashSet<int>();
        // A prime frame size, so the last read is always short of a whole frame.
        var measurement = Exporter.Measure(Reader([.. samples, .. LoudTail], 0, size => sizes.Add(size)), frames, 1031, TestContext.Current.CancellationToken);
        var decision = SocialLoudness.Decide(measurement.IntegratedLufs(), measurement.TruePeakDbtp);
        var expected = item.GetProperty("expected");
        Assert.Equal(expected.GetProperty("gainDb").GetDouble(), decision.GainDb, 6);
        Assert.Equal(expected.GetProperty("capped").GetBoolean(), decision.Capped);
        Assert.Equal(expected.GetProperty("limiting").GetBoolean(), decision.Limiting);
        Assert.Equal(Value(expected.GetProperty("measuredLufs")), Rounded(measurement.IntegratedLufs()));
        Assert.Equal(Value(expected.GetProperty("truePeakDbtp")), Rounded(measurement.TruePeakDbtp));
        Assert.Equal(Value(expected.GetProperty("gainedLufs")), Rounded(measurement.IntegratedLufs(decision.GainDb)));
        Assert.True(sizes.Max() <= 1031);
    }

    [Fact]
    public void ThePrePassStopsWhereTheReaderEnds()
    {
        var samples = SocialLoudnessVectors.Interleaved(Signal("speech-bursts-typical"));
        var whole = Exporter.Measure(Reader(samples, 0), samples.Length / 2, 1024, TestContext.Current.CancellationToken);
        var asked = Exporter.Measure(Reader(samples, 0), samples.Length / 2 + 96_000, 1024, TestContext.Current.CancellationToken);
        Assert.Equal(whole.StepEnergies, asked.StepEnergies);
        Assert.Equal(whole.TruePeak, asked.TruePeak);
    }

    [Theory]
    [InlineData("talk-pure-gain")]
    [InlineData("talk-clicks-limited")]
    [InlineData("talk-plosives-limited")]
    [InlineData("talk-reduction-cap")]
    [InlineData("talk-silence")]
    public void TheEncoderReadsTheLandedGainAndLimiterInItsFrameSize(string id)
    {
        var item = LimiterCase(id);
        var samples = SocialLoudnessVectors.Interleaved(item);
        var frames = samples.Length / 2;
        var ct = TestContext.Current.CancellationToken;
        var measurement = Exporter.Measure(Reader([.. samples, .. LoudTail], 0), frames, 1031, ct);
        var simulated = 0;
        var plan = Exporter.Plan(measurement, gainDb => { simulated++; return Exporter.Simulate(Reader([.. samples, .. LoudTail], 0), frames, 1031, gainDb, ct); });
        var expected = item.GetProperty("expected");
        Assert.Equal(expected.GetProperty("trials").GetArrayLength(), simulated);
        Assert.Equal(expected.GetProperty("gainDb").GetDouble(), plan.Decision.GainDb, 6);
        // What EncodeAudio reads: the stage over the export's reader, in the AAC frame size, every frame in order.
        var stage = new ExportLoudnessStage(Reader([.. samples, .. LoudTail], 0), frames, plan.Decision.GainDb, plan.Decision.Limiting);
        var output = new List<float>(samples.Length);
        var buffer = new float[2 * 1031];
        int count;
        while ((count = stage.Read(buffer, 1031, ct)) > 0) output.AddRange(buffer.AsSpan(0, 2 * count));
        var core = SocialLoudnessVectors.Export(samples);
        Assert.Equal(core.Output, output);
        var report = SocialLoudness.Report(plan.Measurement, plan.Decision, stage.Limiter, stage.Measured());
        Assert.Equal(core.Report, report);
        Assert.Equal(Value(expected.GetProperty("outputLufs")), Rounded(report.OutputLufs));
        Assert.Equal(Value(expected.GetProperty("limiterMaxReductionDb")), Rounded(report.LimiterMaxReductionDb));
    }

    [Fact]
    public void TheEditedWaveCarriesTheGainAndTheLimiterSampleForSample()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-wave-loudness-").FullName;
        try
        {
            var ct = TestContext.Current.CancellationToken;
            var path = Path.Combine(directory, "edited.wav");
            var samples = Enumerable.Range(0, 4_801 * 2).Select(index => (float)Math.Sin(index * 0.01) * 0.25f).ToArray();
            using (var writer = new WaveWriter(path, 48_000, 2, true)) writer.Write(samples);
            var before = File.ReadAllBytes(path);
            WaveLoudness.Apply(path, new(0, SocialLoudnessLimit.None), ct);
            Assert.Equal(before, File.ReadAllBytes(path));
            // Gain alone.
            WaveLoudness.Apply(path, new(6.5, SocialLoudnessLimit.None), ct);
            var after = File.ReadAllBytes(path);
            Assert.Equal(before.Length, after.Length);
            Assert.Equal(before.AsSpan(0, 44).ToArray(), after.AsSpan(0, 44).ToArray());
            var gain = Math.Pow(10, 6.5 / 20);
            for (var index = 0; index < samples.Length; index++)
                Assert.Equal(BitConverter.SingleToInt32Bits((float)(samples[index] * gain)), BitConverter.ToInt32(after, 44 + index * 4));
            // Gain and limiter, across more than one read of the file.
            var loud = SocialLoudnessVectors.Interleaved(LimiterCase("talk-clicks-limited"));
            using (var writer = new WaveWriter(path, 48_000, 2, true)) writer.Write(loud);
            WaveLoudness.Apply(path, new(8.8, SocialLoudnessLimit.None, true), ct);
            var limited = File.ReadAllBytes(path);
            var replayed = SocialLoudnessVectors.Stream(loud, new SocialLimiter(8.8, true, 48_000, 2));
            Assert.Equal(44 + 4 * loud.Length, limited.Length);
            for (var index = 0; index < replayed.Length; index++)
                Assert.Equal(BitConverter.SingleToInt32Bits(replayed[index]), BitConverter.ToInt32(limited, 44 + index * 4));
            using (var writer = new WaveWriter(path, 48_000, 2, false)) writer.Write(samples);
            Assert.Equal(VoxClipErrorCode.ExportFailed, Assert.Throws<VoxClipException>(() => WaveLoudness.Apply(path, new(6.5, SocialLoudnessLimit.None), ct)).Code);
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
            var report = expected == ExportLoudness.Social ? new SocialLoudnessReport(-20.7, 8.9, -14.02, -1.0, false, 6.4, 41.5) : null;
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
                Assert.Equal(["measuredLufs", "gainDb", "outputLufs", "truePeakDbtp", "capped", "limiterMaxReductionDb", "limitedPercent"],
                    loudness.EnumerateObject().Select(property => property.Name));
                Assert.Equal(8.9, loudness.GetProperty("gainDb").GetDouble());
                Assert.Equal((6.4, 41.5), (loudness.GetProperty("limiterMaxReductionDb").GetDouble(), loudness.GetProperty("limitedPercent").GetDouble()));
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

/// <summary>Social loudness on a real export (ADR-R47, amended 2026-11-08): the decoded MP4 lands within 0.5 LU of −14 with its
/// true peak at most −1 dBTP (plus the codec's margin where the limiter worked), and Off leaves the mix as composed. Needs FFmpeg and
/// the Windows H.264 encoders; generate-fixtures.sh writes speech-bursts.mkv and speech-plosives.mkv.</summary>
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

    [Fact]
    public async Task TransientsAreLimitedAndTheExportLandsAtMinus14()
    {
        var outer = TestContext.Current.CancellationToken;
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(outer);
        bounded.CancelAfter(Budget);
        var ct = bounded.Token;
        var directory = Directory.CreateTempSubdirectory("voxclip-loudness-native-").FullName;
        try
        {
            var info = await new FfmpegMediaProbe().ProbeAsync(NativeTest.Fixture("speech-plosives.mkv"), ct);
            var total = (long)Math.Round(info.DurationSeconds * 48_000);
            var snapshot = new ComposeSnapshot(info, TestPlan.FromKept(48_000, total, [new(0, total)]), null, new(new(160, 90), 30, 1_000_000));
            var limited = Path.Combine(directory, "limited.mp4");
            var result = await new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, limited, null),
                null, ct);
            var report = Assert.IsType<SocialLoudnessReport>(result.Loudness);
            Assert.False(report.Capped);
            Assert.InRange(report.LimiterMaxReductionDb, 3, SocialLoudness.MaximumReductionDb);
            Assert.InRange(report.OutputLufs!.Value, SocialLoudness.TargetLufs - 0.5, SocialLoudness.TargetLufs + 0.5);
            Assert.True(report.TruePeakDbtp <= SocialLoudness.CeilingDbtp + 1e-6, $"reported true peak {report.TruePeakDbtp}");
            var exported = await Measure(limited, result.AudioSamples, ct);
            Assert.InRange(exported.IntegratedLufs()!.Value, SocialLoudness.TargetLufs - 0.5, SocialLoudness.TargetLufs + 0.5);
            // The ceiling is the PCM's: AAC rings a few hundredths of a dB past it on a limited transient (Mac: −0.97 dBTP).
            Assert.True(exported.TruePeakDbtp <= SocialLoudness.CeilingDbtp + 0.1, $"true peak {exported.TruePeakDbtp}");
        }
        catch (Exception exception) when (bounded.IsCancellationRequested && !outer.IsCancellationRequested)
        {
            Assert.Fail($"The native limited loudness export test did not finish within {Budget.TotalMinutes:0} minutes ({exception.GetType().Name}).");
        }
        finally { Directory.Delete(directory, true); }
    }
}
