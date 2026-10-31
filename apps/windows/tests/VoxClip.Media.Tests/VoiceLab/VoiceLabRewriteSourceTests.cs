using System.Buffers.Binary;
using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>Rewrite takes on long recordings, as on the Mac (d2851910, d4dfef26, 2a906dcf): the source is streamed once for its
/// envelope, and only the regions a take run reads are decoded, so no length is refused.</summary>
public sealed class VoiceLabRewriteSourceTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    /// <summary>Sample-unique PCM16, so a shifted cut, a lost chunk or a misplaced region cannot match (the Mac test's mono(_:)).</summary>
    private static short Speech(long frame) => (short)(frame * 7_919L % 65_001 - 32_500);
    private static TimedWord Word(string id, double start, double end) =>
        new(id, id, WordKind.Word, start, end, null, null, 1, null, TimingSource.Native);
    private static VoiceLabWindow Window(double start, double end, int rate, VoiceLabSeamKind kind = VoiceLabSeamKind.Hard)
    {
        var first = (long)Math.Round(start * rate, MidpointRounding.AwayFromZero);
        var last = (long)Math.Round(end * rate, MidpointRounding.AwayFromZero);
        long fade = kind == VoiceLabSeamKind.Hard ? 288 : rate / 50;
        return new("w", "w", [], [], start, end, first, last, new(kind, start, first, fade), new(kind, end, last, fade));
    }

    private static Func<string, long, long, double, CancellationToken, Task<byte[]>> Conversion(long total, Func<long, short> pcm,
        List<(long Start, long End)>? spans = null) => SourceConversion.Fake(total, pcm, spans);

    [Fact]
    public async Task RewriteSourceHoldsOnlyTheWindowAndRoomToneRegionsOfATrackPastTheOldCap()
    {
        // 30,000,001 frames at 8 kHz (62.5 minutes): one more than the old whole-track read accepted before reading anything.
        const int rate = 8_000;
        const long frames = 30_000_001;
        // Speech-like content everywhere except a silent stretch at 50.0–50.6 s, which only a gap in the words exposes.
        static short Pcm(long frame) => frame is >= 400_000 and < 404_800 ? (short)0 : Speech(frame);
        TimedWord[] items = [Word("a", 0, 49.9), Word("b", 50.7, 3_750)];
        var spans = new List<(long Start, long End)>();
        var result = await VoiceLabSourceAudio.RewriteSourceAsync("long-source", frames, rate, Window(30, 31, rate), null, null, items,
            Conversion(frames, Pcm, spans), Token);
        var whole = new float[frames];
        for (var frame = 0; frame < whole.Length; frame++) whole[frame] = Pcm(frame) / 32768f;
        // The streamed envelope is Core's envelope of the whole track.
        var envelope = VoiceLabTakeProcessing.Envelope(whole, rate);
        Assert.Equal(envelope.SampleRate, result.Envelope.SampleRate);
        Assert.Equal(envelope.FrameSeconds, result.Envelope.FrameSeconds);
        Assert.Equal(envelope.Rms, result.Envelope.Rms);
        Assert.Equal(400_000, VoiceLabRoomToneSelection.Select(items, result.Envelope, rate, frames).SourceStartSample);
        // One pass in 280 s chunks, then only two regions: 6 s around the window, and 1 s around the 0.5 s room-tone run.
        var expected = new List<(long Start, long End)>();
        for (long start = 0; start < frames; start += 2_240_000) expected.Add((start, Math.Min(frames, start + 2_240_000)));
        Assert.Equal(14, expected.Count);
        expected.Add((192_000, 296_000));
        expected.Add((392_000, 412_000));
        Assert.Equal(expected, spans);
        Assert.Equal(frames, result.Excerpt.TotalFrames);
        Assert.Equal(new long[] { 192_000, 392_000 }, result.Excerpt.Regions.Select(region => region.Start));
        Assert.Equal(new long[] { 296_000, 412_000 }, result.Excerpt.Regions.Select(region => region.End));
        foreach (var region in result.Excerpt.Regions)
            Assert.Equal(whole[(int)region.Start..(int)region.End], region.Samples.ToArray());
        Assert.Null(result.Excerpt.Samples(0, rate));
        Assert.NotNull(result.Excerpt.Samples(29 * rate, 32 * rate));
    }

    /// <summary>The chunk rule and PCM16 scale the whole-track read had (RewriteGenerationBackend.ReadSourceAsync): a remainder
    /// shorter than 20 ms joins the chunk before it, and a sample is its PCM16 value over 32,768, in the envelope and the regions.</summary>
    [Fact]
    public async Task AFinalRemainderShorterThan20MsJoinsTheChunkBeforeIt()
    {
        const int rate = 8_000;
        const long frames = 280L * rate + 100;
        var spans = new List<(long Start, long End)>();
        // One word spans the whole track, so it has no gap for a room-tone run and only the window's region is decoded.
        var result = await VoiceLabSourceAudio.RewriteSourceAsync("short-tail", frames, rate, Window(100, 101, rate), null, null,
            [Word("a", 0, frames / (double)rate)], Conversion(frames, _ => -16_384, spans), Token);
        // One envelope chunk with the 100-frame remainder, then the window's region.
        Assert.Equal(new (long Start, long End)[] { (0, frames), (752_000, 856_000) }, spans);
        Assert.Equal(frames / 80, result.Envelope.Rms.Count);
        Assert.All(result.Envelope.Rms, level => Assert.Equal(0.5f, level));
        var region = Assert.Single(result.Excerpt.Regions);
        Assert.Equal(752_000, region.Start);
        Assert.All(region.Samples.ToArray(), sample => Assert.Equal(-0.5f, sample));
    }

    [Fact]
    public async Task RewriteSourceRefusesOnlyUnsupportedRatesAndEmptyTracksBeforeReading()
    {
        var reads = 0;
        Func<string, long, long, double, CancellationToken, Task<byte[]>> never = (_, _, _, _, _) =>
        {
            reads++;
            throw new InvalidOperationException("Must refuse before reading.");
        };
        foreach (var rate in new[] { 0, 7_999, 96_001, 192_000 })
            Assert.Equal(VoiceLabSourceAudioErrorCode.UnsupportedRate, (await Assert.ThrowsAsync<VoiceLabSourceAudioException>(() =>
                VoiceLabSourceAudio.RewriteSourceAsync("source", 4_800, rate, Window(0.02, 0.08, 48_000), null, null, [], never, Token))).Code);
        foreach (var frames in new[] { 0L, -1L })
            Assert.Equal(VoiceLabSourceAudioErrorCode.RangeOutsideMedia, (await Assert.ThrowsAsync<VoiceLabSourceAudioException>(() =>
                VoiceLabSourceAudio.RewriteSourceAsync("source", frames, 48_000, Window(0.02, 0.08, 48_000), null, null, [], never, Token))).Code);
        Assert.Equal(0, reads);
    }

    /// <summary>Every quote streams the whole track, so when the selection, voice or model changes the token is all that stops the
    /// read: it must stop before the next chunk, in the envelope pass and in the region decode, and reach the conversion that
    /// holds a decode in progress.</summary>
    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(3)]
    [InlineData(4)]
    public async Task CancellingTheReadStopsItBeforeItsNextChunk(int completed)
    {
        const int rate = 8_000;
        const long frames = 5_000_000;
        static short Pcm(long frame) => frame is >= 400_000 and < 404_800 ? (short)0 : Speech(frame);
        TimedWord[] items = [Word("a", 0, 49.9), Word("b", 50.7, 625)];
        var window = Window(30, 31, rate);
        // Left alone, the read makes three envelope conversions and then decodes two regions.
        var spans = new List<(long Start, long End)>();
        await VoiceLabSourceAudio.RewriteSourceAsync("cancel", frames, rate, window, null, null, items, Conversion(frames, Pcm, spans), Token);
        Assert.Equal(new (long Start, long End)[] { (0, 2_240_000), (2_240_000, 4_480_000), (4_480_000, frames), (192_000, 296_000), (392_000, 412_000) },
            spans);
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(Token);
        if (completed == 0) await cancel.CancelAsync();
        var fake = Conversion(frames, Pcm);
        var tokens = new List<CancellationToken>();
        Func<string, long, long, double, CancellationToken, Task<byte[]>> conversion = async (source, start, end, sampleRate, ct) =>
        {
            tokens.Add(ct);
            var wav = await fake(source, start, end, sampleRate, ct);
            if (tokens.Count == completed) await cancel.CancelAsync();
            return wav;
        };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            VoiceLabSourceAudio.RewriteSourceAsync("cancel", frames, rate, window, null, null, items, conversion, cancel.Token));
        Assert.Equal(completed, tokens.Count);
        // Each conversion was handed the caller's token, so cancelling reaches a decode in progress too.
        Assert.All(tokens, token => Assert.True(token.IsCancellationRequested));
    }

    [Fact]
    public async Task DecodeChunksStayUnderTheUploadLimitAtEverySupportedRate()
    {
        for (var rate = 8_000; rate <= 96_000; rate++)
        {
            var chunk = VoiceLabSourceAudio.DecodeChunkFrames(rate);
            var trailing = (rate + 49) / 50;
            Assert.Equal(Math.Min(280 * rate, 24_999_977 - trailing), chunk);
            // The longest chunk the decode asks for, with the remainder it can absorb, passes the conversion's upload check.
            Assert.Equal(chunk + trailing - 1, VoiceLabSourceAudio.ConversionChunk(0, chunk + trailing - 1, rate).Frames);
        }
        // 280 s at 96 kHz is 53,760,044 bytes of PCM16, so a fixed 280 s chunk would fail every 96 kHz source over about 260 s.
        Assert.Equal(VoiceLabSourceAudioErrorCode.TooLarge,
            Assert.Throws<VoiceLabSourceAudioException>(() => VoiceLabSourceAudio.ConversionChunk(0, 280 * 96_000, 96_000)).Code);
        const long frames = 300 * 96_000;
        var spans = new List<(long Start, long End)>();
        var result = await VoiceLabSourceAudio.RewriteSourceAsync("96k", frames, 96_000, Window(100, 101, 96_000), null, null, [],
            Conversion(frames, frame => (short)(frame % 2_000 - 1_000), spans), Token);
        Assert.Equal<(long Start, long End)>((0, 24_998_057), spans[0]);
        Assert.Equal<(long Start, long End)>((24_998_057, frames), spans[1]);
        Assert.Equal(frames / 960, result.Envelope.Rms.Count);
        Assert.Equal(frames, result.Excerpt.TotalFrames);
    }

    [Fact]
    public void RegionSelectionReplaysTheSharedVectors()
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/rewrite-source-regions.json");
        var root = document.RootElement;
        Assert.Equal("voxclip-voice-lab-rewrite-source-regions/1", root.GetProperty("schema").GetString());
        Assert.Equal(VoiceLabSourceAudio.TakeAssetRate, root.GetProperty("takeAssetRate").GetInt32());
        static (long Start, long End) Range(JsonElement pair) => (pair[0].GetInt64(), pair[1].GetInt64());
        static double? Silence(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetDouble();
        static VoiceLabSeamKind Kind(JsonElement value) => value.GetString() switch
        {
            "none" => VoiceLabSeamKind.None,
            "gap" => VoiceLabSeamKind.Gap,
            "hard" => VoiceLabSeamKind.Hard,
            var other => throw new InvalidDataException("Unknown seam kind " + other)
        };
        var near = root.GetProperty("nearWindow").EnumerateArray().ToArray();
        Assert.Equal(11, near.Length);
        foreach (var row in near)
        {
            var rate = row.GetProperty("rate").GetInt32();
            var start = row.GetProperty("startSample").GetInt64();
            var end = row.GetProperty("endSample").GetInt64();
            var window = new VoiceLabWindow("w", "w", [], [], start / (double)rate, end / (double)rate, start, end,
                new(Kind(row.GetProperty("leftSeam")), start / (double)rate, start, rate / 50),
                new(Kind(row.GetProperty("rightSeam")), end / (double)rate, end, rate / 50));
            var actual = VoiceLabSourceAudio.NearWindow(window, Silence(row.GetProperty("incomingSilence")),
                Silence(row.GetProperty("outgoingSilence")), row.GetProperty("totalFrames").GetInt64(), rate);
            Assert.True(Range(row.GetProperty("expected")) == actual, row.GetProperty("id").GetString() + ": " + actual);
        }
        var aligned = root.GetProperty("aligned").EnumerateArray().ToArray();
        Assert.Equal(7, aligned.Length);
        foreach (var row in aligned)
            Assert.Equal(Range(row.GetProperty("expected")), VoiceLabSourceAudio.Aligned(row.GetProperty("lower").GetInt64(),
                row.GetProperty("upper").GetInt64(), row.GetProperty("totalFrames").GetInt64(), row.GetProperty("rate").GetInt32()));
        var merged = root.GetProperty("merged").EnumerateArray().ToArray();
        Assert.Equal(5, merged.Length);
        foreach (var row in merged)
            Assert.Equal(row.GetProperty("expected").EnumerateArray().Select(Range).ToArray(),
                VoiceLabSourceAudio.Merged(row.GetProperty("ranges").EnumerateArray().Select(Range).ToArray()));
        var chunks = root.GetProperty("decodeChunkFrames").EnumerateArray().ToArray();
        Assert.Equal(12, chunks.Length);
        foreach (var row in chunks)
            Assert.Equal(row.GetProperty("expected").GetInt32(), VoiceLabSourceAudio.DecodeChunkFrames(row.GetProperty("rate").GetInt32()));
    }

    /// <summary>A take 7 s too long for a 1 s window borrows 7 s of the 8 s silence before its gap seam (§8.9.2), and staging reads
    /// the half second before the widened window and the seam handle at its start. Regions of only 6 s around the window would
    /// hold no samples there, and staging would refuse the take after it was paid for.</summary>
    [Fact]
    public async Task TheWindowRegionHoldsWhatAFitThatBorrowsALongSilenceStages()
    {
        const int rate = 8_000, asset = 24_000;
        const long frames = 60 * rate;
        var phase = 2 * Math.PI * 220 / rate;
        short Tone(long frame) => (short)Math.Round(8_000 * Math.Sin(phase * frame), MidpointRounding.AwayFromZero);
        var window = Window(30, 31, rate, VoiceLabSeamKind.Gap);
        var take = new VoiceLabFitTake(8 * asset, asset, 0, 8, [new VoiceLabWord("new", 0, 8, true)],
            new AudioEnvelope(asset, 0.01, Enumerable.Repeat(1f, 800).ToArray()));
        var plan = Assert.IsType<VoiceLabFitResult.Exact>(VoiceLabFitPlanner.Plan(window, 8, 0.1, take, ["new"], rate)).Plan;
        Assert.Equal(7L * rate, plan.Incoming.BorrowedSamples);
        Assert.Equal(23.0, plan.WindowStart);
        Assert.Equal(31.0, plan.WindowEnd);
        var result = await VoiceLabSourceAudio.RewriteSourceAsync("borrow", frames, rate, window, 8, 0.1, [], Conversion(frames, Tone), Token);
        var staged = VoiceLabSourceAudio.Resample(result.Excerpt, rate, asset);
        var decoded = new float[frames];
        for (var frame = 0; frame < decoded.Length; frame++) decoded[frame] = Tone(frame) / 32768f;
        var whole = VoiceConsentAudio.Resample(decoded, rate, asset);
        Assert.Equal(whole.LongLength, staged.TotalFrames);
        // What staging reads at the asset rate: the 0.5 s lead and the incoming handle at 23 s, the outgoing handle and the tail at 31 s.
        const int start = 23 * asset, end = 31 * asset, lead = asset / 2, handle = 240;
        foreach (var (lower, upper) in new[] { (start - lead, start + handle), (end - handle, end + lead) })
        {
            var samples = staged.Samples(lower, upper);
            Assert.NotNull(samples);
            // Each region is resampled on the whole track's grid, so these are the whole track's frames, bit for bit.
            Assert.Equal(whole[lower..upper], samples.Value.ToArray());
        }
        // Without the lendable silence the window region starts 6 s before the window, after the frames staging reads.
        Assert.True(VoiceLabSourceAudio.NearWindow(window, null, null, frames, rate).Start * asset / rate > start - lead);
    }

    [Theory]
    [InlineData(8_000)]
    [InlineData(44_100)]
    [InlineData(48_000)]
    [InlineData(96_000)]
    public void ExcerptRegionsResampleOnTheWholeTracksGrid(int rate)
    {
        const int target = 24_000;
        var whole = Enumerable.Range(0, rate * 12).Select(index => (float)(0.25 * Math.Sin(2 * Math.PI * 220 * index / rate))).ToArray();
        var expected = VoiceConsentAudio.Resample(whole, rate, target);
        var all = VoiceLabSourceAudio.Resample(VoiceLabSourceExcerpt.Whole(whole), rate, target);
        Assert.Equal(expected.LongLength, all.TotalFrames);
        Assert.Equal(expected, Assert.Single(all.Regions).Samples.ToArray());
        var (start, end) = VoiceLabSourceAudio.Aligned(4L * rate + 5, 9L * rate, whole.Length, rate);
        var excerpt = new VoiceLabSourceExcerpt(whole.Length, [new VoiceLabSourceExcerpt.Region(start, whole.AsSpan((int)start, (int)(end - start)))]);
        var resampled = VoiceLabSourceAudio.Resample(excerpt, rate, target);
        Assert.Equal(12L * target, resampled.TotalFrames);
        Assert.Equal(start * target / rate, Assert.Single(resampled.Regions).Start);
        // 1 s in from the region's edges, where a take run reads, the frames are the whole track's, bit for bit.
        var inner = resampled.Samples(5 * target, 8 * target);
        Assert.NotNull(inner);
        Assert.Equal(expected[(5 * target)..(8 * target)], inner.Value.ToArray());
        if (target % rate != 0)
        {
            var offGrid = new VoiceLabSourceExcerpt(100, [new VoiceLabSourceExcerpt.Region(1, new float[2])]);
            Assert.Equal(VoiceLabSourceAudioErrorCode.InvalidAudio,
                Assert.Throws<VoiceLabSourceAudioException>(() => VoiceLabSourceAudio.Resample(offGrid, rate, target)).Code);
        }
    }

    /// <summary>Each region keeps the array it is decoded into, and the 24 kHz excerpt keeps the resampler's output, so neither is
    /// held twice and memory stays one chunk, the regions and the envelope. The fake conversions complete at once, so the whole
    /// read runs on this thread and every allocation it makes is this thread's.</summary>
    [Fact]
    public async Task RegionsAreHeldOnceWhenDecodedAndWhenResampled()
    {
        const int rate = 48_000, asset = 24_000;
        const long frames = 30 * rate;
        var spans = new List<(long Start, long End)>(4);
        var conversion = Conversion(frames, frame => (short)(frame % 2_000 - 1_000), spans);
        var before = GC.GetAllocatedBytesForCurrentThread();
        var read = VoiceLabSourceAudio.RewriteSourceAsync("held-once", frames, rate, Window(10, 20, rate), null, null, [], conversion, Token);
        var allocated = GC.GetAllocatedBytesForCurrentThread() - before;
        Assert.True(read.IsCompletedSuccessfully);
        var result = await read;
        // One envelope chunk, then 1 s around the room-tone run at the start and 6 s past each side of the 10 s window.
        Assert.Equal(new (long Start, long End)[] { (0, frames), (0, 72_000), (192_000, 1_248_000) }, spans);
        var held = result.Excerpt.Regions.Sum(region => (long)region.Samples.Length);
        Assert.Equal(1_128_000, held);
        // The conversions' WAVs and one float per region frame, with room for each decode pass's 256 KB buffer and the envelope.
        // A copy of the regions would add 4.5 MB.
        var wavs = spans.Sum(span => 44 + 2 * (span.End - span.Start));
        Assert.InRange(allocated, wavs + 4 * held, wavs + 4 * held + 2_000_000);
        before = GC.GetAllocatedBytesForCurrentThread();
        var staged = VoiceLabSourceAudio.Resample(result.Excerpt, rate, asset);
        allocated = GC.GetAllocatedBytesForCurrentThread() - before;
        var resampled = staged.Regions.Sum(region => (long)region.Samples.Length);
        Assert.Equal(held / 2, resampled);
        // A copy of the resampled regions would add 2.3 MB.
        Assert.InRange(allocated, 4 * resampled, 4 * resampled + 256_000);
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task RewriteSourceDecodesOnlyTheRegionsOfARealTrackLongerThanOneChunk()
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        const int rate = 8_000, frames = 600 * rate;
        static short Pcm(long frame) => frame is >= 400_000 and < 404_800 ? (short)0 : Speech(frame);
        var path = Path.Combine(storage.Root, "long.wav");
        using (var writer = new BinaryWriter(File.Create(path)))
        {
            writer.Write("RIFF"u8); writer.Write(36 + frames * 2); writer.Write("WAVEfmt "u8); writer.Write(16);
            writer.Write((short)1); writer.Write((short)1); writer.Write(rate); writer.Write(rate * 2); writer.Write((short)2); writer.Write((short)16);
            writer.Write("data"u8); writer.Write(frames * 2);
            for (var frame = 0; frame < frames; frame++) writer.Write(Pcm(frame));
        }
        TimedWord[] items = [Word("a", 0, 49.9), Word("b", 50.7, 600)];
        var result = await VoiceLabSourceAudio.RewriteSourceAsync(path, frames, rate, Window(30, 31, rate), null, null, items, Token);
        var whole = new List<float>(frames);
        for (long start = 0; start < frames; start += 200 * rate)
        {
            var wav = await VoiceLabSourceAudio.ConversionInputAsync(path, start, start + 200 * rate, rate, Token);
            for (var offset = 44; offset < wav.Length; offset += 2) whole.Add(BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(offset, 2)) / 32768f);
        }
        Assert.Equal(frames, whole.Count);
        Assert.Equal(VoiceLabTakeProcessing.Envelope(whole.ToArray(), rate).Rms, result.Envelope.Rms);
        Assert.Equal(400_000, VoiceLabRoomToneSelection.Select(items, result.Envelope, rate, frames).SourceStartSample);
        Assert.Equal(new long[] { 192_000, 392_000 }, result.Excerpt.Regions.Select(region => region.Start));
        Assert.Equal(new long[] { 296_000, 412_000 }, result.Excerpt.Regions.Select(region => region.End));
        foreach (var region in result.Excerpt.Regions)
            Assert.Equal(whole.GetRange((int)region.Start, (int)(region.End - region.Start)), region.Samples.ToArray());
        // Nothing refuses a length up front: a track shorter than the frames asked for fails only where the decode passes its end.
        Assert.Equal(VoiceLabSourceAudioErrorCode.RangeOutsideMedia, (await Assert.ThrowsAsync<VoiceLabSourceAudioException>(() =>
            VoiceLabSourceAudio.RewriteSourceAsync(path, 30_000_001, rate, Window(30, 31, rate), null, null, items, Token))).Code);
    }
}

