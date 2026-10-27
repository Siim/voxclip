import AppKit
import AVFoundation
import VoxClipCore
import VoxClipMedia

struct AppCaptionLayoutInput: Sendable {
    let segments: [EditSegment]
    let settings: CaptionSettings
    let plan: EditPlan
    let output: OutputSpec
    let language: String?
    let style: CaptionStyle?
    var voiceLab: VoiceLabOutputPlan? = nil
}

struct CaptionTileInput: Sendable, Equatable {
    let state: EditState?
    let plan: EditPlan?
    let style: CaptionStyle
    let sampleWords: [String]
    let language: String?
    let frame: PixelSize
    let overrides: [String: JSONValue]
    let position: CaptionPosition?
    let sourceURL: URL
    let sourceTime: Double
}

@MainActor final class CaptionHandoff {
    let shared: SharedResources?
    private var pipeline: CaptionPipeline?
    private var rasterizer: CoreTextCaptionRasterizer?
    private(set) var rejectedOverrides = false
    private(set) var droppedWords = 0
    /// Drawn cards, least recently used first, capped at 8 MB (design §5.4 caching).
    private var cards: [String: CGImage] = [:]
    private var cardOrder: [String] = []
    private var cardBytes = 0

    init(shared: SharedResources?) { self.shared = shared }

    private func services() throws -> (CaptionPipeline, CoreTextCaptionRasterizer) {
        guard let shared else { throw VoxClipError.sharedResourcesMissing }
        if pipeline == nil { pipeline = try CaptionPipeline(shared: shared) }
        if rasterizer == nil { rasterizer = CoreTextCaptionRasterizer(shared: shared) }
        return (pipeline!, rasterizer!)
    }

    func layout(_ input: AppCaptionLayoutInput) async throws -> CaptionLayoutResult? {
        guard input.settings.styleId != "off" else { rejectedOverrides = false; droppedWords = 0; return nil }
        guard let style = input.style else { throw VoxClipError.sharedResourcesMissing }
        let (pipeline, _) = try services()
        let resolution = await pipeline.resolve(style, overrides: input.settings.overrides, frame: input.output.size)
        let words = input.voiceLab?.captions ?? captionCopy(input.segments, plan: input.plan)
        if let voiceLab = input.voiceLab {
            let layoutInput = CaptionLayoutInput(style: style.id,
                frame: .init(width: input.output.size.width, height: input.output.size.height),
                language: input.language ?? "und", duration: voiceLab.duration,
                captions: .init(overrides: input.settings.overrides, position: input.settings.position,
                                positionByAspect: input.settings.positionByAspect),
                words: words.map { .init(id: $0.id, text: $0.text, start: $0.start, end: $0.end) })
            let result = try await pipeline.layout(input: layoutInput, style: style)
            rejectedOverrides = resolution.rejectedOverrides
            droppedWords = result.dropped.count
            return result
        }
        let preset = CaptionStyleResolver.preset(width: input.output.size.width, height: input.output.size.height)
        let position = preset.flatMap { input.settings.positionByAspect[$0] } ?? input.settings.position
        let result = try await pipeline.layout(words: words, language: input.language, style: resolution.style,
            position: position, frame: input.output.size, duration: input.plan.duration)
        rejectedOverrides = resolution.rejectedOverrides
        droppedWords = result.dropped.count
        return result
    }

