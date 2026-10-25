import Foundation
import CoreVideo
import VoxClipCore

struct CaptionAlphaTable {
    let bytes: [UInt8]
    init(_ opacity: Double) {
        bytes = (0...255).map { UInt8(clamping: CaptionMath.roundHalfUp(Double($0) * opacity)) }
    }
}

struct CaptionBand: Sendable {
    var x: Int = 0
    var y: Int = 0
    var width: Int = 0
    var height: Int = 0
    var frameWidth: Int
    var frameHeight: Int
    var bgra = Data()
    var opacity: Double = 1

    func raster() -> CaptionRaster {
        let alpha = CaptionAlphaTable(opacity).bytes
        var rgba = Data(count: frameWidth * frameHeight * 4)
        rgba.withUnsafeMutableBytes { destinationRaw in
            bgra.withUnsafeBytes { sourceRaw in
                let destination = destinationRaw.bindMemory(to: UInt8.self)
                let source = sourceRaw.bindMemory(to: UInt8.self)
                for row in 0..<height {
                    let target = (row + y) * frameWidth * 4 + x * 4
                    let start = row * width * 4
                    for column in 0..<width {
                        let input = start + column * 4, output = target + column * 4
                        destination[output] = alpha[Int(source[input + 2])]; destination[output + 1] = alpha[Int(source[input + 1])]
                        destination[output + 2] = alpha[Int(source[input])]; destination[output + 3] = alpha[Int(source[input + 3])]
                    }
                }
            }
        }
        return .init(width: frameWidth, height: frameHeight, bytesPerRow: frameWidth * 4, rgba: rgba)
    }

    func composite(into pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixelBuffer) == frameWidth, CVPixelBufferGetHeight(pixelBuffer) == frameHeight else {
            throw VoxClipError.exportFailed("Invalid caption BGRA target")
        }
        guard width > 0, height > 0, opacity > 0 else { return }
        let table = CaptionAlphaTable(opacity).bytes
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { throw VoxClipError.exportFailed("Caption BGRA lock") }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { throw VoxClipError.exportFailed("Caption BGRA storage") }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        bgra.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self).baseAddress!
            for row in 0..<height {
                let input = source + row * width * 4
                let output = destination + (row + y) * stride + x * 4
                for column in 0..<width {
                    let offset = column * 4, alpha = Int(table[Int(input[offset + 3])])
                    if alpha == 0 { continue }
                    if alpha == 255 {
                        output[offset] = input[offset]; output[offset + 1] = input[offset + 1]
                        output[offset + 2] = input[offset + 2]; output[offset + 3] = 255
                        continue
                    }
                    let inverse = 255 - alpha
                    output[offset] = UInt8(clamping: Int(table[Int(input[offset])]) + (Int(output[offset]) * inverse + 127) / 255)
                    output[offset + 1] = UInt8(clamping: Int(table[Int(input[offset + 1])]) + (Int(output[offset + 1]) * inverse + 127) / 255)
                    output[offset + 2] = UInt8(clamping: Int(table[Int(input[offset + 2])]) + (Int(output[offset + 2]) * inverse + 127) / 255)
                    output[offset + 3] = UInt8(clamping: alpha + (Int(output[offset + 3]) * inverse + 127) / 255)
                }
            }
        }
    }
}

struct CaptionRenderStatistics: Sendable {
    var renderedBands = 0
    var cacheHits = 0
    var cacheBytes = 0
    var fullFrameRasters = 0
    var largestBandBytes = 0
}

final class CaptionRenderPool: @unchecked Sendable {
    private struct Key: Hashable {
        var layout: UInt64
        var page: Int
        var width: Int
        var activeWord: Int?
        var clusters: [Int?]
        var reduceMotion: Bool
        var wipeBase: Bool
        var wordOpacities: [Double]
    }
    private struct Entry {
        var band: CaptionBand
        var accessed: UInt64
    }
    private struct LayoutEntry {
        var id: UInt64
        var layout: CaptionLayoutResult
    }
    private let shared: SharedResources
    private let lock = NSLock()
    private var idle: [CaptionRenderer] = []
    private var layouts: [LayoutEntry] = []
    private var cache: [Key: Entry] = [:]
    private var serial: UInt64 = 0
    private var counters = CaptionRenderStatistics()
    private let limit: Int
    private let shadowPassHook: (@Sendable (Int) throws -> Void)?

    init(shared: SharedResources, cacheLimit: Int = 64 * 1024 * 1024,
         shadowPassHook: (@Sendable (Int) throws -> Void)? = nil) {
        self.shared = shared; limit = cacheLimit; self.shadowPassHook = shadowPassHook
    }

    var statistics: CaptionRenderStatistics { lock.withLock { counters } }

