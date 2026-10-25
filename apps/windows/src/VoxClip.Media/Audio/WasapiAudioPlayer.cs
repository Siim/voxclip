using System.Runtime.Versioning;
using System.Collections.Concurrent;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using VoxClip.Media.Ffmpeg;
namespace VoxClip.Media.Audio;

/// <summary>Event-driven shared-mode WASAPI with a device clock; architecture §6.3.</summary>
[SupportedOSPlatform("windows")]
public sealed class WasapiAudioPlayer : IAsyncDisposable
{
    private readonly BlockingCollection<OwnerCommand<bool>> commands = new();
    private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Thread owner;
    private WasapiPlayer? output;
    private AudioRing? ring;
    private long framesPlayed;
    private int rate = 48_000;
    private volatile bool disposed;
    private Exception? failure;
    /// <summary>Create an idle device owner; initialization remains explicit.</summary>
    public WasapiAudioPlayer()
    {
        owner = new Thread(Own) { Name = "vc-wasapi", IsBackground = true };
        owner.Start();
    }
    /// <summary>Device frame clock, not wall-clock or video PTS; architecture §6.3.</summary>
    public long FramesPlayed => Interlocked.Read(ref framesPlayed);
    /// <summary>Initialize and start the event-driven device on its dedicated owner thread.</summary>
    public Task StartAsync(int sampleRate, int channels, CancellationToken ct) => ConfigureAsync(sampleRate, channels, true, ct);
    internal int DeviceRate => Volatile.Read(ref rate);
    internal int BufferedBytes => ring?.BufferedBytes ?? 0;
    internal Task Completion => stopped.Task;
    internal int Write(ReadOnlySpan<byte> bytes) => ring?.Write(bytes) ?? 0;
    internal Task ConfigureAsync(int sampleRate, int channels, bool play, CancellationToken ct) => Invoke(() =>
    {
        output?.Dispose();
        ring = new(sampleRate, channels, sampleRate * channels * sizeof(float) * 4);
        output = new WasapiPlayerBuilder().WithSharedMode().WithEventSync().WithLatency(40).Build();
        output.Init(ring);
        rate = output.OutputWaveFormat.SampleRate;
        Interlocked.Exchange(ref framesPlayed, 0);
        if (play) output.Play();
    }, ct);
    internal Task PlayAsync(CancellationToken ct) => Invoke(() => output?.Play(), ct);
    internal Task PauseAsync(CancellationToken ct) => Invoke(() => output?.Pause(), ct);

    private Task Invoke(Action action, CancellationToken ct)
    {
        if (ct.IsCancellationRequested) return Task.FromCanceled(ct);
        if (Volatile.Read(ref failure) is { } exception) return Task.FromException(exception);
        if (disposed) return Task.FromException(new ObjectDisposedException(nameof(WasapiAudioPlayer)));
        var command = new OwnerCommand<bool>(() =>
        {
            action(); return true;
        }, ct);
        try
        {
            if (!commands.TryAdd(command)) command.Fail(failure ?? new ObjectDisposedException(nameof(WasapiAudioPlayer)));
        }
        catch (InvalidOperationException) { command.Fail(failure ?? new ObjectDisposedException(nameof(WasapiAudioPlayer))); }
        return command.Task;
    }

    private void Own()
    {
        try
        {
            while (!commands.IsCompleted)
            {
                if (commands.TryTake(out var command, 5)) command.Execute();
                if (output is not null)
                    Interlocked.Exchange(ref framesPlayed, output.GetPosition() / output.OutputWaveFormat.BlockAlign);
            }
        }
        catch (Exception exception) { Volatile.Write(ref failure, exception); }
        finally
        {
            commands.CompleteAdding();
            while (commands.TryTake(out var command)) command.Fail(failure ?? new ObjectDisposedException(nameof(WasapiAudioPlayer)));
            try { try { output?.Stop(); } finally { output?.Dispose(); } }
            catch (Exception exception) { failure ??= exception; }
            if (failure is not null) stopped.TrySetException(failure);
            else stopped.TrySetResult();
        }
    }
    /// <summary>Release on the owner thread; safe before initialization.</summary>
    public async ValueTask DisposeAsync()
    {
        if (!disposed) { disposed = true; commands.CompleteAdding(); }
        await stopped.Task.ConfigureAwait(false);
    }
}

internal sealed class AudioRing : IWaveProvider
{
    private readonly byte[] buffer;
    private long read;
    private long written;
    public WaveFormat WaveFormat { get; }
    internal int BufferedBytes => (int)(Volatile.Read(ref written) - Volatile.Read(ref read));
    internal AudioRing(int sampleRate, int channels, int capacity)
    { WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, channels); buffer = new byte[capacity]; }

    internal int Write(ReadOnlySpan<byte> source)
    {
        var writePosition = written;
        var available = (int)Math.Min(source.Length, buffer.Length - (writePosition - Volatile.Read(ref read)));
        var start = (int)(writePosition % buffer.Length);
        var first = Math.Min(available, buffer.Length - start);
        source[..first].CopyTo(buffer.AsSpan(start));
        source.Slice(first, available - first).CopyTo(buffer);
        Volatile.Write(ref written, writePosition + available);
        return available;
    }

    public int Read(byte[] target, int offset, int count) => Read(target.AsSpan(offset, count));

    public int Read(Span<byte> target)
    {
        var count = target.Length;
        var readPosition = read;
        var available = (int)Math.Min(count, Volatile.Read(ref written) - readPosition);
        var start = (int)(readPosition % buffer.Length);
        var first = Math.Min(available, buffer.Length - start);
        buffer.AsSpan(start, first).CopyTo(target);
        buffer.AsSpan(0, available - first).CopyTo(target[first..]);
        target.Slice(available, count - available).Clear();
        Volatile.Write(ref read, readPosition + available);
        return count;
    }
}
