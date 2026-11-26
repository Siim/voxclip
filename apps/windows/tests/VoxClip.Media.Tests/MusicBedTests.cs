using System.Text.Json;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Audio;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Background music under the voice on Windows (doc/spec/music.md §4), through the one audio path preview and export
/// share. No FFmpeg: the voice is a synthetic edited reader and the track a WAV written by the test. The levels and timing replay
/// shared/fixtures/music/music-mix-cases.json.</summary>
public sealed class MusicBedTests(ITestOutputHelper output) : IDisposable
{
    /// <summary>The temp folders <see cref="Track"/> made for this test, deleted when it ends.</summary>
    private readonly List<string> tracks = [];
    public void Dispose()
    {
        foreach (var directory in tracks)
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private const int Rate = 48_000;
    private const double MusicHz = 220;

    private static ProjectMusic Entry(double gainDb = -20, bool ducking = true, double fadeIn = 0.5, double fadeOut = 1.5, double offset = 0,
        double duration = 30) => new("music-1", "c", new("00000000-0000-4000-8000-000000000000/music-test.wav", new string('a', 64), duration),
        MusicSource.File, "Test", null, MusicLicense.Own, null, null, null, gainDb, ducking, fadeIn, fadeOut, offset);

    /// <summary>A float WAV of a <see cref="MusicHz"/> sine, stereo, at <paramref name="rate"/>.</summary>
    private string Track(double seconds, float amplitude = 0.4f, int rate = Rate)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-music-bed-").FullName;
        tracks.Add(directory);
        var path = Path.Combine(directory, "music-test.wav");
        var frames = (int)Math.Round(seconds * rate);
        using var stream = File.Create(path);
        using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8); writer.Write(36 + frames * 8); writer.Write("WAVE"u8);
        writer.Write("fmt "u8); writer.Write(16); writer.Write((short)3); writer.Write((short)2); writer.Write(rate); writer.Write(rate * 8);
        writer.Write((short)8); writer.Write((short)32);
        writer.Write("data"u8); writer.Write(frames * 8);
        for (var frame = 0; frame < frames; frame++)
        {
            var value = amplitude * (float)Math.Sin(2 * Math.PI * MusicHz * frame / rate);
            writer.Write(value); writer.Write(value);
        }
        return path;
    }

    /// <summary>A voice of 441 Hz between <paramref name="speech"/> seconds, silent elsewhere, over <paramref name="seconds"/>.</summary>
    private sealed class Voice(double seconds, (double Start, double End) speech, float amplitude = 0.5f, long start = 0)
    {
        private readonly long frames = (long)Math.Round(seconds * Rate);
        private long position = start;
        internal long Frames => frames;
        internal int Read(Span<float> target, int count, CancellationToken ct)
        {
            count = (int)Math.Max(0, Math.Min(count, frames - position));
            for (var index = 0; index < count; index++)
            {
                var time = (position + index) / (double)Rate;
                var value = time >= speech.Start && time < speech.End ? amplitude * (float)Math.Sin(2 * Math.PI * 441 * time) : 0f;
                target[index * 2] = value; target[index * 2 + 1] = value;
            }
            position += count;
            return count;
        }
    }

    private static ComposeSnapshot Snapshot(double seconds, ProjectClipControls? controls, MusicRenderInput? music, IReadOnlyList<(long, long)>? kept = null)
    {
        var samples = (long)Math.Round(seconds * Rate);
        var plan = TestPlan.FromKept(Rate, samples, (kept ?? [(0, samples)]).Select(item => new MediaInterval(item.Item1, item.Item2)).ToArray());
        return new(new("synthetic.mp4", seconds, new(320, 180, 30, 0), new(Rate, 2), new(320, 180), "h264", "aac", false, 0, 1, 0),
            plan, null, new(new(320, 180), 30, 1_000_000)) { Clip = new(controls, null) { Music = music } };
    }

    /// <summary>The rendered audio with its bed, read like the exporter: the voice measured once, then mixed from the start (or a
    /// preview's playhead).</summary>
    private static float[] Render(ComposeSnapshot snapshot, double seconds, (double, double) speech, double startEdited = 0, float amplitude = 0.5f)
    {
        var bed = MusicBed.Stage(snapshot, Rate, () =>
        {
            var voice = new Voice(seconds, speech, amplitude);
            return new RenderedAudioReader(snapshot, Rate, 0, voice.Read, null, voice.Frames, effectsTrack: false);
        }, CancellationToken.None);
        var played = new Voice(seconds, speech, amplitude, (long)Math.Round(startEdited * Rate));
        using var reader = new RenderedAudioReader(snapshot, Rate, startEdited, played.Read, null, played.Frames - (long)Math.Round(startEdited * Rate), music: bed);
        var all = new List<float>();
        var block = new float[4096 * 2];
        int count;
        while ((count = reader.Read(block, 4096, CancellationToken.None)) > 0)
            for (var index = 0; index < count; index++) all.Add(block[index * 2]);
        return all.ToArray();
    }

    private static double Amplitude(float[] samples, double from, double to, double hz) =>
        ClipRenderMediaTests.Amplitude(samples, (int)(from * Rate), (int)(to * Rate), hz);

    private static double Db(double ratio) => 20 * Math.Log10(ratio);

    [Fact]
    public void SharedTimelineMusicVectorsReplay()
    {
        using var document = FixtureLoader.ReadJson("fixtures/music/music-mix-cases.json");
        foreach (var item in document.RootElement.GetProperty("timeline").EnumerateArray())
        {
            var rate = item.GetProperty("sampleRate").GetInt32();
            var trackFrames = item.GetProperty("trackFrames").GetInt32();
            var speed = item.GetProperty("speed").GetDouble();
            double Map(double anchor) => anchor / speed;
            const long outputFrames = 1000;
            var segments = item.GetProperty("segments").Deserialize<MusicSegment[]>(JsonSerializerOptions.Web)!;
            var placements = MusicMix.SegmentPieces(segments, trackFrames, rate, outputFrames, Map);
            var starts = item.GetProperty("starts").Deserialize<long[]>()!;
            Assert.Equal(starts, placements.Select(placement => placement.Span.OutputStart));
            Assert.Equal(item.GetProperty("fades").Deserialize<long[][]>(), placements.Select(placement => new[] { placement.Span.FadeIn, placement.Span.FadeOut }).ToArray());
            var expectedPieces = item.GetProperty("pieces").Deserialize<MusicMix.LoopPiece[][]>(JsonSerializerOptions.Web)!;
            for (var index = 0; index < placements.Count; index++) Assert.Equal(expectedPieces[index], placements[index].Pieces);

            var shape = new ItemShape(segments[0].FadeInSeconds, segments[0].FadeOutSeconds, segments[0].GainPoints);
            var seconds = item.GetProperty("itemSeconds").Deserialize<double[]>()!;
            var gains = item.GetProperty("itemGains").Deserialize<double[]>()!;
            foreach (var (second, gain) in seconds.Zip(gains)) Assert.Equal(gain, MusicMix.ItemGain(second, shape, segments[0].LengthSeconds), 8);
            Assert.InRange(Math.Abs(item.GetProperty("crossfadeWeight").GetDouble() -
                MusicMix.Crossfade(item.GetProperty("crossfadeFrame").GetInt64(), placements[1].Span.FadeIn)), 0, 1e-9);
            var depth = item.GetProperty("depthDb").GetDouble();
            var ducking = MusicMix.DuckingGainsDb(item.GetProperty("activity").Deserialize<bool[]>()!, true, depth);
            foreach (var (actual, expected) in ducking.Zip(item.GetProperty("duckingDb").Deserialize<double[]>()!)) Assert.Equal(expected, actual, 8);

            var track = Enumerable.Range(0, trackFrames).SelectMany(frame => new[] { frame < rate ? -0.25f : 0.25f, 0.25f }).ToArray();
            var entry = Entry(gainDb: 0, duration: trackFrames / (double)rate) with { Segments = segments, DuckDb = depth };
            var speech = Enumerable.Repeat(-20.0, (int)outputFrames).ToArray();
            var bed = MusicBed.Create(entry, track, speech, outputFrames, rate, Map);
            var mix = new float[outputFrames * 2];
            bed.Mix(mix, 0, (int)outputFrames);
            var at = (int)(starts[0] + seconds[1] * rate) * 2;
            var signal = .1 * gains[1] * Math.Pow(10, depth / 20);
            Assert.Equal(signal, mix[at], 6);
            Assert.Equal(signal, mix[at + 1], 6);
            Assert.Equal(0, mix[(starts[0] - 1) * 2]);
            Assert.Equal(0, mix[^1]);
        }
    }

    [Fact]
    public void SharedBedVectorsReplay()
    {
        using var document = FixtureLoader.ReadJson("fixtures/music/music-mix-cases.json");
        foreach (var item in document.RootElement.GetProperty("beds").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!;
            var rate = item.GetProperty("sampleRate").GetInt32();
            var raw = item.GetProperty("entry");
            var entry = Entry(raw.GetProperty("gainDb").GetDouble(), raw.GetProperty("ducking").GetBoolean(), raw.GetProperty("fadeInSeconds").GetDouble(),
                raw.GetProperty("fadeOutSeconds").GetDouble(), raw.GetProperty("startOffsetSeconds").GetDouble());
            var track = item.GetProperty("trackStereo").EnumerateArray().Select(value => (float)value.GetDouble()).ToArray();
            var speech = item.GetProperty("speechLevels").EnumerateArray().Select(value => value.GetDouble()).ToArray();
            var frames = item.GetProperty("outputFrames").GetInt32();
            var bed = MusicBed.Create(entry, track, speech, frames, rate);
            Assert.True(Math.Abs(item.GetProperty("bedGainDb").GetDouble() - bed.BedGainDb) < 1e-6, id);
            var expectedSpeech = item.GetProperty("speechDb");
            Assert.Equal(expectedSpeech.ValueKind == JsonValueKind.Null, bed.SpeechDb is null);
            var mixed = new float[frames * 2];
            bed.Mix(mixed, 0, frames);
            var picks = item.GetProperty("frames").EnumerateArray().Select(value => value.GetInt32()).ToArray();
            var samples = item.GetProperty("samples").EnumerateArray().ToArray();
            for (var index = 0; index < picks.Length; index++)
                for (var channel = 0; channel < 2; channel++)
                    Assert.True(Math.Abs(samples[index][channel].GetDouble() - mixed[picks[index] * 2 + channel]) < 1e-6, $"{id} frame {picks[index]} channel {channel}");
            // A block read from the middle mixes the same samples as the whole.
            var tail = new float[(frames - 100) * 2];
            bed.Mix(tail, 100, frames - 100);
            Assert.Equal(mixed.AsSpan(200).ToArray(), tail);
        }
    }

    [Fact]
    public void TheBedSitsTwentyDecibelsUnderTheVoiceDucksTwelveAndFades()
    {
        var music = new MusicRenderInput(Entry(), Track(8));
        var snapshot = Snapshot(6, null, music);
        var left = Render(snapshot, 6, (1.0, 2.5));
        Assert.Equal(6 * Rate, left.Length);
        var voice = Amplitude(left, 1.2, 2.3, 441);
        var open = Amplitude(left, 3.2, 4.4, MusicHz);
        var ducked = Amplitude(left, 1.2, 2.3, MusicHz);
        output.WriteLine($"voice {voice:F4}, bed {open:F4} ({Db(open / voice):F2} dB), ducked {ducked:F4} ({Db(ducked / open):F2} dB)");
        // The voice is untouched; the bed sits gainDb under the measured speech and dips 12 dB under it.
        Assert.InRange(voice, 0.49, 0.51);
        Assert.InRange(Db(open / voice), -20.3, -19.7);
        Assert.InRange(Db(ducked / open), -12.3, -11.7);
        // Fade-in from silence over 0.5 s, fade-out to silence over the last 1.5 s.
        Assert.InRange(Amplitude(left, 0.2, 0.3, MusicHz) / open, 0.45, 0.55);
        Assert.InRange(Amplitude(left, 5.2, 5.3, MusicHz) / open, 0.45, 0.55);
        Assert.True(Math.Abs(left[^1]) < 1e-3);
        // The attack starts 150 ms before speech, the release ends 400 ms after it.
        Assert.InRange(Amplitude(left, 0.70, 0.80, MusicHz) / open, 0.9, 1.01);
        Assert.InRange(Amplitude(left, 2.95, 3.05, MusicHz) / open, 0.9, 1.01);
    }

    [Fact]
    public void StorySeamsDoNotResetOrFadeTheBed()
    {
        var music = new MusicRenderInput(Entry(ducking: false, fadeIn: 0, fadeOut: 0), Track(3));
        var plan = new EditPlan(Rate, 4 * Rate, [], [new(3 * Rate, 7 * Rate / 2), new(Rate / 2, 13 * Rate / 10), new(2 * Rate, 3 * Rate)],
            23 * Rate / 10, []) { PartSeams = [Rate / 2, 13 * Rate / 10] };
        var story = Snapshot(4, null, music) with { Plan = plan };
        var control = Snapshot(story.RenderedDuration, null, music);
        var continuous = Render(control, story.RenderedDuration, (0, 0));
        var actual = Render(story, story.RenderedDuration, (0, 0));
        Assert.Equal(continuous, actual);
        foreach (var seam in story.Plan.PartSeams)
        {
            var time = seam / (double)Rate;
            Assert.True(Amplitude(actual, time - .02, time + .02, MusicHz) > .004);
        }
    }

    [Fact]
    public void MusicFollowsTheRenderedClockThroughSpeedAndCutsWithoutSpeedingUp()
    {
        var music = new MusicRenderInput(Entry(fadeIn: 0, fadeOut: 0.5), Track(8));
        var controls = new ProjectClipControls("c", 1.25, null, ClipLook.Original, 0, 0, 0, false, false, 0);
        // 6 s of source with 1 s cut out: 5 s edited, 4 s rendered at 1.25×.
        var snapshot = Snapshot(6, controls, music, [(0, 2 * Rate), (3 * Rate, 6 * Rate)]);
        Assert.Equal(4.0, snapshot.RenderedDuration, 9);
        var left = Render(snapshot, 5, (5, 5));
        Assert.Equal(4 * Rate, left.Length);
        // The bed keeps its pitch (a sped-up bed would sit at 275 Hz) and spans the rendered length, fading out at its end.
        var at = Enumerable.Range(150, 200).MaxBy(hz => ClipRenderMediaTests.Amplitude(left, Rate, 2 * Rate, hz));
        Assert.InRange(at, 219, 221);
        Assert.True(Amplitude(left, 3.2, 3.3, MusicHz) > Amplitude(left, 3.85, 3.95, MusicHz) * 3);
        // Without speech the bed takes the fallback level (−20 dBFS) and nothing ducks.
        Assert.InRange(Db(Amplitude(left, 1, 3, MusicHz) / Math.Sqrt(2)), -40.4, -39.6);
    }

    [Fact]
    public void APreviewFromThePlayheadMixesTheSameBedAsTheExport()
    {
        var music = new MusicRenderInput(Entry(), Track(1.2));
        var snapshot = Snapshot(4, null, music);
        var whole = Render(snapshot, 4, (1, 2.5));
        var preview = Render(snapshot, 4, (1, 2.5), startEdited: 1.5);
        Assert.Equal(whole.Length - (int)(1.5 * Rate), preview.Length);
        for (var index = 0; index < preview.Length; index += 97)
            Assert.True(Math.Abs(whole[index + (int)(1.5 * Rate)] - preview[index]) < 1e-6, $"sample {index}");
        // A 1.2 s track loops under 4 s with in-phase equal-power crossfades: no hole at the joins.
        for (var second = 0.6; second < 2.4; second += 0.1)
            Assert.True(Amplitude(whole, second, second + 0.1, MusicHz) > 0.004, $"{second:F1} s");
    }

    [Fact]
    public void ASlippedAndFadedBedIsSampleIdenticalAfterSplittingAndSeeking()
    {
        var bed = new MusicSegment("whole", .5, 1.5, .125, false, FadeInSeconds: .25, FadeOutSeconds: .25);
        var entry = Entry(gainDb: -6, ducking: false, duration: 4) with { Segments = [bed] };
        var path = Track(4);
        var waveform = File.ReadAllBytes(path);
        Array.Clear(waveform, 44, Rate);
        File.WriteAllBytes(path, waveform);
        var split = entry with
        {
            Segments = [bed with { Id = "left", LengthSeconds = .75, FadeOutSeconds = 0 },
                bed with { Id = "right", AnchorSeconds = 1.25, SongFromSeconds = .875, LengthSeconds = .75, FadeInSeconds = 0 }]
        };
        var unsplit = Render(Snapshot(2.5, null, new(entry, path)), 2.5, (0, 0));
        var snapshot = Snapshot(2.5, null, new(split, path));
        var export = Render(snapshot, 2.5, (0, 0));
        var preview = Render(snapshot, 2.5, (0, 0), startEdited: 1);
        Assert.All(export[..(Rate / 2)], sample => Assert.Equal(0, sample));
        Assert.All(export[(2 * Rate)..], sample => Assert.Equal(0, sample));
        Assert.InRange(Amplitude(export, .5, .6, MusicHz) / Amplitude(export, .8, .9, MusicHz), .19, .21);
        Assert.InRange(Amplitude(export, 1.9, 2, MusicHz) / Amplitude(export, 1.6, 1.7, MusicHz), .19, .21);
        Assert.Equal(unsplit, export);
        Assert.Equal(export[Rate..], preview);
    }

    [Fact]
    public void AStartOffsetBeginsInsideTheTrackAndAMissingFileStopsTheExport()
    {
        // The offset reads the track from 0.5 s: a WAV whose first half second is silent starts sounding at once.
        var path = Track(3);
        var bytes = File.ReadAllBytes(path);
        Array.Clear(bytes, 44, (int)(0.5 * Rate) * 8);
        File.WriteAllBytes(path, bytes);
        var late = Render(Snapshot(2, null, new(Entry(fadeIn: 0, offset: 0.5), path)), 2, (2, 2));
        Assert.True(Amplitude(late, 0.05, 0.25, MusicHz) > 0.01);
        var early = Render(Snapshot(2, null, new(Entry(fadeIn: 0), path)), 2, (2, 2));
        Assert.True(Amplitude(early, 0.05, 0.25, MusicHz) < 1e-4);

        var missing = Snapshot(2, null, new(Entry(), Path.Combine(Path.GetTempPath(), "voxclip-no-such-music", "music-gone.mp3")));
        var job = new ExportJob(missing, new ExportTarget.Clip("c"), ExportAspect.Source, ExportQuality.Standard, Path.Combine(Path.GetTempPath(), "voxclip-music-out.mp4"), null);
        Assert.Equal("Export stopped: the music file music-gone.mp3 is missing. Your edits are saved.",
            Assert.Throws<VoxClipException>(() => Exporter.Validate(job)).Message);
    }

    [Fact]
    public void SilentVideoCarriesTheMusicWithoutOpeningASourceAudioDecoder()
    {
        var snapshot = Snapshot(2, null, new(Entry(fadeIn: 0, fadeOut: 0), Track(3)));
        snapshot = snapshot with { Media = snapshot.Media with { Audio = null } };
        var job = new ExportJob(snapshot, new ExportTarget.Clip("c"), ExportAspect.Source, ExportQuality.Standard,
            Path.Combine(Path.GetTempPath(), "voxclip-music-out.mp4"), null);
        Exporter.Validate(job);
        var bed = MusicBed.Stage(snapshot, Rate, () => throw new InvalidOperationException(), CancellationToken.None);
        Assert.NotNull(bed);
        Assert.Null(bed.SpeechDb);
        using var reader = RenderedAudioReader.Open(snapshot, Rate, startEdited: 0.5, ct: TestContext.Current.CancellationToken, music: bed);
        Assert.Equal(72_000, reader.TotalFrames);
        var stereo = new float[2048];
        Assert.Equal(1024, reader.Read(stereo, 1024, CancellationToken.None));
        Assert.Contains(stereo, value => Math.Abs(value) > 0.01f);
    }

    [Fact]
    public void WithoutMusicTheEditedVoicePassesThroughSampleForSample()
    {
        var snapshot = Snapshot(1, null, null);
        Assert.Null(MusicBed.Stage(snapshot, Rate, () => throw new InvalidOperationException(), CancellationToken.None));
        var voice = new Voice(1, (0, 1));
        using var reader = new RenderedAudioReader(snapshot, Rate, 0, voice.Read, null, voice.Frames);
        var block = new float[Rate * 2];
        Assert.Equal(Rate, reader.Read(block, Rate, CancellationToken.None));
        var expected = new float[Rate * 2];
        new Voice(1, (0, 1)).Read(expected, Rate, CancellationToken.None);
        Assert.Equal(expected, block);
    }
}
