#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia
@testable import VoxClip

/// A scripted speaker model that hears pitch: speech at `f` Hz is the unit vector at `f − 100` degrees, read from the
/// zero crossings of its voiced samples. The old voice is 100 Hz ([1, 0]); τ is 0.45.
private struct PitchEmbedder: SpeakerEmbedder {
    let modelID = "fixture-calibrated"
    let dimension = 2
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { pcm16k }
    func embed(_ pcm16k: [Float]) async throws -> [Float] {
        let voiced = pcm16k.filter { abs($0) > 0.01 }
        var crossings = 0
        for index in voiced.indices.dropFirst() where (voiced[index - 1] < 0) != (voiced[index] < 0) { crossings += 1 }
        let hertz = Double(crossings) / 2 / (Double(max(1, voiced.count)) / 16_000)
        let radians = (hertz - 100) * .pi / 180
        return [Float(cos(radians)), Float(sin(radians))]
    }
}

/// ElevenLabs as the rebuild reaches it: the plan check, the creation, the account listing and the old voice's deletion.
private final class RebuildHTTP: URLProtocol, @unchecked Sendable {
    static let calls = Mutex<[String]>([])
    static let uploads = Mutex<[Data]>([])
    static let voices = Mutex<[String]>(["fixtureOwnVoice"])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let method = request.httpMethod ?? "GET"
        Self.calls.withLock { $0.append("\(method) \(url.path)") }
        var status = 200
        let data: Data
        switch (method, url.path) {
        case ("GET", "/v1/user/subscription"):
            data = Data(#"{"tier":"starter","status":"active","character_count":0,"character_limit":1000,"can_use_instant_voice_cloning":true,"voice_slots_used":1,"voice_limit":3}"#.utf8)
        case ("POST", "/v1/voices/add"):
            Self.uploads.withLock { $0.append(Self.body(request)) }
            Self.voices.withLock { $0.append("rebuiltVoice") }
            data = Data(#"{"voice_id":"rebuiltVoice","requires_verification":false}"#.utf8)
        case ("GET", "/v2/voices"):
            let listed = Self.voices.withLock { $0 }.map { #"{"voice_id":"\#($0)","name":"Example (VoxClip)","category":"cloned","is_owner":true}"# }
            data = Data("{\"voices\":[\(listed.joined(separator: ","))],\"has_more\":false}".utf8)
        case ("DELETE", let path) where path.hasPrefix("/v1/voices/"):
            let id = String(path.dropFirst("/v1/voices/".count))
            Self.voices.withLock { $0.removeAll { $0 == id } }
            data = Data(#"{"status":"ok"}"#.utf8)
        default:
            status = 500; data = Data()
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
        while true { let count = stream.read(&buffer, maxLength: buffer.count); guard count > 0 else { break }; result.append(contentsOf: buffer.prefix(count)) }
        return result
    }
}

private struct RebuildKeys: KeyProvider {
    static let key = "synthetic-rebuild-key"
    func key(for provider: String) async throws -> String? { Self.key }
}

@Suite("Rebuild from my videos (Settings › Voices)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows or provider requests are opened."), .offlineFixtures)
@MainActor struct VoiceRebuildFlowTests {
    /// 16 kHz PCM16 mono: `hertz` sine (0.3) during each of the fixture's nine words, silence between them.
    private static func tone(seconds: Double, hertz: Double, words: [(Double, Double)]? = nil) -> Data {
        let frames = Int(seconds * 16_000)
        var pcm = Data(capacity: frames * 2)
        for index in 0..<frames {
            let time: Double = Double(index) / 16_000
            let speaking: Bool = words.map { $0.contains { time >= $0.0 && time < $0.1 } } ?? true
            let phase: Double = 2 * Double.pi * hertz * time
            let value: Double = speaking ? 0.3 * sin(phase) : 0
            withUnsafeBytes(of: Int16((value * 32_767).rounded()).littleEndian) { pcm.append(contentsOf: $0) }
        }
        func little(_ value: Int, _ width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        var data = Data("RIFF".utf8)
        data.append(little(36 + pcm.count, 4)); data.append(Data("WAVEfmt ".utf8))
        data.append(little(16, 4)); data.append(little(1, 2)); data.append(little(1, 2))
        data.append(little(16_000, 4)); data.append(little(32_000, 4)); data.append(little(2, 2)); data.append(little(16, 2))
        data.append(Data("data".utf8)); data.append(little(pcm.count, 4)); data.append(pcm)
        return data
    }

    /// A transcribed 20 s video whose nine words are spoken at `hertz`.
    private static func video(_ root: URL, hertz: Double, name: String) throws -> URL {
        let words: [(Double, Double)] = (0..<9).map { index in
            let start: Double = 0.5 + Double(index) * 2
            return (start, start + 1.5)
        }
        let media = root.appendingPathComponent("\(name).wav")
        try tone(seconds: 20, hertz: hertz, words: words).write(to: media)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: SharedResources.locate().root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip"))) as? [String: Any])
        var mediaJSON = try #require(json["media"] as? [String: Any]); var source = try #require(mediaJSON["source"] as? [String: Any])
        source["absolutePath"] = media.path; source["relativePath"] = media.lastPathComponent
        source["sizeBytes"] = try #require(try media.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        source["contentKey"] = try JSONProjectStore.contentKey(for: media)
        source["durationSeconds"] = 20; source["audio"] = ["sampleRate": 16_000, "channels": 1]
        mediaJSON["source"] = source; json["media"] = mediaJSON
        var transcript = try #require(json["transcript"] as? [String: Any])
        var timed = try #require(transcript["words"] as? [[String: Any]])
        for index in timed.indices {
            timed[index]["start"] = words[index].0; timed[index]["end"] = words[index].1
            timed[index]["rawStart"] = words[index].0; timed[index]["rawEnd"] = words[index].1
        }
        transcript["words"] = timed; transcript["durationSeconds"] = 20; json["transcript"] = transcript
        var voiceLab = try #require(json["voiceLab"] as? [String: Any])
        voiceLab["assets"] = [Any](); voiceLab["segments"] = [Any](); voiceLab["voices"] = [Any](); json["voiceLab"] = voiceLab
        let url = root.appendingPathComponent("\(name).voxclip")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    /// The user's attested voice: its reference sample is 6 s at 100 Hz, its embedding [1, 0], one learned reference.
    private static func oldVoice(_ store: VoiceConsentStore) async throws -> (record: VoiceConsentRecord, reference: Data) {
        let reference = tone(seconds: 6, hertz: 100)
        let hash = VoiceLabFingerprint.bytes(reference)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: SharedResources.locate().root.appendingPathComponent("fixtures/voice-lab/consent-record-project.json"))) as? [String: Any])
        json["recordId"] = "6f0c2c1e-8a0e-4c5e-9d1f-0b9d4a7f2e11"
        json["samples"] = [["sha256": hash, "seconds": 6, "source": "project", "speakerScore": 1],
                           ["sha256": String(repeating: "1", count: 64), "seconds": 24, "source": "project", "speakerScore": 1]]
        var consent = try #require(json["projectConsent"] as? [String: Any]); consent["audioSha256"] = hash; json["projectConsent"] = consent
        // As the attested route made it: the record's embedding is its reference sample's own.
        let embedding = try await VoiceSpeakerCheck(embedder: PitchEmbedder(), calibratedThreshold: 0.45).embedding(VoiceConsentAudio.pcm16k(reference))
        var speaker = try #require(json["speaker"] as? [String: Any])
        speaker["threshold"] = 0.45; speaker["embedding"] = VoiceConsentRecord.encodeEmbedding(embedding); json["speaker"] = speaker
        json["creator"] = ["region": "default", "keyFingerprint": String(VoiceLabFingerprint.bytes(Data(RebuildKeys.key.utf8)).prefix(16))]
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveReferenceAudio(reference, recordID: record.id); try await store.save(record)
        let radians = 25 * Double.pi / 180
        try await store.learnReference(recordID: record.id, embedding: [Float(cos(radians)), Float(sin(radians))], contentKey: "car-video", model: "fixture-calibrated")
        return (try await store.load(record.id), reference)
    }

    private static func occurrences(of needle: Data, in haystack: Data) -> Int {
        var count = 0, start = haystack.startIndex
        while let found = haystack.range(of: needle, in: start..<haystack.endIndex) { count += 1; start = found.upperBound }
        return count
    }

    private func client() throws -> ElevenLabsVoiceLab {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RebuildHTTP.self]
        let prices = try VoiceLabPriceCatalog.load(shared: SharedResources.locate())
        return ElevenLabsVoiceLab(keys: RebuildKeys(), session: URLSession(configuration: configuration), prices: prices, enforceCapabilities: true)
    }

    @Test func rebuildsFromVerifiedSpeechThenSwitchesAndRemovesTheOldVoiceInline() async throws {
        RebuildHTTP.calls.withLock { $0 = [] }; RebuildHTTP.uploads.withLock { $0 = [] }; RebuildHTTP.voices.withLock { $0 = ["fixtureOwnVoice"] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebuild-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.appendingPathComponent("data").path])
        let app = AppModel(locations: locations)
        app.settings.values["voiceLab.enabled"] = .bool(true)
        let store = VoiceConsentStore(locations: locations)
        let (old, reference) = try await Self.oldVoice(store)
        let client = try client()
        let session = VoiceLabSession(app: app, store: store, reconciler: VoiceOperationReconciler(store: store, client: client))
        session.stageEnrollmentForTests(client: client, speaker: VoiceSpeakerCheck(embedder: PitchEmbedder(), calibratedThreshold: 0.45, language: "en"))
        await session.load(recover: false)
        // The user's own videos: one in the statement's room, one on another mic, and one a guest speaks.
        let videos = try [Self.video(root, hertz: 100, name: "kitchen"), Self.video(root, hertz: 130, name: "car"), Self.video(root, hertz: 220, name: "guest")]

        // 1. Find: free, local, nothing sent.
        session.findRebuild(recordID: old.id, projects: videos)
        let state = try #require(session.rebuilds[old.id])
        await state.task?.value
        #expect(state.phase == .found)
        let found = try #require(state.found)
        #expect(found.plan.keptMs == 6_000, "the consent clip goes first, so the statement stays the same")
        // Each video's transcript gives two clean stretches (a low-confidence word splits it); the guest's both fail.
        #expect(found.plan.videoCount == 2 && found.plan.rejected == [.notTheOwner: 2], "the guest's video fails one hop")
        #expect(Set(found.plan.pieces.prefix(2).map(\.video)).count == 2, "each video once before any repeats")
        #expect(state.summary == "36 s from 2 videos and your consent clip")
        #expect(found.samples.count == 5 && found.samples[0].wav == reference)
        #expect(state.line == "Tick the three boxes to rebuild. Only this speech is sent to ElevenLabs; no video.")
        #expect(RebuildHTTP.calls.withLock { $0 }.isEmpty, "finding is free and sends nothing")

        // 2. Consent inline, then the local quote: Rebuild · $0 from the catalogue's createClone row.
        state.ownVoice = true; state.adult = true
        #expect(state.phase == .found && state.plan == nil)
        state.ownVideosOnly = true
        await state.task?.value
        #expect(state.phase == .ready)
        #expect(session.rebuildTitle(state) == "Rebuild · $0")
        #expect(state.plan?.consentMethod == .projectAttestation && state.plan?.trainingSeconds == 36)
        #expect(RebuildHTTP.calls.withLock { $0 }.isEmpty, "the quote is local")

        // 3. The one click: plan check, then the creation, through the attested route's journal and creator binding.
        await session.approveRebuild(state)
        guard case .created(let newID) = state.phase else { Issue.record("not created: \(state.line)"); return }
        let calls = RebuildHTTP.calls.withLock { $0 }
        #expect(calls.filter { $0 == "POST /v1/voices/add" }.count == 1)
        #expect(calls.firstIndex(of: "GET /v1/user/subscription").map { $0 < calls.firstIndex(of: "POST /v1/voices/add")! } == true)
        let upload = try #require(RebuildHTTP.uploads.withLock { $0 }.first)
        #expect(Self.occurrences(of: Data("filename=\"".utf8), in: upload) == 5, "the consent clip and four verified pieces, nothing else")
        #expect(upload.range(of: reference) != nil)
        let new = try await store.load(newID)
        #expect(new.status == .active && new.voiceId == "rebuiltVoice" && new.schema == "voxclip-consent/2")
        #expect(new.projectConsent?.audioSha256 == old.projectConsent?.audioSha256, "the consent clip is the same")
        #expect(new.speaker.embedding == old.speaker.embedding && new.attestations.complete)
        #expect(new.creator?.keyFingerprint == old.creator?.keyFingerprint && new.samples.count == 5)
        #expect(try await store.operations().allSatisfy(\.finished), "the creation journal is settled")
        #expect(new.speaker.references?.map(\.contentKey) == ["car-video"], "the learned reference passes the new voice's own embedding")
        #expect(state.line.hasPrefix("Your rebuilt voice is ready. It keeps what VoxClip learned from 1 of your videos. Next: use it for Rewrite"))
        #expect(session.records.first { $0.id == old.id }?.status == .active, "the old voice stays until it is removed")

        // 4. Use the new voice for Rewrite.
        #expect(app.string(VoiceLabSession.rewriteVoiceKey).isEmpty)
        session.useRebuiltVoice(state)
        #expect(app.string(VoiceLabSession.rewriteVoiceKey) == newID && state.usedForRewrite)
        #expect(state.line == "Rewrite uses your rebuilt voice. Next: remove the old voice.")

        // 5. Remove the old voice: only after its inline confirmation, through the existing deletion.
        await session.removeOldVoice(state)
        #expect(!RebuildHTTP.calls.withLock { $0 }.contains { $0.hasPrefix("DELETE") }, "no deletion without the confirmation row")
        state.confirmingRemoval = true
        await session.removeOldVoice(state)
        #expect(RebuildHTTP.calls.withLock { $0 }.contains("DELETE /v1/voices/fixtureOwnVoice"))
        let removed = try await store.load(old.id)
        #expect(removed.status == .deleted && removed.speaker.references == nil)
        #expect(try await store.load(newID).status == .active && state.removed)
        #expect(session.confirmation == nil, "inline: no sheet")
        #expect(state.line == "Removed the old voice. Rewrite uses your rebuilt voice. Existing takes stay playable and labelled.")
    }

