import AVFoundation
import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// "Cover frame chosen" and "9:16 follows your face" on export (ADR-R48 part 2, doc/publishing.md): the real exporter (the
/// CLI) writes the frame at the clip's cover beside the video as `<name>-cover.jpg` and embeds it as the MP4's `covr` art
/// without adding a stream; `--cover off` writes neither; the 9:16 and 1:1 crops centre on the stored face and 16:9
/// ignores it.
extension HeavyMediaTests {
@Test(.timeLimit(.minutes(3)))
func clipCoverIsWrittenBesideTheExportAndEmbedded() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // counter.mov draws its source frame number in bits along the top, so the cover's frame can be read back.
    let source = try await NativeMediaFixtures.shared.file("counter.mov")
    let input = try await coverProject(source: source, in: directory, controls: ProjectClipControls(clipId: "a", coverSeconds: 1.3))

    func export(_ name: String, extra: [String] = []) throws -> (video: URL, json: [String: Any]) {
        let video = directory.appendingPathComponent("\(name).mp4")
        let result = try runCLI(["--open", input.path, "--clip", "a", "--export", video.path, "--json", "--quiet"] + extra,
                                directory: directory, timeout: 60)
        try #require(result.status == 0, "CLI exit \(result.status): \(result.stderr)")
        let json = try #require(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        return (video, json)
    }
    let on = try export("Clip one")
    let off = try export("Clip two", extra: ["--cover", "off"])

    // The JPEG beside the video, named after it, at the exported size, showing the source frame at 1.3 s (frame 39).
    let cover = directory.appendingPathComponent("Clip one-cover.jpg")
    #expect(on.json["cover"] as? String == cover.path)
    let jpeg = try Data(contentsOf: cover)
    let image = try #require(coverImage(jpeg))
    let track = try #require(try await AVURLAsset(url: on.video).loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(image.width == Int(size.width) && image.height == Int(size.height))
    let frame = try #require(counterFrame(image))
    #expect(abs(frame - 39) <= 1, "cover shows source frame \(frame)")

    // Embedded as the MP4's cover art, the same JPEG; the export keeps its streams.
    let art = try await coverArt(on.video)
    #expect(art == jpeg)
    #expect(try await AVURLAsset(url: on.video).load(.tracks).count == AVURLAsset(url: off.video).load(.tracks).count)
    if let streams = ffprobeStreams(on.video), let plain = ffprobeStreams(off.video) {
        #expect(streams.filter { !$0.attachedPicture }.map(\.codecType) == plain.filter { !$0.attachedPicture }.map(\.codecType))
        #expect(streams.filter(\.attachedPicture).count == 1)
        #expect(plain.filter(\.attachedPicture).isEmpty)
    }

    // --cover off: no JPEG, no art.
    #expect(off.json["cover"] == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Clip two-cover.jpg").path))
    #expect(try await coverArt(off.video) == nil)
    // Nothing of the transaction is left behind.
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!left.contains { $0.hasSuffix(".partial") || $0.hasPrefix(".voxclip-export-") }, "\(left)")
}

/// A clip without a cover writes no JPEG and no art, so ordinary exports stay as they were.
@Test(.timeLimit(.minutes(2)))
func clipWithoutACoverWritesNone() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file("counter.mov")
    let input = try await coverProject(source: source, in: directory, controls: nil)
    let video = directory.appendingPathComponent("plain.mp4")
    let result = try runCLI(["--open", input.path, "--clip", "a", "--export", video.path, "--json", "--quiet"], directory: directory, timeout: 60)
    try #require(result.status == 0, "CLI exit \(result.status): \(result.stderr)")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("plain-cover.jpg").path))
    #expect(try await coverArt(video) == nil)
}

