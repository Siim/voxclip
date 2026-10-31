import SwiftUI

/// F6 order. The toolbar pane went with the toolbar (impl-plan V1a); V1b adds the tab
/// and clip-bar rows and the status bar.
enum EditorPane: CaseIterable {
    case sidebar, transcript, viewer, panel, timeline
    static func order(viewerVisible: Bool) -> [Self] {
        viewerVisible ? allCases : [.sidebar, .transcript, .timeline]
    }
    static func isCycleKey(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        code == 97 && modifiers.intersection([.command, .option]).isEmpty
    }
    static func entersSelectionBar(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        code == 48 && modifiers.intersection([.shift, .command, .option, .control]).isEmpty
    }
}

@MainActor struct EditorPaneFocus: ViewModifier {
    let model: EditorModel?
    let pane: EditorPane
    @FocusState private var focused: Bool
    /// The whole-pane ring marks a pane reached from the keyboard (⌃F6, Tab), not the focus a launch or a click gives it.
    @State private var ringVisible = false
    func body(content: Content) -> some View {
        content.focusable().focused($focused).focusSection()
            .focusEffectDisabled(!ringVisible)
            .onChange(of: model?.paneFocusRequest) { _, _ in
                if model?.focusedPane == pane { ringVisible = true; focused = true }
            }
            .onChange(of: focused) { _, value in
                if value { model?.focusedPane = pane; ringVisible = ringVisible || NSApp.currentEvent?.type == .keyDown } else { ringVisible = false }
            }
    }
}

extension EditorModel {
    func movePaneFocus(backward: Bool) {
        let panes = EditorPane.order(viewerVisible: app.shell.layout.rightVisible)
        let index: Int = panes.firstIndex(of: focusedPane) ?? panes.firstIndex(of: .transcript) ?? 0
        let offset: Int = backward ? panes.count - 1 : 1
        let next: Int = (index + offset) % panes.count
        focusedPane = panes[next]
        paneFocusRequest += 1
        if focusedPane == .transcript { _ = focusTranscript(in: window) }
    }
}
