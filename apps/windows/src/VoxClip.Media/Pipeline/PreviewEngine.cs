using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Media.Pipeline;

/// <summary>Audio-master edited playback with owner-thread video decoders; architecture §6.3.</summary>
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
    private readonly Func<IPreviewAudioOutput> createAudio;
    private readonly Func<double>? clockOverride;
    private Exception? terminalFailure;
    private Exception? playbackFailure;
    /// <summary>The loaded preview's compositor failures: a new count per load and plan swap, kept across caption swaps.</summary>
    private PreviewFrameFailures? failures;
    private readonly Stopwatch videoClock = new();
    private ComposeSnapshot? snapshot;
    private VoiceLabRenderSession? voiceSession;
    private PreviewPosition position = new(0, 0, false);
    private IPreviewVideoWorker? current;
    private IPreviewVideoWorker? lookAhead;
    private readonly Dictionary<string, (string Path, IPreviewVideoWorker Worker)> recordingWorkers = new(StringComparer.Ordinal);
    private Task<PixelBuffer>? prepared;
    private int preparedPart = -1;
    private CancellationTokenSource? prefetchCancellation;
    private TimelineCursor? cursor;
    private IPreviewAudioOutput? audio;
    private PreviewAudioStatus audioStatus;
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
        Func<double>? clockOverride = null, Func<IPreviewAudioOutput>? createAudio = null)
    {
        this.composer = composer;
        this.useFrameLeases = useFrameLeases;
        this.initialize = initialize ?? (ct => FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult());
        this.createWorker = createWorker ?? ((path, name) => new VideoWorker(path, name));
        this.createAudio = createAudio ?? CreateWasapi;
        this.clockOverride = clockOverride;
        new Thread(Own) { Name = "vc-preview", IsBackground = true }.Start();
    }
    /// <inheritdoc />
    public PreviewPosition Position => Volatile.Read(ref position);
    /// <summary>The current preview's staged ducking gains on the rendered clock, or null before a bed is staged.</summary>
    public IReadOnlyList<double>? MusicDuckingGainsDb => Volatile.Read(ref stagedMusic) is { } staged &&
        staged.Revision == Interlocked.Read(ref musicRevision) ? staged.Bed?.DuckingGainsDb : null;
    /// <inheritdoc />
    public event EventHandler<Exception>? PlaybackFaulted;
    /// <inheritdoc />
    public event EventHandler<PreviewAudioStatus>? AudioStatusChanged;
    /// <inheritdoc />
    public event EventHandler<PreviewFailureReason>? CompositorFailed;
    /// <inheritdoc />
    public Task LoadAsync(ComposeSnapshot snapshot, IProgress<MediaProgress>? progress, CancellationToken ct)
    {
        snapshot = snapshot.VoiceLab?.CaptureSnapshot(snapshot) ?? snapshot;
        return Invoke(() =>
    {
        StopMedia();
        playbackFailure = null;
        this.snapshot = null;
        failures = NewFailures();
        try
        {
            initialize(ct);
            voiceSession = VoiceLabRenderSession.PrepareAsync(snapshot, ct).GetAwaiter().GetResult();
            this.snapshot = CapPreview(snapshot);
            if (composer is FrameComposer concrete) concrete.PrepareSnapshot(this.snapshot);
            if (snapshot.SpanSources.Count == 0) OpenLegacyWorkers(snapshot.Media.Path, ct);
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
        Resume(ct);
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
        var previousFailures = failures;
        ComposeSnapshot? nextSnapshot = null;
        var swapped = false;
        try
        {
            nextSnapshot = CapPreview(snapshot);
            if (composer is FrameComposer concrete) concrete.PrepareSnapshot(nextSnapshot);
            var resume = playing;
            Pause();
            // A fault Pause recovered keeps playback stopped; the playhead it settled on carries over to the new plan.
            resume &= playbackFailure is null;
            var source = Position.SourceTime;
            if (!sameVoice) { StopAudio(); voiceSession?.Dispose(); voiceSession = nextSession; }
            Interlocked.Increment(ref musicRevision);
            Interlocked.Exchange(ref this.snapshot, nextSnapshot);
            failures = NewFailures();
            swapped = true;
            var edited = snapshot.Timeline.MapTime(source);
            Seek(edited, ct);
            if (resume) Resume(ct);
            if (composer is FrameComposer used) used.ReleaseSnapshot(previousSnapshot);
        }
        catch
        {
            if (!swapped) failures = previousFailures;
            if (composer is FrameComposer used)
            {
                if (swapped) used.ReleaseSnapshot(previousSnapshot);
                else used.ReleaseSnapshot(nextSnapshot);
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
        if (composer is FrameComposer concrete) concrete.PrepareSnapshot(updated);
        Interlocked.Exchange(ref snapshot, updated);
        try { if (!playing) Present(Position.EditedTime, true, ct); }
        finally { if (composer is FrameComposer used) used.ReleaseSnapshot(previous); }
    }, ct);
    /// <inheritdoc />
    public async Task<PixelBuffer> StillAsync(ProjectClipControls colour, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(colour);
        PixelBuffer? still = null;
        await Invoke(() => still = Still(new(false, colour), ct), ct).ConfigureAwait(false);
        return still!;
    }
    /// <inheritdoc />
    public async Task<PixelBuffer> StillBeforeGradeAsync(CancellationToken ct)
    {
        PixelBuffer? still = null;
        await Invoke(() => still = Still(new(true, null), ct), ct).ConfigureAwait(false);
        return still!;
    }
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
                        // Frames are due on the rendered clock; a clip's speed plays that many edited seconds per frame.
                        var timing = snapshot.Speed;
                        nextFrame = timing.Edited(timing.Rendered(nextFrame) + 1 / snapshot.Output.FrameRate);
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

    /// <summary>A new count for a loaded preview; its first reason raises <see cref="CompositorFailed"/> on the owner thread.</summary>
    private PreviewFrameFailures NewFailures() => new(reason =>
    {
        if (CompositorFailed is { } handlers)
            foreach (EventHandler<PreviewFailureReason> handler in handlers.GetInvocationList())
                try { handler(this, reason); }
                catch (Exception) { }
    });

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
        Pause();
        resume &= playbackFailure is null; // a fault Pause recovered keeps playback stopped
        StopAudio();
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
        var (recording, localTime) = cursor.Picture(local, source);
        if (recording is null)
        {
            OpenLegacyWorkers(local.Media.Path, ct);
            if (cursor.Part != currentPart)
            {
                if (preparedPart == cursor.Part && prepared is { } pending)
                {
                    try { pending.GetAwaiter().GetResult(); (current, lookAhead) = (lookAhead, current); }
                    catch (Exception) when (pending.IsFaulted || pending.IsCanceled) { exact = true; }
                }
                prepared = null; preparedPart = -1; currentPart = cursor.Part;
            }
        }
        PixelBuffer decoded;
        double sourcePts;
        try
        {
            var worker = recording is null ? current! : OpenRecordingWorker(recording, ct);
            decoded = worker.ReadAsync(localTime, recording is null && exact, ct).GetAwaiter().GetResult();
            sourcePts = worker.Position + (recording?.OffsetSamples ?? 0) / local.Timeline.SampleRate;
        }
        catch (Exception exception) { PreviewFrameFailures.Failed(failures, true, PreviewFailureReason.SourceFrame, exception); throw; }
        if (useFrameLeases)
        {
            if (framePool is null || framePool.Size != local.Output.Size) framePool = new(local.Output.Size);
            var lease = framePool.TryRent(edited, sourcePts, generation);
            if (lease is not null)
            {
                try
                {
                    Compose(decoded, lease.Frame.Buffer, local, edited, ct);
                    if (!leases.Writer.TryWrite(lease)) lease.Dispose();
                }
                catch { lease.Dispose(); throw; }
            }
        }
        else
        {
            byte[] bytes;
            try { bytes = GC.AllocateUninitializedArray<byte>(checked(local.Output.Size.Width * local.Output.Size.Height * 4)); }
            catch (Exception exception) when (exception is OutOfMemoryException or OverflowException)
            {
                PreviewFrameFailures.Failed(failures, true, PreviewFailureReason.FrameBuffer, exception); throw;
            }
            var pixels = new PixelBuffer(bytes, local.Output.Size.Width, local.Output.Size.Height, local.Output.Size.Width * 4);
            Compose(decoded, pixels, local, edited, ct);
            frames.Writer.TryWrite(new(pixels, edited, sourcePts, generation));
        }
        if (recording is null && prepared is null && cursor.NextJoin - edited <= 2 && double.IsFinite(cursor.NextSource))
        {
            prefetchCancellation ??= new();
            preparedPart = cursor.Part + 1;
            prepared = lookAhead!.ReadAsync(cursor.NextSource, true, prefetchCancellation.Token);
        }
    }

    private void OpenLegacyWorkers(string path, CancellationToken ct)
    {
        if (current is not null) return;
        current = createWorker(path, "vc-dec-a"); lookAhead = createWorker(path, "vc-dec-b");
        Task.WhenAll(current.Ready, lookAhead.Ready).WaitAsync(ct).GetAwaiter().GetResult();
    }

    private IPreviewVideoWorker OpenRecordingWorker(RecordingRenderSource recording, CancellationToken ct)
    {
        if (recordingWorkers.TryGetValue(recording.ContentKey, out var opened))
        {
            if (opened.Path == recording.Path) return opened.Worker;
            recordingWorkers.Remove(recording.ContentKey);
            opened.Worker.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        var worker = createWorker(RecordingRendering.RequirePath(recording), "vc-dec-recording");
        recordingWorkers.Add(recording.ContentKey, (recording.Path, worker));
        worker.Ready.WaitAsync(ct).GetAwaiter().GetResult();
        return worker;
    }

    /// <summary>A Picture still of the paused frame (looks spec §7): the source frame under the playhead read exactly, as a seek reads
    /// it, then composed as the export composes it into a new buffer at the output size. The playhead, the prefetch and the presented
    /// frames stay as they are.</summary>
    private PixelBuffer Still(FrameStill request, CancellationToken ct)
    {
        RequireSnapshot();
        if (playing) throw new InvalidOperationException("Pause the preview before taking a still.");
        var local = snapshot!;
        var edited = Position.EditedTime;
        var timeline = new TimelineCursor(local.Timeline);
        var source = timeline.Source(Math.Min(edited, Math.Max(0, local.Timeline.Duration - 1 / local.Timeline.SampleRate)));
        var (recording, localTime) = timeline.Picture(local, source);
        if (recording is null) OpenLegacyWorkers(local.Media.Path, ct);
        // A still that fails fails its own call; the preview's failure count is for the frames it shows.
        var decoded = (recording is null ? current! : OpenRecordingWorker(recording, ct)).ReadAsync(localTime, true, ct).GetAwaiter().GetResult();
        var size = local.Output.Size;
        var pixels = new PixelBuffer(GC.AllocateUninitializedArray<byte>(checked(size.Width * size.Height * 4)), size.Width, size.Height, size.Width * 4);
        var synced = voiceSession?.Lipsync?.Read(edited, ct);
        if (composer is FrameComposer concrete)
            concrete.Compose(synced ?? decoded, pixels, local, edited, false, null, ct, renderedVoicePicture: synced is not null, still: request);
        else if (request.BeforeGrade) throw new NotSupportedException("Only the shared frame composer stops before the grade.");
        else
        {
            var colour = request.Colour!;
            var controls = (local.Clip?.Controls ?? colour) with { Look = colour.Look, ColorAdjustments = colour.ColorAdjustments, ColorGrade = colour.ColorGrade };
            composer.Compose(decoded, pixels, local with { Clip = (local.Clip ?? new(null, null)) with { Controls = controls } }, edited, false, ct);
        }
        return pixels;
    }

    /// <summary>The shared compositor, told about this preview's failures; another composer composes as given.</summary>
    private void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot local, double edited, CancellationToken ct)
    {
        var synced = voiceSession?.Lipsync?.Read(edited, ct);
        if (composer is FrameComposer concrete) concrete.Compose(synced ?? decoded, output, local, edited, true, failures, ct, renderedVoicePicture: synced is not null);
        else composer.Compose(decoded, output, local, edited, true, ct);
    }

    /// <summary>Stop at the clock. A device loss or fault seen here is handled exactly as on the owner tick, with the one reopen
    /// or RecoverPlayback, so Pause never throws.</summary>
    private void Pause()
    {
        if (!playing) return;
        try
        {
            var clock = Clock();
            try { audio?.PauseAsync(CancellationToken.None).GetAwaiter().GetResult(); }
            catch (Exception exception) when (audio is { } failed && IPreviewAudioOutput.Unavailable(exception) is not null)
            {
                // Lost before its owner reported it: the same one reopen settles the status, and the next start opens the device.
                ReopenAfterLoss(failed, exception);
                StopAudio();
            }
            playing = false; videoClock.Stop(); origin = clock; UpdatePosition(clock);
        }
        catch (Exception exception) { RecoverPlayback(exception); }
    }

    private void Resume(CancellationToken ct)
    {
        if (snapshot!.Media.Audio is not null || snapshot.Clip?.Music is not null) StartAudio(origin, ct);
        playing = true; videoClock.Restart(); UpdatePosition(origin);
    }

    /// <summary>Without usable output, playback stays muted on the video clock; each start retries the device.</summary>
    private void StartAudio(double edited, CancellationToken ct)
    {
        StopAudio();
        try { OpenAudio(edited, ct); }
        catch (Exception exception) when (IPreviewAudioOutput.Unavailable(exception) is { } status)
        {
            StopAudio(); ReportAudio(status);
            return;
        }
        catch { StopAudio(); throw; }
        ReportAudio(PreviewAudioStatus.Available);
    }

    private sealed record StagedMusic(long Revision, MusicBed? Bed);
    private long musicRevision;
    private StagedMusic? stagedMusic;

    /// <summary>The snapshot's music bed, staged once per snapshot (each play reads it from the playhead). A bed that cannot be
    /// staged (a missing file, a silent video) previews the voice alone; the export names the problem and stops.</summary>
    private MusicBed? PreviewMusic(ComposeSnapshot snapshot, long revision, VoiceLabRenderSession? session, CancellationToken ct)
    {
        if (snapshot.Clip?.Music is null) return null;
        if (Volatile.Read(ref stagedMusic) is { } cached && cached.Revision == revision) return cached.Bed;
        MusicBed? staged = null;
        try { staged = MusicBed.Stage(snapshot, 48_000, session, ct); }
        catch (VoxClipException) { }
        Volatile.Write(ref stagedMusic, new(revision, staged));
        return staged;
    }

    private static IPreviewAudioOutput CreateWasapi()
    {
        if (!OperatingSystem.IsWindows()) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: audio preview requires Windows WASAPI. Your edits are saved.");
        return new WasapiAudioPlayer();
    }

    private void OpenAudio(double edited, CancellationToken ct)
    {
        audio = createAudio(); audio.ConfigureAsync(48_000, 2, false, ct).GetAwaiter().GetResult();
        audioCancellation = new CancellationTokenSource();
        var token = audioCancellation.Token;
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var localAudio = audio;
        var localSnapshot = snapshot!;
        var localSession = voiceSession;
        var revision = Interlocked.Read(ref musicRevision);
        audioProducer = MediaThread.Run("vc-audio", () =>
        {
            try
            {
                using var reader = RenderedAudioReader.Open(localSnapshot, 48_000, edited, localSession, token,
                    PreviewMusic(localSnapshot, revision, localSession, token));
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
        ready.Task.WaitAsync(ct).GetAwaiter().GetResult();
        audio.PlayAsync(ct).GetAwaiter().GetResult();
    }

    private double Clock()
    {
        if (audioProducer?.IsFaulted == true) audioProducer.GetAwaiter().GetResult();
        if (audioProducer?.IsCanceled == true) throw new IOException("The preview audio producer stopped unexpectedly.");
        if (audio is { Completion.IsFaulted: true } failed) ReopenAfterLoss(failed, failed.Completion.Exception!.InnerException!);
        if (clockOverride is not null) return clockOverride();
        var elapsed = audio is not null ? audio.FramesPlayed / (double)audio.DeviceRate : videoClock.Elapsed.TotalSeconds;
        // The clock plays rendered seconds; positions stay on the edited timeline (design §6.9).
        var timing = snapshot!.Speed;
        return Math.Min(snapshot.Timeline.Duration, timing.Edited(timing.Rendered(origin) + elapsed));
    }

    /// <summary>A failed output device first lands the playhead on its last played frame. A lost device then gets exactly one
    /// immediate reopen of the current default device from there, such as speakers after headphones are unplugged; without one,
    /// playback continues muted. Any other device error, including one from the reopen, faults playback at that frame.</summary>
    private void ReopenAfterLoss(IPreviewAudioOutput failed, Exception error)
    {
        var timing = snapshot!.Speed;
        var lost = Math.Min(snapshot.Timeline.Duration, timing.Edited(timing.Rendered(origin) + failed.FramesPlayed / (double)failed.DeviceRate));
        UpdatePosition(lost);
        if (IPreviewAudioOutput.Unavailable(error) is null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error).Throw();
        StartAudio(lost, CancellationToken.None);
        origin = lost;
        videoClock.Restart();
    }

    private void ReportAudio(PreviewAudioStatus status)
    {
        if (audioStatus == status) return;
        audioStatus = status;
        if (AudioStatusChanged is { } handlers)
            foreach (EventHandler<PreviewAudioStatus> handler in handlers.GetInvocationList())
                try { handler(this, status); }
                catch (Exception) { }
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
            try { audio?.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            catch (Exception) { }
            finally { audio = null; }
        }
    }

    private void StopMedia()
    {
        Interlocked.Increment(ref musicRevision);
        ClearPrefetch();
        playing = false;
        videoClock.Stop(); UpdatePosition(Position.EditedTime);
        try { StopAudio(); }
        finally
        {
            Volatile.Write(ref stagedMusic, null);
            try { current?.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            finally
            {
                try { lookAhead?.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
                finally
                {
                    current = null; lookAhead = null; prepared = null;
                    foreach (var entry in recordingWorkers.Values) entry.Worker.DisposeAsync().AsTask().GetAwaiter().GetResult();
                    recordingWorkers.Clear();
                    if (composer is FrameComposer concrete) concrete.ReleaseSnapshot(snapshot);
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
        if (snapshot is null) throw new InvalidOperationException("Load a preview snapshot first.");
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
