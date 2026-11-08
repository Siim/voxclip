import Foundation

/// The bands of a frame that feeds cover with their own buttons and text (design.md §5.1): 9:16 has bands over the top 12%
/// and the bottom 22%, 1:1 over the bottom 12% and 16:9 over the bottom 10%. The stage draws them while a caption is
/// dragged, and the export check (ADR-R49) warns when a caption card or the title reaches into one.
public enum CaptionSafeZones {
    public enum Edge: String, Codable, Sendable { case top, bottom }

    public struct Band: Sendable, Equatable {
        public let edge: Edge
        /// The band's depth, as a fraction of the frame's height from its edge.
        public let fraction: Double
        public init(edge: Edge, fraction: Double) { self.edge = edge; self.fraction = fraction }
    }

    /// 9:16's right-hand column where feeds stack their buttons: the stage draws it as a guide only, and the check leaves
    /// it out, as captions sit centred across the frame.
    public static let portraitSideFraction = 0.12

    /// The bands of a frame of the aspect class `CaptionStyleResolver.aspect` names: "portrait", "square" or "landscape".
    public static func bands(aspectClass: String) -> [Band] {
        switch aspectClass {
        case "portrait": [Band(edge: .top, fraction: 0.12), Band(edge: .bottom, fraction: 0.22)]
        case "square": [Band(edge: .bottom, fraction: 0.12)]
        case "landscape": [Band(edge: .bottom, fraction: 0.10)]
        default: []
        }
    }

    /// The bands of a `width`×`height` frame.
    public static func bands(width: Int, height: Int) -> [Band] {
        bands(aspectClass: CaptionStyleResolver.aspect(width: width, height: height))
    }

    /// How far `rect` (top-left origin, in fractions of the frame) reaches into `band`, as a fraction of the frame's
    /// height; 0 when it is clear of it.
    public static func overlap(_ rect: CaptionRect, band: Band) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        switch band.edge {
        case .top: return max(0, min(band.fraction, rect.y + rect.height) - max(0, rect.y))
        case .bottom:
            let start = 1 - band.fraction
            return max(0, min(1, rect.y + rect.height) - max(start, rect.y))
        }
    }
}
