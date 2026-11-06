#if DEBUG
import Foundation
import Testing
@_spi(Testing) @testable import VoxClipCore

/// A matching voice for each video (voice-lab §6.13, ADR-R45): the remembered answer, one video's pieces at the lower
/// cleanliness floor with identity still one hop, the book in app data, and what may be removed.
@Suite("A matching voice for each video", .offlineFixtures)
struct VoicePerVideoTests {
    private func piece(_ video: String, start: Int, seconds: Int = 15, snr: Double, score: Double = 0.9) -> VoiceRebuild.Candidate {
        .init(video: video, startMs: start * 1_000, endMs: (start + seconds) * 1_000, snrDb: snr, score: score, embedding: [1, 0])
    }
    private static let one = "11111111-1111-4111-8111-111111111111"
    private static let two = "22222222-2222-4222-8222-222222222222"
    private static let anchor = "6f0c2c1e-8a0e-4c5e-9d1f-0b9d4a7f2e11"
    private func video(_ key: String, _ record: String) -> VoicePerVideoBook.Video {
        .init(contentKey: key, recordId: record, anchorId: Self.anchor, anchorReferenceSha256: String(repeating: "a", count: 64),
              title: key, createdAt: "2026-11-06T10:00:00Z", videoSeconds: 41, removesBackgroundNoise: true)
    }

