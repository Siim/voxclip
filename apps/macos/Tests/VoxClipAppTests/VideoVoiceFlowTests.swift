#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia
@testable import VoxClip

/// The scripted speaker model of the rebuild tests: speech at `f` Hz is the unit vector at `f − 100` degrees, read from
/// the zero crossings of its voiced samples. The anchor is 100 Hz ([1, 0]); τ is 0.45.
private struct VideoPitchEmbedder: SpeakerEmbedder {
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

/// ElevenLabs as a per-video voice reaches it: the plan check, each creation (a new voice id each time), the account
/// listing and the deletions, which can be made to fail.
private final class VideoVoiceHTTP: URLProtocol, @unchecked Sendable {
    static let calls = Mutex<[String]>([])
    static let uploads = Mutex<[Data]>([])
    static let voices = Mutex<[String]>(["fixtureOwnVoice"])
    static let failDeletes = Mutex(false)
    static func reset() {
        calls.withLock { $0 = [] }; uploads.withLock { $0 = [] }; voices.withLock { $0 = ["fixtureOwnVoice"] }; failDeletes.withLock { $0 = false }
    }
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
            data = Data(#"{"tier":"starter","status":"active","character_count":0,"character_limit":1000,"can_use_instant_voice_cloning":true,"voice_slots_used":1,"voice_limit":5}"#.utf8)
        case ("POST", "/v1/voices/add"):
            let id = Self.uploads.withLock { uploads in uploads.append(Self.body(request)); return "videoVoice\(uploads.count)" }
            Self.voices.withLock { $0.append(id) }
            data = Data("{\"voice_id\":\"\(id)\",\"requires_verification\":false}".utf8)
        case ("GET", "/v2/voices"):
            let listed = Self.voices.withLock { $0 }.map { #"{"voice_id":"\#($0)","name":"Example (VoxClip)","category":"cloned","is_owner":true}"# }
            data = Data("{\"voices\":[\(listed.joined(separator: ","))],\"has_more\":false}".utf8)
        case ("DELETE", let path) where path.hasPrefix("/v1/voices/"):
            if Self.failDeletes.withLock({ $0 }) { status = 503; data = Data(#"{"detail":"busy"}"#.utf8); break }
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

private struct VideoVoiceKeys: KeyProvider {
    static let key = "synthetic-per-video-key"
    func key(for provider: String) async throws -> String? { Self.key }
}

@Suite("A matching voice for each video (Rewrite and Settings › Voices)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows or provider requests are opened."), .offlineFixtures)
@MainActor struct VideoVoiceFlowTests {
    /// 16 kHz PCM16 mono: a `hertz` sine (0.3) during each word; between words silence, or a 30 Hz hum (0.1) like a
    /// car's, which puts the video's speech at about 9.5 dB SNR: under the 20 dB floor, over the per-video one.
    private static func tone(seconds: Double, hertz: Double, words: [(Double, Double)]? = nil, hum: Bool = false) -> Data {
        let frames = Int(seconds * 16_000)
        var pcm = Data(capacity: frames * 2)
        for index in 0..<frames {
            let time: Double = Double(index) / 16_000
            let speaking: Bool = words.map { $0.contains { time >= $0.0 && time < $0.1 } } ?? true
            let phase: Double = 2 * Double.pi * hertz * time
            let humPhase: Double = 2 * Double.pi * 30 * time
            let background: Double = hum ? 0.1 * sin(humPhase) : 0
            let value: Double = speaking ? 0.3 * sin(phase) : background
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

    /// A transcribed video of `seconds` whose words (1.5 s each, every 2 s) are spoken at `hertz`.
    static func video(_ root: URL, seconds: Int, hertz: Double, name: String, hum: Bool = false) throws -> (url: URL, project: Project, media: URL) {
        let count = seconds / 2
        let words: [(Double, Double)] = (0..<count).map { index in
            let start: Double = 0.5 + Double(index) * 2
            return (start, start + 1.5)
        }
        let media = root.appendingPathComponent("\(name).wav")
        try tone(seconds: Double(seconds), hertz: hertz, words: words, hum: hum).write(to: media)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: SharedResources.locate().root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip"))) as? [String: Any])
        json["id"] = UUID().uuidString.lowercased()
        var mediaJSON = try #require(json["media"] as? [String: Any]); var source = try #require(mediaJSON["source"] as? [String: Any])
        source["absolutePath"] = media.path; source["relativePath"] = media.lastPathComponent
        source["sizeBytes"] = try #require(try media.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        source["contentKey"] = try JSONProjectStore.contentKey(for: media)
        source["durationSeconds"] = seconds; source["audio"] = ["sampleRate": 16_000, "channels": 1]
        mediaJSON["source"] = source; json["media"] = mediaJSON
        var transcript = try #require(json["transcript"] as? [String: Any])
        let template = try #require((transcript["words"] as? [[String: Any]])?.first)
        transcript["words"] = words.enumerated().map { index, word -> [String: Any] in
            var item = template
            item["id"] = "w\(index + 1)"; item["text"] = "word\(index + 1)"; item["conf"] = 0.99
            item["start"] = word.0; item["end"] = word.1; item["rawStart"] = word.0; item["rawEnd"] = word.1
            return item
        }
        transcript["durationSeconds"] = seconds; json["transcript"] = transcript
        var voiceLab = try #require(json["voiceLab"] as? [String: Any])
        voiceLab["assets"] = [Any](); voiceLab["segments"] = [Any](); voiceLab["voices"] = [Any](); json["voiceLab"] = voiceLab
        let url = root.appendingPathComponent("\(name).voxclip")
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
        return (url, try JSONProjectStore.decode(data), media)
    }

    /// The anchor: an attested voice whose reference sample is 6 s at 100 Hz, its embedding [1, 0].
    private static func anchor(_ store: VoiceConsentStore) async throws -> (record: VoiceConsentRecord, reference: Data) {
        let reference = tone(seconds: 6, hertz: 100)
        let hash = VoiceLabFingerprint.bytes(reference)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: SharedResources.locate().root.appendingPathComponent("fixtures/voice-lab/consent-record-project.json"))) as? [String: Any])
        json["recordId"] = "6f0c2c1e-8a0e-4c5e-9d1f-0b9d4a7f2e11"; json["voiceName"] = "siim (VoxClip)"
        json["samples"] = [["sha256": hash, "seconds": 6, "source": "project", "speakerScore": 1],
                           ["sha256": String(repeating: "1", count: 64), "seconds": 24, "source": "project", "speakerScore": 1]]
        var consent = try #require(json["projectConsent"] as? [String: Any]); consent["audioSha256"] = hash; json["projectConsent"] = consent
        let embedding = try await VoiceSpeakerCheck(embedder: VideoPitchEmbedder(), calibratedThreshold: 0.45).embedding(VoiceConsentAudio.pcm16k(reference))
        var speaker = try #require(json["speaker"] as? [String: Any])
        speaker["threshold"] = 0.45; speaker["embedding"] = VoiceConsentRecord.encodeEmbedding(embedding); json["speaker"] = speaker
        json["creator"] = ["region": "default", "keyFingerprint": String(VoiceLabFingerprint.bytes(Data(VideoVoiceKeys.key.utf8)).prefix(16))]
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveReferenceAudio(reference, recordID: record.id); try await store.save(record)
        return (try await store.load(record.id), reference)
    }

    private struct Harness {
        let root: URL
        let app: AppModel
        let store: VoiceConsentStore
        let session: VoiceLabSession
        let anchor: VoiceConsentRecord
        let reference: Data
    }

    private func harness() async throws -> Harness {
        VideoVoiceHTTP.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("per-video-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.appendingPathComponent("data").path])
        let app = AppModel(locations: locations)
        app.settings.values["voiceLab.enabled"] = .bool(true)
        let store = VoiceConsentStore(locations: locations)
        let (anchor, reference) = try await Self.anchor(store)
        let session = try makeSession(app: app, store: store)
        await session.load(recover: false)
        session.pendingTakeVoices = { [] }
        return Harness(root: root, app: app, store: store, session: session, anchor: anchor, reference: reference)
    }

    private func makeSession(app: AppModel, store: VoiceConsentStore) throws -> VoiceLabSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoVoiceHTTP.self]
        let prices = try VoiceLabPriceCatalog.load(shared: SharedResources.locate())
        let client = ElevenLabsVoiceLab(keys: VideoVoiceKeys(), session: URLSession(configuration: configuration), prices: prices, enforceCapabilities: true)
        let session = VoiceLabSession(app: app, store: store, reconciler: VoiceOperationReconciler(store: store, client: client))
        session.stageEnrollmentForTests(client: client, speaker: VoiceSpeakerCheck(embedder: VideoPitchEmbedder(), calibratedThreshold: 0.45, language: "en"))
        return session
    }

    private static func occurrences(of needle: Data, in haystack: Data) -> Int {
        var count = 0, start = haystack.startIndex
        while let found = haystack.range(of: needle, in: start..<haystack.endIndex) { count += 1; start = found.upperBound }
        return count
    }
    private static func noiseRemoval(_ upload: Data) -> String? {
        let marker = Data("name=\"remove_background_noise\"\r\n\r\n".utf8)
        guard let range = upload.range(of: marker) else { return nil }
        return String(decoding: upload[range.upperBound...].prefix(5), as: UTF8.self).components(separatedBy: "\r").first
    }

    @Test func theAnswerIsAskedUntilChosenRememberedAndShownInSettings() async throws {
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let car = try Self.video(h.root, seconds: 40, hertz: 110, name: "car", hum: true)
        #expect(h.session.videoVoiceMode == .ask)
        #expect(h.session.offersVideoVoice(car.project) && h.session.anchorVoice(language: "en")?.id == h.anchor.id)
        #expect(h.session.videoVoicePrice == "free", "the catalogue's createClone price")
        // Unset: nothing is made without the answer, and takes start with the anchor.
        let waiting = h.session.makeVideoVoice(project: car.project, media: car.media)
        #expect(waiting.phase == .idle && waiting.task == nil && VideoVoiceHTTP.calls.withLock { $0 }.isEmpty)
        #expect(h.session.rewriteVoicePreference(contentKey: car.project.media.source.contentKey, language: "en") == h.anchor.id)
        // "Use siim" is remembered; Settings › Voices shows it and can change it back to asking.
        h.session.setVideoVoiceMode(.anchor)
        #expect(h.app.settings.values[VoicePerVideo.settingKey] == .bool(false) && h.session.videoVoiceMode == .anchor)
        #expect(VideoVoiceRows.modeLine(.anchor, anchor: "siim") == "Every video uses siim.")
        #expect(h.session.makeVideoVoice(project: car.project, media: car.media).task == nil, "the stored answer is honoured")
        h.session.setVideoVoiceMode(.ask)
        #expect(h.app.settings.values[VoicePerVideo.settingKey] == .null && h.session.videoVoiceMode == .ask)
        h.session.setVideoVoiceMode(.match)
        #expect(h.app.settings.values[VoicePerVideo.settingKey] == .bool(true) && h.session.videoVoiceMode == .match)
        #expect(VoiceLabSession.videoVoiceQuestion == "Make a matching voice from this video? Your takes will sound like this recording. The previous video's voice is removed.")
    }

    @Test func eachVideoGetsItsOwnVoiceAndThePreviousOneIsRemovedThroughTheDeletion() async throws {
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let car = try Self.video(h.root, seconds: 40, hertz: 110, name: "car", hum: true)
        let kitchen = try Self.video(h.root, seconds: 40, hertz: 120, name: "kitchen")
        let carKey = car.project.media.source.contentKey, kitchenKey = kitchen.project.media.source.contentKey
        h.app.rateCalibrations(seed: h.anchor.id)
        h.session.setVideoVoiceMode(.match)

        // Video 1: its own verified speech, the anchor's consent clip first, noise removal on (the hum is ~9.5 dB).
        let first = h.session.makeVideoVoice(project: car.project, media: car.media)
        #expect(first.phase == .making)
        await first.task?.value
        guard case .ready(let carVoice) = first.phase else { Issue.record("not made: \(first.line)"); return }
        let upload = try #require(VideoVoiceHTTP.uploads.withLock { $0 }.first)
        #expect(upload.range(of: h.reference) != nil && Self.occurrences(of: Data("filename=\"".utf8), in: upload) == 3,
                "the anchor's consent clip and the video's two verified pieces")
        #expect(Self.noiseRemoval(upload) == "true")
        #expect(upload.range(of: Data("siim · car (VoxClip)".utf8)) != nil)
        let made = try await h.store.load(carVoice)
        #expect(made.status == .active && made.schema == "voxclip-consent/2" && made.speaker.embedding == h.anchor.speaker.embedding,
                "one hop: the new record's embedding is the anchor's own")
        #expect(made.projectConsent?.audioSha256 == h.anchor.projectConsent?.audioSha256 && made.attestations == h.anchor.attestations)
        #expect(made.creator?.keyFingerprint == h.anchor.creator?.keyFingerprint)
        #expect(try await h.store.operations().allSatisfy(\.finished), "the creation journal is settled")
        #expect(h.session.perVideoBook.video(carKey)?.recordId == carVoice && h.session.perVideoBook.video(carKey)?.anchorId == h.anchor.id)
        #expect(h.session.perVideoBook.video(carKey)?.anchorReferenceSha256 == h.anchor.referenceAudioSHA256)
        let saved = await VoicePerVideoStore(locations: h.app.locations).load()
        #expect(saved == h.session.perVideoBook, "kept in app data, not in the project file")
        #expect(!(try String(contentsOf: car.url, encoding: .utf8)).contains(carVoice))
        // Every take in that video uses it; another video starts with the anchor.
        #expect(h.session.rewriteVoicePreference(contentKey: carKey, language: "en") == carVoice)
        #expect(h.session.rewriteVoicePreference(contentKey: kitchenKey, language: "en") == h.anchor.id)
        #expect(h.session.anchorVoice(language: "en")?.id == h.anchor.id, "a video's voice is never the anchor")
        #expect(h.app.rateCalibration(recordID: carVoice)?.models == h.app.rateCalibration(recordID: h.anchor.id)?.models, "seeded from the anchor")
        // A second ask for the same video keeps its voice: nothing is made again.
        #expect(h.session.makeVideoVoice(project: car.project, media: car.media).task == nil)
        #expect(VideoVoiceHTTP.calls.withLock { $0 }.filter { $0 == "POST /v1/voices/add" }.count == 1)

        // Video 2: its voice is made, then video 1's is deleted through the existing flow; the anchor stays.
        let second = h.session.makeVideoVoice(project: kitchen.project, media: kitchen.media)
        await second.task?.value
        guard case .ready(let kitchenVoice) = second.phase else { Issue.record("not made: \(second.line)"); return }
        #expect(Self.noiseRemoval(try #require(VideoVoiceHTTP.uploads.withLock { $0 }.last)) == "false", "clean speech: no noise removal")
        let calls = VideoVoiceHTTP.calls.withLock { $0 }
        #expect(calls.contains("DELETE /v1/voices/videoVoice1") && !calls.contains("DELETE /v1/voices/fixtureOwnVoice"))
        let removed = try await h.store.load(carVoice)
        #expect(removed.status == .deleted && removed.deletedAt != nil, "tombstoned, its hashes kept")
        #expect(try await h.store.load(h.anchor.id).status == .active)
        #expect(h.session.perVideoBook.videos.map(\.recordId) == [kitchenVoice] && h.session.perVideoBook.removals.isEmpty)
        #expect(h.session.perVideoNote == nil)
        #expect(h.session.rewriteVoicePreference(contentKey: carKey, language: "en") == h.anchor.id, "video 1 falls back to the anchor")
        #expect(h.session.rewriteVoicePreference(contentKey: kitchenKey, language: "en") == kitchenVoice)
        #expect(h.session.confirmation == nil, "inline: no sheet")
    }

