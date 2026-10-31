#if DEBUG
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

private final class TakeRunClock: Sendable {
    let date = Mutex(Date())
    let time = Mutex<Duration>(.zero)
    func now() -> Date { date.withLock { $0 } }
    func elapsed() -> Duration { time.withLock { $0 } }
    func advance(_ seconds: Double) { date.withLock { $0.addTimeInterval(seconds) }; time.withLock { $0 += .seconds(seconds) } }
    /// Moves only the monotonic clock that quote expiry reads, so the ledger month stays put.
    func elapse(_ seconds: Double) { time.withLock { $0 += .seconds(seconds) } }
    func rewindWall() { date.withLock { $0.addTimeInterval(-3_600) } }
}

@MainActor private final class TakeRunPlayback: VoiceLabAuditionBackend {
    var position = 0.0
    var stopped = false
    func play() -> Bool { true }
    func stop() { stopped = true }
}
@MainActor private final class TakeRunApproval {
    var scratch: VoiceLabTakeScratch?
    var audition: VoiceLabAudition?
    var ledger: VoiceLabSpendLedger?
    var estimate: Decimal?
    var approved = true
    var confirmations = 0
    private var confirmed = false
    func dispatch(_ start: @escaping @Sendable () throws -> Void) async throws {
        if let ledger, let total = await ledger.total(provider: "elevenlabs", at: Date()),
           total.usd + (estimate ?? 0) > 1, !confirmed {
            confirmations += 1
            if confirmations == 1 || !approved {
                #expect(scratch?.isValid == true && audition?.isPlaying == true)
            }
            guard approved else { throw CancellationError() }
            confirmed = true
        }
        try start()
    }
}
private final class TakeRunDispatchSignal: Sendable {
    private struct State {
        var fired = false
        var cancelled = false
        var continuation: CheckedContinuation<Void, any Error>?
    }
    private let value = Mutex(State())
    func fire() {
        let continuation = value.withLock { state in
            state.fired = true
            let result = state.continuation; state.continuation = nil
            return result
        }
        continuation?.resume(returning: ())
    }
    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome = value.withLock { state -> Int in
                    if state.cancelled { return -1 }
                    if state.fired { return 1 }
                    state.continuation = continuation
                    return 0
                }
                if outcome == 1 { continuation.resume(returning: ()) }
                else if outcome == -1 { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.value.withLock { state in
                state.cancelled = true
                let result = state.continuation; state.continuation = nil
                return result
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
private actor TakeRunSuspension {
    nonisolated let reached = TakeRunDispatchSignal()
    private var continuation: CheckedContinuation<Void, Never>?
    private var calls = 0
    func pause(on ordinal: Int) async {
        calls += 1
        if calls == ordinal { await pause() }
    }
    func pause() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; reached.fire() }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private final class TakeRunHTTP: Sendable {
    struct State: Sendable {
        var seeds: [UInt32] = []
        var contexts: [[String: String]] = []
        var qa = 0
        var qaWAVs: [Data] = []
        var firstStatus = 200
        var mismatchCount = 0
        var duration = 4.0
        var missingAlignment = false
        var remoteRequiresVerification = false
        var malformedAlignment = false
        /// Scribe answers 200 with no words, after the spend ledger has recorded the QA request.
        var malformedQA = false
        var current = true
        var paused = false
        var entered = false
    }
    let value: Mutex<State>
    init(_ initial: State) { value = Mutex(initial) }
    let gate = DispatchSemaphore(value: 0)
    let dispatched = TakeRunDispatchSignal()
}
private actor TakeRunEmbedder: SpeakerEmbedder {
    nonisolated let modelID = "fixture-calibrated"
    nonisolated let dimension = 2
    let drift: Bool
    var calls = 0
    var streams = 0
    init(drift: Bool) { self.drift = drift }
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { streams += 1; return pcm16k }
    func embed(_ pcm16k: [Float]) async throws -> [Float] {
        calls += 1
        return drift && streams > 1 ? [0, 1] : [1, 0]
    }
}

@Suite("Bounded take run", .serialized, .timeLimit(.minutes(2)))
struct VoiceLabTakeRunTests {
    private struct Fixture {
        let root: URL
        let http: TakeRunHTTP
        let clock: TakeRunClock
        let store: VoiceConsentStore
        let client: ElevenLabsVoiceLab
        let ledger: VoiceLabSpendLedger
        let run: VoiceLabTakeRun
        let input: VoiceLabTakeInput
        /// A second window's run on the same client, store and speaker check, and its input over the word "last".
        let later: VoiceLabTakeRun
        let laterInput: VoiceLabTakeInput
    }
    private func fixture(_ configure: @Sendable (inout TakeRunHTTP.State) -> Void = { _ in }, drift: Bool = false,
                         sourceAudible: Bool = true, roomToneAvailable: Bool = true,
                         boundary: VoiceLabDispatchBoundary? = nil) async throws -> Fixture {
        let root = try SpeechTestFiles.directory()
        let locations = SpeechTestFiles.locations(root)
        let store = VoiceConsentStore(locations: locations)
        let wav = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 4_000)
        var object = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
        var statement = try #require(object["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); object["statement"] = statement
        var speaker = try #require(object["speaker"] as? [String: Any]); speaker["threshold"] = 0.45; object["speaker"] = speaker
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        var initial = TakeRunHTTP.State(); configure(&initial)
        let http = TakeRunHTTP(initial)
        let base = SpeechStubHTTP.register { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/models"):
                return (200, [:], Data(#"[{"model_id":"eleven_v3","name":"Speech","can_do_text_to_speech":true,"can_do_voice_conversion":false,"languages":[{"language_id":"en"}],"maximum_text_length_per_request":5000}]"#.utf8))
            case ("GET", "/v2/voices"):
                let requiresVerification = http.value.withLock { $0.remoteRequiresVerification }
                let row: [String: Any] = ["voice_id": "fixtureOwnVoice", "name": "My voice", "category": "cloned", "is_owner": true,
                    "voice_verification": ["requires_verification": requiresVerification, "is_verified": false]]
                return (200, [:], try JSONSerialization.data(withJSONObject: ["voices": [row], "has_more": false]))
            case ("POST", "/v1/text-to-speech/fixtureOwnVoice/with-timestamps"):
                let body = try #require(JSONSerialization.jsonObject(with: VoiceLabRequestFixtures.body(request)) as? [String: Any])
                let seed = try #require(body["seed"] as? UInt32)
                let state = http.value.withLock { state in
                    state.seeds.append(seed); state.contexts.append(["previous": body["previous_text"] as? String ?? "", "next": body["next_text"] as? String ?? ""])
                    state.entered = true
                    return state
                }
                http.dispatched.fire()
                if state.paused { http.gate.wait() }
                if state.seeds.count == 1 && state.firstStatus != 200 { return (state.firstStatus, [:], Data()) }
                var pcm = Data()
                let frames = Int(state.duration * 24_000)
                for index in 0..<frames {
                    var value = Int16((sin(2 * Double.pi * 100 * Double(index) / 24_000) * 3_200).rounded()).littleEndian
                    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
                }
                let characters = Array("Hello").map(String.init)
                let starts = characters.indices.map { 0.1 + Double($0) * (state.duration - 0.2) / 5 }
                let ends = characters.indices.map { 0.1 + Double($0 + 1) * (state.duration - 0.2) / 5 }
                let alignment: Any = state.missingAlignment ? NSNull() : ["characters": characters, "character_start_times_seconds": state.malformedAlignment ? Array(starts.dropLast()) : starts, "character_end_times_seconds": ends]
                return (200, [:], try JSONSerialization.data(withJSONObject: ["audio_base64": pcm.base64EncodedString(), "alignment": alignment]))
            case ("POST", "/v1/speech-to-text"):
                let bytes = try VoiceLabRequestFixtures.body(request)
                let body = String(decoding: bytes, as: UTF8.self)
                let start = try #require(bytes.range(of: Data("RIFF".utf8))?.lowerBound)
                let size = bytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: start + 4, as: UInt32.self))) }
                let wave = bytes.subdata(in: start..<(start + size + 8))
                http.value.withLock { $0.qaWAVs.append(wave) }
                for (field, value) in [("model_id", "scribe_v2"), ("language_code", "en"), ("diarize", "false"), ("tag_audio_events", "false"), ("timestamps_granularity", "word")] {
                    #expect(body.contains("name=\"\(field)\"\r\n\r\n\(value)\r\n"))
                }
                let state = http.value.withLock { $0.qa += 1; return $0 }
                if state.malformedQA { return (200, [:], Data(#"{"language_code":"eng"}"#.utf8)) }
                let text = state.qa <= state.mismatchCount ? "different" : "Hello"
                return (200, [:], try JSONSerialization.data(withJSONObject: ["language_code": "eng", "words": [["type": "word", "text": text, "start": 0.65, "end": state.duration + 0.35]]]))
            default: Issue.record("Unexpected take-run request"); return (500, [:], Data())
            }
        }
        let ledger = VoiceLabSpendLedger(locations: locations)
        let client = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-take-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)),
            prices: VoiceLabPricingTests.catalogIfPresent, spend: ledger, enforceCapabilities: true)
        let clock = TakeRunClock(); await client.useClock({ clock.now() }, monotonic: { clock.elapsed() })
        let speakerCheck = VoiceSpeakerCheck(embedder: TakeRunEmbedder(drift: drift), calibratedThreshold: 0.45)
        let storage = VoiceLabTakeStorage(projectId: UUID().uuidString.lowercased(), paidRoot: root.appendingPathComponent("VoiceLab"), scratchRoot: root.appendingPathComponent("scratch"))
        let makeRun: () -> VoiceLabTakeRun = {
            VoiceLabTakeRun(client: client, store: store, speaker: speakerCheck, storage: storage, dispatchIfCurrent: { start in
                if let boundary { try await boundary(start); return }
                try http.value.withLock { state in
                    guard state.current else { throw VoiceLabError.consentRequired }
                    try start()
                }
            }) { http.value.withLock { $0.current } }
        }
        let run = makeRun(), later = makeRun()
        let choices = try await run.discover(language: "en")
        #expect(choices.voices.map(\.id) == (initial.remoteRequiresVerification ? [] : [record.id]))
        let rate = 24_000
        let source: [Float] = (0..<(8 * rate)).map { index in
            let seconds = Double(index) / Double(rate)
            let quiet = (1.9..<2.1).contains(seconds) || (5.9..<6.1).contains(seconds) || (6.5..<7.1).contains(seconds)
            return !sourceAudible ? 0 : quiet ? 0.001 : Float(0.1 * sin(2 * Double.pi * 100 * seconds))
        }
        var items = [TimedWord(id: "before", text: "before", kind: .word, start: 0, end: 1.9),
                     TimedWord(id: "old", text: "old", kind: .word, start: 2.1, end: 5.9),
                     TimedWord(id: "after", text: "after", kind: .word, start: 6.1, end: 6.5),
                     TimedWord(id: "last", text: "last", kind: .word, start: 7.1, end: 7.9)]
        if !roomToneAvailable {
            items.append(TimedWord(id: "gap", text: "gap", start: 6.5, end: 7.1))
            items.sort { $0.start < $1.start }
        }
        let window = VoiceLabWindow(firstWordId: "old", lastWordId: "old", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 2, end: 6,
            startSample: 48_000, endSample: 144_000, leftSeam: .init(kind: .hard, time: 2, sample: 48_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 6, sample: 144_000, fadeSamples: 288))
        let input = VoiceLabTakeInput(text: "Hello", modelID: "eleven_v3", recordID: record.id, language: "en", seed: UInt32.max,
            contentKey: "synthetic-source", source: source, sourceSampleRate: rate, items: items, window: window,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let lastWindow = VoiceLabWindow(firstWordId: "last", lastWordId: "last", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 7, end: 8,
            startSample: 168_000, endSample: 192_000, leftSeam: .init(kind: .hard, time: 7, sample: 168_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 8, sample: 192_000, fadeSamples: 288))
        let laterInput = VoiceLabTakeInput(text: "Hello", modelID: "eleven_v3", recordID: record.id, language: "en", seed: 7,
            contentKey: "synthetic-source", source: source, sourceSampleRate: rate, items: items, window: lastWindow,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        return Fixture(root: root, http: http, clock: clock, store: store, client: client, ledger: ledger, run: run, input: input,
                       later: later, laterInput: laterInput)
    }
    @Test(arguments: ["clock", "inputs", "model", "embedder", "consent", "record", "validation", "approval", "launch"])
    func cancellationAtEveryExecuteSuspension(point: String) async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let suspension = TakeRunSuspension()
        await fixture.run.useExecuteHook { if $0 == point { await suspension.pause() } }
        let sending = Task { try await fixture.run.execute(quote, approved: true) }
        try await suspension.reached.wait()
        await fixture.run.cancel()
        await suspension.release()
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == 0)
    }
    @Test(arguments: [299.0, 300.0, 301.0]) func expiryIgnoresBackwardWallClock(seconds: Double) async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        fixture.clock.advance(seconds)
        fixture.clock.rewindWall()
        #expect(fixture.clock.now() < quote.preparedAt)
        if seconds < 300 {
            _ = try await fixture.run.execute(quote, approved: true)
            #expect(fixture.http.value.withLock { $0.seeds.count == 1 })
        } else {
            await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(quote, approved: true) }
            #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        }
    }
    @Test(arguments: ["clock", "approval"]) func concurrentExecuteCannotDiscardOwnerQuotes(point: String) async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let suspension = TakeRunSuspension()
        await fixture.run.useExecuteHook { if $0 == point { await suspension.pause() } }
        let owner = Task { try await fixture.run.execute(quote, approved: true) }
        try await suspension.reached.wait()
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(quote, approved: true) }
        #expect(await fixture.client.quotesAreFresh(quote.takes.flatMap { [$0.synthesis, $0.qa] }))
        await suspension.release()
        let result = try await owner.value
        #expect(result.end == .earlyStop)
        #expect(fixture.http.value.withLock { $0.seeds.count == 1 && $0.qa == 1 })
    }
    @Test(arguments: [false, true]) func inputChangeAtTransportBoundary(invalidate: Bool) async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let suspension = TakeRunSuspension()
        await fixture.client.useDispatchHook { await suspension.pause() }
        let sending = Task { try await fixture.run.execute(quote, approved: true) }
        try await suspension.reached.wait()
        if invalidate { await fixture.run.invalidate() }
        else { fixture.http.value.withLock { $0.current = false } }
        await suspension.release()
        _ = try await sending.value
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
    }
    @Test(arguments: [false, true]) func withdrawalWinsBetweenValidationAndTransport(deleting: Bool) async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let suspension = TakeRunSuspension()
        await fixture.client.useDispatchHook { await suspension.pause() }
        let sending = Task { try await fixture.run.execute(quote, approved: true) }
        try await suspension.reached.wait()
        if deleting { _ = try await fixture.store.beginDeletion(fixture.input.recordID, region: .default, at: Date()) }
        else {
            await #expect(throws: VoiceConsentError.inactive) { try await fixture.store.withdrawCreation(recordID: fixture.input.recordID, remoteVoiceID: "fixtureOwnVoice") }
            _ = try await fixture.store.beginDeletion(fixture.input.recordID, region: .default, at: Date())
        }
        await suspension.release()
        _ = try await sending.value
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
    }
    @Test func withdrawalMarksAnAlreadyStartedDispatchAmbiguous() async throws {
        let fixture = try await fixture { $0.paused = true }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let sending = Task { try await fixture.run.execute(quote, approved: true) }
        defer { sending.cancel(); fixture.http.gate.signal() }
        try await fixture.http.dispatched.wait()
        let operation = try await fixture.store.beginDeletion(fixture.input.recordID, region: .default, at: Date())
        let persisted = try await fixture.store.operation(operation.id)
        #expect(persisted.ambiguousDispatchIDs == [quote.takes[0].synthesis.requestID])
        fixture.http.gate.signal()
        _ = try await sending.value
        #expect(fixture.http.value.withLock { $0.seeds.count == 1 && $0.qa == 0 })
    }
    @Test func oneApprovalStopsAfterFirstPassingFitAndCannotReplay() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        #expect(quote.takes.count == 3 && quote.takes.map(\.seed) == [UInt32.max, 0, 1])
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == 0)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.end == .earlyStop && result.rows.count == 1, "Failures: \(result.rows.map(\.failure))")
        #expect(result.best?.selectable == true && result.best?.fits == true)
        #expect(result.best?.audio?.words.allSatisfy(\.synthetic) == true)
        #expect(result.best?.generated != nil && result.best?.qaReceipt != nil)
        #expect(result.best?.audio?.trimmed.count == 93_360)
        #expect(result.best?.audio?.fit.plan.outputFrames == 96_000)
        #expect(result.best?.audio?.roomTone?.sourceStartSample == 156_000)
        #expect(fixture.http.value.withLock { $0.seeds == [UInt32.max] && $0.qa == 1 })
        #expect(fixture.http.value.withLock { $0.contexts.first?["previous"] == "" && $0.contexts.first?["next"] == "" })
        let amount = (quote.takes[0].synthesis.estimate.usd ?? 0) + (quote.takes[0].qa.estimate.usd ?? 0)
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == amount)
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(quote, approved: true) }
        #expect(fixture.http.value.withLock { $0.seeds.count } == 1)
    }
    @Test func freshWholeRunQuotePreservesAuditionUntilReplacementStarts() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initial = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(initial, approved: true)
        let row = try #require(result.best)
        let scratch = try #require(await fixture.run.scratch(for: row.id))
        await fixture.run.cancel(keepingTakes: true)
        let quote = try await fixture.run.prepare(fixture.input)
        #expect(quote.id != initial.id && quote.takes.map(\.index) == [0, 1, 2])
        #expect(scratch.isValid && FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(quote, approved: false) }
        #expect(scratch.isValid && fixture.http.value.withLock { $0.seeds.count == 1 })
        let next = try await fixture.run.execute(quote, approved: true)
        #expect(!scratch.isValid && next.rows.first?.index == 0)
        await fixture.run.invalidate()
    }
    @Test @MainActor func refusedReplacementLaunchRetainsScratchSnapshotAndAudition() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initial = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(initial, approved: true)
        let row = try #require(result.best)
        let scratch = try #require(await fixture.run.scratch(for: row.id))
        let backend = TakeRunPlayback()
        let audition = VoiceLabAudition(makeBackend: { _, _ in backend })
        try audition.play(scratch, takeId: row.id, selectionId: "previous")
        let replacement = try await fixture.run.prepare(fixture.input)
        await #expect(throws: CancellationError.self) {
            try await fixture.run.execute(replacement, approved: true, started: { throw CancellationError() })
        }
        #expect(scratch.isValid && FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
        #expect(audition.isPlaying && audition.takeId == row.id && !backend.stopped)
        #expect(fixture.http.value.withLock { $0.seeds.count == 1 && $0.qa == 1 })
        let next = try await fixture.run.prepare(fixture.input)
        #expect(next.id != replacement.id)
        await fixture.run.invalidate()
        #expect(backend.stopped && !audition.isPlaying && !scratch.isValid)
    }
    @Test(arguments: [false, true]) @MainActor
    func firstTransportApprovalRetainsPlayingScratchUntilRequestStarts(approved: Bool) async throws {
        let suspension = TakeRunSuspension()
        let approvals = TakeRunApproval()
        let fixture = try await fixture(boundary: { start in try await approvals.dispatch(start) })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initial = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(initial, approved: true)
        let row = try #require(result.best)
        let scratch = try #require(await fixture.run.scratch(for: row.id))
        let backend = TakeRunPlayback(), audition = VoiceLabAudition(makeBackend: { _, _ in backend })
        try audition.play(scratch, takeId: row.id, selectionId: "prior")
        let replacement = try await fixture.run.prepare(fixture.input)
        approvals.scratch = scratch; approvals.audition = audition
        approvals.ledger = fixture.ledger; approvals.estimate = replacement.estimate.usd
        approvals.approved = approved
        await fixture.client.useDispatchHook {
            await suspension.pause(on: 1)
        }
        let execution = Task { try await fixture.run.execute(replacement, approved: true) }
        try await suspension.reached.wait()
        let spending = CostEstimate(provider: "elevenlabs", operation: "other action", units: 1, unit: "action", usd: 1, basis: "test")
        #expect(await fixture.ledger.record(spending, at: Date()) == nil)
        #expect(scratch.isValid && audition.isPlaying && !backend.stopped)
        await suspension.release()
        let next = try await execution.value
        #expect(approvals.confirmations == 1)
        if approved {
            #expect(!scratch.isValid && backend.stopped && next.rows.first?.index == 0)
            #expect(fixture.http.value.withLock { $0.seeds.count == 2 })
        } else {
            #expect(next.rows.isEmpty && scratch.isValid && audition.isPlaying && !backend.stopped)
            #expect(FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
            #expect(fixture.http.value.withLock { $0.seeds.count == 1 })
            let declinedAgain = try await fixture.run.execute(replacement, approved: true)
            #expect(declinedAgain.rows.isEmpty && approvals.confirmations == 2)
            #expect(scratch.isValid && audition.isPlaying)
            approvals.approved = true
            let retried = try await fixture.run.execute(replacement, approved: true)
            #expect(retried.rows.first?.index == 0 && !scratch.isValid)
            #expect(fixture.http.value.withLock { $0.seeds.count == 2 })
        }
        await fixture.run.invalidate()
    }
    @Test @MainActor func cancellationAtFirstTransportKeepsPlayingScratch() async throws {
        let suspension = TakeRunSuspension()
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initial = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(initial, approved: true)
        let row = try #require(result.best)
        let scratch = try #require(await fixture.run.scratch(for: row.id))
        let backend = TakeRunPlayback(), audition = VoiceLabAudition(makeBackend: { _, _ in backend })
        try audition.play(scratch, takeId: row.id, selectionId: "prior")
        let replacement = try await fixture.run.prepare(fixture.input)
        await fixture.client.useDispatchHook { await suspension.pause(on: 1) }
        let execution = Task { try await fixture.run.execute(replacement, approved: true) }
        try await suspension.reached.wait()
        #expect(scratch.isValid && audition.isPlaying)
        await fixture.run.cancel(keepingTakes: true)
        await suspension.release()
        _ = try await execution.value
        #expect(scratch.isValid && audition.isPlaying && !backend.stopped)
        #expect(FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
        #expect(fixture.http.value.withLock { $0.seeds.count == 1 })
        await fixture.run.invalidate()
    }
    @Test func qaMeasuresScratchReadbackAndRejectionRemovesOnlyScratch() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        let row = try #require(result.best), audio = try #require(row.audio), qa = try #require(row.qa)
        let scratch = try #require(await fixture.run.scratch(for: row.id))
        #expect(scratch.audio == audio)
        #expect(fixture.http.value.withLock { $0.qaWAVs.first } == (try VoiceLabTakeWAV.encode(audio.mixed, rate: audio.sampleRate)))
        #expect(qa.values.peakDbfs == (try VoiceLabLoudness.samplePeakDbfs(audio.mixed)))
        #expect(qa.values.lufsJumpLu == (try VoiceLabLoudness.lufsJumpLu(audio.mixed, sampleRate: audio.sampleRate, seamSamples: audio.seams)))
        let paid = try #require(await fixture.run.paidAsset(for: row.id))
        let paidURL = fixture.root.appendingPathComponent("VoiceLab").appendingPathComponent(paid.file)
        await fixture.run.reject(row.id)
        #expect(!scratch.isValid && !FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
        #expect(FileManager.default.fileExists(atPath: paidURL.path))
    }
    @Test func withdrawalAlsoOrdersScribeDispatchAfterScratchPreparation() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let suspension = TakeRunSuspension()
        await fixture.client.useDispatchHook { await suspension.pause(on: 2) }
        let sending = Task { try await fixture.run.execute(quote, approved: true) }
        try await suspension.reached.wait()
        _ = try await fixture.store.beginDeletion(fixture.input.recordID, region: .default, at: Date())
        await suspension.release()
        let result = try await sending.value
        #expect(result.end == .fatal)
        #expect(fixture.http.value.withLock { $0.seeds.count == 1 && $0.qa == 0 })
        let scratch = try #require(await fixture.run.scratch(for: quote.takes[0].synthesis.requestID))
        await fixture.run.cancel()
        #expect(!scratch.isValid && !FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
    }
    @Test(arguments: [401, 500]) func fatalVersusNonfatalFailureRemainsARow(status: Int) async throws {
        let fixture = try await fixture { $0.firstStatus = status }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.rows.first?.failure != nil)
        #expect(result.rows.count == (status == 401 ? 1 : 2))
        #expect(result.end == (status == 401 ? .fatal : .earlyStop))
        #expect(fixture.http.value.withLock { $0.seeds.count } == (status == 401 ? 1 : 2))
    }
    @Test func expiryAndApprovedRemainderHaveDifferentLifetimes() async throws {
        let fixture = try await fixture { $0.mismatchCount = 1 }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expired = try await fixture.run.prepare(fixture.input)
        fixture.clock.advance(300)
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(expired, approved: true) }
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty })
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true) { rows in
            if rows.count == 1 { fixture.clock.advance(301) }
        }
        #expect(result.rows.count == 2 && result.end == .earlyStop)
    }
    @Test func changedInputsDiscardUnsentQuotesAndKeepOnlySentSpend() async throws {
        let fixture = try await fixture { $0.mismatchCount = 1 }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true) { _ in fixture.http.value.withLock { $0.current = false } }
        #expect(result.end == .invalidated && fixture.http.value.withLock { $0.seeds.count } == 1)
        for take in quote.takes.dropFirst() {
            await #expect(throws: VoiceLabError.consentRequired) { try await fixture.client.approveRun(UUID(), quotes: [take.synthesis, take.qa]) }
        }
    }
    @Test(arguments: [false, true]) func cancelBeforeAndAfterDispatch(afterDispatch: Bool) async throws {
        let fixture = try await fixture { $0.paused = afterDispatch }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        if !afterDispatch {
            await fixture.run.cancel()
            await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(quote, approved: true) }
            #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        } else {
            let sending = Task { try await fixture.run.execute(quote, approved: true) }
            defer { sending.cancel(); fixture.http.gate.signal() }
            try await fixture.http.dispatched.wait()
            #expect(fixture.http.value.withLock { $0.entered })
            await fixture.run.cancel(); fixture.http.gate.signal()
            let result = try await sending.value
            #expect(result.end == .cancelled && result.rows.count == 1)
            #expect(fixture.http.value.withLock { $0.seeds.count == 1 && $0.qa == 0 })
            await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(quote, approved: true) }
        }
    }
    @Test(arguments: [false, true]) func speakerAndScribeFailuresCannotBeSelected(speakerFailure: Bool) async throws {
        let fixture = try await fixture({ $0.mismatchCount = speakerFailure ? 0 : 3 }, drift: speakerFailure)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.rows.count == 3 && result.best == nil)
        #expect(result.rows.allSatisfy { !$0.selectable && $0.qa?.failures.contains(speakerFailure ? .speaker : .transcript) == true })
    }
    @Test(arguments: [false, true]) func missingOrMalformedAlignmentDoesNotBuyUnspecifiedFallback(malformed: Bool) async throws {
        let fixture = try await fixture { $0.missingAlignment = !malformed; $0.malformedAlignment = malformed }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.best == nil && result.rows.count == 1)
        #expect(fixture.http.value.withLock { $0.qa == 0 && $0.seeds.count == 1 })
    }
    @Test func changedDurationRanksButDoesNotPretendToFit() async throws {
        let fixture = try await fixture { $0.duration = 5 }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.rows.count == 3 && result.end == .completed)
        #expect(result.best?.selectable == true && result.best?.fits == false)
        #expect(result.ranked.map(\.index) == [0, 1, 2])
    }
    @Test func shortUncalibratedSpeakerAudioIsNeverPaddedOrSelected() async throws {
        let fixture = try await fixture { $0.duration = 1 }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.rows.count == 3 && result.best == nil)
        #expect(result.rows.allSatisfy { $0.qa?.failures.contains(.speaker) == true && !$0.selectable })
        #expect(fixture.http.value.withLock { $0.qa == 0 })
    }
    @Test func approvalRejectsAChangedQuoteSetWithoutSending() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try await fixture.run.prepare(fixture.input)
        let changed = VoiceLabTakeRunQuote(id: original.id, takes: original.takes.reversed(), preparedAt: original.preparedAt)
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(changed, approved: true) }
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == 0)
    }
    @Test func providerVerificationRequiredVoiceIsNotOfferedOrSent() async throws {
        let fixture = try await fixture { $0.remoteRequiresVerification = true }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.prepare(fixture.input) }
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
    }
    @Test(arguments: [false, true]) func preflightRefusalsNeverSendPaidRequests(noVoicedSource: Bool) async throws {
        let fixture = try await fixture(sourceAudible: !noVoicedSource, roomToneAvailable: noVoicedSource)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        if noVoicedSource {
            await #expect(throws: VoiceLabAudioMathError.noVoicedAudio) { try await fixture.run.prepare(fixture.input) }
        } else {
            await #expect(throws: VoiceLabGeometryError.roomToneUnavailable) { try await fixture.run.prepare(fixture.input) }
        }
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == 0)
    }
    /// voice-lab §8.6 with several hunks: one approval pins every window's set, so a later window still runs after its
    /// quotes' five-minute expiry, and the spend ledger holds exactly what the batch's progress counts as sent.
    @Test func oneBatchApprovalHoldsALaterWindowPastTheExpiry() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = VoiceLabTakeBatchRun(runs: [fixture.run, fixture.later])
        let batch = try await runs.prepare([fixture.input, fixture.laterInput])
        #expect(batch.takeCount == 6 && batch.windows.map(\.input) == [fixture.input, fixture.laterInput])
        let windowTotals = batch.windows.map(\.quote.estimate.usd)
        #expect(batch.estimate.usd == (windowTotals.contains(nil) ? nil : windowTotals.compactMap { $0 }.reduce(0, +)))
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        try await runs.approve(batch)
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 }, "Approving sends nothing")
        var progress = VoiceLabTakeBatchProgress(batch: batch)
        let first = try await fixture.run.execute(batch.windows[0].quote, approved: true) { rows in
            if rows.count == 1 { fixture.clock.elapse(301) }
        }
        #expect(first.end == .earlyStop && first.rows.count == 1, "Failures: \(first.rows.map(\.failure))")
        try progress.finish(window: 0, result: first)
        #expect(progress.window == 1 && progress.discarded.count == 4)
        let later = batch.windows[1].quote.takes.flatMap { [$0.synthesis, $0.qa] }
        #expect(await fixture.client.quotesAreFresh(later) == false, "Unpinned, the later window's set would have expired")
        let second = try await fixture.later.execute(batch.windows[1].quote, approved: true)
        #expect(!second.rows.isEmpty)
        #expect(fixture.http.value.withLock { $0.seeds.count > 1 && $0.seeds.first == UInt32.max && $0.seeds[1] == 7 })
        try progress.finish(window: 1, result: second)
        #expect(progress.window == nil)
        #expect(progress.sentEstimate.units == Double(1 + second.rows.filter { $0.receipt != nil }.count))
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == (progress.sentEstimate.usd ?? 0))
    }
    /// The control: each window approving itself when it starts, a later window prepared with the first expires while
    /// the first runs, and sends nothing.
    @Test func withoutTheBatchApprovalALaterWindowExpiresWhileTheFirstRuns() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await fixture.run.prepare(fixture.input)
        let later = try await fixture.later.prepare(fixture.laterInput)
        let result = try await fixture.run.execute(first, approved: true) { rows in
            if rows.count == 1 { fixture.clock.elapse(301) }
        }
        #expect(result.end == .earlyStop)
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.later.execute(later, approved: true) }
        #expect(fixture.http.value.withLock { $0.seeds == [UInt32.max] && $0.qa == 1 })
    }
    @Test func aBatchApprovalIsAllOrNothingAndPreparationChecksTheWindowsFirst() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = VoiceLabTakeBatchRun(runs: [fixture.run, fixture.later])
        await #expect(throws: VoiceLabError.invalidInput) { try await runs.prepare([fixture.input, fixture.input]) }
        await #expect(throws: VoiceLabError.invalidInput) { try await runs.prepare([fixture.input]) }
        let batch = try await runs.prepare([fixture.input, fixture.laterInput])
        fixture.clock.elapse(300)
        await #expect(throws: VoiceLabError.consentRequired) { try await runs.approve(batch) }
        for (run, window) in zip(runs.runs, batch.windows) {
            await #expect(throws: VoiceLabError.consentRequired) { try await run.execute(window.quote, approved: true) }
        }
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == 0)
    }
    @Test func aRunPinsOnlyItsOwnFreshSetAndOnlyOnce() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let foreign = try await fixture.later.prepare(fixture.laterInput)
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.approve(foreign) }
        try await fixture.run.approve(quote)
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.approve(quote) }
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(quote, approved: false) }
        fixture.clock.elapse(301)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.end == .earlyStop && fixture.http.value.withLock { $0.seeds == [UInt32.max] && $0.qa == 1 })
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.approve(quote) }
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(quote, approved: true) }
    }
    /// A request the provider accepted counts as sent even when its reply then fails and leaves no receipt: the spend
    /// ledger recorded it on the 2xx status line, and the batch's progress agrees with the ledger.
    @Test(arguments: [false, true]) func anAcceptedRequestWithoutAReceiptCountsAsSent(qa: Bool) async throws {
        let fixture = try await fixture { $0.missingAlignment = !qa; $0.malformedQA = qa }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = VoiceLabTakeBatchRun(runs: [fixture.run])
        let batch = try await runs.prepare([fixture.input])
        try await runs.approve(batch)
        let result = try await fixture.run.execute(batch.windows[0].quote, approved: true)
        var progress = VoiceLabTakeBatchProgress(batch: batch)
        try progress.finish(window: 0, result: result)
        let takes = batch.windows[0].quote.takes
        #expect(result.rows.allSatisfy { $0.qaReceipt == nil })
        if qa {
            #expect(result.end == .completed && result.rows.count == 3 && result.rows.allSatisfy { $0.receipt != nil })
            #expect(progress.sent == Set(takes.flatMap { [$0.synthesis.requestID, $0.qa.requestID] }))
            #expect(fixture.http.value.withLock { $0.seeds.count == 3 && $0.qa == 3 })
        } else {
            #expect(result.end == .fatal && result.rows.count == 1 && result.rows[0].receipt == nil)
            #expect(progress.sent == [takes[0].synthesis.requestID] && progress.sentEstimate.units == 1)
            #expect(fixture.http.value.withLock { $0.seeds.count == 1 && $0.qa == 0 })
        }
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == (progress.sentEstimate.usd ?? 0))
    }
    @Test(arguments: [false, true]) func consentOrModelChangeInvalidatesRemainder(consent: Bool) async throws {
        let fixture = try await fixture { $0.mismatchCount = 1 }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true) { _ in
            if consent { try? await fixture.store.markDeleted(fixture.input.recordID, at: fixture.clock.now()) }
            else { _ = try? await fixture.client.models() }
        }
        #expect(result.end == (consent ? .fatal : .invalidated))
        #expect(result.rows.count == 1 && fixture.http.value.withLock { $0.seeds.count } == 1)
    }
}
#endif
