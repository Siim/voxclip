import Darwin
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

@Suite("Lip-sync local result validation", .timeLimit(.minutes(1)), .offlineFixtures)
struct LipsyncResultValidationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("lipsync-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func box(_ kind: String, _ payload: Data) -> Data {
        let size = UInt32(payload.count + 8)
        return Data([UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                     UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)]) + Data(kind.utf8) + payload
    }

    private func container(external: Bool = false) -> Data {
        let reference = box("url ", external ? Data([0, 0, 0, 0]) + Data("https://127.0.0.1/private\0".utf8) : Data([0, 0, 0, 1]))
        let references = box("dref", Data([0, 0, 0, 0, 0, 0, 0, 1]) + reference)
        let movie = box("moov", box("trak", box("mdia", box("minf", box("dinf", references)))))
        return box("ftyp", Data("isom".utf8) + Data([0, 0, 0, 0])) + movie + box("mdat", Data([0]))
    }

    private func inspect(_ bytes: Data, root: URL) throws {
        let url = root.appendingPathComponent("container.mp4")
        try bytes.write(to: url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LipsyncError.unsafeFile }
        defer { close(descriptor) }
        try LipsyncResultValidation.inspectContainer(descriptor: descriptor, size: bytes.count)
    }

    @Test func containerRejectsExternalDataReferencesBeforeAVFoundation() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try inspect(container(), root: root)
        #expect(throws: LipsyncError.invalidMedia) { try inspect(container(external: true), root: root) }
    }

    @Test func malformedBoxesMissingReferencesAndReferenceMoviesFailClosed() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for bytes in [Data([0, 0, 0, 7]) + Data("ftyp".utf8), container().dropLast(),
                      box("ftyp", Data(repeating: 0, count: 8)) + box("moov", Data()) + box("mdat", Data([0])),
                      container() + box("rmra", Data()), container() + box("moov", Data())] {
            #expect(throws: LipsyncError.invalidMedia) { try inspect(Data(bytes), root: root) }
        }
    }

    @Test func oversizedExtendedBoxDoesNotAllocateItsClaimedSize() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let malicious = Data([0, 0, 0, 1]) + Data("moov".utf8) + Data(repeating: 255, count: 8)
        #expect(throws: LipsyncError.invalidMedia) { try inspect(malicious, root: root) }
    }

    @Test func dimensionsRateAndDurationAreBoundToTheSourceWindow() throws {
        let valid = LipsyncVideoMetadata(durationSeconds: 10, frameRate: 30, width: 1_920, height: 1_080, byteCount: 1_200)
        try LipsyncResultValidation.validate(valid, durationSeconds: 10, fps: 30, width: 1_920, height: 1_080)
        for invalid in [
            LipsyncVideoMetadata(durationSeconds: .nan, frameRate: 30, width: 1_920, height: 1_080, byteCount: 1_200),
            LipsyncVideoMetadata(durationSeconds: 10.1, frameRate: 30, width: 1_920, height: 1_080, byteCount: 1_200),
            LipsyncVideoMetadata(durationSeconds: 10, frameRate: 25, width: 1_920, height: 1_080, byteCount: 1_200),
            LipsyncVideoMetadata(durationSeconds: 10, frameRate: 30, width: 1_280, height: 720, byteCount: 1_200),
            LipsyncVideoMetadata(durationSeconds: 10, frameRate: 30, width: 1_920, height: 1_080, byteCount: LipsyncLimits.maximumVideoBytes + 1)
        ] {
            #expect(throws: LipsyncError.invalidMedia) {
                try LipsyncResultValidation.validate(invalid, durationSeconds: 10, fps: 30, width: 1_920, height: 1_080)
            }
        }
    }

    @Test func symlinksDirectoriesAndHardlinksAreRejectedAsLocalResults() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.mp4"), linked = root.appendingPathComponent("linked.mp4")
        try container().write(to: original)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: original)
        await #expect(throws: LipsyncError.unsafeFile) {
            _ = try await LipsyncResultValidation.validate(file: linked, durationSeconds: 10, fps: 30, width: 1_920, height: 1_080)
        }
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.linkItem(at: original, to: linked)
        await #expect(throws: LipsyncError.invalidMedia) {
            _ = try await LipsyncResultValidation.validate(file: linked, durationSeconds: 10, fps: 30, width: 1_920, height: 1_080)
        }
        await #expect(throws: LipsyncError.invalidMedia) {
            _ = try await LipsyncResultValidation.validate(file: root, durationSeconds: 10, fps: 30, width: 1_920, height: 1_080)
        }
    }

    @Test func cancelledValidationCannotReturnAUsableResult() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("result.mp4"); try container().write(to: file)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LipsyncResultValidation.validate(file: file, durationSeconds: 10, fps: 30, width: 1_920, height: 1_080)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func resultRecipeCarriesOnlyIDsAndContentProvenanceNotSignedURLs() throws {
        let quoteID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let hash = String(repeating: "a", count: 64)
        let provenance = LipsyncResultProvenance(provider: "fal", model: "fal-ai/sync-lipsync/v2:lipsync-2", requestID: "fixture-request",
                                                quoteID: quoteID, videoInputSHA256: hash, audioInputSHA256: hash, outputSHA256: hash,
                                                syncMode: .remap, seed: nil, submittedAt: Date(timeIntervalSince1970: 1_000),
                                                importedAt: Date(timeIntervalSince1970: 1_100),
                                                estimate: CostEstimate(provider: "fal", operation: "lipsync", units: 10, unit: "second", usd: Decimal(string: "0.5"), basis: "list-2026-10-25"))
        let result = ImportedLipsyncResult(asset: VoiceLabVideoAsset(id: "fixture-asset", file: "fixture-project/fixture-asset.mp4", sha256: hash,
                                                                  durationSeconds: 10, frameRate: 30, width: 1_920, height: 1_080),
                                          url: URL(fileURLWithPath: "/private/tmp/fixture.mp4"), provenance: provenance)
        let recipe = try result.videoRecipe(sourceStartSample: 48_000, sourceEndSample: 432_000, outputSamples: 384_000,
                                             windowStartSample: 0, windowEndSample: 480_000)
        #expect(recipe.mode == .lipsync); #expect(recipe.assetId == result.asset.id)
        #expect(recipe.provider == "fal"); #expect(recipe.model == provenance.model); #expect(recipe.requestId == provenance.requestID)
        #expect(recipe.windowStartSample == 0); #expect(recipe.windowEndSample == 480_000); #expect(recipe.syncMode == "remap")
        let encoded = String(decoding: try JSONEncoder().encode(provenance), as: UTF8.self)
        #expect(!encoded.contains("https:")); #expect(!encoded.contains("X-Amz")); #expect(!encoded.contains("Authorization"))
        #expect(throws: LipsyncError.invalidInput) {
            _ = try result.videoRecipe(sourceStartSample: 48_000, sourceEndSample: 432_000, outputSamples: 384_000,
                                       windowStartSample: 96_000, windowEndSample: 480_000)
        }
    }
}
