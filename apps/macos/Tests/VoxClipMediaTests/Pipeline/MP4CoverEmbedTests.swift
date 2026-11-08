import AVFoundation
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// The cover written into the MP4 on disk (ADR-R48, doc/publishing.md §7): `MP4CoverEmbed` streams the shared vectors
/// (shared/fixtures/cover-art) to the same bytes as the Core writer, refuses without touching the file, and the movies it
/// writes still decode sample for sample, with the art AVFoundation and ffprobe read.
@Suite("MP4 cover embed")
struct MP4CoverEmbedTests {
    struct Case: Decodable {
        let id: String
        let input: String
        let image: String
        let refusal: String?
        let decodes: Bool?
        let outputSha256: String?
    }

    struct Document: Decodable { let cases: [Case] }

    static func cases() throws -> [Case] {
        try JSONDecoder().decode(Document.self, from: FixtureLoader.data("fixtures/cover-art/cover-art-cases.json")).cases
    }

    static func fixture(_ name: String) throws -> Data { try FixtureLoader.data("fixtures/cover-art/" + name) }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-cover-embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every vector, on disk: the output's bytes are the Core's (the generator's SHA-256), and a refusal leaves the input's
    /// bytes and no staged copy.
    @Test func everyVectorEmbedsOnDiskOrIsLeftUntouched() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for item in try Self.cases() {
            let input = try Self.fixture(item.input)
            let file = directory.appendingPathComponent(item.id + ".mp4")
            try input.write(to: file)
            if let refusal = item.refusal {
                await #expect(throws: MP4CoverArt.Refusal.self, "\(item.id)") { try await MP4CoverEmbed.embed(Self.fixture(item.image), into: file) }
                do { try await MP4CoverEmbed.embed(Self.fixture(item.image), into: file) } catch let error as MP4CoverArt.Refusal {
                    #expect(error.wire == refusal, "\(item.id)")
                }
                #expect(try Data(contentsOf: file) == input, "\(item.id): untouched")
            } else {
                try await MP4CoverEmbed.embed(Self.fixture(item.image), into: file)
                #expect(Self.sha(try Data(contentsOf: file)) == item.outputSha256, "\(item.id)")
            }
            let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(!left.contains { $0.hasSuffix(".cover") }, "\(item.id): \(left)")
        }
    }

