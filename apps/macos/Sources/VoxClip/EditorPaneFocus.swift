import SwiftUI

/// F6 order (impl-plan §3.2): Explorer → tab and clip-bar rows → transcript → viewer →
/// panel → timeline → status bar. A hidden Explorer, right column or timeline panel is no
/// stop; an Explorer or right column shown over the editor is.
enum EditorPane: CaseIterable {
    case sidebar, tabs, transcript, viewer, panel, timeline, status
    static func order(explorerVisible: Bool, viewerVisible: Bool, timelineVisible: Bool) -> [Self] {
        allCases.filter { pane in
            switch pane {
            case .sidebar: explorerVisible
            case .viewer, .panel: viewerVisible
            case .timeline: timelineVisible
            case .tabs, .transcript, .status: true
            }
        }
    }
    static func isCycleKey(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        code == 97 && modifiers.intersection([.command, .option]).isEmpty
    }
    static func entersSelectionBar(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        code == 48 && modifiers.intersection([.shift, .command, .option, .control]).isEmpty
    }
}

/// The shell's AppKit F6 stops in its window: the tab and clip-bar rows, the transcript's
/// text view and the status bar (EditorShellController). The SwiftUI panes take focus
/// through `EditorPaneFocus`.
@MainActor protocol ShellChromeFocus: AnyObject {
    /// The pane that holds keyboard focus when it is one of these stops.
    func paneHoldingFocus() -> EditorPane?
    /// Puts keyboard focus in one of these stops. False when it cannot take it.
    @discardableResult func focus(_ pane: EditorPane) -> Bool
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
    /// Moves `focusedPane` one stop along `order` and asks that pane to take focus.
    func movePaneFocus(backward: Bool, through order: [EditorPane]) {
        guard !order.isEmpty else { return }
        let index: Int = order.firstIndex(of: focusedPane) ?? order.firstIndex(of: .transcript) ?? 0
        let offset: Int = backward ? order.count - 1 : 1
        focusedPane = order[(index + offset) % order.count]
        paneFocusRequest += 1
    }
}

extension WorkspaceShell {
    /// F6 and ⇧F6 in this shell's window: the next or previous of its stops. It starts from
    /// the AppKit stop or the transcript holding focus, else the editor's last pane.
    func movePaneFocus(backward: Bool) {
        guard let editor, !showsHome else { return }
        if let holding = chromeFocus?.paneHoldingFocus() { editor.focusedPane = holding }
        editor.movePaneFocus(backward: backward, through: paneOrder)
        switch editor.focusedPane {
        case .tabs, .transcript, .status:
            if chromeFocus?.focus(editor.focusedPane) != true, editor.focusedPane == .transcript { _ = focusTranscript(in: windowController?.window ?? editor.window) }
        case .sidebar, .viewer, .panel, .timeline: break
        }
    }
}