    @Test func tooLittleVerifiedSpeechNamesTheNextStep() async throws {
        RebuildHTTP.calls.withLock { $0 = [] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebuild-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.appendingPathComponent("data").path])
        let app = AppModel(locations: locations)
        app.settings.values["voiceLab.enabled"] = .bool(true)
        let store = VoiceConsentStore(locations: locations)
        let (old, _) = try await Self.oldVoice(store)
        let session = VoiceLabSession(app: app, store: store)
        session.stageEnrollmentForTests(client: try client(), speaker: VoiceSpeakerCheck(embedder: PitchEmbedder(), calibratedThreshold: 0.45, language: "en"))
        await session.load(recover: false)
        session.findRebuild(recordID: old.id, projects: [try Self.video(root, hertz: 220, name: "guest")])
        await session.rebuilds[old.id]?.task?.value
        let state = try #require(session.rebuilds[old.id])
        #expect(state.phase == .failed && state.found == nil)
        #expect(state.line == "Only 6 s of speech that's clearly yours in 1 video. A rebuild needs 30 s. Transcribe more of your videos, then try again.")
        session.findRebuild(recordID: old.id, projects: [])
        #expect(state.line == "Open or export a video first. VoxClip rebuilds your voice from your projects on this Mac.")
        #expect(RebuildHTTP.calls.withLock { $0 }.isEmpty)
    }
}
#endif
