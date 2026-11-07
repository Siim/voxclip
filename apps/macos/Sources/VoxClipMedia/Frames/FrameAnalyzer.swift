@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VoxClipCore

/// Decodes frames of a source. The seam between the analyzer and AVFoundation.
public protocol FrameDecoding: Sendable {
    /// A reader for one lane of work. Each lane runs on its own task and reads its times in order.
    func reader(source: URL, maximumEdge: Int, tolerance: Double) -> any FrameReading
}

/// One lane's frame reader. It is used on one task only.
public protocol FrameReading {
    /// The frame nearest `time` within the reader's tolerance, and the source second it shows.
    func image(at time: Double) async throws -> (image: CGImage, time: Double)
}

/// `AVAssetImageGenerator` at a small size, with the track's rotation applied: hardware decode, so 4K 10-bit HEVC costs
/// about what 1080p does.
public struct AVFoundationFrameDecoder: FrameDecoding {
    public init() {}
    public func reader(source: URL, maximumEdge: Int, tolerance: Double) -> any FrameReading {
        AVFoundationFrameReader(source: source, maximumEdge: maximumEdge, tolerance: tolerance)
    }
}

final class AVFoundationFrameReader: FrameReading {
    private let generator: AVAssetImageGenerator

    init(source: URL, maximumEdge: Int, tolerance: Double) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumEdge, height: maximumEdge)
        let window = CMTime(seconds: max(0, tolerance), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = window
        generator.requestedTimeToleranceAfter = window
    }

    func image(at time: Double) async throws -> (image: CGImage, time: Double) {
        let result = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600))
        let actual = result.actualTime.seconds
        return (result.image, actual.isFinite ? actual : time)
    }
}

/// A clip's analysis with its frame sheet.
public struct FrameClipAnalysis: Sendable {
    public var analysis: FrameAnalysis
    public var sheet: FrameSheet
}

/// The on-device frame analyzer (ADR-R48): for given source times it decodes small frames, runs Vision on them in
/// parallel lanes, and caches each observation per source and millisecond asked for (`FrameAnalysisCache`). A cached
/// time is never decoded or looked at again. Each observation's `time` is the frame's own time, which may differ from
/// the time asked for by up to the pass's tolerance.
public struct FrameAnalyzer: Sendable {
    /// Frames are decoded with this long edge for Vision: faces and phone-screen text stay measurable, decode stays cheap.
    public static let analysisEdge = 1280
    /// Lanes that decode and look at once.
    public static let lanes = 4
    /// Seconds a sentence frame may be from its time: the decoder may then return a nearby frame without decoding a
    /// long run of frames, which on the user's 4K HEVC footage takes the 24 frames from 2.4 s to 0.7 s (ADR-R48).
    public static let sentenceTolerance = 0.25
    /// Seconds an opening-scan frame may be from its time: one frame at 30 fps, so the 10 fps scan sees ten frames a
    /// second.
    public static let openingTolerance = 1.0 / 30

    let vision: any FrameObserving
    let decoder: any FrameDecoding
    let cache: FrameAnalysisCache?

    public init(vision: any FrameObserving = AppleFrameVision(), decoder: any FrameDecoding = AVFoundationFrameDecoder(),
                cache: FrameAnalysisCache?) {
        self.vision = vision
        self.decoder = decoder
        self.cache = cache
    }

    /// A clip's sentence frames and opening scan with their timings, and the sheet of its sentence frames.
    public func analyze(source: URL, contentKey: String, clip: FrameClip) async throws -> FrameClipAnalysis {
        let sentenceTimes = FrameSampling.sentenceSamples(clip).map(\.time)
        let openingTimes = FrameSampling.openingTimes(start: clip.start)
        let clock = ContinuousClock()
        let sentenceStart = clock.now
        let sentences = try await observations(source: source, contentKey: contentKey, times: sentenceTimes,
                                               tolerance: Self.sentenceTolerance, sheet: true)
        let sheet = try await sheet(source: source, contentKey: contentKey, frames: sentences.frames, fresh: sentences.jpegs)
        let sentenceSeconds = Self.seconds(sentenceStart.duration(to: clock.now))
        let openingStart = clock.now
        let opening = try await observations(source: source, contentKey: contentKey, times: openingTimes,
                                             tolerance: Self.openingTolerance, sheet: false)
        let openingSeconds = Self.seconds(openingStart.duration(to: clock.now))
        let timings = FrameAnalysisTimings(sentenceSeconds: sentenceSeconds, openingSeconds: openingSeconds,
                                           cachedFrames: sentences.cached + opening.cached, analyzedFrames: sentences.analyzed + opening.analyzed)
        let analysis = FrameAnalysis(contentKey: contentKey, sentences: sentences.frames, opening: opening.frames, timings: timings)
        return FrameClipAnalysis(analysis: analysis, sheet: sheet)
    }

    /// What `observations` found: the frames in the order asked, how many came from the cache, and the sheet JPEGs of
    /// the frames decoded now, keyed by their own time's millisecond.
    public struct Found: Sendable {
        public var frames: [FrameObservation]
        public var cached: Int
        public var analyzed: Int
        public var jpegs: [Int: Data]
    }

