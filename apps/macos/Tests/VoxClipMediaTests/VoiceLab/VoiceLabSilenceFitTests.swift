import CryptoKit
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

struct FittedAssetVector: Decodable {
    struct Edit: Decodable { let kind: String; let start: Int64; let count: Int64 }
    struct Expected: Decodable {
        let paidSHA256: String
        let fittedSHA256: String
        let outputFrames: Int64
        let trimStartFrame: Int64
        let trimEndFrame: Int64
    }
    let name: String
    let rate: Int
    let channels: Int
    let bits: Int
    let floating: Bool
    let incomingPadFrames: Int64
    let outgoingPadFrames: Int64
    let edits: [Edit]
    let residualSeconds: Double
    let windowStart: Double
    let windowEnd: Double
    let expected: Expected
    static func load() throws -> [Self] {
        struct Document: Decodable { let cases: [FittedAssetVector] }
        return try JSONDecoder().decode(Document.self, from: FixtureLoader.data("fixtures/voice-lab/fitted-asset-cases.json")).cases
    }
    func paidPCM() -> Data {
        var wave = VoiceLabWavePCM(rate: rate, channels: channels, bits: bits, floating: floating,
            pcm: Data(count: 21_600 * channels * (bits / 8)))
        for frame in 0..<21_600 {
            for channel in 0..<channels {
                var base = (frame * 17 + channel * 13) % 127 - 63
                if [(2300, 2600), (4800, 6000), (14400, 15600), (19000, 19300)].contains(where: { $0.0 <= frame && frame < $0.1 }) { base += 18_000 }
                wave.setSample(Double(base) / 32_768, frame: Int64(frame), channel: channel)
            }
        }
        return wave.pcm
    }
    func window() -> VoiceLabWindow {
        let start = Int64(EditingPrimitives.jsRound(windowStart * 48_000)), end = Int64(EditingPrimitives.jsRound(windowEnd * 48_000))
        return VoiceLabWindow(firstWordId: "w4", lastWordId: "w5", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: windowStart, end: windowEnd, startSample: start, endSample: end,
            leftSeam: .init(kind: .gap, time: windowStart, sample: start, fadeSamples: 960),
            rightSeam: .init(kind: .gap, time: windowEnd, sample: end, fadeSamples: 960))
    }
    func mapped(_ frame: Int64) -> Int64 {
        incomingPadFrames + frame - 2400 + edits.filter { $0.start + $0.count <= frame }.reduce(Int64(0)) { $0 + ($1.kind == "insert" ? $1.count : -$1.count) }
    }
    func fit() -> VoiceLabFitResult {
        let window = window()
        let words = [("new", Int64(4800), Int64(6000)), ("words", Int64(14400), Int64(15600))].map {
            VoiceLabWord(text: $0.0, start: Double(mapped($0.1)) / Double(rate), end: Double(mapped($0.2)) / Double(rate), synthetic: true)
        }
        let plan = VoiceLabFitPlan(edits: edits.map { .init(kind: $0.kind == "insert" ? .insert : .remove, start: $0.start, count: $0.count) },
            incoming: .init(padFrames: incomingPadFrames, borrowedSamples: windowStart == 2.48 ? 960 : 0),
            outgoing: .init(padFrames: outgoingPadFrames, borrowedSamples: 0), trimStartFrame: 2400, trimEndFrame: 19_200,
            windowStart: window.start, windowEnd: window.end, windowStartSample: window.startSample, windowEndSample: window.endSample,
            outputFrames: expected.outputFrames, words: words)
        return residualSeconds == 0 ? .exact(plan) : .changedDuration(plan, naturalOut: 0.7, residualSeconds: residualSeconds)
    }
    func prepare(root: URL, projectId: String = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11") throws -> VoiceLabFittedAudio {
        let paid = try VoiceLabAssetStore.writeWave(pcm: paidPCM(), sampleRate: rate, channels: channels, bits: bits, floating: floating,
            projectId: projectId, assetId: "paid-\(name)", paidRoot: root, createdAt: Date(timeIntervalSince1970: 0))
        let snapshot = try VoiceLabAssets.preparePaid(asset: paid, projectId: projectId, paidRoot: root, scratchRoot: root)
        return try VoiceLabSilenceFit.prepare(snapshot: snapshot, paidAsset: paid, fit: fit(), window: window(), sourceSampleRate: 48_000)
    }
    func scratch(root: URL, hard: Bool = false, roomTone: Bool = false) throws -> VoiceLabTakeScratch {
        let initial = try prepare(root: root)
        var window = window()
        if hard {
            window.leftSeam.kind = .hard; window.leftSeam.fadeSamples = 576
            window.rightSeam.kind = .hard; window.rightSeam.fadeSamples = 576
        }
        let fitted = try VoiceLabSilenceFit.prepare(snapshot: initial.snapshot, paidAsset: initial.paidAsset, fit: fit(), window: window, sourceSampleRate: 48_000)
        var source = [Float](repeating: 0.1, count: rate * 6)
        if roomTone { for frame in 0..<(rate / 2) { source[frame] = Float(frame) / Float(rate / 2) * 0.01 } }
        let room: VoiceLabRoomTone? = roomTone ? .init(sourceStartSample: 0, sourceEndSample: 24_000, gainDb: -6) : nil
        let analysis = VoiceLabTakeAnalysis(sampleRate: rate, trimmed: [], gainDb: roomTone ? -3 : 0, roomTone: room, fit: fit())
        let input = VoiceLabTakeInput(text: "new words", modelID: "fixture", recordID: "fixture", language: "en", seed: 7,
            contentKey: "fixture", source: [], sourceSampleRate: 48_000, items: [], window: window,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        return try VoiceLabAudioRenderer.stageTake(fitted: fitted, analysis: analysis, input: input, sourceAtAssetRate: source, scratchRoot: root)
    }
}

@MainActor private final class AuditionTestBackend: VoiceLabAuditionBackend {
    var position = 0.0
    var stops = 0
    let finished: @MainActor @Sendable () -> Void
    init(finished: @escaping @MainActor @Sendable () -> Void) { self.finished = finished }
    func play() -> Bool { true }
    func stop() { stops += 1 }
}

extension HeavyMediaTests {
@Suite("Fitted take assets", .serialized) struct VoiceLabSilenceFitTests {
    private let projectId = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11"
    @Test(arguments: [false, true]) func scratchSeamsAreCentredEqualPowerAndHaveExactLengths(hard: Bool) throws {
        let vector = try #require(FittedAssetVector.load().first { $0.name == "balanced-edits" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try vector.scratch(root: root, hard: hard)
        let wave = scratch.fitted.wave, rate = vector.rate, count = hard ? 288 : 480
        #expect(scratch.audio.seams == [rate / 2, rate / 2 + Int(vector.expected.outputFrames)])
        for (index, seam) in scratch.audio.seams.enumerated() {
            for offset in 0..<count {
                let local = offset - count / 2
                let phase = Double(offset) / Double(count - 1)
                let left = Float(cos(.pi * phase / 2)), right = Float(sin(.pi * phase / 2))
                #expect(abs(left * left + right * right - 1) < 0.000_001)
                let frame = index == 0 ? scratch.fitted.trimStartFrame + Int64(local) : scratch.fitted.trimEndFrame + Int64(local)
                let generated = Float(wave.sample(frame: frame, channel: 0))
                let expected = index == 0 ? Float(0.1) * left + generated * right : generated * left + Float(0.1) * right
                #expect(scratch.audio.mixed[seam + local] == expected)
            }
        }
        #expect(scratch.audio.mixed[rate / 2 - count / 2 - 1] == 0.1)
        #expect(scratch.audio.mixed[rate / 2 + Int(vector.expected.outputFrames) + count - count / 2] == 0.1)
        let file = try VoiceLabWavePCM(Data(contentsOf: scratch.mixedAudioURL))
        #expect(file.frames == scratch.audio.mixed.count && file.floating && file.bits == 32)
    }
    @Test func scratchUsesFiftyMillisecondRoomLoopAndDoesNotBakeItIntoFit() throws {
        let vector = try #require(FittedAssetVector.load().first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try vector.scratch(root: root, roomTone: true)
        let fade = 1200, period = 10_800, lead = vector.rate / 2
        for offset in 0..<fade {
            let phase = Double(offset) / Double(fade - 1)
            let left = Float(period + offset) / 12_000 * 0.01 * Float(cos(.pi * phase / 2))
            let right = Float(offset) / 12_000 * 0.01 * Float(sin(.pi * phase / 2))
            let expectedTone = (left + right) * Float(pow(10, -6.0 / 20))
            let bodyFrame = period + offset
            let speech = Float(scratch.fitted.wave.sample(frame: scratch.fitted.trimStartFrame + Int64(bodyFrame), channel: 0)) * Float(pow(10, -3.0 / 20))
            #expect(abs(scratch.audio.mixed[lead + bodyFrame] - (speech + expectedTone)) < 0.000_001)
        }
        let digest = SHA256.hash(data: Data(try Data(contentsOf: scratch.fittedAudioURL))).map { String(format: "%02x", $0) }.joined()
        #expect(digest == vector.expected.fittedSHA256)
    }
    #if DEBUG
    @MainActor @Test func auditionCancelsOnTakeSelectionRejectionAndSessionEnd() throws {
        let vector = try #require(FittedAssetVector.load().first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try vector.scratch(root: root)
        var backends: [AuditionTestBackend] = []
        let player = VoiceLabAudition { url, finished in
            #expect(url == scratch.mixedAudioURL)
            let backend = AuditionTestBackend(finished: finished); backends.append(backend); return backend
        }
        let take = UUID()
        try player.play(scratch, takeId: take, selectionId: "first")
        backends[0].position = 0.25; player.refreshPosition()
        #expect(player.isPlaying && player.position == 0.25)
        player.selectionChanged(to: "second")
        #expect(!player.isPlaying && backends[0].stops == 1 && scratch.isValid)
        try player.play(scratch, takeId: take, selectionId: "second")
        backends[0].finished()
        #expect(player.isPlaying && !player.completed)
        backends[1].position = 1; backends[1].finished()
        #expect(player.completed && !player.isPlaying && player.position == 1)
        player.takeChanged(to: UUID())
        #expect(!player.isPlaying && !player.completed)
        try player.play(scratch, takeId: take, selectionId: "second")
        player.reject(take)
        #expect(!player.isPlaying && !scratch.isValid && !FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
        #expect(throws: VoiceLabError.invalidAudio) { try player.play(scratch, takeId: take, selectionId: "second") }
        let paid = root.appendingPathComponent(scratch.fitted.paidAsset.file)
        #expect(FileManager.default.fileExists(atPath: paid.path))
        let secondRoot = root.appendingPathComponent("another")
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false)
        let second = try vector.scratch(root: secondRoot)
        let ending = VoiceLabAudition { _, finished in AuditionTestBackend(finished: finished) }
        try ending.play(second, takeId: UUID(), selectionId: "last")
        ending.endSession()
        #expect(!second.isValid && !FileManager.default.fileExists(atPath: second.fittedAudioURL.path))
    }
    #endif
    @Test func sharedTest19HashesAndUneditedFrames() throws {
        for vector in try FittedAssetVector.load() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let fitted = try vector.prepare(root: root)
            #expect(fitted.paidAsset.sha256 == vector.expected.paidSHA256, Comment(rawValue: vector.name))
            let digest = SHA256.hash(data: fitted.wave.bytes).map { String(format: "%02x", $0) }.joined()
            #expect(digest == vector.expected.fittedSHA256, Comment(rawValue: vector.name))
            #expect(fitted.trimStartFrame == vector.expected.trimStartFrame && fitted.trimEndFrame == vector.expected.trimEndFrame)
            let original = try VoiceLabWavePCM(Data(contentsOf: fitted.snapshot.url)), stride = original.stride
            for frame in Int64(2400)..<19_200 {
                if vector.edits.contains(where: { $0.start - 240 <= frame && frame < $0.start + $0.count + 240 }) { continue }
                let output = fitted.trimStartFrame + vector.mapped(frame)
                #expect(original.pcm[Int(frame) * stride..<(Int(frame) + 1) * stride] == fitted.wave.pcm[Int(output) * stride..<(Int(output) + 1) * stride])
            }
            if vector.incomingPadFrames > 0 {
                #expect(fitted.wave.pcm.prefix(Int(fitted.trimStartFrame + vector.incomingPadFrames) * stride).allSatisfy { $0 == 0 })
            } else {
                #expect(fitted.wave.pcm[Int(fitted.trimStartFrame - 240) * stride..<Int(fitted.trimStartFrame) * stride] == original.pcm[2160 * stride..<2400 * stride])
            }
            if vector.outgoingPadFrames > 0 { #expect(fitted.wave.pcm.suffix(Int(vector.outgoingPadFrames + 240) * stride).allSatisfy { $0 == 0 }) }
            let publication = try fitted.publish(projectId: projectId, assetId: "fitted-\(vector.name)", paidRoot: root,
                createdAt: Date(timeIntervalSince1970: 0), requestId: "paid-request", seed: 7, gainDb: -2)
            #expect(publication.audio.stretch == 1)
            #expect(publication.outDuration == (vector.windowEnd - vector.windowStart) + vector.residualSeconds)
            #expect(Int64(EditingPrimitives.jsRound(publication.audio.trimEnd * Double(vector.rate))) - Int64(EditingPrimitives.jsRound(publication.audio.trimStart * Double(vector.rate))) == vector.expected.outputFrames)
            #expect(publication.chunks[0].assetId == fitted.paidAsset.id && publication.chunks[0].assetSha256 == fitted.paidAsset.sha256)
            #expect(publication.chunks[0].requestId == "paid-request" && publication.chunks[0].seed == 7)
            #expect(publication.sourceStartSample == vector.window().startSample && publication.sourceEndSample == vector.window().endSample)
            #expect(publication.assets.count == (fitted.isDerived ? 2 : 1))
            let asset = try #require(publication.assets.last)
            #expect(asset.sha256 == vector.expected.fittedSHA256)
            let snapshot = try VoiceLabAssets.preparePaid(asset: asset, projectId: projectId, paidRoot: root, scratchRoot: root)
            #expect(snapshot.sha256 == vector.expected.fittedSHA256)
        }
    }
    @Test func paidPathSwapCannotChangeFitAndSnapshotTamperingIsRefused() throws {
        let vector = try #require(FittedAssetVector.load().first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fitted = try vector.prepare(root: root)
        try Data("changed".utf8).write(to: root.appendingPathComponent(fitted.paidAsset.file))
        _ = try VoiceLabSilenceFit.prepare(snapshot: fitted.snapshot, paidAsset: fitted.paidAsset, fit: fitted.fit, window: vector.window(), sourceSampleRate: 48_000)
        try Data("changed".utf8).write(to: fitted.snapshot.url)
        #expect(throws: VoiceLabAssetError.altered(fitted.paidAsset.id)) {
            try VoiceLabSilenceFit.prepare(snapshot: fitted.snapshot, paidAsset: fitted.paidAsset, fit: fitted.fit, window: vector.window(), sourceSampleRate: 48_000)
        }
    }
    @Test func everyPublishBoundaryLeavesNothingOrCompleteVerifiedBytes() throws {
        struct Injected: Error {}
        for boundary in VoiceLabAssetStore.WriteBoundary.allCases {
            for (derived, occurrence) in [(false, 1), (true, 1), (false, 2), (true, 2)].filter({ boundary == .pcm || $0.1 == 1 }) {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: root) }
                let pcm = Data(repeating: 1, count: 150_000)
                var listed: [VoiceLabAsset] = []
                var seen = 0
                func fail(_ point: VoiceLabAssetStore.WriteBoundary) throws {
                    if point == boundary { seen += 1; if seen == occurrence { throw Injected() } }
                }
                #expect(throws: Injected.self) {
                    let asset: VoiceLabAsset
                    if derived {
                        asset = try VoiceLabAssetStore.writeWave(pcm: pcm, sampleRate: 24_000, channels: 1, bits: 16, floating: false,
                            projectId: projectId, assetId: "candidate", paidRoot: root, createdAt: Date(), checkpoint: fail)
                    } else {
                        asset = try VoiceLabAssetStore.write(pcm16: pcm, sampleRate: 24_000, projectId: projectId, assetId: "candidate",
                            paidRoot: root, createdAt: Date(), afterPublish: nil, checkpoint: fail)
                    }
                    listed.append(asset)
                }
                #expect(listed.isEmpty)
                let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(projectId).path)
                #expect(files.allSatisfy { $0 == "candidate.wav" })
                if files.contains("candidate.wav") {
                    let expected = VoiceLabAssetStore.wavHeader(frames: pcm.count / 2, sampleRate: 24_000) + pcm
                    #expect(try Data(contentsOf: root.appendingPathComponent(projectId).appendingPathComponent("candidate.wav")) == expected)
                }
            }
        }
    }
    @Test func pcm24OddFramePaddingIsCanonicalAndVerified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = try VoiceLabAssetStore.writeWave(pcm: Data(count: 3003), sampleRate: 24_000, channels: 1, bits: 24, floating: false,
            projectId: projectId, assetId: "odd", paidRoot: root, createdAt: Date())
        let snapshot = try VoiceLabAssets.preparePaid(asset: asset, projectId: projectId, paidRoot: root, scratchRoot: root)
        let bytes = try Data(contentsOf: snapshot.url), wave = try VoiceLabWavePCM(bytes)
        #expect(bytes.count == 3048 && wave.frames == 1001 && wave.pcm.count == 3003)
    }
}
}
