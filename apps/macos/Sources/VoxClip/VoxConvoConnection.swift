import SwiftUI
import VoxClipCore

@MainActor @Observable final class VoxConvoConnection {
    static var available: Bool { !SecretStore.keychainDisabled && (Bundle.main.object(forInfoDictionaryKey: "VoxConvoDevicePublishingEnabled") as? Bool == true) }
    static let unavailableReason = "Direct posting isn't available in this build. You can still export your video."
    private let secrets: SecretStore
    let api = VoxConvoPublishing()
    private(set) var handle: String?
    private(set) var waiting: VoxConvoDeviceCode?
    private(set) var busy = false
    private(set) var hasSession = false
    private(set) var message: String?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(secrets: SecretStore) { self.secrets = secrets }

    func refresh() async {
        guard Self.available, !busy, !loaded else { return }
        busy = true
        defer { busy = false }
        do {
            let key = VoxConvoPublishing.accountKey
            guard await secrets.hasKey(for: key), let token = try await secrets.key(for: key) else { loaded = true; return }
            hasSession = true
            try await readAccount(token)
            loaded = true
        } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch {
            await show(error)
        }
    }

    func connect() {
        guard Self.available, !busy, !hasSession else { return }
        message = nil; busy = true
        task = Task { [self] in
            defer { waiting = nil; busy = false; task = nil }
            do {
                let code = try await api.beginConnection()
                try Task.checkCancellation()
                waiting = code
                NSWorkspace.shared.open(code.verificationURL)
                let token = try await api.waitForApproval(code)
                try await readAccount(token)
                try await secrets.save(token, for: VoxConvoPublishing.accountKey)
                hasSession = true; loaded = true
            } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch {
                if !hasSession { handle = nil }
                await show(error)
            }
        }
    }

    func cancel() { task?.cancel() }

    func checkAgain() {
        loaded = false
        Task { await refresh() }
    }

    func disconnect() {
        guard !busy else { return }
        busy = true
        task = Task { [self] in
            defer { busy = false; task = nil }
            do {
                if let token = try await session() { try await api.disconnect(session: token) }
                try await clearSession()
                message = nil
            } catch { await show(error) }
        }
    }

    func session() async throws -> String? {
        guard Self.available else { return nil }
        return try await secrets.key(for: VoxConvoPublishing.accountKey)
    }

    func show(_ error: any Error) async {
        if error as? VoxConvoPublishError == .unauthorized {
            do { try await clearSession() }
            catch { message = "The connection expired, but VoxClip couldn't remove it from Keychain."; return }
        }
        message = Self.message(error)
    }

    static func message(_ error: any Error) -> String {
        (error as? VoxConvoPublishError)?.errorDescription ?? "VoxClip couldn't reach VoxConvo or access its connection. Try again."
    }

    private func clearSession() async throws {
        handle = nil; hasSession = false
        try await secrets.save("", for: VoxConvoPublishing.accountKey)
    }

    private func readAccount(_ token: String) async throws {
        handle = try await api.account(session: token)?.handle
        message = handle == nil ? "Finish sign-up on voxconvo.com." : nil
    }
}

@MainActor struct VoxConvoAccountsSettings: View {
    let connection: VoxConvoConnection

    var body: some View {
        Form {
            Section("VoxConvo") {
                if let code = connection.waiting {
                    LabeledContent("Confirm this code on voxconvo.com") { Text(code.displayCode).font(DesignValues.mono()).textSelection(.enabled) }
                    Link("Open VoxConvo", destination: code.verificationURL)
                    Button("Cancel") { connection.cancel() }
                } else if connection.hasSession {
                    if let handle = connection.handle { Text("Connected as @\(handle)") }
                    else {
                        Link("Open voxconvo.com", destination: URL(string: "https://voxconvo.com")!)
                        Button("Check connection") { connection.checkAgain() }.disabled(connection.busy)
                    }
                    Button("Disconnect") { connection.disconnect() }.disabled(connection.busy)
                } else {
                    Button("Connect") { connection.connect() }.disabled(connection.busy || !VoxConvoConnection.available)
                    Text(VoxConvoConnection.available ? "Approve on voxconvo.com to let VoxClip post videos you choose." : VoxConvoConnection.unavailableReason)
                        .foregroundStyle(.secondary)
                }
                if connection.busy, connection.waiting == nil { ProgressView("Checking VoxConvo…") }
                if let message = connection.message { InlineNotice(text: message) }
            }
        }.formStyle(.grouped).task { await connection.refresh() }
    }
}