    @Test func neverRemovesAVoiceWithPendingTakesAndAFailedRemovalRetriesWithANote() async throws {
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let car = try Self.video(h.root, seconds: 40, hertz: 110, name: "car")
        let kitchen = try Self.video(h.root, seconds: 40, hertz: 120, name: "kitchen")
        h.session.setVideoVoiceMode(.match)
        let first = h.session.makeVideoVoice(project: car.project, media: car.media)
        await first.task?.value
        guard case .ready(let carVoice) = first.phase else { Issue.record("not made: \(first.line)"); return }
        // Video 1's Rewrite still holds paid takes nobody used: its voice stays until they are.
        h.session.pendingTakeVoices = { [carVoice] }
        await h.session.makeVideoVoice(project: kitchen.project, media: kitchen.media).task?.value
        #expect(!VideoVoiceHTTP.calls.withLock { $0 }.contains { $0.hasPrefix("DELETE") })
        #expect(try await h.store.load(carVoice).status == .active)
        #expect(h.session.perVideoBook.removals.map(\.recordId) == [carVoice] && h.session.perVideoBook.removals[0].lastError == nil)
        #expect(h.session.perVideoNote == "The voice for car is removed once its unused takes are used or discarded.")
        // The takes are used: the next pass removes it, but ElevenLabs fails, so it stays owed with a note.
        h.session.pendingTakeVoices = { [] }
        VideoVoiceHTTP.failDeletes.withLock { $0 = true }
        await h.session.removePreviousVideoVoices(now: Date(timeIntervalSince1970: 1_800_000_000))
        let owed = try #require(h.session.perVideoBook.removals.first)
        #expect(owed.recordId == carVoice && owed.attempts == 1 && owed.lastError != nil)
        #expect(owed.nextAttemptAt == "2027-01-15T08:00:30Z", "the first retry after 30 s, then backing off")
        #expect(h.session.perVideoNote == "Couldn't remove the voice for car yet. VoxClip retries in the background.")
        #expect(try await h.store.load(h.anchor.id).status == .active, "never the anchor")
        // The retry (Settings' Retry now, or the background one) finishes it.
        VideoVoiceHTTP.failDeletes.withLock { $0 = false }
        await h.session.removePreviousVideoVoices()
        #expect(try await h.store.load(carVoice).status == .deleted && h.session.perVideoBook.removals.isEmpty && h.session.perVideoNote == nil)
        h.session.removalRetry?.cancel()
    }

