import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite struct VoiceLabDisclosureTests {
    private func project(_ name: String) throws -> Project {
        try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/\(name).voxclip"))
    }
    private func prepared(_ name: String, scope: VoiceLabOutputScope = .full) throws -> (Project, VoiceLabPreparedRender) {
        let value = try project(name)
        return (value, try VoiceLabRenderContract.prepare(value, scope: scope, labelPosition: .topRight))
    }
    private func font() throws -> URL { try FixtureLoader.sharedRoot().appendingPathComponent("fonts/dm-sans/DMSans-Bold.ttf") }

    @Test func narrowFrameRejectsMarginsForEveryCornerAndCollision() throws {
        let value = try project("full-take-render-v3")
        for position: VoiceLabLabelPosition in [.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let disclosure = try VoiceLabRenderContract.prepare(value, scope: .full, labelPosition: position).disclosure
            for blocks: [VoiceLabDisclosureCaptionBlock] in [[],
                [.init(start: 0, end: 7, bounds: CGRect(x: 0, y: 0, width: 195, height: 200))]] {
                #expect(throws: VoiceLabDisclosureError.invalidFrame) {
                    try VoiceLabDisclosureOverlay(plan: disclosure, width: 195, height: 1000,
                                                  fontURL: font(), captionBlocks: blocks)
                }
            }
        }
    }

    @Test func preflightDefaultsToTopRightAndCollisionMovesToTheOppositeTopCorner() throws {
        // Which top corners the chip darkens on row 70 of a white 1000 × 1000 frame at 0.3 s.
        func corners(_ disclosure: VoiceLabDisclosurePlan, _ blocks: [VoiceLabDisclosureCaptionBlock]) throws -> [Bool] {
            let overlay = try VoiceLabDisclosureOverlay(plan: disclosure, width: 1000, height: 1000, fontURL: font(), captionBlocks: blocks)
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 1000, 1000, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            let frame = try #require(buffer)
            CVPixelBufferLockBaseAddress(frame, [])
            if let raw = CVPixelBufferGetBaseAddress(frame) { memset(raw, 255, CVPixelBufferGetDataSize(frame)) }
            CVPixelBufferUnlockBaseAddress(frame, [])
            try overlay.draw(into: frame, at: 0.3)
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            let raw = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(frame)
            return [50..<500, 500..<1000].map { columns in columns.contains { raw[70 * stride + $0 * 4] < 255 } }
        }
        let value = try project("full-take-render-v3")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-unused-paid-root", isDirectory: true)
        let input = try #require(try VoiceLabRenderPreflight.prepare(project: value, scope: .full, paidRoot: root))
        #expect(input.labelPosition == .topRight && input.prepared.disclosure.position == .topRight)
        let rightCaption = VoiceLabDisclosureCaptionBlock(start: 2, end: 4, bounds: CGRect(x: 500, y: 0, width: 500, height: 200))
        #expect(try corners(input.prepared.disclosure, []) == [false, true])
        #expect(try corners(input.prepared.disclosure, [rightCaption]) == [true, false])
        // An explicit position is still honoured, and moves to the other top corner the same way.
        let left = try #require(try VoiceLabRenderPreflight.prepare(project: value, scope: .full, paidRoot: root, labelPosition: .topLeft))
        #expect(left.prepared.disclosure.position == .topLeft)
        let leftCaption = VoiceLabDisclosureCaptionBlock(start: 2, end: 4, bounds: CGRect(x: 0, y: 0, width: 500, height: 200))
        #expect(try corners(left.prepared.disclosure, []) == [true, false])
        #expect(try corners(left.prepared.disclosure, [leftCaption]) == [false, true])
    }

    @Test func nonfiniteCaptionBlocksCannotSkipIntervalCollision() throws {
        let disclosure = try prepared("full-take-render-v3").1.disclosure
        for block in [VoiceLabDisclosureCaptionBlock(start: .nan, end: 7,
                                                     bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                      .init(start: 0, end: 7, bounds: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100))] {
            #expect(throws: VoiceLabDisclosureError.invalidFrame) {
                try VoiceLabDisclosureOverlay(plan: disclosure, width: 1000, height: 1000,
                                              fontURL: font(), captionBlocks: [block])
            }
        }
    }

    @Test func intervalsFadesAndIntervalWideCollision() throws {
        let at = try prepared("disclosure-at-30-render-v3").1
        let above = try prepared("disclosure-above-30-render-v3").1
        let half = try prepared("voice-changer-half-render-v3").1
        let whole = try prepared("full-take-render-v3").1
        #expect(!at.disclosure.persistent && above.disclosure.persistent && half.disclosure.persistent)
        #expect(whole.disclosure.intervals.count == 1 && whole.disclosure.intervals[0].start == 0 && whole.disclosure.intervals[0].end == 7)
        let overlay = try VoiceLabDisclosureOverlay(plan: whole.disclosure, width: 1000, height: 1000, fontURL: font(),
            captionBlocks: [.init(start: 2, end: 4, bounds: CGRect(x: 500, y: 0, width: 500, height: 200))])
        #expect(overlay.opacity(at: 0) == 0)
        #expect(abs(overlay.opacity(at: 0.075) - 0.5) < 0.001)
        #expect(overlay.opacity(at: 0.15) == 1)
        #expect(abs(overlay.opacity(at: 6.925) - 0.5) < 0.001)
        #expect(overlay.opacity(at: 7) == 0)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 1000, 1000, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        if let raw = CVPixelBufferGetBaseAddress(frame) { memset(raw, 255, CVPixelBufferGetDataSize(frame)) }
        CVPixelBufferUnlockBaseAddress(frame, [])
        try overlay.draw(into: frame, at: 0.3)
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        let raw = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        let leftDark = (50..<500).contains { raw[70 * stride + $0 * 4] < 255 }
        let rightDark = (500..<1000).contains { raw[70 * stride + $0 * 4] < 255 }
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        #expect(leftDark && !rightDark)
        if let evidence = ProcessInfo.processInfo.environment["VOXCLIP_DISCLOSURE_EVIDENCE"] {
            try FileManager.default.createDirectory(atPath: evidence, withIntermediateDirectories: true)
            let image = CIImage(cvPixelBuffer: frame)
            try CIContext(options: [.workingColorSpace: NSNull()]).writePNGRepresentation(of: image,
                to: URL(fileURLWithPath: evidence).appendingPathComponent("mac-offscreen-synthetic-disclosure.png"),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        #expect(try prepared("passage-render-v3", scope: .clip("clip-main")).1.disclosure.required)
        let passage = try project("passage-render-v3")
        let disabled = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: passage)
        #expect(try !VoiceLabRenderContract.prepare(disabled, scope: .full, labelPosition: .topRight).disclosure.required)
    }

    @Test func realMP4XMPAndFinalHashAreIndependentOfExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-disclosure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("native.mp4")
        try await nativeMP4(native)
        if let evidence = ProcessInfo.processInfo.environment["VOXCLIP_DISCLOSURE_EVIDENCE"] {
            try FileManager.default.createDirectory(atPath: evidence, withIntermediateDirectories: true)
            let copy = URL(fileURLWithPath: evidence).appendingPathComponent("mac-native-synthetic-input.mp4")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: native, to: copy)
        }
        let stage = root.appendingPathComponent("render.mp4.partial")
        let destination = root.appendingPathComponent("render.mp4")
        try Data("prior destination".utf8).write(to: destination)
        let (project, prepared) = try prepared("passage-render-v3")
        let result = try VoiceLabDisclosureWriter.stage(sourceMP4: native, stagedMP4: stage, finalFilename: "render.mp4",
            project: project, prepared: prepared, appVersion: "0.1.0", createdAt: Date(timeIntervalSince1970: 1_792_998_000.0625))
        #expect(try Data(contentsOf: destination) == Data("prior destination".utf8))
        #expect(result.sidecarFilename == "render.mp4.provenance.json")
        let bytes = try Data(contentsOf: stage)
        #expect(result.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(VoiceLabDisclosureWriter.isLabelled(stage) && !VoiceLabDisclosureWriter.isLabelled(native))
        let packet = try extractTopLevelXMP(bytes)
        let xml = try XMLDocument(data: packet)
        #expect(try xml.nodes(forXPath: "//*[local-name()='Description']/@*[local-name()='DigitalSourceType']").first?.stringValue == VoiceLabDisclosureWriter.digitalSourceType)
        let inspect = root.appendingPathComponent("inspect.mp4")
        try FileManager.default.copyItem(at: stage, to: inspect)
        #expect(try await AVURLAsset(url: inspect).loadTracks(withMediaType: .video).count == 1)
        if let evidence = ProcessInfo.processInfo.environment["VOXCLIP_DISCLOSURE_EVIDENCE"] {
            let copy = URL(fileURLWithPath: evidence).appendingPathComponent("mac-staged-synthetic-disclosure.mp4")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: stage, to: copy)
            try result.sidecarData.write(to: URL(fileURLWithPath: evidence).appendingPathComponent("mac-staged-synthetic-disclosure.provenance.json"))
        }
        let sidecar = try #require(JSONSerialization.jsonObject(with: result.sidecarData) as? [String: Any])
        let export = try #require(sidecar["export"] as? [String: Any])
        #expect(export["file"] as? String == "render.mp4")
        #expect(export["sha256"] as? String == result.sha256)
        // 62.5 ms is an exact half, so the sidecar shows the later millisecond (editing.md §10.1).
        #expect(export["createdAt"] as? String == "2026-10-26T07:00:00.063Z")
        let segments = try #require(sidecar["aiSegments"] as? [[String: Any]])
        #expect(segments.map { $0["generatedAt"] as? String } == ["2026-10-25T12:10:00.000Z"])
        let consent = try #require(sidecar["consent"] as? [[String: Any]])
        #expect(consent.map { $0["verifiedAt"] as? String } == ["2026-10-25T12:09:00.000Z"])
        #expect(!(String(data: result.sidecarData, encoding: .utf8) ?? "").contains(project.media.source.absolutePath))
        #expect(throws: VoiceLabDisclosureError.self) {
            try VoiceLabDisclosureWriter.stage(sourceMP4: native, stagedMP4: stage, finalFilename: "render.mp4",
                project: project, prepared: prepared, appVersion: "0.1.0")
        }
        let repeated = root.appendingPathComponent("repeated.mp4.partial")
        #expect(throws: VoiceLabDisclosureError.existingXMP) {
            try VoiceLabDisclosureWriter.stage(sourceMP4: stage, stagedMP4: repeated, finalFilename: "render.mp4",
                project: project, prepared: prepared, appVersion: "0.1.0")
        }
        #expect(!FileManager.default.fileExists(atPath: repeated.path))
        let sizeZero = root.appendingPathComponent("size-zero-final-mdat.mp4")
        var sizeZeroBytes = try Data(contentsOf: native)
        sizeZeroBytes.append(contentsOf: [0, 0, 0, 0, 0x6d, 0x64, 0x61, 0x74])
        try sizeZeroBytes.write(to: sizeZero)
        let rejected = root.appendingPathComponent("size-zero-stage.mp4.partial")
        #expect(throws: VoiceLabDisclosureError.invalidMP4) {
            try VoiceLabDisclosureWriter.stage(sourceMP4: sizeZero, stagedMP4: rejected, finalFilename: "render.mp4",
                project: project, prepared: prepared, appVersion: "0.1.0")
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
        let paid = root.appendingPathComponent("paid-input.wav")
        let paidBytes = Data("paid input must survive failed staging".utf8)
        try paidBytes.write(to: paid)
        let failed = root.appendingPathComponent("failed.mp4.partial")
        #expect(throws: VoiceLabDisclosureError.invalidMP4) {
            try VoiceLabDisclosureWriter.stage(sourceMP4: paid, stagedMP4: failed, finalFilename: "render.mp4",
                project: project, prepared: prepared, appVersion: "0.1.0")
        }
        #expect(try Data(contentsOf: paid) == paidBytes)
        #expect(!VoiceLabDisclosureWriter.isLabelled(paid) && !VoiceLabDisclosureWriter.isLabelled(sizeZero))
        #expect(!FileManager.default.fileExists(atPath: failed.path))
        #expect(try Data(contentsOf: destination) == Data("prior destination".utf8))
        #expect(FileManager.default.fileExists(atPath: native.path))
        let cancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            let cancelledStage = root.appendingPathComponent("cancel.mp4.partial")
            do {
                _ = try VoiceLabDisclosureWriter.stage(sourceMP4: native, stagedMP4: cancelledStage,
                    finalFilename: "render.mp4", project: project, prepared: prepared, appVersion: "0.1.0")
                return false
            } catch is CancellationError {
                return !FileManager.default.fileExists(atPath: cancelledStage.path)
            } catch { return false }
        }.value
        #expect(cancelled)
    }

    /// voice-lab.md §6.5.1: own-voice training refuses media whose XMP names a trained-algorithmic source, in the
    /// top-level UUID box or in QuickTime's `moov/udta/XMP_`, and ignores other boxes.
    @Test func trainedAlgorithmicXMPLabelsAFileInEitherPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-label-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func box(_ kind: String, _ body: Data) -> Data {
            var data = Data(withUnsafeBytes(of: UInt32(8 + body.count).bigEndian, Array.init)); data.append(Data(kind.utf8)); data.append(body); return data
        }
        let xmpUUID = Data([0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8, 0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac])
        let generated = VoiceLabDisclosureWriter.xmpPacket()
        let camera = Data(String(decoding: generated, as: UTF8.self).replacingOccurrences(of: "compositeWithTrainedAlgorithmicMedia", with: "digitalCapture").utf8)
        let head = box("ftyp", Data("isom".utf8) + Data(count: 4))
        let cases: [(Data, Bool)] = [
            (head + box("moov", box("trak", Data(count: 8))) + box("mdat", Data(count: 16)) + box("uuid", xmpUUID + generated), true),
            (head + box("moov", box("udta", box("XMP_", generated))) + box("mdat", Data(count: 16)), true),
            (head + box("moov", Data()) + box("uuid", xmpUUID + camera), false),
            (head + box("moov", Data()) + box("uuid", Data(count: 16) + generated), false),
            (head + box("free", generated), false),
        ]
        for (index, (bytes, labelled)) in cases.enumerated() {
            let url = root.appendingPathComponent("case-\(index).mp4")
            try bytes.write(to: url)
            #expect(VoiceLabDisclosureWriter.isLabelled(url) == labelled)
        }
        #expect(!VoiceLabDisclosureWriter.isLabelled(root.appendingPathComponent("missing.mp4")))
    }

    @Test(arguments: [false, true])
    func failedDisclosureKeepsReplacementDirectoriesAndCallerFiles(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("native.mp4"), stage = root.appendingPathComponent("stage.mp4.partial")
        try await nativeMP4(native)
        let (project, prepared) = try prepared("passage-render-v3")
        let original = root.appendingPathComponent("original")
        var replacement: URL?
        do {
            _ = try VoiceLabDisclosureWriter.stage(sourceMP4: native, stagedMP4: stage, finalFilename: "render.mp4",
                project: project, prepared: prepared, appVersion: "0.1.0", createdAt: Date(timeIntervalSince1970: 0), afterCopy: { directory in
                    replacement = directory
                    try FileManager.default.moveItem(at: directory, to: original)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    try Data("keep".utf8).write(to: directory.appendingPathComponent("user.txt"))
                    try Data("caller replacement".utf8).write(to: stage)
                    if cancel { throw CancellationError() }
                })
            Issue.record("Cancellation or a destination collision must refuse publication")
        } catch is CancellationError { #expect(cancel) }
        catch VoiceLabDisclosureError.destinationExists { #expect(!cancel) }
        let directory = try #require(replacement)
        #expect(try Data(contentsOf: directory.appendingPathComponent("user.txt")) == Data("keep".utf8))
        #expect(try Data(contentsOf: stage) == Data("caller replacement".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: native.path))
    }

    private func nativeMP4(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let frame = buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(frame, [])
        if let raw = CVPixelBufferGetBaseAddress(frame) { memset(raw, 0, CVPixelBufferGetDataSize(frame)) }
        CVPixelBufferUnlockBaseAddress(frame, [])
        guard adaptor.append(frame, withPresentationTime: .zero) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    // Independent ISO BMFF box walk, separate from the production stage parser and encoder.
    private func extractTopLevelXMP(_ bytes: Data) throws -> Data {
        let uuid = Data([0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8, 0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac])
        var offset = 0
        while offset + 8 <= bytes.count {
            let size32 = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let size: Int
            if size32 == 1 {
                guard offset + 16 <= bytes.count else { throw VoiceLabDisclosureError.invalidMP4 }
                size = bytes[(offset + 8)..<(offset + 16)].reduce(0) { ($0 << 8) | Int($1) }
            } else { size = size32 == 0 ? bytes.count - offset : size32 }
            guard size >= (size32 == 1 ? 16 : 8), offset + size <= bytes.count else { throw VoiceLabDisclosureError.invalidMP4 }
            if String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self) == "uuid", size >= 24,
               bytes[(offset + 8)..<(offset + 24)] == uuid {
                return bytes[(offset + 24)..<(offset + size)]
            }
            offset += size
        }
        throw VoiceLabDisclosureError.invalidMP4
    }
}
