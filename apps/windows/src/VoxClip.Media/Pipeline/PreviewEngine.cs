using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Media.Pipeline;

/// <summary>Audio-master edited playback with two owner-thread video decoders; architecture §6.3.</summary>
public sealed class PreviewEngine : IPreviewEngine
{
    private readonly BlockingCollection<OwnerCommand<bool>> commands = new();
    private readonly Channel<PreviewFrame> frames = CreateFrames();
    private static Channel<PreviewFrame> CreateFrames() => Channel.CreateBounded<PreviewFrame>(new BoundedChannelOptions(6)
        { SingleWriter = true, SingleReader = false, FullMode = BoundedChannelFullMode.DropOldest });
    private readonly Channel<PreviewFrameLease> leases = CreateLeases();
    private static Channel<PreviewFrameLease> CreateLeases() => Channel.CreateBounded<PreviewFrameLease>(new BoundedChannelOptions(6)
        { SingleWriter = true, SingleReader = false, FullMode = BoundedChannelFullMode.DropOldest }, dropped => dropped.Dispose());
    private readonly bool useFrameLeases;
    private PreviewFramePool? framePool;
    private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly IFrameComposer composer;
    private readonly Action<CancellationToken> initialize;
    private readonly Func<string, string, IPreviewVideoWorker> createWorker;
    private readonly Func<double>? clockOverride;
    private Exception? terminalFailure;
    private Exception? playbackFailure;
    private readonly Stopwatch videoClock = new();
    private ComposeSnapshot? snapshot;
    private VoiceLabRenderSession? voiceSession;
    private PreviewPosition position = new(0, 0, false);
    private IPreviewVideoWorker? current;
    private IPreviewVideoWorker? lookAhead;
    private Task<PixelBuffer>? prepared;
    private int preparedPart = -1;
    private CancellationTokenSource? prefetchCancellation;
    private TimelineCursor? cursor;
    private WasapiAudioPlayer? audio;
    private CancellationTokenSource? audioCancellation;
    private Task? audioProducer;
    private long generation;
    private long seekRequest;
    private double origin;
    private double nextFrame;
    private int currentPart;
    private bool playing;
    private volatile bool disposed;

