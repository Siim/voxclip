#if DEBUG
import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia
@testable import VoxClip

private struct ClipTakeKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { "inert-fixture-key" }
}
private actor MeasuredFitConnector: LLMConnector {
    nonisolated let id: ConnectorID
    private(set) var requests: [LLMRequest] = []
    /// Awaited before each reply: a test holds the reply until the plan reaches a state it names.
    private let hold: (@Sendable () async -> Void)?
    init(id: ConnectorID = .ollama, hold: (@Sendable () async -> Void)? = nil) { self.id = id; self.hold = hold }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [.init(id: "fixture", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) async -> RawCompletion {
        if let hold { await hold() }
        requests.append(request)
        return RawCompletion(text: #"{"phrases":[{"ordinal":2,"action":"reword","text":"Corrected Welcome today"}]}"#,
            model: model, stop: .complete)
    }
}
/// Replies with each scripted wording in turn, as an AI that suggested the same wording twice did in MVP18.
private actor ScriptedFitConnector: LLMConnector {
    nonisolated let id: ConnectorID = .ollama
    private(set) var requests: [LLMRequest] = []
    private var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [.init(id: "fixture", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        requests.append(request)
        let text = replies.isEmpty ? "Welcome" : replies.removeFirst()
        return RawCompletion(text: #"{"phrases":[{"ordinal":2,"action":"reword","text":""# + text + #""}]}"#, model: model, stop: .complete)
    }
}
@MainActor private final class TakeReviewPlayback: VoiceLabAuditionBackend {
    var position = 0.0
    var stops = 0
    func play() -> Bool { true }
    func stop() { stops += 1 }
}
private actor ClipTakeSpeaker: SpeakerEmbedder {
    nonisolated let modelID = "fixture-calibrated"
    nonisolated let dimension = 2
    private var generated = false
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] {
        generated = pcm16k.count <= 80_000
        let fraction = generated ? ClipTakeHTTP.state.withLock { $0.voicedFraction } : 1
        return Array(pcm16k.prefix(Int(Double(pcm16k.count) * fraction)))
    }
    func embed(_ pcm16k: [Float]) async throws -> [Float] {
        let mismatch = ClipTakeHTTP.state.withLock { $0.failOwner || (generated && $0.failGenerated) }
        return mismatch ? [0, 1] : [1, 0]
    }
}
private final class ClipTakeHTTP: URLProtocol, @unchecked Sendable {
    struct State {
        var texts: [String] = []
        var seeds: [UInt32] = []
        var paces: [Double] = []
        var duration = 0.5
        var speechMargin = 0.05
        var voicedFraction = 1.0
        var synthesisStatus = 200
        /// The v4 dialogue route's status; 402 replies "quota_exceeded".
        var dialogueStatus = 200
        var failQA = false
        var malformedSegments = false
        var malformedSynthesis = false
        var malformedQA = false
        var failOwner = false
        var failGenerated = false
        /// Synthesis returns silence, which fails the level step after the paid audio is stored, before any check.
        var silentSynthesis = false
        var amplitudeVariance = 0.0
        var echoQA = false
        var gets = 0
        var qa = 0
        var voicesVisible = true
        /// The account also lists Multilingual v2, after Eleven v3, as the live account did.
        var listsMultilingual = false
        var listsDialogue = false
        /// Each synthesis request's `model_id`, in order.
        var models: [String] = []
        /// A synthesis duration by request text, over `duration`.
        var durations: [String: Double] = [:]
        /// A synthesis duration by request order (0 = the first synthesis), over `durations` and `duration`: phrases with
        /// the same words.
        var durationsInOrder: [Int: Double] = [:]
        /// The last synthesis's duration when `durationsInOrder` set it: its word check times words within it.
        var orderedDuration: Double?
        /// The first this many word checks hear "wrong".
        var failFirstQA = 0
        /// Words the echoing word check writes as another word, as Scribe writes "Claude" as "cloud".
        var heardAs: [String: String] = [:]
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let data: Data
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/models"):
                Self.state.withLock { $0.gets += 1 }
                let multilingual = Self.state.withLock { $0.listsMultilingual }
                    ? #",{"model_id":"eleven_multilingual_v2","name":"Multilingual v2","can_do_text_to_speech":true,"can_do_voice_conversion":false,"languages":[{"language_id":"en"}],"maximum_text_length_per_request":10000}"# : ""
                let dialogue = Self.state.withLock { $0.listsDialogue }
                    ? #",{"model_id":"eleven_v4","name":"Eleven v4 account name","can_do_text_to_speech":true,"languages":[{"language_id":"en"}],"maximum_text_length_per_request":5000},{"model_id":"eleven_v4_turbo","name":"Turbo","can_do_text_to_speech":true,"languages":[{"language_id":"en"}]}"# : ""
                data = Data((#"[{"model_id":"eleven_v3","name":"Speech","can_do_text_to_speech":true,"can_do_voice_conversion":false,"languages":[{"language_id":"en"}],"maximum_text_length_per_request":5000}"# + multilingual + dialogue + "]").utf8)
            case ("GET", "/v2/voices"):
                data = Self.state.withLock { $0.voicesVisible } ? Data(#"{"voices":[{"voice_id":"fixtureOwnVoice","name":"My voice","category":"cloned","is_owner":true}],"has_more":false}"#.utf8) : Data(#"{"voices":[],"has_more":false}"#.utf8)
            case ("POST", "/v1/text-to-speech/fixtureOwnVoice/with-timestamps"), ("POST", "/v1/text-to-dialogue/with-timestamps"):
                let body = try #require(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
                let dialogue = request.url?.path == "/v1/text-to-dialogue/with-timestamps"
                let input = (body["inputs"] as? [[String: Any]])?.first
                let text = try #require((dialogue ? input?["text"] : body["text"]) as? String)
                let seed = try #require(body["seed"] as? UInt32)
                let model = body["model_id"] as? String ?? ""
                let pace = (body["voice_settings"] as? [String: Any])?["speed"] as? Double ?? 1
                let duration = Self.state.withLock { state in
                    state.paces.append(pace)
                    let order = state.texts.count
                    state.texts.append(text); state.seeds.append(seed); state.models.append(model)
                    state.orderedDuration = state.durationsInOrder[order]
                    return state.durationsInOrder[order] ?? state.durations[text] ?? state.duration
                }
                let variance = Self.state.withLock { $0.amplitudeVariance }
                let silent = Self.state.withLock { $0.silentSynthesis }
                var pcm = Data()
                for index in 0..<Int(EditingPrimitives.jsRound(duration * 24_000)) {
                    let seconds = Double(index) / 24_000
                    let amplitude = 1 + variance * sin(2 * Double.pi * 2 * seconds)
                    var value = Int16(silent ? 0 : (sin(2 * Double.pi * 100 * seconds) * 3_200 * amplitude).rounded()).littleEndian
                    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
                }
                let characters = Array(text).map(String.init)
                let margin = Self.state.withLock { $0.speechMargin }
                let speechDuration: Double = duration - 2 * margin
                let starts = characters.indices.map { margin + Double($0) * speechDuration / Double(characters.count) }
                let ends = characters.indices.map { margin + Double($0 + 1) * speechDuration / Double(characters.count) }
                var reply: [String: Any] = ["audio_base64": pcm.base64EncodedString()]
                if !Self.state.withLock({ $0.malformedSynthesis }) {
                    reply["alignment"] = ["characters": characters, "character_start_times_seconds": starts, "character_end_times_seconds": ends]
                }
                if dialogue {
                    reply["voice_segments"] = [["voice_id": Self.state.withLock { $0.malformedSegments } ? "wrong" : "fixtureOwnVoice",
                        "dialogue_input_index": 0, "character_start_index": 0, "character_end_index": characters.count,
                        "start_time_seconds": 0, "end_time_seconds": duration]]
                }
                data = try JSONSerialization.data(withJSONObject: reply)
            case ("POST", "/v1/speech-to-text"):
                let state = Self.state.withLock { state in state.qa += 1; return state }
                let failing = state.failQA || state.qa <= state.failFirstQA
                let word = failing ? "wrong" : "Hello"
                if state.malformedQA { data = Data(#"{"language_code":"eng"}"#.utf8) }
                else {
                    let words = state.echoQA && !failing ? (state.texts.last ?? word).split(separator: " ").map { state.heardAs[String($0)] ?? String($0) } : [word]
                    let stride = ((state.orderedDuration ?? state.duration) - 0.2) / Double(words.count)
                    let timed = words.enumerated().map { index, text in
                        ["type": "word", "text": text, "start": 0.1 + Double(index) * stride,
                         "end": 0.1 + Double(index + 1) * stride] as [String: Any]
                    }
                    data = try JSONSerialization.data(withJSONObject: ["language_code": "eng", "words": timed])
                }
            default: throw URLError(.unsupportedURL)
            }
            let url = try #require(request.url)
            let status = url.path.contains("/text-to-speech/") ? Self.state.withLock { $0.synthesisStatus }
                : url.path.contains("/text-to-dialogue/") ? Self.state.withLock { $0.dialogueStatus } : 200
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: status == 402 ? Data(#"{"detail":{"status":"quota_exceeded"}}"#.utf8) : data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try #require(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@MainActor private final class ClipTakeBarrier {
    var arrived = false
    private var arrival: TestContinuation<Void>?
    private var release: TestContinuation<Void>?
    func pause() async {
        await withTaskCancellationHandler {
            await withTestDeadline { release = $0; arrived = true; arrival?.resume(); arrival = nil }
        } onCancel: { Task { @MainActor in self.resume() } }
    }
    func wait() async { if !arrived { await withTestDeadline { arrival = $0 } } }
    func resume() { release?.resume(); release = nil }
    func finished() { arrived = true; arrival?.resume(); arrival = nil; resume() }
}

@Suite("Clip take plan", .serialized, .timeLimit(.minutes(2)), .offlineFixtures)
@MainActor struct ClipTakePlanTests {
    @MainActor private final class Fixture {
        let root: URL
        let plan: ClipTakePlan
        let ledger: VoiceLabSpendLedger
        let playback: TakeReviewPlayback
        let source: Project
        let envelope: AudioEnvelope
        let client: ElevenLabsVoiceLab
        let store: VoiceConsentStore
        let record: VoiceConsentRecord
        var preparations = 0
        var approved = 0
        var decoded = 0
        var cap: Decimal?
        var afterPhrase: ((Int) async throws -> Void)?
        var finishFailure: VoiceLabTakeFailure?
        var transformFinish: (([UUID: VoiceLabTakeRow]) -> [UUID: VoiceLabTakeRow])?
        var transformRow: ((VoiceLabTakeRow) -> VoiceLabTakeRow)?
        var fatalResult: VoiceLabTakeFailure?
        var beforePhrase: ((Int) async throws -> Void)?
        var beforeQuote: (() async -> Void)?
        /// Thrown by the next quotes, after the plan was priced.
        var quoteFailure: (any Error)?
        var beforePublish: ((Int) async -> Void)?
        /// What publishing returns for a phrase, changed: a take whose render recipe can't be made (MVP32 Clip 7).
        var transformPublished: ((Int, VoiceLabPublishedTake) -> VoiceLabPublishedTake)?
        var beforeDispatch: (() -> Void)?
        var beforeProgress: (@MainActor @Sendable () async -> Void)?
        var beforeScratch: (() async -> Void)?
        var publishedIDs: [UUID] = []
        var lastBatch: VoiceLabTakeBatch?
        /// The guard's verdicts before pricing, in place of the real free screen.
        var screenVerdicts: [VoiceGuardVerdict]?
        var screens = 0
        var lostResponseStage: Bool?
        var simulatedRequests: [UUID] = []
        var current = true
        init(root: URL, plan: ClipTakePlan, ledger: VoiceLabSpendLedger, playback: TakeReviewPlayback, source: Project, envelope: AudioEnvelope,
             client: ElevenLabsVoiceLab, store: VoiceConsentStore, record: VoiceConsentRecord) {
            self.root = root; self.plan = plan; self.ledger = ledger; self.playback = playback; self.source = source; self.envelope = envelope
            self.client = client; self.store = store; self.record = record
        }
    }
    private func project(contextWords: Bool = false) throws -> (Project, [Float], AudioEnvelope) {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.id = UUID().uuidString.lowercased()
        project.voiceLab.segments = []; project.voiceLab.assets = []
        project.edits = ProjectEdits()
        project.media.source.durationSeconds = 121
        project.media.source.audio?.sampleRate = 24_000
        let wordCount = contextWords ? 32 : 24
        // A slow speaker: five letters a 3.8 s word, so the calibrated prior (ADR-R43) gives a one-word take about the
        // length the plan's slots were drawn for.
        project.transcript?.words = (0..<wordCount).map { index in
            let start = 0.2 + Double(index) * (contextWords ? 3.5 : 5)
            let text = contextWords ? String(repeating: "context", count: 10) + (index % 4 == 3 ? "." : "") : "older"
            return TimedWord(id: "w\(index)", text: text, start: start, end: start + (contextWords ? 3 : 3.8))
        }
        project.transcript?.durationSeconds = 121
        let source = (0..<(121 * 24_000)).map { index -> Float in
            let seconds = Double(index) / 24_000
            return (4..<5.2).contains(seconds) ? 0.001 : Float(0.1 * sin(2 * Double.pi * 100 * seconds))
        }
        return (project, source, VoiceLabTakeProcessing.envelope(source, sampleRate: 24_000))
    }
    private func hunks(_ indices: [Int], text: String = "Hello") -> [VoiceLabDiffHunk] {
        indices.map { index in
            VoiceLabDiffHunk(kind: .voice, sourceWordIds: ["w\(index)"], newTokens: [text], correctedTexts: [],
                absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: index, sourceEndIndex: index + 1, anchorSeconds: nil)
        }
    }
    private func fixture(indices: [Int] = [3, 10, 17], badPlacement: Bool = false, unknownPrice: Bool = false, dialogue: Bool = false,
                         contextWords: Bool = false) async throws -> Fixture {
        ClipTakeHTTP.state.withLock { $0 = ClipTakeHTTP.State(); $0.listsDialogue = dialogue }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-v18a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
        let shared = try SharedResources.locate()
        let store = VoiceConsentStore(locations: locations)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 80_000), rate: 16_000)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any])
        var statement = try #require(object["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); object["statement"] = statement
        var speaker = try #require(object["speaker"] as? [String: Any]); speaker["threshold"] = 0.45; object["speaker"] = speaker
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClipTakeHTTP.self]
        let ledger = VoiceLabSpendLedger(locations: locations)
        var priceDocument = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json"))) as? [String: Any])
        if unknownPrice {
            let entries = try #require(priceDocument["entries"] as? [[String: Any]])
            priceDocument["entries"] = entries.filter { $0["operation"] as? String != "textToSpeech" }
        }
        let prices = try VoiceLabPriceCatalog(data: JSONSerialization.data(withJSONObject: priceDocument))
        let client = ElevenLabsVoiceLab(keys: ClipTakeKeys(), session: URLSession(configuration: configuration),
            prices: prices, spend: ledger, enforceCapabilities: true)
        let (sourceProject, pcm, envelope) = try project(contextWords: contextWords)
        let project = sourceProject
        let playback = TakeReviewPlayback()
        let audition = VoiceLabAudition(makeBackend: { _, _ in playback })
        weak var fixture: Fixture?
        let plan: ClipTakePlan
        do {
            plan = try ClipTakePlan(project: project, scope: .full, envelope: envelope, hunks: hunks(badPlacement ? [3, 10, 999] : indices), makeInput: { phrase in
                fixture?.decoded += 1
                let silence = try VoiceLabWindowPlanner.lendableSilence(project: sourceProject, scope: .full, window: phrase.window)
                return VoiceLabTakeInput(text: phrase.text, modelID: "eleven_v3", recordID: record.id, language: "en", seed: 7,
                    contentKey: sourceProject.media.source.contentKey, source: VoiceLabSourceExcerpt(whole: pcm), sourceEnvelope: envelope,
                    sourceSampleRate: 24_000, items: sourceProject.transcript?.words ?? [], window: phrase.window,
                    incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, providerConsent: true)
            }, readCap: {
                guard let fixture, let cap = fixture.cap else { return nil }
                let total = await ledger.total(provider: "elevenlabs", at: Date())
                return VoiceLabMonthlyCap(limit: cap, spent: try #require(total).usd)
            }, isCurrent: { fixture?.current ?? true }, audition: audition)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
        let made = Fixture(root: root, plan: plan, ledger: ledger, playback: playback, source: project, envelope: envelope,
            client: client, store: store, record: record); fixture = made
        ClipTakeHTTP.state.withLock { $0.duration = fittingSyntheticDuration(plan.phrases[0].window) }
        let storage = VoiceLabTakeStorage(projectId: project.id, paidRoot: root.appendingPathComponent("VoiceLab"), scratchRoot: root.appendingPathComponent("scratch"))
        let check = VoiceSpeakerCheck(embedder: ClipTakeSpeaker(), calibratedThreshold: 0.45)
        let runs = plan.phrases.map { _ in
            VoiceLabTakeRun(client: client, store: store, speaker: check, storage: storage, dispatchIfCurrent: { [weak plan, weak made] request, start in
                guard let plan else { throw CancellationError() }
                await MainActor.run { made?.beforeDispatch?() }
                try await plan.dispatch(request, start: start)
            }, inputsAreCurrent: { true })
        }
        let real = ClipTakePlan.Backend(runs: runs)
        _ = try await runs[0].discover(language: "en")
        var backend = real
        backend.prepare = { [weak made] inputs, indices, candidates in
            made?.preparations += 1
            await made?.beforeQuote?()
            if let failure = made?.quoteFailure { throw failure }
            do {
                let batch = try await real.prepare(inputs, indices, candidates)
                made?.lastBatch = batch
                return batch
            }
            catch is CancellationError { throw CancellationError() }
            catch { Issue.record("Unexpected quote refusal: \(String(reflecting: error))"); throw error }
        }
        backend.approve = { [weak made] batch, indices, continuing in made?.approved += 1; try await real.approve(batch, indices, continuing) }
        backend.screen = { [weak made] inputs in
            made?.screens += 1
            if let verdicts = made?.screenVerdicts { return verdicts }
            return await real.screen(inputs)
        }
        backend.execute = { [weak made, weak plan] batch, index, phrase, progress in
            if let qa = made?.lostResponseStage {
                guard let plan else { throw CancellationError() }
                var rows: [VoiceLabTakeRow] = []
                for take in batch.windows[index].quote.takes {
                    let requests = qa ? [take.synthesis, take.qa] : [take.synthesis]
                    for request in requests {
                        try await plan.dispatch(request.requestID, start: {})
                        made?.simulatedRequests.append(request.requestID)
                        #expect(await ledger.record(request.estimate, at: Date()) == nil)
                    }
                    rows.append(VoiceLabTakeRow(id: take.synthesis.requestID, index: take.index, seed: take.seed,
                        failure: .provider(.network), quote: take, accepted: Set(requests.map(\.requestID))))
                    await progress(rows)
                }
                return VoiceLabTakeRunResult(rows: rows, end: .completed)
            }
            try await made?.beforePhrase?(phrase)
            let result = try await real.execute(batch, index, phrase) { [weak made] rows in
                await made?.beforeProgress?()
                let transformed = await MainActor.run { rows.map { made?.transformRow?($0) ?? $0 } }
                await progress(transformed)
            }
            try await made?.afterPhrase?(phrase)
            if let failure = made?.fatalResult { return VoiceLabTakeRunResult(rows: result.rows, end: .fatal, failure: failure) }
            return VoiceLabTakeRunResult(rows: result.rows.map { made?.transformRow?($0) ?? $0 }, end: result.end, failure: result.failure)
        }
        backend.finishVoice = { [weak made] in
            let original = await real.finishVoice()
            let checked = made?.transformFinish?(original) ?? original
            guard let failure = made?.finishFailure else { return checked }
            return checked.mapValues { $0.checkingVoice(.perTake, failure: failure) }
        }
        backend.publish = { [weak made] phrase, row, input, date in
            made?.publishedIDs.append(row.id)
            await made?.beforePublish?(phrase)
            let (published, record) = try await real.publish(phrase, row, input, date)
            return (made?.transformPublished?(phrase, published) ?? published, record)
        }
        backend.scratch = { [weak made] phrase, take in
            await made?.beforeScratch?()
            return await real.scratch(phrase, take)
        }
        plan.connect(backend)
        return made
    }

    private func chooseSourceDuration(_ plan: ClipTakePlan) throws {
        for phrase in plan.phrases where phrase.selected?.row.selectable == true {
            let chosen = plan.chooseVideo(.source, phrase: phrase.id)
            let fit = phrase.selected?.row.audio?.fit
            let reason = plan.videoAvailability(phrase: phrase.id).unchangedReason ?? "none"
            try #require(chosen, "\(reason); fit=\(String(describing: fit))")
        }
    }

    private func fittingSyntheticDuration(_ window: VoiceLabWindow) -> Double {
        let duration = window.end - window.start
        let reserve = VoiceLabHardJoin.pauseSeconds(windowDuration: duration)
        let hardSides = [window.leftSeam.kind, window.rightSeam.kind].filter { $0 == .hard }.count
        let trimmedLead = window.leftSeam.kind == .hard ? 0 : max(0, 0.05 - VoiceLabPatchConstants.TTS_TRIM_LEAD)
        return duration - Double(hardSides) * reserve + trimmedLead
    }

    private func sourceAcceptance(_ plan: ClipTakePlan) async throws -> ClipTakePlan.Acceptance {
        try chooseSourceDuration(plan)
        return try await plan.acceptance()
    }

    private static func advisoryRow(_ row: VoiceLabTakeRow, side: VoiceLabJoinAdvisorySeam.Side = .left) -> VoiceLabTakeRow {
        var values = row.qa!.values
        values.lufsJumpLu = 4
        let qa = VoiceLabTakeQAResult(values: values, failures: row.qa!.hardFailures + [.loudness],
            joinSeams: [.init(side: side, excessLu: 4)])
        return VoiceLabTakeRow(id: row.id, index: row.index, seed: row.seed, receipt: row.receipt, audio: row.audio,
            qa: qa, score: 1, failure: row.failure, qaReceipt: row.qaReceipt, generated: row.generated,
            quote: row.quote, accepted: row.acceptedRequestIDs, voiceCheck: row.voiceCheck)
    }

    /// ADR-R39: a fitting take whose only issue is its join is chosen automatically, its advisory accepted, and the
    /// normal duration and Use flow follows with no Use anyway click.
    @Test func aTakeWithOnlyAJoinAdvisoryIsChosenAutomatically() async throws {
        let fixture = try await fixture(indices: [3])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.transformRow = { Self.advisoryRow($0) }
        let plan = fixture.plan
        let before = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        await plan.prepare()
        await plan.start(approved: true)
        let row = try #require(plan.phrases[0].takes.first?.row)
        let selectable = row.selectable
        try #require(selectable && row.qa?.verdict == .passedWithAdvisory)
        #expect(plan.phrases[0].selectedID == row.id && plan.automaticTake(phrase: 0)?.id == row.id)
        let acceptance = try #require(row.acceptedJoinAdvisory)
        #expect(!row.requiresJoinAdvisoryAcceptance && acceptance.acceptedAt >= before && !plan.phrases[0].explicitlySelected)
        #expect(TakeFailurePresentation.joinAdvisory(row, number: 1) == "Take 1 · join may sound slightly louder")
        #expect(plan.offeredTake(phrase: 0) == nil)
        await plan.play(take: row.id, phrase: 0)
        #expect(plan.audition.isPlaying && plan.phrases[0].selectedID == row.id)
        try chooseSourceDuration(plan)
        #expect(plan.canAccept)
        let accepted = try await plan.acceptance(at: Date().addingTimeInterval(1))
        #expect(accepted.segments[0].candidates[0].recipe?.qa.joinAdvisory == acceptance)
        let command = try VoiceLabEditCommand.acceptAll(segments: accepted.segments, assets: accepted.assets, voice: accepted.voice)
        let project = try command.applying(to: fixture.source, outputScope: .full)
        _ = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        let encoded = try JSONProjectStore.encode(project)
        #expect(try JSONProjectStore.encode(JSONProjectStore.decode(encoded)) == encoded)
    }

    @Test func mixedAdvisoryRunKeepsTheCleanTakeSelectedAndExplicitChoiceSurvivesRetry() async throws {
        let fixture = try await fixture(indices: [3])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare()
        await plan.start(approved: true)
        let clean = try #require(plan.phrases[0].selectedID)
        fixture.transformRow = { $0.id == clean ? $0 : Self.advisoryRow($0) }
        await plan.prepareAnother(phrase: 0)
        await plan.tryAnother(phrase: 0, approved: true)
        let advisory = try #require(plan.phrases[0].takes.last?.row)
        try #require(advisory.qa?.verdict == .passedWithAdvisory)
        #expect(advisory.score! >= plan.phrases[0].selected!.row.score!)
        #expect(plan.phrases[0].selectedID == clean && plan.automaticTake(phrase: 0)?.id == clean)
        // The clean take ranks first; the user's click on the advisory take's number chooses it and accepts its join.
        let used = plan.select(take: advisory.id, phrase: 0)
        try #require(used && plan.phrases[0].selected?.row.acceptedJoinAdvisory != nil)
        let acceptance = plan.phrases[0].selected?.row.acceptedJoinAdvisory
        await plan.prepareAnother(phrase: 0)
        await plan.tryAnother(phrase: 0, approved: true)
        #expect(plan.phrases[0].selectedID == advisory.id)
        #expect(plan.phrases[0].selected?.row.acceptedJoinAdvisory == acceptance)
        fixture.transformRow = { $0.id == clean ? $0 : Self.advisoryRow($0, side: .right) }
        fixture.transformFinish = { rows in
            var updates = rows
            updates[advisory.id] = Self.advisoryRow(advisory, side: .right)
            return updates
        }
        await plan.prepareAnother(phrase: 0)
        await plan.tryAnother(phrase: 0, approved: true)
        #expect(plan.phrases[0].selectedID != advisory.id)
        #expect(plan.phrases[0].takes.first(where: { $0.id == advisory.id })?.row.acceptedJoinAdvisory == nil)
    }

    @Test func useAllUsesAnAutomaticallyChosenAdvisoryWithItsAcceptance() async throws {
        let fixture = try await fixture(indices: [3, 10])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.transformRow = { row in
            (row.audio?.fit.plan.windowStart ?? 0) < 20 ? Self.advisoryRow(row) : row
        }
        let plan = fixture.plan
        await plan.prepare()
        await plan.start(approved: true)
        #expect(plan.phrases[0].selectedID != nil && plan.phrases[1].selectedID != nil)
        let accepted = try await sourceAcceptance(plan)
        #expect(accepted.segments.count == 2)
        #expect(accepted.segments.compactMap { $0.candidates[0].recipe?.qa.joinAdvisory }.count == 1)
        #expect(Set(fixture.publishedIDs) == Set([plan.phrases[0].selectedID!, plan.phrases[1].selectedID!]))
    }

    @Test func reviewerUnmeasuredNeedsExplicitSelection() async throws {
        let fixture = try await fixture(indices: [3])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.3 }
        await fixture.plan.prepare()
        await fixture.plan.start(approved: true)
        let row = try #require(fixture.plan.phrases[0].takes.first?.row)
        #expect(row.selectable && row.voiceCheck.evidence?.mode == .unmeasured)
        #expect(fixture.plan.phrases[0].selectedID == nil)
        // ADR-R37: never chosen automatically, but offered for the user's one click (the footer's [Choose Take 1]).
        #expect(fixture.plan.automaticTake(phrase: 0) == nil && fixture.plan.offeredTake(phrase: 0)?.id == row.id)
        #expect(fixture.plan.select(take: row.id, phrase: 0))
        #expect(fixture.plan.offeredTake(phrase: 0) == nil)
    }

    @Test func reviewerRetryCannotBypassFailedPool() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Prepare source consent first; only generated speech is off voice.
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.5 }
        await fixture.plan.prepare()
        ClipTakeHTTP.state.withLock { $0.failGenerated = true }
        await fixture.plan.start(approved: true)
        #expect(fixture.plan.phrases.allSatisfy { $0.takes.first?.row.failure == .qa([.speaker]) })
        await fixture.plan.prepareAnother(phrase: 1)
        await fixture.plan.tryAnother(phrase: 1, approved: true)
        let retry = try #require(fixture.plan.phrases[1].takes.last?.row)
        #expect(retry.voiceCheck.evidence?.mode == .pooled)
        #expect(retry.failure == .qa([.speaker]) && !retry.selectable)
        #expect(fixture.plan.phrases[1].selectedID == nil)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 4 && $0.qa == 4 })
        ClipTakeHTTP.state.withLock { $0.failGenerated = false }
        await fixture.plan.prepareAnother(phrase: 1)
        await fixture.plan.tryAnother(phrase: 1, approved: true)
        let recovered = try #require(fixture.plan.phrases[1].takes.last?.row)
        #expect(recovered.selectable && recovered.qa?.values.speakerScore == 1)
        #expect(fixture.plan.phrases[1].selectedID == recovered.id)
    }

    @Test func reviewerFailedLongTakeBlocksUnmeasuredShortInSameRun() async throws {
        let fixture = try await fixture(indices: [3, 10])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.plan.prepare()
        ClipTakeHTTP.state.withLock { $0.failGenerated = true }
        fixture.afterPhrase = { phrase in
            if phrase == 0 { ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.2 } }
        }
        await fixture.plan.start(approved: true)
        #expect(fixture.plan.phrases[0].takes.first?.row.failure == .qa([.speaker]))
        let short = try #require(fixture.plan.phrases[1].takes.first?.row)
        #expect(short.voiceCheck.evidence?.mode == .unmeasured)
        #expect(!short.selectable && short.failure == .qa([.speaker]))
    }

    @Test(arguments: [VoiceLabTakeFailure.consent(.speakerUnavailable), .provider(.quotaExceeded)])
    func reviewerFinishedPoolNamesConsentOrProviderFailure(failure: VoiceLabTakeFailure) async throws {
        let fixture = try await fixture(indices: [3])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.3 }
        fixture.finishFailure = failure
        await fixture.plan.prepare()
        await fixture.plan.start(approved: true)
        #expect(fixture.plan.phrases[0].status == .failed(TakeFailurePresentation.reason(for: failure)))
    }

    @Test func reviewerFinalizingVoicePreservesSpecificFatalFailure() async throws {
        let fixture = try await fixture(indices: [3])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.3 }
        fixture.fatalResult = .provider(.quotaExceeded)
        await fixture.plan.prepare()
        await fixture.plan.start(approved: true)
        #expect(fixture.plan.phrases[0].status == .failed(TakeFailurePresentation.reason(for: .provider(.quotaExceeded))))
    }

    @Test(arguments: [false, true])
    func reviewerUnmeasuredRetryCannotReplaceMeasuredOrExplicitSelection(explicit: Bool) async throws {
        let fixture = try await fixture(indices: [3])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare()
        await plan.start(approved: true)
        let original = try #require(plan.phrases[0].selectedID)
        if explicit { #expect(plan.select(take: original, phrase: 0)) }
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.3 }
        // Isolate the selection rule from retry borrowing: model a legitimate under-length result
        // with a higher timing rank than the existing measured take.
        let evidence = VoiceLabShortSpeechEvidence(mode: .unmeasured, recordId: fixture.record.id,
            consentMethod: fixture.record.consentMethod, voicedFrames: 16_000, takeCount: 1)
        fixture.transformFinish = { rows in
            rows.mapValues { row in
                let unmeasured = row.checkingVoice(.shortSpeech(evidence))
                return VoiceLabTakeRow(id: row.id, index: row.index, seed: row.seed, receipt: row.receipt,
                    audio: row.audio, qa: unmeasured.qa, score: 1_000, failure: row.failure,
                    qaReceipt: row.qaReceipt, generated: row.generated, quote: row.quote,
                    accepted: row.acceptedRequestIDs, voiceCheck: unmeasured.voiceCheck)
            }
        }
        await plan.prepareAnother(phrase: 0)
        await plan.tryAnother(phrase: 0, approved: true)
        #expect(plan.phrases[0].takes.last?.row.voiceCheck.evidence?.mode == .unmeasured)
        #expect(plan.phrases[0].selectedID == original && plan.automaticTake(phrase: 0)?.id == original)
    }

    @Test func reviewerExplicitUnmeasuredChoiceSurvivesMeasuredRetry() async throws {
        let fixture = try await fixture(indices: [3])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.3 }
        await fixture.plan.prepare()
        await fixture.plan.start(approved: true)
        let original = try #require(fixture.plan.phrases[0].takes.first?.id)
        #expect(fixture.plan.select(take: original, phrase: 0))
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 1 }
        await fixture.plan.prepareAnother(phrase: 0)
        await fixture.plan.tryAnother(phrase: 0, approved: true)
        #expect(fixture.plan.phrases[0].takes.last?.row.qa?.values.speakerScore == 1)
        #expect(fixture.plan.phrases[0].selectedID == original)
    }

    @Test func reviewerMismatchBlocksPreviouslySelectedUnmeasuredTake() async throws {
        let fixture = try await fixture(indices: [3, 10])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.2 }
        await fixture.plan.prepare()
        await fixture.plan.start(approved: true)
        let original = try #require(fixture.plan.phrases[0].takes.first?.id)
        #expect(fixture.plan.select(take: original, phrase: 0))
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 1; $0.failGenerated = true }
        await fixture.plan.prepareAnother(phrase: 1)
        await fixture.plan.tryAnother(phrase: 1, approved: true)
        let earlier = try #require(fixture.plan.phrases[0].takes.first?.row)
        #expect(earlier.failure == .qa([.speaker]) && !earlier.selectable)
        #expect(fixture.plan.phrases[0].selectedID == nil)
        ClipTakeHTTP.state.withLock { $0.failGenerated = false }
        await fixture.plan.prepareAnother(phrase: 1)
        await fixture.plan.tryAnother(phrase: 1, approved: true)
        #expect(fixture.plan.phrases[0].takes.first?.row.selectable == true)
        #expect(fixture.plan.phrases[0].status == .ready)
        #expect(fixture.plan.phrases[0].selectedID == nil)
    }

    @Test func firstRunPoolsThreeShortPhrasesThenRetryBuysOneRequest() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.5 }
        fixture.afterPhrase = { phrase in
            if phrase < 2 {
                #expect(plan.phrases[0].takes.allSatisfy { !$0.row.selectable && $0.row.voiceCheck == .waiting })
            }
        }
        await plan.prepare()
        #expect(plan.estimate?.units == 3)
        await plan.start(approved: true)
        let details = plan.phrases.map { phrase in
            "\(phrase.status): " + phrase.takes.map { "\($0.row.failure), \($0.row.qa), \($0.row.voiceCheck)" }.joined(separator: "; ")
        }
        #expect(plan.phrases.allSatisfy { $0.status == .ready && $0.selected?.row.voiceCheck.evidence?.takeCount == 3 }, "\(details)")
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 3 && $0.qa == 3 })
        let originals = plan.phrases.map(\.selectedID)
        fixture.afterPhrase = nil
        await plan.prepareAnother(phrase: 1)
        #expect(plan.estimate?.units == 1)
        await plan.tryAnother(phrase: 1, approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 4 && $0.qa == 4 })
        #expect(plan.phrases[0].selectedID == originals[0] && plan.phrases[2].selectedID == originals[2])
        #expect(plan.phrases[1].takes.count == 2)
        #expect(plan.phrases[1].takes.last?.row.voiceCheck.evidence?.mode == .pooled)
        #expect(plan.phrases[1].takes.last?.row.voiceCheck.evidence?.takeCount == 2)
    }

    @Test func stopFinalizesTheCompletedShortPoolWithoutBuyingExtraAudio() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let barrier = ClipTakeBarrier()
        ClipTakeHTTP.state.withLock { $0.voicedFraction = 0.35 }
        fixture.beforePhrase = { phrase in if phrase == 1 { await barrier.pause() } }
        await fixture.plan.prepare()
        let operation = Task { await fixture.plan.start(approved: true) }
        await barrier.wait()
        await fixture.plan.stop()
        await operation.value
        let rows = fixture.plan.phrases[0].takes.map { "\($0.row.failure), \($0.row.qa), \($0.row.voiceCheck)" }
        let row = try #require(fixture.plan.phrases[0].takes.first?.row, "\(rows)")
        #expect(fixture.plan.phrases[0].selectedID == nil)
        #expect(fixture.plan.select(take: row.id, phrase: 0))
        #expect(row.selectable && row.voiceCheck.evidence?.mode == .unmeasured)
        #expect(row.shortPhraseCopy == "voice couldn't be measured (under 3 s of speech)")
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 && $0.qa == 1 })
    }

    @Test func threePhrasesQuoteOneSetAndWaitForApprovalThenFit() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        #expect(plan.phrases.count == 3)
        await plan.prepare()
        #expect(fixture.preparations == 1 && fixture.decoded == 3)
        #expect(plan.cost != nil && plan.estimate?.units == 3)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
        await plan.start(approved: false)
        #expect(fixture.approved == 0)
        await plan.start(approved: true)
        #expect(plan.problem.isEmpty, "\(plan.problem), \(plan.phrases.map(\.status))")
        let allReadyAndFitting = plan.phrases.allSatisfy { $0.status == .ready && $0.takes.count == 1 && $0.selected?.fits == true }
        #expect(allReadyAndFitting,
                "\(plan.phrases.map { $0.takes.map { String(describing: $0.row.failure) } })")
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 3 && $0.qa == 3 })
        let spent = await fixture.ledger.total(provider: "elevenlabs", at: Date())
        #expect(plan.spent.usd == spent?.usd)
        for index in plan.phrases.indices { #expect(plan.chooseVideo(.source, phrase: index)) }
        let acceptance = try await sourceAcceptance(plan)
        #expect(acceptance.segments.count == 3 && !acceptance.assets.isEmpty)
        let selected = try #require(plan.phrases.first?.selectedID)
        let scratch = await plan.scratch(take: selected, phrase: 0)
        #expect(scratch?.isValid == true)
    }

    /// MVP23: a full take's Rewrite of more phrases than one batch holds is priced once, approved once, and voiced part by
    /// part, each later part quoted again just before it runs.
    @Test func aLongRunPricesOnceAndVoicesEveryPartUnderOneApproval() async throws {
        let fixture = try await fixture(indices: Array(stride(from: 4, to: 24, by: 3)))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        #expect(plan.phrases.count == 7 && ClipTakePlan.parts(plan.phrases.map(\.id)).map(\.count) == [5, 2])
        await plan.prepare()
        #expect(plan.problem.isEmpty, "\(plan.problem)")
        #expect(fixture.preparations == 2 && fixture.decoded == 7 && plan.estimate?.units == 7 && plan.cost != nil)
        #expect(plan.preparationStep == nil && !plan.preparing)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
        await plan.start(approved: true)
        #expect(plan.problem.isEmpty, "\(plan.problem), \(plan.phrases.map(\.status))")
        #expect(fixture.preparations == 3 && fixture.approved == 2)
        #expect(plan.phrases.allSatisfy { $0.status == .ready && $0.takes.count == 1 && $0.selected?.fits == true },
                "\(plan.phrases.map(\.status))")
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 7 && $0.qa == 7 })
        let spent = await fixture.ledger.total(provider: "elevenlabs", at: Date())
        #expect(plan.spent.usd == spent?.usd && plan.spent.units == 7)
        let acceptance = try await sourceAcceptance(plan)
        #expect(acceptance.segments.count == 7)
    }

    @Test func aLaterPartThatCannotBeQuotedAgainStopsWithNothingMoreSent() async throws {
        let fixture = try await fixture(indices: Array(stride(from: 4, to: 24, by: 3)))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare()
        fixture.quoteFailure = VoiceLabError.consentRequired
        await plan.start(approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 5 })
        #expect(plan.phrases.prefix(5).allSatisfy { $0.selected != nil })
        let stopped = plan.phrases.dropFirst(5).allSatisfy { phrase in
            if case .stopped(let reason) = phrase.status { return reason.contains("Nothing sent for this phrase.") }
            return false
        }
        #expect(stopped, "\(plan.phrases.map(\.status))")
        #expect(plan.problem == ClipTakePlan.copy(VoiceLabError.consentRequired) && plan.problem != UserMessages.generic)
        #expect(!plan.generating && plan.approvalID == nil)
    }

    @Test func unplaceableSetDoesNotDecodeOrQuote() async throws {
        do {
            let fixture = try await fixture(badPlacement: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            await fixture.plan.prepare()
            #expect(fixture.decoded == 0 && fixture.preparations == 0)
        } catch {
            guard case .placement(.geometry(.unknownWord("w999")), _)? = error as? ClipTakePlan.Failure else { Issue.record("\(error)"); return }
        }
        #expect(ClipTakeHTTP.state.withLock { $0.gets == 0 && $0.texts.isEmpty })
    }

    @Test func capCrossingAfterPhraseTwoKeepsTakesAndStopsBeforeThree() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.cap = 1
        fixture.afterPhrase = { phrase in
            if phrase == 1 {
                let external = CostEstimate(provider: "elevenlabs", operation: "other", units: 1, unit: "request", usd: 1, basis: "fixture")
                #expect(await fixture.ledger.record(external, at: Date()) == nil)
            }
        }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 2 })
        #expect(fixture.plan.phrases[0].selected != nil && fixture.plan.phrases[1].selected != nil)
        #expect(fixture.plan.phrases[2].takes.isEmpty)
        #expect(fixture.plan.problem == ClipTakePlan.copy(ClipTakePlan.Failure.spendingCap))
    }

    /// MVP18: phrase 1's v4 replies carried no usable timing and every later phrase stopped with "can't be checked yet".
    /// Now the take's own word check (its approved Scribe request, used once) times it; phrase 2 and 3 are still sent.
    @Test(arguments: ["eleven_v3", "eleven_v4"])
    func aTimingFailureIsRecoveredFromTheWordCheckAndLaterPhrasesAreSent(model: String) async throws {
        let fixture = try await fixture(dialogue: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        #expect(plan.changeModel(model))
        ClipTakeHTTP.state.withLock { $0.malformedSynthesis = true; $0.echoQA = true }
        fixture.afterPhrase = { phrase in if phrase == 0 { ClipTakeHTTP.state.withLock { $0.malformedSynthesis = false } } }
        await plan.prepare()
        await plan.start(approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 3 && $0.qa == 3 })
        let recovered = try #require(plan.phrases[0].takes.first)
        #expect(recovered.row.failure == nil && recovered.row.audio != nil && recovered.row.qa?.passed == true,
            "\(String(describing: recovered.row.failure)) \(plan.phrases[0].takeDetail)")
        #expect(recovered.row.qaReceipt != nil && recovered.length != nil)
        for phrase in plan.phrases {
            #expect(phrase.takes.count == 1, "\(phrase.status)")
            if case .stopped(let message) = phrase.status { Issue.record("phrase \(phrase.id + 1) stopped: \(message)") }
        }
        #expect(plan.phrases.allSatisfy { $0.selected != nil })
    }

    /// The word check heard other words in a take with no provider timing: its timing is still recovered, and the take
    /// is left out by the word check, never for timing. The run goes on.
    @Test func aRecoveredTakeWithDifferentWordsFailsTheWordCheckNotTiming() async throws {
        let fixture = try await fixture(dialogue: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.plan.changeModel("eleven_v4"))
        ClipTakeHTTP.state.withLock { $0.malformedSynthesis = true; $0.failQA = true }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 3 && $0.qa == 3 })
        for phrase in fixture.plan.phrases {
            let take = try #require(phrase.takes.first)
            #expect(take.row.failure == .qa([.transcript]) && take.length != nil, "\(String(describing: take.row.failure))")
        }
    }

    @Test func aSegmentFailureIsRecoveredAndKeepsTheBatchMoving() async throws {
        let fixture = try await fixture(dialogue: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.plan.changeModel("eleven_v4"))
        ClipTakeHTTP.state.withLock { $0.malformedSegments = true; $0.echoQA = true }
        fixture.afterPhrase = { phrase in if phrase == 0 { ClipTakeHTTP.state.withLock { $0.malformedSegments = false } } }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 3 && $0.qa == 3 })
        let recovered = try #require(fixture.plan.phrases[0].takes.first)
        #expect(recovered.row.failure == nil && recovered.row.receipt != nil)
        #expect(fixture.plan.phrases.allSatisfy { phrase in
            phrase.takes.count == 1 && phrase.takes[0].row.qa != nil
        })
    }

    @Test(arguments: [false, true])
    func aNonfatalQAFailureKeepsTheBatchMoving(malformed: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.failQA = !malformed; $0.malformedQA = malformed }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 3 && $0.qa == 3 })
        #expect(fixture.plan.phrases.allSatisfy { phrase in
            guard phrase.takes.count == 1 else { return false }
            let row = phrase.takes[0].row
            return malformed ? row.failure == .provider(.malformedResponse) : row.qa?.failures.contains(.transcript) == true
        })
    }

    @Test func aFatalAccountFailureLabelsAllUnsentPhrasesWithItsCause() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.fatalResult = .provider(.quotaExceeded)
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        let reason = TakeFailurePresentation.reason(for: .provider(.quotaExceeded))
        for phrase in fixture.plan.phrases.dropFirst() {
            #expect(phrase.status == .stopped("Stopped: \(reason) Nothing sent for this phrase. Add credit to your ElevenLabs account, then choose Price a take."))
            #expect(phrase.takes.isEmpty)
        }
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    @Test func stopKeepsFinishedTakesAndLabelsStoppedSlot() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let barrier = ClipTakeBarrier()
        fixture.beforePhrase = { phrase in if phrase == 1 { await barrier.pause() } }
        await fixture.plan.prepare()
        let operation = Task { await fixture.plan.start(approved: true); barrier.finished() }
        await barrier.wait()
        try #require(fixture.plan.generating, "\(fixture.plan.problem), \(fixture.plan.phrases.map(\.status))")
        #expect(fixture.plan.phrases[1].status == .generating("Phrase 2 of 3…"))
        await fixture.plan.stop(); await operation.value
        #expect(fixture.plan.phrases[0].takes.count == 1 && fixture.plan.phrases[0].selected != nil)
        #expect(fixture.plan.phrases[1].status == .stopped("Take 1 stopped."))
        #expect(fixture.plan.phrases[2].status == .waiting)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
        let output = try await sourceAcceptance(fixture.plan)
        #expect(output.segments.count == 1)
    }

    @Test func tryAnotherPricesOnlyPhraseTwoAndKeepsTheOtherSelections() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare(); await plan.start(approved: true)
        let first = plan.phrases[0].selectedID, last = plan.phrases[2].selectedID
        await plan.prepareAnother(phrase: 1)
        #expect(plan.estimate?.units == 1 && fixture.preparations == 2)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 3 })
        await plan.tryAnother(phrase: 1, approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 4 && $0.qa == 4 })
        #expect(plan.phrases[0].selectedID == first && plan.phrases[2].selectedID == last)
        #expect(plan.phrases[1].takes.map(\.number) == [1, 2])
        let earlier = try #require(plan.phrases[1].takes.first)
        let selected = plan.select(take: earlier.id, phrase: 1)
        #expect(selected)
        #expect(plan.phrases[1].selectedID == earlier.id && plan.phrases[1].lengthDifference != nil)
        let kept = await plan.scratch(take: earlier.id, phrase: 1)
        #expect(kept?.isValid == true)
        let output = try await sourceAcceptance(plan)
        #expect(output.segments.count == 3)
    }

    @Test func retriesUseFreshSeedsAndKeepThreeSlots() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare(); await plan.start(approved: true)
        let original = try #require(plan.phrases[0].selectedID)
        var held: [UUID: VoiceLabTakeScratch] = [:]
        let initialScratch = try #require(await plan.scratch(take: original, phrase: 0))
        held[original] = initialScratch
        for _ in 0..<3 {
            await plan.prepareAnother(phrase: 0)
            await plan.tryAnother(phrase: 0, approved: true)
            for take in plan.phrases[0].takes {
                let scratch = try #require(await plan.scratch(take: take.id, phrase: 0))
                held[take.id] = scratch
            }
        }
        #expect(ClipTakeHTTP.state.withLock { $0.seeds == [7, 8, 9, 10] })
        #expect(plan.phrases[0].takes.count == 3)
        #expect(plan.phrases[0].takes.map(\.number).sorted() == [1, 2, 3])
        #expect(plan.phrases[0].takes.contains { $0.id == original })
        #expect(held.count == 4 && held.values.filter(\.isValid).count == 3)
        let selected = try #require(plan.phrases[0].selectedID)
        let scratch = await plan.scratch(take: selected, phrase: 0)
        #expect(scratch?.isValid == true)
        let output = try await sourceAcceptance(plan)
        #expect(output.segments.count == 1)
    }

    @Test func repeatedRetryRetiresOnlyEvictedScratchesAndDrainsConsumers() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare(); await plan.start(approved: true)
        let selected = try #require(plan.phrases[0].selectedID)
        for _ in 0..<2 { await plan.prepareAnother(phrase: 0); await plan.tryAnother(phrase: 0, approved: true) }
        #expect(plan.select(take: selected, phrase: 0))
        let number = plan.phrases[0].nextTakeNumber
        let evicted = try #require(plan.phrases[0].takes.first { $0.number == number })
        let scratch = try #require(await plan.scratch(take: evicted.id, phrase: 0))
        let privateMixed = scratch.mixedAudioURL.deletingLastPathComponent()
        let privatePaid = scratch.fitted.snapshot.url.deletingLastPathComponent()
        let barrier = ClipTakeBarrier()
        _ = try scratch.attach {
            #expect(FileManager.default.fileExists(atPath: privateMixed.path) && FileManager.default.fileExists(atPath: privatePaid.path))
            await barrier.pause()
        }
        await plan.prepareAnother(phrase: 0)
        let retry = Task { await plan.tryAnother(phrase: 0, approved: true) }
        await barrier.wait()
        #expect(!scratch.isValid && plan.generating)
        #expect(FileManager.default.fileExists(atPath: privateMixed.path) && FileManager.default.fileExists(atPath: privatePaid.path))
        #expect(plan.phrases[0].selectedID == selected)
        barrier.resume(); await retry.value
        #expect(!FileManager.default.fileExists(atPath: privateMixed.path) && !FileManager.default.fileExists(atPath: privatePaid.path))
        #expect(await plan.scratch(take: evicted.id, phrase: 0) == nil)
        var allIDs = Set(plan.phrases[0].takes.map(\.id)); allIDs.insert(evicted.id)
        for _ in 0..<4 {
            #expect(plan.select(take: selected, phrase: 0))
            await plan.prepareAnother(phrase: 0); await plan.tryAnother(phrase: 0, approved: true)
            allIDs.formUnion(plan.phrases[0].takes.map(\.id))
            var live = 0
            for id in allIDs {
                if let retained = await plan.scratch(take: id, phrase: 0) { #expect(retained.isValid); live += 1 }
            }
            #expect(live == 3 && plan.phrases[0].takes.count == 3 && plan.phrases[0].takes.contains { $0.id == selected })
            for take in plan.phrases[0].takes {
                #expect(plan.select(take: take.id, phrase: 0))
                #expect(try await sourceAcceptance(plan).segments.count == 1)
            }
        }
        var survivors: [VoiceLabTakeScratch] = []
        for take in plan.phrases[0].takes { survivors.append(try #require(await plan.scratch(take: take.id, phrase: 0))) }
        plan.invalidate(); await plan.invalidation?.value
        #expect(survivors.allSatisfy { !$0.isValid })
        let paid = fixture.root.appendingPathComponent("VoiceLab").appendingPathComponent(fixture.source.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paid.path).contains { $0.hasSuffix(".wav") })
    }

    @Test func changedLengthIsVisibleButCannotBeAccepted() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        ClipTakeHTTP.state.withLock { $0.duration += 2.5; $0.speechMargin = 0.15 }
        await plan.prepare(); await plan.start(approved: true)
        let phrase = plan.phrases[0]
        #expect(phrase.takes.count == 1)
        #expect(phrase.selected != nil && phrase.selected?.fits == false,
                "\(phrase.takes.map { String(describing: $0.row.failure) })")
        #expect((phrase.lengthDifference ?? 0) > 1)
        await #expect(throws: ClipTakePlan.Failure.noSelection) { try await plan.acceptance() }
        let (editor, session) = session(fixture)
        defer { editor.close() }
        #expect(!plan.videoAvailability(phrase: 0).allows(.source))
        #expect(!plan.videoAvailability(phrase: 0).allows(.retimed))
        #expect(session.takeNeedsWordingRecovery(phrase, plan: plan))
        let recovery = PhraseTimingRecovery(priceAnyway: false, action: { _ in })
        #expect(recovery.retryTitle == "Ask for shorter")
    }

    @Test func individualFirstTakeQuoteSaysMakeTake() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture)
        defer { editor.close() }
        await fixture.plan.prepare()
        await fixture.plan.prepareAnother(phrase: 0)
        session.takeQuotePhrase = 0
        #expect(fixture.plan.phrases[0].takes.isEmpty)
        let action = try #require(session.pricedTakeAction(phrase: 0))
        #expect(action.title.hasPrefix("Make take · ≈ $"))
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
    }

    @Test func aFailedRetryShowsItsReasonAndKeepsTheEarlierTakeUsable() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare(); await plan.start(approved: true)
        let selected = plan.phrases[0].selectedID
        ClipTakeHTTP.state.withLock { $0.synthesisStatus = 401 }
        await plan.prepareAnother(phrase: 0); await plan.tryAnother(phrase: 0, approved: true)
        #expect(plan.phrases[0].selectedID == selected)
        #expect(plan.phrases[0].status == .failed(RewriteSession.refusal(VoiceLabError.unauthorized)))
        #expect(plan.spent.units == 1)
        let output = try await sourceAcceptance(plan)
        #expect(output.segments.count == 1)
    }

    @Test func singlePhraseUsesTheSamePlanAndCapsBeforeAnyRequest() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.plan.prepare()
        #expect(fixture.plan.estimate?.units == 1)
        fixture.cap = 0
        await fixture.plan.start(approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
        #expect(fixture.plan.problem == ClipTakePlan.copy(ClipTakePlan.Failure.spendingCap))
    }

    @Test func capCrossingBeforeQAHasAnExplicitStopReason() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        var dispatches = 0
        fixture.beforeDispatch = { [weak fixture] in
            dispatches += 1
            if dispatches == 2 { fixture?.cap = 0 }
        }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 && $0.qa == 0 })
        let copy = ClipTakePlan.copy(ClipTakePlan.Failure.spendingCap)
        #expect(fixture.plan.problem == copy)
        #expect(fixture.plan.phrases[0].status == .failed(copy))
        #expect(fixture.plan.spent.units == 1)
        #expect(fixture.plan.phrases[0].takes.count == 1)
    }

    @Test func failedSpeechChecksLeaveThePhraseUnselected() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.failQA = true }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        #expect(fixture.plan.phrases[0].selected == nil && fixture.plan.phrases[0].takes.count == 1)
        #expect(fixture.plan.phrases[0].status == .failed("These takes didn't sound right. Edit the words or try again."))
        await #expect(throws: ClipTakePlan.Failure.noSelection) { try await fixture.plan.acceptance() }
    }

    @Test(arguments: zip([false, false, true, true], [false, true, false, true]))
    func acceptedMalformedOrLostResponsesRetainAvailableReceiptsWithoutAutomaticResend(qa: Bool, lost: Bool) async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock {
            $0.malformedSynthesis = !qa && !lost; $0.malformedQA = qa && !lost
        }
        fixture.lostResponseStage = lost ? qa : nil
        let attempts = 1
        await fixture.plan.prepare()
        let quotes = try #require(fixture.lastBatch?.windows.first?.quote.takes)
        await fixture.plan.start(approved: true)
        let rows = fixture.plan.phrases[0].takes.map(\.row)
        // A malformed synthesis reply's paid audio is timed from its own word check (voice-lab §8.5): that one approved
        // Scribe request is its QA, never a resend.
        let recovered = !qa && !lost
        #expect(rows.count == attempts && rows.allSatisfy { recovered ? $0.qaReceipt != nil : !$0.selectable && $0.qaReceipt == nil })
        #expect(rows.allSatisfy { ($0.receipt != nil) == !lost && (recovered || $0.acceptedRequestIDs.count == (qa ? 2 : 1)) })
        if recovered {
            #expect(rows.allSatisfy { $0.receipt != nil && $0.receipt == $0.generated?.receipt && $0.generated?.alignment != nil })
        }
        let accepted = Set(rows.flatMap(\.acceptedRequestIDs))
        let expectedIDs = Set(quotes.prefix(attempts).flatMap { qa ? [$0.synthesis.requestID, $0.qa.requestID] : [$0.synthesis.requestID] })
        #expect(recovered || accepted == expectedIDs)
        if lost {
            #expect(fixture.simulatedRequests.count == expectedIDs.count && Set(fixture.simulatedRequests) == expectedIDs)
            #expect(Set(quotes.prefix(attempts).map(\.seed)).count == attempts)
            #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
        } else {
            #expect(ClipTakeHTTP.state.withLock { $0.texts.count == attempts && $0.qa == (qa || recovered ? attempts : 0) && Set($0.seeds).count == attempts })
        }
        #expect(fixture.plan.spent.units == Double(attempts) && (recovered || fixture.plan.phrases[0].selected == nil))
        guard !recovered else { return }
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: Date())?.usd == fixture.plan.spent.usd)
        await #expect(throws: ClipTakePlan.Failure.noSelection) { try await fixture.plan.acceptance() }
    }

    @Test(arguments: [false, true]) func unknownTakePricesStayExplicitAndCannotBypassACap(capped: Bool) async throws {
        let fixture = try await fixture(indices: [10], unknownPrice: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        if capped { fixture.cap = 1 }
        await fixture.plan.prepare()
        #expect(fixture.plan.estimate?.usd == nil)
        guard case .confirm = try #require(fixture.plan.cost) else { Issue.record("Unknown prices require inline confirmation"); return }
        await fixture.plan.start(approved: true)
        let total = try #require(await fixture.ledger.total(provider: "elevenlabs", at: Date()))
        if capped {
            #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
            #expect(fixture.plan.problem == ClipTakePlan.copy(ClipTakePlan.Failure.unknownSpend))
            #expect(total.usd == 0 && total.unknownCount == 0)
        } else {
            #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 && $0.qa == 1 })
            #expect(fixture.plan.spent.usd == nil && fixture.plan.spent.units == 1 && total.unknownCount == 1)
            #expect(fixture.plan.phrases[0].selected?.fits == true)
        }
    }

    @Test func capChangingAtRetryDispatchKeepsSelectionAndRequiresAFreshQuote() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        let selected = fixture.plan.phrases[0].selectedID
        let spent = fixture.plan.spent
        await fixture.plan.prepareAnother(phrase: 0)
        fixture.beforeDispatch = { [weak fixture] in fixture?.cap = 0 }
        await fixture.plan.tryAnother(phrase: 0, approved: true)
        #expect(fixture.plan.phrases[0].selectedID == selected && fixture.plan.spent == spent)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 && $0.qa == 1 })
        #expect(fixture.plan.problem == ClipTakePlan.copy(ClipTakePlan.Failure.spendingCap))
        fixture.beforeDispatch = nil; fixture.cap = 1
        await fixture.plan.tryAnother(phrase: 0, approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
        await fixture.plan.prepareAnother(phrase: 0); await fixture.plan.tryAnother(phrase: 0, approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 2 && Set($0.seeds).count == 2 })
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: Date())?.usd == fixture.plan.spent.usd)
    }

    @Test func stopAfterTransportAcceptanceDrainsAndAccountsWithoutResend() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let barrier = ClipTakeBarrier()
        fixture.beforeProgress = { await barrier.pause() }
        await fixture.plan.prepare()
        let generating = Task { await fixture.plan.start(approved: true); barrier.finished() }
        await barrier.wait()
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 && $0.qa == 1 })
        await fixture.plan.stop(); await generating.value
        #expect(!fixture.plan.generating && !fixture.plan.preparing && !fixture.plan.audition.isPlaying)
        #expect(fixture.plan.spent.units == 1)
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: Date())?.usd == fixture.plan.spent.usd)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 && $0.qa == 1 })
        let row = try #require(fixture.plan.phrases[0].selected?.row)
        #expect(row.selectable && row.fits && row.acceptedRequestIDs.count == 2)
    }

    @Test func ownerMismatchMakesNoPaidRequest() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.failOwner = true }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
        // The guard's refusal settles the phrase (voice-lab §6.9): said once, nothing priced for it again, no run-level problem.
        let stop = ClipTakePlan.blockedCopy(.consent(.voiceOwnerMismatch))
        #expect(stop.hasPrefix(RewriteSession.refusal(VoiceConsentError.voiceOwnerMismatch)) && stop.hasSuffix("Nothing sent for this phrase."))
        #expect(fixture.plan.phrases[0].status == .failed(stop) && fixture.plan.phrases[0].blocked == stop,
                "\(fixture.plan.phrases[0].takes.map { String(describing: $0.row.failure) })")
        #expect(fixture.plan.problem.isEmpty && fixture.plan.voiceableIndices.isEmpty && fixture.plan.settledWithBlocks)
        await fixture.plan.prepareAnother(phrase: 0)
        #expect(fixture.plan.approvalID == nil && ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
    }

    @Test func getPriceNeverPricesAPhraseTheGuardBlocks() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        // The free local screen (ADR-R41) blocks phrase 2 before any quote.
        fixture.screenVerdicts = [.passes(.statement(score: 0.9)), .blocked(.voiceOwnerMismatch), .passes(.reference(score: 0.8, contentKey: "x"))]
        var blocked: [Int] = []
        fixture.plan.onBlocked = { phrase, _ in blocked.append(phrase) }
        await fixture.plan.prepare()
        #expect(fixture.screens == 1)
        #expect(blocked == [1])
        #expect(fixture.plan.phrases[1].blocked == ClipTakePlan.blockedCopy(.consent(.voiceOwnerMismatch)))
        #expect(fixture.plan.voiceableIndices == [0, 2])
        // The quote and its approval cover phrases 1 and 3 only; nothing was sent.
        let batch = try #require(fixture.lastBatch)
        #expect(batch.windows.count == 2)
        #expect(fixture.plan.approvalID != nil && fixture.plan.cost != nil)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
        #expect(!fixture.plan.learnedFromThisVideo, "phrase 3 matched another video's reference")
        // A later price of the same plan still leaves phrase 2 out.
        fixture.screenVerdicts = [.passes(.statement(score: 0.9)), .passes(.statement(score: 0.9)), .passes(.statement(score: 0.9))]
        await fixture.plan.prepareAnother(phrase: 1)
        #expect(fixture.plan.phrases[1].blocked != nil && fixture.preparations == 1)
    }

    @Test func everyPhraseBlockedBeforePricingAsksForNoPrice() async throws {
        let fixture = try await fixture(indices: [3, 10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.screenVerdicts = [.blocked(.voiceOwnerMismatch), .blocked(.speakerMismatch)]
        await fixture.plan.prepare()
        #expect(fixture.preparations == 0 && fixture.plan.approvalID == nil && fixture.plan.cost == nil)
        #expect(fixture.plan.settledWithBlocks)
        #expect(fixture.plan.phrases[1].blocked == ClipTakePlan.blockedCopy(.consent(.speakerMismatch)))
    }

    @Test func aPhraseMatchedThroughThisVideosReferenceSaysSo() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.screenVerdicts = [.passes(.reference(score: 0.8, contentKey: fixture.source.media.source.contentKey))]
        await fixture.plan.prepare()
        #expect(fixture.plan.learnedFromThisVideo && fixture.plan.voiceableIndices == [0] && fixture.preparations == 1)
    }

    @Test func stoppingQuotePreparationDrainsItBeforeTheNextQuote() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let barrier = ClipTakeBarrier()
        fixture.beforeQuote = { await barrier.pause() }
        let preparing = Task { await fixture.plan.prepare(); barrier.finished() }
        await barrier.wait()
        try #require(fixture.plan.preparing)
        await fixture.plan.stop(); await preparing.value
        #expect(!fixture.plan.preparing && fixture.plan.cost == nil)
        fixture.beforeQuote = nil
        await fixture.plan.prepare()
        #expect(fixture.plan.cost != nil && fixture.preparations == 2)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
    }

    @Test func changedInputsRefuseStalePublicationAndDispatch() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        try chooseSourceDuration(fixture.plan)
        fixture.beforePublish = { [weak fixture] _ in fixture?.current = false }
        await #expect(throws: ClipTakePlan.Failure.stale) { try await fixture.plan.acceptance() }
        await fixture.plan.prepareAnother(phrase: 0)
        #expect(fixture.plan.cost == nil)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    @Test func completeSetPreflightChecksTheSourceBetweenBothWindows() throws {
        let (project, _, envelope) = try project()
        let phrases = try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope, hunks: hunks([3, 10]))
        let first = phrases[0].window
        var second = phrases[1].window
        second.start = first.end + 0.001; second.startSample = first.endSample + 24
        second.leftSeam.time = second.start; second.leftSeam.sample = second.startSample
        second.leftSeam.fadeSamples = 288
        try VoiceLabRenderContract.validatePlacement(project, scope: .full, window: first)
        try VoiceLabRenderContract.validatePlacement(project, scope: .full, window: second)
        #expect(throws: (any Error).self) {
            try VoiceLabRenderContract.validatePlacement(project, scope: .full, windows: [first, second])
        }
    }

    @Test func anOldApprovalCannotRunANewQuote() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.plan.prepare()
        let old = fixture.plan.approvalID
        await fixture.plan.prepareAnother(phrase: 0)
        await fixture.plan.start(approved: true, quoteID: old)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
        await fixture.plan.tryAnother(phrase: 0, approved: true, quoteID: fixture.plan.approvalID)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    @Test func rewritingAgainCannotSilentlyDiscardThePlansPaidTakes() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": fixture.root.path]))
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        let shared = try SharedResources.locate()
        let project = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let scenes = DebugRewrite.proposalScenes(app: app, fixture: project)
        defer { for scene in scenes { scene.editor?.close() } }
        let editor = try #require(scenes.first { $0.name == "r2-make-takes" }?.editor)
        let session = try #require(editor.openRewrite)
        session.showProposal()
        #expect(!session.hasPaidTakes)
        session.takePlan = fixture.plan
        #expect(session.hasPaidTakes)
        editor.sendRewriteAgain(session)
        #expect(session.task.confirm?.question == "Discard these 3 changes?")
        #expect(!fixture.plan.generating && fixture.plan.phrases[0].selected != nil)
    }

    private func session(_ fixture: Fixture) -> (EditorModel, RewriteSession) {
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": fixture.root.path]))
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: fixture.source, demo: true), app: app, preview: DemoPreviewEngine())
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: fixture.envelope, connector: nil)
        editor.rewrite = session
        session.takePlan = fixture.plan
        return (editor, session)
    }

    private func productionSession(_ fixture: Fixture, touchingVoices: Bool = false, exactSourceEnvelope: Bool = false,
                                   rewriteConnector: (any LLMConnector)? = nil, v4Available: Bool = true,
                                   voices: [Int]? = nil, extraHunks: [VoiceLabDiffHunk] = [], prepare: Bool = true,
                                   edit: (inout Project) -> Void = { _ in }) async throws -> (EditorModel, RewriteSession) {
        ClipTakeHTTP.state.withLock { $0.listsDialogue = v4Available }
        var source = fixture.source
        edit(&source)
        let (_, pcm, _) = try project()
        let audio = fixture.root.appendingPathComponent("source.wav")
        try VoiceTrainingAudio.wav(Array(pcm.prefix(120 * 24_000)), rate: 24_000).write(to: audio)
        source.media.source.absolutePath = audio.path
        source.media.source.durationSeconds = 120
        source.transcript?.durationSeconds = 120
        let bridgeEnd = try #require(source.transcript?.words[10].start)
        source.transcript?.words[9].end = bridgeEnd
        if touchingVoices {
            let touchingStart = try #require(source.transcript?.words[10].end)
            source.transcript?.words[11].start = touchingStart
        }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": fixture.root.path]))
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: source, demo: true), app: app, preview: DemoPreviewEngine())
        let envelope: AudioEnvelope
        if exactSourceEnvelope {
            let decoded = try await VoiceLabSourceAudio.rewriteSource(source: audio, frames: 120 * 24_000, sampleRate: 24_000,
                window: fixture.plan.phrases[0].window, incomingSilence: nil, outgoingSilence: nil,
                items: source.transcript?.words ?? [])
            envelope = decoded.envelope
        } else { envelope = fixture.envelope }
        let connector = rewriteConnector.map { RewriteConnector(connector: $0, model: "fixture", name: "Fixture", group: "local", plan: "") }
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: envelope, connector: connector)
        editor.rewrite = session
        let fix = VoiceLabDiffHunk(kind: .textOnly, sourceWordIds: ["w9"], newTokens: ["Corrected"], correctedTexts: ["Corrected"],
            absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 9, sourceEndIndex: 10, anchorSeconds: nil)
        let received = ([fix] + hunks(voices ?? (touchingVoices ? [10, 11] : [10])) + extraHunks).sorted { $0.sourceStartIndex < $1.sourceStartIndex }
        session.receive(received.map { RewriteChange(hunk: $0) })
        session.finishRun(seconds: 1); session.showProposal()
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        session.showProposal()
        session.configureGeneration(client: fixture.client, store: fixture.store,
            speaker: VoiceSpeakerCheck(embedder: ClipTakeSpeaker(), calibratedThreshold: 0.45))
        let factory = try #require(session.takeBackend)
        session.takeBackend = { count, dispatch in
            var backend = factory(count, dispatch)
            let execute = backend.execute
            backend.execute = { batch, index, phrase, progress in
                try await execute(batch, index, phrase) { rows in
                    await fixture.beforeProgress?()
                    await progress(rows)
                }
            }
            let publish = backend.publish
            backend.publish = { phrase, row, input, date in
                await fixture.beforePublish?(phrase)
                return try await publish(phrase, row, input, date)
            }
            return backend
        }
        let generation = try #require(session.generation)
        generation.prepareQuote = {}
        await generation.discover(language: "en"); await generation.finishQuotePreparationForTests()
        if !v4Available || !prepare { return (editor, session) }
        await session.prepareTakes()
        let plan = try #require(session.takePlan)
        #expect(plan.problem.isEmpty, "\(plan.problem), \(generation.problem)")
        #expect(plan.phrases[0].text.contains("Corrected"))
        #expect(plan.phrases[0].window.leftBridgeWordIds.contains("w9"))
        #expect(plan.approvalID != nil && plan.stillCurrent)
        ClipTakeHTTP.state.withLock { $0.duration = fittingSyntheticDuration(plan.phrases[0].window); $0.echoQA = true }
        return (editor, session)
    }

    /// MVP48: one phrase that can't be placed stopped the whole plan after Claude's rewrite, with "This change can't be
    /// placed in this take." The review places each voice change without the rewrite's own cuts, so a change beside a
    /// cut the rewrite proposes passes the review and is refused only by the plan. Now that change keeps its original
    /// words, the summary says why in one line, and the other change is priced. Here the rewrite cuts w16 and w17 starts
    /// inside it (overlapping items): the review bridges w17 to w16, but once w16 is cut w17's hard seam crosses it even
    /// as a seam at a cut (`windowCrossesWord`).
    @Test func unplaceablePhraseKeepsItsWordsAndTheOthersArePriced() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cut = VoiceLabDiffHunk(kind: .cut, sourceWordIds: ["w16"], newTokens: [], correctedTexts: [], absorbedItemIds: [],
                                   bridgeWordIds: [], sourceStartIndex: 16, sourceEndIndex: 17, anchorSeconds: nil)
        let (editor, session) = try await productionSession(fixture, voices: [10, 17], extraHunks: [cut], prepare: false) { source in
            if let end = source.transcript?.words[16].end { source.transcript?.words[17].start = end - 0.1 }
        }
        defer { editor.close() }
        #expect(session.includedVoice == [2, 4], "\(session.includedVoice) \(session.ownProposal?.changes.map { ($0.ordinal, $0.kind, $0.state) } ?? [])")
        await session.prepareTakes()
        await session.takesTask?.value
        #expect(session.takePlanFailure == nil && session.problem.isEmpty)
        #expect(session.ownProposal?[4]?.state == .excluded && session.includedVoice == [2])
        #expect(session.autoFix.notes == ["Change 4 keeps your original words: it can't be joined to the recording there."], "\(session.autoFix.notes)")
        let plan = try #require(session.takePlan)
        #expect(plan.phrases.count == 1 && plan.phrases[0].text.contains("Corrected"), "\(plan.phrases.map(\.text))")
        #expect(plan.problem.isEmpty && plan.approvalID != nil && plan.stillCurrent, "\(plan.problem)")
    }

    @Test func timingShortSurroundingReviewDoesNotOverridePriceOrExcludedWords() async throws {
        let fixture = try await fixture(indices: [10], contextWords: true); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        var short = try #require(hunks([17]).first)
        short = VoiceLabDiffHunk(kind: .voice, sourceWordIds: short.sourceWordIds, newTokens: ["Hi"], correctedTexts: [],
            absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 17, sourceEndIndex: 18, anchorSeconds: nil)
        session.receive([RewriteChange(hunk: short)])
        session.finishRun(seconds: 0.1); session.showProposal()
        #expect(session.blockedVoiceOrdinals == [1] && session.includedVoice.isEmpty)
        #expect(session.voiceReview(1)?.timing?.tooLong == false)
        _ = try session.timingSpeechContextReview(ordinal: 1)
        session.phraseTimingAction(.surrounding, ordinal: 1)
        #expect(session.speechContextReview != nil, "\(session.speechContextProblem)")
        #expect(session.includedVoice.isEmpty && session.pricedAnyway.isEmpty)
        #expect(!session.hasPaidTakes && ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
        session.cancelSpeechContextReview()
        #expect(session.surroundingSentenceOrdinal == nil)
        session.phraseTimingAction(.surrounding, ordinal: 1)
        session.phraseTimingAction(.original, ordinal: 1)
        await session.acceptSpeechContextReview()
        #expect(session.acceptedSpeechContext == nil && !session.speechContextProblem.isEmpty)
        #expect(session.includedVoice.isEmpty && ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
    }

    @Test func prepayPaceCopyTracksTheSelectedModel() async throws {
        let fixture = try await fixture(indices: [10], dialogue: true); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let ordinal = try #require(session.ownProposal?.changes.first(where: { $0.kind == .voice })?.ordinal)
        let pace = try #require(session.voiceReview(ordinal)?.timing?.pace)
        #expect(pace == 1)
        let generation = try #require(session.generation)
        generation.chooseModel("eleven_v4")
        #expect(session.voiceReview(ordinal)?.timing?.pace == 1)
        #expect(session.voiceReview(ordinal)?.timing?.copy.contains("pace") == false)
        generation.chooseModel("eleven_v3")
        #expect(session.voiceReview(ordinal)?.timing?.pace == pace)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
    }

    @Test func productionV4KeepsFixedPaceAndBindsFreshRetryQuotes() async throws {
        let fixture = try await fixture(indices: [10], dialogue: true); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let ordinal = try #require(session.ownProposal?.changes.first(where: { $0.kind == .voice })?.ordinal)
        let originalReviewPace = session.voiceReview(ordinal)?.timing?.pace
        let originalPace = try #require(plan.phrasePace(0))
        #expect(originalPace == 1)
        #expect(!session.takeSendLine.contains("× pace"))
        let oldQuote = try #require(plan.approvalID)
        ClipTakeHTTP.state.withLock { $0.duration += 2.5; $0.speechMargin = 0.15 }
        await plan.start(approved: true, quoteID: oldQuote)
        // Takes, automatic steps and the take's publishing finish before each manual step: a busy plan ignores a click.
        await settle(session)
        let selectedID = try #require(plan.phrases[0].selectedID)
        let selected = try #require(plan.phrases[0].takes.first(where: { $0.id == selectedID }))
        let audio = try #require(selected.row.audio)
        #expect(selected.row.receipt?.pace == originalPace)
        #expect(ClipTakeHTTP.state.withLock { $0.paces == [originalPace] })
        #expect(!plan.videoAvailability(phrase: 0).allows(.source))
        let measured = Double(audio.trimmed.count) / Double(audio.sampleRate)
        let silence = try VoiceLabWindowPlanner.lendableSilence(project: editor.project, scope: .full, window: plan.phrases[0].window)
        let expected = try VoiceLabPaceMatching.match(seconds: measured, oldPace: originalPace,
            window: plan.phrases[0].window, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
            sourceSampleRate: 24_000, supportsPace: false, hardJoinSmoothing: true)
        #expect(plan.phrasePace(0) == expected.pace)
        await settle(session)
        await plan.prepareAnother(phrase: 0)
        #expect(plan.phrasePace(0) == expected.pace && (0.9...1.1).contains(expected.pace))
        #expect(plan.approvalID != oldQuote)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
        let unusedQuote = plan.approvalID
        await settle(session)
        await plan.prepareAnother(phrase: 0)
        #expect(plan.phrasePace(0) == expected.pace && plan.approvalID != unusedQuote)
        await settle(session)
        await plan.tryAnother(phrase: 0, approved: true, quoteID: unusedQuote)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
        await settle(session)
        await plan.tryAnother(phrase: 0, approved: true, quoteID: plan.approvalID)
        #expect(ClipTakeHTTP.state.withLock { $0.paces == [originalPace, expected.pace] }, "\(plan.problem)")
        let generation = try #require(session.generation)
        generation.chooseModel("eleven_v4")
        #expect(plan.phrasePace(0) == 1)
        #expect(session.voiceReview(ordinal)?.timing?.pace == 1)
        #expect(originalReviewPace == 1)
        await settle(session)
        await plan.prepareAnother(phrase: 0)
        #expect(plan.phrasePace(0) == 1 && plan.approvalID != nil, "\(plan.problem)")
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 2 })
    }

    @Test func productionTakesUseV4AndRefuseOtherNewTakeModels() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.listsMultilingual = true }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let generation = try #require(session.generation)
        #expect(generation.models.map(\.id) == ["eleven_v3", "eleven_multilingual_v2", "eleven_v4"])
        #expect(generation.selectedModelID == "eleven_v4")
        generation.chooseModel("eleven_v3")
        #expect(generation.selectedModelID == "eleven_v4")
    }

    @Test func missingV4RefusesNewTakesWithoutFallingBack() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, v4Available: false); defer { editor.close() }
        let generation = try #require(session.generation)
        #expect(generation.selectedModelID == nil && generation.problem.contains("Eleven v4 is not available"))
        await session.prepareTakes()
        #expect(session.takePlan == nil && ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
    }

    @Test func legacyV2TakesRemainSelectableAndPlayable() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.listsMultilingual = true }
        _ = try await fixture.client.models()
        #expect(fixture.plan.changeModel("eleven_multilingual_v2"))
        await fixture.plan.prepare()
        await fixture.plan.start(approved: true, quoteID: fixture.plan.approvalID)
        let take = try #require(fixture.plan.phrases[0].selected)
        #expect(take.row.receipt?.modelID == "eleven_multilingual_v2")
        #expect(fixture.plan.select(take: take.id, phrase: 0))
        await fixture.plan.play(take: take.id, phrase: 0)
        #expect(fixture.plan.audition.isPlaying)
        fixture.plan.stopAudition()
    }

    /// A take too short for every video duration gets no measured rewording round, which could only pad (ADR-R42): its
    /// phrase keeps the recorded audio with one line (design.md R2 "A take that can't fit its place"). Nothing is sent.
    @Test func aTooShortMeasuredTakeKeepsTheRecordingWithoutARewordingRound() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = MeasuredFitConnector()
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.duration = 4; $0.speechMargin = 0.15 }
        await plan.start(approved: true, quoteID: plan.approvalID)
        await session.wordingFit.measuredWork?.value
        #expect(session.wordingFit.measured == nil)
        #expect(await connector.requests.isEmpty)
        #expect(plan.phrases[0].leftOut)
        #expect(session.autoFix.notes.contains(ClipTakePlan.noDurationCopy([1])))
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    /// A take too long for every duration: the measured round offers a shorter wording before the phrase is settled.
    /// Declining it can't keep a take no duration carries, so the button reads Keep Original Audio and the phrase keeps
    /// the recording with one line (design.md R2 "A take that can't fit its place"). Nothing more is paid for.
    @Test func measuredRewordingPreparesButNeverPaysAndDecliningKeepsTheRecording() async throws {
        let tooLong = true
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = MeasuredFitConnector()
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let originalText = plan.phrases[0].text
        ClipTakeHTTP.state.withLock { $0.duration = tooLong ? $0.duration + 5 : 4; $0.speechMargin = 0.15 }
        await plan.start(approved: true, quoteID: plan.approvalID)
        if plan.phrases[0].selectedID == nil, let take = plan.phrases[0].takes.first {
            #expect(plan.select(take: take.id, phrase: 0))
        }
        await session.wordingFit.measuredWork?.value
        let suggestion = try #require(session.wordingFit.measured)
        #expect(suggestion.tooLong == tooLong && suggestion.text == "Corrected Welcome today", "\(suggestion.problem)")
        #expect(!suggestion.preparing && plan.approvalID != nil, "\(plan.problem)")
        #expect(plan.phrases[0].text == suggestion.text && plan.phrases[0].takes.count == 1)
        #expect(plan.measuredInput(take: suggestion.take)?.text == originalText)
        let requests = await connector.requests
        #expect(requests.count == 1 && requests[0].cachedBlock?.contains("Measured") == true)
        #expect(requests[0].cachedBlock?.contains(tooLong ? "fewer words" : "more words") == true)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
        #expect(editor.project.voiceLab.speakingRateSamples?[VoiceLabRateCalibration.projectKey("eleven_v4")]?.count == 1)
        let staleAction = try #require(session.pricedTakeAction(phrase: 0))
        #expect(staleAction.title.hasPrefix("Make Take"))
        #expect(session.measuredKeepTitle(suggestion, plan: plan) == "Keep Original Audio")
        session.keepMeasuredTake()
        staleAction.perform()
        await session.takesTask?.value
        #expect(session.wordingFit.measured == nil && plan.phrases[0].text == originalText)
        #expect(plan.phrases[0].leftOut && plan.phrases[0].selectedID == nil && plan.approvalID == nil,
                "selected \(String(describing: plan.phrases[0].selectedID)) approval \(String(describing: plan.approvalID)) \(plan.problem)")
        #expect(session.autoFix.notes.contains(ClipTakePlan.noDurationCopy([1])))
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    @Test func calibrationDoesNotReinsertEvictedSamplesWhenRowsAreObservedAgain() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = self.session(fixture); defer { editor.close() }
        let ids = (0..<12).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            session.recordSpeakingRate(model: "eleven_v4", recordID: "fixture-voice", take: id, measured: 1 + Double(index) / 10, baseline: 1)
        }
        let key = VoiceLabRateCalibration.projectKey("eleven_v4")
        let samples = editor.project.voiceLab.speakingRateSamples?[key]
        #expect(samples?.map(\.id) == ids.suffix(10).map(\.uuidString))
        #expect(editor.project.voiceLab.speakingRateSamples?["eleven_v4"] == nil)
        for id in ids { session.recordSpeakingRate(model: "eleven_v4", recordID: "fixture-voice", take: id, measured: 3, baseline: 1) }
        #expect(editor.project.voiceLab.speakingRateSamples?[key] == samples)
        // The voice keeps all twelve across projects (its last 30).
        #expect(editor.app.rateCalibration(recordID: "fixture-voice")?.samples("eleven_v4").map(\.id) == ids.map(\.uuidString))
    }

    @Test func measuredRecoveryOffersWordingEvenWhenRetimeIsAvailable() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = MeasuredFitConnector()
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let length = plan.phrases[0].originalLength
        ClipTakeHTTP.state.withLock { $0.duration = length + 1.5; $0.speechMargin = 0.15 }
        await plan.start(approved: true, quoteID: plan.approvalID)
        // The measured round starts after the take lands and the reworded phrase's fresh quote after that; slow hosted
        // runners reach both later (CI 41967010628 read the wording before its round had started), so wait for both,
        // bounded in time rather than in polls (a 3-core runner stretched 3,000 short sleeps past the suite's limit).
        await TestDeadline.until(timeout: .seconds(30)) {
            if let work = session.wordingFit.measuredWork { await work.value }
            return session.wordingFit.measured?.text != nil && plan.approvalID != nil
                || session.wordingFit.measured?.problem.isEmpty == false
        }
        let availability = plan.videoAvailability(phrase: 0)
        #expect(!availability.allows(.source) && !availability.allows(.cut) && availability.allows(.retimed))
        #expect(session.wordingFit.measured?.text != nil && plan.approvalID != nil,
                "measured \(String(describing: session.wordingFit.measured)) left out \(plan.phrases[0].leftOut) \(plan.diagnostics) \(session.wordingFit.problem)")
        #expect(await connector.requests.count == 1)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    /// The take that just landed starts its own video preparation (Match, the only duration it allows) while the measured
    /// round asks for a shorter wording. A hosted runner, or a single-thread cooperative pool, let that preparation run
    /// into the round's price, which was refused as busy: "The new wording couldn't be priced." Here the preparation is
    /// held at its render until the round has its wording, so the two always overlap: the price waits for it, then runs.
    @Test func measuredRewordingWaitsForTheTakesOwnVideoPreparation() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = MeasuredFitConnector()
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let render = try #require(plan.prepareDurationRender)
        let barrier = ClipTakeBarrier()
        plan.prepareDurationRender = { project, scope in
            await barrier.pause()
            return try await render(project, scope)
        }
        ClipTakeHTTP.state.withLock { $0.duration = plan.phrases[0].originalLength + 1.5; $0.speechMargin = 0.15 }
        await plan.start(approved: true, quoteID: plan.approvalID)
        await barrier.wait()
        #expect(plan.preparingVideo && plan.phrases[0].videoChoice == .retimed)
        await TestDeadline.until {
            session.wordingFit.measured?.text != nil || session.wordingFit.measured?.problem.isEmpty == false
        }
        let waiting = try #require(session.wordingFit.measured)
        #expect(waiting.text == "Corrected Welcome today" && waiting.preparing && waiting.problem.isEmpty, "\(waiting)")
        barrier.resume()
        await session.wordingFit.measuredWork?.value
        let suggestion = try #require(session.wordingFit.measured)
        #expect(suggestion.text == "Corrected Welcome today" && !suggestion.preparing && suggestion.problem.isEmpty, "\(suggestion) \(plan.diagnostics)")
        #expect(plan.phrases[0].text == suggestion.text && plan.approvalID != nil, "\(plan.diagnostics)")
        #expect(await connector.requests.count == 1)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    /// CI 42715860857, after the price learned to wait for the take's own video preparation. That preparation failed
    /// here (this fixture's source file doesn't match the project's content key: "source identity"), and the lip sync
    /// refresh that `autoChooseVideo` runs after it published the take for its offers (`makeLipsyncOffers` →
    /// `publishSelection`), outside the preparation the price waited for. The round's reply arrived during that publish
    /// and was refused as busy: "The new wording couldn't be priced." Here lip sync's publish is held until the reply
    /// arrives, so the two always overlap: the price waits for it, and the offers it was making, stale now, end quietly.
    @Test func measuredRewordingWaitsForLipSyncsPublishAfterTheTakeLands() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let publish = ClipTakeBarrier()
        let connector = MeasuredFitConnector(hold: { await publish.wait() })
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        fixture.beforePublish = { [weak plan] _ in
            guard plan?.publishPurpose == .lipsync, !publish.arrived else { return }
            await publish.pause()
        }
        ClipTakeHTTP.state.withLock { $0.duration = plan.phrases[0].originalLength + 1.5; $0.speechMargin = 0.15 }
        await plan.start(approved: true, quoteID: plan.approvalID)
        await TestDeadline.until { publish.arrived }
        #expect(plan.publishing && plan.publishPurpose == .lipsync && plan.phrases[0].videoChoice == .retimed, "\(plan.diagnostics)")
        await TestDeadline.until {
            session.wordingFit.measured?.text != nil || session.wordingFit.measured?.problem.isEmpty == false
        }
        let waiting = try #require(session.wordingFit.measured)
        #expect(waiting.text == "Corrected Welcome today" && waiting.preparing && waiting.problem.isEmpty, "\(waiting) \(plan.diagnostics)")
        publish.resume()
        await session.wordingFit.measuredWork?.value
        let suggestion = try #require(session.wordingFit.measured)
        #expect(suggestion.text == "Corrected Welcome today" && !suggestion.preparing && suggestion.problem.isEmpty,
                "\(suggestion) \(plan.diagnostics)")
        #expect(plan.phrases[0].text == suggestion.text && plan.approvalID != nil && plan.rewordingRefusal == nil, "\(plan.diagnostics)")
        #expect(plan.problem.isEmpty && plan.lipsync.problem.isEmpty, "\(plan.diagnostics) lip sync \(plan.lipsync.problem)")
        #expect(await connector.requests.count == 1)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    @Test(arguments: [false, true]) func measuredAPIRoundWaitsForInlineApprovalAndNeverSynthesizes(approve: Bool) async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = MeasuredFitConnector(id: .anthropic)
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.duration += 5; $0.speechMargin = 0.15 }
        await plan.start(approved: true, quoteID: plan.approvalID)
        await session.wordingFit.measuredWork?.value
        #expect(session.wordingFit.measured?.awaitingApproval == true)
        #expect(await connector.requests.isEmpty)
        if approve {
            session.approveMeasuredFit(plan)
            await session.wordingFit.measuredWork?.value
            #expect(await connector.requests.count == 1)
            #expect(session.wordingFit.measured?.text != nil && plan.approvalID != nil)
        } else {
            session.keepMeasuredTake()
            #expect(await connector.requests.isEmpty)
            #expect(session.wordingFit.measured == nil)
        }
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    /// The automatic wording fit ended with a change still too long (ai.md §12.9, the Rewrite smoke's S12): it keeps the
    /// speaker's words, since no take of it could fit the running video, and Get Price prices the rest. Stop is the
    /// user's choice and changes nothing until the footer's Keep My Words.
    @Test func heldBackChangeKeepsItsWordsOnceTheAutomaticFitEnds() async throws {
        let fixture = try await fixture(indices: [10, 17]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture)
        defer { editor.close() }
        let long = VoiceLabDiffHunk(kind: .voice, sourceWordIds: ["w10"],
            newTokens: [String(repeating: "collaboratively", count: 8)], correctedTexts: [], absorbedItemIds: [],
            bridgeWordIds: [], sourceStartIndex: 10, sourceEndIndex: 11, anchorSeconds: nil)
        session.receive(([long] + hunks([17], text: "Welcome")).map { RewriteChange(hunk: $0) })
        session.finishRun(seconds: 1)
        session.showProposal()
        #expect(session.blockedVoiceOrdinals == [1] && session.includedVoice == [2])
        #expect(session.voiceReview(1)?.timing?.tooLong == true)
        session.wordingFit.stopped = true
        session.keepLongChangesAsRecorded()
        #expect(session.blockedVoiceOrdinals == [1] && session.includedVoice == [2] && session.autoFix.notes.isEmpty)
        session.wordingFit.stopped = false
        session.keepLongChangesAsRecorded()
        #expect(session.blockedVoiceOrdinals.isEmpty && session.includedVoice == [2])
        #expect(session.ownProposal?[1]?.state == .excluded && session.wordingFit.kept == [1])
        #expect(session.autoFix.notes == ["Change 1 keeps your original words: still longer than its time in the video after a fit."])
        session.showProposal()
        #expect(session.task.footer.primary?.title == "Get Price · 1 phrase", "\(session.task.footer)")
    }

    @Test func productionQuoteLeavesOutBlockedPhrasesUntilExplicitOverride() async throws {
        let fixture = try await fixture(indices: [10, 17]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture)
        defer { editor.close() }
        let long = VoiceLabDiffHunk(kind: .voice, sourceWordIds: ["w10"],
            newTokens: [String(repeating: "collaboratively", count: 8)], correctedTexts: [], absorbedItemIds: [],
            bridgeWordIds: [], sourceStartIndex: 10, sourceEndIndex: 11, anchorSeconds: nil)
        session.receive(([long] + hunks([17], text: "Welcome")).map { RewriteChange(hunk: $0) })
        session.finishRun(seconds: 1)
        session.showProposal()
        #expect(session.blockedVoiceOrdinals == [1] && session.includedVoice == [2])
        let generation = try #require(session.generation)
        await generation.finishQuotePreparationForTests()
        await session.prepareTakes()
        let pendingPlan = session.takePlan
        let first = try #require(pendingPlan)
        #expect(first.phrases.count == 1 && session.takePlanOrdinals == [2])
        session.showProposal()
        #expect(session.task.footer.note?.hasPrefix("Change 1 needs a shorter wording before takes.") == true)
        #expect(session.task.footer.note?.contains("ElevenLabs with your key") == true)
        session.phraseTimingAction(.priceAnyway, ordinal: 1)
        await generation.finishQuotePreparationForTests()
        await session.prepareTakes()
        let overridden = try #require(session.takePlan)
        #expect(overridden.phrases.count == 2 && session.takePlanOrdinals == [1, 2])
        #expect(first !== overridden && first.approvalID == nil)
        session.phraseTimingAction(.original, ordinal: 1)
        await generation.finishQuotePreparationForTests()
        await session.prepareTakes()
        #expect(session.takePlan?.phrases.count == 1 && session.takePlanOrdinals == [2])
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
    }

    @Test func paidUnusableTakeRecoveryKeepsNormalDiscardApproval() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture)
        defer { editor.close() }
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.duration += 5; $0.speechMargin = 0.15 }
        await plan.start(approved: true)
        let phrase = try #require(plan.phrases.first)
        // The paid take fits no video duration, so the phrase already keeps its recording (design.md R2); its change's
        // own recovery steps still ask before discarding paid takes.
        #expect(phrase.leftOut && plan.phrases[0].takes.count == 1)
        #expect(session.autoFix.notes.contains(ClipTakePlan.noDurationCopy([1])))
        let ordinal = try #require(session.takePhraseOrdinals(phrase).first)
        let synthesisCount = ClipTakeHTTP.state.withLock { $0.texts.count }
        session.phraseTimingAction(.shorter, ordinal: ordinal)
        #expect(session.task.confirm?.question == "Discard these 2 changes?")
        #expect(session.takePlan === plan && session.hasPaidTakes && !plan.generating)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == synthesisCount })
        session.task.confirm?.cancel.perform()
        session.phraseTimingAction(.original, ordinal: ordinal)
        #expect(session.task.confirm?.question == "Discard these 2 changes?")
        #expect(session.ownProposal?[ordinal]?.state != .excluded)
        #expect(session.takePlan === plan && plan.stillCurrent && !plan.isRetired)
        session.task.confirm?.cancel.perform()
        #expect(session.takePlan === plan && plan.stillCurrent)
        session.phraseTimingAction(.original, ordinal: ordinal)
        session.task.confirm?.confirm.perform()
        #expect(session.ownProposal?[ordinal]?.state == .excluded)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == synthesisCount })
    }

    @Test func unpaidExpressionChangeRequotesWithoutSendingSpeech() async throws {
        let fixture = try await fixture(indices: [10])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture)
        defer { editor.close() }
        let previous = try #require(session.takePlan)
        let approval = try #require(previous.approvalID)
        let sends = ClipTakeHTTP.state.withLock { $0.texts.count }
        let project = editor.project
        let oldTiming = try #require(session.voiceReview(2)?.timing)
        session.updateAudioTags([.init(beforeToken: 1, tag: "laughs")], ordinal: 2)
        await session.takesTask?.value
        let next = try #require(session.takePlan)
        #expect(previous.isRetired && next !== previous && next.approvalID != approval)
        #expect(session.changes[1].hunk.audioTags == [.init(beforeToken: 1, tag: "laughs")])
        #expect(next.phrases[0].audioTags.map(\.tag) == ["laughs"])
        let timing = try #require(session.voiceReview(2)?.timing)
        #expect(abs(timing.estimateSeconds * timing.pace - oldTiming.estimateSeconds * oldTiming.pace - 0.8) < 1e-9)
        #expect(editor.project == project)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == sends })
        await next.start(approved: true, quoteID: approval)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == sends })
        let model = VoiceLabModel(id: "eleven_v3", name: "Provider name", languages: ["en"], canSpeak: true,
            canConvert: false, maximumTextLength: nil, characterCostMultiplier: nil)
        #expect(DirectorTakeRows.speechModelName(model) == "Eleven v3 · audio tags")
        #expect(AudioTagPhrase.explanation == "Rewrite suggests tags where your original had a laugh, sigh or pause. Tags aren't spoken words and don't count in the word check.")
    }

    @Test func mergedPhraseRemovalPreservesOtherHunksAnnotations() async throws {
        let fixture = try await fixture(indices: [10, 11])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, touchingVoices: true)
        defer { editor.close() }
        session.updateAudioTags([.init(beforeToken: 1, tag: "laughs")], ordinal: 2)
        await session.takesTask?.value
        session.updateAudioTags([.init(beforeToken: 1, tag: "sighs")], ordinal: 3)
        await session.takesTask?.value
        let plan = try #require(session.takePlan)
        let phrase = try #require(plan.phrases.first)
        #expect(phrase.audioTags.map(\.tag) == ["laughs", "sighs"])
        // On the takes panel the merged phrase's own tags change, in its plan; the other tag stays where it was.
        session.updateAudioTags(Array(phrase.audioTags.dropFirst()), phrase: phrase)
        await session.takesTask?.value
        #expect(session.takePlan === plan && plan.phrases[0].audioTags == Array(phrase.audioTags.dropFirst()))
    }

    @Test(arguments: ["price", "original", "keepVoice", "undoVoice", "keepFree", "undoFree", "keepAll", "edit", "tag"])
    func paidProposalActionsWaitForDiscardAndCancellationChangesNothing(action: String) async throws {
        let fixture = try await fixture(indices: [10])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture)
        defer { editor.close() }
        let plan = try #require(session.takePlan)
        await plan.start(approved: true)
        let changes = try #require(session.ownProposal?.changes)
        let selected = plan.phrases[0].selectedID
        let included = session.includedVoice, overrides = session.pricedAnyway
        let project = editor.project
        let sends = ClipTakeHTTP.state.withLock { $0.texts.count }
        func act() {
            switch action {
            case "price": session.phraseTimingAction(.priceAnyway, ordinal: 2)
            case "original": session.phraseTimingAction(.original, ordinal: 2)
            case "keepVoice": _ = editor.keepChange(2)
            case "undoVoice": _ = editor.excludeChange(2)
            case "keepFree": _ = editor.keepChange(1)
            case "undoFree": _ = editor.excludeChange(1)
            case "keepAll": _ = editor.keepAllChanges()
            case "tag": session.updateAudioTags([VoiceLabAudioTag(beforeToken: 1, tag: "laughs")], ordinal: 2)
            default: _ = editor.editChange(2, text: "Different words")
            }
        }
        act()
        #expect(session.task.confirm?.question == "Discard these 2 changes?")
        #expect(session.ownProposal?.changes == changes && session.includedVoice == included && session.pricedAnyway == overrides)
        #expect(session.takePlan === plan && plan.stillCurrent && plan.phrases[0].selectedID == selected)
        #expect(editor.project == project)
        session.task.confirm?.cancel.perform()
        #expect(session.takePlan === plan && plan.stillCurrent && session.ownProposal?.changes == changes)
        act()
        session.task.confirm?.confirm.perform()
        #expect(plan.isRetired && session.takePlan !== plan && !session.hasPaidTakes)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == sends })
    }

    @Test func paidShorterFeedbackUsesMeasuredLengthAndEveryMergedOrdinal() async throws {
        let fixture = try await fixture(indices: [10, 11])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, touchingVoices: true)
        defer { editor.close() }
        let plan = try #require(session.takePlan)
        #expect(plan.phrases.count == 1)
        let ordinals = session.takePhraseOrdinals(plan.phrases[0])
        #expect(ordinals == [2, 3])
        ClipTakeHTTP.state.withLock { $0.duration += 5; $0.speechMargin = 0.15 }
        await plan.start(approved: true)
        let take = try #require(plan.phrases[0].selected ?? plan.phrases[0].takes.first)
        let measured = try #require(take.length)
        let feedback = try session.shorterFeedbackBlock(ordinals: [2])
        #expect(feedback.contains("Measured take: \(toFixed1(measured)) s"))
        #expect(!feedback.contains("Estimated:"))
        #expect(feedback.components(separatedBy: "Proposed words: Hello").count == 3)
        #expect(session.takePlan === plan && session.hasPaidTakes)
    }

    @Test(arguments: ["eleven_v4"])
    func surroundingRequoteUsesTheChangedPlansModelAndPace(model: String) async throws {
        let fixture = try await fixture(indices: [10], dialogue: true, contextWords: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, exactSourceEnvelope: true)
        defer { editor.close() }
        let generation = try #require(session.generation)
        session.receive(hunks([17]).map { RewriteChange(hunk: $0) })
        session.finishRun(seconds: 0.1)
        session.showProposal()
        if model == "eleven_v3" {
            generation.chooseModel("eleven_v4")
            await generation.finishQuotePreparationForTests()
        }
        session.phraseTimingAction(.priceAnyway, ordinal: 1)
        await session.prepareTakes()
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.duration = 1; $0.speechMargin = 0.15 }
        await plan.start(approved: true)
        #expect(session.hasPaidTakes)
        generation.chooseModel(model)
        #expect(plan.modelID == model && plan.stillCurrent)
        session.reviewSpeechContext(phrase: 0)
        #expect(session.speechContextReview != nil, "\(session.speechContextProblem)")
        await session.acceptSpeechContextReview()
        #expect(session.speechContextProblem.isEmpty && plan.problem.isEmpty, "\(session.speechContextProblem); \(plan.problem)")
        #expect(plan.approvalID != nil && session.takePlan === plan)
        let pace = try #require(plan.phrasePace(0))
        #expect(pace == 1)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    @Test func estimatedPaceAndFittingTimingAreVisibleToPopoverAndVoiceOver() async throws {
        let fixture = try await fixture(indices: [10], dialogue: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture)
        defer { editor.close() }
        editor.waveform = WaveformData(fine: fixture.envelope.levels)
        let item = try #require(session.proposalContent().set.items.first { $0.kind == .voice })
        let timing = try #require(item.timing)
        #expect(timing.pace == 1)
        #expect(!timing.copy.contains("pace") && item.spoken.contains(timing.copy))
        let paced = try #require(editor.changeFit(item.ordinal, text: "Hello"))
        #expect(!paced.contains("pace"))
        let generation = try #require(session.generation)
        generation.chooseModel("eleven_v4")
        let fixed = try #require(editor.changeFit(item.ordinal, text: "Hello"))
        #expect(!fixed.contains("pace"))
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
    }

    @Test func dialogueFitRemainsStableWhenGenerationStarts() async throws {
        let fixture = try await fixture(indices: [10], dialogue: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture)
        defer { editor.close() }
        let generation = try #require(session.generation)
        session.receive((session.changes.map(\.hunk) + hunks([17])).map { RewriteChange(hunk: $0) })
        session.finishRun(seconds: 0.1)
        session.showProposal()
        generation.chooseModel("eleven_v4")
        await generation.finishQuotePreparationForTests()
        session.phraseTimingAction(.priceAnyway, ordinal: 3)
        #expect(session.blockedVoiceOrdinals == [2] && session.includedVoice == [3])
        await session.prepareTakes()
        let plan = try #require(session.takePlan)
        #expect(plan.approvalID != nil && plan.stillCurrent, "\(plan.problem)")
        let ordinal = try #require(session.takePhraseOrdinals(plan.phrases[0]).first)
        #expect(session.voiceReview(ordinal)?.timing?.pace == 1)
        let included = session.includedVoice
        var checkedGenerating = false
        fixture.beforeProgress = {
            guard !checkedGenerating else { return }
            checkedGenerating = true
            #expect(plan.generating && session.hasPaidTakes)
            #expect(session.voiceReview(2)?.timing?.pace == 1)
            // Once takes are paid the estimate holds nothing back (MVP32 Clip 7); change 2 is outside the plan.
            #expect(session.blockedVoiceOrdinals.isEmpty)
            #expect(session.voiceReview(ordinal)?.timing?.pace == 1)
            #expect(session.includedVoice == included)
        }
        await plan.start(approved: true)
        #expect(checkedGenerating && !plan.phrases[0].takes.isEmpty, "\(plan.problem)")
        #expect(session.voiceReview(ordinal)?.timing?.pace == 1)
        #expect(session.blockedVoiceOrdinals.isEmpty && !session.includedVoice.contains(2))
        let proposal = session.ownProposal?.changes
        for action in [PhraseTimingAction.priceAnyway, .original] {
            session.phraseTimingAction(action, ordinal: 2)
            #expect(session.task.confirm != nil)
            #expect(session.takePlan === plan && plan.stillCurrent && session.ownProposal?.changes == proposal)
            session.task.confirm?.cancel.perform()
        }
        for action in [ChangeReview.keep, .undo] {
            session.review(2, action)
            #expect(session.task.confirm != nil)
            #expect(session.takePlan === plan && plan.stillCurrent && session.ownProposal?.changes == proposal)
            session.task.confirm?.cancel.perform()
        }
    }

    @Test func failedSurroundingSentenceDoesNotRedirectFuturePricing() async throws {
        let fixture = try await fixture(indices: [10, 17], contextWords: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture)
        defer { editor.close() }
        let short = VoiceLabDiffHunk(kind: .voice, sourceWordIds: ["w17"], newTokens: ["Hi"], correctedTexts: [],
            absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 17, sourceEndIndex: 18, anchorSeconds: nil)
        session.receive((hunks([10]) + [short]).map { RewriteChange(hunk: $0) })
        session.finishRun(seconds: 0.1)
        session.phraseTimingAction(.priceAnyway, ordinal: 1)
        await session.prepareTakes()
        #expect(session.takePlan?.phrases.count == 1)
        session.phraseTimingAction(.surrounding, ordinal: 2)
        #expect(!session.speechContextProblem.isEmpty)
        #expect(session.speechContextReview == nil)
        #expect(session.surroundingSentenceOrdinal == nil)
        await session.prepareTakes()
        #expect(session.takePlan?.approvalID != nil)
        session.surroundingSentenceOrdinal = 2
        session.phraseTimingAction(.priceAnyway, ordinal: 2)
        #expect(session.surroundingSentenceOrdinal == nil)
        session.surroundingSentenceOrdinal = 2
        session.review(2, .undo)
        #expect(session.surroundingSentenceOrdinal == nil)
        session.review(2, .keep)
        #expect(session.surroundingSentenceOrdinal == nil)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
    }

    @Test func dialogueIsSelectableByAccountNameAndTurboIsHidden() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.listsMultilingual = true; $0.listsDialogue = true }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let generation = try #require(session.generation)
        #expect(generation.models.map(\.id) == ["eleven_v3", "eleven_multilingual_v2", "eleven_v4"])
        #expect(generation.models.last?.name == "Eleven v4 account name")
        #expect(generation.selectedModelID == "eleven_v4")
        generation.chooseModel("eleven_v4")
        #expect(generation.selectedModelID == "eleven_v4")
        #expect(generation.models.last?.sendsSpeechContext == false)
    }

    @Test func newTakesStayOnV4AfterARunAndKeepPaidTakes() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        ClipTakeHTTP.state.withLock { $0.listsMultilingual = true }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let generation = try #require(session.generation), plan = try #require(session.takePlan)
        await plan.start(approved: true)
        #expect(session.hasPaidTakes && plan.phrases[0].takes.count == 1)
        generation.chooseModel("eleven_v3")
        await generation.finishQuotePreparationForTests()
        #expect(generation.selectedModelID == "eleven_v4" && session.takePlan === plan && plan.stillCurrent)
        #expect(plan.modelID == "eleven_v4" && plan.phrases[0].takes.count == 1 && plan.approvalID == nil && generation.problem.isEmpty)
        session.priceAnotherTake(phrase: 0); await session.takesTask?.value
        let retry = try #require(session.pricedTakeAction(phrase: 0))
        retry.perform(); await session.takesTask?.value
        #expect(ClipTakeHTTP.state.withLock { $0.models } == ["eleven_v4", "eleven_v4"])
        #expect(plan.phrases[0].takes.count == 2)
        #expect(plan.phrases[0].takes.map { $0.row.receipt?.modelID } == ["eleven_v4", "eleven_v4"])
        let first = plan.phrases[0].takes[0]
        #expect(first.row.selectable && plan.select(take: first.id, phrase: 0) && plan.chooseVideo(.source, phrase: 0))
        #expect(await session.acceptTakes(), "\(plan.problem); \(session.problem)")
        #expect(editor.project.voiceLab.segments.last?.candidates.first?.recipe?.provenance.model == "eleven_v4")
    }

    @Test(arguments: [false, true]) func productionQuotePinsPendingBridgeCorrectionAndPaidDiscard(generated: Bool) async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let oldAction = try #require(session.pricedTakeAction())
        var original = editor.project
        let undo = UndoManager(); editor.undoManager = undo
        if generated {
            await plan.start(approved: true)
            #expect(plan.phrases[0].selected?.fits == true, "\(plan.phrases[0].status), \(plan.problem)")
        }
        let sent = ClipTakeHTTP.state.withLock { ($0.texts.count, $0.qa) }
        if generated {
            #expect(!editor.excludeChange(1) && plan.stillCurrent)
            #expect(session.task.confirm != nil)
            session.task.confirm?.confirm.perform()
        } else { #expect(editor.excludeChange(1)) }
        original.voiceLab.speakingRateSamples = editor.project.voiceLab.speakingRateSamples
        #expect(editor.project == original && editor.undoSteps == 0 && !plan.stillCurrent)
        oldAction.perform(); await session.takesTask?.value
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == sent.0 && $0.qa == sent.1 })
        let accepted = await session.acceptTakes()
        #expect(!accepted)
        #expect(editor.project == original && editor.undoSteps == 0 && !undo.canUndo)
        session.showProposal()
        await session.prepareTakes()
        let fresh = try #require(session.takePlan)
        #expect(fresh !== plan && fresh.approvalID != nil && fresh.approvalID != plan.approvalID)
        #expect(!fresh.phrases[0].text.contains("Corrected"))
        oldAction.perform(); await session.takesTask?.value
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == sent.0 && $0.qa == sent.1 })
        #expect(!fresh.generating && fresh.spent.units == 0)
    }

    @Test func proposalChangeDuringAcceptedRequestRetainsPaidOwnershipUntilDrained() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan), action = try #require(session.pricedTakeAction())
        var original = editor.project
        let undo = UndoManager(); editor.undoManager = undo
        let barrier = ClipTakeBarrier()
        fixture.beforeProgress = { await barrier.pause() }
        await editor.app.refreshMonthlySpend()
        let generating = Task { await plan.start(approved: true); barrier.finished() }
        await barrier.wait()
        #expect(plan.generating && plan.spent.units == 0 && session.hasPaidTakes)
        let sent = ClipTakeHTTP.state.withLock { ($0.texts.count, $0.qa) }
        #expect(!editor.excludeChange(1) && editor.project == original)
        #expect(session.task.confirm != nil)
        session.showProposal()
        #expect(session.takePlan === plan && !plan.isRetired && session.hasPaidTakes)
        session.task.confirm?.cancel.perform()
        action.perform(); await session.takesTask?.value
        let acceptedWhileDraining = await session.acceptTakes()
        #expect(plan.stillCurrent && !acceptedWhileDraining)
        barrier.resume(); await generating.value; await plan.invalidation?.value
        #expect(!plan.generating && !plan.preparing && session.takePlan === plan && session.hasPaidTakes)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == sent.0 && $0.qa >= sent.1 })
        let total = try #require(await fixture.ledger.total(provider: "elevenlabs", at: Date()))
        #expect(plan.spent.units > 0 && editor.app.monthlySpend.total == total)
        original.voiceLab.speakingRateSamples = editor.project.voiceLab.speakingRateSamples
        #expect(editor.project == original && editor.undoSteps == 0 && !undo.canUndo)
        #expect(!editor.excludeChange(1) && plan.stillCurrent)
        session.task.confirm?.confirm.perform()
        #expect(plan.isRetired && session.takePlan == nil && !session.hasPaidTakes)
    }

    @Test func confirmingPaidReviewDuringGenerationDrainsBeforeDiscarding() async throws {
        let fixture = try await fixture(indices: [10])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture)
        defer { editor.close() }
        let plan = try #require(session.takePlan), barrier = ClipTakeBarrier()
        fixture.beforeProgress = { await barrier.pause() }
        let generating = Task { await plan.start(approved: true) }
        await barrier.wait()
        #expect(!editor.excludeChange(1) && session.task.confirm != nil)
        session.task.confirm?.confirm.perform()
        #expect(session.takePlan === plan && session.ownProposal?[1]?.state == .pending)
        barrier.resume()
        await generating.value
        await session.takesTask?.value
        await plan.invalidation?.value
        #expect(plan.isRetired && session.takePlan == nil && !session.hasPaidTakes)
        #expect(session.ownProposal?[1]?.state == .excluded)
        #expect(plan.spent.units > 0 && ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    @Test func explicitLowerScoreSelectionSurvivesFailedBetterRetryStopAndEviction() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        ClipTakeHTTP.state.withLock { $0.amplitudeVariance = 0.8 }
        await plan.prepare(); await plan.start(approved: true)
        let selected = try #require(plan.phrases[0].selected)
        ClipTakeHTTP.state.withLock { $0.amplitudeVariance = 0.4 }
        await plan.prepareAnother(phrase: 0); await plan.tryAnother(phrase: 0, approved: true)
        #expect(try #require(plan.phrases[0].selected?.row.score) > #require(selected.row.score))
        #expect(plan.select(take: selected.id, phrase: 0))
        ClipTakeHTTP.state.withLock { $0.failQA = true }
        await plan.prepareAnother(phrase: 0); await plan.tryAnother(phrase: 0, approved: true)
        #expect(plan.phrases[0].selectedID == selected.id && plan.phrases[0].takes.count == 3)
        ClipTakeHTTP.state.withLock { $0.failQA = false; $0.amplitudeVariance = 0 }
        fixture.beforeProgress = { #expect(plan.phrases[0].selectedID == selected.id) }
        await plan.prepareAnother(phrase: 0); await plan.tryAnother(phrase: 0, approved: true)
        #expect(plan.phrases[0].selectedID == selected.id && plan.phrases[0].takes.count == 3)
        let barrier = ClipTakeBarrier()
        fixture.beforeProgress = { #expect(plan.phrases[0].selectedID == selected.id); await barrier.pause() }
        await plan.prepareAnother(phrase: 0)
        let retry = Task { await plan.tryAnother(phrase: 0, approved: true); barrier.finished() }
        await barrier.wait()
        await plan.stop(); await retry.value
        #expect(plan.phrases[0].selectedID == selected.id)
        let accepted = try await sourceAcceptance(plan)
        #expect(accepted.segments.count == 1 && fixture.publishedIDs == [selected.id])
    }

    @Test func sessionAuditionAndSourceTransportAreMutuallyExclusive() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        let plan = fixture.plan
        await plan.prepare(); await plan.start(approved: true)
        editor.transport(" ")
        #expect(editor.isPlaying && !plan.audition.isPlaying)
        await session.playTake(phrase: 0)
        #expect(!editor.isPlaying && plan.audition.isPlaying)
        editor.transport(" ")
        #expect(editor.isPlaying && !plan.audition.isPlaying)
        await session.playTake(phrase: 0); editor.transport("l")
        #expect(editor.isPlaying && !plan.audition.isPlaying)
        let barrier = ClipTakeBarrier()
        fixture.beforeScratch = { await barrier.pause() }
        let starting = Task { await session.playTake(phrase: 0) }
        await barrier.wait()
        editor.transport(" ")
        barrier.resume(); await starting.value
        #expect(editor.isPlaying && !plan.audition.isPlaying)
        fixture.beforeScratch = nil
        await session.playTake(phrase: 0); plan.invalidate()
        #expect(!editor.isPlaying && !plan.audition.isPlaying)
    }

    @Test(arguments: [false, true]) func productionTakesRefreshMonthlyCacheWhileReviewRemainsOpen(unpriced: Bool) async throws {
        let fixture = try await fixture(indices: [10], unknownPrice: unpriced); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan)
        await editor.app.refreshMonthlySpend()
        #expect(editor.app.monthlySpend.total?.usd == 0 && editor.app.monthlySpend.total?.unknownCount == 0)
        if unpriced { ClipTakeHTTP.state.withLock { $0.malformedSynthesis = true } }
        let gets = ClipTakeHTTP.state.withLock { $0.gets }
        await plan.start(approved: true)
        let total = try #require(await fixture.ledger.total(provider: "elevenlabs", at: Date()))
        #expect(editor.openRewrite === session && plan.spent.units > 0)
        #expect(editor.app.monthlySpend.total == total)
        let status = StatusBarContent.make(app: editor.app, editor: editor, now: Date())
        #expect(status[.spend]?.text == editor.app.monthlySpend.text)
        #expect(ClipTakeHTTP.state.withLock { $0.gets == gets })
        #expect(unpriced ? editor.app.monthlySpend.text.contains("unpriced") : total.usd > 0)
        await plan.prepareAnother(phrase: 0); await plan.tryAnother(phrase: 0, approved: true)
        await plan.stop()
        #expect(editor.app.monthlySpend.total == (await fixture.ledger.total(provider: "elevenlabs", at: Date())))
        #expect(editor.openRewrite === session)
    }

    @Test func queuedPaidReturnUsesEventTimeInsteadOfDelayedHandlerTime() {
        let appeared = Date(timeIntervalSince1970: 100)
        let now = appeared.addingTimeInterval(4)
        let early = VoiceLabSession.paidEventDate(timestamp: 90.1, now: now, uptime: 94)
        let fresh = VoiceLabSession.paidEventDate(timestamp: 91, now: now, uptime: 94)
        #expect(!VoiceLabSession.permitsPaidActivation(keyboard: true, command: false, repeated: false, appeared: appeared, now: now, eventDate: early))
        #expect(VoiceLabSession.permitsPaidActivation(keyboard: true, command: false, repeated: false, appeared: appeared, now: now, eventDate: fresh))
        #expect(!VoiceLabSession.permitsPaidActivation(keyboard: true, command: true, repeated: true, appeared: appeared, now: now, eventDate: fresh))
    }

    @Test(arguments: [false, true]) func monthlyCacheAccountsAcceptedResponseAfterStopOrInvalidation(retired: Bool) async throws {
        let fixture = try await fixture(indices: [10], unknownPrice: true); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan)
        await editor.app.refreshMonthlySpend()
        let barrier = ClipTakeBarrier()
        fixture.beforeProgress = { await barrier.pause() }
        ClipTakeHTTP.state.withLock { $0.malformedSynthesis = true }
        let generating = Task { await plan.start(approved: true); barrier.finished() }
        await barrier.wait()
        if retired { plan.invalidate(); barrier.resume() }
        else { await plan.stop() }
        await generating.value
        let total = try #require(await fixture.ledger.total(provider: "elevenlabs", at: Date()))
        #expect(total.unknownCount > 0 && plan.spent.units > 0)
        #expect(editor.app.monthlySpend.total == total && editor.app.monthlySpend.text.contains("unpriced"))
        #expect(editor.openRewrite === session)
    }

    @Test func inlinePriceCapturesItsQuoteBeforeDeferredExecution() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        await fixture.plan.prepare()
        let old = try #require(session.pricedTakeAction())
        #expect(old.priced && old.title.contains("Make Takes") && old.title.contains("$"))
        await fixture.plan.prepareAnother(phrase: 0)
        old.perform()
        await session.takesTask?.value
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
        session.takeQuotePhrase = 0
        let retry = try #require(session.pricedTakeAction(phrase: 0))
        #expect(retry.title.contains("Make take") && session.takeSendLine.contains("only phrase 1"))
        if case .inline(let amount)? = fixture.plan.cost {
            #expect(retry.title == "Make take · " + amount)
            #expect(retry.title.components(separatedBy: "≈").count <= 2)
        } else { Issue.record("This fixture must exercise the inline retry price") }
        retry.perform()
        await session.takesTask?.value
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    @Test func selectionStopAndInvalidationAlwaysEndAuditionWithoutAutoplay() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare(); await plan.start(approved: true)
        #expect(!plan.audition.isPlaying)
        await plan.play(phrase: 0)
        #expect(plan.audition.isPlaying)
        let selected = try #require(plan.phrases[0].selectedID)
        #expect(plan.select(take: selected, phrase: 0))
        #expect(!plan.audition.isPlaying && fixture.playback.stops == 1)
        await plan.play(phrase: 0); await plan.stop()
        #expect(!plan.audition.isPlaying && fixture.playback.stops == 2)
        await plan.play(phrase: 0); plan.invalidate()
        #expect(!plan.audition.isPlaying && fixture.playback.stops == 3)
        await plan.play(phrase: 0)
        #expect(!plan.audition.isPlaying)
    }

    /// Live 2026-11-03: four failed takes could not be heard. A failed take with staged audio plays without being selected.
    /// A take that failed before the checks has no checked mix, but its paid audio plays inline, named as not checked.
    @Test func aTakeThatFailedBeforeTheChecksPlaysItsPaidAudio() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare()
        ClipTakeHTTP.state.withLock { $0.silentSynthesis = true }
        await plan.start(approved: true)
        let take = try #require(plan.phrases[0].takes.first)
        #expect(take.row.audio == nil && take.row.generated != nil && take.notChecked && take.playable && !take.row.selectable)
        #expect(TakeFailurePresentation.leftOut(take.row, number: take.number)?.hasPrefix("Take 1 · not checked: ") == true)
        await plan.play(take: take.id, phrase: 0)
        #expect(plan.audition.isPlaying && plan.audition.takeId == take.id && plan.phrases[0].selectedID == nil)
        #expect(!plan.select(take: take.id, phrase: 0))
        await plan.play(take: take.id, phrase: 0)
        #expect(!plan.audition.isPlaying && fixture.playback.stops >= 1)
    }
    @Test func aFailedTakeWithAudioPlaysButStaysLeftOut() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare()
        ClipTakeHTTP.state.withLock { $0.failGenerated = true }
        await plan.start(approved: true)
        let take = try #require(plan.phrases[0].takes.first)
        #expect(!take.row.selectable && take.row.audio != nil && plan.phrases[0].selectedID == nil)
        await plan.play(phrase: 0)
        #expect(!plan.audition.isPlaying)
        await plan.play(take: take.id, phrase: 0)
        #expect(plan.audition.isPlaying && plan.audition.takeId == take.id && plan.phrases[0].selectedID == nil)
        #expect(!plan.select(take: take.id, phrase: 0))
        await plan.play(take: take.id, phrase: 0)
        #expect(!plan.audition.isPlaying && fixture.playback.stops >= 1)
        await plan.play(take: UUID(), phrase: 0)
        #expect(!plan.audition.isPlaying)
    }

    @Test func rowKeysPickOnlyTheFocusedPhraseAndKeepFailedRowsVisible() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        let plan = fixture.plan
        await plan.prepare(); await plan.start(approved: true)
        let before = plan.phrases.map(\.selectedID)
        await plan.prepareAnother(phrase: 1); await plan.tryAnother(phrase: 1, approved: true)
        session.focusedTakePhrase = 1
        session.selectTake(number: 1)
        #expect(plan.phrases.map(\.selectedID) == before)
        session.selectTake(number: 2)
        #expect(plan.phrases[1].selected?.number == 2 && plan.phrases[0].selectedID == before[0] && plan.phrases[2].selectedID == before[2])
        ClipTakeHTTP.state.withLock { $0.failQA = true }
        await plan.prepareAnother(phrase: 1); await plan.tryAnother(phrase: 1, approved: true)
        #expect(plan.phrases[1].takes.count == 3 && plan.phrases[1].takes.contains { !$0.row.selectable })
        try chooseSourceDuration(plan)
        #expect(!plan.phrases[1].takeDetail.isEmpty && session.usableTakeCount == 3)
    }

    @Test func inlineConfirmationIsSafeAndCannotApproveAReplacementQuote() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        fixture.cap = 0
        await fixture.plan.prepare()
        let action = try #require(session.pricedTakeAction())
        action.perform()
        let confirmation = try #require(session.task.confirm)
        #expect(confirmation.cancel.title == "Keep Working" && confirmation.confirm.priced)
        #expect(session.task.pressReturn(command: true) && session.task.confirm == nil)
        confirmation.confirm.perform()
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
        action.perform()
        let stale = try #require(session.task.confirm?.confirm)
        fixture.cap = nil
        await fixture.plan.prepareAnother(phrase: 0)
        stale.perform()
        await session.takesTask?.value
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
        #expect(!fixture.plan.generating)
    }

    @Test func phraseReviewUsesCommandReturnAndFreshPricedActivation() {
        var ran = 0
        let task = DirectorTask(scope: .fullTake, words: DirectorScope(kind: .fullTake, wordCount: 24), state: .choosingAI,
            close: PanelAction(id: "close", title: "Close", perform: {}))
        task.show(.choosingAI, headline: PanelHeadline(text: "Takes"), cards: [.takes],
            footer: PanelFooter(primary: PanelAction(id: "paid", title: "Make Takes · fixture", priced: true) { ran += 1 }))
        #expect(task.job == .voice && !task.pressReturn(command: false) && ran == 0)
        #expect(task.pressReturn(command: true) && ran == 1)
        task.show(.choosingAI, headline: PanelHeadline(text: "Takes"),
            footer: PanelFooter(primary: PanelAction(id: "paid2", title: "Make Takes · fixture", priced: true) { ran += 1 }))
        #expect(task.pressReturn(command: false) && ran == 1)
        task.primaryAppearedAt = Date().addingTimeInterval(-1)
        #expect(task.pressReturn(command: false) && ran == 2)
    }

    private func installReview(_ session: RewriteSession, fixture: Fixture, withFreeChanges: Bool) {
        session.takePlan = nil
        var changes = hunks([3, 10, 17]).map { RewriteChange(hunk: $0) }
        if withFreeChanges {
            changes.insert(RewriteChange(hunk: VoiceLabDiffHunk(kind: .cut, sourceWordIds: ["w0"], newTokens: [], correctedTexts: [],
                absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 0, sourceEndIndex: 1, anchorSeconds: nil)), at: 0)
            changes.insert(RewriteChange(hunk: VoiceLabDiffHunk(kind: .textOnly, sourceWordIds: ["w1"], newTokens: ["Old"], correctedTexts: ["Old"],
                absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 1, sourceEndIndex: 2, anchorSeconds: nil)), at: 1)
        }
        session.receive(changes); session.finishRun(seconds: 1); session.showProposal()
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        session.showProposal()
        session.takePlan = fixture.plan
    }

    /// ADR-R37 beside Use: while phrase 3's take waits for its click (its voice couldn't be measured), the footer never
    /// offers Use for fewer phrases than were voiced without saying so. The button names what it applies ("Use 2 of 3")
    /// and the note names the waiting phrase; one click on its take number makes it "Use Takes".
    @Test func useNamesWhatItAppliesWhileAnotherPhrasesTakeWaitsForItsClick() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        let plan = fixture.plan
        let starts = plan.phrases.map(\.window.start)
        let evidence = VoiceLabShortSpeechEvidence(mode: .unmeasured, recordId: fixture.record.id,
            consentMethod: fixture.record.consentMethod, voicedFrames: 16_000, takeCount: 1)
        fixture.transformRow = { row in
            let start = row.audio?.fit.plan.windowStart ?? 0
            guard row.audio != nil, starts.indices.min(by: { abs(starts[$0] - start) < abs(starts[$1] - start) }) == 2 else { return row }
            let unmeasured = row.checkingVoice(.shortSpeech(evidence))
            return VoiceLabTakeRow(id: row.id, index: row.index, seed: row.seed, receipt: row.receipt,
                audio: row.audio, qa: unmeasured.qa, score: row.score, failure: row.failure,
                qaReceipt: row.qaReceipt, generated: row.generated, quote: row.quote,
                accepted: row.acceptedRequestIDs, voiceCheck: unmeasured.voiceCheck)
        }
        await plan.prepare(); await plan.start(approved: true)
        try chooseSourceDuration(plan)
        session.showProposal()
        #expect(plan.phrases[0].selectedID != nil && plan.phrases[1].selectedID != nil && plan.phrases[2].selectedID == nil)
        let offered = try #require(plan.offeredTake(phrase: 2))
        let footer = session.task.footer
        #expect(footer.primary?.id == "useTakes" && footer.primary?.title == "Use 2 of 3", "\(footer)")
        #expect(footer.note?.hasPrefix("Phrase 3's take waits for your pick; Use keeps its original words.") == true, "\(footer)")
        #expect(session.useTakesTitle == "Use 2 of 3" && session.waitingTakePhrases == [2])
        try await ReviewCaptures.capture(DirectorPanel(task: session.task, model: editor).environment(editor.app),
                                         name: "rewrite-footer-use-2-of-3", size: CGSize(width: 360, height: 900))
        // One click on its take number, and Use applies every voiced phrase.
        #expect(plan.select(take: offered.id, phrase: 2))
        try chooseSourceDuration(plan)
        session.showProposal()
        #expect(session.task.footer.primary?.title == "Use Takes" && session.waitingTakesLine == nil, "\(session.task.footer)")
    }

    @Test func useTakesCommitsThreePhrasesAndReviewChangesAsOneUndoWithFeedback() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: true)
        let original = editor.project
        #expect(!editor.document.isDocumentEdited)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        await fixture.plan.play(phrase: 0)
        #expect(fixture.plan.audition.isPlaying)
        try chooseSourceDuration(fixture.plan)
        session.showProposal()
        #expect(session.task.footer.primary?.id == "useTakes")
        undo.beginUndoGrouping()
        #expect(session.task.pressReturn(command: true))
        await session.takesTask?.value
        undo.endUndoGrouping()
        #expect(editor.openRewrite == nil && editor.project.voiceLab.segments.count == 3)
        #expect(editor.project.transcript == original.transcript && editor.document.isDocumentEdited)
        #expect(editor.project.edits.cutWordIds.contains("w0") && editor.project.edits.corrections["w1"] == "Old")
        #expect(editor.undoSteps == 1 && undo.undoActionName == "Rewrite full take")
        #expect(!fixture.plan.audition.isPlaying)
        let currentFeedback = editor.currentVoiceFeedback
        let feedback = try #require(currentFeedback)
        #expect(feedback.phrases.count == 3 && feedback.spent == fixture.plan.spent && editor.voiceRewriteToastVisible)
        #expect(feedback.message.contains("3 phrases in your voice, 1 cut, 1 fix") && editor.lastAnnouncement == feedback.message)
        #expect(feedback.spendLine.hasPrefix("Spent ") && editor.canUndoVoiceRewrite)
        #expect(PanelJob.available(in: editor).contains(.voice))
        editor.app.settings.values["voiceLab.enabled"] = .bool(false)
        #expect(editor.currentVoiceFeedback == nil && !editor.canUndoVoiceRewrite)
        #expect(!PanelJob.available(in: editor).contains(.voice))
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        #expect(editor.selectedWordIDs == ["w0"])
        let render = try await editor.renderRequest(target: .fullEdit)
        let voice = try #require(render.voiceLab)
        #expect(voice.prepared.selectedSegmentRecipes.count == 3 && voice.prepared.outputPlan.pieces.filter { $0.kind == .synth }.count == 3)
        #expect(editor.containsAISpeech(clipID: nil))
        editor.sourceTime = try #require(editor.project.voiceLab.segments.first).replace.start + 0.2
        #expect(ViewerSection.tag(for: editor, standIn: false) == .aiVoice)
        #expect(editor.undoVoiceRewrite())
        #expect(editor.project == original && editor.currentVoiceFeedback == nil && !undo.canUndo)
        #expect(!editor.document.isDocumentEdited)
        #expect(!editor.containsAISpeech(clipID: nil) && !editor.voiceRewriteToastVisible)
        undo.redo()
        #expect(editor.project.voiceLab.segments.count == 3 && editor.currentVoiceFeedback == nil)
        #expect(editor.document.isDocumentEdited)
    }

    @Test func stalePublicationNeverShowsSuccessOrRegistersUndo() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        try chooseSourceDuration(fixture.plan)
        let barrier = ClipTakeBarrier()
        fixture.beforePublish = { phrase in if phrase == 1 { await barrier.pause() } }
        let accepting = Task { await session.acceptTakes() }
        await barrier.wait()
        fixture.current = false
        barrier.resume()
        #expect(await accepting.value == false)
        #expect(editor.project.voiceLab.segments.isEmpty && editor.currentVoiceFeedback == nil && !editor.voiceRewriteToastVisible)
        #expect(editor.undoSteps == 0 && !undo.canUndo && editor.openRewrite === session)
    }

    @Test func voiceUndoNeverUndoesAnInterveningEdit() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        try chooseSourceDuration(fixture.plan)
        undo.beginUndoGrouping(); let accepted = await session.acceptTakes(); undo.endUndoGrouping()
        #expect(accepted && editor.canUndoVoiceRewrite)
        undo.beginUndoGrouping(); editor.apply(.correct(id: "w0", text: "Later"), name: "Later correction"); undo.endUndoGrouping()
        let later = editor.project
        #expect(!editor.undoVoiceRewrite() && editor.project == later && undo.undoActionName == "Later correction")
    }

    @Test func stoppedReviewAcceptsOnlyTheFinishedPhraseWithTruthfulFeedback() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        let barrier = ClipTakeBarrier()
        fixture.beforePhrase = { phrase in if phrase == 1 { await barrier.pause() } }
        await fixture.plan.prepare()
        let operation = Task { await fixture.plan.start(approved: true); barrier.finished() }
        await barrier.wait()
        session.stopTakes(); await session.takesTask?.value; await operation.value
        #expect(fixture.plan.phrases[1].takeDetail == "Take 1 stopped.")
        try chooseSourceDuration(fixture.plan)
        #expect(await session.acceptTakes())
        let feedback = try #require(editor.currentVoiceFeedback)
        #expect(editor.project.voiceLab.segments.count == 1 && feedback.phrases.count == 1)
        #expect(feedback.spent.units == 1 && feedback.message.contains("1 phrase in your voice"))
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    /// MVP32 Clip 7: a take whose render recipe can't be made stopped Use on a Review card whose only button, Use 1 Take,
    /// repeated the failure. Now that phrase keeps the speaker's audio with one line of why, and the others are used.
    @Test func aTakeThatCannotRenderKeepsItsPhraseAsRecordedAndUseGoesOn() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        fixture.transformPublished = { phrase, published in
            guard phrase == 1 else { return published }
            return VoiceLabPublishedTake(assets: published.assets, audio: published.audio, outDuration: published.outDuration,
                                         words: [], chunks: published.chunks)
        }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        try chooseSourceDuration(fixture.plan)
        #expect(await session.acceptTakes(), "\(session.problem)")
        #expect(fixture.plan.phrases[1].leftOut && !fixture.plan.phrases[0].leftOut && !fixture.plan.phrases[2].leftOut)
        #expect(editor.project.voiceLab.segments.count == 2)
        #expect(editor.announcements.contains("Phrase 2 couldn't be made part of the video, so it keeps your original audio."), "\(editor.announcements)")
        #expect(editor.openRewrite == nil)
    }

    /// Every take refused: each phrase keeps its audio and the footer ends the Rewrite (never a Review card that repeats Use).
    @Test func whenNoTakeCanRenderTheFooterEndsTheRewrite() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        fixture.transformPublished = { _, published in
            VoiceLabPublishedTake(assets: published.assets, audio: published.audio, outDuration: published.outDuration,
                                  words: [], chunks: published.chunks)
        }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        try chooseSourceDuration(fixture.plan)
        #expect(await session.acceptTakes() == false)
        #expect(fixture.plan.phrases.allSatisfy(\.leftOut) && session.takePlanFailure == nil)
        session.showProposal()
        let primary = try #require(session.task.footer.primary, "\(session.task.footer)")
        #expect(["closeRewrite", "apply"].contains(primary.id))
        #expect(!session.task.cards.contains { card in
            if case .nextSteps(let steps) = card { return steps.chips.contains { $0.action.id == "useTakes" } } else { return false }
        })
    }

    /// No Rewrite footer that waits on nothing lacks a step forward (design.md R2): a plan failure Use could not settle
    /// still offers Keep My Original Audio with paid takes, and a fresh price without.
    @Test func aPlanFailureFooterAlwaysHasAStepForward() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        session.takePlanFailure = VoiceLabProjectError.invalidSegment
        session.showProposal()
        #expect(session.task.footer.primary?.id == "freshPrice", "\(session.task.footer)")
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        #expect(session.hasPaidTakes)
        session.takePlanFailure = VoiceLabProjectError.qaRejected
        session.showProposal()
        let forward = try #require(session.task.footer.primary, "\(session.task.footer)")
        #expect(forward.id == "keepOriginalAudio" && session.task.footer.note == "Fix the problem above to go on.")
        forward.perform()
        #expect(fixture.plan.phrases.allSatisfy(\.leftOut) && session.takePlanFailure == nil)
        #expect(["closeRewrite", "apply"].contains(session.task.footer.primary?.id ?? ""), "\(session.task.footer)")
    }

    /// design.md R2 "A take that can't fit its place" (the old S5's dead end: a 0.41 s take asked "Choose the video duration
    /// for phrase 1." with no duration to choose). A take far too short, or far too long, for every video duration keeps its
    /// phrase's recorded audio with one line of why and no click, and the footer's primary is Use for the rest.
    @Test(arguments: [false, true]) func aTakeNoVideoDurationCarriesKeepsItsAudioAndUseGoesOn(tooLong: Bool) async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        let plan = fixture.plan
        ClipTakeHTTP.state.withLock { $0.durationsInOrder[1] = tooLong ? $0.duration + 5 : $0.duration * 0.6 }
        await plan.prepare(); await plan.start(approved: true)
        // The panel's observation may already have drawn it (and settled phrase 2) while the takes landed.
        #expect(plan.phrases[1].takes.contains { $0.row.selectable && !plan.durationAvailable(take: $0) }, "\(plan.phrases[1].takeDetail)")
        #expect(!plan.fitsNoDuration(phrase: 0) && !plan.fitsNoDuration(phrase: 2))
        session.showProposal()
        #expect(plan.phrases[1].leftOut && !plan.phrases[0].leftOut && !plan.phrases[2].leftOut,
                "\(plan.phrases.map(\.takeDetail)) \(editor.announcements)")
        let line = "Phrase 2's take can't fit its place in the video, so it keeps your original audio."
        #expect(editor.announcements.filter { $0 == line }.count == 1, "\(editor.announcements)")
        let footer = session.task.footer
        #expect(footer.primary?.id == "useTakes", "\(footer)")
        #expect(footer.note.map { !$0.contains("Choose the video duration") } ?? true, "\(footer)")
        session.showProposal()
        #expect(editor.announcements.filter { $0 == line }.count == 1, "said once")
        #expect(await session.acceptTakes(), "\(session.problem)")
        #expect(editor.project.voiceLab.segments.count == 2 && editor.openRewrite == nil)
    }

    /// A passing take whose voice couldn't be measured (ADR-R37) is offered for the user's click only when a video duration
    /// can carry it; one that none can carry is never offered ([Choose Take 1] led to the dead end) and keeps its audio.
    @Test func anUnmeasuredTakeNoDurationCarriesIsNeverOfferedAndKeepsItsAudio() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        let plan = fixture.plan
        let starts = plan.phrases.map(\.window.start)
        let evidence = VoiceLabShortSpeechEvidence(mode: .unmeasured, recordId: fixture.record.id,
            consentMethod: fixture.record.consentMethod, voicedFrames: 16_000, takeCount: 1)
        fixture.transformRow = { row in
            let start = row.audio?.fit.plan.windowStart ?? 0
            guard row.audio != nil, starts.indices.min(by: { abs(starts[$0] - start) < abs(starts[$1] - start) }) == 0 else { return row }
            let unmeasured = row.checkingVoice(.shortSpeech(evidence))
            return VoiceLabTakeRow(id: row.id, index: row.index, seed: row.seed, receipt: row.receipt,
                audio: row.audio, qa: unmeasured.qa, score: row.score, failure: row.failure,
                qaReceipt: row.qaReceipt, generated: row.generated, quote: row.quote,
                accepted: row.acceptedRequestIDs, voiceCheck: unmeasured.voiceCheck)
        }
        ClipTakeHTTP.state.withLock { $0.durationsInOrder[0] = $0.duration * 0.6 }
        await plan.prepare(); await plan.start(approved: true)
        #expect(plan.phrases[0].selectedID == nil, "\(plan.phrases[0].takeDetail)")
        #expect(plan.phrases[0].takes.contains { $0.row.selectable && !plan.durationAvailable(take: $0) }, "\(plan.phrases[0].takeDetail)")
        #expect(plan.offeredTake(phrase: 0) == nil)
        session.showProposal()
        #expect(plan.phrases[0].leftOut, "\(plan.phrases[0].takeDetail)")
        #expect(editor.announcements.contains("Phrase 1's take can't fit its place in the video, so it keeps your original audio."))
        #expect(session.task.footer.primary?.id == "useTakes" && session.task.footer.primary?.id != "chooseTake", "\(session.task.footer)")
    }

    /// design.md R2 footer: a duration a take allows that nobody chose yet is the footer's primary, the phrase card's
    /// radio made one click away; a take no duration carries has Keep Original Audio instead (never a request for a choice
    /// no control makes).
    @Test func aDurationAllowedButNotChosenIsTheFootersPrimary() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        let plan = fixture.plan
        ClipTakeHTTP.state.withLock { $0.durationsInOrder[2] = $0.duration + 5 }
        // The takes land while no panel is drawn: drawing it chooses each duration (autoChooseVideo) and keeps phrase 3's
        // audio, so the footer's own steps are read before it is drawn again.
        session.takePlan = nil
        await plan.prepare(); await plan.start(approved: true)
        session.takePlan = plan
        #expect(plan.phrases.allSatisfy { $0.selected != nil && $0.videoChoice == nil }, "\(plan.phrases.map(\.takeDetail))")
        #expect(plan.acceptanceBlocker == "Choose the video duration for phrases 1 and 2.", "\(plan.acceptanceBlocker ?? "none")")
        #expect(plan.chooseVideo(.source, phrase: 1))
        #expect(plan.acceptanceBlocker == "Choose the video duration for phrase 1.", "\(plan.acceptanceBlocker ?? "none")")
        let forward = try #require(session.acceptanceForward(plan))
        #expect(forward.id == "chooseDuration.0" && forward.title == "Keep Source Duration for Phrase 1")
        #expect(ClipTakePlan.noDurationCopy([3], kept: false) == "Phrase 3's take can't fit its place in the video.")
        #expect(ClipTakePlan.noDurationCopy([1, 3]) == "The takes of phrases 1 and 3 can't fit their places in the video, so they keep your original audio.")
        // The click chooses phrase 1's duration and draws the panel, which keeps phrase 3's audio: Use is the step left.
        forward.perform()
        #expect(plan.phrases[0].videoChoice == .source && plan.phrases[2].leftOut, "\(plan.phrases.map(\.takeDetail))")
        #expect(session.task.footer.primary?.id == "useTakes", "\(session.task.footer)")
        #expect(RewriteSession.durationTitle(.cut, phrase: 0) == "Cut the Video for Phrase 1")
        #expect(RewriteSession.durationTitle(.retimed, phrase: 1) == "Match the Video for Phrase 2")
    }

    @Test func nonfittingReviewRefusesUseWithoutSuccessFeedbackOrUndo() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        session.takePlan = nil
        session.receive(hunks([10]).map { RewriteChange(hunk: $0) }); session.finishRun(seconds: 1); session.showProposal()
        session.takePlan = fixture.plan
        let original = editor.project
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        ClipTakeHTTP.state.withLock { $0.duration += 2.5; $0.speechMargin = 0.15 }
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        #expect(fixture.plan.phrases[0].takes.first?.fits == false)
        // No video duration carries the take, so the panel keeps the phrase's audio (design.md R2) and Use has nothing.
        session.showProposal()
        #expect(fixture.plan.phrases[0].leftOut)
        #expect(await session.acceptTakes() == false)
        #expect(editor.project == original && editor.currentVoiceFeedback == nil && !editor.voiceRewriteToastVisible)
        #expect(!undo.canUndo && editor.undoSteps == 0 && editor.openRewrite === session)
    }

    @Test(arguments: [false, true]) func createdVoiceReturnsToTheSameReviewAndRefreshesWithoutManualLegacyAction(pending: Bool) async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        session.takePlan = nil
        session.receive(hunks([10]).map { RewriteChange(hunk: $0) }); session.finishRun(seconds: 1); session.showProposal()
        let changes = session.changes
        editor.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        session.configureGeneration(client: fixture.client, store: fixture.store, speaker: .unavailable)
        let generation = try #require(session.generation)
        ClipTakeHTTP.state.withLock { $0.voicesVisible = false }
        await generation.discover(language: "en"); await generation.finishQuotePreparationForTests()
        #expect(generation.voices.isEmpty && generation.selectedVoiceID == nil)
        generation.prepareQuote = { [weak generation] in
            guard generation?.selectedVoiceID == fixture.record.id else { return }
            await fixture.plan.prepare()
        }
        var created = fixture.record
        if pending { created.status = .verificationRequired; try await fixture.store.save(created) }
        ClipTakeHTTP.state.withLock { $0.voicesVisible = true }
        let enrollment = editor.app.voiceLabSession
        enrollment.flow.owner = editor; enrollment.flow.state = .finished; enrollment.flow.finishedRecord = created; enrollment.showEnrollment = true
        enrollment.returnToRewrite()
        await session.takesTask?.value; await generation.finishQuotePreparationForTests()
        #expect(editor.openRewrite === session && session.changes == changes && !enrollment.showEnrollment)
        #expect(generation.selectedVoiceID == (pending ? nil : created.id))
        #expect((fixture.plan.approvalID != nil) == !pending)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty })
    }

    @Test func invalidatedLateResultCannotRestoreRowsOrAudition() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan, barrier = ClipTakeBarrier()
        fixture.beforeProgress = { await barrier.pause() }
        await plan.prepare()
        let operation = Task { await plan.start(approved: true) }
        await barrier.wait()
        fixture.current = false; plan.invalidate()
        barrier.resume(); await operation.value; await plan.invalidation?.value
        #expect(plan.phrases[0].takes.isEmpty && !plan.audition.isPlaying && !plan.stillCurrent)
        #expect(plan.spent.units == 1 && ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    @Test func changingGenerationInputsCannotReplaceAPaidPlanWithoutDiscardConfirmation() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        session.takePlan = nil
        session.receive(hunks([10]).map { RewriteChange(hunk: $0) }); session.finishRun(seconds: 1); session.showProposal()
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        session.showProposal()
        editor.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        session.configureGeneration(client: fixture.client, store: fixture.store, speaker: .unavailable)
        let generation = try #require(session.generation)
        await generation.discover(language: "en"); await generation.finishQuotePreparationForTests()
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        session.takePlan = fixture.plan
        generation.chooseVoice(nil); await generation.finishQuotePreparationForTests()
        #expect(session.takePlan === fixture.plan && session.hasPaidTakes && !fixture.plan.stillCurrent)
        #expect(generation.problem.contains("Your paid takes are kept") && ClipTakeHTTP.state.withLock { $0.texts.count == 1 })
    }

    // MARK: Automatic fixes (RewriteAutoFix.swift, design.md R2 "Automatic fixes")

    /// Approves Get Price as the user does: the footer's priced Make Takes, then its inline confirmation if it asks.
    private func approvePrice(_ session: RewriteSession) throws {
        let action = try #require(session.pricedTakeAction(), "\(session.task.footer)")
        action.perform()
        if let confirm = session.task.confirm { confirm.confirm.perform() }
    }
    /// Waits until takes, automatic steps and measured rewords are all done.
    private func settle(_ session: RewriteSession) async {
        for _ in 0..<1000 {
            if let task = session.takesTask { await task.value }
            if let work = session.autoFix.work { await work.value; continue }
            if let work = session.wordingFit.measuredWork { await work.value; continue }
            await Task.yield()
            if session.autoFix.work == nil, session.wordingFit.measuredWork == nil, !session.takesBusy { return }
            // A take still publishing or preparing its video is real work, not a yield away (up to 10 s in all).
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Every take too long and failing its word check (MVP13's dead end, cause a): with no take selected the measured
    /// reword still runs from the closest take, and a take of the new wording is made with no click; Use is all that's left.
    @Test func allTakesTooLongAreRewordedAndRetakenWithNoClick() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        // An automatic round must move toward the slot (voice-lab §8.2.2): a too-long take gets a shorter wording.
        let connector = ScriptedFitConnector(["Corrected Hi"])
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let first = plan.phrases[0].text
        ClipTakeHTTP.state.withLock { $0.durations[first] = $0.duration + 5; $0.failQA = false; $0.failFirstQA = 1 }
        #expect(session.task.footer.note?.contains("Automatic fixes may spend up to $0.10 more.") == true, "\(session.task.footer)")
        try approvePrice(session)
        await settle(session)
        #expect(await connector.requests.count == 1)
        #expect(ClipTakeHTTP.state.withLock { $0.texts } == [first, "Corrected Hi"])
        #expect(plan.phrases[0].takes.count == 2 && plan.phrases[0].selected?.row.selectable == true)
        #expect(plan.phrases[0].selected?.number == 2 && session.autoFix.rounds[0] == 1 && session.autoFix.lines.isEmpty)
        #expect(session.task.footer.primary?.id == "useTakes", "\(session.task.footer)")
        #expect(session.task.headline.sub == "Listen, pick a take, then use them.")
    }

    /// A phrase with a passing take that fits is voiced: a later speaking-rate recalibration from measured takes, which
    /// now estimates its words too long for the slot, never blocks it, its change row or Use (the Rewrite smoke's S6,
    /// "Change 3 needs a shorter wording before takes." beside its fitting take). The new estimate holds back only a
    /// phrase that isn't voiced.
    @Test func recalibrationNeverBlocksAVoicedPhraseOrUse() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan)
        try approvePrice(session)
        await settle(session)
        let take = try #require(plan.phrases[0].selected)
        #expect(take.row.selectable && plan.lengthFits(take: take), "\(plan.phrases[0].takeDetail)")
        let ordinal = try #require(session.takePhraseOrdinals(plan.phrases[0]).first)
        let model = try #require(plan.measuredInput(take: take.id)?.modelID)
        session.pricedAnyway = []
        #expect(session.voicedOrdinals == [ordinal] && session.blockedVoiceOrdinals.isEmpty)
        // Measured takes read as speech nearly four times slower than estimated (the most a sample may say).
        for _ in 0..<10 { session.recordSpeakingRate(model: model, recordID: "fixture-voice", take: UUID(), measured: 3.9, baseline: 1) }
        #expect(session.voiceReview(ordinal)?.timing?.fits == false)
        session.showProposal()
        #expect(session.blockedVoiceOrdinals.isEmpty)
        #expect(session.task.footer.primary?.id == "useTakes", "\(session.task.footer)")
        #expect(session.task.footer.note?.contains("before takes") != true, "\(session.task.footer)")
        // Kept as recorded, the phrase isn't voiced any more, and with takes paid the estimate still holds nothing back:
        // the footer goes on (MVP32 Clip 7's "need a shorter wording before takes" with no step forward).
        plan.leaveOut(phrase: 0)
        session.showProposal()
        #expect(session.voicedOrdinals.isEmpty && session.blockedVoiceOrdinals.isEmpty)
        #expect(session.task.footer.primary != nil, "\(session.task.footer)")
    }

    /// A failed word check gets one automatic Try another; its passing take is chosen with no click.
    @Test func aFailedWordCheckTriesAnotherTakeWithNoClick() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, rewriteConnector: MeasuredFitConnector()); defer { editor.close() }
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.failFirstQA = 1 }
        try approvePrice(session)
        await settle(session)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count } == 2)
        #expect(plan.phrases[0].takes.count == 2 && plan.phrases[0].selected?.number == 2)
        #expect(session.autoFix.triedAnother == [0] && session.task.footer.primary?.id == "useTakes",
            "\(session.autoFix.rounds) \(plan.phrases[0].takes.map { "\($0.number) \($0.row.selectable) \(String(describing: $0.row.failure)) \(String(describing: $0.row.voiceCheck))" })")
    }

    /// MVP13 (cause b): Scribe spells a replacement word as the word it sounds like. The take passes; nothing is fixed.
    @Test func aHomophoneOfTheAskedWordPassesWithNoRetry() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, rewriteConnector: MeasuredFitConnector()); defer { editor.close() }
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.heardAs = ["Hello": "Hallo"] }
        try approvePrice(session)
        await settle(session)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count } == 1)
        #expect(plan.phrases[0].selected?.row.selectable == true && session.autoFix.rounds.isEmpty)
    }

    /// Three rounds per phrase, then its original words: every paid take stays listed, nothing is discarded, the summary
    /// says so with Undo, and the footer's Apply completes the Rewrite with the text fix.
    @Test func afterThreeRoundsThePhraseKeepsItsOriginalWordsAndApplyCompletes() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, rewriteConnector: MeasuredFitConnector()); defer { editor.close() }
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.failQA = true }
        try approvePrice(session)
        await settle(session)
        #expect(session.autoFix.rounds[0] == RewriteAutoFixState.maximumRounds && session.autoFix.gaveUp == [0])
        #expect(plan.phrases[0].leftOut && plan.phrases[0].selectedID == nil && !plan.isRetired && session.takePlan === plan)
        let made = ClipTakeHTTP.state.withLock { $0.texts.count }
        #expect(plan.phrases[0].takes.count == made && made >= 2, "\(made) synthesized, \(plan.phrases[0].takes.count) listed")
        let kept = try #require(session.task.nextSteps.first { $0.id == "kept.0" })
        #expect(kept.line == "Phrase 1 kept your original audio after 3 tries." && kept.chips.first?.action.title == "Undo")
        let apply = try #require(session.task.footer.primary)
        #expect(apply.id == "apply" && apply.title == "Apply 1 text fix", "\(session.task.footer)")
        apply.perform()
        #expect(!session.isOpen && editor.openRewrite == nil, "\(String(describing: editor.proposal?.changes.map { "\($0.ordinal) \($0.state) \($0.isFree)" })) \(session.task.state)")
    }

    /// The cap: the next automatic step past max($0.10, the price) waits for [Keep fixing · ≈ $y], which goes on.
    @Test func theSpendingCapStopsAutomaticFixesUntilKeepFixing() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, rewriteConnector: MeasuredFitConnector()); defer { editor.close() }
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.failFirstQA = 1 }
        try approvePrice(session)
        session.autoFix.allowance = 0
        await settle(session)
        let cap = try #require(session.autoFix.capped)
        #expect(cap.phrase == 0 && ClipTakeHTTP.state.withLock { $0.texts.count } == 1 && !session.autoFix.running)
        let keep = try #require(session.task.footer.primary)
        #expect(keep.id == "keepFixing" && keep.title.hasPrefix("Keep fixing") && keep.priced, "\(keep.title)")
        keep.perform()
        await settle(session)
        #expect(session.autoFix.capped == nil && ClipTakeHTTP.state.withLock { $0.texts.count } == 2)
        #expect(plan.phrases[0].selected?.number == 2 && session.autoFix.spent > 0)
    }

    /// AI sends billed to a key count against the cap; a local or subscription AI's do not.
    @Test(arguments: [false, true]) func billedAISendsCountTowardTheCap(billed: Bool) async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = MeasuredFitConnector(id: billed ? .anthropic : .ollama)
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        #expect(session.sendAsksFirst == billed)
        let plan = try #require(session.takePlan)
        session.armAutoFix(plan)
        let estimate = CostEstimate(provider: "anthropic", operation: "rewrite", units: 1, unit: "request", usd: Decimal(string: "0.04"), basis: "test")
        #expect(session.autoFixChargeSend(estimate, phrase: 0))
        #expect(session.autoFix.spent == (billed ? Decimal(string: "0.04")! : 0))
        session.autoFix.spent = session.autoFix.allowance
        #expect(session.autoFixChargeSend(estimate, phrase: 0) == !billed)
        #expect((session.autoFix.capped != nil) == billed)
    }

    /// MVP18 ("always same variants"): every take runs long. Each reworded round sends the AI the wordings already
    /// tried with their measured results and forbids repeats; a repeated wording is never voiced again, and the next
    /// round is told it repeated. Three rounds, three distinct wordings at most, then the original words.
    @Test func threeRoundsNeverRepeatAWordingAndSendTheTriedHistory() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = ScriptedFitConnector(["Corrected Hi", "corrected, HI", "Corrected A"])
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let first = plan.phrases[0].text
        ClipTakeHTTP.state.withLock { $0.duration += 5; $0.echoQA = true }
        try approvePrice(session)
        session.autoFix.allowance = 100
        await settle(session)
        let requests = await connector.requests
        let texts = ClipTakeHTTP.state.withLock { $0.texts }
        #expect(requests.count == 3, "\(requests.map(\.cachedBlock))")
        #expect(texts == [first, "Corrected Hi", "Corrected A"], "\(texts)")
        #expect(Set(texts.map(VoiceLabFitTried.key)).count == texts.count)
        let second = requests.dropFirst().first?.cachedBlock ?? "", third = requests.dropFirst(2).first?.cachedBlock ?? ""
        #expect(second.contains("Never return any of them again") && second.contains("“\(first)”: too long by")
            && second.contains("“Corrected Hi”: too long by"), "\(second)")
        #expect(third.contains("“corrected, HI”: repeated an earlier wording, not used"), "\(third)")
        #expect(session.autoFix.rounds[0] == RewriteAutoFixState.maximumRounds && session.autoFix.gaveUp == [0])
        let history = try #require(session.autoFixHistoryLine(plan.phrases[0], plan: plan))
        #expect(history.hasPrefix("Round 3 of 3 · tried: ") && history.contains("“corrected, HI” (repeat, not used)"), "\(history)")
    }

    /// The AI's reworded phrase dropped its bridge word ("Corrected" joins the change to the recording before it), so
    /// it could not be priced or placed, and the round was silently used up. The reply is checked before it counts:
    /// one free re-ask in the same round names the words to keep and lists the dropped wording, and only the valid
    /// wording is priced and voiced. No speech is paid for the dropped one.
    @Test func aReplyThatDropsTheBridgeWordsIsReaskedOnceInTheSameRound() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = ScriptedFitConnector(["Hi", "Corrected Hi"])
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let first = plan.phrases[0].text
        ClipTakeHTTP.state.withLock { $0.durations[first] = $0.duration + 5 }
        try approvePrice(session)
        session.autoFix.allowance = 100
        await settle(session)
        let requests = await connector.requests
        let texts = ClipTakeHTTP.state.withLock { $0.texts }
        #expect(requests.count == 2, "\(requests.map(\.cachedBlock))")
        #expect(texts == [first, "Corrected Hi"], "\(texts) \(plan.problem)")
        let firstAsk = requests.first?.cachedBlock ?? "", reask = requests.dropFirst().first?.cachedBlock ?? ""
        #expect(firstAsk.contains("must begin with “Corrected”"), "\(firstAsk)")
        #expect(reask.contains("must begin with “Corrected”") && reask.contains("“Hi”: dropped the joining words, not used"), "\(reask)")
        #expect(session.autoFix.rounds[0] == 1 && session.autoFix.gaveUp.isEmpty, "\(session.autoFix.rounds)")
        #expect(plan.phrases[0].text == "Corrected Hi" && plan.problem.isEmpty, "\(plan.phrases[0].text) \(plan.problem)")
        #expect(plan.phrases[0].selected?.number == 2 && session.task.footer.primary?.id == "useTakes", "\(session.task.footer)")
    }

    /// A re-ask that still drops the bridge words ends its round with the reason on the phrase card, never a take of
    /// words that can't be placed; the phrase's words stay as they were. After three such rounds the original words.
    @Test func aReaskThatStillDropsTheBridgeWordsEndsTheRoundWithItsReason() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = ScriptedFitConnector(["Hi", "Hey", "Hi there", "Hey there", "Hi you", "Hey you"])
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let first = plan.phrases[0].text
        ClipTakeHTTP.state.withLock { $0.durations[first] = $0.duration + 5 }
        try approvePrice(session)
        session.autoFix.allowance = 100
        await settle(session)
        let requests = await connector.requests
        #expect(requests.count == 6, "\(requests.map(\.cachedBlock))")
        #expect(ClipTakeHTTP.state.withLock { $0.texts } == [first])
        #expect(plan.phrases[0].text == first, "\(plan.phrases[0].text)")
        #expect(session.autoFix.rounds[0] == RewriteAutoFixState.maximumRounds && session.autoFix.gaveUp == [0])
        let history = try #require(session.autoFixHistoryLine(plan.phrases[0], plan: plan))
        #expect(history.hasPrefix("Round 3 of 3 · tried: ") && history.contains("“Hey you” (dropped “Corrected”, not used)"), "\(history)")
    }

    /// A provider failure (here: out of credit) shows its cause and its one fix; no wording round or wording chip.
    @Test func aProviderFailureShowsItsFixAndNeverRewords() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connector = ScriptedFitConnector([])
        let (editor, session) = try await productionSession(fixture, rewriteConnector: connector); defer { editor.close() }
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.dialogueStatus = 402 }
        try approvePrice(session)
        await settle(session)
        #expect(plan.phrases[0].takes.first?.row.failure == .provider(.quotaExceeded))
        #expect(await connector.requests.isEmpty && session.autoFix.rounds.isEmpty)
        let steps = try #require(session.task.nextSteps.first { $0.id == "take.0" }, "\(session.task.nextSteps.map(\.id))")
        #expect(steps.line?.contains("Add credit to your ElevenLabs account") == true, "\(steps.line ?? "")")
        #expect(steps.chips.map(\.action.title) == ["Price a take", "Keep original words"])
        #expect(!plan.phrases[0].takes.isEmpty)
    }

    /// One Stop for the whole resolver: it keeps the takes made so far and the chips show.
    @Test func stopKeepsTheTakesAndShowsTheChips() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, rewriteConnector: MeasuredFitConnector()); defer { editor.close() }
        let plan = try #require(session.takePlan)
        ClipTakeHTTP.state.withLock { $0.failQA = true }
        let barrier = ClipTakeBarrier()
        var calls = 0
        fixture.beforeProgress = { calls += 1; if calls == 2 { await barrier.pause() } }
        try approvePrice(session)
        await barrier.wait()
        #expect(session.task.headline.stop?.id == "stopAutoFix", "\(session.task.headline)")
        #expect(session.task.nextSteps.first { $0.id == "autofix" }?.line == "Fixing phrase 1: making a take…")
        session.task.headline.stop?.perform()
        barrier.resume()
        await settle(session)
        #expect(session.autoFix.stopped && session.takePlan === plan && !plan.phrases[0].takes.isEmpty)
        #expect(session.task.nextSteps.contains { $0.id == "take.0" && $0.chips.contains { $0.action.id == "tryAnother.0" } })
        #expect(session.task.nextSteps.compactMap(\.ask).count == 1)
    }

    // MARK: Expressions on a takes-panel phrase (design.md R2 "Expressions")

    /// MVP13 (scope 3a): with paid takes an expression asked to discard every take, out of view. Now it changes that phrase
    /// only: no confirmation, the plan and its takes stay, the old takes read "Before expression", a fresh quote is ready.
    @Test func anExpressionWithPaidTakesKeepsThemAndRequotesOnlyThatPhrase() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan)
        await plan.start(approved: true, quoteID: plan.approvalID)
        let takes = plan.phrases[0].takes.map(\.id)
        #expect(!takes.isEmpty && session.hasPaidTakes)
        let tags = [VoiceLabAudioTag(beforeToken: 1, tag: "laughs")]
        session.updateAudioTags(tags, phrase: plan.phrases[0])
        #expect(session.shownAudioTags(plan.phrases[0]) == tags)
        await session.takesTask?.value
        #expect(session.task.confirm == nil && session.takePlan === plan && !plan.isRetired)
        #expect(plan.phrases[0].audioTags == tags && plan.phrases[0].takes.map(\.id) == takes)
        #expect(plan.phrases[0].beforeExpression == Set(takes) && plan.phrases[0].selectedID == nil)
        #expect(plan.approvalID != nil && session.takeQuotePhrase == 0)
        // Removing it works the same way.
        session.updateAudioTags([], phrase: plan.phrases[0])
        await session.takesTask?.value
        #expect(plan.phrases[0].audioTags.isEmpty && plan.phrases[0].takes.map(\.id) == takes && session.task.confirm == nil)
    }

    /// Scope 3b: a merged phrase gets the tag; a phrase whose hunks map to no change (a widened sentence) no longer
    /// returns silently: the tag goes into the plan's phrase.
    @Test(arguments: [false, true]) func anExpressionOnAMergedOrUnmappedPhraseIsAdded(unmapped: Bool) async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture, touchingVoices: true); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let phrase = try #require(plan.phrases.first { $0.indices.count > 1 } ?? plan.phrases.first)
        if unmapped { session.takePlanOrdinals = [] }
        let tags = [VoiceLabAudioTag(beforeToken: 0, tag: "sighs")]
        session.updateAudioTags(tags, phrase: phrase)
        #expect(session.shownAudioTags(phrase) == tags)
        await session.takesTask?.value
        #expect(plan.phrases[phrase.id].audioTags == tags && session.task.confirm == nil && session.takePlan === plan)
        // Nothing was paid yet: the whole set is priced again, so Get Price still covers every phrase.
        #expect(plan.approvalID != nil && session.takeQuotePhrase == nil)
    }

    /// Scope 3c: while takes run the tag shows at once with a line saying why it waits, then it is applied.
    @Test func anExpressionChosenWhileTakesRunIsShownThenApplied() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let tags = [VoiceLabAudioTag(beforeToken: 1, tag: "laughs")]
        var shown: [VoiceLabAudioTag] = [], note: String?
        fixture.beforeProgress = {
            guard shown.isEmpty else { return }
            session.updateAudioTags(tags, phrase: plan.phrases[0])
            shown = session.shownAudioTags(plan.phrases[0]); note = session.autoFix.expressionNote[0]
        }
        await plan.start(approved: true, quoteID: plan.approvalID)
        #expect(shown == tags && note == "The expression is added when the current takes finish.")
        await session.takesTask?.value
        #expect(plan.phrases[0].audioTags == tags && session.autoFix.expressionNote[0] == nil)
    }

    /// Scope 2: a single valid duration is chosen for the user; before a passing take the card's line says what's next.
    @Test func aLoneValidDurationIsChosenAndWaitingSaysWhatIsNext() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan)
        #expect(session.phraseStatus(plan.phrases[0], plan: plan) == "Takes start after you approve the price.")
        #expect(plan.validVideoChoices(phrase: 0).isEmpty)
        await plan.start(approved: true, quoteID: plan.approvalID)
        let valid = plan.validVideoChoices(phrase: 0)
        #expect(!valid.isEmpty)
        #expect(plan.phrases[0].videoChoice == valid[0])
    }

    /// Scope 2: the quote marks sit on the first and last words, so no space is left inside them.
    @Test func theQuoteHasNoSpaceInsideItsMarks() {
        let words = ["you're", "using", "your", "Claude"]
        #expect(AudioTagPhrase.pieces(words: words, tags: [], caret: nil) == [.word(0, "“you're"), .word(1, "using"), .word(2, "your"), .word(3, "Claude”")])
        let tagged = AudioTagPhrase.pieces(words: words, tags: [VoiceLabAudioTag(beforeToken: 3, tag: "laughs")], caret: nil)
        #expect(tagged == [.word(0, "“you're"), .word(1, "using"), .word(2, "your"), .tag(0), .word(3, "Claude”")])
        #expect(AudioTagPhrase.pieces(words: ["Hi"], tags: [VoiceLabAudioTag(beforeToken: 1, tag: "sighs")], caret: nil) == [.word(0, "“Hi"), .tag(0), .close])
    }
}
#endif
