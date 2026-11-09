using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Thumbnails;

namespace VoxClip.Media.Frames;

/// <summary>A decoded frame, upright, and the source second it shows.</summary>
/// <param name="Pixels">Premultiplied BGRA, as <see cref="CurrentFrames"/> decodes it.</param>
/// <param name="Time">The frame's own time, which may differ from the time asked for by up to the reader's tolerance.</param>
public readonly record struct DecodedFrame(PixelBuffer Pixels, double Time);

/// <summary>Decodes frames of a source: the seam between the frame analyzer and FFmpeg, twin of the Mac <c>FrameDecoding</c>.</summary>
public interface IFrameDecoding
{
    /// <summary>A reader for one lane of work. The lane opens, reads and disposes it on its own thread, reading its times in order.</summary>
    /// <param name="source">The media file.</param>
    /// <param name="maximumEdge">The long side of each frame at most, in pixels; a smaller picture is never scaled up.</param>
    /// <param name="tolerance">Seconds a frame may be from the time asked for.</param>
    /// <param name="ct">Cancels the open.</param>
    IFrameReader Open(string source, int maximumEdge, double tolerance, CancellationToken ct);
}

/// <summary>One lane's frame reader, used on one thread only.</summary>
public interface IFrameReader : IDisposable
{
    /// <summary>The frame nearest <paramref name="time"/> within the reader's tolerance, and the source second it shows.</summary>
    DecodedFrame Read(double time, CancellationToken ct);
}

/// <summary>The shipped FFmpeg in software, as <see cref="CurrentFrames"/> decodes: the stream's rotation applied, the whole picture
/// scaled to the reader's long side (never up). Each reader keeps one decoder and decodes forward through its lane's times; a time
/// more than 2 s ahead or behind seeks.</summary>
public sealed class FfmpegFrameDecoder : IFrameDecoding
{
    /// <inheritdoc/>
    public IFrameReader Open(string source, int maximumEdge, double tolerance, CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrEmpty(source);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumEdge, 1);
        FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult();
        return new Reader(source, maximumEdge, tolerance);
    }

    /// <summary>The size of a picture of <paramref name="width"/> × <paramref name="height"/> with its long side at most
    /// <paramref name="maximumEdge"/>, each side rounded half away from zero and at least 1, as the sheet's JPEGs are scaled.</summary>
    public static PixelSize Fit(int width, int height, int maximumEdge)
    {
        var longest = Math.Max(width, height);
        var scale = longest > maximumEdge ? (double)maximumEdge / longest : 1;
        return new(Math.Max(1, (int)Math.Round(width * scale, MidpointRounding.AwayFromZero)),
            Math.Max(1, (int)Math.Round(height * scale, MidpointRounding.AwayFromZero)));
    }

    private sealed class Reader : IFrameReader
    {
        private readonly VideoDecoder decoder;
        private readonly double tolerance;
        private readonly int rotation;
        private readonly PixelSize output;

        internal Reader(string source, int maximumEdge, double tolerance)
        {
            decoder = new VideoDecoder(source, hardware: false);
            this.tolerance = double.IsFinite(tolerance) ? Math.Max(0, tolerance) : 0;
            rotation = decoder.RotationDegrees;
            var quarter = rotation is 90 or 270;
            output = Fit(quarter ? decoder.Height : decoder.Width, quarter ? decoder.Width : decoder.Height, maximumEdge);
        }

        public DecodedFrame Read(double time, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            var frame = decoder.ReadNear(Math.Max(0, time), tolerance, ct);
            var actual = double.IsFinite(decoder.Position) ? decoder.Position : time;
            return new(CurrentFrames.Transform(frame, rotation, output, output, preserveSource: true), actual);
        }

        public void Dispose() => decoder.Dispose();
    }
}
