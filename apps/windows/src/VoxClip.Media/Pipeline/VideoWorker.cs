using System.Collections.Concurrent;
using VoxClip.Core.Domain.Captions;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

internal interface IPreviewVideoWorker : IAsyncDisposable
{
    Task Ready { get; }
    double Position { get; }
    Task<PixelBuffer> ReadAsync(double source, bool exact, CancellationToken ct);
}

internal sealed class VideoWorker : IPreviewVideoWorker
{
    private readonly BlockingCollection<OwnerCommand<PixelBuffer>> commands = new();
    private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task Ready => ready.Task;
    private Exception? failure;
    private VideoDecoder? decoder;
    private double position;
    public double Position => Volatile.Read(ref position);

    internal VideoWorker(string path, string name, Action? beforeOpen = null)
    {
        new Thread(() =>
        {
            try
            {
                beforeOpen?.Invoke();
                using var localDecoder = new VideoDecoder(path);
                decoder = localDecoder;
                ready.SetResult();
                foreach (var command in commands.GetConsumingEnumerable()) command.Execute();
            }
            catch (Exception exception) { Volatile.Write(ref failure, exception); ready.TrySetException(exception); }
            finally
            {
                commands.CompleteAdding();
                while (commands.TryTake(out var command)) command.Fail(failure ?? new ObjectDisposedException(nameof(VideoWorker)));
                decoder = null;
                stopped.TrySetResult();
            }
        }) { IsBackground = true, Name = name }.Start();
    }

    public Task<PixelBuffer> ReadAsync(double source, bool exact, CancellationToken ct)
    {
        if (ct.IsCancellationRequested) return Task.FromCanceled<PixelBuffer>(ct);
        var command = new OwnerCommand<PixelBuffer>(() =>
        {
            var buffer = decoder!.ReadAt(source, exact, ct);
            Volatile.Write(ref position, decoder.Position);
            return buffer;
        }, ct);
        try
        {
            if (!commands.TryAdd(command)) command.Fail(failure ?? new ObjectDisposedException(nameof(VideoWorker)));
        }
        catch (InvalidOperationException) { command.Fail(failure ?? new ObjectDisposedException(nameof(VideoWorker))); }
        return command.Task;
    }

    public async ValueTask DisposeAsync()
    {
        commands.CompleteAdding();
        await stopped.Task.ConfigureAwait(false);
    }
}
