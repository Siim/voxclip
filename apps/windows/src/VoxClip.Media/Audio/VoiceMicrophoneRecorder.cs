using System.Buffers.Binary;
using System.Globalization;
using VoxClip.Core.Services.Logging;

namespace VoxClip.Media.Audio;

/// <summary>Actionable input failures; no endpoint names or samples are diagnostic data.</summary>
public enum MicrophoneError
{
    /// <summary>Windows denied microphone access.</summary>
    Permission,
    /// <summary>No Console-role capture endpoint exists.</summary>
    NoDevice,
    /// <summary>The endpoint cannot be activated or used.</summary>
    Unavailable,
    /// <summary>The bound endpoint stopped providing audio; the take was discarded.</summary>
    DeviceLost,
    /// <summary>The endpoint provided only exact zero or SILENT packets.</summary>
    Silent
}

/// <summary>Device-rate mono samples, owned by the take until discarded.</summary>
public sealed record MicrophoneTake(float[] Mono, int Rate);

/// <summary>UI polling state; DeviceName is display-only and must never be logged.</summary>
public sealed record MicrophoneSnapshot(bool Recording, bool Activating, double Seconds, double Level,
    MicrophoneError? Failure, string? DeviceName);

/// <summary>Typed capture failure without the underlying exception's potentially identifying message.</summary>
public sealed class MicrophoneException(MicrophoneError error, int hresult = 0) : Exception(error.ToString())
{
    /// <summary>The actionable failure.</summary>
    public MicrophoneError Error { get; } = error;
    internal int NativeHResult { get; } = hresult;
}

internal enum MicrophoneSampleKind { Float32, Pcm16, Pcm24, Pcm32 }
internal delegate void MicrophonePacket(ReadOnlySpan<byte> data, bool silent);
internal interface IMicrophoneEndpoint : IDisposable
{
    int Rate { get; }
    int Channels { get; }
    MicrophoneSampleKind Kind { get; }
    string Name { get; }
    void Start(MicrophonePacket packet, Action<Exception?> stopped);
    void Stop();
}

/// <summary>Memory-only capture with a dedicated COM owner, bounded storage and monotonic safety clocks.</summary>
public sealed class VoiceMicrophoneRecorder : IAsyncDisposable
{
    private readonly object sync = new();
    private readonly Func<CancellationToken, IMicrophoneEndpoint> open;
    private readonly TimeProvider clock;
    private readonly ILog? log;
    private Session? session;
    private bool disposed;

    /// <summary>Resolve the Console-role capture endpoint afresh for every take.</summary>
    public VoiceMicrophoneRecorder(ILog? log = null) : this(OpenDefault, TimeProvider.System, log) { }

    internal VoiceMicrophoneRecorder(Func<CancellationToken, IMicrophoneEndpoint> open, TimeProvider clock, ILog? log = null)
    { this.open = open; this.clock = clock; this.log = log; }

    private static IMicrophoneEndpoint OpenDefault(CancellationToken ct)
    {
#if DEBUG
        if (DebugMicrophoneEndpoint.FromEnvironment(ct) is { } endpoint) return endpoint;
#endif
        if (!OperatingSystem.IsWindows()) throw new MicrophoneException(MicrophoneError.Unavailable);
        return MicrophoneDevices.OpenDefault(ct);
    }

    /// <summary>Activation has no timeout. Cancellation promptly completes the caller and discards eventual input.</summary>
    public Task StartAsync(int maximumSeconds, CancellationToken ct = default)
    {
        if (maximumSeconds is not (30 or 90)) throw new ArgumentOutOfRangeException(nameof(maximumSeconds));
        ct.ThrowIfCancellationRequested();
        lock (sync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (session is { } previous && !previous.Done.Task.IsCompleted)
                throw new InvalidOperationException("The microphone is already active.");
            session?.Clear();
            var next = new Session(maximumSeconds, clock.GetTimestamp(), ct);
            session = next;
            next.Cancellation = ct.Register(() => Cancel(next));
            next.Timer = clock.CreateTimer(_ => Tick(next), null, TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(100));
            var owner = new Thread(() => Run(next)) { IsBackground = true, Name = "vc-mic" };
            if (OperatingSystem.IsWindows()) owner.SetApartmentState(ApartmentState.MTA);
            owner.Start();
            return next.Started.Task;
        }
    }

    /// <summary>Completes after the endpoint has been stopped and disposed on its owner thread.</summary>
    public Task Completion { get { lock (sync) return session?.Done.Task ?? Task.CompletedTask; } }

    /// <summary>Poll from the UI without making a COM call.</summary>
    public MicrophoneSnapshot Snapshot()
    {
        lock (sync)
        {
            if (session is not { } current) return new(false, false, 0, 0, null, null);
            return new(current.Recording && !current.Starting, !current.Ending && current.Starting &&
                clock.GetElapsedTime(current.Activation).TotalSeconds >= 1,
                current.Rate == 0 ? 0 : (double)current.Count / current.Rate,
                current.Recording ? current.Level : 0, current.Failure, current.Name);
        }
    }

