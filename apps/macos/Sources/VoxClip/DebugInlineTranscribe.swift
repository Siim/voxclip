#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

@MainActor enum DebugInlineTranscribe {
    /// Approved f20b/f21/f25 scenes are available in -sceneAudit. No download or provider is invoked.
    static func captures(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        for name in ["f20b", "f21", "f25"] {
            var project = fixture
            project.media.source.durationSeconds = 326
            if name != "f25" { project.transcript = nil; project.edits = ProjectEdits() }
            let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
            let flow = editor.transcription
            flow.phase = .choosing; flow.language = name == "f20b" ? "et" : "en"
            flow.engine = name == "f21" ? "elevenlabs" : "local"
            flow.again = name == "f25"; flow.hasKey = true; flow.rate = 0.22; flow.keytermsSurcharge = 0.2
            flow.selectedModel = try await app.modelLibrary.localModel(language: flow.language)
            flow.readiness = name == "f20b" ? .needsModels(ids: [flow.selectedModel!.id], bytes: flow.selectedModel!.totalBytes) : .ready
            for width in [652, 440] {
                try await DebugUISuite.snapshot(InlineTranscriptionView(transcription: flow).environment(app),
                    name: "v2-inline-\(name)-\(width)", size: NSSize(width: width, height: 540), appearance: .darkAqua, directory: directory)
            }
            editor.close()
        }
        return [.init(name: "captured inline Transcribe f20b/f21/f25 scenes", passed: true)]
    }
}
#endif
