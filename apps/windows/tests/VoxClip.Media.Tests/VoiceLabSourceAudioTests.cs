using System.Buffers.Binary;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Editing;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class VoiceLabSourceAudioTests
{
    private static CancellationToken Cancellation => TestContext.Current.CancellationToken;
    private static float Left(int frame) => ((frame * 7_919L) % 4_001 - 2_000) / 4_000f;
    private static float Right(int frame) => ((frame * 104_729L) % 3_001 - 1_500) / 6_000f;
    private static short Pcm(float sample) => (short)Math.Clamp(Math.Round((double)sample * 32_767, MidpointRounding.ToEven), -32_767, 32_767);

    private static string FloatWave(VoiceLabTestStorage storage, int rate, int frames, int channels = 2,
        Func<int, int, float>? value = null)
    {
        var path = Path.Combine(storage.Root, "source-" + Guid.NewGuid().ToString("N") + ".wav");
        using var writer = new BinaryWriter(File.Create(path));
        var dataSize = frames * channels * 4;
        writer.Write("RIFF"u8); writer.Write(36 + dataSize); writer.Write("WAVEfmt "u8); writer.Write(16);
        writer.Write((short)3); writer.Write((short)channels); writer.Write(rate); writer.Write(rate * channels * 4);
        writer.Write((short)(channels * 4)); writer.Write((short)32); writer.Write("data"u8); writer.Write(dataSize);
        for (var frame = 0; frame < frames; frame++)
            for (var channel = 0; channel < channels; channel++) writer.Write(value?.Invoke(frame, channel) ?? (channel == 0 ? Left(frame) : Right(frame)));
        return path;
    }

    private static void Header(byte[] wav, int rate, int frames)
    {
        Assert.Equal(44 + frames * 2, wav.Length);
        Assert.Equal("RIFF"u8.ToArray(), wav[..4]);
        Assert.Equal((uint)(wav.Length - 8), BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(4)));
        Assert.Equal("WAVEfmt "u8.ToArray(), wav[8..16]);
        Assert.Equal(16u, BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(16)));
        Assert.Equal(1, BinaryPrimitives.ReadUInt16LittleEndian(wav.AsSpan(20)));
        Assert.Equal(1, BinaryPrimitives.ReadUInt16LittleEndian(wav.AsSpan(22)));
        Assert.Equal((uint)rate, BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(24)));
        Assert.Equal((uint)(rate * 2), BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(28)));
        Assert.Equal(2, BinaryPrimitives.ReadUInt16LittleEndian(wav.AsSpan(32)));
        Assert.Equal(16, BinaryPrimitives.ReadUInt16LittleEndian(wav.AsSpan(34)));
        Assert.Equal("data"u8.ToArray(), wav[36..40]);
        Assert.Equal((uint)(frames * 2), BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(40)));
    }

    private static void Refuses(VoiceLabSourceAudioErrorCode code, Action action)
        => Assert.Equal(code, Assert.Throws<VoiceLabSourceAudioException>(action).Code);
    private static async Task RefusesAsync(VoiceLabSourceAudioErrorCode code, Func<Task> action)
        => Assert.Equal(code, (await Assert.ThrowsAsync<VoiceLabSourceAudioException>(action)).Code);

    public static TheoryData<JsonElement> ContinuityCases
    {
        get
        {
            using var document = FixtureLoader.ReadJson("fixtures/voice-lab/continuity-cases.json");
            Assert.Equal(60, document.RootElement.GetProperty("caseCount").GetInt32());
            TheoryData<JsonElement> result = [];
            foreach (var row in document.RootElement.GetProperty("cases").EnumerateArray()) result.Add(row.Clone());
            Assert.Equal(60, result.Count);
            return result;
        }
    }

    [Theory]
    [MemberData(nameof(ContinuityCases))]
    public void SharedContinuityVectorsUseProductionPlacement(JsonElement row)
    {
        var expected = row.GetProperty("expected");
        var timestamp = row.GetProperty("timestamp");
        var previous = row.GetProperty("previousEnd");
        long? previousEnd = previous.ValueKind == JsonValueKind.Null ? null : previous.GetInt64();
        long Place() => VoiceLabSourceAudio.SourceFrame(
            timestamp.ValueKind == JsonValueKind.Null ? ffmpeg.AV_NOPTS_VALUE : timestamp.GetProperty("value").GetInt64(),
            row.GetProperty("origin").GetDouble(), previousEnd, row.GetProperty("rate").GetInt32(),
            timestamp.ValueKind == JsonValueKind.Null ? 1 : timestamp.GetProperty("numerator").GetInt32(),
            timestamp.ValueKind == JsonValueKind.Null ? 1 : timestamp.GetProperty("denominator").GetInt32());
        var error = expected.TryGetProperty("error", out var refusal) ? refusal.GetString() : null;
        if (error == "unreadable")
        {
            Refuses(VoiceLabSourceAudioErrorCode.Unreadable, () => Place());
            return;
        }
        var first = Place();
        Assert.Equal(expected.GetProperty("firstSample").GetInt64(), first);
        var next = row.GetProperty("nextSample").GetInt64();
        if (error == "rangeOutsideMedia") Assert.True(first > next, row.GetProperty("name").GetString());
        else
        {
            Assert.True(first <= next, row.GetProperty("name").GetString());
            var skip = Math.Min(row.GetProperty("sampleCount").GetInt64(), next - first);
            Assert.Equal(expected.GetProperty("skipCount").GetInt64(), skip);
        }
    }

    [Theory]
    [InlineData(-0.6, null, -1)]
    [InlineData(-0.6, 0L, 0)]
    [InlineData(4799.4, null, 4799)]
    [InlineData(4799.4, 4800L, 4800)]
    public void FirstFrameUsesItsOwnHalfUpAnchorAndNegativeOverlap(double exact, long? previousEnd, long first)
        => Assert.Equal(first, VoiceLabSourceAudio.SourceFrame(exact, previousEnd, 48_000, 1, 48_000));

    [Theory]
    [InlineData(double.NegativeInfinity)]
    [InlineData(double.PositiveInfinity)]
    [InlineData(double.NaN)]
    [InlineData(-9.223372036854776e18)]
    [InlineData(4.611686018427388e18)]
    public void NonfiniteAndOverflowingPositionsAreUnreadable(double position)
        => Refuses(VoiceLabSourceAudioErrorCode.Unreadable,
            () => VoiceLabSourceAudio.SourceFrame(position, null, 48_000, 1, 48_000));

    [Theory]
    [InlineData(1024.0, 1024)]
    [InlineData(1071.9999999999998, 1024)]
    [InlineData(976.0000000000001, 1024)]
    [InlineData(1072.0, 1072)]
    [InlineData(976.0, 976)]
    [InlineData(1048.0, 1024)]
    [InlineData(1000.0, 1024)]
    public void MillisecondTimestampContinuityIsStrictlyBoundedByOneTick(double exact, long first)
        => Assert.Equal(first, VoiceLabSourceAudio.SourceFrame(exact, 1024, 48_000, 1, 1_000));

    [Theory]
    [InlineData(48_000, 90_000, 1024.75, 1024)]
    [InlineData(48_000, 90_000, 1023.25, 1024)]
    [InlineData(48_000, 90_000, 1025.0, 1025)]
    [InlineData(48_000, 90_000, 1023.0, 1023)]
    [InlineData(96_000, 90_000, 1025.0625, 1024)]
    [InlineData(96_000, 90_000, 1022.9375, 1024)]
    [InlineData(96_000, 90_000, 1025.125, 1025)]
    [InlineData(96_000, 90_000, 1022.875, 1023)]
    [InlineData(48_000, 48_000, 1024.0, 1024)]
    [InlineData(48_000, 48_000, 1024.75, 1024)]
    [InlineData(48_000, 48_000, 1023.25, 1024)]
    [InlineData(48_000, 48_000, 1025.0, 1025)]
    [InlineData(48_000, 48_000, 1023.0, 1023)]
    [InlineData(48_000, 48_000, 1072.0, 1072)]
    public void FineTimestampContinuityUsesTheUnroundedTickWithAOneSampleMinimum(int rate, int denominator, double exact, long first)
        => Assert.Equal(first, VoiceLabSourceAudio.SourceFrame(exact, 1024, rate, 1, denominator));

    [Fact]
    public void RepeatedFortySampleGapsCannotAccumulatePastOneTick()
    {
        var first = VoiceLabSourceAudio.SourceFrame(0, null, 48_000, 1, 1_000);
        Assert.Equal(0, first);
        var previousEnd = first + 960;
        first = VoiceLabSourceAudio.SourceFrame(1000, previousEnd, 48_000, 1, 1_000);
        Assert.Equal(previousEnd, first);
        previousEnd = first + 960;
        first = VoiceLabSourceAudio.SourceFrame(2000, previousEnd, 48_000, 1, 1_000);
        Assert.Equal(2000, first);
        Assert.True(first > previousEnd);
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(2.0)]
    [InlineData(double.NaN)]
    public void MissingInitialTimestampIsUnreadable(double origin)
        => Refuses(VoiceLabSourceAudioErrorCode.Unreadable,
            () => VoiceLabSourceAudio.SourceFrame(ffmpeg.AV_NOPTS_VALUE, origin, null, 48_000, 1, 1_000));

    [Theory]
    [InlineData(0.0)]
    [InlineData(2.0)]
    [InlineData(double.NaN)]
    public void MissingMidstreamTimestampUsesPreviousDecodedEnd(double origin)
        => Assert.Equal(1_920, VoiceLabSourceAudio.SourceFrame(ffmpeg.AV_NOPTS_VALUE, origin, 1_920, 48_000, 1, 1_000));

    [Theory]
    [InlineData(1_003, 0.0, 48_000, 1_000, 48_144)]
    [InlineData(3_003, 2.0, 48_000, 1_000, 48_144)]
    [InlineData(1_024, 0.0, 48_000, 48_000, 1_024)]
    [InlineData(8_192, 1.0, 8_000, 8_000, 192)]
    public void TimestampedFramesKeepTheDecodeSessionOriginAndHalfUpAnchor(long timestamp, double origin, int rate, int denominator, long first)
        => Assert.Equal(first, VoiceLabSourceAudio.SourceFrame(timestamp, origin, null, rate, 1, denominator));

    [Fact]
    public async Task ConversionRefusalsPrecedeOpeningTheSourceOrLoadingNativeCode()
    {
        using var storage = new VoiceLabTestStorage();
        var missing = Path.Combine(storage.Root, "missing.wav");
        foreach (var rate in new[] { 7_999, 96_001, 44_100.5, double.NaN, double.PositiveInfinity, -48_000 })
            await RefusesAsync(VoiceLabSourceAudioErrorCode.UnsupportedRate, () => VoiceLabSourceAudio.ConversionInputAsync(missing, 0, 48_000, rate, Cancellation));
        foreach (var (start, end) in new[] { (-1L, 48_000L), (500L, 500L), (500L, 499L) })
            await RefusesAsync(VoiceLabSourceAudioErrorCode.RangeOutsideMedia, () => VoiceLabSourceAudio.ConversionInputAsync(missing, start, end, 48_000, Cancellation));
        await RefusesAsync(VoiceLabSourceAudioErrorCode.TooShort, () => VoiceLabSourceAudio.ConversionInputAsync(missing, 0, 959, 48_000, Cancellation));
        await RefusesAsync(VoiceLabSourceAudioErrorCode.TooLong, () => VoiceLabSourceAudio.ConversionInputAsync(missing, 0, 13_920_001, 48_000, Cancellation));
        await RefusesAsync(VoiceLabSourceAudioErrorCode.TooLarge, () => VoiceLabSourceAudio.ConversionInputAsync(missing, 0, 24_999_978, 96_000, Cancellation));
        Assert.False(Directory.Exists(storage.PaidRoot));
    }

    [Theory]
    [InlineData(8_000, 160, 2_320_000)]
    [InlineData(11_025, 221, 3_197_250)]
    [InlineData(44_100, 882, 12_789_000)]
    [InlineData(48_000, 960, 13_920_000)]
    [InlineData(86_200, 1724, 24_998_000)]
    [InlineData(86_206, 1725, 24_999_740)]
    [InlineData(86_207, 1725, 24_999_977)]
    [InlineData(88_200, 1764, 24_999_977)]
    [InlineData(96_000, 1920, 24_999_977)]
    public void ConversionBoundsMatchTheMacIncludingThe50MbCrossover(int rate, int minimum, int maximum)
    {
        using var storage = new VoiceLabTestStorage();
        Assert.Equal((rate, minimum), VoiceLabSourceAudio.ConversionChunk(7, 7 + minimum, rate));
        Refuses(VoiceLabSourceAudioErrorCode.TooShort, () => VoiceLabSourceAudio.ConversionChunk(7, 6 + minimum, rate));
        Assert.Equal((rate, maximum), VoiceLabSourceAudio.ConversionChunk(7, 7 + maximum, rate));
        Assert.True(44L + maximum * 2L < 50_000_000);
        Refuses(maximum == rate * 290 ? VoiceLabSourceAudioErrorCode.TooLong : VoiceLabSourceAudioErrorCode.TooLarge,
            () => VoiceLabSourceAudio.ConversionChunk(7, 8 + maximum, rate));
    }

    [Fact]
    public void DecodeRefusesInvalidRateFormatAndUnsafeFilesBeforeNativeCode()
    {
        using var storage = new VoiceLabTestStorage();
        var path = Path.Combine(storage.Root, "missing.wav");
        foreach (var rate in new[] { 0, 7_999, 192_001 })
            Refuses(VoiceLabSourceAudioErrorCode.UnsupportedRate, () => VoiceLabSourceAudio.DecodeAsset(path, rate, cancellationToken: Cancellation));
        Refuses(VoiceLabSourceAudioErrorCode.UnsupportedFormat, () => VoiceLabSourceAudio.DecodeAsset(path + ".flac", 48_000, cancellationToken: Cancellation));
        Refuses(VoiceLabSourceAudioErrorCode.Unreadable, () => VoiceLabSourceAudio.DecodeAsset(path, 48_000, cancellationToken: Cancellation));
        Directory.CreateDirectory(path);
        Refuses(VoiceLabSourceAudioErrorCode.Unreadable, () => VoiceLabSourceAudio.DecodeAsset(path, 48_000, cancellationToken: Cancellation));
        Directory.Delete(path); File.WriteAllBytes(path, []);
        Refuses(VoiceLabSourceAudioErrorCode.Unreadable, () => VoiceLabSourceAudio.DecodeAsset(path, 48_000, cancellationToken: Cancellation));
        var valid = FloatWave(storage, 48_000, 2_000);
        Refuses(VoiceLabSourceAudioErrorCode.Altered, () => VoiceLabSourceAudio.DecodeAsset(valid, 48_000, new string('0', 64), Cancellation));
        string? snapshot = null;
        using var cancelled = new CancellationTokenSource();
        Assert.Throws<OperationCanceledException>(() => VoiceLabSourceAudio.DecodeAsset(valid, 48_000, null, cancelled.Token,
            checkedPath => { snapshot = checkedPath; cancelled.Cancel(); }));
        Assert.NotNull(snapshot); Assert.False(Directory.Exists(Path.GetDirectoryName(snapshot)));
        Assert.True(File.Exists(valid));
        if (!OperatingSystem.IsWindows())
        {
            File.Delete(path); File.CreateSymbolicLink(path, valid);
            Refuses(VoiceLabSourceAudioErrorCode.Unreadable, () => VoiceLabSourceAudio.DecodeAsset(path, 48_000, cancellationToken: Cancellation));
        }
    }

    [Theory]
    [InlineData(8_000)]
    [InlineData(11_025)]
    [InlineData(24_000)]
    [InlineData(44_100)]
    [InlineData(48_000)]
    [InlineData(192_000)]
    public void EnvelopeExactlyMatchesCoreAndOmitsThePartialFinalFrame(int rate)
    {
        using var storage = new VoiceLabTestStorage();
        var samples = Enumerable.Range(0, rate / 3 + 17).Select(Left).ToArray();
        var builder = new AudioEnvelopeBuilder(rate, 1);
        builder.Append(samples.AsSpan(0, 11)); builder.Append(samples.AsSpan(11));
        var expected = builder.Finish(); var actual = VoiceLabSourceAudio.Envelope(samples, rate);
        Assert.Equal(expected.SampleRate, actual.SampleRate); Assert.Equal(expected.FrameSeconds, actual.FrameSeconds);
        Assert.Equal(expected.Rms, actual.Rms);
        Assert.Equal(samples.Length / (int)Math.Floor(rate * 0.01 + 0.5), actual.Rms.Count);
        Assert.Empty(VoiceLabSourceAudio.Envelope([], rate).Rms);
    }

    [Theory, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    [InlineData(8_000)]
    [InlineData(11_025)]
    [InlineData(24_000)]
    [InlineData(44_100)]
    [InlineData(48_000)]
    [InlineData(96_000)]
    public async Task StereoFloatExtractionIsTheMeanOnTheExactHalfOpenSourceGrid(int rate)
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        var path = FloatWave(storage, rate, rate + 123);
        const int start = 123;
        var end = rate - 17;
        var wav = await VoiceLabSourceAudio.ConversionInputAsync(path, start, end, rate, Cancellation);
        Header(wav, rate, end - start);
        for (var index = 0; index < end - start; index++)
        {
            var mean = (float)(((double)Left(start + index) + Right(start + index)) / 2);
            var actual = BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(44 + index * 2));
            Assert.InRange(Math.Abs(actual - Pcm(mean)), 0, 1);
        }
        var tail = Math.Max(1000, (rate + 49) / 50);
        var last = await VoiceLabSourceAudio.ConversionInputAsync(path, rate - tail, rate + 123, rate, Cancellation);
        Header(last, rate, tail + 123);
        await RefusesAsync(VoiceLabSourceAudioErrorCode.RangeOutsideMedia,
            () => VoiceLabSourceAudio.ConversionInputAsync(path, rate - tail, rate + 124, rate, Cancellation));
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task MonoPcmExtractionStaysWithinOneLsbAndDoesNotResample()
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        var pcm = new byte[24_000 * 2];
        for (var index = 0; index < 24_000; index++) BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(index * 2), (short)((index * 7919L) % 65001 - 32500));
        var asset = VoiceLabAssetStore.Write(pcm, 24_000, storage.ProjectId, "mono", storage.PaidRoot, DateTimeOffset.UtcNow, Cancellation);
        var wav = await VoiceLabSourceAudio.ConversionInputAsync(storage.AssetPath(asset), 731, 23_001, 24_000, Cancellation);
        Header(wav, 24_000, 22_270);
        for (var index = 0; index < 22_270; index++)
            Assert.InRange(Math.Abs(BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(44 + index * 2)) -
                BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan((731 + index) * 2))), 0, 1);
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task ExtractionRefusesRateMismatchMissingCoverageAndNonfiniteSamples()
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        var path = FloatWave(storage, 48_000, 48_000);
        await RefusesAsync(VoiceLabSourceAudioErrorCode.RateMismatch, () => VoiceLabSourceAudio.ConversionInputAsync(path, 0, 24_000, 24_000, Cancellation));
        await RefusesAsync(VoiceLabSourceAudioErrorCode.RangeOutsideMedia, () => VoiceLabSourceAudio.ConversionInputAsync(path, 48_001, 49_001, 48_000, Cancellation));
        await RefusesAsync(VoiceLabSourceAudioErrorCode.RangeOutsideMedia,
            () => VoiceLabSourceAudio.ConversionInputAsync(path, long.MaxValue - 2000, long.MaxValue, 48_000, Cancellation));
        var malformed = FloatWave(storage, 48_000, 48_000, value: (_, _) => float.NaN);
        await RefusesAsync(VoiceLabSourceAudioErrorCode.InvalidAudio, () => VoiceLabSourceAudio.ConversionInputAsync(malformed, 0, 48_000, 48_000, Cancellation));
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => VoiceLabSourceAudio.ConversionInputAsync(path, 0, 48_000, 48_000, cancelled.Token));
        await RefusesAsync(VoiceLabSourceAudioErrorCode.NoAudioTrack,
            () => VoiceLabSourceAudio.ConversionInputAsync(NativeTest.Fixture("bars-4k.mkv"), 0, 48_000, 48_000, Cancellation));
        var malformedAsset = Path.Combine(storage.Root, "malformed.wav"); File.WriteAllText(malformedAsset, "not audio");
        Refuses(VoiceLabSourceAudioErrorCode.UnsupportedFormat, () => VoiceLabSourceAudio.DecodeAsset(malformedAsset, 48_000, cancellationToken: Cancellation));
        var excessiveChannels = FloatWave(storage, 48_000, 2_000, channels: 9);
        Refuses(VoiceLabSourceAudioErrorCode.UnsupportedFormat, () => VoiceLabSourceAudio.DecodeAsset(excessiveChannels, 48_000, cancellationToken: Cancellation));
        Refuses(VoiceLabSourceAudioErrorCode.InvalidAudio, () => VoiceLabSourceAudio.DecodeAsset(malformed, 48_000, cancellationToken: Cancellation));
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task WindowsWriterRefusesProjectJunctionAndPinsTheDirectoryDuringPublication()
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        Directory.CreateDirectory(storage.PaidRoot);
        var outside = Directory.CreateDirectory(Path.Combine(storage.Root, "outside")).FullName;
        var project = Path.Combine(storage.PaidRoot, storage.ProjectId);
        var start = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var argument in new[] { "/d", "/c", "mklink", "/J", project, outside }) start.ArgumentList.Add(argument);
        using (var process = Process.Start(start)!)
        {
            await process.WaitForExitAsync(Cancellation);
            Assert.Equal(0, process.ExitCode);
        }
        try
        {
            var failure = Assert.Throws<VoiceLabAssetStoreException>(() => VoiceLabAssetStore.Write([1, 0], 24_000,
                storage.ProjectId, "linked", storage.PaidRoot, DateTimeOffset.UtcNow, Cancellation));
            Assert.Equal(VoiceLabAssetStoreErrorCode.UnsafePath, failure.Code);
            Assert.Empty(Directory.GetFileSystemEntries(outside));
        }
        finally { Directory.Delete(project); }
        var asset = VoiceLabAssetStore.Write([1, 0], 24_000, storage.ProjectId, "pinned", storage.PaidRoot,
            DateTimeOffset.UtcNow, Cancellation, () => Assert.Throws<IOException>(() => Directory.Move(project, project + "-moved")), null);
        Assert.True(File.Exists(storage.AssetPath(asset)));
    }

    [Theory, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    [InlineData(24_000, 48_000)]
    [InlineData(48_000, 24_000)]
    [InlineData(44_100, 48_000)]
    [InlineData(48_000, 44_100)]
    public async Task StoredAssetResamplesToSourceRateWithAlignedImpulseAndExpectedLength(int rate, int target)
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        var frames = rate + 31;
        var impulse = rate / 4;
        var samples = new float[frames]; samples[impulse] = 0.9f;
        var asset = VoiceLabAssetStore.WriteDerived(samples, rate, storage.ProjectId, "impulse", storage.PaidRoot, DateTimeOffset.UtcNow, Cancellation);
        var decoded = VoiceLabSourceAudio.DecodeAsset(storage.AssetPath(asset), target, asset.Sha256, Cancellation);
        var expected = (int)Math.Floor(frames * (double)target / rate + 0.5);
        Assert.InRange(decoded.Length, expected - 1, expected + 1);
        var peak = Enumerable.Range(0, decoded.Length).MaxBy(index => Math.Abs(decoded[index]));
        Assert.InRange(peak, (int)Math.Round(impulse * (double)target / rate) - 1, (int)Math.Round(impulse * (double)target / rate) + 1);
        Assert.True(Math.Abs(decoded[peak]) > 0.3);
    }

    [Theory, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    [InlineData(1, 24_000, 48_000)]
    [InlineData(8, 48_000, 24_000)]
    [InlineData(31, 44_100, 48_000)]
    [InlineData(1, 192_000, 8_000)]
    public async Task ShortStoredAssetsDrainTheFilterWithoutInventingExtraDuration(int frames, int rate, int target)
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        var samples = new float[frames]; samples[0] = 0.9f;
        var asset = VoiceLabAssetStore.WriteDerived(samples, rate, storage.ProjectId, "short", storage.PaidRoot, DateTimeOffset.UtcNow, Cancellation);
        var decoded = VoiceLabSourceAudio.DecodeAsset(storage.AssetPath(asset), target, asset.Sha256, Cancellation);
        var expected = (int)Math.Floor(frames * (double)target / rate + 0.5);
        Assert.Equal(expected, decoded.Length);
        if (expected > 0) Assert.True(Math.Abs(decoded[0]) > 0.1);
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task ConversionDoesNotApplyThePaidAssetChannelCapToTheOriginalSource()
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        var path = FloatWave(storage, 48_000, 2_000, channels: 16, value: (_, channel) => channel / 32f);
        var wav = await VoiceLabSourceAudio.ConversionInputAsync(path, 0, 2_000, 48_000, Cancellation);
        Header(wav, 48_000, 2_000);
        for (var index = 0; index < 2_000; index++)
            Assert.Equal(Pcm(7.5f / 32), BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(44 + index * 2)));
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task StoredAssetDecodesTheCheckedDescriptorEvenWhenThePathIsReplaced()
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        var path = FloatWave(storage, 48_000, 48_017);
        var expectedHash = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
        string? snapshot = null;
        var decoded = VoiceLabSourceAudio.DecodeAsset(path, 48_000, expectedHash, Cancellation, checkedPath =>
        {
            snapshot = checkedPath;
            File.Move(path, path + ".original"); File.WriteAllText(path, "not the checked audio");
        });
        Assert.Equal(48_017, decoded.Length);
        foreach (var index in new[] { 0, 1, 123, 4096, 48_016 })
            Assert.Equal((float)(((double)Left(index) + Right(index)) / 2), decoded[index]);
        Assert.NotNull(snapshot); Assert.False(Directory.Exists(Path.GetDirectoryName(snapshot)));
        var builder = new AudioEnvelopeBuilder(48_000, 1); builder.Append(decoded);
        Assert.Equal(builder.Finish().Rms, VoiceLabSourceAudio.Envelope(decoded, 48_000).Rms);
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task CommittedCoarseTimestampContainerExtractsEverySampleAcrossPacketsWithoutChangingFixture()
    {
        await NativeTest.RequireAsync(windows: true);
        using (var storage = new VoiceLabTestStorage())
        {
            var path = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "voice-lab-7s.mkv");
            NativeTest.Require(File.Exists(path), "The committed Voice Lab seven-second container is required.");
            var hash = SHA256.HashData(File.ReadAllBytes(path));
            Assert.Equal("6be0c2e01c675805f2cb61b0e0a31ec1980be433a23daf8897ebb18443cbcf39", Convert.ToHexStringLower(hash));
            const int start = 123, end = 96_517;
            var wav = await VoiceLabSourceAudio.ConversionInputAsync(path, start, end, 48_000, Cancellation);
            Header(wav, 48_000, end - start);
            using var reference = new AudioDecoder(path);
            var values = new float[end * reference.Channels];
            Assert.Equal(end, reference.Read(values, end, Cancellation));
            for (var index = start; index < end; index++)
            {
                double sum = 0;
                for (var channel = 0; channel < reference.Channels; channel++) sum += values[index * reference.Channels + channel];
                var actual = BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(44 + (index - start) * 2));
                Assert.Equal(Pcm((float)(sum / reference.Channels)), actual);
            }
            var extracted = VoiceLabAssetStore.Write(wav.AsSpan(44), 48_000, storage.ProjectId, "container", storage.PaidRoot, DateTimeOffset.UtcNow, Cancellation);
            var decoded = VoiceLabSourceAudio.DecodeAsset(storage.AssetPath(extracted), 24_000, extracted.Sha256, Cancellation);
            Assert.InRange(decoded.Length, (end - start) / 2 - 1, (end - start) / 2 + 1);
            Assert.Equal(hash, SHA256.HashData(File.ReadAllBytes(path)));
        }
        VoiceLabTestStorage.NativePassed(nameof(CommittedCoarseTimestampContainerExtractsEverySampleAcrossPacketsWithoutChangingFixture));
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task CommittedCoarseTimestampNonzeroSeekMatchesEveryDecodeSessionSample()
    {
        await NativeTest.RequireAsync(windows: true);
        using (var storage = new VoiceLabTestStorage())
        {
            var path = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "voice-lab-7s.mkv");
            var hash = SHA256.HashData(File.ReadAllBytes(path));
            Assert.Equal("6be0c2e01c675805f2cb61b0e0a31ec1980be433a23daf8897ebb18443cbcf39", Convert.ToHexStringLower(hash));
            const int start = 96_000, end = 144_017;
            var reference = TimestampAnchoredSamples(path, start, end);
            var wav = await VoiceLabSourceAudio.ConversionInputAsync(path, start, end, 48_000, Cancellation);
            Header(wav, 48_000, end - start);
            for (var index = 0; index < reference.Samples.Length; index++)
                Assert.Equal(reference.Samples[index], BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(44 + index * 2)));
            Assert.Equal(hash, SHA256.HashData(File.ReadAllBytes(path)));
        }
        VoiceLabTestStorage.NativePassed(nameof(CommittedCoarseTimestampNonzeroSeekMatchesEveryDecodeSessionSample));
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task ExtractionAndDecodeSessionShareTheNonzeroSeekAnchor()
    {
        await NativeTest.RequireAsync(windows: true);
        long offset;
        double tick;
        using (var storage = new VoiceLabTestStorage())
        {
            var path = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "voice-lab-7s.mkv");
            var hash = SHA256.HashData(File.ReadAllBytes(path));
            Assert.Equal("6be0c2e01c675805f2cb61b0e0a31ec1980be433a23daf8897ebb18443cbcf39", Convert.ToHexStringLower(hash));
            const int start = 96_000, end = 98_123;
            var reference = TimestampAnchoredSamples(path, start, end);
            var anchor = Native.Round(reference.Precise);
            Assert.Equal(anchor, VoiceLabSourceAudio.SourceFrame(reference.Timestamp, 0, null, 48_000, 1, 1_000));
            var sequentialAnchor = SequentialFrameForTimestamp(path, reference.Timestamp);
            Assert.Equal(48_144, anchor);
            Assert.Equal(48_128, sequentialAnchor);
            offset = anchor - sequentialAnchor;
            tick = reference.Tick;
            Assert.Equal(16, offset);
            Assert.Equal(48, tick);
            Assert.True(Math.Abs(offset) < tick);
            using var sequential = new AudioDecoder(path);
            Assert.Equal(1, sequential.Channels);
            var values = new float[end];
            Assert.Equal(end, sequential.Read(values, end, Cancellation));
            Assert.NotEqual(Pcm(values[start]), Pcm(values[start - (int)offset]));
            var wav = await VoiceLabSourceAudio.ConversionInputAsync(path, start, end, 48_000, Cancellation);
            Header(wav, 48_000, end - start);
            for (var index = 0; index < end - start; index++)
            {
                var actual = BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(44 + index * 2));
                Assert.Equal(reference.Samples[index], actual);
                Assert.Equal(Pcm(values[start + index - (int)offset]), actual);
            }
            Assert.Equal(hash, SHA256.HashData(File.ReadAllBytes(path)));
        }
        VoiceLabTestStorage.NativePassed($"{nameof(ExtractionAndDecodeSessionShareTheNonzeroSeekAnchor)} (offsetSamples={offset}, tickSamples={tick})");
    }

    private static unsafe (short[] Samples, long Timestamp, double Precise, double Tick) TimestampAnchoredSamples(string path, int start, int end)
    {
        using var decoder = new DecodeSession(path, AVMediaType.AVMEDIA_TYPE_AUDIO);
        Assert.Equal(48_000, decoder.Codec->sample_rate);
        Assert.Equal(1, decoder.Stream->time_base.num);
        Assert.Equal(1_000, decoder.Stream->time_base.den);
        Assert.Equal(0, decoder.Origin);
        decoder.Seek(start / 48_000d - 0.5);
        Assert.True(decoder.Next(Cancellation));
        var timestamp = decoder.Frame->best_effort_timestamp;
        Assert.NotEqual(ffmpeg.AV_NOPTS_VALUE, timestamp);
        var precise = decoder.Timestamp * 48_000;
        var tick = 48_000d * decoder.Stream->time_base.num / decoder.Stream->time_base.den;
        var first = Native.Round(precise);
        var samples = new short[end - start];
        var copied = 0;
        do
        {
            Assert.Equal((int)AVSampleFormat.AV_SAMPLE_FMT_S16, decoder.Frame->format);
            Assert.Equal(1, decoder.Frame->ch_layout.nb_channels);
            Assert.True(Math.Abs(decoder.Timestamp * 48_000 - first) < tick);
            var values = (short*)decoder.Frame->extended_data[0];
            for (var index = 0; index < decoder.Frame->nb_samples; index++)
                if (first + index >= start && first + index < end)
                    samples[copied++] = Pcm(values[index] / 32_768f);
            first += decoder.Frame->nb_samples;
        } while (first < end && decoder.Next(Cancellation));
        Assert.Equal(samples.Length, copied);
        return (samples, timestamp, precise, tick);
    }

    private static unsafe long SequentialFrameForTimestamp(string path, long timestamp)
    {
        using var decoder = new DecodeSession(path, AVMediaType.AVMEDIA_TYPE_AUDIO);
        long samples = 0;
        while (decoder.Next(Cancellation))
        {
            if (decoder.Frame->best_effort_timestamp == timestamp) return samples;
            samples += decoder.Frame->nb_samples;
        }
        throw new InvalidOperationException("The seek anchor is absent from sequential fixture decoding.");
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task ContinuousContainerExtractsExactlyAcrossPacketBoundaries()
    {
        await NativeTest.RequireAsync(windows: true);
        using (var storage = new VoiceLabTestStorage())
        {
            var path = await TimestampContainerAsync(storage, gapSamples: 0);
            AssertContainerTimestamps(path, 1_000, 0);
            const int start = 123, end = 9_517;
            var wav = await VoiceLabSourceAudio.ConversionInputAsync(path, start, end, 48_000, Cancellation);
            Header(wav, 48_000, end - start);
            for (var frame = start; frame < end; frame++)
                Assert.Equal(Pcm((float)(((double)Left(frame) + Right(frame)) / 2)),
                    BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(44 + (frame - start) * 2)));
        }
        VoiceLabTestStorage.NativePassed(nameof(ContinuousContainerExtractsExactlyAcrossPacketBoundaries));
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task ContainerWithTwoMillisecondTimestampGapIsRefused()
    {
        await NativeTest.RequireAsync(windows: true);
        using (var storage = new VoiceLabTestStorage())
        {
            var path = await TimestampContainerAsync(storage, gapSamples: 96);
            AssertContainerTimestamps(path, 1_000, 96);
            await RefusesAsync(VoiceLabSourceAudioErrorCode.RangeOutsideMedia,
                () => VoiceLabSourceAudio.ConversionInputAsync(path, 0, 9_600, 48_000, Cancellation));
        }
        VoiceLabTestStorage.NativePassed(nameof(ContainerWithTwoMillisecondTimestampGapIsRefused));
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task SampleAccurateMp4WithOneSampleTimestampGapIsRefused()
    {
        await NativeTest.RequireAsync(windows: true);
        using (var storage = new VoiceLabTestStorage())
        {
            var path = await TimestampContainerAsync(storage, gapSamples: 1, sampleAccurate: true);
            AssertContainerTimestamps(path, 48_000, 1);
            await RefusesAsync(VoiceLabSourceAudioErrorCode.RangeOutsideMedia,
                () => VoiceLabSourceAudio.ConversionInputAsync(path, 0, 9_600, 48_000, Cancellation));
        }
        VoiceLabTestStorage.NativePassed(nameof(SampleAccurateMp4WithOneSampleTimestampGapIsRefused));
    }

    private static unsafe void AssertContainerTimestamps(string path, int denominator, int gapSamples)
    {
        using var decoder = new DecodeSession(path, AVMediaType.AVMEDIA_TYPE_AUDIO);
        Assert.Equal(48_000, decoder.Codec->sample_rate);
        Assert.Equal(1, decoder.Stream->time_base.num);
        Assert.Equal(denominator, decoder.Stream->time_base.den);
        long decoded = 0;
        while (decoder.Next(Cancellation))
        {
            var timestampSamples = decoder.Frame->best_effort_timestamp * 48_000;
            Assert.Equal(0, timestampSamples % denominator);
            Assert.Equal(decoded + (decoded >= 4_800 ? gapSamples : 0), timestampSamples / denominator);
            Assert.Equal(960, decoder.Frame->nb_samples);
            decoded += decoder.Frame->nb_samples;
        }
        Assert.Equal(9_600, decoded);
    }

    private static async Task<string> TimestampContainerAsync(VoiceLabTestStorage storage, int gapSamples, bool sampleAccurate = false)
    {
        var source = FloatWave(storage, 48_000, 9_600);
        var path = Path.Combine(storage.Root, "timestamps-" + gapSamples + (sampleAccurate ? ".mp4" : ".mkv"));
        var tools = Environment.GetEnvironmentVariable("VOXCLIP_FFMPEG_DIR");
        NativeTest.Require(!string.IsNullOrEmpty(tools) && File.Exists(Path.Combine(tools, "ffmpeg.exe")),
            "The native timestamp tests need the pinned FFmpeg test-tools executable.");
        var start = new ProcessStartInfo(Path.Combine(tools!, "ffmpeg.exe"))
        {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true
        };
        foreach (var argument in new[] { "-nostdin", "-hide_banner", "-v", "error", "-i", source, "-af",
            "asetnsamples=n=960:p=0,asetpts='PTS+gte(N,4800)*" + gapSamples + "'",
            "-c:a", "pcm_f32le" }) start.ArgumentList.Add(argument);
        if (sampleAccurate)
            foreach (var argument in new[] { "-movflags", "+frag_every_frame+empty_moov" }) start.ArgumentList.Add(argument);
        foreach (var argument in new[] { "-f", sampleAccurate ? "mp4" : "matroska", path }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var stdout = process.StandardOutput.ReadToEndAsync(Cancellation);
        var stderr = process.StandardError.ReadToEndAsync(Cancellation);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(Cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(CancellationToken.None); } throw; }
        await stdout;
        var errors = await stderr;
        Assert.True(process.ExitCode == 0, "Timestamp container generation failed: " + errors);
        return path;
    }
}
