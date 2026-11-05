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
    var policyOverride: EditorAccessibilityPolicy?
    /// "✦ Rewrite as ▾" opens or closes the tone strip under the bar (design.md §6.3.1); nil hides the verb.
    var rewriteAs: (() -> Void)?
    var stripOpen = false
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool
    private var policy: EditorAccessibilityPolicy {
        let system = EditorAccessibilityPolicy.system
        return policyOverride ?? EditorAccessibilityPolicy(reduceMotion: system.reduceMotion,
            reduceTransparency: reduceTransparency || system.reduceTransparency,
            increaseContrast: contrast == .increased || system.increaseContrast)
    }
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
            // ✦ Rewrite as first (design.md §6.3.1): one click opens the tone strip under the bar, a chip rewrites the words
            // at once, and ⇧⌘R asks the default tone. Text Rewrite needs no Voice Lab.
            if let rewriteAs, !model.selectedIDs.isEmpty, model.capabilities.ai {
                Button(action: rewriteAs) { label("\u{2726} Rewrite as \u{25BE}", "⇧⌘R") }
                    .background(stripOpen ? DesignValues.color("bg.selectedRow") : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .help("Rewrite these words in a tone. ⇧⌘R uses your default, \(model.defaultRewriteItem?.title ?? "Fix mistakes").")
                    .accessibilityLabel("Rewrite as")
                    .accessibilityValue(stripOpen ? "Tones shown" : "")
                    .accessibilityIdentifier("voxclip.selectionBar.rewriteAs")
            }
            // ✦ Ask Claude second (design.md §6.8): one inline field in the right panel; nothing is sent until Return.
            if model.canAskClaude, model.askClaudeWordSelection != nil {
                Button { model.openAskClaudeOnSelection(); dismiss() } label: { label("\u{2726} Ask Claude", "") }
                    .help("Ask Claude to censor, add an overlay or change timing on these words")
                    .accessibilityLabel("Ask Claude")
                    .accessibilityIdentifier("voxclip.selectionBar.askClaude")
                Divider().frame(height: 18)
            }
            Button { model.makeClip(); dismiss() } label: { label("Make Clip", "⌥⌘K") }
                .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .focused($focused)
                .help(makeClipHelp)
            Button { model.cutSelection(); dismiss() } label: { label("Cut", "⌫") }
            Button { model.cutSelection(restore: true); dismiss() } label: { label("Restore", "⇧⌫") }
                .disabled(model.selectedWordIDs.isDisjoint(with: model.cutWordIDs) && model.selectedPauseIDs.isDisjoint(with: model.cutPauseIDs))
        }
        .buttonStyle(.plain)
        .disabled(!model.capabilities.edit)
        .font(.system(size: 13))
        .foregroundStyle(DesignValues.color("text.primary"))
        .padding(.horizontal, 6)
        .frame(height: 36)
    }
    @ViewBuilder private var surface: some View {
        if forceOpaque || policy.opaqueSelectionBar {
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
            if !shortcut.isEmpty { Text(shortcut).font(DesignValues.mono(11)).foregroundStyle(DesignValues.color("text.secondary")) }
        }.padding(.horizontal, 8).frame(minWidth: EditorAccessibilityPolicy.minimumTarget, minHeight: 26).contentShape(Rectangle())
    }
    private var makeClipHelp: String {
        if let clip = model.sortedClips.first(where: { $0.startWordId == model.selectedIDs.first && $0.endWordId == model.selectedIDs.last }), let number = model.clipNumber(clip.id) {
            return "Clip \(number) already covers these words."
        }
        return "Make Clip (⌥⌘K)"
    }
}
