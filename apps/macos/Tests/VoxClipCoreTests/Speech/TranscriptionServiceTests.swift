import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite("Speech orchestration", .serialized)
struct TranscriptionServiceTests {
    @Test func applicationWideConcurrencyLimits() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let activity = SpeechJobActivity()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<7 {
                group.addTask {
                    let type: TranscriptEngine = index < 3 ? .whispercpp : .elevenlabs
                    let engine = CountingSpeechEngine(engine: type, activity: activity, waitForConcurrency: true)
                    let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
                    var request = try SpeechTestFiles.request(root.appendingPathComponent("job-\(index)"))
                    request.contentKey = "content-\(index)"
                    request.plan = TranscriptionPlan(engine: type, language: .forced("en"))
                    _ = try await service.transcribe(request, using: engine, envelope: nil)
                }
            }
            try await group.waitForAll()
        }
        #expect(await activity.maximumLocal == 1)
        #expect(await activity.maximumCloud == 2)
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
    func start(_ engine: TranscriptEngine) {
        if engine == .elevenlabs { cloud += 1; maximumCloud = max(maximumCloud, cloud) }
        else { local += 1; maximumLocal = max(maximumLocal, local) }
    }
    func end(_ engine: TranscriptEngine) { if engine == .elevenlabs { cloud -= 1 } else { local -= 1 } }
    func waitForSaturation() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while maximumLocal < 1 || maximumCloud < 2 {
            try #require(ContinuousClock.now < deadline, "Expected one local and two cloud jobs to run concurrently")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct CountingSpeechEngine: Transcriber {
    let engine: TranscriptEngine
    let activity: SpeechJobActivity
    var delay: Duration = .milliseconds(75)
    var waitForConcurrency = false
    func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .native, verbatim: true, autoLanguage: false, onDevice: engine != .elevenlabs) }
    func supports(_ language: LanguageChoice, model: String?) async -> Bool { true }
    func readiness(for plan: TranscriptionPlan) async -> Readiness { .ready }
    func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        await activity.start(engine)
        do {
            if waitForConcurrency { try await activity.waitForSaturation() }
            for index in 0..<1000 { progress(TranscriptionProgress(stage: .transcribing, fraction: Double(index) / 1000)) }
            try await Task.sleep(for: delay)
            await activity.end(engine)
            return RawTranscript(engine: EngineRef(id: engine, engineVersion: "test"), grouping: GroupingRule(end: .lastToken, conf: .single, bracketEvents: false), tokens: [RawToken(text: "hello", start: 0.1, end: 0.4)], language: "en", verbatim: true, timing: .native)
        } catch { await activity.end(engine); throw error }
    }
}
