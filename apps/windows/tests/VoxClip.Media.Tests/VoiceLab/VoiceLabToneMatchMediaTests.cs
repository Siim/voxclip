using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>The tone match where a take is heard (voice-lab.md §8.7 item 2b; Mac <c>VoiceLabCompositionTests</c>
/// <c>toneMatchTiltsTheStagedTakeOnlyWhenTheSegmentSaysSo</c> and <c>toneMatchRunsFromTheAssetsFirstFrameWhenTheReadStartsLater</c>): the take's
/// own mix (the staged scratch) and the render's mixer, which reads assets random-access for preview and export, both run the cascade from
/// the asset's first frame, so a frame sounds the same wherever it is read. An asset without a tilt is read as it is.</summary>
public sealed class VoiceLabToneMatchMediaTests
{
    private const int Rate = 24_000;
    private const int Frames = Rate * 2;

    /// <summary>A 16-bit WAV of LCG noise, <paramref name="channels"/> channels, the second at half level.</summary>
    private static byte[] Wave(int channels)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        var block = channels * 2;
        writer.Write("RIFF"u8); writer.Write(36 + Frames * block); writer.Write("WAVEfmt "u8); writer.Write(16);
        writer.Write((short)1); writer.Write((short)channels); writer.Write(Rate); writer.Write(Rate * block);
        writer.Write((short)block); writer.Write((short)16); writer.Write("data"u8); writer.Write(Frames * block);
        var state = 7u;
        for (var frame = 0; frame < Frames; frame++)
        {
            state = unchecked(state * 1_664_525u + 1_013_904_223u);
            var value = (short)((int)(state >> 16) - 32_768 >> 2);
            for (var channel = 0; channel < channels; channel++) writer.Write(channel == 0 ? value : (short)(value / 2));
        }
        return stream.ToArray();
    }

    private static float[] Channel(VoiceLabWavePcm wave, int channel) =>
        Enumerable.Range(0, wave.Frames).Select(frame => (float)wave.Sample(frame, channel)).ToArray();

    private static float[] Read(VoiceLabWaveReader reader, long first, int count)
    {
        var stereo = new float[count * 2];
        reader.Read(first, 1, stereo, TestContext.Current.CancellationToken);
        return Enumerable.Range(0, count).Select(index => stereo[2 * index]).ToArray();
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public void ToneMatchRunsFromTheAssetsFirstFrameWhenTheReadStartsLater(int channels)
    {
        var folder = Directory.CreateTempSubdirectory("voxclip-tone-match-").FullName;
        try
        {
            var bytes = Wave(channels);
            var path = Path.Combine(folder, "take.wav");
            File.WriteAllBytes(path, bytes);
            var wave = VoiceLabWavePcm.Parse(bytes);
            var sections = VoiceLabTilt.Sections(1.5, Rate);
            // The take's own mix runs the cascade over the whole asset (VoiceLabTakeRenderer.Stage), channel by channel.
            var staged = VoiceLabTakeRenderer.TiltedChannels(wave, 1.5)!;
            Assert.Equal(channels, staged.Length);
            Assert.Equal(VoiceLabTilt.Apply(Channel(wave, 0), sections), staged[0]);
            Assert.Null(VoiceLabTakeRenderer.TiltedChannels(wave, null));
            using var asset = new PreparedVoiceLabAsset("segment", "asset", path, Path.Combine(folder, "scratch"), Rate, channels, Frames,
                0, Frames, 1, 0, tiltDbPerOctave: 1.5);
            // A read that starts mid-asset (a preview seek, an export's later piece) hears the cascade warmed from frame 0, not from the read.
            using (var reader = new VoiceLabWaveReader(asset))
                Assert.Equal(staged[0][30_000..34_000], Read(reader, 30_000, 4_000));
            // After a later read, an earlier one warms again from frame 0; reads that follow on keep the state.
            using (var reader = new VoiceLabWaveReader(asset))
            {
                Assert.Equal(staged[0][40_000..41_000], Read(reader, 40_000, 1_000));
                Assert.Equal(staged[0][5_000..13_000], Read(reader, 5_000, 8_000));
                Assert.Equal(staged[0][13_000..20_000], Read(reader, 13_000, 7_000));
            }
            // Without a tilt the asset is read as it is.
            using var plain = new PreparedVoiceLabAsset("segment", "asset", path, Path.Combine(folder, "plain"), Rate, channels, Frames, 0, Frames, 1, 0);
            using (var reader = new VoiceLabWaveReader(plain))
                Assert.Equal(Channel(wave, 0)[30_000..34_000], Read(reader, 30_000, 4_000));
        }
        finally { Directory.Delete(folder, true); }
    }
}
