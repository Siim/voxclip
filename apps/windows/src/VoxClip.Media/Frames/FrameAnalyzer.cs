using System.Diagnostics;
using System.Runtime.ExceptionServices;
using VoxClip.Core.Domain.Frames;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Frames;

/// <summary>Which of a clip's looks a frame is for: a sentence frame (the sheet, text and screens, faces) or an opening-scan frame
/// (faces only).</summary>
public enum FrameScanKind
{
    /// <summary>One frame per sentence, within <see cref="FrameAnalyzer.SentenceTolerance"/>: faces, text and screens, and a sheet JPEG.</summary>
    Sentence,
    /// <summary>The opening scan's 10 fps, within <see cref="FrameAnalyzer.OpeningTolerance"/>: faces only. The opening scan only feeds
    /// the opening frame, which reads faces, and blur spans come from sentence frames (ADR-R48 Windows, the speed lever).</summary>
    Opening,
}

/// <summary>A clip's analysis with its frame sheet.</summary>
public sealed record FrameClipAnalysis(FrameAnalysis Analysis, FrameSheet Sheet);

/// <summary>What <see cref="FrameAnalyzer.ObservationsAsync"/> found.</summary>
/// <param name="Frames">The frames in the order asked.</param>
/// <param name="Cached">How many came from the cache.</param>
/// <param name="Analyzed">How many were decoded and looked at now.</param>
/// <param name="Jpegs">The sheet JPEGs of the frames decoded now, keyed by their own time's millisecond.</param>
public sealed record FrameObservationsFound(IReadOnlyList<FrameObservation> Frames, int Cached, int Analyzed, IReadOnlyDictionary<long, byte[]> Jpegs);

/// <summary>The on-device frame analyzer on Windows (ADR-R48 Windows, W5), twin of the Mac <c>FrameAnalyzer</c>: for given source
/// times it decodes frames with FFmpeg in parallel lanes, measures faces (<see cref="IFrameFaces"/>) and, on sentence frames, text and
/// screens (<see cref="FrameScreenScan"/>), and caches each observation per source and millisecond asked for
/// (<see cref="FrameAnalysisCache"/>). A cached time is never decoded or looked at again. Each observation's time is the frame's own,
/// which may differ from the time asked for by up to the pass's tolerance. There is no analyzer without a face source: faces
/// unavailable is <see cref="FrameFacesUnavailableException"/>, never frames without faces.</summary>
public sealed class FrameAnalyzer
{
    /// <summary>Frames are decoded with this long edge: faces and phone-screen text stay measurable, decode stays cheap.</summary>
    public const int AnalysisEdge = 1280;
    /// <summary>Lanes that decode and look at once.</summary>
    public const int Lanes = 4;
    /// <summary>Seconds a sentence frame may be from its time: the decoder may then return a nearby frame without decoding a long run of
    /// frames (ADR-R48).</summary>
    public const double SentenceTolerance = 0.25;
    /// <summary>Seconds an opening-scan frame may be from its time: one frame at 30 fps, so the 10 fps scan sees ten frames a second.</summary>
    public const double OpeningTolerance = 1.0 / 30;

    private readonly IFrameFaces faces;
    private readonly Func<FrameScreenScan> laneScreens;
    private readonly IFrameDecoding decoder;
    private readonly FrameAnalysisCache? cache;

    /// <summary>An analyzer that measures faces with <paramref name="faces"/> and text and screens with a new
    /// <paramref name="laneScreens"/> scan per lane (each needs its own <see cref="QuadFinder"/>, which is not thread-safe:
    /// <see cref="ScreensWith"/>). Null <paramref name="faces"/> is faces unavailable: <see cref="FrameFacesUnavailableException"/>.</summary>
    public FrameAnalyzer(IFrameFaces? faces, Func<FrameScreenScan> laneScreens, IFrameDecoding decoder, FrameAnalysisCache? cache)
    {
        ArgumentNullException.ThrowIfNull(laneScreens);
        ArgumentNullException.ThrowIfNull(decoder);
        this.faces = FrameFaces.Require(faces);
        this.laneScreens = laneScreens;
        this.decoder = decoder;
        this.cache = cache;
    }

    /// <summary>A new scan per lane on <paramref name="text"/> (the App's <c>WindowsFrameText</c>, which serialises itself), each with
    /// its own <see cref="QuadFinder"/>.</summary>
    public static Func<FrameScreenScan> ScreensWith(IFrameTextLines text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return () => new FrameScreenScan(text, new QuadFinder());
    }