    /// <summary>Create an idle preview without opening media or an audio device.</summary>
    public PreviewEngine() : this(new FrameComposer()) { }
    /// <summary>Opt in to eight pooled buffers and consume ReadFrameLeasesAsync instead of the caller-owned frame stream.</summary>
    public PreviewEngine(bool useFrameLeases) : this(new FrameComposer(), useFrameLeases) { }
    internal PreviewEngine(IFrameComposer composer, bool useFrameLeases = false,
        Action<CancellationToken>? initialize = null, Func<string, string, IPreviewVideoWorker>? createWorker = null,
        Func<double>? clockOverride = null)
    {
        this.composer = composer;
        this.useFrameLeases = useFrameLeases;
        this.initialize = initialize ?? (ct => FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult());
        this.createWorker = createWorker ?? ((path, name) => new VideoWorker(path, name));
        this.clockOverride = clockOverride;
        new Thread(Own) { Name = "vc-preview", IsBackground = true }.Start();
    }
    /// <inheritdoc />
    public PreviewPosition Position => Volatile.Read(ref position);
    /// <inheritdoc />
    public event EventHandler<Exception>? PlaybackFaulted;
    /// <inheritdoc />
    public Task LoadAsync(ComposeSnapshot snapshot, IProgress<MediaProgress>? progress, CancellationToken ct)
    {
        snapshot = snapshot.VoiceLab?.CaptureSnapshot(snapshot) ?? snapshot;
        return Invoke(() =>
    {
        StopMedia();
        playbackFailure = null;
        this.snapshot = null;
        try
        {
            initialize(ct);
            voiceSession = VoiceLabRenderSession.PrepareAsync(snapshot, ct).GetAwaiter().GetResult();
            this.snapshot = CapPreview(snapshot);
            if (composer is FrameComposer concrete) concrete.PrepareDisclosure(this.snapshot);
            current = createWorker(snapshot.Media.Path, "vc-dec-a"); lookAhead = createWorker(snapshot.Media.Path, "vc-dec-b");
            Task.WhenAll(current.Ready, lookAhead.Ready).WaitAsync(ct).GetAwaiter().GetResult();
            Seek(0, ct);
        }
        catch { StopMedia(); this.snapshot = null; UpdatePosition(0); throw; }
        }, ct);
    }
    /// <inheritdoc />
    public Task PlayAsync(CancellationToken ct) => Invoke(() =>
    {
        RequireSnapshot();
        ThrowPlaybackFailure();
        if (playing) return;
        if (Position.EditedTime >= snapshot!.Timeline.Duration) Seek(0, ct);
        origin = Position.EditedTime;
        if (snapshot!.Media.Audio is not null)
        {
            if (!OperatingSystem.IsWindows()) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: audio preview requires Windows WASAPI. Your edits are saved.");
            StartAudio(origin, ct);
            audio!.PlayAsync(ct).GetAwaiter().GetResult();
        }
        videoClock.Restart(); playing = true;
        UpdatePosition(origin);
    }, ct);
    /// <inheritdoc />
    public Task PauseAsync(CancellationToken ct) => Invoke(Pause, ct);
    /// <inheritdoc />
    public Task SeekAsync(double editedTime, bool exact, CancellationToken ct)
    {
        var request = Interlocked.Increment(ref seekRequest);
        return Invoke(() =>
        {
            ThrowPlaybackFailure();
            if (exact || request == Interlocked.Read(ref seekRequest)) Seek(editedTime, ct, true);
        }, ct);
    }
    /// <inheritdoc />
    public Task UpdateSnapshotAsync(ComposeSnapshot snapshot, CancellationToken ct)
    {
        snapshot = snapshot.VoiceLab?.CaptureSnapshot(snapshot) ?? snapshot;
        return Invoke(() =>
    {
        RequireSnapshot();
        var sameVoice = voiceSession is not null && this.snapshot!.VoiceLab is { } oldInput &&
            snapshot.VoiceLab is { } newInput && oldInput.Fingerprint == newInput.Fingerprint &&
            oldInput.PaidRoot == newInput.PaidRoot && oldInput.Prepared.OutputPlan.Scope == newInput.Prepared.OutputPlan.Scope &&
            oldInput.Prepared.Disclosure.Position == newInput.Prepared.Disclosure.Position;
        var nextSession = sameVoice ? voiceSession : VoiceLabRenderSession.PrepareAsync(snapshot, ct).GetAwaiter().GetResult();
        var previousSnapshot = this.snapshot;
        ComposeSnapshot? nextSnapshot = null;
        var swapped = false;
        try
        {
            nextSnapshot = CapPreview(snapshot);
            if (composer is FrameComposer concrete) concrete.PrepareDisclosure(nextSnapshot);
            var source = Position.SourceTime;
            var resume = playing;
            Pause();
            if (!sameVoice) { StopAudio(); voiceSession?.Dispose(); voiceSession = nextSession; }
            Interlocked.Exchange(ref this.snapshot, nextSnapshot);
            swapped = true;
            var edited = snapshot.Timeline.MapTime(source);
            Seek(edited, ct);
            if (resume) Resume(ct);
            if (composer is FrameComposer used) used.ReleaseDisclosure(previousSnapshot);
        }
        catch
        {
            if (composer is FrameComposer used)
            {
                if (swapped) used.ReleaseDisclosure(previousSnapshot);
                else used.ReleaseDisclosure(nextSnapshot);
            }
            if (!sameVoice && !ReferenceEquals(voiceSession, nextSession)) nextSession?.Dispose();
            throw;
        }
        }, ct);
    }
    /// <inheritdoc />
    public Task UpdateCaptionsAsync(CaptionTrack? captions, CancellationToken ct) => Invoke(() =>
    {
        RequireSnapshot();
        var updated = snapshot! with { Captions = captions };
        updated = updated.VoiceLab?.CaptureSnapshot(updated) ?? updated;
        var previous = snapshot;
        if (composer is FrameComposer concrete) concrete.PrepareDisclosure(updated);
        Interlocked.Exchange(ref snapshot, updated);
        try { if (!playing) Present(Position.EditedTime, true, ct); }
        finally { if (composer is FrameComposer used) used.ReleaseDisclosure(previous); }
    }, ct);
    /// <inheritdoc />
    public async IAsyncEnumerable<PreviewFrame> ReadFramesAsync([EnumeratorCancellation] CancellationToken ct)
    {
        if (useFrameLeases) throw new InvalidOperationException("Use ReadFrameLeasesAsync for a leased preview engine.");
        await foreach (var frame in frames.Reader.ReadAllAsync(ct).ConfigureAwait(false)) yield return frame;
    }

