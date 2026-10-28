import AppKit
import SwiftUI

struct EditorAccessibilityPolicy: Equatable {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool
    static let minimumTarget: CGFloat = 24
    var opaqueSelectionBar: Bool { reduceTransparency || increaseContrast }
    var transcriptScrollDuration: Double { reduceMotion ? 0 : 0.12 }
    var timelineZoomDuration: Double { reduceMotion ? 0 : 0.24 }
    var crossfadeDuration: Double { reduceMotion ? 0 : 0.12 }
    static let staticCaptionTiles = true
    @MainActor static var system: Self {
        let workspace = NSWorkspace.shared
        return Self(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }
}

enum EditorIconAction: CaseIterable {
    case back, play, pause, forward, closeRewrite, hideViewer, showViewer, previousMatch, nextMatch, closeFind
    var name: String {
        switch self {
        case .back: "Back 3 seconds"
        case .play: "Play"
        case .pause: "Pause"
        case .forward: "Forward 3 seconds"
        case .closeRewrite: "Close Rewrite"
        case .hideViewer: "Hide Viewer"
        case .showViewer: "Show Viewer"
        case .previousMatch: "Previous match"
        case .nextMatch: "Next match"
        case .closeFind: "Close find"
        }
    }
    static func suggestion(keep: Bool, number: Int) -> String {
        "\(keep ? "Keep" : "Dismiss") suggested clip \(number)"
    }
}

struct SidebarActionTarget: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: EditorAccessibilityPolicy.minimumTarget, minHeight: EditorAccessibilityPolicy.minimumTarget)
            .contentShape(Rectangle())
    }
}