    @Test func theAnswerIsUnsetUntilChosenAndOnlyABooleanOrNullIsStored() throws {
        #expect(VoicePerVideo.Mode(setting: nil) == .ask && VoicePerVideo.Mode(setting: true) == .match && VoicePerVideo.Mode(setting: false) == .anchor)
        for mode in [VoicePerVideo.Mode.ask, .match, .anchor] { #expect(VoicePerVideo.Mode(setting: mode.setting) == mode) }
        #expect(SettingsDocument.defaults[VoicePerVideo.settingKey] == nil, "no default: unset asks once")
        #expect(SettingsDocument.isKnownKey(VoicePerVideo.settingKey))
        for value in [JSONValue.bool(true), .bool(false), .null] { try SettingsDocument(values: [VoicePerVideo.settingKey: value]).validate() }
        #expect(throws: (any Error).self) { try SettingsDocument(values: [VoicePerVideo.settingKey: .string("yes")]).validate() }
    }

    @Test func oneVideosNoisyPiecesCountAtTheLowerFloorButIdentityIsStillOneHop() {
        // The DJI car video's shape (ADR-R45): nothing at 20 dB, owner pieces at 8.8–11.3 dB, a noisier owner piece,
        // and a clean-enough piece that isn't the owner one hop from the consent embedding.
        let candidates = [
            piece("car", start: 72, seconds: 10, snr: 8.83, score: 0.47),
            piece("car", start: 83, seconds: 17, snr: 8.84, score: 0.48),
            piece("car", start: 101, seconds: 15, snr: 11.31, score: 0.49),
            piece("car", start: 172, seconds: 12, snr: 6.70, score: 0.45),
            piece("car", start: 117, seconds: 20, snr: 15.43, score: 0.40),
        ]
        let clean = VoiceRebuild.pick(candidates, threshold: 0.45, keptMs: 27_720)
        #expect(clean.pieces.isEmpty && !clean.enough, "the rebuild's own 20 dB floor finds nothing")
        let plan = VoiceRebuild.pick(candidates, threshold: 0.45, keptMs: 27_720, minimumSnrDb: VoicePerVideo.minimumSnrDb)
        #expect(plan.pieces.map(\.startMs).sorted() == [72_000, 83_000, 101_000])
        #expect(plan.rejected == [.notTheOwner: 1, .noisy: 1], "a lower floor never lets in a voice that isn't the owner's")
        #expect(VoicePerVideo.videoMs(plan) == 42_000 && VoicePerVideo.videoMs(plan) >= VoicePerVideo.minimumVideoMs)
        #expect(VoicePerVideo.removesBackgroundNoise(plan), "under 20 dB, creation asks ElevenLabs to remove the noise")
        let quiet = VoiceRebuild.pick([piece("room", start: 0, seconds: 30, snr: 25), piece("room", start: 40, seconds: 10, snr: 30)],
                                      threshold: 0.45, keptMs: 6_000, minimumSnrDb: VoicePerVideo.minimumSnrDb)
        #expect(!VoicePerVideo.removesBackgroundNoise(quiet), "clean speech keeps remove_background_noise false (§6.5 step 5)")
        // Too little of the video's own speech: the kept clip alone never makes a video's voice.
        let short = VoiceRebuild.pick([piece("car", start: 0, seconds: 12, snr: 9)], threshold: 0.45, keptMs: 27_720,
                                      minimumSnrDb: VoicePerVideo.minimumSnrDb)
        #expect(short.enough && VoicePerVideo.videoMs(short) == 12_000 && VoicePerVideo.videoMs(short) < VoicePerVideo.minimumVideoMs)
    }

    @Test func aNewVideosVoiceMakesThePreviousOneARemovalAndTheBookValidates() throws {
        var book = VoicePerVideoBook().adding(video("dji30", Self.one))
        #expect(book.video("dji30")?.recordId == Self.one && book.removals.isEmpty)
        book.shortNoted = ["kitchen"]
        book = book.adding(video("dji75", Self.two))
        #expect(book.videos.map(\.contentKey) == ["dji75"] && book.removals.map(\.recordId) == [Self.one])
        #expect(book.isVideoVoice(Self.one) && book.isVideoVoice(Self.two) && !book.isVideoVoice(Self.anchor))
        try book.validate()
        // The same video again keeps one entry; a removal is never also a current voice.
        #expect(book.adding(video("dji75", Self.two)).removals.map(\.recordId) == [Self.one])
        var broken = book; broken.videos[0].anchorId = Self.two
        #expect(throws: (any Error).self) { try broken.validate() }
        broken = book; broken.removals.append(.init(recordId: Self.two, title: "x"))
        #expect(throws: (any Error).self) { try broken.validate() }
        broken = book; broken.videos[0].contentKey = "../escape"
        #expect(throws: (any Error).self) { try broken.validate() }
        // Diagnostics: one per video, the newest first, merged with what was there.
        let first = book.measuring(.init(contentKey: "dji30", title: "DJI 30", videoVoice: nil, anchor: 0.54, measuredAt: "2026-11-06T10:00:00Z"))
        let merged = first.measuring(.init(contentKey: "dji30", title: "DJI 30", videoVoice: 0.71, anchor: nil, measuredAt: "2026-11-06T10:05:00Z"))
        #expect(merged.measurements.count == 1 && merged.measurements[0].videoVoice == 0.71 && merged.measurements[0].anchor == 0.54)
        var many = merged
        for index in 0..<20 { many = many.measuring(.init(contentKey: "v\(index)", title: "v", videoVoice: 0.5, anchor: nil, measuredAt: "2026-11-06T10:00:00Z")) }
        #expect(many.measurements.count == VoicePerVideoBook.maximumMeasurements && many.measurements[0].contentKey == "v19")
        try many.validate()
    }

    @Test func theStoreKeepsTheBookInAppDataAndADamagedFileReadsAsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("per-video-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoicePerVideoStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        #expect(store.url.path.hasSuffix("VoiceLab/per-video.json"))
        #expect(await store.load() == VoicePerVideoBook())
        let saved = try await store.update { $0.adding(video("dji30", Self.one)) }
        #expect(await store.load() == saved)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("\"schema\" : \"voxclip-voice-per-video\\/1\"") && !text.contains("absolutePath"))
        try Data("{\"schema\":\"other\"}".utf8).write(to: store.url)
        #expect(await store.load() == VoicePerVideoBook())
        var invalid = VoicePerVideoBook(); invalid.shortNoted = ["no spaces allowed"]
        await #expect(throws: (any Error).self) { try await store.save(invalid) }
    }

    @Test func theAnchorsEarlierTakesAreItsOwnAcceptedTextToSpeechTakesNewestFirst() throws {
        var project = try ProjectJSON.decode(FixtureLoader.data("fixtures/voice-lab/passage-project.voxclip"))
        let template = try #require(project.voiceLab.segments.first)
        func take(_ id: String, minutes: Double, kind: VoiceLabSegmentKind = .tts, voice: String? = Self.anchor, enabled: Bool = true,
                  asset: String = "asset-one") -> VoiceLabSegment {
            var segment = template
            segment.id = id; segment.kind = kind; segment.enabled = enabled; segment.audio.assetId = asset
            segment.provenance.consentRecordId = voice
            segment.provenance.createdAt = Date(timeIntervalSince1970: 1_790_000_000 + minutes * 60)
            return segment
        }
        project.voiceLab.segments = [take("old", minutes: 1), take("new", minutes: 9), take("other-voice", minutes: 5, voice: Self.one),
                                     take("recorded", minutes: 6, kind: .recorded), take("changed", minutes: 7, kind: .voiceChanger),
                                     take("off", minutes: 8, enabled: false), take("no-asset", minutes: 4, asset: "gone"),
                                     take("unlinked", minutes: 3, voice: nil), take("middle", minutes: 5)]
        let takes = VoicePerVideo.anchorTakes(in: project, anchorID: Self.anchor)
        #expect(takes.map(\.segment.id) == ["new", "middle", "old"], "only the anchor's accepted text-to-speech takes with their file, newest first")
        #expect(takes.allSatisfy { $0.asset.id == $0.segment.audio.assetId })
        #expect(VoicePerVideo.anchorTakes(in: project, anchorID: Self.two).isEmpty)
        #expect(VoicePerVideo.maximumBaselineTakes == 12)
    }

    @Test func theAnchorsBaselineIsKeptWithItsModelAndReadAsMissingForAnotherModelOrVoice() throws {
        var book = VoicePerVideoBook()
        #expect(book.baseline(anchorId: Self.anchor, model: "wespeaker-resnet34") == nil)
        book.anchorBaseline = .init(anchorId: Self.anchor, model: "wespeaker-resnet34", score: 0.54, takes: 8, measuredAt: "2026-11-06T10:00:00Z")
        try book.validate()
        #expect(book.baseline(anchorId: Self.anchor, model: "wespeaker-resnet34")?.score == 0.54)
        #expect(book.baseline(anchorId: Self.anchor, model: "ecapa-tdnn") == nil, "another model's numbers don't compare")
        #expect(book.baseline(anchorId: Self.one, model: "wespeaker-resnet34") == nil, "another voice's numbers aren't the anchor's")
        let decoded = try JSONDecoder().decode(VoicePerVideoBook.self, from: JSONEncoder().encode(book))
        #expect(decoded == book)
        // A book written before the baseline existed still reads.
        let legacy = try JSONDecoder().decode(VoicePerVideoBook.self, from: Data(#"{"schema":"voxclip-voice-per-video/1","videos":[],"removals":[],"shortNoted":[],"measurements":[]}"#.utf8))
        #expect(legacy.anchorBaseline == nil)
        try legacy.validate()
        var none = book; none.anchorBaseline = .init(anchorId: Self.anchor, model: "m", score: nil, takes: 0, measuredAt: "2026-11-06T10:00:00Z")
        try none.validate()
        for broken in [VoicePerVideoBook.AnchorBaseline(anchorId: Self.anchor, model: "m", score: 0.5, takes: 13, measuredAt: ""),
                       .init(anchorId: Self.anchor, model: "m", score: nil, takes: 3, measuredAt: ""),
                       .init(anchorId: Self.anchor, model: "m", score: 0.5, takes: 0, measuredAt: ""),
                       .init(anchorId: Self.anchor, model: "", score: 0.5, takes: 2, measuredAt: ""),
                       .init(anchorId: "not-a-record", model: "m", score: 0.5, takes: 2, measuredAt: ""),
                       .init(anchorId: Self.anchor, model: "m", score: 1.5, takes: 2, measuredAt: "")] {
            var invalid = book; invalid.anchorBaseline = broken
            #expect(throws: (any Error).self) { try invalid.validate() }
        }
    }

    @Test func aTakesGuardSpeechFallsBackToTenSecondsAroundItsWindow() {
        let none = VoiceLabGuardSpeech.forTake(items: [], start: 20, end: 22, startSample: 320_000, endSample: 352_000, sampleRate: 16_000, totalFrames: 960_000)
        #expect(none.ranges == [256_000..<416_000] && none.speaker == nil)
        let word = TimedWord(id: "w1", text: "hi", start: 21, end: 21.5)
        let spoken = VoiceLabGuardSpeech.forTake(items: [word], start: 20, end: 22, startSample: 320_000, endSample: 352_000, sampleRate: 16_000, totalFrames: 960_000)
        #expect(spoken == VoiceLabGuardSpeech.select(items: [word], start: 20, end: 22, sampleRate: 16_000, totalFrames: 960_000))
    }

    @Test func neverTheAnchorTheCurrentVoiceOrOneWithPendingTakes() {
        #expect(VoicePerVideo.keep(Self.anchor, anchorID: Self.anchor, currentID: Self.two, pendingTakes: []) == .anchor)
        #expect(VoicePerVideo.keep(Self.two, anchorID: Self.anchor, currentID: Self.two, pendingTakes: []) == .current)
        #expect(VoicePerVideo.keep(Self.one, anchorID: Self.anchor, currentID: Self.two, pendingTakes: [Self.one]) == .pendingTakes)
        #expect(VoicePerVideo.keep(Self.one, anchorID: Self.anchor, currentID: Self.two, pendingTakes: [Self.two]) == nil)
    }

    @Test func theNameThePriceAndTheSeededCalibration() throws {
        #expect(VoicePerVideo.displayName(owner: "siim", title: "DJI_20261014184458_0030_D_1080p") == "siim · DJI_20261014184458_0030_D_1080p")
        let long = VoicePerVideo.displayName(owner: "siim", title: String(repeating: "õ", count: 80) + "\n")
        #expect(long.unicodeScalars.count == VoicePerVideo.maximumNameScalars && (try? VoiceConsentText.displayName(long)) == long)
        #expect(VoicePerVideo.displayName(owner: "siim", title: "a\u{0007}b") == "siim · a b", "no control character reaches the name")
        #expect(VoicePerVideo.displayName(owner: "siim", title: "  ") == "siim")
        #expect(VoicePerVideo.title(mediaPath: "/Users/x/Desktop/DJI_0030.MP4") == "DJI_0030")
        let catalog = try VoiceLabPriceCatalog.load(shared: SharedResources.locate())
        #expect(VoicePerVideo.priceLabel(catalog: catalog) == "free", "the catalogue's createClone row is zero")
        #expect(VoicePerVideo.priceLabel(catalog: nil) == nil, "no catalogue: no invented price")
        let anchor = VoiceLabVoiceCalibration(recordId: Self.anchor, models: ["eleven_v4": [.init(id: "t1", ratio: 1.4), .init(id: "t2", ratio: 1.5)]], seeded: true)
        let seeded = VoicePerVideo.seededCalibration(from: anchor, recordId: Self.one)
        #expect(seeded.recordId == Self.one && seeded.models == anchor.models && seeded.seeded)
        let learned = seeded.recording("eleven_v4", id: "t3", measured: 2.0, estimated: 1.0)
        #expect(learned.samples("eleven_v4").map(\.id) == ["t1", "t2", "t3"], "the voice's own takes then join and take over")
    }
}
#endif
