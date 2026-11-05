using System.Text.Json;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Cli;
using VoxClip.Media.Audio;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Windows renders clip controls (design §6.9) and Ask Claude's effects (ai.md §18.5) through the one path preview and
/// export share. These checks run without FFmpeg: the audio path reads a synthetic edited voice, and the picture stages run on
/// synthetic frames. The Mac's decisions come from shared/fixtures/clip-render and its goldens from shared/fixtures/media/effects.</summary>
public sealed class ClipRenderMediaTests(ITestOutputHelper output)
{
    private const int Rate = 48_000;
    private static JsonElement Cases() => FixtureLoader.ReadJson("fixtures/clip-render/clip-render-cases.json").RootElement.Clone();

    private static ProjectClipControls Controls(double speed = 1, ClipLook look = ClipLook.Original, double gain = 0, double fadeIn = 0,
        double fadeOut = 0, bool mute = false, bool flip = false, int rotation = 0)
        => new("c", speed, null, look, gain, fadeIn, fadeOut, mute, flip, rotation);

    /// <summary>A 2 s, 320 × 180 source with a 441 Hz voice; nothing cut, so source time is edited time.</summary>
    private static ComposeSnapshot Snapshot(ClipRenderInput? clip, long samples = 96_000) => new(
        new("synthetic.mp4", samples / (double)Rate, new(320, 180, 30, 0), new(Rate, 2), new(320, 180), "h264", "aac", false, 0, 1, 0),
        TestPlan.FromKept(Rate, samples, [new(0, samples)]), null, new(new(320, 180), 30, 1_000_000)) { Clip = clip };

    private sealed class Tone(long frames, double hz = 441, float amplitude = 0.5f, long start = 0)
    {
        private long position = start;
        internal int Read(Span<float> target, int count, CancellationToken ct)
        {
            count = (int)Math.Max(0, Math.Min(count, frames - position));
            for (var index = 0; index < count; index++)
            {
                var value = amplitude * (float)Math.Sin(2 * Math.PI * hz * (position + index) / Rate);
                target[index * 2] = value; target[index * 2 + 1] = value;
            }
            position += count;
            return count;
        }
    }

    private static float[] Left(RenderedAudioReader reader)
    {
        var all = new List<float>();
        var block = new float[4096 * 2];
        int count;
        while ((count = reader.Read(block, 4096, CancellationToken.None)) > 0)
            for (var index = 0; index < count; index++) all.Add(block[index * 2]);
        return all.ToArray();
    }

    private static RenderedAudioReader Reader(ComposeSnapshot snapshot, long frames = 96_000, double hz = 441, float amplitude = 0.5f, bool effects = true,
        double start = 0)
    {
        var tone = new Tone(frames, hz, amplitude, (long)Math.Round(start * Rate));
        return new(snapshot, Rate, start, tone.Read, null, frames - (long)Math.Round(start * Rate), effectsTrack: effects);
    }

    /// <summary>The amplitude of <paramref name="hz"/> over <paramref name="from"/>..<paramref name="to"/> (a single-bin DFT).</summary>
    internal static double Amplitude(ReadOnlySpan<float> samples, int from, int to, double hz)
    {
        double real = 0, imaginary = 0;
        for (var index = from; index < to; index++)
        {
            var phase = 2 * Math.PI * hz * index / Rate;
            real += samples[index] * Math.Cos(phase); imaginary += samples[index] * Math.Sin(phase);
        }
        return 2 * Math.Sqrt(real * real + imaginary * imaginary) / (to - from);
    }

    private static double DominantFrequency(float[] samples, int from, int count, int low, int high)
        => Enumerable.Range(low, high - low + 1).MaxBy(hz => Amplitude(samples, from, from + count, hz));

    // MARK: Audio

    [Fact]
    public void ASpeedRendersEditedOverSpeedAndKeepsThePitch()
    {
        foreach (var (speed, frames) in new[] { (1.25, 76_800), (0.75, 128_000) })
        {
            var snapshot = Snapshot(new(Controls(speed), null));
            Assert.Equal(frames, snapshot.RenderedSamples);
            using var reader = Reader(snapshot);
            Assert.Equal(frames, reader.TotalFrames);
            var samples = Left(reader);
            Assert.Equal(frames, samples.Length);
            // A resample would move 441 Hz to 551 Hz at 1.25× and 331 Hz at 0.75×.
            var pitch = DominantFrequency(samples, 4_800, 24_000, 300, 600);
            output.WriteLine($"{speed}x: {samples.Length} samples, dominant {pitch} Hz, level {Amplitude(samples, 4_800, 28_800, 441):F3}");
            Assert.InRange(pitch, 440, 442);
            Assert.InRange(Amplitude(samples, 4_800, frames - 4_800, 441), 0.42, 0.55);
        }
    }

    [Fact]
    public void VolumeFadesAndMuteActOnTheVoiceOnTheRenderedClock()
    {
        using (var quieter = Reader(Snapshot(new(Controls(gain: -6), null))))
            Assert.Equal(0.5 * 0.501187, Amplitude(Left(quieter), 24_000, 72_000, 441), 2);
        using (var muted = Reader(Snapshot(new(Controls(mute: true), null))))
            Assert.All(Left(muted), sample => Assert.Equal(0, sample));
        using var faded = Reader(Snapshot(new(Controls(speed: 2, fadeIn: 0.5, fadeOut: 0.25), null)));
        var samples = Left(faded);
        Assert.Equal(48_000, samples.Length);
        // At 2× the clip renders 1 s: silent at 0, half level 0.25 s in, full in the middle, half 0.125 s from the end.
        Assert.True(Math.Abs(samples[0]) < 1e-6);
        Assert.InRange(Amplitude(samples, 11_400, 12_600, 441), 0.2, 0.3);
        Assert.InRange(Amplitude(samples, 26_400, 33_600, 441), 0.45, 0.55);
        Assert.InRange(Amplitude(samples, 41_400, 42_600, 441), 0.2, 0.3);
    }

