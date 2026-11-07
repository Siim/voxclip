using VoxClip.Core.Domain.Loudness;
using VoxClip.Media.Audio;

namespace VoxClip.Media.Pipeline;

/// <summary>What social loudness decided for one export (ADR-R47): the composed mix's measurement and the gain, after the
/// offline pre-passes that simulated the limiter and landed the gain on target.</summary>
internal sealed record ExportLoudnessPlan(SocialLoudnessMeasurement Measurement, SocialLoudnessDecision Decision);

/// <summary>The export's gain and true-peak limiter over a reader of interleaved 48 kHz stereo, read like the reader itself: it
/// reads at most <c>total</c> frames ahead of its lookahead and flushes the lookahead when the source ends, so it returns as
/// many frames as the source, in order, and the encoder never sees the latency. It meters what it returns when it limits; the
/// offline pre-pass and <c>EncodeAudio</c> read through the same stage (Mac ExportLoudnessStage).</summary>
internal sealed class ExportLoudnessStage
{
    private readonly StereoRead source;
    private readonly long total;
    private readonly SocialLoudnessMeter? meter;
    private float[] input = [];
    private float[] pending = [];
    private int pendingStart;
    private int pendingCount;
    private long consumed;
    private bool flushed;

    internal ExportLoudnessStage(StereoRead source, long total, double gainDb, bool limiting)
    {
        this.source = source; this.total = total;
        Limiter = new SocialLimiter(gainDb, limiting, 48_000, 2);
        meter = limiting ? new SocialLoudnessMeter(48_000, 2) : null;
    }

    internal SocialLimiter Limiter { get; }

    /// <summary>Up to <paramref name="frames"/> output frames into <paramref name="target"/>; 0 once everything is out.</summary>
    internal int Read(Span<float> target, int frames, CancellationToken ct)
    {
        var written = 0;
        while (written < frames)
        {
            if (pendingCount == 0 && !Fill(Math.Max(frames - written, 1), ct)) break;
            var take = Math.Min(frames - written, pendingCount);
            pending.AsSpan(2 * pendingStart, 2 * take).CopyTo(target[(2 * written)..]);
            pendingStart += take; pendingCount -= take; written += take;
        }
        return written;
    }

    /// <summary>The returned PCM's loudness when the stage limited.</summary>
    internal SocialLoudnessMeasurement? Measured() => meter?.Finish();

    // Pulls one source read through the limiter, or flushes its lookahead once the source is done; false when nothing is left.
    private bool Fill(int frames, CancellationToken ct)
    {
        while (pendingCount == 0)
        {
            if (flushed) return false;
            var want = (int)Math.Min(frames, total - consumed);
            var count = want > 0 ? ReadSource(want, ct) : 0;
            var room = Math.Max(count, Limiter.Latency);
            if (pending.Length < 2 * room) pending = new float[2 * room];
            int produced;
            if (count > 0) { produced = Limiter.Process(input.AsSpan(0, 2 * count), pending); consumed += count; }
            else { produced = Limiter.Finish(pending); flushed = true; }
            pendingStart = 0; pendingCount = produced;
            if (produced > 0) meter?.Append(pending.AsSpan(0, 2 * produced));
        }
        return true;
    }

    private int ReadSource(int frames, CancellationToken ct)
    {
        if (input.Length < 2 * frames) input = new float[2 * frames];
        return source(input, frames, ct);
    }
}