/// The face-follow centre reaches the compositor: 9:16 and 1:1 move the crop to the face, 16:9 ignores it.
@Test(.timeLimit(.minutes(3)))
func faceFollowCentreMovesTheVerticalAndSquareCrops() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // bars.mov: eight full-height bars across 1920 px.
    let source = try await NativeMediaFixtures.shared.file("bars.mov")
    let face = try await coverProject(source: source, in: directory, name: "face",
                                      controls: ProjectClipControls(clipId: "a", reframe: .face(x: 0.15, y: 0.4)))
    let centred = try await coverProject(source: source, in: directory, name: "centre", controls: nil)

    struct Colour: CustomStringConvertible {
        var red: Int, green: Int, blue: Int
        var description: String { "rgb(\(red), \(green), \(blue))" }
    }
    /// The colour at `across` of the exported frame's width, a third of the way down (above the captions), and the frame.
    func export(_ input: URL, aspect: String, name: String, across: Double = 0.5) throws -> (colour: Colour, frame: [UInt8]) {
        let video = directory.appendingPathComponent("\(name).mp4")
        let result = try runCLI(["--open", input.path, "--clip", "a", "--aspect", aspect, "--export", video.path, "--json", "--quiet"],
                                directory: directory, timeout: 60)
        try #require(result.status == 0, "CLI exit \(result.status): \(result.stderr)")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        let image = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        let pixels = rgba(image)
        let index = ((image.height / 3) * image.width + Int(Double(image.width) * across)) * 4
        return (Colour(red: Int(pixels[index]), green: Int(pixels[index + 1]), blue: Int(pixels[index + 2])), try clipLookFrame(video, at: 0.5))
    }
    // 9:16 on x 0.15 clamps at the left edge (source 0–608): its middle is bar 1 (yellow). The centre crop (656–1264) shows
    // bar 3 (green) at 3/8 of its width. 1:1 on the face clamps too (0–1080): its middle is bar 2 (cyan).
    let portrait = try export(face, aspect: "9:16", name: "face-portrait").colour
    #expect(portrait.red > 150 && portrait.green > 150 && portrait.blue < 60, "9:16 face \(portrait)")
    let portraitCentre = try export(centred, aspect: "9:16", name: "centre-portrait", across: 0.375).colour
    #expect(portraitCentre.red < 60 && portraitCentre.green > 150 && portraitCentre.blue < 60, "9:16 centre \(portraitCentre)")
    let square = try export(face, aspect: "1:1", name: "face-square").colour
    #expect(square.red < 60 && square.green > 150 && square.blue > 150, "1:1 face \(square)")
    // 16:9 shows the whole picture either way.
    let wide = try export(face, aspect: "16:9", name: "face-wide").frame
    let wideCentre = try export(centred, aspect: "16:9", name: "centre-wide").frame
    #expect(clipLookChanged(wide, wideCentre) < 0.0005)
}
}

/// The crop rule itself: a face centre moves the 9:16 and 1:1 crops (clamped inside the picture), 16:9 and a clip without
/// one keep the centre crop.
@Suite struct FaceFollowCropGeometryTests {
    let source = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func portraitAndSquareCentreOnTheFace() {
        let face = ProjectClipControls(clipId: "a", reframe: .face(x: 0.3, y: 0.5))
        let portrait = FrameCompositor.aspectCrop(source: source, output: CGSize(width: 1080, height: 1920), controls: face)
        #expect(abs(portrait.width - 607.5) < 1 && abs(portrait.midX - 576) < 1)
        let square = FrameCompositor.aspectCrop(source: source, output: CGSize(width: 1080, height: 1080), controls: face)
        #expect(abs(square.width - 1080) < 1 && abs(square.minX - 36) < 1)
        let edge = ProjectClipControls(clipId: "a", reframe: .face(x: 0.98, y: 0.5))
        #expect(abs(FrameCompositor.aspectCrop(source: source, output: CGSize(width: 1080, height: 1920), controls: edge).maxX - 1920) < 1)
    }