    [Fact]
    public void DefaultsAndPictureOnlyControlsReadTheEditedVoiceSampleForSample()
    {
        float[] Plain() { using var reader = Reader(Snapshot(null)); return Left(reader); }
        var plain = Plain();
        foreach (var clip in new ClipRenderInput?[] { null, new(Controls(look: ClipLook.Warm, flip: true, rotation: 90), null) })
        {
            using var reader = Reader(Snapshot(clip));
            Assert.Equal(plain, Left(reader));
        }
        // From a later start too: the preview opens the reader at its playhead.
        using var later = Reader(Snapshot(null), start: 0.5);
        Assert.Equal(plain.Skip(24_000), Left(later));
    }

    private static ClipEffect Bleep(JsonElement vector) => new("fx-bleep-1", null, "bleep", vector.GetProperty("bleep").GetProperty("start").GetDouble(),
        vector.GetProperty("bleep").GetProperty("end").GetDouble()) { WordIds = ["w1"] };

    private static ClipEffect Pop(JsonElement vector)
    {
        var pop = vector.GetProperty("pop");
        var start = pop.GetProperty("start").GetDouble();
        var duration = pop.GetProperty("durationSeconds").GetDouble();
        return new("fx-sound-1", null, "sound", start, start + duration) { Sound = new("bundled", "pop", null, duration), GainDb = 0 };
    }

    [Fact]
    public void AtASpeedTheBleepAndTheSoundSitOnTheRenderedClock()
    {
        var vector = Cases().GetProperty("effectsAtSpeed");
        var speed = vector.GetProperty("speed").GetDouble();
        var sounds = new Dictionary<string, string> { ["fx-sound-1"] = ClipEffectsRenderInput.BundledSoundPath("pop", FixtureLoader.SharedRoot) };
        var clip = new ClipRenderInput(Controls(speed), new([Bleep(vector), Pop(vector)], sounds));
        var snapshot = Snapshot(clip);
        Assert.Equal(vector.GetProperty("renderedSamples").GetInt64(), snapshot.RenderedSamples);
        // The effects track alone: the voice reads silence.
        using var effectsOnly = Reader(snapshot, amplitude: 0);
        var effects = Left(effectsOnly);
        Assert.Equal(76_800, effects.Length);
        var toneFirst = Array.FindIndex(effects, sample => sample != 0) / (double)Rate;
        var toneLast = Array.FindLastIndex(effects, (int)(0.9 * Rate), (int)(0.9 * Rate), sample => sample != 0) / (double)Rate;
        var popFirst = Array.FindIndex(effects, (int)(0.85 * Rate), sample => sample != 0) / (double)Rate;
        output.WriteLine($"tone {toneFirst:F4}–{toneLast:F4} s, pop at {popFirst:F4} s");
        Assert.Equal(vector.GetProperty("toneFirst").GetDouble(), toneFirst, vector.GetProperty("toneTolerance").GetDouble());
        Assert.Equal(vector.GetProperty("toneLast").GetDouble(), toneLast, vector.GetProperty("toneTolerance").GetDouble());
        Assert.Equal(vector.GetProperty("popFirst").GetDouble(), popFirst, vector.GetProperty("popTolerance").GetDouble());
        var held = ((int)(0.41 * Rate), (int)(0.79 * Rate));
        Assert.Equal(vector.GetProperty("toneAmplitude").GetDouble(), Amplitude(effects, held.Item1, held.Item2, vector.GetProperty("toneHz").GetDouble()), 2);
        Assert.Equal(1_000, DominantFrequency(effects, held.Item1, held.Item2 - held.Item1, 900, 1_100));
        // The voice alone: silent over the word's rendered bounds, within 10 ms.
        using var voiceOnly = Reader(snapshot, effects: false);
        var voice = Left(voiceOnly);
        var level = Amplitude(voice, (int)(1.1 * Rate), (int)(1.5 * Rate), 441);
        Assert.True(level > 0.2, $"{level}");
        var window = (int)(0.005 * Rate);
        double? first = null, last = null;
        for (var index = (int)(0.2 * Rate); index + window <= (int)(1.2 * Rate); index += window)
            if (Amplitude(voice, index, index + window, 441) < level * 0.1) { first ??= index / (double)Rate; last = (index + window) / (double)Rate; }
        output.WriteLine($"voice silent {first:F4}–{last:F4} s");
        var silent = vector.GetProperty("voiceSilent");
        var tolerance = vector.GetProperty("silenceTolerance").GetDouble();
        Assert.Equal(silent[0].GetDouble(), first!.Value, tolerance);
        Assert.Equal(silent[1].GetDouble(), last!.Value, tolerance);
        // And mixed, as a preview or export reads it: the tone and no voice inside the word.
        using var mixedReader = Reader(snapshot);
        var mixed = Left(mixedReader);
        var inside = ((int)(0.42 * Rate), (int)(0.78 * Rate));
        Assert.True(Amplitude(mixed, inside.Item1, inside.Item2, 441) < 0.005);
        Assert.Equal(0.25, Amplitude(mixed, inside.Item1, inside.Item2, 1_000), 2);
    }

