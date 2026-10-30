using System.Collections.Concurrent;
using System.Runtime.Versioning;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Audio;

/// <summary>One render endpoint per playback. Implementations own their device thread and scratch-file reader.</summary>
public interface IVoiceLabRenderEndpoint : IAsyncDisposable
{
    /// <summary>Null means output is available; otherwise returns a tooltip-ready reason without playing audio.</summary>
    Task<string?> CheckAvailabilityAsync(CancellationToken ct);
    /// <summary>Opens the scratch WAV without playing it.</summary>
    Task OpenAsync(string path, CancellationToken ct);
    /// <summary>Starts the configured take.</summary>
    Task PlayAsync(CancellationToken ct);
    /// <summary>Completes at natural end or device failure.</summary>
    Task Completion { get; }
    /// <summary>Cached device position; no COM call on the reader's thread.</summary>
    TimeSpan Position { get; }
}

/// <summary>Immutable audition state. Changed may be raised off the UI thread; the editor must marshal it.</summary>
public sealed record VoiceLabAuditionState(bool IsPlaying, bool Completed, TimeSpan Position, Guid? TakeId, string? UnavailableReason)
{
    /// <summary>Whether Play is available, including before the first explicit availability refresh.</summary>
    public bool CanPlay => UnavailableReason is null;
}

/// <summary>R11 scratch audition. The editor binds selection, rejection, invalidation and close hooks below.</summary>
public sealed class VoiceLabAudition : IAsyncDisposable
{
    /// <summary>Tooltip when Windows has no default render endpoint.</summary>
    public const string NoOutputDevice = "No audio output device is available. Connect speakers or headphones to play a take.";
    /// <summary>Tooltip for an unavailable or lost render endpoint.</summary>
    public const string OutputUnavailable = "Audio output isn't available. Check your output device and try again.";
    private readonly Func<IVoiceLabRenderEndpoint> createEndpoint;
    private readonly Func<CancellationToken, Task> pausePreview;
    private readonly TimeProvider clock;
    private readonly SemaphoreSlim serial = new(1, 1);
    private readonly object sync = new();
    private Playback? playback;
    private VoiceLabTakeScratch? scratch;
    private string? selectionId;
    private bool disposed;
    private VoiceLabAuditionState state = new(false, false, TimeSpan.Zero, null, null);

    /// <summary>Uses the Windows default shared-mode render endpoint; preview is paused before any playback.</summary>
    public VoiceLabAudition(Func<CancellationToken, Task> pausePreview, TimeProvider? clock = null)
        : this(DefaultEndpoint, pausePreview, clock) { }
    /// <summary>Injects an endpoint and monotonic clock for silent, deterministic tests.</summary>
    public VoiceLabAudition(Func<IVoiceLabRenderEndpoint> createEndpoint, Func<CancellationToken, Task> pausePreview, TimeProvider? clock = null)
    { this.createEndpoint = createEndpoint; this.pausePreview = pausePreview; this.clock = clock ?? TimeProvider.System; }
    private static IVoiceLabRenderEndpoint DefaultEndpoint() => OperatingSystem.IsWindows()
        ? new WasapiAuditionEndpoint() : throw new PlatformNotSupportedException();
    /// <summary>State updates, including clock ticks and natural completion. Marshal to the editor's UI thread.</summary>
    public event EventHandler? Changed;
    /// <summary>Thread-safe state for bindings and the no-output-device tooltip.</summary>
    public VoiceLabAuditionState Snapshot { get { lock (sync) return state; } }
    private void Update(VoiceLabAuditionState value)
    { lock (sync) state = value; Changed?.Invoke(this, EventArgs.Empty); }

