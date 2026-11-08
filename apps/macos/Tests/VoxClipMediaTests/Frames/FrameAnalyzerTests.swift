import CoreGraphics
import CoreText
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// ADR-R48: the frame analyzer's cache, its sheet and its Vision path. Faces cannot be synthesised reliably for Vision,
/// so face handling is exercised through the `FrameObserving` seam with stubs; the real Vision path is checked on a
/// drawn phone screen (text) and on the repository's counter fixture (no face), and measured on the user's footage
/// (ADR-R48's numbers).
@Suite(.serialized, .offlineFixtures)
struct FrameAnalyzerTests {
    static let key = String(repeating: "ab", count: 32)

    @Test func aCacheHitSkipsDecodingAndVision() async throws {
        let folder = try FrameTestFolder()
        let cache = FrameAnalysisCache(locations: folder.locations)
        let vision = CountingVision()
        let decoder = SyntheticDecoder()
        let analyzer = FrameAnalyzer(vision: vision, decoder: decoder, cache: cache)
        let clip = try #require(Self.clip())
        let first = try await analyzer.analyze(source: folder.url, contentKey: Self.key, clip: clip)
        let decoded = decoder.count, looked = vision.count
        #expect(looked == first.analysis.sentences.count + first.analysis.opening.count)
        #expect(first.analysis.timings.analyzedFrames == looked && first.analysis.timings.cachedFrames == 0)
        #expect(first.sheet.frames.count == first.analysis.sentences.count)
        let second = try await analyzer.analyze(source: folder.url, contentKey: Self.key, clip: clip)
        #expect(vision.count == looked && decoder.count == decoded)
        #expect(second.analysis.sentences == first.analysis.sentences && second.analysis.opening == first.analysis.opening)
        #expect(second.analysis.timings.cachedFrames == looked && second.analysis.timings.analyzedFrames == 0)
        #expect(second.sheet.images == first.sheet.images)
    }

    @Test func clearingTheCacheDropsTheAnalysis() async throws {
        let folder = try FrameTestFolder()
        let store = CacheStore(locations: folder.locations)
        let cache = FrameAnalysisCache(store: store)
        let vision = CountingVision()
        let analyzer = FrameAnalyzer(vision: vision, decoder: SyntheticDecoder(), cache: cache)
        let clip = try #require(Self.clip())
        _ = try await analyzer.analyze(source: folder.url, contentKey: Self.key, clip: clip)
        let looked = vision.count
        let frames = try store.entryDirectory(contentKey: Self.key).appendingPathComponent("frames")
        #expect(FileManager.default.fileExists(atPath: frames.appendingPathComponent(FrameAnalysisCache.fileName).path))
        // "Clear cache" keeps envelopes and transcripts and strips what can be made again.
        try await store.evict(limitBytes: 0, protectedKeys: [], keepingEnvelopes: true)
        #expect(!FileManager.default.fileExists(atPath: frames.path))
        #expect(cache.observations(contentKey: Self.key, pass: FrameAnalysisCache.pass(tolerance: FrameAnalyzer.sentenceTolerance)).isEmpty)
        _ = try await analyzer.analyze(source: folder.url, contentKey: Self.key, clip: clip)
        #expect(vision.count == 2 * looked)
    }

    @Test func passesWithDifferentTolerancesAreCachedApartAndKeyedByTheTimeAskedFor() async throws {
        let folder = try FrameTestFolder()
        let cache = FrameAnalysisCache(locations: folder.locations)
        let vision = CountingVision()
        // The decoder returns the frame 0.2 s after the time asked for, as a 0.25 s tolerance may.
        let analyzer = FrameAnalyzer(vision: vision, decoder: SyntheticDecoder(offset: 0.2), cache: cache)
        let loose = try await analyzer.observations(source: folder.url, contentKey: Self.key, times: [5], tolerance: 0.25)
        #expect(loose.frames.map(\.time) == [5.2])
        let exact = try await analyzer.observations(source: folder.url, contentKey: Self.key, times: [5], tolerance: 1.0 / 30)
        #expect(exact.analyzed == 1 && vision.count == 2)
        let again = try await analyzer.observations(source: folder.url, contentKey: Self.key, times: [5], tolerance: 0.25)
        #expect(again.cached == 1 && again.frames.map(\.time) == [5.2] && vision.count == 2)
    }

