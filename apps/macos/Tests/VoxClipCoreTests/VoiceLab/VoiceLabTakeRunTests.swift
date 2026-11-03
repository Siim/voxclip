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
                else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [self] in
                        let expired = value.withLock { state in
                            let pending = state.continuation
                            state.continuation = nil
                            return pending
                        }
                        expired?.resume(throwing: TestDeadlineFailure.timedOut("take dispatch"))
                    }
                }
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
    private var continuation: TestContinuation<Void>?
    private var calls = 0
    func pause(on ordinal: Int) async {
        calls += 1
        if calls == ordinal { await pause() }
    }
    func pause() async {
        await withTestDeadline { continuation in self.continuation = continuation; reached.fire() }
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
        var durations: [Double] = []
        var recognized: [String] = []
        var missingAlignment = false
        var remoteRequiresVerification = false
        var malformedAlignment = false
        var wrongDialogueVoice = false
        /// Eleven v3's shape: the characters run from 0 to the PCM's last frame plus this overshoot (the client accepts
        /// up to 50 ms), so the audio holds nothing past the last aligned character. Nil keeps 0.1 s at each end.
        var edgeAlignmentOvershoot: Double?
        /// The PCM is silent this long at each end, inside the aligned lead and tail, as a take that pauses at its edges.
        var silentEdges = 0.0
        /// Scribe answers 200 with no words, after the spend ledger has recorded the QA request.
        var malformedQA = false
        var current = true
        var paused = false
        var entered = false
        /// The request each default dispatch started, in order.
        var dispatches: [UUID] = []
        /// With `recordsSpend`, the month's ledger total just before each of `dispatches`.
        var recordsSpend = false
        var spentAtDispatch: [Decimal] = []
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
    let voicedFraction: Double
    let rejectGeneratedVAD: Bool
    let generatedRawFrames: (@Sendable () -> Int)?
    var calls = 0
    var streams = 0
    init(drift: Bool, voicedFraction: Double = 1, rejectGeneratedVAD: Bool = false, generatedRawFrames: (@Sendable () -> Int)? = nil) {
        self.drift = drift; self.voicedFraction = voicedFraction; self.rejectGeneratedVAD = rejectGeneratedVAD; self.generatedRawFrames = generatedRawFrames
    }
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] {
        streams += 1
        if rejectGeneratedVAD, streams > 1 { throw VoiceConsentError.speakerMismatch }
        let basis = generatedRawFrames.map { frames in
            let raw = frames()
            return pcm16k.count <= raw ? raw : pcm16k.count
        } ?? pcm16k.count
        return Array(pcm16k.prefix(min(pcm16k.count, Int(Double(basis) * voicedFraction))))
    }
    func embed(_ pcm16k: [Float]) async throws -> [Float] {
        calls += 1
        return drift && streams > 1 ? [0, 1] : [1, 0]
    }
}

private struct ReviewerGroupSpeaker: SpeakerEmbedder {
    let modelID = "fixture-calibrated"
    let dimension = 2
    func voicedSamples(_ samples: [Float]) async throws -> [Float] { samples }
    func embed(_ samples: [Float]) async throws -> [Float] {
        samples.first.map { $0 < 0 } == true ? [0, 1] : [1, 0]
    }
}

private actor ReviewerCapturingSpeaker: SpeakerEmbedder {
    nonisolated let modelID = "fixture-calibrated"
    nonisolated let dimension = 2
    var windows: [[Float]] = []
    func voicedSamples(_ samples: [Float]) async throws -> [Float] { samples }
    func embed(_ samples: [Float]) async throws -> [Float] { windows.append(samples); return [1, 0] }
}

