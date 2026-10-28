#if DEBUG
import SwiftUI
import VoxClipCore

actor RegressionLogger: Logger {
    private(set) var entries: [LogEntry] = []
    func write(_ entry: LogEntry) { entries.append(entry) }
}

@MainActor enum DebugPersistence {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        var input = fixture
        input.savedBy = ProjectWriter(version: "0.0.0", platform: .windows)
        input.edits.cutWordIds.append("missing-word")
        let document = try VoxClipDocument(data: ProjectJSON.encode(input))
        let logger = RegressionLogger()
        await document.reportWarnings(to: logger)
        let warnings = await logger.entries
        check("document decoding cleans references and reports warnings", !document.project.edits.cutWordIds.contains("missing-word") && !warnings.isEmpty)
        let model = EditorModel(document: document, app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.mediaResolved = true; model.refresh()
        let range = ClipRange(id: "persistence-range", startWordId: model.words[0].id, endWordId: model.words[3].id, title: "Persistence fixture")
        model.apply(.addClip(range), name: "Add fixture clip")
        let ids = Array(model.words.suffix(4).map(\.id).reversed())
        model.apply(.cutSelection(ids: ids), name: "Cut fixture words")
        document.updateLocation(directory.appendingPathComponent("roundtrip.voxclip"))
        let snapshot = try document.snapshot(contentType: .voxclipProject)
        let reopened = try VoxClipDocument(data: JSONProjectStore.encode(snapshot)).project
        let cutIDs = Set(model.project.edits.cutWordIds)
        check("document round-trip orders cut ids by transcript", reopened.edits.cutWordIds == model.words.map(\.id).filter(cutIDs.contains))
        check("document save updates savedBy and modifiedAt", reopened.savedBy == ProjectWriter(version: AppModel.version) && reopened.modifiedAt > fixture.modifiedAt)
        check("document save uses Core relative paths", reopened.media.source.relativePath == JSONProjectStore.relativePath(source: model.sourceURL, projectURL: document.fileURL!))
        if let existing = model.project.edits.clips.first {
            let duplicate = ClipRange(id: "duplicate-range", startWordId: existing.startWordId, endWordId: existing.endWordId, title: "Duplicate")
            let aiClip = ProjectAIClip(title: "Duplicate", reason: "Fixture", score: 8, startWordId: existing.startWordId, endWordId: existing.endWordId)
            var next = model.project
            next.ai.results.append(ProjectAIResult(id: "duplicate-run", createdAt: Date(), provider: "openai", model: "fixture", preset: .best, inputSha256: String(repeating: "0", count: 64), clips: [aiClip]))
            let count = next.edits.clips.count
            model.apply(.addAIClips(resultId: "duplicate-run", clips: [duplicate]), name: "Find clips", base: next)
            check("duplicate AI runs persist with feedback", model.project.ai.results.last?.id == "duplicate-run" && model.project.edits.clips.count == count && model.clipError == "These clips are already in the list.")
            let before = model.project
            model.apply(.addAIClips(resultId: "missing-run", clips: [duplicate]), name: "Invalid AI reference")
            check("AI commands validate result references", model.project == before)
        } else { check("duplicate AI runs persist with feedback", false) }
        check("clip titles respect Unicode scalar limits", EditingAlgorithms.clipTitle([String(repeating: "👩🏽‍💻", count: 120)])?.unicodeScalars.count == EditingLimits.maxClipTitleScalars)
        var invalid = model.project
        invalid.edits.clips.append(ClipRange(id: "reversed", startWordId: model.words.last!.id, endWordId: model.words.first!.id, title: "Invalid range"))
        document.replaceProject(invalid); model.refresh()
        check("share captions tolerate reversed clip bounds", model.shareCaption("reversed") == "Invalid range")
        // Left edited at a file that was never written, the document would fail AppKit's
        // autosave later, and that app-modal alert would block later checks' menu actions.
        document.updateChangeCount(.changeCleared)
        document.close()
        return results
    }
}
#endif
