import CryptoKit
import Darwin
import Foundation
import Synchronization
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
    @MainActor @Test func auditionCancelsOnTakeSelectionRejectionAndSessionEnd() async throws {
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
        await player.reject(take)
        #expect(!player.isPlaying && !scratch.isValid && !FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
        #expect(throws: VoiceLabError.invalidAudio) { try player.play(scratch, takeId: take, selectionId: "second") }
        let paid = root.appendingPathComponent(scratch.fitted.paidAsset.file)
        #expect(FileManager.default.fileExists(atPath: paid.path))
        let secondRoot = root.appendingPathComponent("another")
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false)
        let second = try vector.scratch(root: secondRoot)
        let ending = VoiceLabAudition { _, finished in AuditionTestBackend(finished: finished) }
        try ending.play(second, takeId: UUID(), selectionId: "last")
        await ending.endSession()
        #expect(!second.isValid && !FileManager.default.fileExists(atPath: second.fittedAudioURL.path))
    }
    @Test func invalidationStopsConsumersBeforeRemovingBothPrivateDirectories() async throws {
        let vector = try #require(FittedAssetVector.load().first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try vector.scratch(root: root)
        let stopped = Mutex(false)
        _ = try scratch.attach {
            #expect(FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
            #expect(FileManager.default.fileExists(atPath: scratch.fitted.snapshot.url.path))
            stopped.withLock { $0 = true }
        }
        await scratch.invalidate()
        await scratch.invalidate()
        #expect(stopped.withLock { $0 })
        #expect(!scratch.isValid && !scratch.fitted.snapshot.isValid)
        #expect(!FileManager.default.fileExists(atPath: scratch.mixedAudioURL.deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: scratch.fitted.snapshot.url.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(scratch.fitted.paidAsset.file).path))
    }
    @Test func invalidationNeverTraversesReplacementScratchOrSnapshotDirectories() async throws {
        let vector = try #require(FittedAssetVector.load().first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try vector.scratch(root: root)
        let directories = [scratch.mixedAudioURL.deletingLastPathComponent(), scratch.fitted.snapshot.url.deletingLastPathComponent()]
        for (index, directory) in directories.enumerated() {
            try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("original-\(index)"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("replacement user file".utf8).write(to: directory.appendingPathComponent("user.txt"))
        }
        await scratch.invalidate()
        for (index, directory) in directories.enumerated() {
            #expect(try Data(contentsOf: directory.appendingPathComponent("user.txt")) == Data("replacement user file".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("original-\(index)").path).isEmpty)
        }
        #expect(!scratch.isValid && !scratch.fitted.snapshot.isValid)
    }
    @MainActor @Test(arguments: [false, true]) func sharedLeaseStopsBothWindowsBeforeCleanup(ending: Bool) async throws {
        let vector = try #require(FittedAssetVector.load().first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try vector.scratch(root: root)
        var backends: [AuditionTestBackend] = []
        func player() -> VoiceLabAudition {
            VoiceLabAudition { _, completion in
                let backend = AuditionTestBackend(finished: completion); backends.append(backend); return backend
            }
        }
        let first = player(), otherWindow = player(), take = UUID()
        try first.play(scratch, takeId: take, selectionId: "selection")
        try otherWindow.play(scratch, takeId: take, selectionId: "selection")
        #expect(first.isPlaying && otherWindow.isPlaying)
        if ending { await first.endSession() } else { await first.reject(take) }
        #expect(!first.isPlaying && !otherWindow.isPlaying)
        #expect(backends.allSatisfy { $0.stops == 1 })
        #expect(!FileManager.default.fileExists(atPath: scratch.mixedAudioURL.path))
        #expect(!FileManager.default.fileExists(atPath: scratch.fitted.snapshot.url.path))
        backends[1].finished()
        #expect(!otherWindow.completed && !otherWindow.isPlaying)
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
                #expect(files.allSatisfy { $0 == "candidate.wav" || $0 == ".candidate.wav.ownership.json" })
                #expect(files.contains("candidate.wav") == files.contains(".candidate.wav.ownership.json"))
                if files.contains("candidate.wav") {
                    let expected = VoiceLabAssetStore.wavHeader(frames: pcm.count / 2, sampleRate: 24_000) + pcm
                    #expect(try Data(contentsOf: root.appendingPathComponent(projectId).appendingPathComponent("candidate.wav")) == expected)
                }
            }
        }
    }
    @Test func startupRecoveryDeletesOnlyJournalledDeadPartialsAndNeverCompleteAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(projectId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let identity = UUID().uuidString.lowercased()
        let old = directory.appendingPathComponent(".old.wav.\(identity).partial")
        let current = directory.appendingPathComponent(".current.wav.\(identity).partial")
        let unknown = directory.appendingPathComponent("old.partial")
        let complete = directory.appendingPathComponent("paid.wav")
        let link = directory.appendingPathComponent(".link.wav.\(identity).partial")
        let boundary = Date(timeIntervalSince1970: 1_000)
        for path in [old, current, unknown, complete] {
            try Data([1, 2, 3]).write(to: path)
            try FileManager.default.setAttributes([.modificationDate: path == current ? boundary : boundary.addingTimeInterval(-1)], ofItemAtPath: path.path)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: complete)
        let descriptor = try VoiceLabPaidRoot.open(root)
        defer { Darwin.close(descriptor) }
        let lock = try VoiceLabAssetRecovery.lock(descriptor)
        defer { Darwin.close(lock) }
        let project = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        let partial = Darwin.open(old.path, O_RDWR)
        defer { Darwin.close(project); Darwin.close(partial) }
        _ = try VoiceLabAssetRecovery.recordPartial(project, name: old.lastPathComponent, descriptor: partial,
            owner: .init(pid: 123, seconds: 100, microseconds: 0))
        let operation = try VoiceLabAssetRecovery.Operation(parent: project, owner: .init(pid: 123, seconds: 100, microseconds: 0))
        let staged = directory.appendingPathComponent(operation.name).appendingPathComponent("audio.partial")
        try Data([4, 5]).write(to: staged)
        #expect(try VoiceLabAssetRecovery.recover(descriptor, status: { _ in .gone }) == 1)
        #expect(try VoiceLabAssetRecovery.recover(descriptor, status: { _ in .gone }) == 0)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        for path in [old, current, unknown, complete, link] { #expect(FileManager.default.fileExists(atPath: path.path)) }
        #expect(try Data(contentsOf: complete) == Data([1, 2, 3]))
    }
    @Test(arguments: ["replacement", "live", "dead", "reused", "unknown", "unjournalled"])
    func partialRecoveryRequiresAbandonmentAndOriginalIdentity(scenario: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(projectId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootFD = try VoiceLabPaidRoot.open(root)
        let projectFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(projectFD); Darwin.close(rootFD) }
        guard case .running(let owner) = VoiceLabAssetRecovery.ownerStatus(getppid()) else {
            Issue.record("Cannot read the live second process start time"); return
        }
        let operation = try VoiceLabAssetRecovery.Operation(parent: projectFD, owner: owner)
        let staged = directory.appendingPathComponent(operation.name)
        let file = staged.appendingPathComponent("audio.partial")
        try Data([1, 2]).write(to: file)
        var info = stat()
        #expect(fstat(operation.descriptor, &info) == 0 && info.st_mode & 0o777 == 0o700)
        if scenario == "unjournalled" {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(VoiceLabAssetRecovery.intentName(operation.name)))
            try FileManager.default.removeItem(at: staged.appendingPathComponent(".operation.json"))
        }
        if scenario == "replacement" {
            let journal = try Data(contentsOf: staged.appendingPathComponent(".operation.json"))
            try FileManager.default.moveItem(at: staged, to: directory.appendingPathComponent("kept-original"))
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try journal.write(to: staged.appendingPathComponent(".operation.json"))
            try Data("replacement user file".utf8).write(to: file)
        }
        let removed = try VoiceLabAssetRecovery.recover(rootFD, status: { pid in
            #expect(pid == owner.pid)
            switch scenario {
            case "live": return VoiceLabAssetRecovery.ownerStatus(pid)
            case "reused": return .running(.init(pid: pid, seconds: owner.seconds + 1, microseconds: owner.microseconds))
            case "unknown": return .unknown
            default: return .gone
            }
        })
        let abandoned = scenario == "dead" || scenario == "reused"
        #expect(removed == (abandoned ? 1 : 0))
        #expect(FileManager.default.fileExists(atPath: file.path) == !abandoned)
        if scenario == "replacement" { #expect(try Data(contentsOf: file) == Data("replacement user file".utf8)) }
    }
    @Test(arguments: ["file", "directory", "symlink"])
    func recoveryUsesOpenedDirectoryWhenItsPathIsReplaced(replacement: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent(projectId)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootFD = try VoiceLabPaidRoot.open(root), projectFD = Darwin.open(project.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(projectFD); Darwin.close(rootFD) }
        let operation = try VoiceLabAssetRecovery.Operation(parent: projectFD, owner: .init(pid: 123, seconds: 100, microseconds: 0))
        let staged = project.appendingPathComponent(operation.name), original = project.appendingPathComponent("original")
        try Data([1, 2]).write(to: staged.appendingPathComponent("audio.partial"))
        let outside = root.appendingPathComponent("user-files")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let marker = outside.appendingPathComponent("user.txt")
        try Data("keep".utf8).write(to: marker)
        var opened = false
        let recovered = try VoiceLabAssetRecovery.recover(rootFD, status: { _ in .gone }, afterOpening: { name in
            #expect(name == operation.name); opened = true
            try FileManager.default.moveItem(at: staged, to: original)
            if replacement == "file" { try Data("keep".utf8).write(to: staged) }
            else if replacement == "symlink" { try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: outside) }
            else {
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
                try Data("keep".utf8).write(to: staged.appendingPathComponent("user.txt"))
            }
        })
        #expect(recovered == 1)
        #expect(opened && FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.path).isEmpty)
        if replacement == "file" { #expect(try Data(contentsOf: staged) == Data("keep".utf8)) }
        else { #expect(try Data(contentsOf: staged.appendingPathComponent("user.txt")) == Data("keep".utf8)) }
    }
    @Test func writerHoldsRecoveryLockUntilPublicationCompletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var checked = false
        let asset = try VoiceLabAssetStore.write(pcm16: Data(repeating: 0, count: 480), sampleRate: 24_000,
            projectId: projectId, assetId: "paid", paidRoot: root, createdAt: Date(), afterPublish: nil, checkpoint: { point in
                guard point == .temporary else { return }
                let descriptor = Darwin.open(root.appendingPathComponent(".asset-write.lock").path, O_RDWR)
                defer { Darwin.close(descriptor) }
                #expect(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == -1)
                let directory = root.appendingPathComponent(projectId)
                let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                #expect(names.count == 2)
                let operation = try #require(names.first(where: { $0.hasPrefix("op-") }))
                #expect(names.contains(VoiceLabAssetRecovery.intentName(operation)))
                let entries = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(operation).path)
                #expect(entries.contains(".operation.json"))
                #expect(entries.filter { $0.hasSuffix(".partial") }.count == 1)
                #expect(entries.filter { $0.hasSuffix(".partial.owner.json") }.count == 1)
                checked = true
            })
        #expect(checked)
        #expect(try VoiceLabAssetStore.recoverStalePartials(paidRoot: root) == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
    }
    @Test(arguments: ["before-mkdir", "after-mkdir", "during-identity"])
    func intentRecoveryClosesDirectoryCreationCrashGaps(point: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent(projectId)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootFD = try VoiceLabPaidRoot.open(root), parent = Darwin.open(project.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(parent); Darwin.close(rootFD) }
        let name = "op-\(UUID().uuidString.lowercased())"
        let intent = VoiceLabAssetRecovery.DirectoryRecord(name: name, owner: .init(pid: 123, seconds: 100, microseconds: 0), identity: nil)
        _ = try VoiceLabAssetRecovery.writeRecord(intent, directory: parent, filename: VoiceLabAssetRecovery.intentName(name))
        if point != "before-mkdir" {
            #expect(mkdirat(parent, name, 0o700) == 0)
            if point == "during-identity" { try Data("{incomplete".utf8).write(to: project.appendingPathComponent(name).appendingPathComponent(".operation.json")) }
        }
        #expect(try VoiceLabAssetRecovery.recover(rootFD, status: { _ in .gone }) == (point == "before-mkdir" ? 0 : 1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
        #expect(try VoiceLabAssetRecovery.recover(rootFD, status: { _ in .gone }) == 0)
    }
    @Test(arguments: ["intent", "directory"])
    func initializationFailureImmediatelyRemovesItsOwnedDirectory(point: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(parent) }
        #expect(throws: VoiceLabAssetStoreError.self) {
            _ = try VoiceLabAssetRecovery.Operation(parent: parent, checkpoint: { stage in
                if stage == point { throw VoiceLabAssetStoreError.unwritable("injected") }
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test(arguments: ["live", "unknown", "symlink", "foreign-entry", "noncanonical-name", "reused-pid"])
    func identitylessIntentRecoveryRequiresDeadOwnerAndStrictDirectory(scenario: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent(projectId)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootFD = try VoiceLabPaidRoot.open(root), parent = Darwin.open(project.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(parent); Darwin.close(rootFD) }
        let name = scenario == "noncanonical-name" ? "op-not-a-uuid" : "op-\(UUID().uuidString.lowercased())"
        let owner = VoiceLabAssetRecovery.Owner(pid: 123, seconds: 100, microseconds: 0)
        _ = try VoiceLabAssetRecovery.writeRecord(.init(name: name, owner: owner, identity: nil), directory: parent,
            filename: VoiceLabAssetRecovery.intentName(name))
        let path = project.appendingPathComponent(name)
        let target = root.appendingPathComponent("user-files")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: target.appendingPathComponent("user.txt"))
        if scenario == "symlink" { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target) }
        else { #expect(mkdirat(parent, name, 0o700) == 0) }
        if scenario == "foreign-entry" { try Data("keep".utf8).write(to: path.appendingPathComponent("user.txt")) }
        let removed = try VoiceLabAssetRecovery.recover(rootFD, status: { _ in
            if scenario == "live" { return .running(owner) }
            if scenario == "unknown" { return .unknown }
            if scenario == "reused-pid" { return .running(.init(pid: owner.pid, seconds: 101, microseconds: 0)) }
            return .gone
        })
        #expect(removed == (scenario == "reused-pid" ? 1 : 0))
        #expect(FileManager.default.fileExists(atPath: path.path) == (scenario != "reused-pid"))
        #expect(try Data(contentsOf: target.appendingPathComponent("user.txt")) == Data("keep".utf8))
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
