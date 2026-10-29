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
    func rewindWall() { date.withLock { $0.addTimeInterval(-3_600) } }
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
        var firstStatus = 200
        var mismatchCount = 0
        var duration = 4.0
        var missingAlignment = false
        var remoteRequiresVerification = false
        var malformedAlignment = false
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
    }
    private func fixture(_ configure: @Sendable (inout TakeRunHTTP.State) -> Void = { _ in }, drift: Bool = false,
                         sourceAudible: Bool = true, roomToneAvailable: Bool = true) async throws -> Fixture {
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
                let body = String(decoding: try VoiceLabRequestFixtures.body(request), as: UTF8.self)
                for (field, value) in [("model_id", "scribe_v2"), ("language_code", "en"), ("diarize", "false"), ("tag_audio_events", "false"), ("timestamps_granularity", "word")] {
                    #expect(body.contains("name=\"\(field)\"\r\n\r\n\(value)\r\n"))
                }
                let state = http.value.withLock { $0.qa += 1; return $0 }
                let text = state.qa <= state.mismatchCount ? "different" : "Hello"
                return (200, [:], try JSONSerialization.data(withJSONObject: ["language_code": "eng", "words": [["type": "word", "text": text, "start": 0.65, "end": state.duration + 0.35]]]))
            default: Issue.record("Unexpected take-run request"); return (500, [:], Data())
            }
        }
        let ledger = VoiceLabSpendLedger(locations: locations)
        let client = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-take-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)),
            prices: VoiceLabPricingTests.catalogIfPresent, spend: ledger, enforceCapabilities: true)
        let clock = TakeRunClock(); await client.useClock({ clock.now() }, monotonic: { clock.elapsed() })
        let run = VoiceLabTakeRun(client: client, store: store, speaker: .init(embedder: TakeRunEmbedder(drift: drift), calibratedThreshold: 0.45), dispatchIfCurrent: { start in
            try http.value.withLock { state in
                guard state.current else { throw VoiceLabError.consentRequired }
                try start()
            }
        }) { http.value.withLock { $0.current } }
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
        return Fixture(root: root, http: http, clock: clock, store: store, client: client, ledger: ledger, run: run, input: input)
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
        else { try await fixture.store.withdrawCreation(recordID: fixture.input.recordID, remoteVoiceID: "fixtureOwnVoice") }
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
        #expect(fixture.http.value.withLock { $0.contexts.first?["previous"] == "before" && $0.contexts.first?["next"] == "after last" })
        let amount = (quote.takes[0].synthesis.estimate.usd ?? 0) + (quote.takes[0].qa.estimate.usd ?? 0)
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == amount)
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(quote, approved: true) }
        #expect(fixture.http.value.withLock { $0.seeds.count } == 1)
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
        #expect(result.best == nil && result.rows.count == 3)
        #expect(fixture.http.value.withLock { $0.qa == 0 && $0.seeds.count == 3 })
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
