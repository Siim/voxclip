import SwiftUI
import VoxClipCore

@MainActor struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var connector = ""
    @State private var consent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Step \(step + 1) of 3").foregroundStyle(.secondary); Spacer(); Button("Skip") { finish() } }
            Text(["Cut video by its words.", "Find clips with AI (optional)", "Five keys to know"][step]).font(.title2).fontWeight(.semibold)
            if step == 0 {
                Text("How should VoxClip transcribe?")
                Form {
                    EnginePicker(app: app)
                    LanguagePicker(app: app)
                    if app.string("transcription.engineMode", fallback: "local") == "elevenlabs" { ProviderKeyRow(provider: "elevenlabs", label: "ElevenLabs Scribe", app: app) }
                }.formStyle(.grouped).scrollContentBackground(.hidden)
                Text("On this Mac: private and free. Downloads a model once. You can download it later, when you import.").font(.callout).foregroundStyle(.secondary)
                Button("Choose or download a local model…") { openVoxClipSettings() }
            } else if step == 1 {
                Picker("Connect using", selection: $connector) {
                    Text("Not now").tag("")
                    ForEach(app.providers, id: \.id) { Text($0.label).tag($0.id) }
                }
                if let choice = app.providers.first(where: { $0.id == connector }) {
                    if choice.group == "apiKey" { ProviderKeyRow(provider: choice.id, label: choice.label, app: app) }
                    if let copy = choice.cliConsentCopy { Text(copy); Toggle("I understand and want to use this connector", isOn: $consent) }
                    Button("Configure and test this connector…") { openVoxClipSettings() }
                }
                Text("Sends transcript text only. No audio or video.").foregroundStyle(.secondary)
                Text("You can always make clips yourself: select words, press ⌘K.")
                Spacer()
            } else {
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 14) {
                    GridRow { Text("Space"); Text("Play / pause") }
                    GridRow { Text("⌫"); Text("Cut selected words") }
                    GridRow { Text("⌘Z"); Text("Undo") }
                    GridRow { Text("J K L"); Text("Shuttle") }
                    GridRow { Text("⌘E"); Text("Export") }
                }.font(.title3)
                Spacer()
                Text("Local-first. No account required. No telemetry.").foregroundStyle(.secondary)
            }
            HStack {
                HStack(spacing: 6) { ForEach(0..<3) { position in Circle().fill(position == step ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 6, height: 6) } }.accessibilityLabel("Step \(step + 1) of 3")
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step == 1 {
                    Button("Not now") { step = 2 }.keyboardShortcut(.defaultAction)
                    Button("Continue") {
                        if app.selectOnboardingConnector(connector, consent: consent) { step = 2 }
                    }.disabled(connector.isEmpty || (app.providers.first { $0.id == connector }?.cliConsentCopy != nil && !consent))
                } else if step == 2 {
                    Button("Open a video…") { finish(); chooseFile(app: app) }
                    Button("Done") { finish() }.keyboardShortcut(.defaultAction)
                }
                else { Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction) }
            }
        }.padding(28).frame(width: 560, height: 480).background(DesignValues.color("bg.window"))
        .onChange(of: connector) { _, _ in consent = false }
    }
    private func finish() { app.set("onboarding.completed", .bool(true)); dismiss() }
}