    /// <summary>The decode tolerance of a kind of frame; its three decimals name the cache's pass (<c>"0.250"</c>, <c>"0.033"</c>), as on
    /// the Mac.</summary>
    public static double Tolerance(FrameScanKind kind) => kind == FrameScanKind.Opening ? OpeningTolerance : SentenceTolerance;

    /// <summary>A clip's sentence frames and opening scan with their timings, and the sheet of its sentence frames.</summary>
    public async Task<FrameClipAnalysis> AnalyzeAsync(string source, string contentKey, FrameClip clip, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(clip);
        var sentenceTimes = FrameSampling.SentenceSamples(clip).Select(sample => sample.Time).ToArray();
        var openingTimes = FrameSampling.OpeningTimes(clip.Start);
        var clock = Stopwatch.StartNew();
        var sentences = await ObservationsAsync(source, contentKey, sentenceTimes, FrameScanKind.Sentence, ct).ConfigureAwait(false);
        var sheet = await SheetAsync(source, contentKey, sentences.Frames, sentences.Jpegs, ct).ConfigureAwait(false);
        var sentenceSeconds = clock.Elapsed.TotalSeconds;
        clock.Restart();
        var opening = await ObservationsAsync(source, contentKey, openingTimes, FrameScanKind.Opening, ct).ConfigureAwait(false);
        var openingSeconds = clock.Elapsed.TotalSeconds;
        var timings = new FrameAnalysisTimings(sentenceSeconds, openingSeconds, sentences.Cached + opening.Cached, sentences.Analyzed + opening.Analyzed);
        return new(new FrameAnalysis(contentKey, sentences.Frames, opening.Frames, timings), sheet);
    }

    /// <summary>The observation at each of <paramref name="times"/>, in order: cached ones from the cache, the rest decoded and looked at
    /// in <see cref="Lanes"/> parallel lanes and then cached. Sentence frames also get their sheet JPEG, made and cached.</summary>
    public async Task<FrameObservationsFound> ObservationsAsync(string source, string contentKey, IReadOnlyList<double> times, FrameScanKind kind,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(times);
        var tolerance = Tolerance(kind);
        var pass = FrameAnalysisFile.Pass(tolerance);
        var cached = cache?.Observations(contentKey, pass) ?? new Dictionary<long, FrameObservation>();
        var found = new Dictionary<long, FrameObservation>();
        var missing = new List<double>();
        foreach (var time in times)
        {
            var key = FrameAnalysisCache.Millisecond(time);
            if (cached.TryGetValue(key, out var hit)) found[key] = hit;
            else if (!missing.Any(other => FrameAnalysisCache.Millisecond(other) == key)) missing.Add(time);
        }
        var fresh = await AnalyzeMissingAsync(source, missing, kind, ct).ConfigureAwait(false);
        var jpegs = new Dictionary<long, byte[]>();
        foreach (var item in fresh)
        {
            found[FrameAnalysisCache.Millisecond(item.Requested)] = item.Observation;
            if (item.Jpeg is { } jpeg) jpegs[FrameAnalysisCache.Millisecond(item.Observation.Time)] = jpeg;
        }
        if (cache is not null)
        {
            await cache.StoreAsync([.. fresh.Select(item => (item.Requested, item.Observation))], contentKey, pass, ct).ConfigureAwait(false);
            foreach (var item in fresh)
                if (item.Jpeg is { } jpeg) await cache.StoreSheetImageAsync(jpeg, contentKey, item.Observation.Time, ct).ConfigureAwait(false);
        }
        var frames = times.Select(time => found.GetValueOrDefault(FrameAnalysisCache.Millisecond(time))).OfType<FrameObservation>().ToArray();
        return new(frames, times.Count - missing.Count, missing.Count, jpegs);
    }

