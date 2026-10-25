using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Services.Media;

namespace VoxClip.App.Services;

internal sealed class PreviewPresenter(Image image, IPreviewEngine engine, Action<PreviewPosition> position, Action<Exception> error, Action<PixelBuffer>? still = null) : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly List<PreviewFrame> frames = [];
    private readonly CancellationTokenSource lifetime = new();
    private Task? reader;
    private WriteableBitmap? bitmap;
    private long generation = -1;
    private int failed;
    private bool stillSent;

    internal void Start()
    {
        CompositionTarget.Rendering += Present;
        reader = ReadAsync();
    }

    private async Task ReadAsync()
    {
        try
        {
            await foreach (var frame in engine.ReadFramesAsync(lifetime.Token).ConfigureAwait(false))
            {
                lock (gate)
                {
                    if (frame.Generation < generation) continue;
                    if (frame.Generation > generation) { frames.Clear(); generation = frame.Generation; }
                    frames.Add(frame);
                    while (frames.Count > 6) frames.RemoveAt(0);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { Fail(exception); }
    }

    private void Fail(Exception exception)
    {
        if (Interlocked.Exchange(ref failed, 1) == 0) image.DispatcherQueue.TryEnqueue(() => error(exception));
    }

    private void Present(object? sender, object args)
    {
        if (Volatile.Read(ref failed) != 0) return;
        PreviewPosition clock;
        try { clock = engine.Position; }
        catch (Exception exception) { Fail(exception); return; }
        PreviewFrame? due = null;
        lock (gate)
        {
            for (var index = frames.Count - 1; index >= 0; index--)
            {
                if (frames[index].EditedPts > clock.EditedTime + 0.001) continue;
                due = frames[index];
                frames.RemoveRange(0, index + 1);
                break;
            }
        }
        if (due is not null)
        {
            try
            {
                var buffer = due.Buffer;
                if (buffer.Width <= 0 || buffer.Height <= 0 || buffer.Stride < buffer.Width * 4 || buffer.Pixels.Length < buffer.Stride * buffer.Height) return;
                if (bitmap is null || bitmap.PixelWidth != buffer.Width || bitmap.PixelHeight != buffer.Height)
                {
                    bitmap = new(buffer.Width, buffer.Height);
                    image.Source = bitmap;
                }
                using var stream = bitmap.PixelBuffer.AsStream();
                for (var row = 0; row < buffer.Height; row++) stream.Write(buffer.Pixels.Span.Slice(row * buffer.Stride, buffer.Width * 4));
                bitmap.Invalidate();
                if (!stillSent) { stillSent = true; still?.Invoke(buffer); }
            }
            catch (Exception exception) { Fail(exception); return; }
        }
        position(clock);
    }

    public async ValueTask DisposeAsync()
    {
        CompositionTarget.Rendering -= Present;
        await lifetime.CancelAsync();
        if (reader is not null) await reader;
        await engine.DisposeAsync();
        lifetime.Dispose();
        lock (gate) frames.Clear();
    }
}
