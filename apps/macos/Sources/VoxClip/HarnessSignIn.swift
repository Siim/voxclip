import AppKit
import Observation
import SwiftUI
import VoxClipCore

/// Sign-in stays with the selected harness. No credentials or provider output are collected here.
@MainActor @Observable final class HarnessSignIn {
    private unowned let app: AppModel
    private(set) var providerID: String?
    private(set) var result: String?
    private(set) var checking = false
    @ObservationIgnored private var script: URL?
    init(app: AppModel) { self.app = app }

    static func command(provider: ProviderChoice, path: String) -> String? {
        guard provider.id == "claude-code" || provider.id == "codex", let cli = provider.cli else { return nil }
        let executable = path.isEmpty ? cli.executable : path
        // Terminal receives a quoted executable, never arbitrary shell text from the catalogue or settings.
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return quoted + (provider.id == "codex" ? " login" : "")
    }
    /// Matches today's catalogue instructions: run Claude Code, or `codex login`, in Terminal.
    /// Tests inject the opener and detection so they launch no CLI or browser.
    func signIn(_ provider: ProviderChoice, open: ((URL) async throws -> Void)? = nil) async {
        guard !checking, let command = Self.command(provider: provider, path: app.string("llm.cliPath.\(provider.id)")) else { return }
        providerID = provider.id
        do {
            let folder = app.locations.cache.appendingPathComponent("SignIn", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(UUID().uuidString + ".command")
            // A fresh empty working directory also keeps a CLI's project discovery away from the user's project.
            let cd = "'" + folder.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let text = "#!/bin/zsh -l\ntrap 'rm -- \"$0\"' EXIT\ncd -- \(cd) || exit 1\n\(command)\n"
            try Data(text.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            script = file
            if let open { try await open(file) }
            else {
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw CocoaError(.fileNoSuchFile) }
                _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            }
            result = "Finish signing in in Terminal, then return here."
        } catch {
            if let script { try? FileManager.default.removeItem(at: script) }; script = nil
            result = "Couldn't open Terminal. \(provider.cli?.signInHint ?? "Sign in through the installed app, then check again.")"
        }
    }
    func check(_ provider: ProviderChoice, using connector: (any LLMConnector)? = nil) async {
        guard !checking else { return }
        checking = true; providerID = provider.id
        let status = await app.connectorStatus(provider, using: connector)
        checking = false
        switch status {
        case .ready: result = "\(provider.shortName) is signed in."
        case .cliSignedOut: result = "Still not signed in. \(provider.cli?.signInHint ?? "Finish signing in in Terminal, then check again.")"
        default: result = "Couldn't check sign-in. \(provider.cli?.signInHint ?? "Try again.")"
        }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: result ?? "", .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }
    func checkPending() async {
        guard let providerID, let provider = app.providers.first(where: { $0.id == providerID }) else { return }
        await check(provider)
    }
    func message(for provider: ProviderChoice) -> String? { providerID == provider.id ? result : nil }
}

/// Home reaches the same harness menu even before a project is open.
@MainActor struct HomeHarnessPicker: NSViewRepresentable {
    let app: AppModel
    func makeNSView(context: Context) -> HarnessPicker { HarnessPicker(app: app) }
    func updateNSView(_ view: HarnessPicker, context: Context) { view.render() }
}