    /// <summary>The frame sheet of <paramref name="frames"/> (at most <see cref="FrameSheet.MaximumFrames"/>): each frame's JPEG from
    /// <paramref name="fresh"/> or the cache, or one decoded now at the sheet's size and cached.</summary>
    public async Task<FrameSheet> SheetAsync(string source, string contentKey, IReadOnlyList<FrameObservation> frames,
        IReadOnlyDictionary<long, byte[]>? fresh, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(frames);
        var chosen = frames.Take(FrameSheet.MaximumFrames).ToArray();
        var jpegs = new byte[]?[chosen.Length];
        var undecoded = new List<int>();
        for (var offset = 0; offset < chosen.Length; offset++)
        {
            ct.ThrowIfCancellationRequested();
            var time = chosen[offset].Time;
            jpegs[offset] = (fresh is not null && fresh.TryGetValue(FrameAnalysisCache.Millisecond(time), out var made) ? made : null)
                ?? cache?.SheetImage(contentKey, time);
            if (jpegs[offset] is null) undecoded.Add(offset);
        }
        if (undecoded.Count > 0)
        {
            var decoded = await MediaThread.Run("vc-frames-sheet", () =>
            {
                using var reader = decoder.Open(source, FrameSheet.FrameEdge, OpeningTolerance, ct);
                return undecoded.Select(offset =>
                {
                    ct.ThrowIfCancellationRequested();
                    return FrameJpeg.Encode(reader.Read(chosen[offset].Time, ct).Pixels, FrameSheet.FrameEdge);
                }).ToArray();
            }, ct).ConfigureAwait(false);
            for (var index = 0; index < undecoded.Count; index++)
            {
                var offset = undecoded[index];
                jpegs[offset] = decoded[index];
                if (cache is not null) await cache.StoreSheetImageAsync(decoded[index], contentKey, chosen[offset].Time, ct).ConfigureAwait(false);
            }
        }
        var result = new List<FrameSheetFrame>();
        for (var offset = 0; offset < chosen.Length; offset++)
        {
            if (jpegs[offset] is not { } jpeg || FrameJpeg.Size(jpeg) is not { } size) continue;
            result.Add(new FrameSheetFrame(offset + 1, chosen[offset], jpeg, size.Width, size.Height));
        }
        return new FrameSheet(result);
    }

    private sealed record Analyzed(double Requested, FrameObservation Observation, byte[]? Jpeg);

    private async Task<IReadOnlyList<Analyzed>> AnalyzeMissingAsync(string source, IReadOnlyList<double> times, FrameScanKind kind, CancellationToken ct)
    {
        if (times.Count == 0) return [];
        var ordered = times.Order().ToArray();
        var laneCount = Math.Min(Lanes, ordered.Length);
        // Contiguous runs, so each lane's decoder decodes forward through its own stretch of the source.
        var size = (ordered.Length + laneCount - 1) / laneCount;
        var runs = Enumerable.Range(0, (ordered.Length + size - 1) / size).Select(run => ordered.Skip(run * size).Take(size).ToArray()).ToArray();
        using var lanes = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var tasks = runs.Select(run => LaneAsync(source, run, kind, lanes)).ToArray();
        try
        {
            await Task.WhenAll(tasks).ConfigureAwait(false);
        }
        catch
        {
            // A lane's own failure, not the cancellation it caused in the others.
            var failure = tasks.Where(task => task.IsFaulted).Select(task => task.Exception!.InnerException!)
                .FirstOrDefault(exception => exception is not OperationCanceledException);
            if (failure is not null) ExceptionDispatchInfo.Throw(failure);
            ct.ThrowIfCancellationRequested();
            throw;
        }
        return [.. tasks.SelectMany(task => task.Result).OrderBy(item => item.Requested)];
    }

    /// <summary>One lane on its own thread (FFmpeg's contexts belong to the thread that made them): its reader, its own screen scan, and
    /// for each time the decode, the text and screens (sentence frames only), the faces (given the screens) and the sheet JPEG
    /// (sentence frames only).</summary>
    private async Task<IReadOnlyList<Analyzed>> LaneAsync(string source, double[] run, FrameScanKind kind, CancellationTokenSource lanes)
    {
        var ct = lanes.Token;
        var opening = kind == FrameScanKind.Opening;
        try
        {
            return await MediaThread.Run("vc-frames-lane", () =>
            {
                using var reader = decoder.Open(source, AnalysisEdge, Tolerance(kind), ct);
                var screens = laneScreens();
                var results = new List<Analyzed>(run.Length);
                foreach (var time in run)
                {
                    ct.ThrowIfCancellationRequested();
                    var frame = reader.Read(time, ct);
                    // Screens first, so the face path can pass over a face shown on a screen (SpeakerFace).
                    var text = screens.ScanAsync(frame.Pixels, opening, ct).GetAwaiter().GetResult();
                    var found = faces.FacesAsync(frame.Pixels, [.. text.Screens.Select(screen => screen.Rect)], ct).GetAwaiter().GetResult();
                    var observation = text.ApplyTo(found.ApplyTo(new FrameObservation(frame.Time)));
                    var jpeg = opening ? null : FrameJpeg.Encode(frame.Pixels, FrameSheet.FrameEdge);
                    results.Add(new(time, observation, jpeg));
                }
                return (IReadOnlyList<Analyzed>)results;
            }, ct).ConfigureAwait(false);
        }
        catch
        {
            await lanes.CancelAsync().ConfigureAwait(false);
            throw;
        }
    }
}