    [Fact]
    public void TheEditedAudioOfAFasterClipStaysOneXAndCensoredWithoutATone()
    {
        var vector = Cases().GetProperty("effectsAtSpeed");
        var sounds = new Dictionary<string, string> { ["fx-sound-1"] = ClipEffectsRenderInput.BundledSoundPath("pop", FixtureLoader.SharedRoot) };
        var snapshot = RenderedAudioReader.EditedVoiceSnapshot(Snapshot(new(Controls(1.25, gain: -6), new([Bleep(vector), Pop(vector)], sounds))));
        Assert.Null(snapshot.Clip!.Controls);
        Assert.Equal(96_000, snapshot.RenderedSamples);
        using var reader = Reader(snapshot, effects: false);
        var samples = Left(reader);
        Assert.Equal(vector.GetProperty("editedAudioSamples").GetInt32(), samples.Length);
        Assert.True(Amplitude(samples, 24_000, 48_000, 441) < 0.001, "the bleeped word stays silent");
        Assert.True(Amplitude(samples, 60_000, 90_000, 441) > 0.45, "the rest of the voice plays at its level");
        Assert.True(Amplitude(samples, 24_000, 48_000, 1_000) < 0.001, "no tone in the voice alone");
    }

    [Fact]
    public void TheExportWritesTheRenderedLengthAndItsSubtitlesSitOnTheRenderedClock()
    {
        foreach (var item in Cases().GetProperty("speed").EnumerateArray())
        {
            var snapshot = Snapshot(new(Controls(item.GetProperty("speed").GetDouble()), null), item.GetProperty("editedSamples").GetInt64());
            var (frames, samples) = Exporter.RenderedCounts(snapshot, item.GetProperty("fps").GetDouble());
            Assert.Equal((item.GetProperty("frames").GetInt64(), item.GetProperty("renderedSamples").GetInt64()), (frames, samples));
        }
        var fast = Snapshot(new(Controls(1.25), null));
        Assert.Equal(1.25 * 47 / 30, Exporter.EditedTime(fast, 47, 30), 12);
        Assert.Equal(47 / 30.0, Exporter.EditedTime(Snapshot(null), 47, 30), 12);
        Assert.Equal((60L, 96_000L), Exporter.RenderedCounts(Snapshot(null), 30));
        MeasuredCaptionWord Word(string raw) => new(0, raw, raw, raw, 0, 1, 0, 0, [], 0, false, null, null, null);
        foreach (var item in Cases().GetProperty("srt").EnumerateArray())
        {
            var page = new CaptionPage(0, [0, 1], item.GetProperty("page")[0].GetDouble(), item.GetProperty("page")[1].GetDouble(), 64, 1, false,
                [new CaptionLine([0, 1], 0, 0, 0, 0, 0)], [], new(0, 0, 0, 0), new(0, 0, 0, 0), [], [], null, new(0, 0));
            var track = new CaptionTrack(CaptionRendering.LoadStyle("vox-bold"), new(640, 360), [Word("Hello"), Word("there")], [page], 2);
            Assert.Contains(item.GetProperty("cue").GetString()!, Exporter.Subtitles(track, item.GetProperty("speed").GetDouble()));
        }
    }

    // MARK: Picture

    private static PixelBuffer Swatches(JsonElement looks)
    {
        var swatches = looks.GetProperty("swatches").EnumerateArray().ToArray();
        var pixels = new byte[4 * 2 * 4];
        for (var index = 0; index < 8; index++)
        {
            var rgb = swatches[index].EnumerateArray().Select(value => (byte)Math.Floor(value.GetDouble() * 255 + 0.5)).ToArray();
            pixels[index * 4] = rgb[2]; pixels[index * 4 + 1] = rgb[1]; pixels[index * 4 + 2] = rgb[0]; pixels[index * 4 + 3] = 255;
        }
        return new(pixels, 4, 2, 16);
    }

    [Fact]
    public void LooksMatchTheMacGoldensOnTheSyntheticFrame()
    {
        var looks = Cases().GetProperty("looks");
        var tolerance = looks.GetProperty("tolerance").GetInt32();
        var original = Swatches(looks);
        ClipPicture.Look(original, ClipLook.Original, CancellationToken.None);
        Assert.Equal(Swatches(looks).Pixels.ToArray(), original.Pixels.ToArray());
        var worst = 0;
        foreach (var (look, name) in new[] { (ClipLook.Original, "original"), (ClipLook.Muted, "muted"), (ClipLook.Warm, "warm"), (ClipLook.Bw, "bw") })
        {
            var frame = Swatches(looks);
            ClipPicture.Look(frame, look, CancellationToken.None);
            var goldens = looks.GetProperty("macGoldens").GetProperty(name).EnumerateArray().ToArray();
            for (var index = 0; index < 8; index++)
            {
                var golden = goldens[index].EnumerateArray().Select(value => value.GetInt32()).ToArray();
                var pixel = frame.Pixels.Span.Slice(index * 4, 4);
                int[] rgb = [pixel[2], pixel[1], pixel[0]];
                var difference = rgb.Zip(golden).Max(pair => Math.Abs(pair.First - pair.Second));
                worst = Math.Max(worst, difference);
                Assert.True(difference <= tolerance, $"{name}[{index}]: {string.Join(",", rgb)} vs Mac {string.Join(",", golden)}");
                Assert.Equal(255, pixel[3]);
            }
        }
        output.WriteLine($"looks: largest channel difference from the Mac goldens {worst}");
    }

