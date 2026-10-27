import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite("Speech orchestration", .serialized, .timeLimit(.minutes(1)))
struct TranscriptionServiceTests {
    /// Seven services share one queue: one local and two cloud jobs run together, the others wait,
    /// and each finished job hands its slot to the oldest waiter of its kind; transcription §13.4.
    /// Jobs stay in their engines until the test lets them go, so no step races a clock, and a
    /// private gate keeps the ElevenLabs suites running in parallel out of the shared slots.
    @Test func applicationWideConcurrencyLimits() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = SpeechJobGate()
        let activity = SpeechJobActivity()
        let local = Set(0..<3)
        func job(_ key: String) -> Int? { (0..<7).first { key.contains("/content-\($0)/") } }
        /// Every unfinished job is in an engine or queued, and every admitted job has reached its engine.
        func settled(_ unfinished: Int) async -> Bool {
            let state = await gate.snapshot(), running = await activity.running
            return state.local + state.cloud == running.count && running.count + state.waiting.count == unfinished
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<7 {
                let type: TranscriptEngine = local.contains(index) ? .whispercpp : .elevenlabs
                let engine = CountingSpeechEngine(engine: type, activity: activity, delay: .zero, job: index, holdUntilFinished: true)
                let service = TranscriptionService(locations: SpeechTestFiles.locations(root), gate: gate)
                var request = try SpeechTestFiles.request(root.appendingPathComponent("job-\(index)"))
                request.contentKey = "content-\(index)"
                request.plan = TranscriptionPlan(engine: type, language: .forced("en"))
                let value = request
                group.addTask { _ = try await service.transcribe(value, using: engine, envelope: nil) }
            }
            var finished: Set<Int> = []
            var handOff: (running: [Int], next: Int?)?
            while finished.count < 7 {
                try await SpeechTestWait.until { await settled(7 - finished.count) }
                let running = await activity.running, waiting = await gate.snapshot().waiting.compactMap(job)
                let left = Set(0..<7).subtracting(finished)
                #expect(running.filter(local.contains).count == min(1, left.filter(local.contains).count))
                #expect(running.filter { !local.contains($0) }.count == min(2, left.filter { !local.contains($0) }.count))
                if let handOff { #expect(Set(running).subtracting(handOff.running) == Set([handOff.next].compactMap { $0 })) }
                guard let next = running.first else { group.cancelAll(); break }
                handOff = (running, waiting.first { local.contains($0) == local.contains(next) })
                finished.insert(next)
                await activity.finish(next)
            }
            try await group.waitForAll()
        }
        #expect(await activity.maximumLocal == 1)
        #expect(await activity.maximumCloud == 2)
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 0, waiting: []))
        #expect(await TranscriptionService().gate === SpeechJobGate.shared)
        #expect(await TranscriptionService(locations: SpeechTestFiles.locations(root)).gate === SpeechJobGate.shared)
    }

    /// A queued job that is cancelled never reaches its engine, and a failed job hands its slot on;
    /// transcription §13.2 and §13.4.
    @Test func cancelledQueuedAndFailedJobsGiveBackTheirPlaces() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = SpeechJobGate()
        let activity = SpeechJobActivity()
        func submit(_ index: Int, hold: Bool = false, fails: Bool = false) throws -> Task<Transcript, any Error> {
            let engine = CountingSpeechEngine(engine: .whispercpp, activity: activity, delay: .zero, job: index, holdUntilFinished: hold, fails: fails)
            let service = TranscriptionService(locations: SpeechTestFiles.locations(root), gate: gate)
            var request = try SpeechTestFiles.request(root.appendingPathComponent("job-\(index)"))
            request.contentKey = "content-\(index)"
            request.plan = TranscriptionPlan(engine: .whispercpp, language: .forced("en"))
            let value = request
            return Task { try await service.transcribe(value, using: engine, envelope: nil) }
        }
        let running = try submit(0, hold: true)
        try await SpeechTestWait.until { await activity.running == [0] }
        let cancelled = try submit(1)
        try await SpeechTestWait.until { await gate.snapshot().waiting.count == 1 }
        let failing = try submit(2, fails: true)
        try await SpeechTestWait.until { await gate.snapshot().waiting.count == 2 }
        cancelled.cancel()
        do { _ = try await SpeechTestWait.value(cancelled); Issue.record("Expected cancellation") }
        catch let error as VoxClipError { #expect(error.code == .cancelled) }
        #expect(await gate.snapshot().waiting.count == 1)
        await activity.finish(0)
        _ = try await SpeechTestWait.value(running)
        await #expect(throws: VoxClipError.transcriptionFailed("Synthetic engine failure")) { try await SpeechTestWait.value(failing) }
        _ = try await SpeechTestWait.value(submit(3))
        #expect(await activity.started == [0, 2, 3])
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 0, waiting: []))
    }

    /// Identical jobs in one data folder run one at a time and the second reads the first one's
    /// cache entry, while the same job for another data folder starts at once; transcription §13.4.
    @Test func identicalJobsWaitForEachOtherOnlyInOneDataFolder() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: elsewhere) }
        let gate = SpeechJobGate()
        let activity = SpeechJobActivity()
        let request = try SpeechTestFiles.request(root)
        func submit(_ index: Int, in folder: URL, hold: Bool = true) -> Task<TranscriptionResult, any Error> {
            let engine = CountingSpeechEngine(engine: .elevenlabs, activity: activity, delay: .zero, job: index, holdUntilFinished: hold)
            let service = TranscriptionService(locations: SpeechTestFiles.locations(folder), gate: gate)
            return Task { try await service.transcribeResult(request, using: engine, envelope: nil) }
        }
        let first = submit(0, in: root)
        try await SpeechTestWait.until { await activity.running == [0] }
        // Not held, so a cache miss fails the expectations below instead of the time limit.
        let duplicate = submit(1, in: root, hold: false)
        try await SpeechTestWait.until { await gate.snapshot().waiting.count == 1 }
        // The duplicate waits although a cloud slot is free, and the job for the other folder takes it.
        #expect(await gate.snapshot().cloud == 1)
        let other = submit(2, in: elsewhere)
        try await SpeechTestWait.until { await activity.running == [0, 2] }
        let waiting = await gate.snapshot().waiting
        #expect(waiting.count == 1 && waiting.allSatisfy { $0.hasPrefix(SpeechTestFiles.locations(root).cache.path + "/") })
        await activity.finish(0)
        #expect(try await SpeechTestWait.value(first).fromCache == false)
        #expect(try await SpeechTestWait.value(duplicate).fromCache)
        await activity.finish(2)
        #expect(try await SpeechTestWait.value(other).fromCache == false)
        #expect(await activity.started == [0, 2])
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 0, waiting: []))
    }

    @Test func cancellationReleasesGlobalSlotAndDoesNotCache() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let activity = SpeechJobActivity()
        let engine = CountingSpeechEngine(engine: .whispercpp, activity: activity, delay: .seconds(10))
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        var request = try SpeechTestFiles.request(root)
        request.plan = TranscriptionPlan(engine: .whispercpp, language: .forced("en"))
        let value = request
        let job = Task { try await service.transcribe(value, using: engine, envelope: nil) }
        while await activity.local == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let clock = ContinuousClock.now
        job.cancel()
        do { _ = try await job.value; Issue.record("Expected cancellation") }
        catch let error as VoxClipError { #expect(error.code == .cancelled) }
        #expect(clock.duration(to: .now) < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Cache/synthetic-content/transcripts").path))
        let replacement = CountingSpeechEngine(engine: .whispercpp, activity: activity)
        _ = try await service.transcribe(value, using: replacement, envelope: nil)
        #expect(await activity.local == 0)
    }

    @Test func sameProjectRejectsOverlappingJobAndProgressIsThrottled() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let activity = SpeechJobActivity()
        let engine = CountingSpeechEngine(engine: .whispercpp, activity: activity, delay: .milliseconds(150))
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        var request = try SpeechTestFiles.request(root)
        request.plan = TranscriptionPlan(engine: .whispercpp, language: .forced("en"))
        let value = request
        let stream = await service.progress()
        let events = Task { var values: [TranscriptionProgress] = []; for await event in stream { values.append(event) }; return values }
        let job = Task { try await service.transcribe(value, using: engine, envelope: nil) }
        while await activity.local == 0 { try await Task.sleep(for: .milliseconds(5)) }
        do { _ = try await service.transcribe(value, using: engine, envelope: nil); Issue.record("Expected overlapping-job rejection") }
        catch let error as VoxClipError { #expect(error.code == .transcriptionFailed) }
        let result = try await job.value
        #expect(!result.refined)
        #expect(result.words.map(\.id) == ["w1"])
        let values = await events.value
        #expect((3...4).contains(values.count))
        #expect(values.first?.stage == .preparing)
        #expect(values.contains { $0.stage == .transcribing })
        #expect(values.last?.stage == .aligning && values.last?.fraction == 1)
    }

    @Test(arguments: [false, true])
    func nonWordResultsAreNoSpeech(_ withUnlabeledSpeech: Bool) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = CountingSpeechEngine(engine: .whispercpp, activity: SpeechJobActivity(), delay: .zero, kind: .event, verbatim: !withUnlabeledSpeech)
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        var request = try SpeechTestFiles.request(root)
        request.plan = TranscriptionPlan(engine: .whispercpp, language: .forced("en"))
        let value = request
        var levels = [Float](repeating: 0, count: 400)
        for index in 10..<40 { levels[index] = 1 }
        for index in 100..<200 { levels[index] = 1 }
        let envelope = withUnlabeledSpeech ? AudioEnvelope(sampleRate: 16000, levels: levels) : nil
        if withUnlabeledSpeech {
            let imported = try SpeechEditingImportAdapter.pipeline([RawWord(text: "hello", start: 0.1, end: 0.4, kind: .event)], envelope: envelope, timing: .native, verbatim: false, duration: 4)
            #expect(imported.words.contains { $0.kind == .unlabeledSpeech })
            #expect(!imported.words.contains { $0.kind == .word })
        }
        for _ in 0..<2 {
            await #expect(throws: VoxClipError.noSpeech) { try await service.transcribe(value, using: engine, envelope: envelope) }
        }
    }

    @Test(arguments: [false, true])
    func localForcedLanguageIsNormalizedBeforeEngineAndCache(_ injectCatalog: Bool) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let activity = SpeechJobActivity()
        let engine = CountingSpeechEngine(engine: .whispercpp, activity: activity, delay: .zero)
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root), catalog: injectCatalog ? try SpeechTestFiles.catalog() : nil)
        var rawKey: String?
        for alias in ["est", "et", "EST-ee"] {
            var request = try SpeechTestFiles.request(root)
            request.plan = TranscriptionPlan(engine: .whispercpp, language: .forced(alias))
            let transcript = try await service.transcribe(request, using: engine, envelope: nil)
            if let rawKey { #expect(transcript.rawKey == rawKey) }
            else { rawKey = transcript.rawKey }
        }
        #expect(await activity.languages == [.forced("et")])
    }

    @Test func keySeparatesOptionsAndAudioTracks() throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var request = try SpeechTestFiles.request(root)
        let identity = EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2")
        let original = try SpeechRawCacheKey(request: request, identity: identity).digest()
        request.plan.options.diarize = true
        #expect(try SpeechRawCacheKey(request: request, identity: identity).digest() != original)
        request.plan.options.diarize = false
        request.audio.audioTrackIndex = 1
        #expect(try SpeechRawCacheKey(request: request, identity: identity).digest() != original)
    }
}