    /// Every decodable vector still decodes: AVFoundation reads the same samples, byte for byte, from every track, and reads
    /// the cover as the file's artwork; ffprobe (when installed) lists the same streams plus one attached picture.
    @Test func theEmbeddedVectorsStillDecode() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for item in try Self.cases() where item.decodes == true {
            let source = directory.appendingPathComponent(item.id + "-in.mp4")
            let file = directory.appendingPathComponent(item.id + ".mp4")
            try Self.fixture(item.input).write(to: source)
            try Self.fixture(item.input).write(to: file)
            let image = try Self.fixture(item.image)
            try await MP4CoverEmbed.embed(image, into: file)
            let before = try await Self.samples(source), after = try await Self.samples(file)
            // Three H.264 frames (56 bytes) and 16 AAC frames, which AVFoundation hands back a chunk at a time (64 bytes).
            #expect(before.map { $0.reduce(0) { $0 + $1.count } } == [56, 64], "\(item.id)")
            #expect(after == before, "\(item.id): samples")
            #expect(try await Self.artwork(file) == image, "\(item.id): artwork")
            try Self.probe(file, against: source, id: item.id)
        }
    }

    /// An AVAssetWriter movie, network-optimised as the exporter writes it: moov comes first, every chunk offset moves by
    /// the growth, the samples decode as before and the cover is the JPEG.
    @Test func aWriterMovieGetsItsCover() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("writer-in.mp4"), file = directory.appendingPathComponent("writer.mp4")
        try await Self.writeMovie(to: source)
        try FileManager.default.copyItem(at: source, to: file)
        let jpeg = try Self.fixture("cover.jpg")
        try await MP4CoverEmbed.embed(jpeg, into: file)
        let input = try Data(contentsOf: source), output = try Data(contentsOf: file)
        let layout = try Self.layout(input)
        #expect(layout.map(\.type).firstIndex(of: "moov")! < layout.map(\.type).firstIndex(of: "mdat")!)
        let growth = Int64(output.count) - Int64(input.count)
        let old = try Self.tables(input), new = try Self.tables(output)
        #expect(!old.isEmpty && old.map(\.box) == new.map(\.box))
        #expect(zip(old, new).allSatisfy { a, b in zip(a.entries, b.entries).allSatisfy { Int64($1) == Int64($0) + growth } })
        #expect(try await Self.samples(file) == Self.samples(source))
        #expect(try await coverArt(file) == jpeg)
        #expect(try await Self.artwork(file) == jpeg)
        try Self.probe(file, against: source, id: "writer")
    }

    /// The cover is extra: when it can't be embedded, the export keeps its bytes and one line is logged.
    @Test func aFailedEmbedKeepsTheExportAndLogsOneLine() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("video.mp4.partial")
        let input = try Self.fixture("truncated.mp4")
        try input.write(to: file)
        let lines = Mutex<[String]>([])
        let embedded = await AVExporter.embedCover(try Self.fixture("cover.jpg"), in: file) { line in lines.withLock { $0.append(line) } }
        #expect(!embedded)
        #expect(try Data(contentsOf: file) == input)
        let logged = lines.withLock { $0 }
        #expect(logged.count == 1 && logged.first?.hasPrefix("cover: ") == true, "\(logged)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["video.mp4.partial"])
        let fine = directory.appendingPathComponent("fine.mp4")
        try Self.fixture("moov-first.mp4").write(to: fine)
        #expect(await AVExporter.embedCover(try Self.fixture("cover.jpg"), in: fine) { line in lines.withLock { $0.append(line) } })
        #expect(lines.withLock { $0.count } == 1)
    }

    // MARK: Reading

    static func layout(_ file: Data) throws -> [MP4CoverArt.Box] {
        try MP4CoverArt.layout(length: UInt64(file.count)) { offset, count in
            file.subdata(in: Int(offset)..<min(file.count, Int(offset) + count))
        }
    }

    static func tables(_ file: Data) throws -> [MP4CoverArt.ChunkOffsets] {
        let movie = try MP4CoverArt.movie(in: layout(file))
        return try MP4CoverArt.chunkOffsets(moov: file.subdata(in: Int(movie.offset)..<Int(movie.end)))
    }

    /// Each track's samples as stored, read by AVFoundation without decoding into another format.
    static func samples(_ file: URL) async throws -> [[Data]] {
        let asset = AVURLAsset(url: file)
        var tracks: [[Data]] = []
        for track in try await asset.load(.tracks) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            var samples: [Data] = []
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var bytes = Data(count: CMBlockBufferGetDataLength(block))
                let status = bytes.withUnsafeMutableBytes { raw in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw CocoaError(.fileReadCorruptFile) }
                samples.append(bytes)
            }
            guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            tracks.append(samples)
        }
        return tracks
    }

    /// The artwork AVFoundation reads from the file's metadata.
    static func artwork(_ file: URL) async throws -> Data? {
        let items = try await AVURLAsset(url: file).load(.metadata)
        let art = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first
            ?? AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataCoverArt).first
        return try await art?.load(.dataValue)
    }

    static func probe(_ file: URL, against source: URL, id: String) throws {
        guard let streams = ffprobeStreams(file), let plain = ffprobeStreams(source) else { return }
        #expect(streams.filter { !$0.attachedPicture }.map(\.codecType) == plain.filter { !$0.attachedPicture }.map(\.codecType), "\(id)")
        #expect(streams.filter(\.attachedPicture).count == 1, "\(id)")
    }

    /// One second of 160 × 90 H.264 (two frames), network-optimised.
    static func writeMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input)
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
}