    @Test func tooLittleOfTheVideosOwnSpeechKeepsTheAnchorAndSaysSoOnce() async throws {
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        // 29 s of its own speech: with the anchor's 6 s clip the set would reach the 30 s a voice needs, but the video's own
        // speech must reach it alone.
        let short = try Self.video(h.root, seconds: 30, hertz: 110, name: "short")
        let key = short.project.media.source.contentKey
        h.session.setVideoVoiceMode(.match)
        let state = h.session.makeVideoVoice(project: short.project, media: short.media)
        await state.task?.value
        #expect(state.phase == .anchor)
        #expect(state.line == "This video has only 29 s of your own clear speech, so takes use siim. A matching voice needs 30 s.")
        #expect(VideoVoiceHTTP.calls.withLock { $0 }.isEmpty, "nothing is sent")
        #expect(h.session.perVideoBook.shortNoted == [key])
        #expect(h.session.rewriteVoicePreference(contentKey: key, language: "en") == h.anchor.id)
        // A later run of the app: the anchor again, and no note.
        let later = try makeSession(app: h.app, store: h.store)
        await later.load(recover: false)
        let again = later.makeVideoVoice(project: short.project, media: short.media)
        #expect(again.phase == .anchor && again.line.isEmpty && again.task == nil)
    }

