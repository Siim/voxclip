using System.Collections.Concurrent;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Pipeline;

/// <summary>Owns one pooled preview buffer until disposed; do not retain pixels after disposal.</summary>
public sealed class PreviewFrameLease : IDisposable
{
    private Action? release;
    private readonly PreviewFrame frame;
    internal PreviewFrameLease(PreviewFrame frame, Action release) { this.frame = frame; this.release = release; }
    /// <summary>Read or copy this frame before releasing the lease; architecture §6.3.</summary>
    public PreviewFrame Frame
    {
        get { ObjectDisposedException.ThrowIf(Volatile.Read(ref release) is null, this); return frame; }
    }
    /// <summary>Return the buffer exactly once. Disposing the engine never invalidates an outstanding lease.</summary>
    public void Dispose() => Interlocked.Exchange(ref release, null)?.Invoke();
}

internal sealed class PreviewFramePool
{
    internal const int Capacity = 8;
    private readonly ConcurrentQueue<byte[]> free = new();
    internal PixelSize Size { get; }
    internal PreviewFramePool(PixelSize size)
    {
        Size = size;
        var length = checked(size.Width * size.Height * 4);
        for (var index = 0; index < Capacity; index++) free.Enqueue(GC.AllocateUninitializedArray<byte>(length));
    }
    internal PreviewFrameLease? TryRent(double edited, double source, long generation)
    {
        if (!free.TryDequeue(out var pixels)) return null;
        var buffer = new PixelBuffer(pixels, Size.Width, Size.Height, Size.Width * 4);
        return new(new(buffer, edited, source, generation), () => free.Enqueue(pixels));
    }
}