@Suite("Bounded take run", .serialized, .timeLimit(.minutes(2)), .offlineFixtures)
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
        /// A second window's run on the same client, store and speaker check, and its input over the word "last". The window
        /// ends half a second before the source does, so its right seam has source on both sides (the crossfade handle and
        /// the loudness check's context) and its takes reach Scribe.
        let later: VoiceLabTakeRun
        let laterInput: VoiceLabTakeInput
    }
    private func fixture(_ configure: @Sendable (inout TakeRunHTTP.State) -> Void = { _ in }, drift: Bool = false,
                         sourceAudible: Bool = true, roomToneAvailable: Bool = true,
                         background: (left: Double, right: Double, run: Double)? = nil,
                         boundary: VoiceLabTakeDispatchBoundary? = nil, text: String = "Hello", modelID: String = "eleven_v3", voicedFraction: Double = 1, rejectGeneratedVAD: Bool = false) async throws -> Fixture {
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
                return (200, [:], try JSONSerialization.data(withJSONObject: [["model_id": modelID, "name": "Speech", "can_do_text_to_speech": true, "can_do_voice_conversion": false, "languages": [["language_id": "en"]], "maximum_text_length_per_request": 5000]]))
            case ("GET", "/v2/voices"):
                let requiresVerification = http.value.withLock { $0.remoteRequiresVerification }
                let row: [String: Any] = ["voice_id": "fixtureOwnVoice", "name": "My voice", "category": "cloned", "is_owner": true,
                    "voice_verification": ["requires_verification": requiresVerification, "is_verified": false]]
                return (200, [:], try JSONSerialization.data(withJSONObject: ["voices": [row], "has_more": false]))
            case ("POST", "/v1/text-to-speech/fixtureOwnVoice/with-timestamps"), ("POST", "/v1/text-to-dialogue/with-timestamps"):
                let body = try #require(JSONSerialization.jsonObject(with: VoiceLabRequestFixtures.body(request)) as? [String: Any])
                let seed = try #require(body["seed"] as? UInt32)
                let state = http.value.withLock { state in
                    state.seeds.append(seed); state.contexts.append(["previous": body["previous_text"] as? String ?? "", "next": body["next_text"] as? String ?? ""])
                    state.entered = true
                    if !state.durations.isEmpty { state.duration = state.durations[(state.seeds.count - 1) % state.durations.count] }
                    return state
                }
                http.dispatched.fire()
                if state.paused, http.gate.wait(timeout: .now() + 10) != .success {
                    throw TestDeadlineFailure.timedOut("held take response")
                }
                if state.seeds.count == 1 && state.firstStatus != 200 { return (state.firstStatus, [:], Data()) }
                var pcm = Data()
                let frames = Int(state.duration * 24_000)
                let edge = Int(state.silentEdges * 24_000)
                for index in 0..<frames {
                    // Speech fades over 20 ms (480 frames) into its silent edges.
                    let inside = edge == 0 ? Int.max : min(index - edge, frames - edge - 1 - index)
                    let envelope = inside < 0 ? 0 : inside >= 480 ? 1 : 0.5 - 0.5 * cos(Double.pi * Double(inside) / 480)
                    var value = Int16((sin(2 * Double.pi * 100 * Double(index) / 24_000) * 3_200 * envelope).rounded()).littleEndian
                    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
                }
                let inputs = body["inputs"] as? [[String: Any]]
                let generatedText = try #require(body["text"] as? String ?? inputs?.first?["text"] as? String)
                let characters = Array(generatedText).map(String.init)
                let lead = state.edgeAlignmentOvershoot == nil ? 0.1 : 0
                let span = state.edgeAlignmentOvershoot.map { state.duration + $0 } ?? state.duration - 0.2
                let starts = characters.indices.map { lead + Double($0) * span / Double(characters.count) }
                var ends = characters.indices.map { lead + Double($0 + 1) * span / Double(characters.count) }
                if state.edgeAlignmentOvershoot != nil { ends[ends.count - 1] = span }
                let alignment: Any = state.missingAlignment ? NSNull() : ["characters": characters, "character_start_times_seconds": state.malformedAlignment ? Array(starts.dropLast()) : starts, "character_end_times_seconds": ends]
                var reply: [String: Any] = ["audio_base64": pcm.base64EncodedString(), "alignment": alignment]
                if modelID == "eleven_v4" {
                    #expect(request.url?.path == "/v1/text-to-dialogue/with-timestamps")
                    #expect(inputs?.count == 1 && inputs?.first?["voice_id"] as? String == "fixtureOwnVoice")
                    #expect(body["previous_text"] == nil && body["future_text"] == nil && body["next_text"] == nil)
                    reply["voice_segments"] = [["voice_id": state.wrongDialogueVoice ? "otherVoice" : "fixtureOwnVoice", "dialogue_input_index": 0,
                        "character_start_index": 0, "character_end_index": generatedText.unicodeScalars.count,
                        "start_time_seconds": 0, "end_time_seconds": state.duration]]
                }
                return (200, [:], try JSONSerialization.data(withJSONObject: reply))
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
                let text = state.recognized.isEmpty ? (state.qa <= state.mismatchCount ? "different" : text)
                    : state.recognized[(state.qa - 1) % state.recognized.count]
                let tokens = text.split(separator: " ").map(String.init)
                let step = (state.duration - 0.2) / Double(tokens.count)
                let words = tokens.enumerated().map { index, token -> [String: Any] in
                    ["type": "word", "text": token, "start": 0.6 + Double(index) * step,
                     "end": 0.6 + Double(index + 1) * step]
                }
                return (200, [:], try JSONSerialization.data(withJSONObject: ["language_code": "eng", "words": words]))
            default: Issue.record("Unexpected take-run request"); return (500, [:], Data())
            }
        }
        let ledger = VoiceLabSpendLedger(locations: locations)
        let client = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-take-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)),
            prices: VoiceLabPricingTests.catalogIfPresent, spend: ledger, enforceCapabilities: true)
        let clock = TakeRunClock(); await client.useClock({ clock.now() }, monotonic: { clock.elapsed() })
        let generatedRawFrames: @Sendable () -> Int = { http.value.withLock { Int($0.duration * 16_000) } }
        let rawFrames: (@Sendable () -> Int)? = voicedFraction < 1 ? generatedRawFrames : nil
        let speakerCheck = VoiceSpeakerCheck(embedder: TakeRunEmbedder(drift: drift, voicedFraction: voicedFraction, rejectGeneratedVAD: rejectGeneratedVAD,
            generatedRawFrames: rawFrames), calibratedThreshold: 0.45)
        let storage = VoiceLabTakeStorage(projectId: UUID().uuidString.lowercased(), paidRoot: root.appendingPathComponent("VoiceLab"), scratchRoot: root.appendingPathComponent("scratch"))
        let makeRun: () -> VoiceLabTakeRun = {
            VoiceLabTakeRun(client: client, store: store, speaker: speakerCheck, storage: storage, dispatchIfCurrent: { request, start in
                if let boundary { try await boundary(request, start); return }
                var spent: Decimal?
                if http.value.withLock({ $0.recordsSpend }) { spent = await ledger.total(provider: "elevenlabs", at: clock.now())?.usd ?? 0 }
                let observed = spent
                try http.value.withLock { state in
                    guard state.current else { throw VoiceLabError.consentRequired }
                    try start()
                    state.dispatches.append(request)
                    if let observed { state.spentAtDispatch.append(observed) }
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
            guard sourceAudible else { return 0 }
            // With `background`, speech fades over 20 ms into and out of each pause, as speech decays, instead of
            // stopping on a broadband click, and the pauses hold noise at each side's level.
            let edges = [1.9, 2.1, 5.9, 6.1, 6.5, 7.1], distance = edges.map { abs(seconds - $0) }.min() ?? 1
            let envelope = background == nil || distance >= 0.02 ? 1 : 0.5 - 0.5 * cos(Double.pi * distance / 0.02)
            guard quiet else { return Float(0.1 * envelope * sin(2 * Double.pi * 100 * seconds)) }
            guard let background else { return 0.001 }
            let level = seconds < 4 ? background.left : seconds < 6.3 ? background.right : background.run
            return Float(Double((index * 7_919) % 1_001 - 500) / 500 * level)
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
        let input = VoiceLabTakeInput(text: text, modelID: modelID, recordID: record.id, language: "en", seed: UInt32.max,
            contentKey: "synthetic-source", source: source, sourceSampleRate: rate, items: items, window: window,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let lastWindow = VoiceLabWindow(firstWordId: "last", lastWordId: "last", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 7, end: 7.5,
            startSample: 168_000, endSample: 180_000, leftSeam: .init(kind: .hard, time: 7, sample: 168_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 7.5, sample: 180_000, fadeSamples: 288))
        let laterInput = VoiceLabTakeInput(text: text, modelID: modelID, recordID: record.id, language: "en", seed: 7,
            contentKey: "synthetic-source", source: source, sourceSampleRate: rate, items: items, window: lastWindow,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        return Fixture(root: root, http: http, clock: clock, store: store, client: client, ledger: ledger, run: run, input: input,
                       later: later, laterInput: laterInput)
    }
    @Test func dialogueTakePassesQAAndPublishesARenderableRecipe() async throws {
        let fixture = try await fixture(modelID: "eleven_v4")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        #expect(quote.takes.allSatisfy { $0.synthesis.endpoint == "v1/text-to-dialogue/with-timestamps" })
        let result = try await fixture.run.execute(quote, approved: true)
        let row = try #require(result.best)
        #expect(row.selectable && row.qa?.passed == true && row.fits)
        #expect(fixture.http.value.withLock { $0.seeds.count == 1 && $0.qa == 1 })
        let (published, record) = try await fixture.run.publishForAcceptance(row, input: fixture.input, at: fixture.clock.now())
        let take = try #require(row.audio)
        let candidate = try VoiceLabRecipeBuilder.candidate(row: row, input: fixture.input, published: published,
            record: record, createdAt: fixture.clock.now(), videoChoice: .source)
        #expect(candidate.recipe?.provenance.endpoint == "v1/text-to-dialogue/with-timestamps")
        #expect(candidate.recipe?.provenance.model == "eleven_v4")
        let segment = try VoiceLabRecipeBuilder.segment(id: "dialogue-take", candidates: [candidate], selected: 0,
            input: fixture.input, plan: take.fit.plan)
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        let publishedAsset = try #require(published.assets.first)
        project.id = String(try #require(publishedAsset.file.split(separator: "/").first))
        project.media.source.durationSeconds = 8
        project.media.source.audio = MediaAudio(sampleRate: 24_000, channels: 1)
        project.transcript!.words = fixture.input.items
        project.transcript!.durationSeconds = 8
        project.edits = ProjectEdits()
        project.voiceLab = ProjectVoiceLab(assets: [], cleanAudio: .init(mode: .off), voices: [], videoAssets: [])
        project = try VoiceLabProject.addVoiceReference(.init(id: record.id, provider: record.provider, voiceId: record.voiceId,
            consentRecordId: record.id, displayName: record.voiceName, status: .active), to: project)
        let accepted = try VoiceLabProject.accept(segment, assets: published.assets, into: project)
        let prepared = try VoiceLabRenderContract.prepare(accepted, scope: .full, labelPosition: .topRight)
        #expect(prepared.selectedSegmentRecipes.count == 1)
        _ = try JSONProjectStore.decode(ProjectJSON.encode(accepted))
        await fixture.run.invalidate()
    }
    @Test(arguments: [false, true]) func dialogueBadAlignmentRecordsSpendAndSkipsQA(malformed: Bool) async throws {
        let fixture = try await fixture({ $0.missingAlignment = !malformed; $0.malformedAlignment = malformed }, modelID: "eleven_v4")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        let row = try #require(result.rows.first)
        #expect(row.failure == .provider(.invalidAlignment) && !row.selectable && result.best == nil)
        #expect(row.generated?.alignment == nil && row.generated?.pcm.isEmpty == false)
        #expect(fixture.http.value.withLock { $0.seeds.count == 1 && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == quote.takes[0].synthesis.estimate.usd)
        let paid = try #require(await fixture.run.paidAudioURL(for: row.id))
        #expect(FileManager.default.fileExists(atPath: paid.path))
        await fixture.run.invalidate()
    }
    @Test func dialogueBadSegmentsKeepPaidPCMPlayableWithoutQAOrRetry() async throws {
        let fixture = try await fixture({ $0.wrongDialogueVoice = true }, modelID: "eleven_v4")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input, candidates: 1)
        let result = try await fixture.run.execute(quote, approved: true)
        let row = try #require(result.rows.first)
        #expect(result.rows.count == 1 && result.best == nil && !row.selectable)
        #expect(row.failure == .provider(.malformedResponse))
        #expect(row.generated?.alignment == nil && row.generated?.pcm.isEmpty == false)
        #expect(fixture.http.value.withLock { $0.seeds.count == 1 && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == quote.takes[0].synthesis.estimate.usd)
        let paid = try #require(await fixture.run.paidAudioURL(for: row.id))
        #expect(FileManager.default.fileExists(atPath: paid.path))
        await fixture.run.invalidate()
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
        let fixture = try await fixture(boundary: { _, start in try await approvals.dispatch(start) })
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
        // The seam value is the step the join adds over the unedited source's own jump at the same seams (§8.11 item 3).
        let original = try #require(fixture.input.source.samples(36_000..<156_000))
        #expect(audio.sourceSeamSteps == (try VoiceLabLoudness.seamStepsLu(Array(original), sampleRate: 24_000, seamSamples: [12_000, 108_000])))
        #expect(audio.sourceSeamPauseSteps == (try VoiceLabLoudness.pauseSeamStepsLu(Array(original), sampleRate: 24_000, seamSamples: [12_000, 108_000])))
        #expect(qa.values.lufsJumpLu == (try VoiceLabLoudness.seamExcessLu(mixedSteps: VoiceLabLoudness.seamStepsLu(audio.mixed,
            sampleRate: audio.sampleRate, seamSamples: audio.seams), sourceSteps: audio.sourceSeamSteps,
            mixedPauseSteps: VoiceLabLoudness.pauseSeamStepsLu(audio.mixed, sampleRate: audio.sampleRate, seamSamples: audio.seams),
            sourcePauseSteps: audio.sourceSeamPauseSteps)))
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
    /// Live 2026-11-03 (Eleven v3): a take that ends on its last aligned character has no handle after its trim. A longer
    /// take that must shorten has no pad either, so the fitted asset once read past the paid file (invalidAudio).
    @Test(arguments: [0.0, 0.03]) func aTakeWithNoAudioPastItsAlignmentGetsSilentHandles(overshoot: Double) async throws {
        let fixture = try await fixture { $0.duration = 5; $0.edgeAlignmentOvershoot = overshoot }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.rows.count == 3 && result.rows.allSatisfy { $0.failure == nil || $0.qa != nil })
        let row = try #require(result.rows.first), scratch = try #require(await fixture.run.scratch(for: row.id))
        let fitted = scratch.fitted, plan = fitted.fit.plan
        #expect(plan.incoming.padFrames == 0 && plan.outgoing.padFrames == 0 && plan.trimStartFrame == 0 && plan.trimEndFrame == 120_000)
        // The hard seams' handles (144 frames at 24 kHz) are silence; the take between them is the paid audio.
        #expect(fitted.isDerived && fitted.trimStartFrame == 144 && fitted.wave.frames == 144 + plan.outputFrames + 144)
        #expect((0..<144).allSatisfy { fitted.wave.sample(frame: Int64($0), channel: 0) == 0 })
        #expect((0..<144).allSatisfy { fitted.wave.sample(frame: fitted.wave.frames - 1 - Int64($0), channel: 0) == 0 })
        // The take's file starts on a zero sample, so its start is the paid audio unchanged.
        #expect(fitted.wave.sample(frame: 145, channel: 0) != 0)
        // It ends on a non-zero sample, as Eleven v3 stops mid-word: the take's own last 5 ms fade to 0 before the silent
        // handle, so no step at the edge is larger than the 100 Hz tone's own largest step (§8.9.3).
        let end = fitted.trimEndFrame, edge = Int64(120)
        #expect(fitted.wave.sample(frame: end - 1, channel: 0) == 0 && fitted.wave.sample(frame: end, channel: 0) == 0)
        let slope = 2 * Double.pi * 100 / 24_000 * 3_200 / 32_768 + 1.0 / 32_768
        #expect(((end - edge)...end).allSatisfy { abs(fitted.wave.sample(frame: $0, channel: 0) - fitted.wave.sample(frame: $0 - 1, channel: 0)) <= slope })
        #expect(abs(fitted.wave.sample(frame: end - edge - 1, channel: 0)) > 0.001)
        // The source kept around the window is untouched: the mixed lead and tail outside the seam fades are its frames.
        let audio = scratch.audio, lead = audio.patchRange.lowerBound, half = 144
        let source = try #require(fixture.input.source.samples((48_000 - lead)..<(48_000 + 96_000 + 12_000)))
        #expect(Array(audio.mixed[0..<(audio.seams[0] - half)]) == Array(source[source.startIndex..<(source.startIndex + audio.seams[0] - half)]))
        let tailCount = audio.mixed.count - (audio.seams[1] + half)
        #expect(Array(audio.mixed.suffix(tailCount)) == Array(source.suffix(tailCount)))
    }
    /// Live 2026-11-03 (take 4): the background was 8 LU apart on the two sides of a window, and one room-tone level
    /// met neither join. The bed ramps from the left side's level to the right side's, so both pause joins stay within
    /// 2 LU; equal backgrounds keep today's single pooled level and the earlier encoding.
    @Test(arguments: [8.0, 0.0]) func theRoomToneBedRampsBetweenTwoBackgrounds(stepDb: Double) async throws {
        let left = 0.003, right = left * pow(10, -stepDb / 20)
        let fixture = try await fixture({ $0.duration = 2.6; $0.silentEdges = 0.2 }, background: (left, right, 0.001))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rate = 24_000, window = 48_000..<144_000
        let preflight = try VoiceLabTakeProcessing.preflight(fixture.input)
        let tone = try #require(preflight.roomTone)
        let run = Array(try #require(fixture.input.source.samples(Int(tone.sourceStartSample)..<Int(tone.sourceEndSample))))
        let sides = try VoiceLabLoudness.seamBackgroundSidesRmsDb(fixture.input.source, sampleRate: rate, window: window)
        let (l, r) = (try #require(sides.left), try #require(sides.right))
        #expect(abs((l - r) - stepDb) < 0.5)
        if stepDb == 0 {
            // Equal backgrounds: one level, today's pooled one, and no end gain in the file.
            let pooled = try VoiceLabLoudness.seamBackgroundRmsDb(fixture.input.source, sampleRate: rate, window: window)
            let today = try VoiceLabLoudness.roomToneGainDb(seamBackgroundRmsDb: pooled, run: run)
            #expect(tone.endGainDb == nil && tone.gainDb == today)
            let encoded = try JSONEncoder().encode(tone)
            #expect(String(decoding: encoded, as: UTF8.self).contains("endGainDb") == false)
        } else {
            let start = try VoiceLabLoudness.roomToneGainDb(seamBackgroundRmsDb: l, run: run)
            let end = try VoiceLabLoudness.roomToneGainDb(seamBackgroundRmsDb: r, run: run)
            #expect(tone.gainDb == start && tone.endGainDb == end)
            #expect(tone.gainDb(atFrame: -10, of: 100) == tone.gainDb && tone.gainDb(atFrame: 200, of: 100) == tone.endGainDb)
            #expect(abs(tone.gainDb(atFrame: 50, of: 100) - (tone.gainDb + (tone.endGainDb ?? 0)) / 2) < 1e-12)
            let decoded = try JSONDecoder().decode(VoiceLabRoomTone.self, from: JSONEncoder().encode(tone))
            #expect(decoded == tone)
        }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        let row = try #require(result.rows.first), audio = try #require(row.audio), qa = try #require(row.qa)
        #expect(audio.roomTone == tone)
        // Both joins sit in a pause on both sides: the source's pause, and the take's pad over the bed.
        let pauses = try VoiceLabLoudness.pauseSeamStepsLu(audio.mixed, sampleRate: audio.sampleRate, seamSamples: audio.seams)
        #expect(pauses.count == 2 && pauses.allSatisfy { $0.map { abs($0) <= 2 } == true }, "\(pauses)")
        #expect((qa.values.lufsJumpLu ?? 9) <= 2 && !qa.failures.contains(.loudness), "\(qa)")
        if stepDb > 0 {
            // One pooled level would have missed both joins by about half the step.
            let pooled = try VoiceLabLoudness.seamBackgroundRmsDb(fixture.input.source, sampleRate: rate, window: window)
            let flat = try VoiceLabLoudness.roomToneGainDb(seamBackgroundRmsDb: pooled, run: run)
            #expect(abs(flat - tone.gainDb) > 2 && abs(flat - (tone.endGainDb ?? 0)) > 2)
        }
    }
    /// Live 2026-11-03: a 1.36 s Eleven v3 take timed to its last frame. `ceil(1.36 × 24,000)` is 32,641 in binary64, one
    /// frame past the asset, and the fit planner refused the word timing (invalidAlignment) until times were clamped.
    @Test(arguments: [0.0, 0.03]) func aLastCharacterTimedToTheEndOfThePCMIsClamped(overshoot: Double) async throws {
        let fixture = try await fixture { $0.duration = 1.36; $0.edgeAlignmentOvershoot = overshoot }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect((1.36 * 24_000).rounded(.up) == 32_641)
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.end == .completed && result.rows.count == 3)
        #expect(result.rows.allSatisfy { $0.failure != .invalidAlignment && $0.failure != .provider(.invalidAlignment) && $0.qa != nil })
        let words = try #require(result.rows.first?.audio?.words)
        #expect(words.count == 1 && words[0].end > words[0].start)
        #expect(VoiceLabTakeProcessing.lastAlignedTime(frames: 32_640, rate: 24_000) < 1.36)
        #expect((VoiceLabTakeProcessing.lastAlignedTime(frames: 32_640, rate: 24_000) * 24_000).rounded(.up) == 32_640)
    }
    @Test func changedDurationRanksButDoesNotPretendToFit() async throws {
        let fixture = try await fixture { $0.duration = 5 }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.rows.count == 3 && result.end == .completed)
        #expect(result.best?.selectable == true && result.best?.fits == false)
        #expect(result.ranked.map(\.index) == [0, 1, 2])
    }
    @Test func reviewerRejectedGeneratedVADDoesNotBuyScribe() async throws {
        let fixture = try await fixture(rejectGeneratedVAD: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input, candidates: 1)
        let result = try await fixture.run.execute(quote, approved: true)
        let row = try #require(result.rows.first)
        #expect(row.failure == .qa([.speaker]))
        #expect(row.qaReceipt == nil && row.acceptedRequestIDs == [quote.takes[0].synthesis.requestID])
        #expect(fixture.http.value.withLock { $0.qa == 0 })
    }

    @Test func reviewerPoolsConsecutiveGroupsAndAttachesTail() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try await fixture.store.load(fixture.input.recordID)
        let speaker = VoiceSpeakerCheck(embedder: ReviewerGroupSpeaker(), calibratedThreshold: 0.45)
        let pool = VoiceLabShortTakePool()
        var ids: [UUID] = []
        // Two 1.5 s takes per group; the final 0.5 s tail joins group two.
        // The negative samples model an off-voice group without any real voice/model.
        for (index, frames) in [24_000, 24_000, 24_000, 24_000, 8_000].enumerated() {
            let id = UUID(); ids.append(id)
            let row = VoiceLabTakeRow(id: id, index: index, seed: 1, voiceCheck: .waiting)
            let samples = [Float](repeating: index < 2 ? 0.1 : -0.1, count: frames)
            try await pool.append(row, voiced: samples, record: record, speaker: speaker, store: fixture.store, current: { true })
        }
        let rows = await pool.finish()
        for id in ids.prefix(2) {
            #expect(rows[id]?.voiceCheck.evidence?.takeCount == 2)
            #expect(rows[id]?.voiceCheck.evidence?.voicedFrames == 48_000)
            #expect(rows[id]?.qa?.values.speakerScore == nil)
            #expect(rows[id]?.failure == nil)
        }
        for id in ids.dropFirst(2) {
            #expect(rows[id]?.voiceCheck.evidence?.takeCount == 3)
            #expect(rows[id]?.voiceCheck.evidence?.voicedFrames == 56_000)
            #expect(rows[id]?.failure == .qa([.speaker]))
        }
    }

    @Test func reviewerRetryBorrowsPhraseHistoryThenRecentPlanAndStopsAtMinimum() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try await fixture.store.load(fixture.input.recordID)
        let session = VoiceLabVoiceCheckSession()
        let oldRun = UUID()
        // Other phrases are more recent, but this phrase's newest and older takes come first.
        let donors: [(Int, Int, Float)] = [(9, 8_000, 0.2), (9, 8_000, 0.3), (1, 32_000, 0.4), (2, 32_000, 0.5)]
        for (phrase, frames, tag) in donors {
            await session.remember(.init(id: UUID(), run: oldRun, phrase: phrase, record: record,
                                         voiced: [Float](repeating: tag, count: frames)))
        }
        // A mismatch for a different record must not influence this record.
        await session.measured(record: "other-record", run: oldRun, passed: false)
        let embedder = ReviewerCapturingSpeaker()
        let speaker = VoiceSpeakerCheck(embedder: embedder, calibratedThreshold: 0.45)
        let pool = VoiceLabShortTakePool(session: session, retryPhrase: 9)
        let row = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, voiceCheck: .waiting)
        try await pool.append(row, voiced: [Float](repeating: 0.1, count: 16_000), record: record,
                              speaker: speaker, store: fixture.store, phrase: 9, current: { true })
        let checked = await pool.finish()
        #expect(checked[row.id]?.voiceCheck.evidence?.takeCount == 4)
        #expect(checked[row.id]?.voiceCheck.evidence?.voicedFrames == 48_000)
        #expect(checked.count == 1 && checked[row.id]?.failure == nil)
        let windows = await embedder.windows
        #expect(windows.count == 1)
        let expected = [Float](repeating: 0.1, count: 16_000) + [Float](repeating: 0.3, count: 8_000)
            + [Float](repeating: 0.2, count: 8_000) + [Float](repeating: 0.5, count: 16_000)
        #expect(windows.first == expected)
        // Idempotent finalization cannot reuse the retry or add another embedding.
        #expect(await pool.finish() == checked)
        #expect(await embedder.windows.count == 1)
    }

    @Test func reviewerMixedShortAndLongHistoryFollowsGenerationOrder() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try await fixture.store.load(fixture.input.recordID)
        let session = VoiceLabVoiceCheckSession()
        let embedder = ReviewerCapturingSpeaker()
        let speaker = VoiceSpeakerCheck(embedder: embedder, calibratedThreshold: 0.45)
        let original = VoiceLabShortTakePool(session: session)
        let short = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, voiceCheck: .waiting)
        try await original.append(short, voiced: [Float](repeating: 0.2, count: 8_000), record: record,
                                  speaker: speaker, store: fixture.store, phrase: 0, current: { true })
        // This long take is newer than the short one, even though the short verdict is finalized later.
        await original.measured(id: UUID(), voiced: [Float](repeating: 0.3, count: 48_000), record: record, phrase: 1, passed: true)
        _ = await original.finish()
        let retryPool = VoiceLabShortTakePool(session: session, retryPhrase: 2)
        let retry = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, voiceCheck: .waiting)
        try await retryPool.append(retry, voiced: [Float](repeating: 0.1, count: 16_000), record: record,
                                   speaker: speaker, store: fixture.store, phrase: 2, current: { true })
        let checked = await retryPool.finish()
        #expect(checked[retry.id]?.voiceCheck.evidence?.takeCount == 2)
        let expected = [Float](repeating: 0.1, count: 16_000) + [Float](repeating: 0.3, count: 32_000)
        #expect(await embedder.windows.last == expected)
    }

    @Test func reviewerMismatchBlocksEarlierUnmeasuredUntilLaterApprovedMeasuredPass() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try await fixture.store.load(fixture.input.recordID)
        let session = VoiceLabVoiceCheckSession()
        let speaker = VoiceSpeakerCheck(embedder: ReviewerGroupSpeaker(), calibratedThreshold: 0.45)
        let first = VoiceLabShortTakePool(session: session)
        let row = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, voiceCheck: .waiting)
        try await first.append(row, voiced: [Float](repeating: 0.1, count: 8_000), record: record,
                               speaker: speaker, store: fixture.store, current: { true })
        let initial = await first.finish()
        #expect(initial[row.id]?.failure == nil)
        let failedRun = VoiceLabShortTakePool(session: session)
        await failedRun.measured(id: UUID(), voiced: [], record: record, phrase: 0, passed: false)
        // A passing check in this failing approval cannot clear its mismatch.
        await failedRun.measured(id: UUID(), voiced: [], record: record, phrase: 1, passed: true)
        let blocked = await failedRun.finish()
        #expect(blocked[row.id]?.failure == .qa([.speaker]))
        #expect(!(await session.allowsUnmeasured(record: record.id)))
        let shortRun = VoiceLabShortTakePool(session: session)
        let later = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, voiceCheck: .waiting)
        try await shortRun.append(later, voiced: [Float](repeating: 0.1, count: 8_000), record: record,
                                  speaker: speaker, store: fixture.store, current: { true })
        let stillBlocked = await shortRun.finish()
        #expect(stillBlocked[later.id]?.failure == .qa([.speaker]))
        let passedRun = VoiceLabShortTakePool(session: session)
        await passedRun.measured(id: UUID(), voiced: [], record: record, phrase: 0, passed: true)
        let cleared = await passedRun.finish()
        #expect(cleared[row.id]?.failure == nil && cleared[later.id]?.failure == nil)
        #expect(await session.allowsUnmeasured(record: record.id))
    }

    @Test func reviewerHistoryNeverCrossesConsentRecords() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = try await fixture.store.load(fixture.input.recordID)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["voiceName"] = "Changed consent snapshot"
        let other = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        let session = VoiceLabVoiceCheckSession()
        await session.remember(.init(id: UUID(), run: UUID(), phrase: 0, record: other,
                                     voiced: [Float](repeating: 0.1, count: 48_000)))
        let earlier = await session.earlier(record: record, phrase: 0, excluding: UUID())
        #expect(earlier.isEmpty)
    }

    @Test func shortSingleTakeGetsWordsAndAcousticChecks() async throws {
        let fixture = try await fixture { $0.duration = 1.4 }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input, candidates: 1)
        let result = try await fixture.run.execute(quote, approved: true)
        let row = try #require(result.rows.first)
        #expect(fixture.http.value.withLock { $0.qa == 1 && $0.seeds.count == 1 })
        #expect(row.qaReceipt != nil && row.qa?.values.transcriptMatch == 1)
        #expect(row.qa?.values.peakDbfs != nil && row.qa?.values.lufsJumpLu != nil)
        #expect(row.selectable && row.failure == nil)
    }

    @Test func aCompletedShortSetRunsWordsAndReportsTruthfulUnmeasuredVoice() async throws {
        let fixture = try await fixture { $0.duration = 1 }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.rows.count == 3 && result.best != nil)
        for row in result.rows {
            #expect(row.selectable && row.failure == nil && row.qaReceipt != nil)
            #expect(row.qa?.values.transcriptMatch == 1 && row.qa?.values.speakerScore == nil)
            #expect(row.voiceCheck.evidence?.mode == .unmeasured)
            #expect(row.shortPhraseCopy == "voice couldn't be measured (under 3 s of speech)")
            #expect(row.acceptedRequestIDs.count == 2)
        }
        #expect(fixture.http.value.withLock { $0.qa == 3 && $0.seeds.count == 3 })
    }

    @Test func replayThirteenCasualPhrasesWithPooledVoiceAndTwoWrongWords() async throws {
        // Synthetic 24 kHz sine waves only; no user WAVs or voice. The supplied raw durations
        // are replayed exactly. Stub VAD retains roughly 75% of each raw 24 kHz duration
        // from the available trimmed samples, approximating voiced speech; even 3.12 s raw takes therefore stay below the 3 s calibrated window.
        let cases: [(String, [Double])] = [
            ("game development of the flight simulator.", [2.72, 2.00, 2.96]),
            ("and yeah I keep going.", [2.24, 1.68, 1.92]),
            ("The next idea is", [2.08, 2.40, 1.76]),
            ("to the way.", [1.76, 1.36, 2.32]),
            ("development of the flight simulator game.", [2.72, 2.96, 3.12]),
            ("and yeah I keep going", [2.00, 2.40, 2.16]),
            ("The next idea is", [1.84, 2.40, 1.84]),
            ("to how.", [2.24, 1.52, 2.32]),
            ("Players can collaborate.", [2.40, 2.48, 2.24]),
            ("game development of the flight simulator.", [3.12, 2.48, 2.72]),
            ("and yeah I keep going.", [2.24, 2.32, 1.44]),
            ("The next idea is", [1.92, 2.24, 1.92]),
            ("to the ones that were in the original.", [2.16, 2.72, 2.64])
        ]
        var allRows: [VoiceLabTakeRow] = []
        for range in [0..<9, 9..<13] {
            let pool = VoiceLabShortTakePool()
            var fixtures: [Fixture] = []
            defer { for fixture in fixtures { try? FileManager.default.removeItem(at: fixture.root) } }
            var pending: [VoiceLabTakeRow] = []
            for index in range {
                let (text, durations) = cases[index]
                let recognized = index == 0 ? [text.replacingOccurrences(of: "flight", with: "fight"),
                                               text.replacingOccurrences(of: "flight", with: "fight"), text] : [text, text, text]
                let fixture = try await fixture({ $0.durations = durations; $0.recognized = recognized }, text: text, voicedFraction: 0.75)
                fixtures.append(fixture)
                let quote = try await fixture.run.prepare(fixture.input, candidates: 3)
                let result = try await fixture.run.execute(quote, approved: true, shortTakePool: pool)
                #expect(result.rows.count == 3)
                #expect(result.rows.allSatisfy { !$0.selectable && $0.voiceCheck == .waiting && $0.qaReceipt != nil })
                #expect(fixture.http.value.withLock { $0.seeds.count == 3 && $0.qa == 3 })
                for (row, seconds) in zip(result.rows, durations) {
                    #expect(row.generated?.pcm.count == Int(seconds * 24_000) * 2)
                    #expect(row.voiceCheck == .waiting)
                }
                pending += result.rows
            }
            let checked = await pool.finish()
            #expect(checked.count == range.count * 3)
            // Durations are exact hundredths; integer arithmetic avoids losing a sample to binary rounding.
            let frames = range.flatMap { cases[$0].1 }.map { seconds in
                let centiseconds: Int = Int((seconds * 100).rounded())
                return centiseconds * 120
            }
            #expect(frames.reduce(0, +) == (range.lowerBound == 0 ? 718_080 : 335_040))
            var groups: [[Int]] = [], pendingIndices: [Int] = []
            for index in pending.indices {
                pendingIndices.append(index)
                if pendingIndices.reduce(0, { $0 + frames[$1] }) >= 48_000 {
                    groups.append(pendingIndices); pendingIndices = []
                }
            }
            if !pendingIndices.isEmpty { groups[groups.count - 1] += pendingIndices }
            for group in groups {
                let groupFrames = group.reduce(0) { $0 + frames[$1] }
                for index in group {
                    let result = try #require(checked[pending[index].id])
                    #expect(result.voiceCheck.evidence?.mode == .pooled)
                    #expect(result.voiceCheck.evidence?.takeCount == group.count)
                    #expect(result.voiceCheck.evidence?.voicedFrames == groupFrames)
                    #expect(result.qa?.values.speakerScore == 1)
                    allRows.append(result)
                }
            }
        }
        #expect(allRows.count == 39 && allRows.filter(\.selectable).count == 37)
        #expect(allRows.prefix(2).allSatisfy { $0.qa?.failures == [.transcript] && $0.failure == .qa([.transcript]) })
        #expect(allRows.dropFirst(2).allSatisfy { $0.qa?.passed == true && $0.failure == nil })
    }

    @Test func offVoicePoolFailsEveryCompletedShortTake() async throws {
        let fixture = try await fixture({ $0.duration = 1.8 }, drift: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quote = try await fixture.run.prepare(fixture.input, candidates: 3)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.rows.count == 3 && result.best == nil)
        #expect(result.rows.allSatisfy { $0.qa?.failures == [.speaker] && $0.failure == .qa([.speaker]) && !$0.selectable })
        #expect(result.rows.allSatisfy { $0.qa?.values.transcriptMatch == 1 && $0.qaReceipt != nil })
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
        let first = try await runs.execute(batch, window: 0) { rows in
            if rows.count == 1 { fixture.clock.elapse(301) }
        }
        #expect(first.end == .earlyStop && first.rows.count == 1, "Failures: \(first.rows.map(\.failure))")
        try progress.finish(window: 0, result: first)
        #expect(progress.window == 1 && progress.discarded.count == 4)
        let later = batch.windows[1].quote.takes.flatMap { [$0.synthesis, $0.qa] }
        #expect(await fixture.client.quotesAreFresh(later) == false, "Unpinned, the later window's set would have expired")
        let second = try await runs.execute(batch, window: 1)
        #expect(!second.rows.isEmpty && second.rows.contains { $0.qaReceipt != nil }, "Failures: \(second.rows.map(\.failure))")
        #expect(fixture.http.value.withLock { $0.seeds.count > 1 && $0.seeds.first == UInt32.max && $0.seeds[1] == 7 })
        #expect(fixture.http.value.withLock { $0.qa > 1 }, "Window 2's Scribe QA ran past the expiry on its pinned quote")
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
    @Test func aStaleBatchIsNotApproved() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = VoiceLabTakeBatchRun(runs: [fixture.run, fixture.later])
        let batch = try await runs.prepare([fixture.input, fixture.laterInput])
        fixture.clock.elapse(300)
        await #expect(throws: VoiceLabError.consentRequired) { try await runs.approve(batch) }
        for (run, window) in zip(runs.runs, batch.windows) {
            await #expect(throws: VoiceLabError.consentRequired) { try await run.execute(window.quote, approved: true) }
        }
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == 0)
    }
    /// The batch approval is all or nothing: when a later window's set cannot be pinned, the window already pinned is
    /// discarded too, so it cannot be sent past its expiry without a new approval.
    @Test func aRefusedLaterWindowUnpinsTheWindowsAlreadyApproved() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = VoiceLabTakeBatchRun(runs: [fixture.run, fixture.later])
        let batch = try await runs.prepare([fixture.input, fixture.laterInput])
        _ = try await fixture.later.prepare(fixture.laterInput)
        await #expect(throws: VoiceLabError.consentRequired) { try await runs.approve(batch) }
        #expect(await fixture.run.preparedSetID == nil)
        #expect(await fixture.later.preparedSetID == nil)
        fixture.clock.elapse(301)
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.run.execute(batch.windows[0].quote, approved: true) }
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == 0)
    }
    /// Preparation checks the windows before it prepares any of them, and a window that cannot be prepared discards the
    /// sets prepared before it.
    @Test func aBatchPreparationThatFailsLeavesNoSetBehind() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = VoiceLabTakeBatchRun(runs: [fixture.run, fixture.later])
        let kept = try await fixture.run.prepare(fixture.input)
        await #expect(throws: VoiceLabError.invalidInput) { try await runs.prepare([fixture.input]) }
        await #expect(throws: VoiceLabError.invalidInput) { try await runs.prepare([fixture.input, fixture.input]) }
        #expect(await fixture.run.preparedSetID == kept.id, "Refused before any window was prepared")
        #expect(await fixture.later.preparedSetID == nil)
        let later = fixture.laterInput
        let refused = VoiceLabTakeInput(text: later.text, modelID: later.modelID, recordID: later.recordID, language: later.language,
            seed: later.seed, contentKey: later.contentKey, source: later.source, sourceEnvelope: later.sourceEnvelope,
            sourceSampleRate: later.sourceSampleRate, items: later.items, window: later.window, incomingSilence: later.incomingSilence,
            outgoingSilence: later.outgoingSilence, providerConsent: false)
        await #expect(throws: VoiceConsentError.speakerUnavailable) { try await runs.prepare([fixture.input, refused]) }
        #expect(await fixture.run.preparedSetID == nil, "The first window's new set is discarded with the batch")
        #expect(await fixture.later.preparedSetID == nil)
        #expect(fixture.http.value.withLock { $0.seeds.isEmpty && $0.qa == 0 })
    }
    /// Stop between windows discards the windows from the given one on and leaves the earlier ones approved.
    @Test func discardingFromALaterWindowKeepsTheEarlierOnesApproved() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = VoiceLabTakeBatchRun(runs: [fixture.run, fixture.later])
        let batch = try await runs.prepare([fixture.input, fixture.laterInput])
        try await runs.approve(batch)
        await runs.discard(from: 1)
        fixture.clock.elapse(301)
        await #expect(throws: VoiceLabError.consentRequired) { try await fixture.later.execute(batch.windows[1].quote, approved: true) }
        let first = try await runs.execute(batch, window: 0)
        #expect(first.end == .earlyStop)
        #expect(fixture.http.value.withLock { $0.seeds == [UInt32.max] && $0.qa == 1 })
    }
    /// A window that ends the batch, with a fatal end or a launch that throws, discards its own set and every later
    /// window's before `execute` returns: nothing more is sent under the batch's approval, even straight through a run.
    @Test(arguments: [false, true]) func aWindowThatEndsTheBatchDiscardsTheRest(launchFails: Bool) async throws {
        let fixture = try await fixture { $0.firstStatus = launchFails ? 200 : 401 }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = VoiceLabTakeBatchRun(runs: [fixture.run, fixture.later])
        let batch = try await runs.prepare([fixture.input, fixture.laterInput])
        try await runs.approve(batch)
        var progress = VoiceLabTakeBatchProgress(batch: batch)
        if launchFails {
            await #expect(throws: CancellationError.self) { try await runs.execute(batch, window: 0, started: { throw CancellationError() }) }
            try progress.finish(window: 0, sent: [], end: .cancelled)
        } else {
            let first = try await runs.execute(batch, window: 0)
            #expect(first.end == .fatal && first.rows.count == 1 && first.rows.allSatisfy { $0.acceptedRequestIDs.isEmpty })
            try progress.finish(window: 0, result: first)
        }
        #expect(progress.window == nil && progress.sent.isEmpty)
        // Later windows first, straight through each run, so no refusal here can discard what the batch left behind.
        for (run, window) in zip(runs.runs, batch.windows).reversed() {
            await #expect(throws: VoiceLabError.consentRequired) { try await run.execute(window.quote, approved: true) }
        }
        #expect(fixture.http.value.withLock { $0.seeds == (launchFails ? [] : [UInt32.max]) && $0.qa == 0 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: fixture.clock.now())?.usd == 0)
    }
    /// Each dispatch names its request, so a cap check can weigh exactly what the batch can still spend: just before a
    /// request starts, the month's ledger plus `remainingEstimate(from:)` is the approved estimate less what will never
    /// be sent. The figure that moves only when a window finishes counts the first take's TTS twice at its QA dispatch.
    @Test func eachDispatchNamesItsRequestForAnExactCapCheck() async throws {
        let fixture = try await fixture { $0.recordsSpend = true }; defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = VoiceLabTakeBatchRun(runs: [fixture.run, fixture.later])
        let batch = try await runs.prepare([fixture.input, fixture.laterInput])
        try await runs.approve(batch)
        let total = try #require(batch.estimate.usd)
        var progress = VoiceLabTakeBatchProgress(batch: batch)
        let fresh = progress
        let first = try await runs.execute(batch, window: 0)
        #expect(first.end == .earlyStop)
        try progress.finish(window: 0, result: first)
        let take = batch.windows[0].quote.takes[0]
        let (requests, ledger) = fixture.http.value.withLock { ($0.dispatches, $0.spentAtDispatch) }
        try #require(requests == [take.synthesis.requestID, take.qa.requestID] && ledger.count == 2)
        for (request, spent) in zip(requests, ledger) {
            #expect(spent + (fresh.remainingEstimate(from: request)?.usd ?? 0) == total)
        }
        #expect(ledger[1] + (fresh.remainingEstimate.usd ?? 0) > total)
        let afterFirst = progress
        _ = try await runs.execute(batch, window: 1)
        let (laterRequests, laterLedger) = fixture.http.value.withLock { (Array($0.dispatches.dropFirst(2)), Array($0.spentAtDispatch.dropFirst(2))) }
        let opening = try #require(laterRequests.first), spentAtOpening = try #require(laterLedger.first)
        #expect(opening == batch.windows[1].quote.takes[0].synthesis.requestID)
        let dropped = batch.estimate(of: afterFirst.discarded).usd ?? 0
        #expect(spentAtOpening + (afterFirst.remainingEstimate(from: opening)?.usd ?? 0) == total - dropped)
        #expect(afterFirst.remainingEstimate(from: opening) == afterFirst.remainingEstimate)
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
            #expect(result.end == .fatal && result.rows.count == 1 && result.rows.allSatisfy { $0.receipt == nil })
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
