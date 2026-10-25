import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import Dispatch
import VoxClipCore

private final class CaptionCanvasLane: @unchecked Sendable {
    let context: CGContext
    let bytes: UnsafeMutableRawPointer
    var result: Result<Void, any Error>?
    init(_ context: CGContext, bytes: UnsafeMutableRawPointer) { self.context = context; self.bytes = bytes }
    deinit { bytes.deallocate() }
}

private final class CaptionCanvas {
    private static let firstFillLock = NSLock()
    nonisolated(unsafe) private static var firstFillComplete = false
    let width: Int
    let height: Int
    var origin: CGPoint
    let bytes: UnsafeMutableRawPointer
    let context: CGContext
    let byteCount: Int
    private var lanes: [CaptionCanvasLane] = []
    var parallelism: Int { max(1, lanes.count) }
    init(width: Int, height: Int, origin: CGPoint = .zero, alphaOnly: Bool = false) throws {
        self.width = width; self.height = height; self.origin = origin
        byteCount = width * height * (alphaOnly ? 1 : 4)
        bytes = .allocate(byteCount: byteCount, alignment: 64)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        do {
            context = try Self.context(bytes: bytes, width: width, height: height, origin: origin, alphaOnly: alphaOnly)
            if height >= 80, width * height >= 16_384 {
                for _ in 0..<(width >= 512 ? 4 : 2) {
                    let storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
                    storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
                    do {
                        let context = try Self.context(bytes: storage, width: width, height: height, origin: origin, alphaOnly: alphaOnly)
                        lanes.append(.init(context, bytes: storage))
                    } catch { storage.deallocate(); throw error }
                }
            }
        } catch { bytes.deallocate(); throw error }
    }

    private static func context(bytes: UnsafeMutableRawPointer, width: Int, height: Int, origin: CGPoint, alphaOnly: Bool) throws -> CGContext {
        guard let context = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * (alphaOnly ? 1 : 4),
            space: alphaOnly ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alphaOnly ? CGImageAlphaInfo.alphaOnly.rawValue : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw CaptionFailure.invalid("Caption bitmap")
        }
        context.translateBy(x: 0, y: Double(height)); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -origin.x, y: -origin.y)
        context.setShouldAntialias(true); context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(false); context.setAllowsFontSmoothing(false)
        context.setLineJoin(.round); context.setLineCap(.round)
        return context
    }
    func reset(origin: CGPoint) {
        context.translateBy(x: self.origin.x - origin.x, y: self.origin.y - origin.y)
        for lane in lanes { lane.context.translateBy(x: self.origin.x - origin.x, y: self.origin.y - origin.y) }
        self.origin = origin
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    }
    deinit { bytes.deallocate() }
    var buffer: UnsafeMutableBufferPointer<UInt8> { .init(start: bytes.assumingMemoryBound(to: UInt8.self), count: byteCount) }

    private static func warmUpFirstFill(_ path: CGPath) throws {
        try firstFillLock.withLock {
            guard !firstFillComplete else { return }
            let bounds = path.boundingBoxOfPath
            guard !bounds.isNull, !bounds.isEmpty else { throw CaptionFailure.invalid("Caption warm-up glyph") }
            let scale = 64 / max(bounds.width, bounds.height)
            var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                tx: 16 - bounds.minX * scale, ty: 16 - bounds.minY * scale)
            guard let glyph = path.copy(using: &transform) else { throw CaptionFailure.invalid("Caption warm-up path") }
            let outline = glyph.copy(strokingWithWidth: 4.3008, lineCap: .round, lineJoin: .round, miterLimit: 10)
            for alphaOnly in [true, false] {
                let storage = UnsafeMutableRawPointer.allocate(byteCount: 128 * 128 * (alphaOnly ? 1 : 4), alignment: 64)
                defer { storage.deallocate() }
                storage.initializeMemory(as: UInt8.self, repeating: 0, count: 128 * 128 * (alphaOnly ? 1 : 4))
                let context = try Self.context(bytes: storage, width: 128, height: 128, origin: .zero, alphaOnly: alphaOnly)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.addPath(glyph); context.fillPath()
                context.addPath(outline); context.fillPath()
                context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(4.3008)
                context.addPath(glyph); context.strokePath()
            }
            firstFillComplete = true
        }
    }

    func draw(_ groups: [[CaptionDrawWord]], offset: CGPoint = .zero, _ body: @Sendable (CGContext, [CaptionDrawWord]) throws -> Void) throws {
        guard let word = groups.lazy.flatMap({ $0 }).first(where: { !$0.path.isEmpty }) else {
            try body(context, groups.flatMap { $0 }); return
        }
        try Self.warmUpFirstFill(word.path)
        guard !lanes.isEmpty, groups.filter({ !$0.isEmpty }).count > 1 else { try body(context, groups.flatMap { $0 }); return }
        let jobs = lanes
        for (index, group) in groups.enumerated() {
            copy(group, offset: offset, from: bytes, to: jobs[index].bytes)
        }
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            jobs[index].result = Result { if !groups[index].isEmpty { try body(jobs[index].context, groups[index]) } }
        }
        for job in jobs { try job.result!.get() }
        for (index, group) in groups.enumerated() {
            copy(group, offset: offset, from: jobs[index].bytes, to: bytes)
        }
    }

    private func copy(_ words: [CaptionDrawWord], offset: CGPoint, from source: UnsafeRawPointer, to destination: UnsafeMutableRawPointer) {
        let channels = byteCount / (width * height)
        for word in words {
            let bounds = word.coverage.offsetBy(dx: offset.x, dy: offset.y)
            let left = max(0, Int(floor(bounds.minX - origin.x))), right = min(width, Int(ceil(bounds.maxX - origin.x)))
            let top = max(0, Int(floor(bounds.minY - origin.y))), bottom = min(height, Int(ceil(bounds.maxY - origin.y)))
            guard left < right, top < bottom else { continue }
            for row in top..<bottom {
                let position = (row * width + left) * channels
                destination.advanced(by: position).copyMemory(from: source.advanced(by: position), byteCount: (right - left) * channels)
            }
        }
    }
}

