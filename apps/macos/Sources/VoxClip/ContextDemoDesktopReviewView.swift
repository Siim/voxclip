import SwiftUI
import VoxClipCore

@MainActor struct ContextDemoDesktopReviewView: View {
    @Bindable var session: ContextDemoSession
    @State private var textControlID = ""
    @State private var replacement = ""
    @State private var nonsecretConfirmed = false
    @State private var pauseMilliseconds = 500

    private var review: ContextDemoDesktopReviewSession { session.desktopReview }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional reviewed app actions").font(VCType.body.font(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Manual recording remains available without app actions. Checking access and inspecting never run an action. Only Start Recording approves the exact reviewed plan; this is not an autonomous AI agent.")
                .foregroundStyle(DesignValues.color("text.secondary"))
            Text(ContextDemoDesktopPlan.reviewWarning)
                .foregroundStyle(DesignValues.color("text.secondary"))
            Text("No passwords, forms, global keyboard events, coordinates or command fallback. Some apps cannot expose an exact accessible window; VoxClip will refuse rather than choose another window.")
                .foregroundStyle(DesignValues.color("text.secondary"))
            Button("Check Accessibility Access", action: session.checkDesktopAccess)
                .accessibilityHint("Checks only the existing Accessibility grant without requesting permission or opening Settings.")
                .accessibilityIdentifier("voxclip.demo.desktop.checkAccess")
            Button("Inspect Selected Window", action: session.inspectDesktopWindow)
                .disabled(session.selectedWindow == nil || !review.canInspect)
                .accessibilityHint("Reads only stable control identifiers and capabilities from the exact chosen window. Does not read field values or perform actions.")
                .accessibilityIdentifier("voxclip.demo.desktop.inspect")
            if let snapshot = review.snapshot {
                Text("Window \(snapshot.identity.window.windowID) · process \(snapshot.identity.window.processID) · \(snapshot.identity.window.bundleID)")
                    .textSelection(.enabled)
                DisclosureGroup("Stable controls (\(snapshot.controls.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshot.controls) { control in controlRow(control) }
                    }
                }
                replacementFields(snapshot.controls)
                if review.usesActions {
                    Stepper("Pause: \(pauseMilliseconds) milliseconds", value: $pauseMilliseconds,
                        in: 1...ContextDemoDesktopLimits.maximumPauseMilliseconds, step: 100)
                    Button("Add Pause") { session.appendDesktopAction(.pause(milliseconds: pauseMilliseconds)) }
                        .accessibilityIdentifier("voxclip.demo.desktop.addPause")
                }
            }
            if review.usesActions {
                Text("Draft app actions (\(review.actions.count)/\(ContextDemoDesktopLimits.maximumActions))")
                    .font(VCType.body.font(.semibold))
                ForEach(Array(review.actions.enumerated()), id: \.offset) { index, action in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(action.reviewDescription)").textSelection(.enabled)
                        Button("Remove Action \(index + 1)") { session.removeDesktopAction(at: index) }
                            .accessibilityIdentifier("voxclip.demo.desktop.removeAction.\(index)")
                    }
                }
                Text("Review Capture binds these exact actions, source and window to a digest. Each control step budgets one second; pauses and a half-second margin must fit the selected recording duration.")
                    .foregroundStyle(DesignValues.color("text.secondary"))
            } else {
                Text("No app actions selected. Review Capture will record this window for you to demonstrate manually.")
                    .foregroundStyle(DesignValues.color("text.secondary"))
            }
            if let message = review.message {
                Text(message).foregroundStyle(DesignValues.color("text.secondary"))
                    .accessibilityIdentifier("voxclip.demo.desktop.message")
            }
            if review.isDraining {
                Text("Stopping and discarding the cancelled recording. Wait for capture and app actions to finish draining.")
                    .accessibilityIdentifier("voxclip.demo.desktop.draining")
            }
        }
        .disabled(review.isDraining)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.demo.desktop.review")
        .onChange(of: review.snapshot?.inspectionID) { _, _ in clearReplacement() }
        .onChange(of: textControlID) { _, _ in replacement = ""; nonsecretConfirmed = false }
        .onDisappear { clearReplacement() }
    }

    private func controlRow(_ control: ContextDemoDesktopControl) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(control.node.role) · AXIdentifier: \(control.node.identifier)").textSelection(.enabled)
            Text("Capabilities: \(control.capabilities.map(\.rawValue).joined(separator: ", "))")
                .foregroundStyle(DesignValues.color("text.secondary"))
            Menu("Add Action for \(control.node.identifier)") {
                if control.capabilities.contains(.focus) {
                    Button("Focus") { session.appendDesktopAction(.focus(control)) }
                }
                if control.capabilities.contains(.press) {
                    Button("Press Once") { session.appendDesktopAction(.press(control)) }
                }
                if control.capabilities.contains(.increment) {
                    Button("Scroll One Increment") { session.appendDesktopAction(.scroll(control, direction: .increment)) }
                }
                if control.capabilities.contains(.decrement) {
                    Button("Scroll One Decrement") { session.appendDesktopAction(.scroll(control, direction: .decrement)) }
                }
                if control.capabilities.contains(.setNonsecretValue) {
                    Button("Choose for Nonsecret Text…") { textControlID = control.id }
                }
            }
            .accessibilityIdentifier("voxclip.demo.desktop.control.\(control.id)")
        }
    }

    @ViewBuilder private func replacementFields(_ controls: [ContextDemoDesktopControl]) -> some View {
        if let control = controls.first(where: { $0.id == textControlID && $0.capabilities.contains(.setNonsecretValue) }) {
            Text("New nonsecret text for AXIdentifier: \(control.node.identifier)")
            TextField("Nonsecret demonstration text only", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("New nonsecret text, not a password or form value")
                .accessibilityIdentifier("voxclip.demo.desktop.nonsecretValue")
            Toggle("This is nonsecret demonstration text, not a password, credential or form submission.", isOn: $nonsecretConfirmed)
                .accessibilityIdentifier("voxclip.demo.desktop.confirmNonsecret")
            Button("Add Nonsecret Text Replacement") {
                session.appendDesktopAction(.setNonsecretValue(control, value: replacement))
                clearReplacement()
            }
            .disabled(!nonsecretConfirmed || replacement.isEmpty || replacement.utf8.count > ContextDemoDesktopLimits.maximumReplacementBytes)
            .accessibilityIdentifier("voxclip.demo.desktop.addNonsecretValue")
        }
    }

    private func clearReplacement() {
        textControlID = ""
        replacement = ""
        nonsecretConfirmed = false
    }
}