    func tile(_ input: CaptionTileInput) async -> NSImage? {
        do {
            let (pipeline, rasterizer) = try services()
            let resolution = await pipeline.resolve(input.style, overrides: input.overrides, frame: input.frame)
            let sample = input.sampleWords.isEmpty ? ["Your", "story"] : input.sampleWords
            guard !sample.isEmpty else { return nil }
            let words = sample.enumerated().map { index, text in
                CaptionWord(id: "tile-\(index)", text: text, start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
            }
            let layout = try await pipeline.layout(words: words, language: input.language, style: resolution.style,
                position: input.position, frame: input.frame, duration: Double(words.count) * 0.4 + 0.5)
            let raster = try await rasterizer.rasterize(layout, time: 0.2, previewWidth: 320, reduceMotion: true)
            guard let provider = CGDataProvider(data: raster.rgba as CFData),
                  let overlay = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: raster.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: input.sourceURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            let still = try? await generator.image(at: CMTime(seconds: input.sourceTime, preferredTimescale: 600)).image
            let size = CGSize(width: raster.width, height: raster.height)
            let image = NSImage(size: size)
            image.lockFocus()
            if let still {
                NSImage(cgImage: still, size: size).draw(in: CGRect(origin: .zero, size: size))
                DesignValues.nsColor("stage").withAlphaComponent(0.15).setFill()
                CGRect(origin: .zero, size: size).fill()
            }
            else { DesignValues.nsColor("stage").setFill(); CGRect(origin: .zero, size: size).fill() }
            NSImage(cgImage: overlay, size: size).draw(in: CGRect(origin: .zero, size: size))
            image.unlockFocus()
            return image
        } catch { return nil }
    }

    /// A caption card (design §5.4.3): VoxClipCore's card words set by the export
    /// renderer at the largest size that fits, taking the card's shorter forms when none
    /// does, over the style's card backdrop. Composited off the main actor.
    func card(_ input: CaptionCardInput) async -> CGImage? {
        let overrides = (try? JSONEncoder().encode(input.overrides)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let words = input.text.words.map { "\($0.id)=\($0.text)" }.joined(separator: "\u{1F}")
        let key = [input.style.id, input.previewBackground ?? "", overrides, input.language ?? "", "\(input.fit)", "\(input.text.keyIndex)", "\(input.text.time)", words].joined(separator: "|")
        if let cached = cards[key] {
            cardOrder.removeAll { $0 == key }
            cardOrder.append(key)
            return cached
        }
        guard let image = await drawCard(input) else { return nil }
        if cards.updateValue(image, forKey: key) == nil {
            cardOrder.append(key)
            cardBytes += image.bytesPerRow * image.height
        }
        while cardBytes > 8 << 20, cardOrder.count > 1, let oldest = cardOrder.first {
            cardOrder.removeFirst()
            if let dropped = cards.removeValue(forKey: oldest) { cardBytes -= dropped.bytesPerRow * dropped.height }
        }
        return image
    }

    private func drawCard(_ input: CaptionCardInput) async -> CGImage? {
        guard let tools = try? services() else { return nil }
        let (pipeline, rasterizer) = tools
        let fit = input.fit
        let frame = PixelSize(width: fit.width, height: fit.height)
        var style = await pipeline.resolve(input.style, overrides: input.overrides, frame: frame).style
        let backdrop = CaptionCardLook.backdrop(style, previewBackground: input.previewBackground)
        guard !input.text.words.isEmpty else {
            return await Task.detached(priority: .utility) { CaptionCardLook.compose(nil, backdrop: backdrop, width: fit.width, height: fit.height) }.value
        }
        let lines = input.text.maxLines(on: fit.surface)
        CaptionCardLook.adapt(&style, fit: fit, lines: lines, backdrop: backdrop ?? "#000000")
        var next: CaptionCardText? = input.text
        while let card = next {
            // The card's own clock and emphasis; the adapted style is already resolved,
            // so the layout gets no overrides or position of its own.
            let layoutInput = { (sized: CaptionStyle) in
                CaptionLayoutInput(style: sized.id, frame: .init(width: fit.width, height: fit.height), language: input.language ?? "und",
                                   duration: card.duration, captions: .init(position: nil), words: card.layoutWords)
            }
            var low = fit.fontMin, high = fit.fontMax
            var best: CaptionLayoutResult?
            while low <= high {
                let size = (low + high) / 2
                var sized = style
                sized.font.sizeSh = Double(size) / Double(min(fit.width, fit.height))
                sized.layout.maxWords = card.words.count
                if let layout = try? await pipeline.layout(input: layoutInput(sized), style: sized),
                   CaptionCardLook.fits(layout, fit: fit, count: card.words.count, lines: lines) {
                    best = layout
                    low = size + 1
                } else { high = size - 1 }
            }
            if let best {
                guard let raster = try? await rasterizer.rasterize(best, time: card.time, reduceMotion: true) else { return nil }
                return await Task.detached(priority: .utility) { CaptionCardLook.compose(raster, backdrop: backdrop, width: fit.width, height: fit.height) }.value
            }
            next = card.droppingLastWord()
        }
        return nil
    }
}