    /// <summary>Consume and dispose each pooled frame. Undisposed leases apply bounded backpressure by dropping new video frames.</summary>
    public async IAsyncEnumerable<PreviewFrameLease> ReadFrameLeasesAsync([EnumeratorCancellation] CancellationToken ct)
    {
        if (!useFrameLeases) throw new InvalidOperationException("Enable frame leases when constructing the preview engine.");
        await foreach (var lease in leases.Reader.ReadAllAsync(ct).ConfigureAwait(false)) yield return lease;
    }

    private void Own()
    {
        try
        {
            while (!commands.IsCompleted)
            {
                if (commands.TryTake(out var command, 3)) command.Execute();
                if (!playing || snapshot is null) continue;
                try
                {
                    var clock = Clock();
                    UpdatePosition(clock);
                    if (clock >= snapshot.Timeline.Duration) { Pause(); continue; }
                    if (nextFrame <= clock + 0.1)
                    {
                        if (nextFrame < clock - 0.1) nextFrame = clock;
                        Present(nextFrame, false, CancellationToken.None);
                        nextFrame += 1 / snapshot.Output.FrameRate;
                    }
                }
                catch (Exception exception) { RecoverPlayback(exception); }
            }
        }
        catch (Exception exception)
        {
            Volatile.Write(ref terminalFailure, exception);
            frames.Writer.TryComplete(exception); leases.Writer.TryComplete(exception);
        }
        finally
        {
            commands.CompleteAdding();
            while (commands.TryTake(out var command)) command.Fail(terminalFailure ?? new ObjectDisposedException(nameof(PreviewEngine)));
            try { StopMedia(); }
            catch (Exception exception) { frames.Writer.TryComplete(exception); leases.Writer.TryComplete(exception); }
            finally
            {
                if (composer is FrameComposer concrete) concrete.ReleaseThreadResources();
                frames.Writer.TryComplete(); leases.Writer.TryComplete();
                while (leases.Reader.TryRead(out var lease)) lease.Dispose();
                framePool = null; stopped.TrySetResult();
            }
        }
    }

    private void RecoverPlayback(Exception exception)
    {
        origin = Position.EditedTime;
        playing = false; videoClock.Stop(); StopAudio(); UpdatePosition(origin);
        prepared = null; preparedPart = -1;
        playbackFailure = exception;
        if (PlaybackFaulted is { } handlers)
            foreach (EventHandler<Exception> handler in handlers.GetInvocationList())
                try { handler(this, exception); }
                catch (Exception) { }
    }

    private void ThrowPlaybackFailure()
    {
        if (Interlocked.Exchange(ref playbackFailure, null) is { } failure)
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
    }

    private void Seek(double editedTime, CancellationToken ct, bool exact = true)
    {
        RequireSnapshot();
        var resume = playing;
        Pause(); StopAudio();
        ClearPrefetch();
        origin = Math.Clamp(double.IsFinite(editedTime) ? editedTime : 0, 0, snapshot!.Timeline.Duration);
        cursor = new(snapshot.Timeline); currentPart = cursor.Part;
        prepared = null; preparedPart = -1; generation++;
        while (frames.Reader.TryRead(out _)) { }
        while (leases.Reader.TryRead(out var lease)) lease.Dispose();
        nextFrame = origin;
        Present(origin, exact, ct);
        UpdatePosition(origin);
        if (resume) Resume(ct);
    }