    [Fact]
    public void FlipAndQuarterTurnsMoveTheTopLeftCornerAndSwapTheFrame()
    {
        var looks = Cases().GetProperty("looks");
        foreach (var item in Cases().GetProperty("orient").EnumerateArray())
        {
            var controls = Controls(flip: item.GetProperty("flip").GetBoolean(), rotation: item.GetProperty("rotation").GetInt32());
            var source = Swatches(looks);
            var (width, height) = ClipPicture.OrientedSize(4, 2, controls);
            Assert.Equal((item.GetProperty("size")[0].GetInt32(), item.GetProperty("size")[1].GetInt32()), (width, height));
            var target = new byte[width * height * 4];
            ClipPicture.Orient(source, target, controls, CancellationToken.None);
            Assert.Equal(item.GetProperty("topLeft").EnumerateArray().Select(value => value.GetInt32()), new int[] { target[2], target[1], target[0] });
        }
        Assert.False(ClipPicture.Orients(null));
        Assert.False(ClipPicture.Orients(Controls(look: ClipLook.Bw)));
    }

    // The Mac's EffectRenderTests frame: a gradient under a fine checkerboard, here reproduced pixel for pixel (Core Image's
    // linear gradient from the bottom-left to the top-right corner, 8 px squares at 55% opacity).
    internal static PixelBuffer SyntheticFrame(int width = 640, int height = 360)
    {
        var pixels = new byte[width * height * 4];
        double[] from = [0.1, 0.3, 0.8], to = [0.9, 0.5, 0.2];
        for (var row = 0; row < height; row++)
            for (var column = 0; column < width; column++)
            {
                double x = column + 0.5, y = height - row - 0.5;
                var t = Math.Clamp((x * width + y * height) / ((double)width * width + (double)height * height), 0, 1);
                var white = (column / 8 + (height - 1 - row) / 8) % 2 == 0;
                for (var channel = 0; channel < 3; channel++)
                {
                    var value = (white ? 0.55 : 0) + (from[channel] * (1 - t) + to[channel] * t) * 0.45;
                    pixels[(row * width + column) * 4 + 2 - channel] = (byte)Math.Round(value * 255);
                }
                pixels[(row * width + column) * 4 + 3] = 255;
            }
        return new(pixels, width, height, width * 4);
    }

    private static PixelBuffer Copy(PixelBuffer frame) => new(frame.Pixels.ToArray(), frame.Width, frame.Height, frame.Stride);

    private static ClipEffect Effect(string kind, ClipEffectRect? rect = null, string? text = null, string? position = null)
        => new($"fx-{kind}-1", null, kind, 0, 4)
        {
            Rect = rect, Tracking = kind is "blur" or "pixelate" ? "none" : null, Text = text, Position = position, Scale = kind == "sticker" ? 1 : null
        };

    private static PixelBuffer Render(IReadOnlyList<ClipEffect> effects, int width = 640, int height = 360, double time = 1, PixelBuffer? source = null)
    {
        source ??= SyntheticFrame();
        var crop = ExportPresets.CenterCrop(new(source.Width, source.Height), new(width, height));
        var frame = width == source.Width && height == source.Height ? Copy(source) : Scale(source, crop, width, height);
        using var frames = new EffectFrames(new(effects, new Dictionary<string, string>()), FixtureLoader.SharedRoot);
        frames.DrawPicture(frame, source.Width, source.Height, crop, time, null, CancellationToken.None);
        frames.DrawFrame(frame, time, time, value => value, CancellationToken.None);
        return frame;
    }

    /// <summary>The crop of <paramref name="source"/> filled into the output with bilinear sampling, as Core Image's fill draws it.</summary>
    private static PixelBuffer Scale(PixelBuffer source, RectD crop, int width, int height)
    {
        var pixels = new byte[width * height * 4];
        var input = source.Pixels.ToArray();
        for (var row = 0; row < height; row++)
            for (var column = 0; column < width; column++)
            {
                var x = Math.Clamp(crop.X + (column + 0.5) * crop.Width / width - 0.5, 0, source.Width - 1);
                var y = Math.Clamp(crop.Y + (row + 0.5) * crop.Height / height - 0.5, 0, source.Height - 1);
                int x0 = (int)x, y0 = (int)y, x1 = Math.Min(source.Width - 1, x0 + 1), y1 = Math.Min(source.Height - 1, y0 + 1);
                double fx = x - x0, fy = y - y0;
                for (var channel = 0; channel < 4; channel++)
                {
                    double Sample(int sx, int sy) => input[sy * source.Stride + sx * 4 + channel];
                    var value = (Sample(x0, y0) * (1 - fx) + Sample(x1, y0) * fx) * (1 - fy) + (Sample(x0, y1) * (1 - fx) + Sample(x1, y1) * fx) * fy;
                    pixels[(row * width + column) * 4 + channel] = (byte)Math.Round(value);
                }
            }
        return new(pixels, width, height, width * 4);
    }

