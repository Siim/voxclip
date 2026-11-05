import AVFoundation
import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// Each clip exports in its own caption look (design.md §6.6): three clips over the same words, each with a different
/// caption pick, rendered by the real exporter (the CLI). Only the captions differ, so the frames and SRTs show the style.
extension HeavyMediaTests {
@Test(.timeLimit(.minutes(3)))
func eachClipExportsInItsOwnCaptionLook() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    let texts = ["Every", "clip", "keeps", "its", "own", "look", "today"]
    let words = texts.enumerated().map { index, text in
        TimedWord(id: "w\(index)", text: text, start: 0.1 + Double(index) * 0.22, end: 0.28 + Double(index) * 0.22)
    }
    let transcript = Transcript(words: words, durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
                                rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let clips = ["a", "b", "c"].map { ClipRange(id: $0, startWordId: "w0", endWordId: "w6", title: $0.uppercased()) }
    let probe = try await AVMediaProbe().probe(source)
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    var project = Project(id: UUID().uuidString.lowercased(), createdAt: Date(), modifiedAt: Date(), savedBy: ProjectWriter(version: "9.8.7"),
        media: ProjectMedia(source: MediaReference(absolutePath: source.path,
            sizeBytes: try #require((attributes[.size] as? NSNumber)?.int64Value), durationSeconds: probe.durationSeconds,
            contentKey: try JSONProjectStore.contentKey(for: source), video: probe.video, audio: probe.audio)),
        transcript: transcript, edits: ProjectEdits(clips: clips, activeClipId: "a"))
    project.captions.styleId = "vox-highlight"
    // Make it postable's "as said" case on Marker, whose own case is UPPER.
    let asSaid: [String: JSONValue] = ["text": .object(["transform": .string("none")])]
    project.clipStyle = ClipStyle(preset: .auto, captions: .auto, music: .auto, maxLengthSec: 60, shapes: [.landscape], rewording: .fixOnly,
        captionPicks: ["a": ClipCaptionPick(styleId: "marker", reason: "Bold claims.", overrides: asSaid),
                       "b": ClipCaptionPick(styleId: "minimal", reason: "A quiet line.")])
    let input = directory.appendingPathComponent("take.voxclip")
    try await JSONProjectStore(appVersion: "9.8.7").save(project, to: input)
    let original = try Data(contentsOf: input)

    func export(_ clip: String, style: String? = nil, name: String) throws -> (frame: [UInt8], srt: String) {
        let video = directory.appendingPathComponent("\(name).mp4"), srt = directory.appendingPathComponent("\(name).srt")
        var arguments = ["--open", input.path, "--clip", clip, "--export", video.path, "--srt", srt.path, "--json", "--quiet"]
        if let style { arguments += ["--style", style] }
        let result = try runCLI(arguments, directory: directory, timeout: 60)
        try #require(result.status == 0, "CLI exit \(result.status): \(result.stderr)")
        clipLookCapture(video, at: 0.9, name: "clip-\(name)")
        return (try clipLookFrame(video, at: 0.9), try String(contentsOf: srt, encoding: .utf8))
    }
    let marker = try export("a", name: "a"), minimal = try export("b", name: "b"), fallback = try export("c", name: "c")
    // Each clip renders with its own pick; a clip without one follows the project's captions.
    #expect(clipLookChanged(marker.frame, minimal.frame) > 0.004, "marker vs minimal")
    #expect(clipLookChanged(marker.frame, fallback.frame) > 0.004, "marker vs project default")
    #expect(clipLookChanged(minimal.frame, fallback.frame) > 0.004, "minimal vs project default")
    // The same style named explicitly renders the same frame: the difference is the clip's look, nothing else.
    let defaultExplicit = try export("a", style: "vox-highlight", name: "a-default")
    #expect(clipLookChanged(fallback.frame, defaultExplicit.frame) < 0.0005)
    #expect(fallback.srt == defaultExplicit.srt)
    // The SRT pages follow each clip's style too.
    #expect(marker.srt != minimal.srt && marker.srt != fallback.srt && minimal.srt != fallback.srt)
    // The pick's overrides apply: Marker in its own UPPER case is another picture.
    let markerUpper = try export("a", style: "marker", name: "a-marker")
    #expect(clipLookChanged(marker.frame, markerUpper.frame) > 0.002)
    #expect(marker.srt == markerUpper.srt)
    #expect(try Data(contentsOf: input) == original)
}

/// Translated captions (ai.md §18.2) render in the export and its SRT: the translation's words in place of the
/// transcript's over its range, spread over their time; the voice and the rest of the captions stay.
@Test(.timeLimit(.minutes(3)))
func translatedCaptionsRenderInTheExportAndTheSRT() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    let texts = ["Every", "clip", "keeps", "its", "own", "look", "today"]
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
        transcript: transcript, edits: ProjectEdits(clips: [ClipRange(id: "a", startWordId: "w0", endWordId: "w6", title: "A")], activeClipId: "a"))
    project.captions.styleId = "marker"
    let plain = directory.appendingPathComponent("plain.voxclip"), translated = directory.appendingPathComponent("translated.voxclip")
    try await JSONProjectStore(appVersion: "9.8.7").save(project, to: plain)
    // "Translate these captions to Spanish" on the clip, words 0–4 (Ask Claude's toolbox, as ClipAutopilotMapping applies it).
    project = try CaptionTranslations.translating(0...4, clipID: "a", language: "es", text: "Cada clip tiene su estilo propio", in: project)
    try await JSONProjectStore(appVersion: "9.8.7").save(project, to: translated)

    func export(_ input: URL, name: String) throws -> (frame: [UInt8], srt: String) {
        let video = directory.appendingPathComponent("\(name).mp4"), srt = directory.appendingPathComponent("\(name).srt")
        let result = try runCLI(["--open", input.path, "--clip", "a", "--export", video.path, "--srt", srt.path, "--json", "--quiet"],
                                directory: directory, timeout: 60)
        try #require(result.status == 0, "CLI exit \(result.status): \(result.stderr)")
        clipLookCapture(video, at: 0.5, name: "translated-caption-\(name)")
        return (try clipLookFrame(video, at: 0.5), try String(contentsOf: srt, encoding: .utf8))
    }
    let before = try export(plain, name: "as-said"), after = try export(translated, name: "es")
    #expect(clipLookChanged(before.frame, after.frame) > 0.002, "the captions changed on screen")
    let cues = after.srt.uppercased()
    #expect(cues.contains("CADA") && cues.contains("PROPIO") && !cues.contains("EVERY") && !cues.contains("KEEPS"), "\(after.srt)")
    #expect(cues.contains("LOOK") && cues.contains("TODAY"), "words outside the range stay")
    // Six translated words over five shown words: the SRT still starts and ends where the clip's captions did.
    func bounds(_ srt: String) -> [String] { srt.split(separator: "\n").filter { $0.contains("-->") }.map(String.init) }
    #expect(bounds(after.srt).first?.prefix(12) == bounds(before.srt).first?.prefix(12))
    #expect(bounds(after.srt).last?.suffix(12) == bounds(before.srt).last?.suffix(12))
}
}

