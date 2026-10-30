import SwiftUI
#if DEBUG
import AppKit

@MainActor final class DebugButtonActions {
    static var current: DebugButtonActions?
    struct Entry {
        let token: UUID
        let trigger: @MainActor () -> Void
    }
    var entries: [String: Entry] = [:]
    func press(_ identifier: String) throws {
        guard let entry = entries[identifier] else {
            throw CocoaError(.coderInvalidValue)
        }
        entry.trigger()
    }
}

private struct DebugActionButtonStyle: PrimitiveButtonStyle {
    let identifier: String
    let actions: DebugButtonActions
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background {
            DebugActionProbe(identifier: identifier, actions: actions) { configuration.trigger() }
        }
    }
}

private struct DebugActionProbe: NSViewRepresentable {
    let identifier: String
    let actions: DebugButtonActions
    let trigger: @MainActor () -> Void
    final class Coordinator {
        let token = UUID()
        let identifier: String
        let actions: DebugButtonActions
        init(identifier: String, actions: DebugButtonActions) {
            self.identifier = identifier
            self.actions = actions
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(identifier: identifier, actions: actions) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        actions.entries[identifier] = .init(token: context.coordinator.token, trigger: trigger)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if coordinator.actions.entries[coordinator.identifier]?.token == coordinator.token {
            coordinator.actions.entries[coordinator.identifier] = nil
        }
    }
}
#endif

extension View {
    @ViewBuilder func auditButtonAction(_ identifier: String) -> some View {
        #if DEBUG
        if let actions = DebugButtonActions.current {
            buttonStyle(DebugActionButtonStyle(identifier: identifier, actions: actions))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
