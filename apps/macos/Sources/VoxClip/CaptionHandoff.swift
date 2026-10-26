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
}
