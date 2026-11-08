import Foundation
import VoxClipCore

/// The whole video's sentence-frame pass (ADR-R48 part 2, ai.md §19.6). It starts as soon as the transcript exists, while
/// Find Clips runs, and looks at one frame per sentence of the whole recording through `FrameAnalyzer` and its cache (about
/// 200 frames for 29 minutes), so a clip's plan later takes its frames without decoding. Each clip's opening scan runs on
/// its own, beside that clip's plan request. A source the analyzer cannot read (no video track, a decode failure) logs one
/// line and every clip goes on as text only: nothing fails.
public actor VideoFramePass {
    /// A clip's frames: its sentence frames (from the pass) and their sheet.
    public struct ClipFrames: Sendable {
        public var sentences: [FrameObservation]
        public var sheet: FrameSheet
    }

    let analyzer: FrameAnalyzer
    let source: URL
    let contentKey: String
    let samples: [FrameSample]
    let log: @Sendable (String) -> Void
    private var pass: Task<Found?, Never>?
    private var openings: [Int: Task<[FrameObservation]?, Never>] = [:]
    /// Wall seconds of the whole pass, once it has run; nil before or after a failure.
    public private(set) var seconds: Double?
    /// When the pass started and ended, seconds from `clock`'s origin, for the CLI's `--timings`.
    public private(set) var started: Double?
    public private(set) var ended: Double?
    /// Frames looked at now and taken from the cache.
    public private(set) var analyzed = 0
    public private(set) var cached = 0

    struct Found: Sendable {
        var frames: [Int: FrameObservation]
        var jpegs: [Int: Data]
    }

    /// `words` are the transcript's; `log` gets the one line a failure writes.
    public init(analyzer: FrameAnalyzer, source: URL, contentKey: String, words: [TimedWord],
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.analyzer = analyzer
        self.source = source
        self.contentKey = contentKey
        self.samples = FrameSampling.videoSamples(words)
        self.log = log
    }

    /// How many sentence frames the pass looks at.
    public nonisolated var frameCount: Int { samples.count }

    /// Starts the pass; later calls do nothing. `clock` stamps `started` and `ended`.
    public func start(clock: ClaudeModeClock? = nil) {
        guard pass == nil else { return }
        started = clock?.elapsed
        let analyzer = analyzer, source = source, contentKey = contentKey, times = samples.map(\.time), log = log
        pass = Task.detached(priority: .utility) { [weak self] in
            let begin = ContinuousClock.now
            do {
                let found = try await analyzer.observations(source: source, contentKey: contentKey, times: times,
                                                            tolerance: FrameAnalyzer.sentenceTolerance, sheet: true)
                var frames: [Int: FrameObservation] = [:]
                for (time, frame) in zip(times, found.frames) { frames[FrameAnalysisCache.millisecond(time)] = frame }
                await self?.finished(seconds: FrameAnalyzer.seconds(begin.duration(to: .now)), clock: clock,
                                     analyzed: found.analyzed, cached: found.cached)
                return Found(frames: frames, jpegs: found.jpegs)
            } catch is CancellationError {
                return nil
            } catch {
                log("frames: the video's frames can't be read, so plans go as text only (\(type(of: error)))")
                await self?.finished(seconds: nil, clock: clock, analyzed: 0, cached: 0)
                return nil
            }
        }
    }

    private func finished(seconds: Double?, clock: ClaudeModeClock?, analyzed: Int, cached: Int) {
        self.seconds = seconds
        self.analyzed = analyzed
        self.cached = cached
        ended = clock?.elapsed
        if let clock, let started, seconds != nil { clock.record(.frames, since: started) }
    }

    /// Waits for the pass (starting it if it has not started); false when the source could not be read.
    @discardableResult public func finish() async -> Bool { await found() != nil }

    private func found() async -> Found? {
        if pass == nil { start() }
        return await pass?.value
    }

    /// A clip's sentence frames, at most 24 evenly spread, from the pass (`FrameSampling.clipSamples`), with their sheet.
    /// Waits for the pass when it is still running. Nil when the source cannot be read.
    public func frames(for clip: FrameClip) async -> ClipFrames? {
        guard let found = await found() else { return nil }
        let wanted = FrameSampling.clipSamples(samples, clip: clip)
        var frames: [FrameObservation] = []
        var missing: [Double] = []
        for sample in wanted {
            if let frame = found.frames[FrameAnalysisCache.millisecond(sample.time)] { frames.append(frame) } else { missing.append(sample.time) }
        }
        var jpegs = found.jpegs
        do {
            if !missing.isEmpty {
                // A clip inside one long sentence: its own sentence frames, looked at now (and cached).
                let extra = try await analyzer.observations(source: source, contentKey: contentKey, times: missing,
                                                            tolerance: FrameAnalyzer.sentenceTolerance, sheet: true)
                frames = (frames + extra.frames).sorted { $0.time < $1.time }
                jpegs.merge(extra.jpegs) { first, _ in first }
            }
            let sheet = try await analyzer.sheet(source: source, contentKey: contentKey, frames: frames, fresh: jpegs)
            return ClipFrames(sentences: frames, sheet: sheet)
        } catch {
            log("frames: a clip's frames can't be read, so its plan goes as text only (\(type(of: error)))")
            return nil
        }
    }

    /// The clip's opening scan (10 fps over ±0.6 s at its first kept word), started once per start time: the plan's
    /// request asks for it as it is sent and the apply waits for it. Nil when the frames cannot be read.
    public func opening(for clip: FrameClip) async -> [FrameObservation]? {
        let key = FrameAnalysisCache.millisecond(clip.start)
        if let running = openings[key] { return await running.value }
        let analyzer = analyzer, source = source, contentKey = contentKey, log = log
        let times = FrameSampling.openingTimes(start: clip.start)
        let task = Task.detached(priority: .userInitiated) { () -> [FrameObservation]? in
            do {
                return try await analyzer.observations(source: source, contentKey: contentKey, times: times,
                                                       tolerance: FrameAnalyzer.openingTolerance).frames
            } catch {
                if !(error is CancellationError) { log("frames: a clip's opening can't be read (\(type(of: error)))") }
                return nil
            }
        }
        openings[key] = task
        return await task.value
    }

    /// Starts the opening scan without waiting for it.
    public func startOpening(for clip: FrameClip) {
        let key = FrameAnalysisCache.millisecond(clip.start)
        guard openings[key] == nil else { return }
        Task { _ = await self.opening(for: clip) }
    }

    /// Small JPEGs of the frames at `times` (the sheet's size, cached), for the review's thumbnails; empty when they can't
    /// be read.
    public func thumbnails(_ times: [Double]) async -> [Data] {
        let frames = times.map { FrameObservation(time: $0) }
        guard let sheet = try? await analyzer.sheet(source: source, contentKey: contentKey, frames: frames) else { return [] }
        return sheet.frames.map(\.image.data)
    }

    /// Stops the pass and every opening scan.
    public func cancel() {
        pass?.cancel()
        for task in openings.values { task.cancel() }
    }
}
