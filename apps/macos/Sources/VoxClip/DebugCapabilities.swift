#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

@MainActor enum DebugCapabilities {
    static func run(app: AppModel, fixture: Project) -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let document = VoxClipDocument(project: fixture)
        let editor = EditorModel(document: document, app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        editor.refresh()
        guard let word = editor.words.first else { return results }
        editor.selectedWordIDs = [word.id]
        let original = editor.project
        check("missing media allows document Rename and caption position only", editor.capabilities.rename && editor.capabilities.captionPosition && !editor.capabilities.edit && !editor.capabilities.ai && !editor.canExport)
        let commands: [Int] = [1, 2, 3, 7, 8, 9, 29, 30, 31, 34, 37, 38, 40, 41, 42, 43, 44, 45]
        for command in commands { check("missing-media menu command \(command) disabled", editor.mutationEnabled(command) == false) }
        editor.cutSelection(); editor.beginCorrection(); editor.beginRewrite(); editor.requestFindClips(from: .toolbar)
        check("missing-media action entries refuse editing and AI UI", editor.project == original && editor.correctionID == nil && editor.rewrite == nil && !editor.showFindClips && !editor.showVoiceLabOptIn)
        editor.mediaResolved = true
        check("resolved transcript enables edits and AI", editor.capabilities.edit && editor.capabilities.ai)
        editor.exporting = true
        check("export snapshot leaves edits enabled but blocks duplicate export", editor.capabilities.edit && !editor.canExport)
        check("export menu keeps edits enabled and blocks duplicate target", editor.mutationEnabled(1) == true && editor.mutationEnabled(45) == false)
        editor.exporting = false
        document.versionForTesting = true
        check("read-only disables every mutation", !editor.capabilities.edit && !editor.capabilities.rename && !editor.canMoveCaptions && !editor.capabilities.ai && !editor.canExport)
        for command in commands { check("read-only menu command \(command) disabled", editor.mutationEnabled(command) == false) }
        editor.cutSelection(); editor.beginCorrection()
        check("read-only action entries preserve document", editor.project == original && editor.correctionID == nil)
        document.versionForTesting = false
        editor.isLeaving = true
        check("leaving disables every mutation", !editor.capabilities.edit && !editor.capabilities.rename && !editor.capabilities.captionPosition && !editor.capabilities.ai && !editor.canExport)
        editor.isLeaving = false
        if let lease = editor.llmRuns.acquire() {
            check("project lease atomically excludes a second AI run", editor.llmRuns.acquire() == nil && !editor.capabilities.ai && editor.capabilities.edit)
            check("AI-busy menu refuses Find Clips and Rewrite but allows edits", editor.mutationEnabled(34) == false && editor.mutationEnabled(38) == false && editor.mutationEnabled(1) == true)
            editor.llmRuns.release(UUID())
            check("stale lease release cannot free a newer owner", editor.llmRuns.isBusy)
            editor.llmRuns.release(lease)
            check("owner releases shared AI lease", editor.capabilities.ai)
        }
        return results
    }
}
#endif
