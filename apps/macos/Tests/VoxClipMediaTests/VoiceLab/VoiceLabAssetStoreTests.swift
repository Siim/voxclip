import CryptoKit
import Darwin
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite struct VoiceLabAssetStoreTests {
    private let projectId = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11"
    private let createdAt = Date(timeIntervalSince1970: 1_793_000_000)

    /// A temporary data directory whose canonical `VoiceLab` folder is the paid root.
    private func store() throws -> (data: URL, paid: URL) {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-vl-store-\(UUID().uuidString)", isDirectory: true)
        let paid = DataLocations(environment: ["VOXCLIP_DATA_DIR": data.path]).root.appendingPathComponent("VoiceLab", isDirectory: true)
        try FileManager.default.createDirectory(at: paid, withIntermediateDirectories: true)
        return (data, paid)
    }

    private func pcm(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func tone(frames: Int, rate: Int) -> Data {
        pcm((0..<frames).map { Int16((sin(2 * Double.pi * 440 * Double($0) / Double(rate)) * 10_000).rounded()) })
    }

    private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func entries(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test func canonicalHeaderAndFileForThreeFramesAt24kHz() throws {
        let expected: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, 0x2a, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20,
            0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0xc0, 0x5d, 0x00, 0x00, 0x80, 0xbb, 0x00, 0x00,
            0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61, 0x06, 0x00, 0x00, 0x00,
        ]
        #expect([UInt8](VoiceLabAssetStore.wavHeader(frames: 3, sampleRate: 24_000)) == expected)
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let samples = pcm([1, -2, 32_767])
        let asset = try VoiceLabAssetStore.write(pcm16: samples, sampleRate: 24_000, projectId: projectId,
                                                 assetId: "take-1", paidRoot: paid, createdAt: createdAt)
        let url = paid.appendingPathComponent(asset.file)
        let bytes = try Data(contentsOf: url)
        #expect([UInt8](bytes.prefix(44)) == expected)
        #expect(bytes.count == 50 && bytes.dropFirst(44) == samples)
        #expect(asset == VoiceLabAsset(id: "take-1", file: "\(projectId)/take-1.wav", sha256: hex(bytes),
                                       durationSeconds: 3.0 / 24_000, sampleRate: 24_000, createdAt: createdAt))
        var directory = stat(), written = stat()
        let directoryStatus = stat(paid.appendingPathComponent(projectId).path, &directory)
        let fileStatus = stat(url.path, &written)
        #expect(directoryStatus == 0 && directory.st_mode & 0o777 == 0o700)
        #expect(fileStatus == 0 && written.st_mode & 0o777 == 0o600)
        #expect(try entries(paid.appendingPathComponent(projectId)) == ["take-1.wav"])
    }

    @Test func derivedSamplesRoundHalfToEvenAndClamp() throws {
        // 0.5 × 32767 = 16383.5 is the only in-range tie for float32 input. 0.50006103515625 × 32767 is
        // 16385.49993…, so the exact binary64 product gives 16385; a float32 multiply gives 16385.5 and then 16386.
        let values: [Float] = [0, 0.5, -0.5, 0.25, -0.25, 0.75, 0.50006103515625, -0.50006103515625,
                               1, -1, 1.5, -2, 1 / 32_767, .ulpOfOne]
        let expected: [Int16] = [0, 16_384, -16_384, 8_192, -8_192, 24_575, 16_385, -16_385,
                                 32_767, -32_767, 32_767, -32_767, 1, 0]
        #expect(values.map(VoiceLabAssetStore.pcm16) == expected)
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let asset = try VoiceLabAssetStore.writeDerived(samples: values, sampleRate: 48_000, projectId: projectId,
                                                        assetId: "derived", paidRoot: paid, createdAt: createdAt)
        let bytes = try Data(contentsOf: paid.appendingPathComponent(asset.file))
        #expect(bytes == VoiceLabAssetStore.wavHeader(frames: values.count, sampleRate: 48_000) + pcm(expected))
        #expect(asset.sha256 == hex(bytes) && asset.durationSeconds == Double(values.count) / 48_000)
        for invalid: Float in [.nan, .infinity, -.infinity] {
            #expect(throws: VoiceLabAssetStoreError.invalidAudio("\(projectId)/nonfinite.wav")) {
                try VoiceLabAssetStore.writeDerived(samples: [0, invalid], sampleRate: 48_000, projectId: projectId,
                                                    assetId: "nonfinite", paidRoot: paid, createdAt: createdAt)
            }
        }
        #expect(try entries(paid.appendingPathComponent(projectId)) == ["derived.wav"])
    }

    @Test func writtenAssetPreparesInVersion3ProjectAndOneChangedByteIsAltered() throws {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        #expect(project.schemaVersion == 3)
        let index = try #require(project.voiceLab.assets?.firstIndex { $0.id == "asset-one" })
        let recorded = project.voiceLab.assets![index]
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let frames = Int((recorded.durationSeconds * Double(recorded.sampleRate)).rounded())
        #expect(frames == 21_600)
        let asset = try VoiceLabAssetStore.write(pcm16: tone(frames: frames, rate: recorded.sampleRate), sampleRate: recorded.sampleRate,
                                                 projectId: project.id, assetId: recorded.id, paidRoot: paid,
                                                 createdAt: recorded.createdAt)
        #expect(asset.file == recorded.file && asset.sampleRate == recorded.sampleRate)
        #expect(asset.durationSeconds == recorded.durationSeconds && asset.createdAt == recorded.createdAt)
        project.voiceLab.assets![index] = asset
        // A v3 recipe also records the hash of every chunk's asset.
        for candidate in project.voiceLab.segments[0].candidates.indices {
            var recipe = try #require(project.voiceLab.segments[0].candidates[candidate].recipe)
            for chunk in recipe.chunks.indices where recipe.chunks[chunk].assetId == asset.id {
                recipe.chunks[chunk].assetSha256 = asset.sha256
            }
            project.voiceLab.segments[0].candidates[candidate].recipe = recipe
        }
        let plan = try VoiceLabOutputPlanner.build(project, scope: .full)
        let prepared = try VoiceLabAssets.prepare(project: project, plan: plan, paidRoot: paid)
        let handle = try #require(prepared["vl-passage"])
        #expect(prepared.count == 1 && handle.assetId == "asset-one")
        #expect(handle.sampleRate == 24_000 && handle.channels == 1 && handle.frameCount == Int64(frames))
        let url = paid.appendingPathComponent(asset.file)
        let snapshot = try Data(contentsOf: handle.url)
        #expect(hex(snapshot) == asset.sha256)
        #expect(try Data(contentsOf: url) == snapshot)

        let file = try FileHandle(forUpdating: url)
        try file.seek(toOffset: 1_000)
        let original = try #require(try file.read(upToCount: 1)?.first)
        try file.seek(toOffset: 1_000)
        try file.write(contentsOf: Data([original ^ 0x01]))
        try file.close()
        #expect(throws: VoiceLabAssetError.altered(asset.file)) {
            try VoiceLabAssets.prepare(project: project, plan: plan, paidRoot: paid)
        }
    }

    @Test func existingNameIsRefusedBeforeAnyByteIsWritten() throws {
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let first = try VoiceLabAssetStore.write(pcm16: tone(frames: 2_400, rate: 24_000), sampleRate: 24_000, projectId: projectId,
                                                 assetId: "take-1", paidRoot: paid, createdAt: createdAt)
        let url = paid.appendingPathComponent(first.file)
        let before = try Data(contentsOf: url)
        let identity = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        #expect(throws: VoiceLabAssetStoreError.alreadyExists(first.file)) {
            try VoiceLabAssetStore.write(pcm16: pcm([7, 7]), sampleRate: 24_000, projectId: projectId,
                                         assetId: "take-1", paidRoot: paid, createdAt: createdAt)
        }
        #expect(throws: VoiceLabAssetStoreError.alreadyExists(first.file)) {
            try VoiceLabAssetStore.writeDerived(samples: [0.5], sampleRate: 48_000, projectId: projectId,
                                                assetId: "take-1", paidRoot: paid, createdAt: createdAt)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int == identity)

        // A link at the final name is an existing entry too: it is neither followed nor replaced.
        let outside = data.appendingPathComponent("outside.wav")
        try Data("outside".utf8).write(to: outside)
        let link = paid.appendingPathComponent(projectId).appendingPathComponent("take-2.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: VoiceLabAssetStoreError.alreadyExists("\(projectId)/take-2.wav")) {
            try VoiceLabAssetStore.write(pcm16: pcm([1]), sampleRate: 24_000, projectId: projectId,
                                         assetId: "take-2", paidRoot: paid, createdAt: createdAt)
        }
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
        // So are a directory and a FIFO, which is not opened.
        let folder = paid.appendingPathComponent(projectId).appendingPathComponent("take-3.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(mkfifo(paid.appendingPathComponent(projectId).appendingPathComponent("take-4.wav").path, 0o600) == 0)
        for asset in ["take-3", "take-4"] {
            #expect(throws: VoiceLabAssetStoreError.alreadyExists("\(projectId)/\(asset).wav")) {
                try VoiceLabAssetStore.write(pcm16: pcm([1]), sampleRate: 24_000, projectId: projectId,
                                             assetId: asset, paidRoot: paid, createdAt: createdAt)
            }
        }
        // The check comes before the temporary file, so an existing name in a folder that cannot take one is still
        // alreadyExists, while a new name there is unwritable.
        let project = paid.appendingPathComponent(projectId)
        #expect(chmod(project.path, 0o500) == 0)
        #expect(throws: VoiceLabAssetStoreError.alreadyExists(first.file)) {
            try VoiceLabAssetStore.write(pcm16: tone(frames: 2_400, rate: 24_000), sampleRate: 24_000, projectId: projectId,
                                         assetId: "take-1", paidRoot: paid, createdAt: createdAt)
        }
        #expect(throws: VoiceLabAssetStoreError.unwritable("\(projectId)/take-5.wav")) {
            try VoiceLabAssetStore.write(pcm16: pcm([1]), sampleRate: 24_000, projectId: projectId,
                                         assetId: "take-5", paidRoot: paid, createdAt: createdAt)
        }
        #expect(chmod(project.path, 0o700) == 0)
        #expect(try entries(project) == ["take-1.wav", "take-2.wav", "take-3.wav", "take-4.wav"])
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func concurrentWritersOfOneAssetPublishItExactlyOnce() async throws {
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let projectId = self.projectId, createdAt = self.createdAt
        let outcomes = await withTaskGroup(of: (Int, VoiceLabAsset?, VoiceLabAssetStoreError?).self) { group in
            for writer in 0..<8 {
                group.addTask {
                    let samples = [Float](repeating: Float(writer + 1) / 16, count: 48_000)
                    do {
                        let asset = try VoiceLabAssetStore.writeDerived(samples: samples, sampleRate: 48_000, projectId: projectId,
                                                                        assetId: "race", paidRoot: paid, createdAt: createdAt)
                        return (writer, asset, nil)
                    } catch let error as VoiceLabAssetStoreError { return (writer, nil, error) }
                    catch { return (writer, nil, .unwritable("unexpected \(error)")) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let winners = outcomes.filter { $0.1 != nil }
        #expect(winners.count == 1)
        #expect(outcomes.filter { $0.2 == .alreadyExists("\(projectId)/race.wav") }.count == 7)
        let winner = try #require(winners.first)
        let published = try Data(contentsOf: paid.appendingPathComponent("\(projectId)/race.wav"))
        let value = VoiceLabAssetStore.pcm16(Float(winner.0 + 1) / 16)
        let expected = VoiceLabAssetStore.wavHeader(frames: 48_000, sampleRate: 48_000) + pcm([Int16](repeating: value, count: 48_000))
        #expect(published == expected)
        #expect(hex(published) == winner.1?.sha256)
        #expect(try entries(paid.appendingPathComponent(projectId)) == ["race.wav"])
    }

    @Test func fullSyncFlushesFilesAndDirectoriesAndKeepsRealErrors() throws {
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let probe = paid.appendingPathComponent("probe")
        try Data([1]).write(to: probe)
        let file = open(probe.path, O_RDONLY | O_CLOEXEC), directory = open(paid.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(file); close(directory) }
        #expect(file >= 0 && directory >= 0)
        #expect(VoiceLabPaidRoot.fullSync(file) && VoiceLabPaidRoot.fullSync(directory))
        // Only ENOTSUP and EINVAL fall back to fsync; a bad descriptor stays a failure.
        #expect(!VoiceLabPaidRoot.fullSync(-1))
    }

    @Test func failuresAfterPublishKeepTheFileAndSayWhetherItWasConfirmed() throws {
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let samples = tone(frames: 2_400, rate: 24_000)
        func write(_ assetId: String, afterPublish: @escaping () -> Void) throws {
            _ = try VoiceLabAssetStore.write(pcm16: samples, sampleRate: 24_000, projectId: projectId, assetId: assetId,
                                             paidRoot: paid, createdAt: createdAt, afterPublish: afterPublish)
        }
        // Unreadable once published: kept, and reported as saved but unconfirmed rather than unwritable.
        let locked = paid.appendingPathComponent("\(projectId)/locked.wav")
        #expect(throws: VoiceLabAssetStoreError.publishedUnverified("\(projectId)/locked.wav")) {
            try write("locked") { _ = chmod(locked.path, 0) }
        }
        #expect(chmod(locked.path, 0o600) == 0)
        #expect(try Data(contentsOf: locked) == VoiceLabAssetStore.wavHeader(frames: 2_400, sampleRate: 24_000) + samples)
        // The caller re-hashes the kept file; writing the same asset again is refused.
        #expect(throws: VoiceLabAssetStoreError.alreadyExists("\(projectId)/locked.wav")) { try write("locked") {} }

        // Different bytes at the name once published are altered, and that file is kept too.
        let changed = paid.appendingPathComponent("\(projectId)/changed.wav")
        #expect(throws: VoiceLabAssetStoreError.altered("\(projectId)/changed.wav")) {
            try write("changed") {
                guard let handle = try? FileHandle(forUpdating: changed) else { return }
                defer { try? handle.close() }
                try? handle.seek(toOffset: 100)
                let byte = (try? handle.read(upToCount: 1))?.first ?? 0
                try? handle.seek(toOffset: 100)
                try? handle.write(contentsOf: Data([byte ^ 0x01]))
            }
        }
        #expect(try entries(paid.appendingPathComponent(projectId)) == ["changed.wav", "locked.wav"])
        #expect(VoiceLabAssetStoreError.publishedUnverified("x").errorDescription?
            .contains("saved but could not be confirmed; the file was kept") == true)
    }

    @Test func rootMustBeADirectoryAndComponentsBelowItCannotBeLinks() throws {
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let file = "\(projectId)/take.wav"
        func write(_ root: URL) throws -> VoiceLabAsset {
            try VoiceLabAssetStore.write(pcm16: pcm([1, 2]), sampleRate: 24_000, projectId: projectId,
                                         assetId: "take", paidRoot: root, createdAt: createdAt)
        }
        let regular = data.appendingPathComponent("regular")
        try Data().write(to: regular)
        #expect(throws: VoiceLabAssetStoreError.unsafePath(file)) { try write(regular) }

        let elsewhere = data.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: paid.appendingPathComponent(projectId), withDestinationURL: elsewhere)
        #expect(throws: VoiceLabAssetStoreError.unsafePath(file)) { try write(paid) }
        #expect(try entries(elsewhere).isEmpty)
        try FileManager.default.removeItem(at: paid.appendingPathComponent(projectId))
        try Data().write(to: paid.appendingPathComponent(projectId))
        #expect(throws: VoiceLabAssetStoreError.unsafePath(file)) { try write(paid) }
        try FileManager.default.removeItem(at: paid.appendingPathComponent(projectId))

        // The root itself resolves as VoiceLabAssets.prepare resolves it.
        let linkedRoot = data.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: paid)
        let asset = try write(linkedRoot)
        #expect(try entries(paid.appendingPathComponent(projectId)) == ["take.wav"])
        #expect(try Data(contentsOf: paid.appendingPathComponent(asset.file)).count == 48)
    }

    @Test func missingPaidRootIsCreatedButNeverItsDataFolder() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-vl-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let paid = DataLocations(environment: ["VOXCLIP_DATA_DIR": data.path]).root.appendingPathComponent("VoiceLab", isDirectory: true)
        let file = "\(projectId)/take.wav"
        func write() throws -> VoiceLabAsset {
            try VoiceLabAssetStore.write(pcm16: pcm([1, 2]), sampleRate: 24_000, projectId: projectId,
                                         assetId: "take", paidRoot: paid, createdAt: createdAt)
        }
        // A missing data folder is its own error, and nothing is created for it.
        #expect(throws: VoiceLabAssetStoreError.rootMissing(file)) { try write() }
        #expect(!FileManager.default.fileExists(atPath: data.path))

        // With the data folder present, the first write creates VoiceLab with mode 0700.
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        let asset = try write()
        var info = stat()
        let status = stat(paid.path, &info)
        #expect(status == 0 && info.st_mode & 0o777 == 0o700)
        #expect(try Data(contentsOf: paid.appendingPathComponent(asset.file)).count == 48)

        // A dangling link in its place is refused, and the link's target is not created.
        try FileManager.default.removeItem(at: paid)
        let target = data.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: paid, withDestinationURL: target)
        #expect(throws: VoiceLabAssetStoreError.unsafePath(file)) { try write() }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try entries(data) == ["VoiceLab"])
    }

    @Test func boundsAndNamesAreRefusedBeforeAnyFileIsCreated() throws {
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let file = "\(projectId)/take.wav"
        func write(_ bytes: Data, rate: Int = 24_000, project: String? = nil, asset: String = "take") throws {
            _ = try VoiceLabAssetStore.write(pcm16: bytes, sampleRate: rate, projectId: project ?? projectId,
                                             assetId: asset, paidRoot: paid, createdAt: createdAt)
        }
        #expect(throws: VoiceLabAssetStoreError.invalidAudio(file)) { try write(Data([1])) }
        #expect(throws: VoiceLabAssetStoreError.invalidAudio(file)) { try write(Data([1, 2, 3])) }
        #expect(throws: VoiceLabAssetStoreError.invalidAudio(file)) { try write(Data()) }
        #expect(throws: VoiceLabAssetStoreError.invalidAudio(file)) {
            try VoiceLabAssetStore.writeDerived(samples: [], sampleRate: 24_000, projectId: projectId,
                                                assetId: "take", paidRoot: paid, createdAt: createdAt)
        }
        #expect(throws: VoiceLabAssetStoreError.invalidAudio(file)) { try write(pcm([1]), rate: 7_999) }
        #expect(throws: VoiceLabAssetStoreError.invalidAudio(file)) { try write(pcm([1]), rate: 192_001) }
        for asset in ["Take", "con", "../take", "take.wav", ""] {
            #expect(throws: VoiceLabProjectError.invalidAsset) { try write(pcm([1]), asset: asset) }
        }
        #expect(throws: VoiceLabProjectError.invalidAsset) { try write(pcm([1]), project: projectId.uppercased()) }
        #expect(try entries(paid).isEmpty)

        // The RIFF size field is the binding limit, and it keeps every accepted length inside §10.4.
        #expect(VoiceLabAssetStore.maxFrames == 2_147_483_629)
        #expect(36 + 2 * VoiceLabAssetStore.maxFrames <= Int(UInt32.max) && 36 + 2 * (VoiceLabAssetStore.maxFrames + 1) > Int(UInt32.max))
        #expect(Int64(VoiceLabAssetStore.maxFrames) <= VoiceLabAssets.maxFrames)
        #expect(Int64(44 + 2 * VoiceLabAssetStore.maxFrames) <= VoiceLabAssets.maxBytes)
        try VoiceLabAssetStore.validate(frames: VoiceLabAssetStore.maxFrames, sampleRate: 8_000, file: file)
        #expect(throws: VoiceLabAssetStoreError.tooLarge(file)) {
            try VoiceLabAssetStore.validate(frames: VoiceLabAssetStore.maxFrames + 1, sampleRate: 8_000, file: file)
        }

        try write(pcm([1]), rate: 8_000, asset: "low")
        try write(pcm([1]), rate: 192_000, asset: "high")
        #expect(try entries(paid.appendingPathComponent(projectId)) == ["high.wav", "low.wav"])
    }

    @Test func cancellationRemovesOnlyTheTemporaryFile() async throws {
        let (data, paid) = try store()
        defer { try? FileManager.default.removeItem(at: data) }
        let projectId = self.projectId, createdAt = self.createdAt
        let kept = try VoiceLabAssetStore.write(pcm16: pcm([1, 2, 3]), sampleRate: 24_000, projectId: projectId,
                                                assetId: "kept", paidRoot: paid, createdAt: createdAt)
        let keptBytes = try Data(contentsOf: paid.appendingPathComponent(kept.file))
        let cancelled = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try VoiceLabAssetStore.writeDerived(samples: [Float](repeating: 0.25, count: 100_000), sampleRate: 48_000,
                                                        projectId: projectId, assetId: "cancelled", paidRoot: paid,
                                                        createdAt: createdAt)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(cancelled)
        #expect(try entries(paid.appendingPathComponent(projectId)) == ["kept.wav"])
        #expect(try Data(contentsOf: paid.appendingPathComponent(kept.file)) == keptBytes)
    }
}
