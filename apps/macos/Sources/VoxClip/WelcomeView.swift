import SwiftUI
import VoxClipCore

/// Separate native Welcome scene; design §2. No accounts or providers are required.
@MainActor public struct WelcomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openDocument) private var openDocument
    public init() {}
    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.word.spacing").font(.system(size: 52)).accessibilityHidden(true)
            Text("VoxClip").font(.largeTitle.bold())
            Text("Edit video by words.").foregroundStyle(.secondary)
            Button("Open project…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.voxclipProject]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { Task { try? await openDocument(at: url) } }
            }.buttonStyle(.borderedProminent)
            if let error = appModel.startupError {
                Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Native Settings scene with a safe unavailable state; design §10 and architecture §2.5.
@MainActor public struct SettingsView: View {
    @State private var showLicences = false
    public init() {}
    public var body: some View {
        TabView {
            Tab("General", systemImage: "gear") { Text("General settings will be available here.").padding(32) }
            Tab("Transcription", systemImage: "waveform") { Text("Transcription models will be available here.").padding(32) }
            Tab("AI", systemImage: "sparkles") { Text("Bring your own API key, local model or installed CLI.").padding(32) }
            Tab("About", systemImage: "info.circle") {
                VStack(spacing: 12) {
                    Text("VoxClip 0.1.0 (1)")
                    Text("MIT License")
                    Text("swift-argument-parser 1.8.2 · Apache-2.0")
                    Text("whisper.cpp b5454 (1.9.5) · MIT")
                    Button("Licences…") { showLicences = true }
                }.padding(32)
            }
        }
        .frame(width: 580, height: 320)
        .sheet(isPresented: $showLicences) { LicencesView() }
    }
}

/// Legal notices loaded as plain text; AGENTS.md rule 4 and architecture §2.4.
@MainActor private struct LicencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notices = "swift-argument-parser: Apache-2.0. whisper.cpp and ggml: MIT. Full texts are in apps/macos/THIRD_PARTY_NOTICES.md."
    var body: some View {
        VStack(alignment: .trailing) {
            ScrollView { Text(notices).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).padding()
        }
        .frame(width: 640, height: 480)
        .task {
            var candidates = [Bundle.main.resourceURL?.appendingPathComponent("THIRD_PARTY_NOTICES.md")]
            if let shared = try? SharedResources.locate() {
                candidates.append(shared.root.deletingLastPathComponent().appendingPathComponent("apps/macos/THIRD_PARTY_NOTICES.md"))
            }
            for case let url? in candidates {
                if let text = try? String(contentsOf: url, encoding: .utf8) { notices = text; break }
            }
        }
    }
}