    @Test func aLinkedEntryIsNeverWrittenThrough() async throws {
        let folder = try FrameTestFolder()
        let outside = folder.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let cacheRoot = folder.locations.cache
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cacheRoot.appendingPathComponent(Self.key), withDestinationURL: outside)
        let analyzer = FrameAnalyzer(vision: CountingVision(), decoder: SyntheticDecoder(), cache: FrameAnalysisCache(locations: folder.locations))
        _ = try await analyzer.observations(source: folder.url, contentKey: Self.key, times: [1, 2], tolerance: 0.25, sheet: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func theSheetHoldsSmallLabelledJPEGsAndItsSummary() async throws {
        let folder = try FrameTestFolder()
        let analyzer = FrameAnalyzer(vision: CountingVision(), decoder: SyntheticDecoder(), cache: nil)
        let clip = try #require(Self.clip())
        let sheet = try await analyzer.analyze(source: folder.url, contentKey: Self.key, clip: clip).sheet
        #expect(sheet.frames.count == 3)
        for frame in sheet.frames {
            #expect(max(frame.image.width, frame.image.height) == FrameSheet.frameEdge)
            #expect(frame.image.width == 320 && frame.image.height == 180)
            #expect(frame.image.data.starts(with: [0xFF, 0xD8]))
            #expect(frame.image.mediaType == "image/jpeg")
        }
        #expect(sheet.images.map(\.label) == ["Frame 1 at 1.20 s", "Frame 2 at 2.70 s", "Frame 3 at 4.20 s"])
        #expect(sheet.estimatedImageTokens == 3 * 77)
        #expect(sheet.imageBytes == sheet.frames.map(\.image.data.count).reduce(0, +))
        let lines = sheet.summary.components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines[1] == "F1 1.20 s: face at 0.40,0.30,0.20,0.40, eyes open, quality 0.70, facing camera")
        #expect(sheet.estimatedSummaryTokens == Int((Double(sheet.summary.utf8.count) / 2.2).rounded(.up)))
    }

    @Test func summaryLinesNameScreensAndMissingFaces() {
        let screen = FrameScreen(rect: ClipEffect.Rect(x: 0.6, y: 0.3, width: 0.2, height: 0.4), textBoxes: 6, textCoverage: 0.3, framed: true)
        let frame = FrameSheetFrame(index: 2, observation: FrameObservation(time: 12.346, faceCount: 0, screens: [screen]),
                                    jpeg: Data([0xFF, 0xD8]), width: 320, height: 180)
        #expect(frame.summaryLine == "F2 12.35 s: no face, screen with 6 text boxes at 0.60,0.30,0.20,0.40")
        let face = FrameFace(rect: ClipEffect.Rect(x: 0.1, y: 0.1, width: 0.2, height: 0.3), captureQuality: 0.25, leftEyeAspect: 0.1, rightEyeAspect: 0.1, yaw: 0.79)
        let turned = FrameSheetFrame(index: 1, observation: FrameObservation(time: 0, faceCount: 2, face: face), jpeg: Data(), width: 1, height: 1)
        #expect(turned.summaryLine == "F1 0.00 s: face at 0.10,0.10,0.20,0.30 (largest of 2), eyes closed, quality 0.25, turned away")
    }

    // MARK: Apple Vision and AVFoundation

    /// Through the analyzer's own Vision queue: a synchronous `perform` on a test's cooperative thread starves a small pool.
    @Test(.timeLimit(.minutes(1))) func visionFindsAPhoneScreenWithTextAndKeepsNoWords() async throws {
        let image = try Self.phoneScreen()
        let observation = try await FrameAnalyzer.look(AppleFrameVision(), image: image, time: 3)
        #expect(observation.face == nil && observation.faceCount == 0)
        #expect(observation.textRects.count >= 3)
        let screen = try #require(observation.screens.first)
        #expect(screen.rect.midX > 0.5 && screen.rect.midX < 0.8)
        let encoded = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        #expect(!encoded.contains("Invoice") && !encoded.contains("Account"))
    }