private actor SpeechJobActivity {
    var local = 0
    var cloud = 0
    var maximumLocal = 0
    var maximumCloud = 0
    var languages: [LanguageChoice] = []
    /// Jobs that reached an engine, and the ones still inside, oldest first.
    var started: [Int] = []
    var running: [Int] = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Records the start; a held job then stays in its engine until `finish(_:)`, or until the
    /// suite time limit cancels the test, so a scheduling bug fails the test instead of hanging it.
    func start(_ engine: TranscriptEngine, language: LanguageChoice, job: Int, hold: Bool) async {
        languages.append(language)
        started.append(job)
        running.append(job)
        if engine == .elevenlabs { cloud += 1; maximumCloud = max(maximumCloud, cloud) }
        else { local += 1; maximumLocal = max(maximumLocal, local) }
        guard hold else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { held[job] = $0 }
        } onCancel: {
            Task { await self.finish(job) }
        }
    }
    func finish(_ job: Int) { held.removeValue(forKey: job)?.resume() }
    func end(_ engine: TranscriptEngine, job: Int) {
        running.removeAll { $0 == job }
        if engine == .elevenlabs { cloud -= 1 } else { local -= 1 }
    }
}

private struct CountingSpeechEngine: Transcriber {
    let engine: TranscriptEngine
    let activity: SpeechJobActivity
    var delay: Duration = .milliseconds(75)
    var job = 0
    var holdUntilFinished = false
    var fails = false
    var kind: WordKind = .word
    var verbatim = true
    func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .native, verbatim: true, autoLanguage: false, onDevice: engine != .elevenlabs) }
    func supports(_ language: LanguageChoice, model: String?) async -> Bool { true }
    func readiness(for plan: TranscriptionPlan) async -> Readiness { .ready }
    func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        await activity.start(engine, language: request.plan.language, job: job, hold: holdUntilFinished)
        do {
            if fails { throw VoxClipError.transcriptionFailed("Synthetic engine failure") }
            for index in 0..<1000 { progress(TranscriptionProgress(stage: .transcribing, fraction: Double(index) / 1000)) }
            try await Task.sleep(for: delay)
            await activity.end(engine, job: job)
            return RawTranscript(engine: EngineRef(id: engine, modelId: engine == .elevenlabs ? "scribe_v2" : nil, engineVersion: "test"), grouping: GroupingRule(end: .lastToken, conf: .single, bracketEvents: false), tokens: [RawToken(text: "hello", start: 0.1, end: 0.4, kind: kind)], language: "en", verbatim: verbatim, timing: .native)
        } catch { await activity.end(engine, job: job); throw error }
    }
}
