import AppKit
import SwiftUI

func selectionBarFrame(lineRects: [CGRect], visibleRect: CGRect, barSize: CGSize, toolbarInset: CGFloat) -> CGRect {
    let lines = lineRects.filter { !$0.isEmpty }.sorted { $0.minY < $1.minY }
    guard let first = lines.first, let last = lines.last, barSize.width <= visibleRect.width - 8 else { return .zero }
    let left = min(max(first.minX - 4, visibleRect.minX + 4), visibleRect.maxX - barSize.width - 4)
    let top = max(visibleRect.minY, toolbarInset)
    let candidates = [first.minY - 8 - barSize.height, last.maxY + 8]
    for origin in candidates {
        let frame = CGRect(origin: CGPoint(x: left, y: origin), size: barSize)
        if frame.minY >= top, frame.maxY <= visibleRect.maxY, !lines.contains(where: { $0.intersects(frame) }) { return frame }
    }
    return .zero
}

@MainActor struct SelectionBar: View {
    let model: EditorModel
    var focusRequest = 0
    var forceOpaque = false
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool
    var body: some View {
        surface
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 36)
            .tint(DesignValues.accentText)
            .onExitCommand(perform: dismiss)
            .task(id: focusRequest) { if focusRequest > 0 { focused = true } }
    }
    private var controls: some View {
        HStack(spacing: 4) {
            Button { model.makeClip(); dismiss() } label: { label("Make Clip", "⌘K") }
                .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .focused($focused)
                .help(makeClipHelp)
            Button { model.cutSelection(); dismiss() } label: { label("Cut", "⌫") }
            Button { model.cutSelection(restore: true); dismiss() } label: { label("Restore", "⇧⌫") }
                .disabled(model.selectedWordIDs.isDisjoint(with: model.cutWordIDs) && model.selectedPauseIDs.isDisjoint(with: model.cutPauseIDs))
            if RewriteEntryPolicy.buildEnabled && model.app.bool("voiceLab.enabled") {
                Divider().frame(height: 18)
                Button { model.beginRewrite(); dismiss() } label: { label("Rewrite…", "⇧⌘R") }.disabled(!model.capabilities.ai)
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.capabilities.edit)
        .font(.system(size: 13))
        .foregroundStyle(DesignValues.color("text.primary"))
        .padding(.horizontal, 6)
        .frame(height: 36)
    }
    @ViewBuilder private var surface: some View {
        if forceOpaque || reduceTransparency || contrast == .increased {
            controls.background(DesignValues.color("bg.elevated"), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(DesignValues.color("line.strong"), lineWidth: 1) }
        } else if #available(macOS 26, *) {
            controls.glassEffect(.regular, in: .rect(cornerRadius: 10))
        } else {
            controls.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func label(_ title: String, _ shortcut: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(shortcut).font(DesignValues.mono(11)).foregroundStyle(DesignValues.color("text.secondary"))
        }.padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
    }
    private var makeClipHelp: String {
        if let clip = model.sortedClips.first(where: { $0.startWordId == model.selectedIDs.first && $0.endWordId == model.selectedIDs.last }), let number = model.clipNumber(clip.id) {
            return "Clip \(number) already covers these words."
        }
        return "Make Clip (⌘K)"
    }
}
