import SwiftUI
import Observation
import VoxClipCore
import VoxClipMedia

/// Main-actor app state; architecture §7.1. No service is started by the skeleton.
@MainActor @Observable public final class AppModel {
    public var startupError: VoxClipError?
    public init() {
        do { _ = try SharedResources.locate() }
        catch { startupError = .sharedResourcesMissing }
    }
}

/// Native document app scenes; architecture §1, §3 and design §2–3.
@main @MainActor struct VoxClipApp: App {
    @State private var appModel = AppModel()
    var body: some Scene {
        DocumentGroup(newDocument: { VoxClipDocument() }) { configuration in
            EditorView(document: configuration.document)
                .environment(appModel)
        }
        .defaultSize(width: 1200, height: 760)
        .windowToolbarStyle(.unified)
        .commands { WelcomeCommands() }
        Window("Welcome to VoxClip", id: "welcome") {
            WelcomeView().environment(appModel)
        }
        .defaultSize(width: 560, height: 380)
        .defaultLaunchBehavior(.presented)
        Settings { SettingsView() }
    }
}

/// Native Welcome window routing; design §2.
@MainActor private struct WelcomeCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Welcome") { openWindow(id: "welcome") }
                .keyboardShortcut("0", modifiers: [.command, .shift])
        }
    }
}
