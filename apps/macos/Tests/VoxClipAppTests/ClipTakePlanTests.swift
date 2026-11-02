#if DEBUG
import AppKit
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia
@testable import VoxClip

private struct ClipTakeKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { "inert-fixture-key" }
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
        generated = pcm16k.count < 80_000
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
        var duration = 0.5
        var speechMargin = 0.05
        var voicedFraction = 1.0
        var synthesisStatus = 200
        var failQA = false
        var malformedSynthesis = false
        var malformedQA = false
        var failOwner = false
        var failGenerated = false
        var amplitudeVariance = 0.0
        var echoQA = false
        var gets = 0
        var qa = 0
        var voicesVisible = true
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
                data = Data(#"[{"model_id":"eleven_v3","name":"Speech","can_do_text_to_speech":true,"can_do_voice_conversion":false,"languages":[{"language_id":"en"}],"maximum_text_length_per_request":5000}]"#.utf8)
            case ("GET", "/v2/voices"):
                data = Self.state.withLock { $0.voicesVisible } ? Data(#"{"voices":[{"voice_id":"fixtureOwnVoice","name":"My voice","category":"cloned","is_owner":true}],"has_more":false}"#.utf8) : Data(#"{"voices":[],"has_more":false}"#.utf8)
            case ("POST", "/v1/text-to-speech/fixtureOwnVoice/with-timestamps"):
                let body = try #require(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
                let text = try #require(body["text"] as? String)
                let seed = try #require(body["seed"] as? UInt32)
                let duration = Self.state.withLock { state in state.texts.append(text); state.seeds.append(seed); return state.duration }
                let variance = Self.state.withLock { $0.amplitudeVariance }
                var pcm = Data()
                for index in 0..<Int(duration * 24_000) {
                    let seconds = Double(index) / 24_000
                    let amplitude = 1 + variance * sin(2 * Double.pi * 2 * seconds)
                    var value = Int16((sin(2 * Double.pi * 100 * seconds) * 3_200 * amplitude).rounded()).littleEndian
                    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
                }
                let characters = Array(text).map(String.init)
                let margin = Self.state.withLock { $0.speechMargin }
                let speechDuration: Double = duration - 2 * margin
                let starts = characters.indices.map { margin + Double($0) * speechDuration / Double(characters.count) }
                let ends = characters.indices.map { margin + Double($0 + 1) * speechDuration / Double(characters.count) }
                if Self.state.withLock({ $0.malformedSynthesis }) {
                    data = try JSONSerialization.data(withJSONObject: ["audio_base64": pcm.base64EncodedString()])
                } else {
                    data = try JSONSerialization.data(withJSONObject: ["audio_base64": pcm.base64EncodedString(), "alignment": [
                        "characters": characters, "character_start_times_seconds": starts, "character_end_times_seconds": ends]])
                }
            case ("POST", "/v1/speech-to-text"):
                let state = Self.state.withLock { state in state.qa += 1; return state }
                let word = state.failQA ? "wrong" : "Hello"
                if state.malformedQA { data = Data(#"{"language_code":"eng"}"#.utf8) }
                else {
                    let words = state.echoQA ? (state.texts.last ?? word).split(separator: " ").map(String.init) : [word]
                    let stride = (state.duration - 0.2) / Double(words.count)
                    let timed = words.enumerated().map { index, text in
                        ["type": "word", "text": text, "start": 0.1 + Double(index) * stride,
                         "end": 0.1 + Double(index + 1) * stride] as [String: Any]
                    }
                    data = try JSONSerialization.data(withJSONObject: ["language_code": "eng", "words": timed])
                }
            default: throw URLError(.unsupportedURL)
            }
            let url = try #require(request.url)
            let status = url.path.contains("/text-to-speech/") ? Self.state.withLock { $0.synthesisStatus } : 200
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
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

@Suite("Clip take plan", .serialized, .timeLimit(.minutes(2)))
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
        var fatalResult: VoiceLabTakeFailure?
        var beforePhrase: ((Int) async throws -> Void)?
        var beforeQuote: (() async -> Void)?
        var beforePublish: ((Int) async -> Void)?
        var beforeDispatch: (() -> Void)?
        var beforeProgress: (@MainActor @Sendable () async -> Void)?
        var beforeScratch: (() async -> Void)?
        var publishedIDs: [UUID] = []
        var lastBatch: VoiceLabTakeBatch?
        var lostResponseStage: Bool?
        var simulatedRequests: [UUID] = []
        var current = true
        init(root: URL, plan: ClipTakePlan, ledger: VoiceLabSpendLedger, playback: TakeReviewPlayback, source: Project, envelope: AudioEnvelope,
             client: ElevenLabsVoiceLab, store: VoiceConsentStore, record: VoiceConsentRecord) {
            self.root = root; self.plan = plan; self.ledger = ledger; self.playback = playback; self.source = source; self.envelope = envelope
            self.client = client; self.store = store; self.record = record
        }
    }
    private func project() throws -> (Project, [Float], AudioEnvelope) {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.id = UUID().uuidString.lowercased()
        project.voiceLab.segments = []; project.voiceLab.assets = []
        project.edits = ProjectEdits()
        project.media.source.durationSeconds = 121
        project.media.source.audio?.sampleRate = 24_000
        project.transcript?.words = (0..<24).map { index in
            let start = 0.2 + Double(index) * 5
            return TimedWord(id: "w\(index)", text: "old", start: start, end: start + 3.8)
        }
        project.transcript?.durationSeconds = 121
        let source = (0..<(121 * 24_000)).map { index -> Float in
            let seconds = Double(index) / 24_000
            return (4..<5.2).contains(seconds) ? 0.001 : Float(0.1 * sin(2 * Double.pi * 100 * seconds))
        }
        return (project, source, VoiceLabTakeProcessing.envelope(source, sampleRate: 24_000))
    }
    private func hunks(_ indices: [Int]) -> [VoiceLabDiffHunk] {
        indices.map { index in
            VoiceLabDiffHunk(kind: .voice, sourceWordIds: ["w\(index)"], newTokens: ["Hello"], correctedTexts: [],
                absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: index, sourceEndIndex: index + 1, anchorSeconds: nil)
        }
    }
    private func fixture(indices: [Int] = [3, 10, 17], badPlacement: Bool = false, unknownPrice: Bool = false) async throws -> Fixture {
        ClipTakeHTTP.state.withLock { $0 = ClipTakeHTTP.State() }
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
        let (sourceProject, pcm, envelope) = try project()
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
        ClipTakeHTTP.state.withLock { $0.duration = plan.phrases[0].originalLength }
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
            do {
                let batch = try await real.prepare(inputs, indices, candidates)
                made?.lastBatch = batch
                return batch
            }
            catch is CancellationError { throw CancellationError() }
            catch { Issue.record("Unexpected quote refusal: \(String(reflecting: error))"); throw error }
        }
        backend.approve = { [weak made] batch, indices in made?.approved += 1; try await real.approve(batch, indices) }
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
                await progress(rows)
            }
            try await made?.afterPhrase?(phrase)
            if let failure = made?.fatalResult { return VoiceLabTakeRunResult(rows: result.rows, end: .fatal, failure: failure) }
            return result
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
            return try await real.publish(phrase, row, input, date)
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
            try #require(plan.chooseVideo(.source, phrase: phrase.id))
        }
    }

    private func sourceAcceptance(_ plan: ClipTakePlan) async throws -> ClipTakePlan.Acceptance {
        try chooseSourceDuration(plan)
        return try await plan.acceptance()
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
        #expect(fixture.plan.select(take: row.id, phrase: 0))
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
        #expect(plan.phrases[0].selectedID == original && plan.phrases[0].bestMeasured?.id == original)
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
        #expect(plan.phrases.allSatisfy { $0.status == .ready && $0.takes.count == 1 && $0.selected?.fits == true },
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

    @Test func unplaceableSetDoesNotDecodeOrQuote() async throws {
        do {
            let fixture = try await fixture(badPlacement: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            await fixture.plan.prepare()
            #expect(fixture.decoded == 0 && fixture.preparations == 0)
        } catch { #expect(error as? ClipTakePlan.Failure == .placement(.geometry(.unknownWord("w999")))) }
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
    func acceptedMalformedOrLostResponsesCountWithoutReceiptOrAutomaticResend(qa: Bool, lost: Bool) async throws {
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
        #expect(rows.count == attempts && rows.allSatisfy { !$0.selectable && $0.qaReceipt == nil })
        #expect(rows.allSatisfy { ($0.receipt != nil) == (qa && !lost) && $0.acceptedRequestIDs.count == (qa ? 2 : 1) })
        let accepted = Set(rows.flatMap(\.acceptedRequestIDs))
        let expectedIDs = Set(quotes.prefix(attempts).flatMap { qa ? [$0.synthesis.requestID, $0.qa.requestID] : [$0.synthesis.requestID] })
        #expect(accepted == expectedIDs)
        if lost {
            #expect(fixture.simulatedRequests.count == expectedIDs.count && Set(fixture.simulatedRequests) == expectedIDs)
            #expect(Set(quotes.prefix(attempts).map(\.seed)).count == attempts)
            #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
        } else {
            #expect(ClipTakeHTTP.state.withLock { $0.texts.count == attempts && $0.qa == (qa ? attempts : 0) && Set($0.seeds).count == attempts })
        }
        #expect(fixture.plan.spent.units == Double(attempts) && fixture.plan.phrases[0].selected == nil)
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
        #expect(fixture.plan.phrases[0].status == .failed(RewriteSession.refusal(VoiceConsentError.voiceOwnerMismatch)),
                "\(fixture.plan.phrases[0].takes.map { String(describing: $0.row.failure) })")
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

    private func productionSession(_ fixture: Fixture) async throws -> (EditorModel, RewriteSession) {
        var source = fixture.source
        let (_, pcm, _) = try project()
        let audio = fixture.root.appendingPathComponent("source.wav")
        try VoiceTrainingAudio.wav(Array(pcm.prefix(120 * 24_000)), rate: 24_000).write(to: audio)
        source.media.source.absolutePath = audio.path
        source.media.source.durationSeconds = 120
        source.transcript?.durationSeconds = 120
        let bridgeEnd = try #require(source.transcript?.words[10].start)
        source.transcript?.words[9].end = bridgeEnd
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": fixture.root.path]))
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: source, demo: true), app: app, preview: DemoPreviewEngine())
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: fixture.envelope, connector: nil)
        editor.rewrite = session
        let fix = VoiceLabDiffHunk(kind: .textOnly, sourceWordIds: ["w9"], newTokens: ["Corrected"], correctedTexts: ["Corrected"],
            absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 9, sourceEndIndex: 10, anchorSeconds: nil)
        session.receive(([fix] + hunks([10])).map { RewriteChange(hunk: $0) })
        session.finishRun(seconds: 1); session.showProposal()
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
            return backend
        }
        let generation = try #require(session.generation)
        generation.prepareQuote = {}
        await generation.discover(language: "en"); await generation.finishQuotePreparationForTests()
        await session.prepareTakes()
        let plan = try #require(session.takePlan)
        #expect(plan.problem.isEmpty, "\(plan.problem), \(generation.problem)")
        #expect(plan.phrases[0].text.contains("Corrected"))
        #expect(plan.phrases[0].window.leftBridgeWordIds.contains("w9"))
        #expect(plan.approvalID != nil && plan.stillCurrent)
        ClipTakeHTTP.state.withLock { $0.duration = plan.phrases[0].originalLength; $0.echoQA = true }
        return (editor, session)
    }

    @Test(arguments: [false, true]) func productionQuotePinsPendingBridgeCorrectionAndPaidDiscard(generated: Bool) async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan)
        let oldAction = try #require(session.pricedTakeAction())
        let original = editor.project
        let undo = UndoManager(); editor.undoManager = undo
        if generated {
            await plan.start(approved: true)
            #expect(plan.phrases[0].selected?.fits == true, "\(plan.phrases[0].status), \(plan.problem)")
        }
        let sent = ClipTakeHTTP.state.withLock { ($0.texts.count, $0.qa) }
        #expect(editor.excludeChange(1))
        #expect(editor.project == original && editor.undoSteps == 0 && !plan.stillCurrent)
        oldAction.perform(); await session.takesTask?.value
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == sent.0 && $0.qa == sent.1 })
        let accepted = await session.acceptTakes()
        #expect(!accepted)
        #expect(editor.project == original && editor.undoSteps == 0 && !undo.canUndo)
        session.showProposal()
        await session.prepareTakes()
        if generated {
            #expect(session.takePlan === plan && session.hasPaidTakes)
            #expect(session.generation?.problem.contains("Your paid takes are kept") == true)
            editor.sendRewriteAgain(session)
            #expect(session.task.confirm != nil && editor.openRewrite === session)
        } else {
            let fresh = try #require(session.takePlan)
            #expect(fresh !== plan && fresh.approvalID != nil && fresh.approvalID != plan.approvalID)
            #expect(!fresh.phrases[0].text.contains("Corrected"))
            oldAction.perform(); await session.takesTask?.value
            #expect(ClipTakeHTTP.state.withLock { $0.texts.isEmpty && $0.qa == 0 })
            #expect(!fresh.generating && fresh.spent.units == 0)
        }
    }

    @Test func proposalChangeDuringAcceptedRequestRetainsPaidOwnershipUntilDrained() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = try await productionSession(fixture); defer { editor.close() }
        let plan = try #require(session.takePlan), action = try #require(session.pricedTakeAction())
        let original = editor.project, undo = UndoManager(); editor.undoManager = undo
        let barrier = ClipTakeBarrier()
        fixture.beforeProgress = { await barrier.pause() }
        await editor.app.refreshMonthlySpend()
        let generating = Task { await plan.start(approved: true); barrier.finished() }
        await barrier.wait()
        #expect(plan.generating && plan.spent.units == 0 && session.hasPaidTakes)
        let sent = ClipTakeHTTP.state.withLock { ($0.texts.count, $0.qa) }
        #expect(editor.excludeChange(1) && editor.project == original)
        session.showProposal()
        #expect(session.takePlan === plan && plan.isRetired && session.hasPaidTakes)
        action.perform(); await session.takesTask?.value
        let acceptedWhileDraining = await session.acceptTakes()
        #expect(!plan.stillCurrent && !acceptedWhileDraining)
        barrier.resume(); await generating.value; await plan.invalidation?.value
        #expect(!plan.generating && !plan.preparing && session.takePlan === plan && session.hasPaidTakes)
        #expect(ClipTakeHTTP.state.withLock { $0.texts.count == sent.0 && $0.qa == sent.1 })
        let total = try #require(await fixture.ledger.total(provider: "elevenlabs", at: Date()))
        #expect(plan.spent.units > 0 && editor.app.monthlySpend.total == total)
        await session.prepareTakes()
        let acceptedAfterDraining = await session.acceptTakes()
        #expect(session.takePlan === plan && !acceptedAfterDraining)
        #expect(editor.project == original && editor.undoSteps == 0 && !undo.canUndo)
        editor.sendRewriteAgain(session)
        #expect(session.task.confirm != nil && editor.openRewrite === session)
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
        #expect(retry.title.contains("Try another") && session.takeSendLine.contains("only phrase 1"))
        if case .inline(let amount)? = fixture.plan.cost {
            #expect(retry.title == "Try another · " + amount)
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
        session.takePlan = fixture.plan
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
        let feedback = try #require(editor.currentVoiceFeedback)
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
        #expect(fixture.plan.phrases[0].selected?.fits == false)
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
}
#endif
