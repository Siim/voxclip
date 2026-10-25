import Foundation
import CoreText
import CoreGraphics
import VoxClipCore

/// Bundled-font shaping; captions §4.3. Skeleton never uses a system fallback.
public actor CoreTextShaper: GlyphShaper {
    public init(shared: SharedResources) {}
    public func shape(_ request: GlyphShapeRequest) async throws -> [ShapedRun] { throw VoxClipError.notImplemented("mac-captions") }
}

/// Single outline-based rasterizer; captions §13 and architecture §5.4. Used by preview/export/goldens.
public actor CoreTextCaptionRasterizer: VoxClipCore.CaptionRasterizer {
    public init(shared: SharedResources) {}
    public func rasterize(_ request: CaptionRasterRequest) async throws -> CaptionRaster { throw VoxClipError.notImplemented("mac-captions") }
}
