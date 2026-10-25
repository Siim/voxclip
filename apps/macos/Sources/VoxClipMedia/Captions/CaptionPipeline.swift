import Foundation
import VoxClipCore

public actor CaptionPipeline {
    private let resources: CaptionResources
    private let shaper: CoreTextShaper

    public init(shared: SharedResources) throws {
        let resources = try CaptionResources.load(shared: shared)
        self.resources = resources
        shaper = CoreTextShaper(shared: shared, resources: resources)
    }

    public func resolve(_ style: CaptionStyle, overrides: [String: JSONValue], frame: PixelSize) -> CaptionStyleResolver.Resolution {
        let input = CaptionLayoutInput(style: style.id, frame: .init(width: frame.width, height: frame.height),
            language: "und", duration: 0, captions: .init(overrides: overrides), words: [])
        do {
            return try CaptionStyleResolver.resolution(style, input: input, resources: resources)
        } catch {
            return .init(style: style, rejectedOverrides: true)
        }
    }

    public func layout(words: [CaptionWord], language: String?, style: CaptionStyle, position: CaptionPosition?, frame: PixelSize, duration: Double) async throws -> CaptionLayoutResult {
        let input = CaptionLayoutInput(style: style.id, frame: .init(width: frame.width, height: frame.height), language: language ?? "und", duration: duration,
            captions: .init(position: position), words: words.map { .init(id: $0.id, text: $0.text, start: $0.start, end: $0.end) })
        do {
            return try await CaptionLayoutEngine.build(input: input, style: style, resources: resources, shaper: shaper, resolvedStyle: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VoxClipError {
            throw error
        } catch {
            throw VoxClipError.projectUnreadable("Invalid caption layout")
        }
    }
}
