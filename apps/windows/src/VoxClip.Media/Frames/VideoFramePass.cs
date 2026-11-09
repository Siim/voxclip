using System.Diagnostics;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Frames;

/// <summary>The whole video's sentence-frame pass (ADR-R48 part 2, ai.md §19.6), twin of the Mac <c>VideoFramePass</c>. It starts as
/// soon as the transcript exists, while Find Clips runs, and looks at one frame per sentence of the whole recording through
/// <see cref="FrameAnalyzer"/> and its cache (about 200 frames for 29 minutes), so a clip's plan later takes its frames without
/// decoding. Each clip's opening scan runs on its own, beside that clip's plan request. A source the analyzer cannot read (no video
/// track, a decode failure) logs one line and every clip goes on as text only: nothing fails. <see cref="Cancel"/> stops the pass and
/// every opening scan; a caller's token only stops its own wait.</summary>
public sealed class VideoFramePass
{
    /// <summary>A clip's frames: its sentence frames (from the pass) and their sheet.</summary>
    public sealed record ClipFrames(IReadOnlyList<FrameObservation> Sentences, FrameSheet Sheet);

    private sealed record Found(IReadOnlyDictionary<long, FrameObservation> Frames, IReadOnlyDictionary<long, byte[]> Jpegs);

    private readonly FrameAnalyzer analyzer;
    private readonly string source;
    private readonly string contentKey;
    private readonly IReadOnlyList<FrameSample> samples;
    private readonly Action<string> log;
    private readonly object gate = new();
    private readonly CancellationTokenSource cancellation = new();
    private readonly Dictionary<long, Task<IReadOnlyList<FrameObservation>?>> openings = [];
    private Task<Found?>? pass;

    /// <summary>The pass over <paramref name="words"/>, the transcript's; <paramref name="log"/> gets the one line a failure writes.</summary>
    public VideoFramePass(FrameAnalyzer analyzer, string source, string contentKey, IReadOnlyList<TimedWord> words, Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(analyzer);
        ArgumentNullException.ThrowIfNull(words);
        this.analyzer = analyzer;
        this.source = source;
        this.contentKey = contentKey;
        samples = FrameSampling.VideoSamples(words);
        this.log = log ?? (_ => { });
    }

    /// <summary>How many sentence frames the pass looks at.</summary>
    public int FrameCount => samples.Count;
    /// <summary>Wall seconds of the whole pass, once it has run; null before or after a failure.</summary>
    public double? Seconds { get; private set; }
    /// <summary>When the pass started, seconds on the clock given to <see cref="Start"/>, for the CLI's timings.</summary>
    public double? Started { get; private set; }
    /// <summary>When the pass ended, on the same clock.</summary>
    public double? Ended { get; private set; }
    /// <summary>Frames looked at now.</summary>
    public int Analyzed { get; private set; }
    /// <summary>Frames taken from the cache.</summary>
    public int Cached { get; private set; }

    /// <summary>Starts the pass; later calls do nothing. <paramref name="clock"/> stamps <see cref="Started"/> and <see cref="Ended"/> and
    /// records the pass as its <see cref="ClaudeModeStage.Frames"/> stage, as the Mac's <c>start(clock:)</c> does.</summary>
    public void Start(ClaudeModeClock? clock = null)
    {
        lock (gate)
        {
            if (pass is not null) return;
            Started = clock?.Elapsed;
            pass = Task.Run(() => RunAsync(clock), CancellationToken.None);
        }
    }

    private async Task<Found?> RunAsync(ClaudeModeClock? clock)
    {
        var times = samples.Select(sample => sample.Time).ToArray();
        var watch = Stopwatch.StartNew();
        try
        {
            var found = await analyzer.ObservationsAsync(source, contentKey, times, FrameScanKind.Sentence, cancellation.Token).ConfigureAwait(false);
            var frames = new Dictionary<long, FrameObservation>();
            foreach (var (time, frame) in times.Zip(found.Frames)) frames[FrameAnalysisCache.Millisecond(time)] = frame;
            Finished(watch.Elapsed.TotalSeconds, clock, found.Analyzed, found.Cached);
            return new(frames, found.Jpegs);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception exception)
        {
            log($"frames: the video's frames can't be read, so plans go as text only ({exception.GetType().Name})");
            Finished(null, clock, 0, 0);
            return null;
        }
    }

    private void Finished(double? seconds, ClaudeModeClock? clock, int analyzed, int cached)
    {
        double? started;
        lock (gate)
        {
            Seconds = seconds;
            Analyzed = analyzed;
            Cached = cached;
            Ended = clock?.Elapsed;
            started = Started;
        }
        if (clock is not null && started is { } start) clock.Record(ClaudeModeStage.Frames, null, start);
    }

