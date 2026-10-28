import SwiftUI

enum EditorPane: CaseIterable { case sidebar, toolbar, transcript, viewer, panel, timeline }

@MainActor struct EditorPaneFocus: ViewModifier {
    let model: EditorModel?
    let pane: EditorPane
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focusable().focused($focused)
            .onChange(of: model?.paneFocusRequest) { _, _ in
                if model?.focusedPane == pane { focused = true }
            }
            .onChange(of: focused) { _, value in if value { model?.focusedPane = pane } }
    }
}

extension EditorModel {
    func movePaneFocus(backward: Bool) {
        var panes: [EditorPane] = [.sidebar, .toolbar, .transcript]
        if app.shell.viewerVisible { panes += [.viewer, .panel] }
        panes.append(.timeline)
        let index: Int = panes.firstIndex(of: focusedPane) ?? 2
        let offset: Int = backward ? panes.count - 1 : 1
        let next: Int = (index + offset) % panes.count
        focusedPane = panes[next]
        paneFocusRequest += 1
        if focusedPane == .transcript { _ = focusTranscript(in: window) }
    }
}
