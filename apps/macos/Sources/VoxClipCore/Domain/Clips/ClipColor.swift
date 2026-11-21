import Foundation

public struct ClipColorAdjustments: Codable, Sendable, Equatable {
    public enum Control: String, CaseIterable, Sendable {
        case brightness, contrast, saturation, warmth

        public var label: String { rawValue.capitalized }
    }

    public static let range = -100...100
    public static let neutral = Self()

    public var brightness: Int
    public var contrast: Int
    public var saturation: Int
    public var warmth: Int

    public init(brightness: Int = 0, contrast: Int = 0, saturation: Int = 0, warmth: Int = 0) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
    }

    public subscript(_ control: Control) -> Int {
        get {
            switch control {
            case .brightness: brightness
            case .contrast: contrast
            case .saturation: saturation
            case .warmth: warmth
            }
        }
        set {
            let value = min(Self.range.upperBound, max(Self.range.lowerBound, newValue))
            switch control {
            case .brightness: brightness = value
            case .contrast: contrast = value
            case .saturation: saturation = value
            case .warmth: warmth = value
            }
        }
    }

    var isValid: Bool { self != .neutral && Control.allCases.allSatisfy { Self.range.contains(self[$0]) } }
}

public enum ClipColorPreset: String, CaseIterable, Sendable {
    case original, muted, warm, bw
    case cleanPop, softLight, coolFilm, vintageFade

    public var label: String {
        switch self {
        case .original: "As filmed"
        case .cleanPop: "Clean Pop"
        case .softLight: "Soft Light"
        case .coolFilm: "Cool Film"
        case .vintageFade: "Vintage Fade"
        default: baseLook.label
        }
    }

    public var baseLook: ClipLook { ClipLook(rawValue: rawValue) ?? .original }

    public var adjustments: ClipColorAdjustments? {
        switch self {
        case .cleanPop: .init(brightness: 8, contrast: 22, saturation: 18)
        case .softLight: .init(brightness: 26, contrast: -16, saturation: -8)
        case .coolFilm: .init(contrast: 23, saturation: -22, warmth: -30)
        case .vintageFade: .init(brightness: 8, contrast: -36, saturation: -32, warmth: 30)
        default: nil
        }
    }

    public static func matching(_ controls: ProjectClipControls) -> Self? {
        allCases.first { $0.baseLook == controls.look && $0.adjustments == controls.colorAdjustments }
    }
}
