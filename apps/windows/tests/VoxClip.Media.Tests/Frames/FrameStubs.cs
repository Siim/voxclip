using System.Collections.Concurrent;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Media.Frames;

namespace VoxClip.Media.Tests.Frames;

/// <summary>Stub frames for the analyzer: a solid picture of a chosen size per time, its own time <see cref="Offset"/> seconds after
/// the time asked for. Records every open and read.</summary>
internal sealed class StubFrameDecoder(int width = 1280, int height = 720) : IFrameDecoding
{
    internal int Width { get; } = width;
    internal int Height { get; } = height;
    internal ConcurrentQueue<(int Thread, int Edge, double Tolerance)> Opens { get; } = new();
    internal ConcurrentQueue<(int Thread, double Time)> Reads { get; } = new();
    internal double Offset { get; init; }
    /// <summary>Every lane waits here on its first read until this many lanes are reading: proof they run at once.</summary>
    internal Barrier? Together { get; init; }
    internal bool TogetherTimedOut { get; private set; }
    internal Func<double, Exception?>? Failure { get; init; }
    /// <summary>Set when a read starts; with <see cref="Hold"/>, the read then waits for it (or for its token).</summary>
    internal ManualResetEventSlim Reading { get; } = new();
    internal ManualResetEventSlim? Hold { get; init; }

    public IFrameReader Open(string source, int maximumEdge, double tolerance, CancellationToken ct)
    {
        Opens.Enqueue((Environment.CurrentManagedThreadId, maximumEdge, tolerance));
        return new Reader(this, maximumEdge);
    }

    private sealed class Reader(StubFrameDecoder owner, int edge) : IFrameReader
    {
        private bool first = true;

        public DecodedFrame Read(double time, CancellationToken ct)
        {
            owner.Reads.Enqueue((Environment.CurrentManagedThreadId, time));
            owner.Reading.Set();
            owner.Hold?.Wait(ct);
            if (first && owner.Together is { } together && !together.SignalAndWait(20_000, ct)) owner.TogetherTimedOut = true;
            first = false;
            if (owner.Failure?.Invoke(time) is { } failure) throw failure;
            var size = FfmpegFrameDecoder.Fit(owner.Width, owner.Height, edge);
            var pixels = new byte[size.Width * size.Height * 4];
            for (var index = 0; index < pixels.Length; index += 4) (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]) = (90, 120, 150, 255);
            return new(new PixelBuffer(pixels, size.Width, size.Height, size.Width * 4), time + owner.Offset);
        }

        public void Dispose() { }
    }
}

/// <summary>One face per frame, the same for every frame; records the threads it was called on and the screens it was given.</summary>
internal sealed class StubFrameFaces : IFrameFaces
{
    internal static readonly FrameFace Face = new(new ClipEffectRect(0.4, 0.2, 0.2, 0.36), 0.62, 0.31, 0.33, 0.02, 0.1);
    internal ConcurrentQueue<int> Threads { get; } = new();
    internal ConcurrentQueue<IReadOnlyList<ClipEffectRect>> Screens { get; } = new();

    public Task<FrameFaceFindings> FacesAsync(PixelBuffer frame, IReadOnlyList<ClipEffectRect> screens, CancellationToken ct)
    {
        Threads.Enqueue(Environment.CurrentManagedThreadId);
        Screens.Enqueue(screens);
        return Task.FromResult(new FrameFaceFindings(1, Face));
    }
}

/// <summary>Three text lines inside the top-right quarter of every frame it is asked about; records each call's thread.</summary>
internal sealed class StubFrameText : IFrameTextLines
{
    internal static readonly ClipEffectRect[] Lines = [new(0.6, 0.1, 0.2, 0.04), new(0.6, 0.2, 0.2, 0.04), new(0.6, 0.3, 0.2, 0.04)];
    internal ConcurrentQueue<int> Threads { get; } = new();

    public Task<IReadOnlyList<ClipEffectRect>> LinesAsync(PixelBuffer frame, CancellationToken ct)
    {
        Threads.Enqueue(Environment.CurrentManagedThreadId);
        return Task.FromResult<IReadOnlyList<ClipEffectRect>>(Lines);
    }
}

/// <summary>Eight text lines in the top-left quarter of every frame: a text cluster, so every sentence frame shows one screen.</summary>
internal sealed class StubScreenText : IFrameTextLines
{
    internal static readonly ClipEffectRect[] Lines = [.. Enumerable.Range(0, 8).Select(index => new ClipEffectRect(0.05, 0.05 + index * 0.04, 0.3, 0.03))];

    public Task<IReadOnlyList<ClipEffectRect>> LinesAsync(PixelBuffer frame, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<ClipEffectRect>>(Lines);
}

internal static class FrameFixtures
{
    internal const string ContentKey = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

    internal static TimedWord Word(string id, string text, double start, double end) =>
        new(id, text, WordKind.Word, start, end, null, null, null, null, TimingSource.Native);

    /// <summary>Two sentences, "One two." and "Three four.", from 0.8 s to 2.8 s, as the Mac's analyze-frames test uses.</summary>
    internal static TimedWord[] Words =>
        [Word("w1", "One", 0.8, 1.0), Word("w2", "two.", 1.1, 1.4), Word("w3", "Three", 2.0, 2.3), Word("w4", "four.", 2.4, 2.8)];

    internal static FrameAnalyzer Analyzer(IFrameDecoding decoder, FrameAnalysisCache? cache, IFrameFaces? faces = null, IFrameTextLines? text = null,
        Func<FrameScreenScan>? screens = null) =>
        new(faces ?? new StubFrameFaces(), screens ?? FrameAnalyzer.ScreensWith(text ?? new StubFrameText()), decoder, cache);

    internal static string TempRoot(string name) => Directory.CreateTempSubdirectory("voxclip-w5-" + name + "-").FullName;
}