private struct CaptionDrawWord: @unchecked Sendable {
    var index: Int
    var path: CGPath
    var outline: CGPath?
    var transform: CGAffineTransform
    var rect: CGRect
    var line: CGRect
    var appearance: CaptionWordAppearance
    var stroke: String?
    var strokeWidth: Double
    var coverage: CGRect
}

private final class CaptionShadowScratch: @unchecked Sendable {
    let mask: CaptionCanvas
    let blur = CaptionBlurScratch()
    var result: Result<CaptionBlurRegion, any Error>?
    init(width: Int, height: Int, origin: CGPoint) throws {
        mask = try CaptionCanvas(width: width, height: height, origin: origin, alphaOnly: true)
    }
}

private struct CaptionMaskBlendBuffers: @unchecked Sendable {
    var lookup: UnsafePointer<UInt8>
    var mask: UnsafePointer<UInt8>
    var destination: UnsafeMutablePointer<UInt8>
}

public actor CoreTextCaptionRasterizer: VoxClipCore.CaptionRasterizer {
    private nonisolated let pool: CaptionRenderPool
    private var prepared: CaptionLayoutResult?
    public init(shared: SharedResources) { pool = CaptionRenderPool(shared: shared) }

    nonisolated var statistics: CaptionRenderStatistics { pool.statistics }

    public nonisolated func draw(_ layout: CaptionLayoutResult, time: Double, into pixelBuffer: CVPixelBuffer, previewWidth: Int? = nil, reduceMotion: Bool = false) throws {
        let band = try pool.band(layout, time: time, width: previewWidth ?? layout.input.frame.width, reduceMotion: reduceMotion)
        try band.composite(into: pixelBuffer)
    }

    public func prepare(_ track: CaptionLayoutResult) {
        prepared = track
    }

    public func rasterize(_ request: CaptionRasterRequest) async throws -> CaptionRaster {
        guard let track = prepared, track.style == request.style,
              track.input.frame.width == request.width, track.input.frame.height == request.height,
              track.pages.contains(where: { $0.page == request.page }) else {
            throw CaptionFailure.missingContext("Prepare the complete CaptionLayoutResult before using the page-only rasterizer protocol")
        }
        if let visible = CaptionTimeline.evaluate(track, time: request.time).page, track.pages[visible].page != request.page {
            throw CaptionFailure.invalid("Stale caption page request")
        }
        return try pool.raster(track, time: request.time, width: request.width, reduceMotion: request.reduceMotion)
    }

    public func rasterize(_ track: CaptionLayoutResult, time: Double, previewWidth: Int? = nil, reduceMotion: Bool = false) throws -> CaptionRaster {
        try pool.raster(track, time: time, width: previewWidth ?? track.input.frame.width, reduceMotion: reduceMotion)
    }
}

