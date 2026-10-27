using System.Runtime.Versioning;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Ffmpeg;
namespace VoxClip.Media.Audio;

/// <summary>Device-clocked preview output; WASAPI in production, fakes in portable tests.</summary>
internal interface IPreviewAudioOutput : IAsyncDisposable
{
    long FramesPlayed { get; }
    int DeviceRate { get; }
    int BufferedBytes { get; }
    Task Completion { get; }
    int Write(ReadOnlySpan<byte> bytes);
    Task ConfigureAsync(int sampleRate, int channels, bool play, CancellationToken ct);
    Task PlayAsync(CancellationToken ct);
    Task PauseAsync(CancellationToken ct);

    /// <summary>The status for errors after which preview continues without sound: another app holding the endpoint exclusively
    /// (AUDCLNT_E_DEVICE_IN_USE), no default render endpoint (E_NOTFOUND), endpoint removed (AUDCLNT_E_DEVICE_INVALIDATED,
    /// AUDCLNT_E_RESOURCES_INVALIDATED), endpoint creation failed or the audio service stopped. Null for errors that still fail preview.</summary>
    static PreviewAudioStatus? Unavailable(Exception exception) => (exception as COMException)?.HResult switch
    {
        unchecked((int)0x8889000A) => PreviewAudioStatus.OutputInUse,
        unchecked((int)0x80070490) or unchecked((int)0x88890004) or unchecked((int)0x88890026) or
            unchecked((int)0x8889000F) or unchecked((int)0x88890010) => PreviewAudioStatus.NoOutputDevice,
        _ => null,
    };
}

/// <summary>The NAudio render stream the player drives; WasapiPlayer in production, fakes in portable tests.</summary>
internal interface IWasapiOutput : IDisposable
{
    event EventHandler<StoppedEventArgs> PlaybackStopped;
    WaveFormat OutputWaveFormat { get; }
    void Init(IWaveProvider source);
    void Play();
    void Pause();
    void Stop();
    long GetPosition();
}

/// <summary>Event-driven shared-mode WASAPI on the default render endpoint.</summary>
[SupportedOSPlatform("windows")]
internal sealed class SharedWasapiOutput : IWasapiOutput
{
    private readonly WasapiPlayer player = new WasapiPlayerBuilder().WithSharedMode().WithEventSync().WithLatency(40).Build();
    public event EventHandler<StoppedEventArgs> PlaybackStopped
    {
        add => player.PlaybackStopped += value;
        remove => player.PlaybackStopped -= value;
    }
    public WaveFormat OutputWaveFormat => player.OutputWaveFormat;
    public void Init(IWaveProvider source) => player.Init(source);
    public void Play() => player.Play();
    public void Pause() => player.Pause();
    public void Stop() => player.Stop();
    public long GetPosition() => player.GetPosition();
    public void Dispose() => player.Dispose();
}

/// <summary>Event-driven shared-mode WASAPI with a device clock; architecture §6.3.</summary>
[SupportedOSPlatform("windows")]
public sealed class WasapiAudioPlayer : IAsyncDisposable, IPreviewAudioOutput
{
    private readonly BlockingCollection<OwnerCommand<bool>> commands = new();
    private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Func<IWasapiOutput> createOutput;
    private readonly Thread owner;
    private IWasapiOutput? output;
    private AudioRing? ring;
    private long framesPlayed;
    private int rate = 48_000;
    private volatile bool disposed;
    private Exception? failure;
    private Exception? lost;
    /// <summary>Create an idle device owner; initialization remains explicit.</summary>
    public WasapiAudioPlayer() : this(() => new SharedWasapiOutput()) { }

    internal WasapiAudioPlayer(Func<IWasapiOutput> createOutput)
    {
        this.createOutput = createOutput;
        owner = new Thread(Own) { Name = "vc-wasapi", IsBackground = true };
        owner.Start();
    }
    /// <summary>Device frame clock, not wall-clock or video PTS; architecture §6.3.</summary>
    public long FramesPlayed => Interlocked.Read(ref framesPlayed);
    /// <summary>Initialize and start the event-driven device on its dedicated owner thread.</summary>
    public Task StartAsync(int sampleRate, int channels, CancellationToken ct) => ConfigureAsync(sampleRate, channels, true, ct);
    int IPreviewAudioOutput.DeviceRate => Volatile.Read(ref rate);
    int IPreviewAudioOutput.BufferedBytes => ring?.BufferedBytes ?? 0;
    Task IPreviewAudioOutput.Completion => stopped.Task;
    int IPreviewAudioOutput.Write(ReadOnlySpan<byte> bytes) => ring?.Write(bytes) ?? 0;
    Task IPreviewAudioOutput.ConfigureAsync(int sampleRate, int channels, bool play, CancellationToken ct) => ConfigureAsync(sampleRate, channels, play, ct);
    Task IPreviewAudioOutput.PlayAsync(CancellationToken ct) => Invoke(() => output?.Play(), ct);
    Task IPreviewAudioOutput.PauseAsync(CancellationToken ct) => Invoke(() => output?.Pause(), ct);
    private Task ConfigureAsync(int sampleRate, int channels, bool play, CancellationToken ct) => Invoke(() =>
    {
        output?.Dispose();
        ring = new(sampleRate, channels, sampleRate * channels * sizeof(float) * 4);
        output = createOutput();
        // A removed device ends NAudio's render thread, which reports the error here; GetPosition then reads 0 instead of throwing.
        output.PlaybackStopped += (_, args) => { if (args.Exception is { } exception) Interlocked.CompareExchange(ref lost, exception, null); };
        output.Init(ring);
        rate = output.OutputWaveFormat.SampleRate;
        Interlocked.Exchange(ref framesPlayed, 0);
        if (play) output.Play();
    }, ct);

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
                if (Volatile.Read(ref lost) is { } exception) { Volatile.Write(ref failure, exception); break; }
                if (output is null) continue;
                // One configured stream only moves forward, so the last played frame survives a stopped render thread.
                var played = output.GetPosition() / output.OutputWaveFormat.BlockAlign;
                if (played > Interlocked.Read(ref framesPlayed)) Interlocked.Exchange(ref framesPlayed, played);
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
