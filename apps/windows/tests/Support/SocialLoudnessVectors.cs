using System.Text.Json;
using VoxClip.Core.Domain.Loudness;

namespace VoxClip.Tests.Support;

/// <summary>The signals of shared/fixtures/loudness/social-loudness-cases.json and social-limiter-cases.json (ADR-R47),
/// rendered as tools/fixtures/loudness/generate_social_loudness.py renders them, and the whole export rule over one of them;
/// Core and Media replay them.</summary>
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

    /// <summary>Streams <paramref name="samples"/> through <paramref name="limiter"/> in uneven chunks, so the lookahead and the
    /// detection history cross every kind of boundary, and returns every output frame.</summary>
    internal static float[] Stream(float[] samples, SocialLimiter limiter)
    {
        var output = new List<float>(samples.Length);
        var piece = new float[2 * 5003];
        for (int start = 0, chunk = 1; start < samples.Length; chunk = chunk * 7 % 5003 + 1)
        {
            var end = Math.Min(samples.Length, start + 2 * chunk);
            var written = limiter.Process(samples.AsSpan(start, end - start), piece);
            output.AddRange(piece.AsSpan(0, 2 * written));
            start = end;
        }
        var tail = new float[2 * limiter.Latency];
        output.AddRange(tail.AsSpan(0, 2 * limiter.Finish(tail)));
        return [.. output];
    }

    internal static SocialLoudnessMeasurement Measure(float[] samples)
    {
        var meter = new SocialLoudnessMeter(48_000, 2);
        meter.Append(samples);
        return meter.Finish();
    }

    /// <summary>The whole rule over one mix, as the exporters run it: measure, plan, simulate and land, export.</summary>
    internal static (SocialLoudnessDecision Plan, List<(double GainDb, double? Lufs)> Trials, SocialLoudnessDecision Decision, float[] Output,
        SocialLimiter Limiter, SocialLoudnessReport Report) Export(float[] samples)
    {
        var measurement = Measure(samples);
        var plan = SocialLoudness.Decide(measurement.IntegratedLufs(), measurement.TruePeakDbtp);
        var trials = new List<(double GainDb, double? Lufs)>();
        SocialLoudnessLanding landing;
        while (!(landing = SocialLoudness.Landing(plan, measurement.TruePeakDbtp, trials)).Settled)
            trials.Add((landing.GainDb, Measure(Stream(samples, new SocialLimiter(landing.GainDb, true, 48_000, 2))).IntegratedLufs()));
        var decision = landing.Decision;
        var limiter = new SocialLimiter(decision.GainDb, decision.Limiting, 48_000, 2);
        var output = Stream(samples, limiter);
        var report = SocialLoudness.Report(measurement, decision, limiter, decision.Limiting ? Measure(output) : null);
        return (plan, trials, decision, output, limiter, report);
    }
}
