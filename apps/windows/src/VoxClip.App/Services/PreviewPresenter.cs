using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Services.Media;

namespace VoxClip.App.Services;

/// <summary>What the display watch needs from the page: whether the stage shows the player now, and what to do after a re-attach.</summary>
internal sealed record PreviewDisplayHooks(Func<bool> OnStage, Action Stalled);

internal sealed class PreviewPresenter(Image image, IPreviewEngine engine, Action<PreviewPosition> position, Action<Exception> error, Action<PixelBuffer>? still = null) : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly List<PreviewFrame> frames = [];
    private readonly CancellationTokenSource lifetime = new();
    private Task? reader;
    private WriteableBitmap? bitmap;
    private long generation = -1;
    private int failed;
    private long lastStill;
    private object? item;
    private PlayerDisplayWatch watch;
    private DispatcherQueueTimer? watchTimer;

    /// <summary>The display watch's hooks (design.md §5.4.4 g); without them the watch doesn't run.</summary>
    internal PreviewDisplayHooks? Display { get; init; }

    /// <summary>The preview the engine loaded or swapped in: a new item starts the display watch's own count.</summary>
    internal void Attach(object? loaded) => item = loaded;

    internal void Start()
    {
        CompositionTarget.Rendering += Present;
        reader = ReadAsync();
        if (Display is null) return;
        // Once a second while on screen: a ready preview whose image shows no frame is re-attached once and reported.
        watchTimer = image.DispatcherQueue.CreateTimer();
        watchTimer.Interval = TimeSpan.FromSeconds(1);
        watchTimer.Tick += (_, _) => CheckDisplay();
        watchTimer.Start();
    }

    /// <summary>Mac PlayerLayerView.checkDisplay: the item is ready (loaded, not failed) but the image holds no presented frame.</summary>
    private void CheckDisplay()
    {
        if (Display is not { } display) return;
        var inWindow = image.XamlRoot is not null && image.Visibility == Visibility.Visible && image.ActualWidth > 1 && image.ActualHeight > 1 && display.OnStage();
        var layerReady = bitmap is not null && ReferenceEquals(image.Source, bitmap);
        if (!watch.Tick(item, Volatile.Read(ref failed) == 0, layerReady, inWindow)) return;
        // Re-attach: the image takes the presented frame again (or the next frame makes a new one) and frames are presented again.
        CompositionTarget.Rendering -= Present;
        CompositionTarget.Rendering += Present;
        if (bitmap is not null) image.Source = bitmap;
        display.Stalled();
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
                var now = Environment.TickCount64;
                if (now - lastStill >= 250) { lastStill = now; still?.Invoke(buffer); }
            }
            catch (Exception exception) { Fail(exception); return; }
        }
        position(clock);
    }

    public async ValueTask DisposeAsync()
    {
        watchTimer?.Stop(); watchTimer = null;
        CompositionTarget.Rendering -= Present;
        await lifetime.CancelAsync();
        if (reader is not null) await reader;
        await engine.DisposeAsync();
        lifetime.Dispose();
        lock (gate) frames.Clear();
    }
}