final class CaptionRenderer: @unchecked Sendable {
    private struct GeometryKey: Hashable {
        var layout: UInt64
        var page: Int
        var word: Int
        var clusters: Int?
        var emphasis: Bool
    }
    private struct Geometry {
        var path: CGPath
        var outline: CGPath?
    }
    private struct OutlineKey: Hashable {
        var geometry: GeometryKey
        var scale: Double
        var translateX: Double
        var translateY: Double
        var originX: Double
        var originY: Double
        var height: Int
    }
    private struct ShadowOffset: Hashable {
        var dx: Double
        var dy: Double
    }
    private struct ShadowGeometry: Equatable {
        var layout: UInt64
        var page: Int
        var origin: CGPoint
        var size: CGSize
        var transforms: [CGAffineTransform]
        var words: [Int]
        var clusters: [Int?]
        var opacity: [Double]
        var strokes: [Bool]
        var sigmaScale: Double
    }
    private let shared: SharedResources
    private var library: CaptionFontLibrary?
    private var emojis: [String: [UInt8]] = [:]
    private var resampledEmojis: [String: [UInt8]] = [:]
    private var shadowTables: [CaptionColor: CaptionShadowBlendTable] = [:]
    private var canvas: CaptionCanvas?
    private var shadows: [CaptionShadowScratch] = []
    private var shadowGeometry: ShadowGeometry?
    private var geometry: [GeometryKey: Geometry] = [:]
    private var outlines: [OutlineKey: CGPath] = [:]
    private var directLayout: CaptionLayoutResult?
    private(set) var wipeBase: CaptionBand?
    private let shadowPassHook: (@Sendable (Int) throws -> Void)?
    init(shared: SharedResources, shadowPassHook: (@Sendable (Int) throws -> Void)? = nil) {
        self.shared = shared; self.shadowPassHook = shadowPassHook
    }

    private func surface(width: Int, height: Int, origin: CGPoint) throws -> CaptionCanvas {
        let existing = canvas
        if let existing, existing.width == width, existing.height == height {
            existing.reset(origin: origin); return existing
        }
        let created = try CaptionCanvas(width: width, height: height, origin: origin)
        canvas = created
        return created
    }

    private func getLibrary() throws -> CaptionFontLibrary {
        if library == nil { library = try CaptionFontLibrary(shared: shared) }
        return library!
    }