/// Writes `video`'s frame at `seconds` as `<name>.png` into VOXCLIP_CLIP_FINISH_CAPTURES, when it names a folder.
func clipLookCapture(_ video: URL, at seconds: Double, name: String) {
    guard let folder = ProcessInfo.processInfo.environment["VOXCLIP_CLIP_FINISH_CAPTURES"] else { return }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard let image = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) else { return }
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png") as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

/// The RGBA bytes of `video`'s frame at `seconds`.
func clipLookFrame(_ video: URL, at seconds: Double) throws -> [UInt8] {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

/// The share of pixels (0–1) where two RGBA frames of one size differ by more than 32 in some colour channel: caption
/// glyphs, not encoder noise.
func clipLookChanged(_ first: [UInt8], _ second: [UInt8]) -> Double {
    guard first.count == second.count, !first.isEmpty else { return 1 }
    var changed = 0
    for pixel in stride(from: 0, to: first.count, by: 4) {
        let red = abs(Int(first[pixel]) - Int(second[pixel]))
        let green = abs(Int(first[pixel + 1]) - Int(second[pixel + 1]))
        let blue = abs(Int(first[pixel + 2]) - Int(second[pixel + 2]))
        if max(red, green, blue) > 32 { changed += 1 }
    }
    return Double(changed) / Double(first.count / 4)
}