    /// <summary>Freeze the take immediately; Completion observes asynchronous owner-thread teardown.</summary>
    public MicrophoneTake Stop()
    {
        lock (sync)
        {
            if (session is not { } current) return new([], 0);
            Finish(current, false);
            return current.Take ?? new([], current.Rate);
        }
    }

    /// <summary>Best-effort zero all retained samples, including an already returned take.</summary>
    public void Discard()
    {
        lock (sync) if (session is { } current) { Finish(current, true); current.Clear(); }
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        Task completion;
        lock (sync)
        {
            disposed = true;
            Discard();
            completion = session?.Done.Task ?? Task.CompletedTask;
        }
        await completion.ConfigureAwait(false);
    }

    internal static MicrophoneError MapError(int hresult, bool recording) => unchecked((uint)hresult) switch
    {
        0x80070005 => MicrophoneError.Permission,
        0x80070490 => MicrophoneError.NoDevice,
        0x88890004 or 0x88890026 => recording ? MicrophoneError.DeviceLost : MicrophoneError.Unavailable,
        _ => MicrophoneError.Unavailable
    };

    private void Run(Session current)
    {
        IMicrophoneEndpoint? endpoint = null;
        try
        {
            lock (sync) if (current.Ending) return;
            endpoint = open(current.Token);
            lock (sync)
            {
                if (current.Ending) return;
                if (endpoint.Rate is < 8000 or > 384000 || endpoint.Channels is < 1 or > 32)
                    throw new MicrophoneException(MicrophoneError.Unavailable);
                current.Rate = endpoint.Rate; current.Channels = endpoint.Channels; current.Kind = endpoint.Kind;
                current.Name = endpoint.Name;
                current.Buffer = new float[checked(current.MaximumSeconds * current.Rate)];
                current.Progress = current.Begin = clock.GetTimestamp();
                current.Recording = true;
            }
            endpoint.Start((data, silent) => Append(current, data, silent), exception => EndpointStopped(current, exception));
            lock (sync)
            {
                current.Starting = false;
                current.Progress = current.Begin = clock.GetTimestamp();
                if (!current.Ending) current.Started.TrySetResult();
                else if (current.Failure is { } error) current.Started.TrySetException(new MicrophoneException(error));
            }
            current.End.Wait();
        }
        catch (OperationCanceledException) when (current.Token.IsCancellationRequested) { Cancel(current); }
        catch (Exception exception) { EndpointStopped(current, exception); }
        finally
        {
            try { endpoint?.Stop(); }
            catch (Exception exception) { EndpointStopped(current, exception); }
            try { endpoint?.Dispose(); }
            catch (Exception exception) { EndpointStopped(current, exception); }
            current.Timer?.Dispose();
            current.Cancellation.Dispose();
            lock (sync)
            {
                Finish(current, false);
                Array.Clear(current.Buffer);
                current.Started.TrySetCanceled(new CancellationToken(true));
            }
            WriteLog(current);
            current.End.Dispose();
            try { Stopped?.Invoke(this, EventArgs.Empty); }
            catch (Exception) { }
            finally { current.Done.TrySetResult(); }
        }
    }

    /// <summary>Raised after teardown, on the owner thread. Callers marshal UI work themselves.</summary>
    public event EventHandler? Stopped;

    private void Cancel(Session current)
    {
        lock (sync)
        {
            current.Started.TrySetCanceled(current.Token.IsCancellationRequested ? current.Token : new CancellationToken(true));
            Finish(current, true);
        }
    }

    private void EndpointStopped(Session current, Exception? exception)
    {
        lock (sync)
        {
            if (current.Ending) return;
            var error = exception is MicrophoneException known ? known.Error : exception is null
                ? MicrophoneError.DeviceLost : MapError(exception.HResult, current.Recording && !current.Starting);
            current.HResult = exception is MicrophoneException native ? native.NativeHResult : exception?.HResult ?? 0;
            current.Failure = error;
            Finish(current, true);
            current.Started.TrySetException(new MicrophoneException(error, current.HResult));
        }
    }

    private void Tick(Session current)
    {
        lock (sync)
        {
            if (!current.Recording || current.Starting || current.Ending) return;
            var now = clock.GetTimestamp();
            if (clock.GetElapsedTime(current.Begin, now).TotalSeconds >= current.MaximumSeconds) Finish(current, false);
            else if (clock.GetElapsedTime(current.Progress, now).TotalSeconds >= 1.5)
            { current.Failure = MicrophoneError.DeviceLost; Finish(current, true); }
        }
    }

