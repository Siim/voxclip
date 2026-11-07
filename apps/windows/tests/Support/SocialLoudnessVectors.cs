using System.Text.Json;

namespace VoxClip.Tests.Support;

/// <summary>The signals of shared/fixtures/loudness/social-loudness-cases.json (ADR-R47), rendered as
/// tools/fixtures/loudness/generate_social_loudness.py renders them; Core and Media replay them.</summary>
internal static class SocialLoudnessVectors
{
    /// <summary>One channel of a vector signal, rendered in Float64 and stored as Float32 like the generator.</summary>
    internal static float[] Render(JsonElement parts, double rate)
    {
        var output = new List<float>();
        foreach (var part in parts.EnumerateArray())
        {
            var count = part.GetProperty("samples").GetInt32();
            switch (part.GetProperty("type").GetString())
            {
                case "sine":
                {
                    var amplitude = Math.Pow(10, part.GetProperty("peakDbfs").GetDouble() / 20);
                    var frequency = part.GetProperty("frequency").GetDouble();
                    for (var index = 0; index < count; index++) output.Add((float)(amplitude * Math.Sin(2 * Math.PI * frequency * index / rate)));
                    break;
                }
                case "noise":
                {
                    var amplitude = Math.Pow(10, part.GetProperty("peakDbfs").GetDouble() / 20);
                    var hann = part.GetProperty("envelope").GetString() == "hann";
                    var state = (ulong)part.GetProperty("seed").GetInt64();
                    for (var index = 0; index < count; index++)
                    {
                        state = (1_664_525 * state + 1_013_904_223) % 4_294_967_296;
                        var value = amplitude * (state / 2_147_483_648.0 - 1);
                        if (hann) value *= 0.5 - 0.5 * Math.Cos(2 * Math.PI * index / count);
                        output.Add((float)value);
                    }
                    break;
                }
                default:
                    output.AddRange(Enumerable.Repeat(0f, count));
                    break;
            }
        }
        return output.ToArray();
    }

    /// <summary>The case's stereo signal, interleaved.</summary>
    internal static float[] Interleaved(JsonElement item)
    {
        var rate = item.GetProperty("rate").GetDouble();
        var channels = item.GetProperty("channels").EnumerateArray().Select(parts => Render(parts, rate)).ToArray();
        var frames = channels[0].Length;
        var output = new float[frames * channels.Length];
        for (var channel = 0; channel < channels.Length; channel++)
            for (var frame = 0; frame < frames; frame++) output[frame * channels.Length + channel] = channels[channel][frame];
        return output;
    }
}