    func raster(_ layout: CaptionLayoutResult, time: Double, width: Int, reduceMotion: Bool) throws -> CaptionRaster {
        let band = try band(layout, time: time, width: width, reduceMotion: reduceMotion)
        lock.withLock { counters.fullFrameRasters += 1 }
        return band.raster()
    }

    func band(_ layout: CaptionLayoutResult, time: Double, width: Int, reduceMotion: Bool) throws -> CaptionBand {
        try Task.checkCancellation()
        let state = CaptionTimeline.evaluate(layout, time: time, reduceMotion: reduceMotion)
        let identifier = layoutID(layout)
        let key = cacheKey(layout, identifier: identifier, state: state, width: width, reduceMotion: reduceMotion)
        let cached = key.flatMap { key in lock.withLock { () -> CaptionBand? in
            guard var entry = cache[key] else { return nil }
            serial &+= 1; entry.accessed = serial; cache[key] = entry; counters.cacheHits += 1
            return entry.band
        } }
        if var cached, key?.wipeBase == false {
            cached.opacity = state.motion.alpha
            return cached
        }
        let renderer = lock.withLock { idle.popLast() } ?? CaptionRenderer(shared: shared, shadowPassHook: shadowPassHook)
        let band: CaptionBand
        do {
            var drawing = state
            if key != nil { drawing.motion.alpha = 1 }
            var rendered = try renderer.renderBand(layout, state: drawing, outputWidth: width, layoutID: identifier,
                base: cached, cacheWipeBase: key?.wipeBase == true && cached == nil)
            rendered.opacity = state.motion.alpha
            band = rendered
        } catch is CancellationError { throw CancellationError() }
        catch let error as VoxClipError { throw error }
        catch { throw VoxClipError.exportFailed("Caption rendering failed") }
        lock.withLock {
            defer { if idle.count < 4 { idle.append(renderer) } }
            counters.renderedBands += 1
            counters.largestBandBytes = max(counters.largestBandBytes, band.bgra.count)
            guard let key, cached == nil else { return }
            var stored = key.wipeBase ? renderer.wipeBase : band
            stored?.opacity = 1
            guard let stored, stored.bgra.count <= limit else { return }
            if let old = cache.removeValue(forKey: key) { counters.cacheBytes -= old.band.bgra.count }
            while counters.cacheBytes + stored.bgra.count > limit, let oldest = cache.min(by: { $0.value.accessed < $1.value.accessed }) {
                counters.cacheBytes -= oldest.value.band.bgra.count; cache.removeValue(forKey: oldest.key)
            }
            serial &+= 1; cache[key] = .init(band: stored, accessed: serial); counters.cacheBytes += stored.bgra.count
        }
        return band
    }

    private func cacheKey(_ layout: CaptionLayoutResult, identifier: UInt64, state: CaptionFrameState, width: Int, reduceMotion: Bool) -> Key? {
        guard limit > 0, let pageIndex = state.page, layout.style.reveal?.cursor == nil,
              reduceMotion || layout.style.effects?.jitter == nil else { return nil }
        let page = layout.pages[pageIndex].page, animation = layout.style.animation
        func running(_ animation: CaptionAnim?, start: Double) -> Bool {
            guard !reduceMotion, let animation, animation.type != .none, animation.type != .fade, animation.durationSec > 0 else { return false }
            return state.time >= start && state.time < start + animation.durationSec
        }
        guard !running(animation?.pageIn, start: page.start),
              !running(animation?.pageOut, start: page.end - (animation?.pageOut?.durationSec ?? 0)),
              !state.words.contains(where: { appearance in
                  let start = layout.words[appearance.word].input.start
                  return appearance.state != "future" && (running(animation?.wordIn, start: start) ||
                      (appearance.state == "active" && running(animation?.activeIn, start: start)))
              }) else { return nil }
        return .init(layout: identifier, page: pageIndex, width: width, activeWord: state.activeWord,
            clusters: state.words.map(\.visibleClusters), reduceMotion: reduceMotion,
            wipeBase: state.words.contains { $0.wipe != nil }, wordOpacities: state.words.map(\.opacity))
    }

    private func layoutID(_ layout: CaptionLayoutResult) -> UInt64 {
        lock.withLock {
            let identifier: UInt64
            if let index = layouts.firstIndex(where: { $0.layout == layout }) {
                let entry = layouts.remove(at: index); layouts.append(entry); identifier = entry.id
            } else {
                serial &+= 1; identifier = serial
                if layouts.count >= 8 {
                    let expired = layouts.removeFirst().id
                    for key in cache.keys.filter({ $0.layout == expired }) {
                        counters.cacheBytes -= cache.removeValue(forKey: key)!.band.bgra.count
                    }
                }
                layouts.append(.init(id: identifier, layout: layout))
            }
            return identifier
        }
    }
}
