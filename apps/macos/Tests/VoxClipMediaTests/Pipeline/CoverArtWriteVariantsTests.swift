import AVFoundation
import CoreGraphics
import ImageIO
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VoxClipCore
@testable import VoxClipMedia

/// A diagnostic for the MP4's cover art on each macOS (doc/publishing.md §7): on the macOS 26 CI runner the writer's
/// iTunes `covr` never reached the file, while macOS 27 embeds it. Each candidate write makes a one-second MP4 with a
/// small JPEG as its art and reads the file's bytes for a `covr` atom holding that JPEG. It reports, and fails only when
/// the exporter's own write does not embed on macOS 27. Read the lines `cover-art-variant: …` in the test log.
@Suite("Cover art write variants (diagnostic)", .serialized)
struct CoverArtWriteVariantsTests {
    enum Form: String { case identifier, keySpace }
    enum DataType: String { case jpeg, rawData, none }
    enum Timing: String { case beforeInputs, afterInputs }

    struct Variant: CustomStringConvertible {
        var name: String
        var form: Form = .identifier
        var dataType: DataType = .jpeg
        var timing: Timing = .beforeInputs
        var optimized = true
        /// The exporter's writer settings: `movieTimeScale` 48000 and its own temporary directory.
        var exporterSettings = false
        /// The art goes in through `AVAssetExportSession` remuxing a plain file, not the writer.
        var exportSession = false
        var description: String { name }
    }

    /// In the brief's order: the key form, raw data, the metadata's timing, the export session; then what the exporter
    /// had before (`identifier`, set before the inputs) and the network-optimisation pass the exporter keeps on.
    static let variants: [Variant] = [
        Variant(name: "exporter-before (identifier, jpeg, before inputs)"),
        Variant(name: "key-space iTunes + key covr, jpeg", form: .keySpace),
        Variant(name: "identifier, raw data", dataType: .rawData),
        Variant(name: "key-space iTunes + key covr, raw data", form: .keySpace, dataType: .rawData),
        Variant(name: "identifier, no data type", dataType: .none),
        Variant(name: "identifier, jpeg, after inputs", timing: .afterInputs),
        Variant(name: "key-space + key, jpeg, after inputs (exporter now)", form: .keySpace, timing: .afterInputs),
        Variant(name: "identifier, jpeg, not network-optimised", optimized: false),
        Variant(name: "key-space + key, jpeg, after inputs, not network-optimised", form: .keySpace, timing: .afterInputs, optimized: false),
        Variant(name: "identifier, jpeg, exporter's timescale and temporary directory", exporterSettings: true),
        Variant(name: "key-space + key, jpeg, after inputs, exporter's timescale and temporary directory", form: .keySpace, timing: .afterInputs,
                exporterSettings: true),
        Variant(name: "AVAssetExportSession passthrough, identifier, jpeg", exportSession: true),
        Variant(name: "AVAssetExportSession passthrough, key-space + key, jpeg", form: .keySpace, exportSession: true),
    ]

    @Test(.timeLimit(.minutes(2)))
    func eachCandidateWriteIsReported() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-cover-variants-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try Self.jpeg()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        var embedded: [String: Bool] = [:]
        for (index, variant) in Self.variants.enumerated() {
            let url = directory.appendingPathComponent("variant-\(index).mp4")
            let outcome: String
            do {
                try await Self.write(variant, art: jpeg, to: url, directory: directory)
                let art = try await coverArt(url)
                embedded[variant.name] = art == jpeg
                outcome = art == jpeg ? "embedded" : art == nil ? "missing" : "different bytes (\(art?.count ?? 0))"
            } catch {
                embedded[variant.name] = false
                outcome = "failed (\(type(of: error)): \(error.localizedDescription))"
            }
            print("cover-art-variant: macOS \(os): \(variant.name): \(outcome)")
        }
        let exporterURL = directory.appendingPathComponent("exporter.mp4")
        try await Self.writeMovie(to: exporterURL, optimized: true, temporary: directory) { writer, phase in
            if phase == .afterInputs { writer.metadata = [AVExporter.coverArt(jpeg)] }
        }
        let current = try await coverArt(exporterURL)
        print("cover-art-variant: macOS \(os): AVExporter.coverArt as the exporter writes it: \(current == jpeg ? "embedded" : "missing")")
        print("cover-art-variant: macOS \(os): summary: \(Self.variants.filter { embedded[$0.name] == true }.count) of \(Self.variants.count) embed")
        if version.majorVersion >= 27 { #expect(current == jpeg, "the exporter's cover write embeds on macOS 27") }
    }

    // MARK: Writing

    static func item(_ variant: Variant, art: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        switch variant.form {
        case .identifier: item.identifier = .iTunesMetadataCoverArt
        case .keySpace:
            item.keySpace = .iTunes
            item.key = AVMetadataKey.iTunesMetadataKeyCoverArt.rawValue as NSString
        }
        item.value = art as NSData
        switch variant.dataType {
        case .jpeg: item.dataType = kCMMetadataBaseDataType_JPEG as String
        case .rawData: item.dataType = kCMMetadataBaseDataType_RawData as String
        case .none: break
        }
        return item
    }

    static func write(_ variant: Variant, art: Data, to url: URL, directory: URL) async throws {
        let item = item(variant, art: art)
        guard variant.exportSession else {
            try await writeMovie(to: url, optimized: variant.optimized, temporary: variant.exporterSettings ? directory : nil) { writer, phase in
                if phase == variant.timing { writer.metadata = [item] }
            }
            return
        }
        let plain = directory.appendingPathComponent("plain-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: plain) }
        try await writeMovie(to: plain, optimized: true) { _, _ in }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: plain), presetName: AVAssetExportPresetPassthrough) else {
            throw VoxClipError.exportFailed("no passthrough session")
        }
        session.metadata = [item]
        session.shouldOptimizeForNetworkUse = variant.optimized
        try await session.export(to: url, as: .mp4)
    }

    /// One second of 160 × 90 H.264 (two frames); `configure` sees the writer before and after its input is added. With
    /// `temporary`, the writer takes the exporter's settings: that temporary directory and a 48 kHz movie timescale.
    static func writeMovie(to url: URL, optimized: Bool, temporary: URL? = nil, configure: (AVAssetWriter, Timing) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = optimized
        if let temporary {
            writer.directoryForTemporaryFiles = temporary
            writer.movieTimeScale = 48000
        }
        configure(writer, .beforeInputs)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input)
        configure(writer, .afterInputs)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let frame = buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(frame, [])
        if let raw = CVPixelBufferGetBaseAddress(frame) { memset(raw, 0x60, CVPixelBufferGetDataSize(frame)) }
        CVPixelBufferUnlockBaseAddress(frame, [])
        for time in [CMTime.zero, CMTime(value: 15, timescale: 30)] {
            guard adaptor.append(frame, withPresentationTime: time) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// A small JPEG: a 64 × 36 orange frame.
    static func jpeg() throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