    private static double Variance(PixelBuffer frame, int left, int top, int width, int height, int channel = 1)
    {
        var values = new List<double>();
        for (var row = top; row < top + height; row++)
            for (var column = left; column < left + width; column++) values.Add(frame.Pixels.Span[row * frame.Stride + column * 4 + channel]);
        var mean = values.Average();
        return values.Sum(value => (value - mean) * (value - mean)) / values.Count;
    }

    /// <summary>The Mac's golden comparison: mean channel difference and the share of channels more than 24 apart.</summary>
    private (double Mean, double Far) CompareGolden(string name, PixelBuffer frame, SKRectI? region = null)
    {
        using var golden = SKBitmap.Decode(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "effects", name + ".png"));
        Assert.Equal((golden.Width, golden.Height), (frame.Width, frame.Height));
        var area = region ?? new SKRectI(0, 0, frame.Width, frame.Height);
        long total = 0, far = 0, count = 0;
        for (var row = area.Top; row < area.Bottom; row++)
            for (var column = area.Left; column < area.Right; column++)
            {
                var expected = golden.GetPixel(column, row);
                var offset = row * frame.Stride + column * 4;
                int[] differences = [Math.Abs(expected.Red - frame.Pixels.Span[offset + 2]), Math.Abs(expected.Green - frame.Pixels.Span[offset + 1]),
                    Math.Abs(expected.Blue - frame.Pixels.Span[offset]), Math.Abs(expected.Alpha - frame.Pixels.Span[offset + 3])];
                foreach (var difference in differences) { total += difference; if (difference > 24) far++; count++; }
            }
        var result = (total / (double)count, far / (double)count);
        output.WriteLine($"{name}{(region is null ? "" : " (its footprint)")}: mean {result.Item1:F3}, far {result.Item2 * 100:F2}%");
        if (Environment.GetEnvironmentVariable("VOXCLIP_EFFECT_CAPTURES") is { Length: > 0 } folder)
        {
            Directory.CreateDirectory(folder);
            using var bitmap = new SKBitmap(new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
            System.Runtime.InteropServices.Marshal.Copy(frame.Pixels.ToArray(), 0, bitmap.GetPixels(), frame.Pixels.Length);
            using var data = bitmap.Encode(SKEncodedImageFormat.Png, 100);
            File.WriteAllBytes(Path.Combine(folder, name + ".png"), data.ToArray());
        }
        return result;
    }