    /// <summary>Probes output without rendering sound. Call before enabling Play and after device changes.</summary>
    public async Task<bool> RefreshAvailabilityAsync(CancellationToken ct = default)
    {
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (playback is not null) return Snapshot.CanPlay;
            string? reason;
            try
            {
                await using var endpoint = createEndpoint();
                reason = await endpoint.CheckAvailabilityAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception) { reason = OutputUnavailable; }
            Update(Snapshot with { UnavailableReason = reason });
            return reason is null;
        }
        finally { serial.Release(); }
    }
    /// <summary>Plays mixed scratch audio once, after pausing preview. False exposes an output tooltip.</summary>
    public async Task<bool> PlayAsync(VoiceLabTakeScratch take, Guid takeId, string selection, CancellationToken ct = default)
    {
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            await StopCoreAsync().ConfigureAwait(false);
            if (!take.IsValid) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            scratch = take; selectionId = selection;
            Update(new(false, false, TimeSpan.Zero, takeId, null));
            try
            {
                var current = new Playback(createEndpoint(), CancellationTokenSource.CreateLinkedTokenSource(ct), take);
                playback = current;
                var token = current.Cancellation.Token;
                var reason = await current.Endpoint.CheckAvailabilityAsync(token).ConfigureAwait(false);
                if (reason is not null)
                {
                    await StopCoreAsync().ConfigureAwait(false);
                    Update(Snapshot with { UnavailableReason = reason }); return false;
                }
                current.Lease = take.AttachConsumer(() => StopPlaybackAsync(current, invalidated: true));
                await pausePreview(token).ConfigureAwait(false);
                await current.Endpoint.OpenAsync(take.MixedAudioPath, token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                if (!take.IsValid) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
                await current.Endpoint.PlayAsync(token).ConfigureAwait(false);
                Update(Snapshot with { IsPlaying = true });
                current.Timer = clock.CreateTimer(_ => Tick(current), null, TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(50));
                current.Registration = token.Register(() => _ = StopPlaybackAsync(current));
                _ = ObserveAsync(current);
                return true;
            }
            catch (OperationCanceledException)
            {
                await StopCoreAsync().ConfigureAwait(false);
                if (ct.IsCancellationRequested) throw;
                return false;
            }
            catch (Exception)
            {
                await StopCoreAsync().ConfigureAwait(false);
                Update(Snapshot with { UnavailableReason = OutputUnavailable }); return false;
            }
        }
        finally { serial.Release(); }
    }
    private void Tick(Playback current)
    {
        lock (sync)
        {
            if (playback != current || !state.IsPlaying) return;
            state = state with { Position = current.Endpoint.Position };
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }
    private async Task ObserveAsync(Playback current)
    {
        var failed = false;
        try { await current.Endpoint.Completion.ConfigureAwait(false); }
        catch (Exception) { failed = true; }
        await serial.WaitAsync().ConfigureAwait(false);
        try
        {
            if (playback != current) return;
            var position = current.Endpoint.Position;
            await StopCoreAsync().ConfigureAwait(false);
            Update(Snapshot with { Completed = !failed, Position = position, UnavailableReason = failed ? OutputUnavailable : null });
        }
        finally { serial.Release(); }
    }
    private async Task StopPlaybackAsync(Playback current, bool invalidated = false)
    {
        current.Cancel();
        await serial.WaitAsync().ConfigureAwait(false);
        try
        {
            if (playback == current) await StopCoreAsync().ConfigureAwait(false);
            if (invalidated && ReferenceEquals(scratch, current.Scratch)) { scratch = null; Update(Snapshot with { TakeId = null }); }
        }
        finally { serial.Release(); }
    }
    private async Task StopCoreAsync()
    {
        var current = playback; playback = null;
        if (current is not null)
        {
            current.Cancel(); current.Timer?.Dispose(); current.Lease?.Dispose(); current.Registration.Dispose();
            try { await current.Endpoint.DisposeAsync().ConfigureAwait(false); }
            catch (Exception) { Update(Snapshot with { UnavailableReason = OutputUnavailable }); }
            finally { current.Cancellation.Dispose(); }
        }
        Update(Snapshot with { IsPlaying = false, Completed = false, Position = TimeSpan.Zero });
    }
    /// <summary>Stops playback (also the Play/Pause button's pause action) without invalidating the take.</summary>
    public async Task StopAsync()
    {
        Volatile.Read(ref playback)?.Cancel();
        await serial.WaitAsync().ConfigureAwait(false);
        try { await StopCoreAsync().ConfigureAwait(false); }
        finally { serial.Release(); }
    }
    /// <summary>Bind when the selected take changes. Selecting the same take does not interrupt it.</summary>
    public Task TakeChangedAsync(Guid? takeId) => ChangeAsync(takeId, null, false);
    /// <summary>Bind when the transcript/window selection changes, before invalidating its takes.</summary>
    public Task SelectionChangedAsync(string? selection) => ChangeAsync(null, selection, true);
    private async Task ChangeAsync(Guid? takeId, string? selection, bool selectionChanged)
    {
        if (selectionChanged ? selectionId == selection : Snapshot.TakeId == takeId) return;
        Volatile.Read(ref playback)?.Cancel();
        await serial.WaitAsync().ConfigureAwait(false);
        try
        {
            if (selectionChanged ? selectionId == selection : Snapshot.TakeId == takeId) return;
            await StopCoreAsync().ConfigureAwait(false);
            scratch = null; selectionId = selection; Update(Snapshot with { TakeId = null });
        }
        finally { serial.Release(); }
    }
    /// <summary>Stops and invalidates the auditioned take when it is rejected. Other rows do not interrupt it.</summary>
    public async Task RejectAsync(Guid takeId)
    {
        if (Snapshot.TakeId != takeId) return;
        Volatile.Read(ref playback)?.Cancel();
        await serial.WaitAsync().ConfigureAwait(false);
        VoiceLabTakeScratch? rejected;
        try
        {
            if (Snapshot.TakeId != takeId) return;
            rejected = scratch; scratch = null;
            await StopCoreAsync().ConfigureAwait(false); Update(Snapshot with { TakeId = null });
        }
        finally { serial.Release(); }
        if (rejected is not null) await rejected.InvalidateAsync().ConfigureAwait(false);
    }
    /// <summary>Bind to panel close/invalidation. Stops the endpoint before invalidating its scratch lease.</summary>
    public async Task EndSessionAsync()
    {
        Volatile.Read(ref playback)?.Cancel();
        await serial.WaitAsync().ConfigureAwait(false);
        VoiceLabTakeScratch? previous;
        try
        {
            previous = scratch; scratch = null; selectionId = null;
            await StopCoreAsync().ConfigureAwait(false); Update(Snapshot with { TakeId = null });
        }
        finally { serial.Release(); }
        if (previous is not null) await previous.InvalidateAsync().ConfigureAwait(false);
    }
    /// <summary>Bind to a stale/invalidated generation run, before replacing its take rows.</summary>
    public Task InvalidateAsync() => EndSessionAsync();
    /// <summary>Closes once; endpoint teardown and file release are safe after any earlier stop hook.</summary>
    public async ValueTask DisposeAsync()
    {
        Volatile.Read(ref playback)?.Cancel();
        await serial.WaitAsync().ConfigureAwait(false);
        VoiceLabTakeScratch? previous;
        try
        {
            if (disposed) return;
            disposed = true; previous = scratch; scratch = null; selectionId = null;
            await StopCoreAsync().ConfigureAwait(false); Update(Snapshot with { TakeId = null });
        }
        finally { serial.Release(); }
        if (previous is not null) await previous.InvalidateAsync().ConfigureAwait(false);
    }
    private sealed class Playback(IVoiceLabRenderEndpoint endpoint, CancellationTokenSource cancellation, VoiceLabTakeScratch take)
    {
        internal IVoiceLabRenderEndpoint Endpoint { get; } = endpoint;
        internal CancellationTokenSource Cancellation { get; } = cancellation;
        internal VoiceLabTakeScratch Scratch { get; } = take;
        internal IDisposable? Lease;
        internal ITimer? Timer;
        internal CancellationTokenRegistration Registration;
        internal void Cancel() { try { Cancellation.Cancel(); } catch (ObjectDisposedException) { } }
    }
}

