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
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { pcm16k }
    func embed(_ pcm16k: [Float]) async throws -> [Float] { ClipTakeHTTP.state.withLock { $0.failOwner } ? [0, 1] : [1, 0] }
}
private final class ClipTakeHTTP: URLProtocol, @unchecked Sendable {
    struct State {
        var texts: [String] = []
        var seeds: [UInt32] = []
        var duration = 0.5
        var speechMargin = 0.05
        var synthesisStatus = 200
        var failQA = false
        var failOwner = false
        var gets = 0
        var qa = 0
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
                data = Data(#"{"voices":[{"voice_id":"fixtureOwnVoice","name":"My voice","category":"cloned","is_owner":true}],"has_more":false}"#.utf8)
            case ("POST", "/v1/text-to-speech/fixtureOwnVoice/with-timestamps"):
                let body = try #require(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
                let text = try #require(body["text"] as? String)
                let seed = try #require(body["seed"] as? UInt32)
                let duration = Self.state.withLock { state in state.texts.append(text); state.seeds.append(seed); return state.duration }
                var pcm = Data()
                for index in 0..<Int(duration * 24_000) {
                    var value = Int16((sin(2 * Double.pi * 100 * Double(index) / 24_000) * 3_200).rounded()).littleEndian
                    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
                }
                let characters = Array(text).map(String.init)
                let margin = Self.state.withLock { $0.speechMargin }
                let speechDuration: Double = duration - 2 * margin
                let starts = characters.indices.map { margin + Double($0) * speechDuration / Double(characters.count) }
                let ends = characters.indices.map { margin + Double($0 + 1) * speechDuration / Double(characters.count) }
                data = try JSONSerialization.data(withJSONObject: ["audio_base64": pcm.base64EncodedString(), "alignment": [
                    "characters": characters, "character_start_times_seconds": starts, "character_end_times_seconds": ends]])
            case ("POST", "/v1/speech-to-text"):
                let state = Self.state.withLock { state in state.qa += 1; return state }
                let word = state.failQA ? "wrong" : "Hello"
                data = try JSONSerialization.data(withJSONObject: ["language_code": "eng", "words": [["type": "word", "text": word,
                    "start": 0.1, "end": state.duration - 0.1]]])
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
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { release = $0; arrived = true; arrival?.resume(); arrival = nil }
        } onCancel: { Task { @MainActor in self.resume() } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { arrival = $0 } } }
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
        var preparations = 0
        var approved = 0
        var decoded = 0
        var cap: Decimal?
        var afterPhrase: ((Int) async throws -> Void)?
        var beforePhrase: ((Int) async throws -> Void)?
        var beforeQuote: (() async -> Void)?
        var beforePublish: (() async -> Void)?
        var beforeDispatch: (() -> Void)?
        var current = true
        init(root: URL, plan: ClipTakePlan, ledger: VoiceLabSpendLedger, playback: TakeReviewPlayback, source: Project, envelope: AudioEnvelope) {
            self.root = root; self.plan = plan; self.ledger = ledger; self.playback = playback; self.source = source; self.envelope = envelope
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
    private func fixture(indices: [Int] = [3, 10, 17], badPlacement: Bool = false) async throws -> Fixture {
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
        let client = ElevenLabsVoiceLab(keys: ClipTakeKeys(), session: URLSession(configuration: configuration),
            prices: try VoiceLabPriceCatalog.load(shared: shared), spend: ledger, enforceCapabilities: true)
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
        let made = Fixture(root: root, plan: plan, ledger: ledger, playback: playback, source: project, envelope: envelope); fixture = made
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
            do { return try await real.prepare(inputs, indices, candidates) }
            catch is CancellationError { throw CancellationError() }
            catch { Issue.record("Unexpected quote refusal: \(String(reflecting: error))"); throw error }
        }
        backend.approve = { [weak made] batch, indices in made?.approved += 1; try await real.approve(batch, indices) }
        backend.execute = { [weak made] batch, index, phrase, progress in
            try await made?.beforePhrase?(phrase)
            let result = try await real.execute(batch, index, phrase, progress)
            try await made?.afterPhrase?(phrase)
            return result
        }
        backend.publish = { [weak made] phrase, row, input, date in
            await made?.beforePublish?()
            return try await real.publish(phrase, row, input, date)
        }
        plan.connect(backend)
        return made
    }