    func renderBand(_ track: CaptionLayoutResult, state: CaptionFrameState, outputWidth: Int, layoutID: UInt64 = 0,
                    base: CaptionBand? = nil, cacheWipeBase: Bool = false) throws -> CaptionBand {
        try Task.checkCancellation()
        wipeBase = nil
        if layoutID == 0, directLayout != track {
            geometry.removeAll(keepingCapacity: true); outlines.removeAll(keepingCapacity: true); directLayout = track
        }
        guard (1...32768).contains(outputWidth) else { throw CaptionFailure.invalid("Caption output size") }
        let ratio = Double(outputWidth) / Double(track.input.frame.width)
        let outputHeight = CaptionMath.roundHalfUp(Double(track.input.frame.height) * ratio)
        guard outputHeight > 0, outputWidth * outputHeight <= 134_217_728 else { throw CaptionFailure.invalid("Caption output allocation") }
        guard let pageIndex = state.page, state.motion.alpha > 0, state.motion.scale > 0 else {
            return .init(frameWidth: outputWidth, frameHeight: outputHeight)
        }
        let library = try getLibrary(), layout = track.pages[pageIndex], page = layout.page, style = track.style
        let centre = CGPoint(x: page.block.x + page.block.width / 2, y: page.block.y + page.block.height / 2)
        let pageScale = state.motion.scale
        let pageTransform = CGAffineTransform(a: pageScale * ratio, b: 0, c: 0, d: pageScale * ratio,
            tx: (centre.x * (1 - pageScale) + state.jitter.x) * ratio,
            ty: (centre.y * (1 - pageScale) + state.jitter.y + state.motion.dy) * ratio)
        var drawWords: [CaptionDrawWord] = []
        var bounds = page.visual.cgRect.applying(pageTransform)
        for (local, appearance) in state.words.enumerated() where appearance.visible && appearance.opacity > 0 {
            try Task.checkCancellation()
            let measured = track.words[appearance.word]
            let emphasised = layout.emphasised.keys.contains(appearance.word)
            let shaped = emphasised ? measured.emphasisShaped! : measured.shaped
            let emphasisScale = emphasised ? style.emphasis?.scale ?? 1 : 1
            let rect = page.wordRects[local].cgRect
            guard let line = page.lines.first(where: { $0.words.contains(appearance.word) }) else { throw CaptionFailure.invalid("Word line") }
            let geometryKey = GeometryKey(layout: layoutID, page: pageIndex, word: appearance.word, clusters: appearance.visibleClusters, emphasis: emphasised)
            let paths: Geometry
            if let cached = geometry[geometryKey] { paths = cached }
            else {
                let path = CGMutablePath()
                let count = shaped.runs.reduce(0) { $0 + $1.glyphs.count }
                let spacing = Double(CaptionMath.roundHalfUp(style.font.letterSpacingEm * Double(track.unitsPerEm))) * page.fontPx / Double(track.unitsPerEm)
                var pen = 0.0, glyphIndex = 0
                for run in shaped.runs {
                    let size = page.fontPx / Double(run.unitsPerEm)
                    for glyph in run.glyphs {
                        if appearance.visibleClusters == nil || glyph.cluster < appearance.visibleClusters! {
                            if let outline = try library.outline(file: run.file, glyph: glyph.id) {
                                let transform = CGAffineTransform(a: emphasisScale * size, b: 0, c: 0, d: -emphasisScale * size,
                                    tx: rect.minX + emphasisScale * (pen + Double(glyph.offsetX) * size), ty: line.baseline - emphasisScale * Double(glyph.offsetY) * size)
                                path.addPath(outline, transform: transform)
                            }
                        }
                        pen += Double(glyph.advance) * size
                        if glyphIndex < count - 1 { pen += spacing }
                        glyphIndex += 1
                    }
                }
                let strokeWidth = style.stroke.map { $0.widthEm * page.fontPx } ?? 0
                paths = .init(path: path, outline: strokeWidth > 0 ? path.copy(strokingWithWidth: strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10) : nil)
                if geometry.count >= 512 { geometry.removeAll(keepingCapacity: true) }
                geometry[geometryKey] = paths
            }
            let wordTransform = CGAffineTransform(a: appearance.scale, b: 0, c: 0, d: appearance.scale,
                tx: rect.midX * (1 - appearance.scale), ty: rect.midY * (1 - appearance.scale) + appearance.dy)
            let transform = wordTransform.concatenating(pageTransform)
            let wordState = CaptionTimeline.wordState(style, appearance.state)
            let stroke = wordState?.hideStroke == true ? nil : style.stroke.map { wordState?.strokeColor ?? $0.color }
            let strokeWidth = style.stroke.map { $0.widthEm * page.fontPx } ?? 0
            let padding = max(strokeWidth * abs(transform.a) / 2, (style.effects?.rgbSplit?.offsetEm ?? 0) * page.fontPx * pageScale * ratio) + 2
            let coverage = paths.path.boundingBoxOfPath.applying(transform).insetBy(dx: -padding, dy: -padding)
            drawWords.append(.init(index: appearance.word, path: paths.path, outline: paths.outline, transform: transform, rect: rect, line: line.rect.cgRect, appearance: appearance, stroke: stroke, strokeWidth: strokeWidth, coverage: coverage))
            bounds = bounds.union(paths.path.boundingBoxOfPath.applying(transform).insetBy(dx: -strokeWidth * ratio * pageScale * appearance.scale, dy: -strokeWidth * ratio * pageScale * appearance.scale))
        }
        for box in layout.boxes {
            if let index = box.word {
                if let word = drawWords.first(where: { $0.index == index }) { bounds = bounds.union(box.rect.cgRect.applying(word.transform)) }
            } else { bounds = bounds.union(box.rect.cgRect.applying(pageTransform)) }
        }
        if let box = style.words?.active?.box, let word = drawWords.first(where: { $0.index == state.activeWord }) {
            bounds = bounds.union(word.rect.insetBy(dx: -box.paddingXEm * page.fontPx, dy: -box.paddingYEm * page.fontPx).applying(word.transform))
        }
        if let cursor = state.cursor, cursor.visible { bounds = bounds.union(cursor.rect.cgRect.applying(pageTransform)) }
        if let emoji = layout.emoji { bounds = bounds.union(emoji.rect.cgRect.applying(pageTransform)) }
        var margin = 4.0
        for shadow in style.shadows {
            try Task.checkCancellation()
            margin = max(margin, (ceil(3 * shadow.sigmaEm * page.fontPx * pageScale * ratio) + 3) + max(abs(shadow.dxEm), abs(shadow.dyEm)) * page.fontPx * pageScale * ratio)
        }
        if let split = style.effects?.rgbSplit { margin += split.offsetEm * page.fontPx * pageScale * ratio }
        bounds = bounds.insetBy(dx: -margin, dy: -margin).integral
        let visibleBounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight).insetBy(dx: -margin, dy: -margin)
        bounds = bounds.intersection(visibleBounds).integral
        guard !bounds.isNull, !bounds.isEmpty else { return .init(frameWidth: outputWidth, frameHeight: outputHeight) }
        let canvas = try surface(width: Int(bounds.width), height: Int(bounds.height), origin: bounds.origin)
        let context = canvas.context
        for index in drawWords.indices where drawWords[index].transform.a != 1 || drawWords[index].transform.d != 1 {
            guard drawWords[index].stroke != nil else { continue }
            let word = drawWords[index]
            let key = OutlineKey(geometry: .init(layout: layoutID, page: pageIndex, word: word.index,
                clusters: word.appearance.visibleClusters, emphasis: layout.emphasised.keys.contains(word.index)),
                scale: word.transform.a, translateX: word.transform.tx, translateY: word.transform.ty,
                originX: canvas.origin.x, originY: canvas.origin.y, height: canvas.height)
            if let outline = outlines[key] { drawWords[index].outline = outline; continue }
            context.saveGState(); context.concatenate(word.transform); context.setLineWidth(word.strokeWidth)
            context.addPath(word.path); context.replacePathWithStrokedPath()
            drawWords[index].outline = context.path
            context.beginPath(); context.restoreGState()
            if outlines.count >= 512 { outlines.removeAll(keepingCapacity: true) }
            outlines[key] = drawWords[index].outline
        }
        let groups = wordGroups(drawWords, lanes: canvas.parallelism)
        if let base {
            base.bgra.withUnsafeBytes { raw in
                guard let source = raw.baseAddress else { return }
                for row in 0..<base.height {
                    let offset = ((base.y + row - Int(canvas.origin.y)) * canvas.width + base.x - Int(canvas.origin.x)) * 4
                    canvas.bytes.advanced(by: offset).copyMemory(from: source.advanced(by: row * base.width * 4), byteCount: base.width * 4)
                }
            }
        } else {
            if let box = style.box {
                let path = CGMutablePath(), border = CGMutablePath()
                for geometry in layout.boxes {
                    if let word = geometry.word, let draw = drawWords.first(where: { $0.index == word }) {
                        if draw.appearance.opacity != 1 {
                            try drawBox(geometry.rect.cgRect, radius: geometry.radius, color: box.color, borderWidth: box.borderWidthEm * page.fontPx,
                                borderColor: box.borderColor, transform: draw.transform, opacity: draw.appearance.opacity, style: style, context: context)
                            continue
                        }
                        path.addPath(CaptionPaths.rounded(geometry.rect.cgRect, radius: geometry.radius), transform: draw.transform)
                    } else if geometry.word == nil {
                        path.addPath(CaptionPaths.rounded(geometry.rect.cgRect, radius: geometry.radius), transform: pageTransform)
                        let inset = box.borderWidthEm * page.fontPx / 2
                        border.addPath(CaptionPaths.rounded(geometry.rect.cgRect.insetBy(dx: inset, dy: inset), radius: max(0, geometry.radius - inset)), transform: pageTransform)
                    }
                }
                context.setFillColor(try CaptionColor(box.color, style: style).cgColor); context.addPath(path); context.fillPath()
                if box.borderWidthEm > 0, let color = box.borderColor {
                    context.setStrokeColor(try CaptionColor(color, style: style).cgColor); context.setLineWidth(box.borderWidthEm * page.fontPx * pageScale * ratio)
                    context.addPath(border); context.strokePath()
                    for geometry in layout.boxes {
                        guard let index = geometry.word, let draw = drawWords.first(where: { $0.index == index }), draw.appearance.opacity == 1 else { continue }
                        let borderWidth = box.borderWidthEm * page.fontPx
                        context.saveGState(); context.concatenate(draw.transform); context.setLineWidth(borderWidth)
                        context.addPath(CaptionPaths.rounded(geometry.rect.cgRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), radius: max(0, geometry.radius - borderWidth / 2)))
                        context.strokePath(); context.restoreGState()
                    }
                }
            }
            if let box = style.words?.active?.box, let word = drawWords.first(where: { $0.index == state.activeWord }) {
                let rect = word.rect.insetBy(dx: -box.paddingXEm * page.fontPx, dy: -box.paddingYEm * page.fontPx)
                let radius = box.pill ? rect.height / 2 : min(box.radiusEm * page.fontPx, rect.width / 2, rect.height / 2)
                try drawBox(rect, radius: radius, color: box.color, borderWidth: box.borderWidthEm * page.fontPx, borderColor: box.borderColor,
                    transform: word.transform, opacity: word.appearance.opacity, style: style, context: context)
            }
            let currentShadowGeometry = ShadowGeometry(layout: layoutID, page: pageIndex, origin: canvas.origin,
                size: .init(width: canvas.width, height: canvas.height), transforms: drawWords.map(\.transform),
                words: drawWords.map(\.index), clusters: drawWords.map { $0.appearance.visibleClusters },
                opacity: drawWords.map { $0.appearance.opacity }, strokes: drawWords.map { $0.stroke != nil }, sigmaScale: page.fontPx * pageScale * ratio)
            if layoutID == 0 || shadowGeometry != currentShadowGeometry {
                shadowGeometry = nil
                if shadows.count != style.shadows.count || shadows.contains(where: { $0.mask.width != canvas.width || $0.mask.height != canvas.height }) {
                    shadows = try style.shadows.map { _ in try CaptionShadowScratch(width: canvas.width, height: canvas.height, origin: canvas.origin) }
                }
                var masks: [ShadowOffset: Int] = [:]
                for (index, shadow) in style.shadows.enumerated() {
                    let mask = shadows[index].mask
                    let offset = ShadowOffset(dx: shadow.dxEm, dy: shadow.dyEm)
                    if let source = masks[offset] {
                        mask.bytes.copyMemory(from: shadows[source].mask.bytes, byteCount: mask.byteCount)
                        try shadowPassHook?(index)
                        continue
                    }
                    masks[offset] = index
                    mask.reset(origin: canvas.origin)
                    try mask.draw(groups, offset: .init(x: shadow.dxEm * page.fontPx * pageScale * ratio, y: shadow.dyEm * page.fontPx * pageScale * ratio)) { context, words in
                        for word in words {
                            var transform = word.transform
                            transform.tx += shadow.dxEm * page.fontPx * pageScale * ratio
                            transform.ty += shadow.dyEm * page.fontPx * pageScale * ratio
                            context.saveGState(); context.concatenate(transform); context.setAlpha(word.appearance.opacity)
                            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.addPath(word.path); context.fillPath()
                            if word.stroke != nil {
                                if let outline = word.outline {
                                    context.addPath(outline); context.fillPath()
                                } else {
                                    context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(word.strokeWidth)
                                    context.addPath(word.path); context.strokePath()
                                }
                            }
                            context.restoreGState()
                        }
                    }
                    try shadowPassHook?(index)
                }
                let jobs = shadows
                let sigmas = style.shadows.map { $0.sigmaEm * page.fontPx * pageScale * ratio }
                DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                    let job = jobs[index], mask = job.mask
                    job.result = Result { try job.blur.apply(mask.buffer, width: mask.width, height: mask.height, sigma: sigmas[index]) }
                }
                for job in jobs {
                    guard let result = job.result else { throw CaptionFailure.invalid("Caption shadow result") }
                    _ = try result.get()
                }
                shadowGeometry = currentShadowGeometry
            }
            try Task.checkCancellation()
            guard shadows.count == style.shadows.count else { throw CaptionFailure.invalid("Caption shadow count") }
            for (index, shadow) in style.shadows.enumerated() {
                let job = shadows[index]
                guard job.mask.width == canvas.width, job.mask.height == canvas.height, let result = job.result else {
                    throw CaptionFailure.invalid("Caption shadow scratch")
                }
                let region = try result.get()
                let color = try CaptionColor(shadow.color, style: style)
                compositeMask(job.mask.buffer, region: region, color: color, onto: canvas)
            }
            if let split = style.effects?.rgbSplit {
                try canvas.draw(groups) { context, words in
                    for word in words {
                        for (offset, color) in [(-split.offsetEm, split.leftColor), (split.offsetEm, split.rightColor)] {
                            var transform = word.transform; transform.tx += offset * page.fontPx * pageScale * ratio
                            context.saveGState(); context.concatenate(transform); context.setAlpha(word.appearance.opacity)
                            context.setFillColor(try CaptionColor(color, style: style).cgColor); context.addPath(word.path); context.fillPath(); context.restoreGState()
                        }
                    }
                }
            }
            try canvas.draw(groups) { context, words in
                let inactive = words.filter { $0.index != state.activeWord }, active = words.filter { $0.index == state.activeWord }
                for word in inactive { try self.stroke(word, style: style, context: context) }
                for word in inactive { try self.fill(word, block: page.block.cgRect, style: style, fontPx: page.fontPx, context: context) }
                for word in active { try self.stroke(word, style: style, context: context) }
            }
            if cacheWipeBase { wipeBase = band(canvas, outputWidth: outputWidth, outputHeight: outputHeight) }
            for word in drawWords where word.index == state.activeWord { try fill(word, block: page.block.cgRect, style: style, fontPx: page.fontPx, context: context) }
        }
        if base != nil {
            for word in drawWords where word.index == state.activeWord { try fill(word, block: page.block.cgRect, style: style, fontPx: page.fontPx, context: context) }
        }
        if let cursor = state.cursor, cursor.visible, let color = style.reveal?.cursor?.color {
            context.saveGState(); context.concatenate(pageTransform); context.setFillColor(try CaptionColor(color, style: style).cgColor)
            context.fill(cursor.rect.cgRect); context.restoreGState()
        }
        if let emoji = layout.emoji {
            let pixels = try emojiPixels(emoji.codepoints)
            let targetSize = CaptionMath.roundHalfUp(emoji.rect.width * pageScale * ratio)
            if targetSize > 0 {
                let emojiKey = "\(emoji.codepoints):\(targetSize)"
                let resampled: [UInt8]
                if let cached = resampledEmojis[emojiKey] { resampled = cached }
                else {
                    resampled = try CaptionEmojiResampler.resize(pixels, size: targetSize)
                    if resampledEmojis.count >= 64 { resampledEmojis.removeAll(keepingCapacity: true) }
                    resampledEmojis[emojiKey] = resampled
                }
                let centre = CGPoint(x: emoji.rect.x + emoji.rect.width / 2, y: emoji.rect.y + emoji.rect.height / 2).applying(pageTransform)
                let originX = CaptionMath.roundHalfUp(centre.x - Double(targetSize) / 2) - Int(canvas.origin.x)
                let originY = CaptionMath.roundHalfUp(centre.y - Double(targetSize) / 2) - Int(canvas.origin.y)
                let destination = canvas.buffer
                for row in 0..<targetSize {
                    for column in 0..<targetSize where (0..<canvas.width).contains(originX + column) && (0..<canvas.height).contains(originY + row) {
                        let source = (row * targetSize + column) * 4, target = ((originY + row) * canvas.width + originX + column) * 4
                        let alpha = Int(resampled[source + 3])
                        for channel in 0..<4 {
                            let sourceChannel = channel == 0 ? 2 : channel == 2 ? 0 : channel
                            destination[target + channel] = UInt8(clamping: Int(resampled[source + sourceChannel]) + (Int(destination[target + channel]) * (255 - alpha) + 127) / 255)
                        }
                    }
                }
            }
        }
        var result = band(canvas, outputWidth: outputWidth, outputHeight: outputHeight)
        result.opacity = state.motion.alpha
        return result
    }

    private func band(_ canvas: CaptionCanvas, outputWidth: Int, outputHeight: Int) -> CaptionBand {
        let originX = max(0, Int(canvas.origin.x)), originY = max(0, Int(canvas.origin.y))
        let bandWidth = max(0, min(outputWidth, Int(canvas.origin.x) + canvas.width) - originX)
        let bandHeight = max(0, min(outputHeight, Int(canvas.origin.y) + canvas.height) - originY)
        var band = CaptionBand(x: originX, y: originY, width: bandWidth, height: bandHeight, frameWidth: outputWidth, frameHeight: outputHeight,
            bgra: Data(count: bandWidth * bandHeight * 4))
        let bytes = canvas.bytes.assumingMemoryBound(to: UInt8.self)
        band.bgra.withUnsafeMutableBytes { raw in
            guard let destination = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<bandHeight {
                let source = bytes + ((row + originY - Int(canvas.origin.y)) * canvas.width + originX - Int(canvas.origin.x)) * 4
                let target = destination + row * bandWidth * 4
                target.update(from: source, count: bandWidth * 4)
            }
        }
        return band
    }

    private func wordGroups(_ words: [CaptionDrawWord], lanes: Int) -> [[CaptionDrawWord]] {
        var components: [(bounds: CGRect, words: [CaptionDrawWord])] = []
        for word in words {
            guard !word.path.isEmpty else { continue }
            var component = (bounds: word.coverage, words: [word])
            var index = 0
            while index < components.count {
                if components[index].bounds.intersects(component.bounds) {
                    component.bounds = component.bounds.union(components[index].bounds)
                    component.words.append(contentsOf: components.remove(at: index).words)
                    index = 0
                } else { index += 1 }
            }
            components.append(component)
        }
        var groups = [[CaptionDrawWord]](repeating: [], count: lanes), costs = [Double](repeating: 0, count: lanes)
        for component in components.sorted(by: { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }) {
            let lane = costs.indices.min { costs[$0] < costs[$1] }!
            groups[lane].append(contentsOf: component.words)
            costs[lane] += component.bounds.width * component.bounds.height
        }
        return groups.map { $0.sorted { $0.index < $1.index } }
    }

    private func drawBox(_ rect: CGRect, radius: Double, color: String, borderWidth: Double, borderColor: String?, transform: CGAffineTransform, opacity: Double, style: CaptionStyle, context: CGContext) throws {
        context.saveGState(); defer { context.restoreGState() }
        context.concatenate(transform); context.setAlpha(opacity); context.setFillColor(try CaptionColor(color, style: style).cgColor)
        context.addPath(CaptionPaths.rounded(rect, radius: radius)); context.fillPath()
        if borderWidth > 0, let borderColor {
            context.setStrokeColor(try CaptionColor(borderColor, style: style).cgColor); context.setLineWidth(borderWidth)
            context.addPath(CaptionPaths.rounded(rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), radius: max(0, radius - borderWidth / 2))); context.strokePath()
        }
    }

    private func stroke(_ word: CaptionDrawWord, style: CaptionStyle, context: CGContext) throws {
        guard let color = word.stroke, let outline = word.outline else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.concatenate(word.transform); context.setAlpha(word.appearance.opacity)
        context.setFillColor(try CaptionColor(color, style: style).cgColor)
        context.addPath(outline); context.fillPath()
    }

    private func fill(_ word: CaptionDrawWord, block: CGRect, style: CaptionStyle, fontPx: Double, context: CGContext) throws {
        context.saveGState(); defer { context.restoreGState() }
        context.concatenate(word.transform); context.setAlpha(word.appearance.opacity)
        if let wipe = word.appearance.wipe, let from = word.appearance.wipeFrom {
            try paint(from, path: word.path, word: word.rect, line: word.line, block: block, style: style, context: context)
            if wipe < 1 { context.clip(to: CGRect(x: word.rect.minX - fontPx, y: word.rect.minY - fontPx, width: fontPx + wipe * word.rect.width, height: word.rect.height + 2 * fontPx)) }
        }
        try paint(word.appearance.fill, path: word.path, word: word.rect, line: word.line, block: block, style: style, context: context)
    }

    private func paint(_ paint: CaptionPaint, path: CGPath, word: CGRect, line: CGRect, block: CGRect, style: CaptionStyle, context: CGContext) throws {
        context.saveGState(); defer { context.restoreGState() }
        switch paint {
        case .solid(let color):
            context.setFillColor(try CaptionColor(color, style: style).cgColor); context.addPath(path); context.fillPath()
        case .linear(let angle, let space, let stops):
            let rect = space == .word ? word : space == .line ? line : block
            let (start, end) = CaptionPaths.gradientEndpoints(rect, angle: angle)
            let colors = try stops.map { try CaptionColor($0.color, style: style).cgColor }
            let positions = stops.map { CGFloat($0.offset) }
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: positions) else { throw CaptionFailure.invalid("Caption gradient") }
            context.addPath(path); context.clip(); context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    private func compositeMask(_ mask: UnsafeMutableBufferPointer<UInt8>, region: CaptionBlurRegion, color: CaptionColor, onto canvas: CaptionCanvas) {
        let destination = canvas.bytes.assumingMemoryBound(to: UInt8.self)
        guard !region.isEmpty else { return }
        let table: CaptionShadowBlendTable
        if let cached = shadowTables[color] { table = cached }
        else {
            table = CaptionShadowBlendTable(color: color)
            if shadowTables.count >= 8 { shadowTables.removeAll(keepingCapacity: true) }
            shadowTables[color] = table
        }
        table.bytes.withUnsafeBytes { raw in
            let buffers = CaptionMaskBlendBuffers(lookup: raw.bindMemory(to: UInt8.self).baseAddress!, mask: mask.baseAddress!, destination: destination)
            let width = canvas.width
            let count = (region.right - region.left) * (region.bottom - region.top) >= 65_536 ? 2 : 1
            DispatchQueue.concurrentPerform(iterations: count) { stripe in
                let top = region.top + (region.bottom - region.top) * stripe / count
                let bottom = region.top + (region.bottom - region.top) * (stripe + 1) / count
                let lookup = buffers.lookup, source = buffers.mask, destination = buffers.destination
                for row in top..<bottom {
                    for column in region.left..<region.right {
                        let index = row * width + column, alpha = Int(source[index])
                        if alpha == 0 { continue }
                        let output = index * 4, offset = alpha * 256 * 4
                        destination[output] = lookup[offset + Int(destination[output]) * 4]
                        destination[output + 1] = lookup[offset + Int(destination[output + 1]) * 4 + 1]
                        destination[output + 2] = lookup[offset + Int(destination[output + 2]) * 4 + 2]
                        destination[output + 3] = lookup[offset + Int(destination[output + 3]) * 4 + 3]
                    }
                }
            }
        }
    }

    private func emojiPixels(_ code: String) throws -> [UInt8] {
        if let cached = emojis[code] { return cached }
        guard code.range(of: "^[0-9a-f]+(_[0-9a-f]+)*$", options: .regularExpression) != nil else { throw CaptionFailure.invalid("Emoji codepoints") }
        let url = shared.root.appendingPathComponent("fonts/noto-emoji/png128/emoji_u\(code).png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 128, image.height == 128 else { throw VoxClipError.sharedResourcesMissing }
        let canvas = try CaptionCanvas(width: 128, height: 128)
        canvas.context.translateBy(x: 0, y: 128); canvas.context.scaleBy(x: 1, y: -1)
        canvas.context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        let buffer = canvas.buffer
        var rgba = [UInt8](repeating: 0, count: buffer.count)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgba[index] = buffer[index + 2]; rgba[index + 1] = buffer[index + 1]; rgba[index + 2] = buffer[index]; rgba[index + 3] = buffer[index + 3]
        }
        emojis[code] = rgba
        return rgba
    }
}

extension CaptionRaster {
    public func composite(into pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height,
              bytesPerRow >= width * 4, rgba.count == bytesPerRow * height else { throw CaptionFailure.invalid("Caption BGRA target") }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { throw CaptionFailure.invalid("Caption BGRA lock") }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { throw CaptionFailure.invalid("Caption BGRA storage") }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        rgba.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<width {
                    let input = row * bytesPerRow + column * 4, output = row * stride + column * 4, alpha = Int(source[input + 3])
                    if alpha == 0 { continue }
                    for channel in 0..<4 {
                        let sourceChannel = channel == 0 ? 2 : channel == 2 ? 0 : channel
                        destination[output + channel] = UInt8(clamping: Int(source[input + sourceChannel]) + (Int(destination[output + channel]) * (255 - alpha) + 127) / 255)
                    }
                }
            }
        }
    }
}