    private void Append(Session current, ReadOnlySpan<byte> data, bool silent)
    {
        lock (sync)
        {
            if (!current.Recording || current.Ending) return;
            var width = current.Kind == MicrophoneSampleKind.Pcm16 ? 2 : current.Kind == MicrophoneSampleKind.Pcm24 ? 3 : 4;
            var stride = width * current.Channels;
            if (data.Length % stride != 0) { current.Failure = MicrophoneError.Unavailable; Finish(current, true); return; }
            var frames = Math.Min(data.Length / stride, current.Buffer.Length - current.Count);
            for (var frame = 0; frame < frames; frame++)
            {
                double sum = 0;
                var digitalZero = true;
                if (!silent)
                    for (var channel = 0; channel < current.Channels; channel++)
                    {
                        var sample = Sample(data.Slice(frame * stride + channel * width, width), current.Kind);
                        sum += sample;
                        digitalZero &= sample == 0;
                    }
                var mono = (float)(sum / current.Channels);
                if (!float.IsFinite(mono)) { current.Failure = MicrophoneError.Unavailable; Finish(current, true); return; }
                current.Buffer[current.Count++] = mono;
                current.ZeroFrames = silent || digitalZero ? current.ZeroFrames + 1 : 0;
                if (!silent && !digitalZero) current.Nonzero = true;
                if (current.ZeroFrames >= 2 * current.Rate)
                { current.Failure = MicrophoneError.Silent; Finish(current, true); return; }
            }
            if (frames == 0) return;
            current.Progress = clock.GetTimestamp();
            double squares = 0;
            var first = Math.Max(0, current.Count - 1024);
            for (var frame = first; frame < current.Count; frame++) squares += (double)current.Buffer[frame] * current.Buffer[frame];
            current.Level = Math.Min(1, Math.Sqrt(squares / (current.Count - first)) * 5);
            if (current.Count == current.Buffer.Length) Finish(current, false);
        }
    }

    private static float Sample(ReadOnlySpan<byte> bytes, MicrophoneSampleKind kind) => kind switch
    {
        MicrophoneSampleKind.Float32 => BinaryPrimitives.ReadSingleLittleEndian(bytes),
        MicrophoneSampleKind.Pcm16 => BinaryPrimitives.ReadInt16LittleEndian(bytes) / 32768f,
        MicrophoneSampleKind.Pcm24 => ((bytes[0] << 8 | bytes[1] << 16 | bytes[2] << 24) >> 8) / 8388608f,
        _ => (float)(BinaryPrimitives.ReadInt32LittleEndian(bytes) / 2147483648.0)
    };

    private static void Finish(Session current, bool discard)
    {
        if (!current.Ending)
        {
            current.Ending = true; current.Recording = false;
            if (!discard && !current.Nonzero && current.Count > 0) current.Failure = MicrophoneError.Silent;
            if (!discard && current.Failure is null) current.Take = new(current.Buffer.AsSpan(0, current.Count).ToArray(), current.Rate);
            else { current.Clear(); current.Take = new([], current.Rate); }
            if (current.Failure is { } failure) current.Started.TrySetException(new MicrophoneException(failure, current.HResult));
            else if (current.Count > 0) current.Started.TrySetResult();
            else current.Started.TrySetCanceled(new CancellationToken(true));
            current.End.Set();
        }
        if (discard) current.Clear();
    }

    private void WriteLog(Session current)
    {
        try
        {
            log?.Write(current.Failure is null ? LogLevel.Info : LogLevel.Warn, "microphone",
                string.Create(CultureInfo.InvariantCulture, $"hresult=0x{current.HResult:X8} kind={current.Failure?.ToString() ?? "Stopped"} rate={current.Rate} channels={current.Channels} activationMs={clock.GetElapsedTime(current.Activation, current.Starting ? clock.GetTimestamp() : current.Begin).TotalMilliseconds:F0} elapsedMs={clock.GetElapsedTime(current.Activation).TotalMilliseconds:F0}"));
        }
        catch (Exception) { }
    }

    private sealed class Session(int maximumSeconds, long activation, CancellationToken token)
    {
        internal readonly int MaximumSeconds = maximumSeconds;
        internal readonly long Activation = activation;
        internal readonly CancellationToken Token = token;
        internal readonly TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource Done = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly ManualResetEventSlim End = new(false);
        internal CancellationTokenRegistration Cancellation;
        internal ITimer? Timer;
        internal float[] Buffer = [];
        internal MicrophoneTake? Take;
        internal string? Name;
        internal MicrophoneError? Failure;
        internal MicrophoneSampleKind Kind;
        internal int Rate, Channels, Count, ZeroFrames, HResult;
        internal long Begin, Progress;
        internal double Level;
        internal bool Starting = true;
        internal bool Recording, Ending, Nonzero;
        internal void Clear() { Array.Clear(Buffer); if (Take is not null) Array.Clear(Take.Mono); Take = null; Count = 0; Level = 0; }
    }
}
