using System.Buffers.Binary;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using Whisper.net;

namespace VoxClip.Media.Speech;

internal readonly record struct SpeechUnit(int Start, int End);

internal static class WhisperAudio
{
    internal static async Task<float[]> ReadAsync(ExtractedAudio audio, CancellationToken ct)
    {
        await using var stream = File.OpenRead(audio.Wav16kPath);
        using var reader = new BinaryReader(stream, System.Text.Encoding.ASCII, true);
        if (new string(reader.ReadChars(4)) != "RIFF") throw InvalidWave();
        reader.ReadUInt32();
        if (new string(reader.ReadChars(4)) != "WAVE") throw InvalidWave();
        var formatValid = false;
        while (stream.Position + 8 <= stream.Length)
        {
            ct.ThrowIfCancellationRequested();
            var tag = new string(reader.ReadChars(4));
            var size = reader.ReadUInt32();
            var end = stream.Position + size;
            if (end > stream.Length) throw InvalidWave();
            if (tag == "fmt ")
            {
                if (size < 16) throw InvalidWave();
                var format = reader.ReadUInt16();
                var channels = reader.ReadUInt16();
                var rate = reader.ReadUInt32();
                var byteRate = reader.ReadUInt32();
                var block = reader.ReadUInt16();
                var bits = reader.ReadUInt16();
                formatValid = format == 1 && channels == 1 && rate == 16000 && byteRate == 32000 && block == 2 && bits == 16;
            }
            else if (tag == "data")
            {
                if (!formatValid || size % 2 != 0 || size / 2 != audio.SampleCount || audio.SampleCount > int.MaxValue) throw InvalidWave();
                var samples = new float[(int)audio.SampleCount];
                var buffer = new byte[1 << 20];
                var position = 0;
                while (position < samples.Length)
                {
                    var count = Math.Min(buffer.Length / 2, samples.Length - position) * 2;
                    await stream.ReadExactlyAsync(buffer.AsMemory(0, count), ct).ConfigureAwait(false);
                    for (var index = 0; index < count; index += 2) samples[position++] = BinaryPrimitives.ReadInt16LittleEndian(buffer.AsSpan(index, 2)) / 32768f;
                }
                return samples;
            }
            stream.Position = end + (size & 1);
        }
        throw InvalidWave();
    }

    internal static void Normalize(float[] samples, CancellationToken ct)
    {
        double activePower = 0;
        long activeCount = 0;
        for (var offset = 0; offset + 160 <= samples.Length; offset += 160)
        {
            ct.ThrowIfCancellationRequested();
            double power = 0;
            for (var index = offset; index < offset + 160; index++) power += (double)samples[index] * samples[index];
            if (power / 160 > 1e-6) { activePower += power; activeCount += 160; }
        }
        var gainDb = activeCount == 0 ? 0 : Math.Clamp(-20 - 10 * Math.Log10(activePower / activeCount), -20, 30);
        var gain = Math.Pow(10, gainDb / 20);
        for (var index = 0; index < samples.Length; index++)
        {
            if ((index & 16383) == 0) ct.ThrowIfCancellationRequested();
            samples[index] = (float)Math.Clamp(samples[index] * gain, -1, 1);
        }
    }

    internal static IReadOnlyList<SpeechUnit> MergeRegions(IReadOnlyList<VadSegmentData> regions, int sampleCount)
    {
        var units = new List<SpeechUnit>();
        foreach (var region in regions.OrderBy(region => region.Start))
        {
            var start = (int)Math.Clamp(Math.Floor(region.Start.TotalSeconds * 16000), 0, sampleCount);
            var end = (int)Math.Clamp(Math.Ceiling(region.End.TotalSeconds * 16000), 0, sampleCount);
            if (end <= start) continue;
            if (units.Count > 0 && start <= units[^1].End) units[^1] = units[^1] with { End = Math.Max(units[^1].End, end) };
            else units.Add(new(start, end));
        }
        return units;
    }

    private static VoxClipException InvalidWave() => new(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: the extracted audio must be 16 kHz mono PCM16 WAV. Your edits are saved.");
}
