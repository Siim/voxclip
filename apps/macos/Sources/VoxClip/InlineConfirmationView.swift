import AppKit
import SwiftUI

/// f22/f22b/f22c: the v4 approval row in the slot below the clip bar. It occupies space above the words.
@MainActor struct ConnectorConfirmationView: View {
    @Bindable var confirmation: ConnectorConfirmation
    var model: EditorModel?
    var compact = true
    @FocusState private var rowFocused: Bool
    @FocusState private var keyFocused: Bool

    var body: some View {
        if let prompt = confirmation.prompt {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: prompt.billed ? "key" : "person.crop.circle")
                    .font(.system(size: 14)).foregroundStyle(DesignValues.color("text.secondary"))
                    .padding(.top, 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.message).font(.system(size: 12)).foregroundStyle(DesignValues.color("text.primary"))
                    ForEach(Array(prompt.details.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
                    }
                    if prompt.needsKey {
                        Text("Add your \(prompt.providerName) API key first. It is saved in the macOS Keychain; saving makes no request.")
                            .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
                        HStack {
                            SecureField("\(prompt.providerName) API key", text: $confirmation.key)
                                .textFieldStyle(.roundedBorder).focused($keyFocused)
                                .onSubmit { Task { await confirmation.saveKey() } }
                            Button("Save Key") { Task { await confirmation.saveKey() } }
                                .disabled(confirmation.savingKey || confirmation.key.isEmpty)
                        }.padding(.top, 6)
                        if let error = confirmation.keyError { Text(error).font(.system(size: 11)).foregroundStyle(DesignValues.color("status.warning")) }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 9) { actions(prompt); Spacer(minLength: 4); note(prompt) }
                        VStack(alignment: .leading, spacing: 6) { HStack(spacing: 9) { actions(prompt) }; note(prompt) }
                    }.padding(.top, 6)
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignValues.color("bg.raised"), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignValues.color("line.edge"), lineWidth: 1))
            .padding(.horizontal, compact ? 12 : 0).padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain).accessibilityLabel("Confirm send")
            .accessibilityIdentifier("voxclip.inline.confirmSend")
            .focusable().focused($rowFocused)
            .onAppear {
                // Focus the group, never the billed button. Space keeps controlling the video.
                rowFocused = true
                model?.announce("\(prompt.message) \(prompt.note)")
            }
            .onExitCommand { confirmation.cancel() }
            .onKeyPress(keys: [.return], phases: [.down, .repeat]) { press in
                guard !keyFocused else { return .ignored }
                _ = confirmation.pressReturn(timestamp: NSApp.currentEvent?.timestamp ?? 0,
                    now: ProcessInfo.processInfo.systemUptime, isRepeat: press.phase == .repeat,
                    command: press.modifiers.contains(.command))
                return .handled
            }
            .onKeyPress(keys: [.space]) { press in
                guard !keyFocused, press.modifiers.isEmpty, let model else { return .ignored }
                model.transport(" "); return .handled
            }
        }
    }
    @ViewBuilder private func actions(_ prompt: ConnectorSendPrompt) -> some View {
        if !prompt.needsKey {
            InlinePrimaryButton(title: prompt.confirm, accented: prompt.billed, height: 22,
                help: prompt.message, action: { confirmation.approve() },
                keyAction: { event in
                    _ = confirmation.pressReturn(timestamp: event.timestamp, now: ProcessInfo.processInfo.systemUptime,
                        isRepeat: event.isARepeat, command: event.modifierFlags.contains(.command))
                }, spaceAction: { model?.transport(" ") })
                .accessibilityIdentifier("voxclip.inline.send")
        }
        Button(prompt.cancel) { confirmation.cancel() }.buttonStyle(.plain)
            .font(.system(size: 12)).foregroundStyle(DesignValues.color("text.secondary"))
            .frame(minHeight: 22).padding(.horizontal, 9)
    }
    @ViewBuilder private func note(_ prompt: ConnectorSendPrompt) -> some View {
        if prompt.needsKey { Text("Send appears once the key is saved.").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")) }
        else if let url = prompt.pricingURL {
            Text(LocalizedStringKey("VoxClip can't tell what this costs. Check [\(prompt.pricingName)'s pricing.](\(url.absoluteString))"))
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
        } else { Text(prompt.note).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")) }
    }
}

/// Billed buttons never have a default Return/Space key equivalent. Keyboard activation goes through the same guard
/// as the row; clicks and accessibility presses remain explicit approvals. Also reused by inline Transcribe.
@MainActor struct InlinePrimaryButton: NSViewRepresentable {
    let title: String
    var accented = true
    var height: CGFloat = 28
    var help = ""
    let action: @MainActor () -> Void
    var keyAction: (@MainActor (NSEvent) -> Void)?
    var spaceAction: (@MainActor () -> Void)?
    func makeNSView(context: Context) -> InlineGuardedButton { InlineGuardedButton() }
    func updateNSView(_ button: InlineGuardedButton, context: Context) {
        button.title = title; button.accented = accented; button.controlHeight = height
        button.isEnabled = context.environment.isEnabled
        button.actionHandler = action; button.returnHandler = keyAction; button.spaceHandler = spaceAction
        button.setAccessibilityLabel(title); button.setAccessibilityHelp(help)
        button.invalidateIntrinsicContentSize(); button.needsDisplay = true
    }
}

@MainActor final class InlineGuardedButton: NSButton {
    var accented = false
    var controlHeight: CGFloat = 28
    var actionHandler: @MainActor () -> Void = {}
    var returnHandler: (@MainActor (NSEvent) -> Void)?
    var spaceHandler: (@MainActor () -> Void)?
    init() {
        super.init(frame: .zero)
        isBordered = false; bezelStyle = .rounded; target = self; action = #selector(pressed)
        setButtonType(.momentaryPushIn)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func pressed() { if isEnabled { actionHandler() } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        return NSSize(width: ceil(width) + 18, height: controlHeight)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.keyCode == 36 || event.keyCode == 76 { returnHandler?(event); return }
        if event.keyCode == 49, let spaceHandler { if !event.isARepeat { spaceHandler() }; return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let usesAccent = accented && isEnabled
        (usesAccent ? DesignValues.nsColor(isHighlighted ? "tint.pressed" : "tint.default") : DesignValues.nsColor("bg.muted")).setFill(); shape.fill()
        if !usesAccent { DesignValues.nsColor("line.edge").setStroke(); shape.stroke() }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: !isEnabled ? DesignValues.nsColor("text.tertiary") : usesAccent ? DesignValues.nsColor("tint.on") : DesignValues.nsColor("text.primary")]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if isEnabled && window?.firstResponder === self { DesignValues.nsColor("text.primary").setStroke(); shape.lineWidth = 2; shape.stroke() }
    }
}