/// <summary>A stand-in for VoiceLabSourceAudio.ConversionInputAsync over a synthetic track, for tests without FFmpeg.</summary>
internal static class SourceConversion
{
    /// <summary>The PCM16 WAV a conversion of frames [start, end) returns from a track of <paramref name="total"/> frames whose
    /// samples <paramref name="pcm"/> gives, after the chunk check ConversionInputAsync applies, so a chunk the upload limit would
    /// refuse fails here too. <paramref name="spans"/> records every conversion.</summary>
    internal static Func<string, long, long, double, CancellationToken, Task<byte[]>> Fake(long total, Func<long, short> pcm,
        List<(long Start, long End)>? spans = null) => (source, start, end, rate, ct) =>
    {
        ct.ThrowIfCancellationRequested();
        var frames = VoiceLabSourceAudio.ConversionChunk(start, end, rate).Frames;
        if (end > total) throw new VoiceLabSourceAudioException(VoiceLabSourceAudioErrorCode.RangeOutsideMedia);
        spans?.Add((start, end));
        var wav = new byte[44 + frames * 2];
        for (var index = 0; index < frames; index++) BinaryPrimitives.WriteInt16LittleEndian(wav.AsSpan(44 + index * 2), pcm(start + index));
        return Task.FromResult(wav);
    };
}