    @Test func threePhrasesQuoteOneSetAndWaitForApprovalThenFit() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        #expect(plan.phrases.count == 3)
        await plan.prepare()
        #expect(fixture.preparations == 1 && fixture.decoded == 3)
        #expect(plan.cost != nil && plan.estimate?.units == 9)
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
        let acceptance = try await plan.acceptance()
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
        let output = try await fixture.plan.acceptance()
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
        let output = try await plan.acceptance()
        #expect(output.segments.count == 3)
    }

    @Test func retriesUseFreshSeedsAndKeepThreeSlots() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        await plan.prepare(); await plan.start(approved: true)
        let original = try #require(plan.phrases[0].selectedID)
        for _ in 0..<3 {
            await plan.prepareAnother(phrase: 0)
            await plan.tryAnother(phrase: 0, approved: true)
        }
        #expect(ClipTakeHTTP.state.withLock { $0.seeds == [7, 10, 11, 12] })
        #expect(plan.phrases[0].takes.count == 3)
        #expect(plan.phrases[0].takes.map(\.number).sorted() == [1, 2, 3])
        #expect(plan.phrases[0].takes.contains { $0.id == original })
        let selected = try #require(plan.phrases[0].selectedID)
        let scratch = await plan.scratch(take: selected, phrase: 0)
        #expect(scratch?.isValid == true)
        let output = try await plan.acceptance()
        #expect(output.segments.count == 1)
    }

    @Test func changedLengthIsVisibleButCannotBeAccepted() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = fixture.plan
        ClipTakeHTTP.state.withLock { $0.duration += 2.5; $0.speechMargin = 0.15 }
        await plan.prepare(); await plan.start(approved: true)
        let phrase = plan.phrases[0]
        #expect(phrase.takes.count == 3)
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
        let output = try await plan.acceptance()
        #expect(output.segments.count == 1)
    }

    @Test func singlePhraseUsesTheSamePlanAndCapsBeforeAnyRequest() async throws {
        let fixture = try await fixture(indices: [10]); defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.plan.prepare()
        #expect(fixture.plan.estimate?.units == 3)
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
        #expect(fixture.plan.phrases[0].selected == nil && fixture.plan.phrases[0].takes.count == 3)
        #expect(fixture.plan.phrases[0].status == .failed("These takes didn't sound right. Edit the words or try again."))
        await #expect(throws: ClipTakePlan.Failure.noSelection) { try await fixture.plan.acceptance() }
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
        fixture.beforePublish = { [weak fixture] in fixture?.current = false }
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
        #expect(retry.title.contains("Try Another") && session.takeSendLine.contains("only phrase 1"))
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
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        await fixture.plan.play(phrase: 0)
        #expect(fixture.plan.audition.isPlaying)
        session.showProposal()
        #expect(session.task.footer.primary?.id == "useTakes")
        undo.beginUndoGrouping()
        #expect(session.task.pressReturn(command: true))
        await session.takesTask?.value
        undo.endUndoGrouping()
        #expect(editor.openRewrite == nil && editor.project.voiceLab.segments.count == 3)
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
        #expect(!editor.containsAISpeech(clipID: nil) && !editor.voiceRewriteToastVisible)
        undo.redo()
        #expect(editor.project.voiceLab.segments.count == 3 && editor.currentVoiceFeedback == nil)
    }

    @Test func stalePublicationNeverShowsSuccessOrRegistersUndo() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (editor, session) = session(fixture); defer { editor.close() }
        installReview(session, fixture: fixture, withFreeChanges: false)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        await fixture.plan.prepare(); await fixture.plan.start(approved: true)
        let barrier = ClipTakeBarrier()
        fixture.beforePublish = { await barrier.pause() }
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
}
#endif