    /// The observation at each of `times`, in order: cached ones from the cache, the rest decoded and looked at in
    /// `lanes` parallel lanes and then cached. With `sheet`, each newly decoded frame's sheet JPEG is made and cached too.
    public func observations(source: URL, contentKey: String, times: [Double], tolerance: Double, sheet: Bool = false) async throws -> Found {
        let pass = FrameAnalysisCache.pass(tolerance: tolerance)
        let cached = cache?.observations(contentKey: contentKey, pass: pass) ?? [:]
        var found: [Int: FrameObservation] = [:]
        var missing: [Double] = []
        for time in times {
            let key = FrameAnalysisCache.millisecond(time)
            if let hit = cached[key] { found[key] = hit }
            else if !missing.contains(where: { FrameAnalysisCache.millisecond($0) == key }) { missing.append(time) }
        }
        let fresh = try await analyzeMissing(source: source, times: missing, tolerance: tolerance, sheet: sheet)
        var jpegs: [Int: Data] = [:]
        for item in fresh {
            found[FrameAnalysisCache.millisecond(item.requested)] = item.observation
            if let jpeg = item.jpeg { jpegs[FrameAnalysisCache.millisecond(item.observation.time)] = jpeg }
        }
        if let cache {
            await cache.store(fresh.map { (requested: $0.requested, observation: $0.observation) }, contentKey: contentKey, pass: pass)
            for item in fresh { if let jpeg = item.jpeg { await cache.storeSheetImage(jpeg, contentKey: contentKey, time: item.observation.time) } }
        }
        let frames = times.compactMap { found[FrameAnalysisCache.millisecond($0)] }
        return Found(frames: frames, cached: times.count - missing.count, analyzed: missing.count, jpegs: jpegs)
    }

    /// The frame sheet of `frames`: each frame's JPEG from `fresh` or the cache, or one decoded now at the sheet's size.
    public func sheet(source: URL, contentKey: String, frames: [FrameObservation], fresh: [Int: Data] = [:]) async throws -> FrameSheet {
        let chosen = Array(frames.prefix(FrameSheet.maximumFrames))
        var result: [FrameSheetFrame] = []
        var reader: (any FrameReading)?
        for (offset, frame) in chosen.enumerated() {
            try Task.checkCancellation()
            var jpeg = fresh[FrameAnalysisCache.millisecond(frame.time)] ?? cache?.sheetImage(contentKey: contentKey, time: frame.time)
            if jpeg == nil {
                let lane = reader ?? decoder.reader(source: source, maximumEdge: FrameSheet.frameEdge, tolerance: Self.openingTolerance)
                reader = lane
                let decoded = try await lane.image(at: frame.time)
                let encoded = try FrameJPEG.encode(decoded.image, edge: FrameSheet.frameEdge)
                if let cache { await cache.storeSheetImage(encoded, contentKey: contentKey, time: frame.time) }
                jpeg = encoded
            }
            guard let jpeg, let size = FrameJPEG.size(jpeg) else { continue }
            result.append(FrameSheetFrame(index: offset + 1, observation: frame, jpeg: jpeg, width: size.width, height: size.height))
        }
        return FrameSheet(frames: result)
    }

    struct Analyzed: Sendable { let requested: Double; let observation: FrameObservation; let jpeg: Data? }

    private func analyzeMissing(source: URL, times: [Double], tolerance: Double, sheet: Bool) async throws -> [Analyzed] {
        guard !times.isEmpty else { return [] }
        let ordered = times.sorted()
        let laneCount = min(Self.lanes, ordered.count)
        // Contiguous runs, so each lane's generator decodes forward through its own stretch of the source.
        let size = (ordered.count + laneCount - 1) / laneCount
        let runs = stride(from: 0, to: ordered.count, by: size).map { Array(ordered[$0..<min(ordered.count, $0 + size)]) }
        let vision = self.vision, decoder = self.decoder
        return try await withThrowingTaskGroup(of: [Analyzed].self) { group in
            for run in runs {
                group.addTask {
                    let reader = decoder.reader(source: source, maximumEdge: Self.analysisEdge, tolerance: tolerance)
                    var results: [Analyzed] = []
                    for time in run {
                        try Task.checkCancellation()
                        let decoded = try await reader.image(at: time)
                        let observation = try vision.observe(decoded.image, time: decoded.time)
                        let jpeg = sheet ? try FrameJPEG.encode(decoded.image, edge: FrameSheet.frameEdge) : nil
                        results.append(Analyzed(requested: time, observation: observation, jpeg: jpeg))
                    }
                    return results
                }
            }
            var all: [Analyzed] = []
            for try await results in group { all += results }
            return all.sorted { $0.requested < $1.requested }
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// The frame sheet's JPEGs: scaled so the long edge is `edge`, never up, sRGB, quality 0.7.
enum FrameJPEG {
    static let quality = 0.7

    static func encode(_ image: CGImage, edge: Int) throws -> Data {
        let longest = max(image.width, image.height)
        let scale = longest > edge ? Double(edge) / Double(longest) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw VoxClipError.decodeFailed("Cannot scale a frame")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw VoxClipError.decodeFailed("Cannot scale a frame") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw VoxClipError.decodeFailed("Cannot encode a frame")
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw VoxClipError.decodeFailed("Cannot encode a frame") }
        return data as Data
    }

    static func size(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