    @Test func realDecodeAndVisionOnTheCounterFixture() async throws {
        let source = try FixtureLoader.sharedRoot().appendingPathComponent("fixtures/media/counter-1080p.mp4")
        let folder = try FrameTestFolder()
        let analyzer = FrameAnalyzer(cache: FrameAnalysisCache(locations: folder.locations))
        let found = try await analyzer.observations(source: source, contentKey: Self.key, times: [0.5, 1.5, 2.5, 3.5],
                                                    tolerance: FrameAnalyzer.openingTolerance, sheet: true)
        #expect(found.frames.count == 4 && found.analyzed == 4)
        for (frame, asked) in zip(found.frames, [0.5, 1.5, 2.5, 3.5]) {
            #expect(abs(frame.time - asked) <= FrameAnalyzer.openingTolerance + 1e-6)
            #expect(frame.face == nil)
        }
        let sheet = try await analyzer.sheet(source: source, contentKey: Self.key, frames: found.frames)
        #expect(sheet.frames.count == 4 && sheet.frames.allSatisfy { $0.image.width == 320 && $0.image.height == 180 })
    }

    // MARK: Helpers

    /// Three sentences of three words, 1.5 s apart from 1.0 s; each middle word spans 0.2 s, so the sentence frames are
    /// at 1.2, 2.7 and 4.2 s.
    static func clip() -> FrameClip? {
        var words: [TimedWord] = [TimedWord(id: "lead", text: "Before.", start: 0, end: 0.5)]
        for sentence in 0..<3 {
            for word in 0..<3 {
                let start = 1.0 + Double(sentence) * 1.5 + Double(word) * 0.1
                let text = word == 2 ? "end." : "word"
                words.append(TimedWord(id: "s\(sentence)w\(word)", text: text, start: start, end: start + 0.09))
            }
        }
        for index in words.indices where words[index].id.hasSuffix("w1") { words[index].end = words[index].start + 0.2 }
        return FrameClip(words: words, first: 1, last: words.count - 1, cutWordIds: [])
    }

    /// A 1280×720 grey frame with a dark phone on the right showing six lines of text.
    static func phoneScreen() throws -> CGImage {
        let width = 1280, height = 720
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VoxClipError.decodeFailed("context") }
        context.setFillColor(CGColor(gray: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let phone = CGRect(x: 780, y: 120, width: 260, height: 480)
        context.setFillColor(CGColor(gray: 0.02, alpha: 1))
        context.fill(phone)
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(phone.insetBy(dx: 14, dy: 22))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
        let lines = ["Invoice 2041", "Account 88-13", "Total 1,250 EUR", "Due 12 Nov", "Pay now", "Reference QX7"]
        for (index, line) in lines.enumerated() {
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
            guard let string = CFAttributedStringCreate(nil, line as CFString, attributes) else { continue }
            let text = CTLineCreateWithAttributedString(string)
            context.textPosition = CGPoint(x: phone.minX + 30, y: phone.maxY - 80 - CGFloat(index) * 60)
            CTLineDraw(text, context)
        }
        guard let image = context.makeImage() else { throw VoxClipError.decodeFailed("image") }
        return image
    }
}

/// A Vision stand-in that counts its calls and reports one centred, open-eyed face per frame.
final class CountingVision: FrameObserving {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    func observe(_ image: CGImage, time: Double) throws -> FrameObservation {
        calls.withLock { $0 += 1 }
        let face = FrameFace(rect: ClipEffect.Rect(x: 0.4, y: 0.3, width: 0.2, height: 0.4), captureQuality: 0.7,
                             leftEyeAspect: 0.3, rightEyeAspect: 0.3, yaw: 0, pitch: 0)
        return FrameObservation(time: time, faceCount: 1, face: face)
    }
}

/// A decoder stand-in: a grey 1280×720 frame `offset` seconds after each time asked for, counting decodes.
final class SyntheticDecoder: FrameDecoding {
    let offset: Double
    private let calls = Mutex(0)
    init(offset: Double = 0) { self.offset = offset }
    var count: Int { calls.withLock { $0 } }
    func reader(source: URL, maximumEdge: Int, tolerance: Double) -> any FrameReading {
        SyntheticReader(owner: self, edge: maximumEdge)
    }
    fileprivate func decoded() { calls.withLock { $0 += 1 } }
}

private struct SyntheticReader: FrameReading {
    let owner: SyntheticDecoder
    let edge: Int
    func image(at time: Double) async throws -> (image: CGImage, time: Double) {
        owner.decoded()
        let width = min(edge, 1280), height = width * 9 / 16
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VoxClipError.decodeFailed("context") }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw VoxClipError.decodeFailed("image") }
        return (image, time + owner.offset)
    }
}

/// A temporary data folder, removed afterwards.
final class FrameTestFolder: Sendable {
    let url: URL
    let locations: DataLocations
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("VoxClip-frames-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": url.path])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