[SupportedOSPlatform("windows")]
internal sealed class WasapiAuditionEndpoint : IVoiceLabRenderEndpoint
{
    private readonly BlockingCollection<OwnerCommand<bool>> commands = new();
    private readonly TaskCompletionSource finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private IWasapiOutput? output;
    private WaveFileReader? reader;
    private long positionTicks;
    private int disposed;
    internal WasapiAuditionEndpoint()
    {
        var owner = new Thread(Own) { IsBackground = true, Name = "vc-audition" };
        owner.SetApartmentState(ApartmentState.MTA); owner.Start();
    }
    public Task Completion => finished.Task;
    public TimeSpan Position => TimeSpan.FromTicks(Interlocked.Read(ref positionTicks));
    public async Task<string?> CheckAvailabilityAsync(CancellationToken ct)
    {
        string? reason = null;
        await Invoke(() =>
        {
            try
            {
                using var devices = new MMDeviceEnumerator();
                using var device = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            }
            catch (Exception error) { reason = IPreviewAudioOutput.Unavailable(error) == Core.Services.Media.PreviewAudioStatus.NoOutputDevice ? VoiceLabAudition.NoOutputDevice : VoiceLabAudition.OutputUnavailable; }
        }, ct).ConfigureAwait(false);
        return reason;
    }
    public Task OpenAsync(string path, CancellationToken ct) => Invoke(() =>
    {
        reader = new WaveFileReader(path); output = new SharedWasapiOutput();
        output.PlaybackStopped += (_, args) => { if (args.Exception is { } error) finished.TrySetException(error); else finished.TrySetResult(); };
        output.Init(reader);
    }, ct);
    public Task PlayAsync(CancellationToken ct) => Invoke(() => output!.Play(), ct);
    private Task Invoke(Action action, CancellationToken ct)
    {
        var command = new OwnerCommand<bool>(() => { action(); return true; }, ct);
        try { if (!commands.TryAdd(command)) command.Fail(new ObjectDisposedException(nameof(WasapiAuditionEndpoint))); }
        catch (InvalidOperationException) { command.Fail(new ObjectDisposedException(nameof(WasapiAuditionEndpoint))); }
        return command.Task;
    }
    private void Own()
    {
        try
        {
            while (!commands.IsCompleted)
            {
                if (commands.TryTake(out var command, 10)) command.Execute();
                if (output is not null)
                    Interlocked.Exchange(ref positionTicks, (long)(output.GetPosition() / (double)output.OutputWaveFormat.AverageBytesPerSecond * TimeSpan.TicksPerSecond));
            }
        }
        catch (Exception error) { finished.TrySetException(error); }
        finally
        {
            commands.CompleteAdding();
            while (commands.TryTake(out var command)) command.Fail(new ObjectDisposedException(nameof(WasapiAuditionEndpoint)));
            try { try { output?.Stop(); } finally { try { output?.Dispose(); } finally { reader?.Dispose(); } } }
            catch (Exception error) { finished.TrySetException(error); }
            finally { finished.TrySetResult(); stopped.TrySetResult(); }
        }
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0) commands.CompleteAdding();
        await stopped.Task.ConfigureAwait(false);
    }
}