    [Fact]
    public void TheSyntheticFrameIsTheMacsFrame()
    {
        // Outside the blur's region the Mac's golden is the plain frame.
        var (mean, _) = CompareGolden("blur", Render([Effect("blur", new(0.5, 0.2, 0.3, 0.4))]));
        Assert.True(mean < 1.5);
        using var golden = SKBitmap.Decode(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "effects", "blur.png"));
        var plain = SyntheticFrame();
        var largest = 0;
        for (var row = 0; row < 360; row++)
            for (var column = 0; column < 200; column++)
            {
                var expected = golden.GetPixel(column, row);
                var offset = (row * 640 + column) * 4;
                largest = Math.Max(largest, Math.Max(Math.Abs(expected.Red - plain.Pixels.Span[offset + 2]), Math.Abs(expected.Blue - plain.Pixels.Span[offset])));
            }
        Assert.True(largest <= 1, $"{largest}");
    }

    [Fact]
    public void BlurAndPixelateCoverOnlyTheirRegionAndMatchTheMacGoldens()
    {
        var rect = new ClipEffectRect(0.5, 0.2, 0.3, 0.4);
        var plain = Render([]);
        var blurred = Render([Effect("blur", rect)]);
        var pixelated = Render([Effect("pixelate", rect)]);
        Assert.True(Variance(blurred, 340, 90, 150, 100) < Variance(plain, 340, 90, 150, 100) * 0.2);
        Assert.True(Variance(pixelated, 340, 90, 150, 100) < Variance(plain, 340, 90, 150, 100) * 0.9);
        Assert.Equal(Variance(plain, 40, 90, 150, 100), Variance(blurred, 40, 90, 150, 100));
        foreach (var (name, frame) in new[] { ("blur", blurred), ("pixelate", pixelated) })
        {
            var (mean, far) = CompareGolden(name, frame);
            Assert.True(mean < 1.5 && far < 0.01, $"{name}: mean {mean}, far {far}");
        }
    }

    [Fact]
    public void OverlayAndPointerGoldensMatchTheMacsWithinTextAntialiasing()
    {
        // The title golden is a 9:16 crop of the 16:9 frame, which the Mac upscales with Core Image's Lanczos filter; the test
        // upscales bilinearly, so the checkerboard's phase under the translucent box differs. The title is compared by its
        // geometry instead: the box's edges and the white text's ink bounds, each within 3 px of the golden's.
        var title = Render([Effect("title", text: "Day 1", position: "top")], 360, 640);
        ExpectSameGeometry("title", FrameTitleGeometry(title, (60, 18), (150, 30), 150), GoldenTitleGeometry("title", (60, 18), (150, 30), 150));
        var cases = new (string Name, PixelBuffer Frame)[]
        {
            ("emoji", Render([Effect("sticker", text: "\U0001F525", position: "topRight")])),
            ("arrow", Render([Effect("arrow", new(0.62, 0.3, 0.12, 0.12))])),
            ("lower-third", Render([Effect("lowerThird", text: "Synthetic speaker", position: "bottomLeft")])),
            ("circle-progress", Render([Effect("circle", new(0.2, 0.3, 0.2, 0.3)), Effect("progress", position: "bottom")], time: 2)),
        };
        var results = cases.Select(item => (item.Name, Metrics: CompareGolden(item.Name, item.Frame))).ToArray();
        foreach (var (name, (mean, far)) in results)
            // The Mac's own bar: it absorbs antialiasing differences (Skia against Core Graphics and Core Text) but not a moved,
            // missing or different overlay.
            Assert.True(mean < 1.5 && far < 0.01, $"{name}: mean {mean}, far {far}");
    }

    /// <summary>The title box (columns whose brightest pixel in a band of rows inside the box, and rows whose brightest pixel in a
    /// band of columns inside it, stay under 120: the box darkens every checker square) and the white text's ink bounds above
    /// <paramref name="textRows"/>. <paramref name="rows"/> and <paramref name="columns"/> are the bands.</summary>
    private static (SKRectI Box, SKRectI Text) TitleGeometry(Func<int, int, (byte Red, byte Green, byte Blue)> pixel, int width, int height,
        (int From, int Count) rows, (int From, int Count) columns, int textRows)
    {
        static int Luma((byte Red, byte Green, byte Blue) value) => (value.Red * 299 + value.Green * 587 + value.Blue * 114) / 1000;
        var boxColumns = Enumerable.Range(0, width).Where(column => Enumerable.Range(rows.From, rows.Count).Max(row => Luma(pixel(column, row))) < 120).ToArray();
        var boxRows = Enumerable.Range(0, Math.Min(height, textRows + 20)).Where(row => Enumerable.Range(columns.From, columns.Count).Max(column => Luma(pixel(column, row))) < 120).ToArray();
        int top = int.MaxValue, bottom = 0, left = int.MaxValue, right = 0;
        for (var row = 0; row < textRows; row++)
            for (var column = 0; column < width; column++)
            {
                var value = pixel(column, row);
                if (Math.Min(value.Red, Math.Min(value.Green, value.Blue)) <= 235) continue;
                top = Math.Min(top, row); bottom = Math.Max(bottom, row); left = Math.Min(left, column); right = Math.Max(right, column);
            }
        return (new(boxColumns.Min(), boxRows.Min(), boxColumns.Max(), boxRows.Max()), new(left, top, right, bottom));
    }

    private static (SKRectI Box, SKRectI Text) GoldenTitleGeometry(string name, (int, int) rows, (int, int) columns, int textRows)
    {
        using var golden = SKBitmap.Decode(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "effects", name + ".png"));
        return TitleGeometry((column, row) => { var pixel = golden.GetPixel(column, row); return (pixel.Red, pixel.Green, pixel.Blue); },
            golden.Width, golden.Height, rows, columns, textRows);
    }

    private static (SKRectI Box, SKRectI Text) FrameTitleGeometry(PixelBuffer frame, (int, int) rows, (int, int) columns, int textRows)
        => TitleGeometry((column, row) =>
        {
            var offset = row * frame.Stride + column * 4;
            return (frame.Pixels.Span[offset + 2], frame.Pixels.Span[offset + 1], frame.Pixels.Span[offset]);
        }, frame.Width, frame.Height, rows, columns, textRows);

    private void ExpectSameGeometry(string name, (SKRectI Box, SKRectI Text) actual, (SKRectI Box, SKRectI Text) expected)
    {
        output.WriteLine($"{name} box {actual.Box} vs Mac {expected.Box}; text {actual.Text} vs Mac {expected.Text}");
        foreach (var (mine, mac) in new[] { (actual.Box, expected.Box), (actual.Text, expected.Text) })
            Assert.True(Math.Abs(mine.Left - mac.Left) <= 3 && Math.Abs(mine.Right - mac.Right) <= 3 && Math.Abs(mine.Top - mac.Top) <= 3 &&
                Math.Abs(mine.Bottom - mac.Bottom) <= 3, $"{name}: {mine} vs Mac {mac}");
    }

    private const string Hook = "Most founders price their product completely wrong";

    [Theory]
    [InlineData(360, 640)]
    [InlineData(640, 360)]
    public void AHookTitleWrapsWholeInsideTheFrame(int width, int height)
    {
        using var frames = new EffectFrames(Effects(), FixtureLoader.SharedRoot);
        var layout = frames.TitleLayout(Hook, "top", width, height)!;
        var shortSide = Math.Min(width, height);
        Assert.InRange(layout.Lines.Count, width < height ? 2 : 1, width < height ? 3 : 2);
        Assert.InRange(layout.Size, Math.Round(shortSide * 0.05, MidpointRounding.AwayFromZero), Math.Round(shortSide * 0.075, MidpointRounding.AwayFromZero));
        Assert.Equal(Hook, string.Join(' ', layout.Texts));
        var widths = layout.Lines.Select(line => line.Width).ToArray();
        Assert.True(widths.Min() > widths.Max() * 0.5, $"balanced: {string.Join(", ", widths)}");
        Assert.True(layout.TextWidth + layout.PadX * 2 <= layout.Box.Width + 1 && layout.Box.Width <= width * 0.92 + 1);
        Assert.True(layout.Box.Left >= 0 && layout.Box.Right <= width && layout.Box.Top >= 0 && layout.Box.Bottom <= height);
        Assert.True(layout.Box.MidY < height * 0.4, "at the top");
        // Every white text pixel lies inside the box, clear of its clip edge: no word is cut off.
        var card = new ClipEffect("fx-hook-1", null, "title", 0, 4) { Text = Hook, Position = "top" };
        var shown = Render([card], width, height);
        var inner = SKRectI.Inflate(layout.Box, -(int)Math.Floor(layout.PadX * 0.5), 0);
        for (var row = 0; row < height; row++)
            for (var column = 0; column < width; column++)
            {
                var offset = row * shown.Stride + column * 4;
                if (shown.Pixels.Span[offset] > 235 && shown.Pixels.Span[offset + 1] > 235 && shown.Pixels.Span[offset + 2] > 235)
                    Assert.True(inner.Contains(column, row), $"text pixel {column},{row} outside {inner}");
            }
    }

    [Fact]
    public void HookTitlesMatchTheMacGoldens()
    {
        var card = new ClipEffect("fx-hook-1", null, "title", 0, 4) { Text = Hook, Position = "top" };
        // Landscape: the unscaled base, so the whole frame compares.
        var (mean, far) = CompareGolden("hook-landscape", Render([card], 640, 360));
        Assert.True(mean < 1.5 && far < 0.01, $"hook-landscape: mean {mean}, far {far}");
        // Portrait: the Mac's 9:16 base is Lanczos-upscaled, so the card compares by geometry, as the single-line title does.
        using var frames = new EffectFrames(Effects(), FixtureLoader.SharedRoot);
        var layout = frames.TitleLayout(Hook, "top", 360, 640)!;
        var rows = (layout.Box.Top + 2, Math.Min(18, layout.Box.Height - 4));
        var columns = (layout.Box.MidX - 15, 30);
        ExpectSameGeometry("hook-portrait", FrameTitleGeometry(Render([card], 360, 640), rows, columns, layout.Box.Bottom + 10),
            GoldenTitleGeometry("hook-portrait", rows, columns, layout.Box.Bottom + 10));
    }

    [Fact]
    public void OverlaysAreOffOutsideTheirRangeAndNoEffectsIsANoOp()
    {
        var plain = Render([]);
        Assert.Equal(SyntheticFrame().Pixels.ToArray(), plain.Pixels.ToArray());
        Assert.Equal(plain.Pixels.ToArray(), Render([Effect("title", text: "Day 1", position: "top")], time: 4.5).Pixels.ToArray());
        Assert.Equal(plain.Pixels.ToArray(), Render([Effect("blur", new(0, 0, 1, 1))], time: 5).Pixels.ToArray());
    }

    [Fact]
    public void PictureRectsFollowTheCropToAnotherShape()
    {
        // A 9:16 export crops the middle of the 16:9 picture; a blur on the right quarter is off-frame.
        var plain = Render([], 202, 360);
        Assert.Equal(plain.Pixels.ToArray(), Render([Effect("blur", new(0.75, 0, 0.25, 1))], 202, 360).Pixels.ToArray());
        var middle = Render([Effect("blur", new(0.45, 0.4, 0.1, 0.2))], 202, 360);
        Assert.True(Variance(middle, 90, 160, 20, 40) < Variance(plain, 90, 160, 20, 40) * 0.3);
    }

    private static double MeanDifference(PixelBuffer left, PixelBuffer right)
    {
        Assert.Equal((left.Width, left.Height), (right.Width, right.Height));
        long total = 0;
        for (var index = 0; index < left.Pixels.Length; index++) total += Math.Abs(left.Pixels.Span[index] - right.Pixels.Span[index]);
        return total / (double)left.Pixels.Length;
    }

    private static PixelBuffer Oriented(PixelBuffer frame, ProjectClipControls controls)
    {
        var (width, height) = ClipPicture.OrientedSize(frame.Width, frame.Height, controls);
        var target = new byte[width * height * 4];
        ClipPicture.Orient(frame, target, controls, CancellationToken.None);
        return new(target, width, height, width * 4);
    }

    /// <summary>The composer's after-scale stages (look, censors and pointers, overlays) on <paramref name="frame"/>, the oriented
    /// source at output size.</summary>
    private static PixelBuffer Finish(PixelBuffer frame, ClipRenderInput clip, double editedTime = 1)
    {
        var composer = new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot);
        var result = Copy(frame);
        composer.FinishClipFrame(result, Snapshot(clip, 480_000), editedTime, frame.Width, frame.Height, new(0, 0, frame.Width, frame.Height), CancellationToken.None);
        return result;
    }

    private static ClipEffectsRenderInput Effects(params ClipEffect[] effects) => new(effects, new Dictionary<string, string>());

    [Fact]
    public void ABlurFollowsTheFlippedAndTurnedPicture()
    {
        var blur = Effect("blur", new(0.05, 0.1, 0.3, 0.8));
        var source = SyntheticFrame();
        var upright = Finish(source, new(null, Effects(blur)));
        var flip = Controls(flip: true);
        var flipped = Finish(Oriented(source, flip), new(flip, Effects(blur)));
        var difference = MeanDifference(Oriented(upright, flip), flipped);
        output.WriteLine($"flipped blur vs mirrored upright: mean {difference:F3}");
        Assert.True(difference < 1.5, $"{difference}");
        foreach (var controls in new[] { Controls(rotation: 90), Controls(rotation: 270), Controls(flip: true, rotation: 90) })
        {
            var turned = Effect("blur", new(0.1, 0.15, 0.25, 0.4));
            var censoredFirst = Oriented(Finish(source, new(null, Effects(turned))), controls);
            var turnedFirst = Finish(Oriented(source, controls), new(controls, Effects(turned)));
            var turnedDifference = MeanDifference(censoredFirst, turnedFirst);
            output.WriteLine($"{controls.RotationDegrees}° flip {controls.FlipHorizontal}: mean {turnedDifference:F3}");
            Assert.True(turnedDifference < 1, $"{controls.RotationDegrees}°: {turnedDifference}");
        }
    }

    private static int AccentPixels(PixelBuffer frame)
    {
        var count = 0;
        for (var index = 0; index < frame.Pixels.Length; index += 4)
            if (frame.Pixels.Span[index + 2] > 200 && frame.Pixels.Span[index + 1] > 150 && frame.Pixels.Span[index] < 90) count++;
        return count;
    }

    [Fact]
    public void TheBlackAndWhiteLookGradesThePictureBeforeOverlaysDraw()
    {
        // Colour bars with a yellow bar, as the Mac's bars fixture has.
        var bars = new byte[320 * 180 * 4];
        byte[][] colours = [[255, 255, 255], [255, 255, 0], [0, 255, 255], [0, 255, 0], [255, 0, 255], [255, 0, 0], [0, 0, 255], [0, 0, 0]];
        for (var row = 0; row < 180; row++)
            for (var column = 0; column < 320; column++)
            {
                var colour = colours[column / 40];
                var offset = (row * 320 + column) * 4;
                bars[offset] = colour[2]; bars[offset + 1] = colour[1]; bars[offset + 2] = colour[0]; bars[offset + 3] = 255;
            }
        var frame = new PixelBuffer(bars, 320, 180, 1280);
        var mono = Controls(look: ClipLook.Bw);
        Assert.True(AccentPixels(frame) > 0, "the bars as filmed include yellow");
        Assert.Equal(0, AccentPixels(Finish(frame, new(mono, null))));
        var arrow = new ClipEffect("fx-arrow-1", null, "arrow", 0, 2) { Rect = new(0.6, 0.3, 0.15, 0.2) };
        var progress = new ClipEffect("fx-progress-1", null, "progress", 0, 2) { Position = "bottom" };
        foreach (var effect in new[] { arrow, progress })
        {
            var graded = Finish(frame, new(mono, Effects(effect)));
            var ungraded = Finish(frame, new(null, Effects(effect)));
            output.WriteLine($"{effect.Kind}: {AccentPixels(graded)} accent pixels under B&W, {AccentPixels(ungraded)} without");
            Assert.True(AccentPixels(graded) > 40, $"{effect.Kind}: {AccentPixels(graded)}");
            // The yellow bar itself still turns grey: only the overlay keeps the accent.
            Assert.True(AccentPixels(graded) < AccentPixels(ungraded) - 1_000, $"{effect.Kind}: {AccentPixels(graded)} vs {AccentPixels(ungraded)}");
        }
    }

    [Fact]
    public void ATitleShowsOverItsWindowOnTheRenderedClock()
    {
        var vector = Cases().GetProperty("effectsAtSpeed");
        var window = vector.GetProperty("title");
        var title = new ClipEffect("fx-title-1", null, "title", window.GetProperty("start").GetDouble(), window.GetProperty("end").GetDouble())
            { Text = "Day 1", Position = "top" };
        var timing = new ClipSpeedTiming(vector.GetProperty("speed").GetDouble());
        var frame = SyntheticFrame(320, 180);
        bool Shown(ClipSpeedTiming speed, double rendered)
            => !Finish(frame, new(Controls(speed.Speed), Effects(title)), speed.Edited(rendered)).Pixels.Span.SequenceEqual(frame.Pixels.Span);
        foreach (var seconds in window.GetProperty("shown").EnumerateArray()) Assert.True(Shown(timing, seconds.GetDouble()), $"{seconds} s shown");
        foreach (var seconds in window.GetProperty("hidden").EnumerateArray()) Assert.False(Shown(timing, seconds.GetDouble()), $"{seconds} s hidden");
        foreach (var seconds in window.GetProperty("shownAtOneX").EnumerateArray()) Assert.True(Shown(new(1), seconds.GetDouble()), $"{seconds} s at 1×");
    }

    [Fact]
    public void AFreezeHoldsThePictureAtItsStart()
    {
        var freeze = Effects(new ClipEffect("fx-freeze-1", null, "freeze", 0.5, 1.5));
        Assert.Equal([0.4, 0.5, 0.5, 0.5, 1.5, 1.7], new[] { 0.4, 0.5, 0.9, 1.49, 1.5, 1.7 }.Select(freeze.PictureTime));
        // The composer draws picture effects at the held time: a blur that starts inside the freeze shows only after it.
        var blur = new ClipEffect("fx-blur-1", null, "blur", 1, 2) { Rect = new(0, 0, 0.5, 1), Tracking = "none" };
        var held = new ClipEffectsRenderInput([new ClipEffect("fx-freeze-1", null, "freeze", 0.5, 1.5), blur], new Dictionary<string, string>());
        var frame = SyntheticFrame(320, 180);
        Assert.True(Finish(frame, new(null, held), 1.2).Pixels.Span.SequenceEqual(frame.Pixels.Span));
        Assert.False(Finish(frame, new(null, held), 1.6).Pixels.Span.SequenceEqual(frame.Pixels.Span));
    }
}