    /// <summary>Waits for the pass (starting it if it has not started); false when the source could not be read.</summary>
    public async Task<bool> FinishAsync(CancellationToken ct = default) => await FoundAsync(ct).ConfigureAwait(false) is not null;

    private Task<Found?> FoundAsync(CancellationToken ct)
    {
        Start();
        Task<Found?> running;
        lock (gate) running = pass!;
        return running.WaitAsync(ct);
    }

    /// <summary>The recording's typical pitch (<see cref="FrameFace.PitchBaseline"/> over every frame of the pass), which a clip's facing
    /// is judged against so camera height never counts as looking away. Waits for the pass; null when the source cannot be read or no
    /// face had a pitch.</summary>
    public async Task<double?> PitchBaselineAsync(CancellationToken ct = default) =>
        await FoundAsync(ct).ConfigureAwait(false) is { } found ? FrameFace.PitchBaseline(found.Frames.Values) : null;

    /// <summary>A clip's sentence frames, at most 24 evenly spread, from the pass (<see cref="FrameSampling.ClipSamples"/>), with their
    /// sheet. Waits for the pass when it is still running. Null when the source cannot be read.</summary>
    public async Task<ClipFrames?> FramesAsync(FrameClip clip, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(clip);
        if (await FoundAsync(ct).ConfigureAwait(false) is not { } found) return null;
        var frames = new List<FrameObservation>();
        var missing = new List<double>();
        foreach (var sample in FrameSampling.ClipSamples(samples, clip))
        {
            if (found.Frames.TryGetValue(FrameAnalysisCache.Millisecond(sample.Time), out var frame)) frames.Add(frame);
            else missing.Add(sample.Time);
        }
        var jpegs = new Dictionary<long, byte[]>(found.Jpegs);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, cancellation.Token);
        try
        {
            IReadOnlyList<FrameObservation> sentences = frames;
            if (missing.Count > 0)
            {
                // A clip inside one long sentence: its own sentence frames, looked at now (and cached).
                var extra = await analyzer.ObservationsAsync(source, contentKey, missing, FrameScanKind.Sentence, linked.Token).ConfigureAwait(false);
                sentences = [.. frames.Concat(extra.Frames).OrderBy(frame => frame.Time)];
                foreach (var (key, jpeg) in extra.Jpegs) jpegs.TryAdd(key, jpeg);
            }
            var sheet = await analyzer.SheetAsync(source, contentKey, sentences, jpegs, linked.Token).ConfigureAwait(false);
            return new(sentences, sheet);
        }
        catch (OperationCanceledException) when (linked.IsCancellationRequested)
        {
            ct.ThrowIfCancellationRequested();
            return null;
        }
        catch (Exception exception)
        {
            log($"frames: a clip's frames can't be read, so its plan goes as text only ({exception.GetType().Name})");
            return null;
        }
    }

    /// <summary>The clip's opening scan (10 fps over ±0.6 s at its first kept word), started once per start time: the plan's request
    /// asks for it as it is sent and the apply waits for it. Null when the frames cannot be read.</summary>
    public Task<IReadOnlyList<FrameObservation>?> OpeningAsync(FrameClip clip, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(clip);
        var key = FrameAnalysisCache.Millisecond(clip.Start);
        Task<IReadOnlyList<FrameObservation>?> running;
        lock (gate)
        {
            if (!openings.TryGetValue(key, out running!))
            {
                var times = FrameSampling.OpeningTimes(clip.Start);
                running = Task.Run(() => ScanOpeningAsync(times), CancellationToken.None);
                openings[key] = running;
            }
        }
        return running.WaitAsync(ct);
    }

    private async Task<IReadOnlyList<FrameObservation>?> ScanOpeningAsync(IReadOnlyList<double> times)
    {
        try
        {
            return (await analyzer.ObservationsAsync(source, contentKey, times, FrameScanKind.Opening, cancellation.Token).ConfigureAwait(false)).Frames;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception exception)
        {
            log($"frames: a clip's opening can't be read ({exception.GetType().Name})");
            return null;
        }
    }

    /// <summary>Starts the opening scan without waiting for it.</summary>
    public void StartOpening(FrameClip clip) => _ = OpeningAsync(clip);

    /// <summary>Small JPEGs of the frames at <paramref name="times"/> (the sheet's size, cached), for the review's thumbnails; empty when
    /// they can't be read.</summary>
    public async Task<IReadOnlyList<byte[]>> ThumbnailsAsync(IReadOnlyList<double> times, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(times);
        try
        {
            var sheet = await analyzer.SheetAsync(source, contentKey, [.. times.Select(time => new FrameObservation(time))], null, ct).ConfigureAwait(false);
            return [.. sheet.Frames.Select(frame => frame.Image.Data)];
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception) { return []; }
    }

    /// <summary>Stops the pass and every opening scan.</summary>
    public void Cancel() => cancellation.Cancel();
}
