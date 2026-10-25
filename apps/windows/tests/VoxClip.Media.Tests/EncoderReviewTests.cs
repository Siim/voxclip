using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class EncoderReviewTests
{
    [Theory]
    [InlineData("h264_nvenc", 6_000_000, 8_000_000)]
    [InlineData("h264_qsv", 6_000_000, 0)]
    [InlineData("h264_amf", 6_000_000, 0)]
    [InlineData("h264_mf", 0, 0)]
    public void RateControlMatchesOnlyTheSpecifiedRung(string encoder, long maximum, int buffer)
        => Assert.Equal((maximum, buffer), EncoderSession.RateControl(encoder, 4_000_000));

    [Fact]
    public async Task KnownAdapterCachesFirstSuccessAndProbesFallbackLazily()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "encoders.json");
        var key = new EncoderCacheKey("adapter", "driver", "test-build");
        var attempts = new List<string>();
        var probe = new EncoderProbe(identity => identity, (name, ct) =>
        {
            attempts.Add(name);
            return new(name, true, null);
        }, () => path);
        try
        {
            var first = await probe.ProbeAsync(key, null, TestContext.Current.CancellationToken);
            Assert.Equal("h264_nvenc", Assert.Single(first).Name);
            await probe.ProbeAsync(key, null, TestContext.Current.CancellationToken);
            Assert.Single(attempts);
            EncoderProbe.RecordFailure(key, "h264_nvenc", path);
            var fallback = await probe.ProbeRemainingAsync(key, new HashSet<string> { "h264_nvenc" }, TestContext.Current.CancellationToken);
            Assert.False(fallback[0].Available);
            Assert.Equal("h264_qsv", fallback[1].Name);
            Assert.Equal(new[] { "h264_nvenc", "h264_qsv" }, attempts);
            await probe.ProbeAsync(key with { FfmpegVersion = "new-build" }, null, TestContext.Current.CancellationToken);
            Assert.Equal(3, attempts.Count);
            await File.WriteAllTextAsync(path, "invalid cache", TestContext.Current.CancellationToken);
            await probe.ProbeAsync(key, null, TestContext.Current.CancellationToken);
            Assert.Equal(4, attempts.Count);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("unknown")]
    [InlineData("adapter")]
    public async Task ExhaustedCacheReprobesTheWholeLadder(string adapter)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "encoders.json");
        var key = new EncoderCacheKey(adapter, "driver", "test-build");
        try
        {
            var exhausted = new EncoderCacheDocument(key, EncoderProbe.Ladder.Select(name => new EncoderInfo(name, false, null)).ToArray()) { ConfigurationRevision = 2 };
            File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(exhausted, EncoderCacheJson.Default.EncoderCacheDocument));
            var calls = 0;
            var probe = new EncoderProbe(identity => identity, (name, ct) => { calls++; return new(name, true, null); }, () => path);
            Assert.True(Assert.Single(await probe.ProbeAsync(key, null, TestContext.Current.CancellationToken)).Available);
            Assert.Equal(1, calls);
            await probe.ProbeAsync(key, null, TestContext.Current.CancellationToken);
            Assert.Equal(adapter == "unknown" ? 2 : 1, calls);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task RestartAdvancesEvenWhenCacheWritesFail()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        try
        {
            var probe = new EncoderProbe(identity => identity, (name, ct) => new(name, true, null), () => directory);
            var key = new EncoderCacheKey("adapter", "driver", "test-build");
            Assert.Equal("h264_nvenc", Assert.Single(await probe.ProbeAsync(key, null, TestContext.Current.CancellationToken)).Name);
            var restart = await probe.ProbeRemainingAsync(key, new HashSet<string> { "h264_nvenc" }, TestContext.Current.CancellationToken);
            Assert.Equal("h264_qsv", restart.Single(encoder => encoder.Available).Name);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task FailureOfTheOnlyEncoderIsNotPersisted()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "encoders.json");
        var key = new EncoderCacheKey("adapter", "driver", "test-build");
        try
        {
            var probe = new EncoderProbe(identity => identity, (name, ct) => new(name, name == EncoderProbe.SoftwareMediaFoundation, null), () => path);
            await probe.ProbeAsync(key, null, TestContext.Current.CancellationToken);
            var cached = File.ReadAllText(path);
            EncoderProbe.RecordFailure(key, EncoderProbe.SoftwareMediaFoundation, path);
            Assert.Equal(cached, File.ReadAllText(path));
            Assert.DoesNotContain(await probe.ProbeRemainingAsync(key, new HashSet<string> { EncoderProbe.SoftwareMediaFoundation }, TestContext.Current.CancellationToken), encoder => encoder.Available);
            Assert.Equal(cached, File.ReadAllText(path));
            Assert.Contains(await probe.ProbeAsync(key, null, TestContext.Current.CancellationToken), encoder => encoder.Available);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("unknown")]
    [InlineData("adapter")]
    public async Task ExporterRestartsThroughTheRealProbeWithoutPersistingFailures(string adapter)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        try
        {
            var calls = new List<string>();
            var probe = new EncoderProbe(_ => new(adapter, "driver", "test-build"), (name, ct) => new(name, true, null), () => directory);
            var exporter = new Exporter(new FrameComposer(new TestRasterizer()), probe, (job, encoder, progress, ct) =>
            {
                calls.Add(encoder);
                if (calls.Count == 1) throw new MediaException(-22, "Submit encoder frame", "transient driver failure", VoxClipErrorCode.ExportFailed);
                return new(job.OutputPath, null, 1, 2, 2, 30, 30, 48_000, 0, "h264", encoder, 0);
            }, (_, _) => { });
            var snapshot = new ComposeSnapshot(new("source.mp4", 1, new(2, 2, 30, 0), null, new(2, 2), "h264", null, false, 0, -1, 0),
                TestPlan.FromKept(48_000, 48_000, [new(0, 48_000)]), null, new(new(2, 2), 30, 1_000_000));
            var result = await exporter.ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, "unused.mp4", null), null, TestContext.Current.CancellationToken);
            Assert.Equal("h264_qsv", result.Encoder);
            Assert.Equal(new[] { "h264_nvenc", "h264_qsv" }, calls);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("Open h264_nvenc", -22, VoxClipErrorCode.EncoderUnavailable)]
    [InlineData("Submit encoder frame", -22, VoxClipErrorCode.ExportFailed)]
    [InlineData("Mux MP4 packet", -5, VoxClipErrorCode.ExportFailed)]
    [InlineData("Finalize MP4", -28, VoxClipErrorCode.DiskFull)]
    public void NativeExportErrorsKeepTheirExportClass(string operation, int error, VoxClipErrorCode code)
    {
        var failure = new MediaException(error, operation, "native failure", VoxClipErrorCode.ExportFailed);
        var mapped = ExportErrors.Map(failure, "output.mp4");
        Assert.Equal(code, mapped.Code);
        Assert.Equal(5, mapped.ExitCode);
        Assert.Same(failure, mapped.InnerException);
        if (code == VoxClipErrorCode.ExportFailed) Assert.Equal($"Export stopped: {operation}: native failure. Your edits are saved.", mapped.Message);
        if (error == -28) Assert.False(ExportErrors.IsEncoderFailure(failure));
    }

    [Theory]
    [InlineData(0x80070070, VoxClipErrorCode.DiskFull)]
    [InlineData(0x80070027, VoxClipErrorCode.DiskFull)]
    [InlineData(0x80070020, VoxClipErrorCode.ExportFailed)]
    public void IoErrorsDistinguishFullDiskAndLockedDestination(uint hresult, VoxClipErrorCode code)
    {
        var mapped = ExportErrors.Map(new IOException("write failed", unchecked((int)hresult)), "output.mp4");
        Assert.Equal(code, mapped.Code);
        if (hresult == 0x80070020) Assert.Contains("destination is in use", mapped.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task EncoderFailureRestartsOnlyOnceAndNormalizesTheLastFailure(bool failAgain)
    {
        var calls = new List<string>();
        var invalidated = new List<string>();
        var exporter = new Exporter(new FrameComposer(new TestRasterizer()), new AllEncoders(), (job, encoder, progress, ct) =>
        {
            calls.Add(encoder);
            if (calls.Count == 1 || failAgain) throw new MediaException(-22, "Submit encoder frame", "driver failed", VoxClipErrorCode.ExportFailed);
            return new(job.OutputPath, null, 1, 2, 2, 30, 30, 48_000, 0, "h264", encoder, 0);
        }, (key, encoder) => invalidated.Add(encoder));
        var snapshot = new ComposeSnapshot(new("source.mp4", 1, new(2, 2, 30, 0), null, new(2, 2), "h264", null, false, 0, -1, 0),
            TestPlan.FromKept(48_000, 48_000, [new(0, 48_000)]), null, new(new(2, 2), 30, 1_000_000));
        var job = new ExportJob(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, "output.mp4", null);
        if (failAgain)
        {
            var failure = await Assert.ThrowsAsync<VoxClipException>(() => exporter.ExportAsync(job, null, TestContext.Current.CancellationToken));
            Assert.Equal(VoxClipErrorCode.ExportFailed, failure.Code);
        }
        else Assert.Equal("h264_qsv", (await exporter.ExportAsync(job, null, TestContext.Current.CancellationToken)).Encoder);
        Assert.Equal(new[] { "h264_nvenc", "h264_qsv" }, calls);
        Assert.Equal(failAgain ? 2 : 1, invalidated.Count);
    }

    private sealed class AllEncoders : IEncoderProbe
    {
        public Task<IReadOnlyList<EncoderInfo>> ProbeAsync(EncoderCacheKey key, IProgress<MediaProgress>? progress, CancellationToken ct)
            => Task.FromResult<IReadOnlyList<EncoderInfo>>(EncoderProbe.Ladder.Select(name => new EncoderInfo(name, true, null)).ToArray());
    }
}