    private void Present(double edited, bool exact, CancellationToken ct)
    {
        var local = snapshot!;
        var source = cursor!.Source(Math.Min(edited, Math.Max(0, local.Timeline.Duration - 1 / local.Timeline.SampleRate)));
        if (cursor.Part != currentPart)
        {
            if (preparedPart == cursor.Part && prepared is { } pending)
            {
                try { pending.GetAwaiter().GetResult(); (current, lookAhead) = (lookAhead, current); }
                catch (Exception) when (pending.IsFaulted || pending.IsCanceled) { exact = true; }
            }
            prepared = null; preparedPart = -1; currentPart = cursor.Part;
        }
        var decoded = current!.ReadAsync(source, exact, ct).GetAwaiter().GetResult();
        if (useFrameLeases)
        {
            if (framePool is null || framePool.Size != local.Output.Size) framePool = new(local.Output.Size);
            var lease = framePool.TryRent(edited, current.Position, generation);
            if (lease is not null)
            {
                try
                {
                    composer.Compose(decoded, lease.Frame.Buffer, local, edited, true, ct);
                    if (!leases.Writer.TryWrite(lease)) lease.Dispose();
                }
                catch { lease.Dispose(); throw; }
            }
        }
        else
        {
            var pixels = new PixelBuffer(GC.AllocateUninitializedArray<byte>(checked(local.Output.Size.Width * local.Output.Size.Height * 4)),
                local.Output.Size.Width, local.Output.Size.Height, local.Output.Size.Width * 4);
            composer.Compose(decoded, pixels, local, edited, true, ct);
            frames.Writer.TryWrite(new(pixels, edited, current.Position, generation));
        }
        if (prepared is null && cursor.NextJoin - edited <= 2 && double.IsFinite(cursor.NextSource))
        {
            prefetchCancellation ??= new();
            preparedPart = cursor.Part + 1;
            prepared = lookAhead!.ReadAsync(cursor.NextSource, true, prefetchCancellation.Token);
        }
    }

    private void Pause()
    {
        if (!playing) return;
        var clock = Clock();
        if (OperatingSystem.IsWindows()) audio?.PauseAsync(CancellationToken.None).GetAwaiter().GetResult();
        playing = false; videoClock.Stop(); origin = clock; UpdatePosition(clock);
    }