    @Test func aTakesMatchIsRecordedForTheVideoAndTheAnchor() async throws {
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let car = try Self.video(h.root, seconds: 40, hertz: 110, name: "car")
        let key = car.project.media.source.contentKey
        h.session.setVideoVoiceMode(.match)
        await h.session.makeVideoVoice(project: car.project, media: car.media).task?.value
        let voice = try #require(h.session.perVideoBook.video(key)?.recordId)
        await h.session.recordTakeMatch(contentKey: key, title: "car", recordID: h.anchor.id, score: 0.50)
        await h.session.recordTakeMatch(contentKey: key, title: "car", recordID: h.anchor.id, score: 0.58)
        await h.session.recordTakeMatch(contentKey: key, title: "car", recordID: voice, score: 0.81)
        await h.session.recordTakeMatch(contentKey: key, title: "car", recordID: voice, score: 0.20)
        let measurement = try #require(h.session.perVideoBook.measurements.first)
        #expect(measurement.videoVoice == 0.81, "the first take with the video's voice")
        #expect(measurement.anchor == 0.54, "the anchor's takes pooled")
        #expect(VoiceLabSession.matchLine(measurement, anchor: "siim") == "car: its own voice 0.81 · siim 0.54")
        #expect(await VoicePerVideoStore(locations: h.app.locations).load().measurements == h.session.perVideoBook.measurements)
    }
}

extension AppModel {
    /// Gives the anchor a measured length calibration, as a voice with real takes has.
    fileprivate func rateCalibrations(seed recordID: String) {
        recordRateCalibration(recordID: recordID, model: "eleven_v4", take: "t1", measured: 2.8, estimated: 2.0)
    }
}
#endif
