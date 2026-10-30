#if DEBUG
import Foundation
import VoxClipCore

private actor TranscriptionConsentSettings: SettingsStore {
    private var document = SettingsDocument()
    func load() -> SettingsDocument { document }
    func save(_ settings: SettingsDocument) { document = settings }
    func flush() {}
}

@MainActor enum DebugTranscriptionConsent {
    static func run(fixture: Project) async throws -> [DebugUISuite.Result] {
        guard let transcript = fixture.transcript else { throw CocoaError(.coderInvalidValue) }
        let store = TranscriptionConsentSettings()
        let app = AppModel(settingsStore: store)
        await app.start()
        var input = fixture
        input.transcript = nil
        let editor = EditorModel(document: VoxClipDocument(project: input, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let gate = TranscriptionConsentGate()
        var uploads = 0
        var grantedAtUpload = false
        func upload() {
            uploads += 1
            grantedAtUpload = app.bool("transcription.cloudConsent.elevenlabs")
            editor.replaceTranscript(transcript)
        }
        var results: [DebugUISuite.Result] = []
        gate.request(engine: "elevenlabs", app: app, operation: upload)
        results.append(.init(name: "ElevenLabs first use waits for consent before any upload or project change", passed:
            gate.pending && uploads == 0 && editor.project == input && !app.bool("transcription.cloudConsent.elevenlabs")))
        gate.cancel()
        gate.approve(app: app)
        results.append(.init(name: "cancelling ElevenLabs consent leaves the project untranscribed and stores no grant", passed:
            !gate.pending && uploads == 0 && editor.project == input && editor.project.transcript == nil && !app.bool("transcription.cloudConsent.elevenlabs")))
        gate.request(engine: "elevenlabs", app: app, operation: upload)
        gate.approve(app: app)
        gate.approve(app: app)
        results.append(.init(name: "Continue stores ElevenLabs consent before exactly one upload", passed:
            !gate.pending && uploads == 1 && grantedAtUpload && editor.project.transcript == transcript))
        await app.flushSettings()
        let reopened = AppModel(settingsStore: store)
        await reopened.start()
        let repeated = TranscriptionConsentGate()
        var repeatedUploads = 0
        repeated.request(engine: "elevenlabs", app: reopened) { repeatedUploads += 1 }
        results.append(.init(name: "persisted ElevenLabs consent permits the next request without another prompt", passed:
            reopened.bool("transcription.cloudConsent.elevenlabs") && repeatedUploads == 1 && !repeated.pending))
        for engine in ["local", "apple"] {
            let localApp = AppModel(settingsStore: TranscriptionConsentSettings())
            await localApp.start()
            let localGate = TranscriptionConsentGate()
            var starts = 0
            localGate.request(engine: engine, app: localApp) { starts += 1 }
            results.append(.init(name: "\(engine) transcription starts without granting cloud consent", passed:
                starts == 1 && !localGate.pending && !localApp.bool("transcription.cloudConsent.elevenlabs")))
        }
        return results
    }
}
#endif