    private void Resume(CancellationToken ct)
    {
        if (snapshot!.Media.Audio is not null)
        {
            if (!OperatingSystem.IsWindows()) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: audio preview requires Windows WASAPI. Your edits are saved.");
            StartAudio(origin, ct); audio!.PlayAsync(ct).GetAwaiter().GetResult();
        }
        playing = true; videoClock.Restart(); UpdatePosition(origin);
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private void StartAudio(double edited, CancellationToken ct)
    {
        StopAudio();
        audio = new(); audio.ConfigureAsync(48_000, 2, false, ct).GetAwaiter().GetResult();
        audioCancellation = new CancellationTokenSource();
        var token = audioCancellation.Token;
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var localAudio = audio;
        var localSnapshot = snapshot!;
        var localSession = voiceSession;
        audioProducer = MediaThread.Run("vc-audio", () =>
        {
            try
            {
                using var reader = new EditedAudioReader(localSnapshot, 48_000, edited, localSession, token);
                var samples = new float[4096 * 2];
                int count;
                while ((count = reader.Read(samples, samples.Length / 2, token)) > 0)
                {
                    var bytes = MemoryMarshal.AsBytes(samples.AsSpan(0, count * 2));
                    var offset = 0;
                    while (offset < bytes.Length)
                    {
                        token.ThrowIfCancellationRequested();
                        offset += localAudio.Write(bytes[offset..]);
                        if (localAudio.BufferedBytes >= 48_000 * 2 * 4 * 2) ready.TrySetResult();
                        if (offset < bytes.Length) token.WaitHandle.WaitOne(3);
                    }
                }
                ready.TrySetResult();
                return true;
            }
            catch (Exception exception) { ready.TrySetException(exception); throw; }
        }, token);
        try { ready.Task.WaitAsync(ct).GetAwaiter().GetResult(); }
        catch { StopAudio(); throw; }
    }

    private double Clock()
    {
        if (audioProducer?.IsFaulted == true) audioProducer.GetAwaiter().GetResult();
        if (audioProducer?.IsCanceled == true) throw new IOException("The preview audio producer stopped unexpectedly.");
        if (OperatingSystem.IsWindows() && audio?.Completion.IsFaulted == true) audio.Completion.GetAwaiter().GetResult();
        if (clockOverride is not null) return clockOverride();
        var elapsed = OperatingSystem.IsWindows() && audio is not null ? audio.FramesPlayed / (double)audio.DeviceRate : videoClock.Elapsed.TotalSeconds;
        return Math.Min(snapshot!.Timeline.Duration, origin + elapsed);
    }

    private void UpdatePosition(double edited)
    {
        var source = snapshot is null ? 0 : new TimelineCursor(snapshot.Timeline).Source(edited);
        Volatile.Write(ref position, new(edited, source, playing));
    }

    private void StopAudio()
    {
        audioCancellation?.Cancel();
        try { audioProducer?.GetAwaiter().GetResult(); } catch (Exception) { }
        finally
        {
            audioProducer = null; audioCancellation?.Dispose(); audioCancellation = null;
            try { if (OperatingSystem.IsWindows()) audio?.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            catch (Exception) { }
            finally { audio = null; }
        }
    }

    private void StopMedia()
    {
        ClearPrefetch();
        playing = false;
        videoClock.Stop(); UpdatePosition(Position.EditedTime);
        try { StopAudio(); }
        finally
        {
            try { current?.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            finally
            {
                try { lookAhead?.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
                finally
                {
                    current = null; lookAhead = null; prepared = null;
                    if (composer is FrameComposer concrete) concrete.ReleaseDisclosure(snapshot);
                    voiceSession?.Dispose(); voiceSession = null;
                }
            }
        }
    }

    private void ClearPrefetch()
    {
        prefetchCancellation?.Cancel(); prefetchCancellation?.Dispose(); prefetchCancellation = null;
        prepared = null; preparedPart = -1;
    }

    private void RequireSnapshot()
    {
        if (snapshot is null || current is null || lookAhead is null) throw new InvalidOperationException("Load a preview snapshot first.");
    }

    private Task Invoke(Action action, CancellationToken ct)
    {
        if (ct.IsCancellationRequested) return Task.FromCanceled(ct);
        if (Volatile.Read(ref terminalFailure) is { } failure) return Task.FromException(failure);
        if (disposed) return Task.FromException(new ObjectDisposedException(nameof(PreviewEngine)));
        var command = new OwnerCommand<bool>(() =>
        {
            action(); return true;
        }, ct);
        try
        {
            if (!commands.TryAdd(command)) command.Fail(terminalFailure ?? new ObjectDisposedException(nameof(PreviewEngine)));
        }
        catch (InvalidOperationException) { command.Fail(terminalFailure ?? new ObjectDisposedException(nameof(PreviewEngine))); }
        return command.Task;
    }

    private static ComposeSnapshot CapPreview(ComposeSnapshot snapshot)
    {
        var requested = snapshot.Output.Size;
        var maximum = ExportPresets.OutputSize(requested, ExportAspect.Source);
        return snapshot with { Output = snapshot.Output with { Size = maximum } };
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (!disposed) { disposed = true; commands.CompleteAdding(); }
        await stopped.Task.ConfigureAwait(false);
    }

}