    @Test func wideAndNoFaceKeepTheCentreCrop() {
        let face = ProjectClipControls(clipId: "a", reframe: .face(x: 0.3, y: 0.5))
        let wideOutput = CGSize(width: 1920, height: 1080)
        #expect(FrameCompositor.aspectCrop(source: source, output: wideOutput, controls: face)
            == FrameCompositor.centerCrop(source: source, output: wideOutput))
        let portrait = CGSize(width: 1080, height: 1920)
        #expect(FrameCompositor.aspectCrop(source: source, output: portrait, controls: ProjectClipControls(clipId: "a"))
            == FrameCompositor.centerCrop(source: source, output: portrait))
        #expect(FrameCompositor.aspectCrop(source: source, output: portrait, controls: nil)
            == FrameCompositor.centerCrop(source: source, output: portrait))
    }

    @Test func aFlippedPictureMirrorsTheFace() {
        let flipped = ProjectClipControls(clipId: "a", flipHorizontal: true, reframe: .face(x: 0.3, y: 0.5))
        let crop = FrameCompositor.aspectCrop(source: source, output: CGSize(width: 1080, height: 1920), controls: flipped)
        #expect(abs(crop.midX - 1344) < 1)
    }
}

/// A one-clip project over `source` with words through 1.8 s and `controls` for clip "a".
private func coverProject(source: URL, in directory: URL, name: String = "take", controls: ProjectClipControls?) async throws -> URL {
    let texts = ["The", "cover", "is", "the", "frame", "that", "shows", "you"]
    let words = texts.enumerated().map { index, text in
        TimedWord(id: "w\(index)", text: text, start: 0.1 + Double(index) * 0.22, end: 0.28 + Double(index) * 0.22)
    }
    let transcript = Transcript(words: words, durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
                                rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let probe = try await AVMediaProbe().probe(source)
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    var project = Project(id: UUID().uuidString.lowercased(), createdAt: Date(), modifiedAt: Date(), savedBy: ProjectWriter(version: "9.8.7"),
        media: ProjectMedia(source: MediaReference(absolutePath: source.path,
            sizeBytes: try #require((attributes[.size] as? NSNumber)?.int64Value), durationSeconds: probe.durationSeconds,
            contentKey: try JSONProjectStore.contentKey(for: source), video: probe.video, audio: probe.audio)),
        transcript: transcript, edits: ProjectEdits(clips: [ClipRange(id: "a", startWordId: "w0", endWordId: "w7", title: "A")], activeClipId: "a"))
    if let controls {
        project = try ContextDemoProject.upgradeToV4(project)
        project.clipControls = [controls]
    }
    let input = directory.appendingPathComponent("\(name).voxclip")
    try await JSONProjectStore(appVersion: "9.8.7").save(project, to: input)
    return input
}

private func coverImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

/// The source frame number counter.mov draws: twelve 32 px cells from x 720, rows 16–48, of a 1920 px frame.
private func counterFrame(_ image: CGImage) -> Int? {
    let pixels = rgba(image)
    let scale = Double(image.width) / 1920
    let row = Int(32 * scale)
    var value = 0
    for bit in 0..<12 {
        let column = Int((720 + 40 * Double(bit) + 16) * scale)
        guard column < image.width else { return nil }
        let index = (row * image.width + column) * 4
        value = value << 1 | (pixels[index] > 128 ? 1 : 0)
    }
    return value
}

/// The MP4's iTunes cover art, or nil.
private func coverArt(_ video: URL) async throws -> Data? {
    let asset = AVURLAsset(url: video)
    let items = try await asset.loadMetadata(for: .iTunesMetadata)
    guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataCoverArt).first else { return nil }
    return try await item.load(.dataValue)
}

private struct ProbedStream: Decodable {
    var codecType: String
    var attachedPicture: Bool
}

/// The file's streams by ffprobe (codec type, attached picture), or nil when ffprobe is not installed.
private func ffprobeStreams(_ video: URL) -> [ProbedStream]? {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin"]
    guard let tool = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("ffprobe") })
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
    let process = Process()
    process.executableURL = tool
    process.arguments = ["-v", "error", "-show_entries", "stream=codec_type:stream_disposition=attached_pic", "-of", "json", video.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let streams = root["streams"] as? [[String: Any]] else { return nil }
    return streams.map { stream in
        let disposition = stream["disposition"] as? [String: Any]
        return ProbedStream(codecType: stream["codec_type"] as? String ?? "",
                            attachedPicture: (disposition?["attached_pic"] as? NSNumber)?.intValue == 1)
    }
}
