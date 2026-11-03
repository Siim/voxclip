#if DEBUG
import SwiftUI
import VoxClipCore
import VoxClipMedia

private struct RewriteGenerationFixtureKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { throw VoiceLabError.missingKey }
}

@MainActor enum DebugRewriteGeneration {
    static let states = ["no-voice", "ready", "generating", "provider-error", "none-passed", "length-changed", "cost-confirmation", "cancelled"]
    static var variants: [String] { states.map { "rewrite-takes-" + $0 } }
    static func show(_ state: String, app: AppModel) async throws {
        guard states.contains(state), let root = app.shared?.root else { throw VoiceLabError.invalidInput }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let project = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let document = VoxClipDocument(project: project, demo: true)
        guard await app.shell.replaceProject(with: document), let model = app.shell.editor else { return }
        model.mediaResolved = true
        let connector = RewriteConnector(connector: RewriteFixtureConnector(), model: "fixture-local", name: "Fixture", group: "local", plan: "")
        let session = RewriteSession(editor: model, scope: .selection(12...25),
            envelope: AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000)), connector: connector)
        model.rewrite = session
        try session.receivePassage("A clearer way to explain what happened in this passage."); session.finishRun(seconds: 1)
        try install(state, in: session)
    }
    static func install(_ state: String, in session: RewriteSession) throws {
        // Take-state fixtures show the take rows, not the pre-pay fit check: price a phrase that's too long for its
        // slot as if Price It Anyway was chosen (before generation is configured, as the user would), so the plan
        // keeps its phrase and the column stays on Voice.
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        let app = session.editor.app
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: app.shared!.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        session.configureGeneration(client: ElevenLabsVoiceLab(keys: RewriteGenerationFixtureKeys(), region: .default),
            store: VoiceConsentStore(locations: app.locations), speaker: .unavailable)
        session.generation?.showFixture(state, voice: record)
        if state != "no-voice", let envelope = session.envelope {
            let plan = try ClipTakePlan(project: session.project, scope: session.scope, envelope: envelope,
                hunks: session.changes.enumerated().filter { $0.element.hunk.kind != .voice || session.includedVoice.contains($0.offset + 1) }.map { $0.element.hunk },
                makeInput: { _ in throw VoiceLabError.invalidInput })
            plan.showFixture(state)
            session.takePlan = plan
        }
    }
    static func captures(app: AppModel, directory: URL) throws -> [String] {
        let previous = app.settings
        defer { app.settings = previous }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let project = try DemoEditing.loadFixture(app.shared!.root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        var files: [String] = []
        for state in states {
            let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
            defer { model.close() }
            model.mediaResolved = true
            let connector = RewriteConnector(connector: RewriteFixtureConnector(), model: "fixture-local", name: "Fixture", group: "local", plan: "")
            let session = RewriteSession(editor: model, scope: .selection(12...25),
                envelope: AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000)), connector: connector)
            model.rewrite = session
            try session.receivePassage("A clearer way to explain what happened in this passage."); session.finishRun(seconds: 1)
            try install(state, in: session)
            for width: CGFloat in [300, 360, 560] {
                for scheme: ColorScheme in [.light, .dark] {
                    guard let generation = session.generation else { throw CocoaError(.coderInvalidValue) }
                    let content = DirectorTakeRows(session: session, generation: generation).padding(16)
                        .frame(width: width).sceneAccent().environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    let name = "rewrite-\(state)-\(Int(width))-\(scheme == .light ? "light" : "dark").png"
                    try png.write(to: directory.appendingPathComponent(name)); files.append(name)
                }
            }
        }
        return files
    }
}
#endif
