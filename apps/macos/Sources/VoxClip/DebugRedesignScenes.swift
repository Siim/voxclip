#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import VoxClipMedia

@MainActor enum DebugRedesignScenes {
    static let names = ["live-home", "live-home-empty", "live-dragover", "live-editor-full", "live-editor-clip",
                        "live-editor-1280-blue", "live-compact", "live-selection-bar", "live-suggested", "live-finding",
                        "live-export-clip", "live-rewrite"]
    static func checks(app: AppModel) throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let project = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let expected: Set<String> = ["live-home", "live-home-empty", "live-dragover", "live-editor-full", "live-editor-clip", "live-editor-1280-blue", "live-compact", "live-selection-bar", "live-suggested", "live-finding", "live-export-clip", "live-rewrite"]
        return [
            .init(name: "step 18 scene set contains every required name once", passed: Set(names) == expected && names.count == expected.count),
            .init(name: "Five questions has four kept clips and one suggestion", passed: project.edits.clips.filter(\.selected).count == 4 && project.edits.clips.filter { !$0.selected && $0.origin == .ai }.count == 1),
            .init(name: "Five questions has eight cuts and four source fillers", passed: project.edits.cutWordIds.count == 8 && project.transcript?.words.filter { (try? isFillerText($0.text)) == true }.count == 4)
        ]
    }
    static func capture(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let url = root.appendingPathComponent("fixtures/projects/five-questions.voxclip")
        let project = try DemoEditing.loadFixture(url)
        let savedSettings = app.settings, savedRecent = app.recent, savedOverride = app.connectorOverride
        defer { app.settings = savedSettings; app.recent = savedRecent; app.connectorOverride = savedOverride }
        let fake = ConsentFixtureConnector(id: .ollama)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("ollama")); app.set("llm.model.ollama", .string("fixture-local"))
        app.set("voiceLab.enabled", .bool(true))
        app.recent = [url]; app.recentProjects.refresh([url])
        let shell = WorkspaceShell(app: app)
        var results: [DebugUISuite.Result] = []
        func scene(_ name: String, size: NSSize = NSSize(width: 1440, height: 900), appearance: NSAppearance.Name = .darkAqua,
                   prepare: (@MainActor (NSWindow) async throws -> NSWindow?)? = nil) async throws {
            guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
            try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: name, size: size,
                appearance: appearance, directory: directory, active: true, mainWindow: true, native: true, beforeCapture: prepare)
            results.append(.init(name: "native scene \(name)", passed: true))
        }
        try await scene("live-home")
        app.recent = []
        try await scene("live-home-empty", appearance: .aqua)
        app.recent = [url]; shell.dropTargeted = true
        try await scene("live-dragover")
        shell.dropTargeted = false
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true))
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 300_000))
        try await scene("live-editor-full")
        guard editor.keptClips.count == 4, let second = editor.keptClips.dropFirst().first else { throw CocoaError(.coderInvalidValue) }
        shell.selection = .clip(second.id); editor.setAspect(.portrait)
        try await scene("live-editor-clip", appearance: .aqua)
        shell.selection = .fullTake; editor.setAspect(.landscape)
        if Bundle.main.bundleURL.pathExtension == "app" && UserDefaults.standard.integer(forKey: "AppleAccentColor") == 4 {
            try await scene("live-editor-1280-blue", size: NSSize(width: 1280, height: 800), appearance: .aqua)
        } else {
            results.append(.init(name: "native scene live-editor-1280-blue", passed: false,
                skipped: "Owed: launch a bundled app with the blue system accent (-AppleAccentColor 4)."))
        }
        try await scene("live-compact", size: NSSize(width: 1024, height: 700))
        let selected = Array(editor.words[12...15])
        editor.selectedWordIDs = Set(selected.map(\.id))
        try await scene("live-selection-bar") { window in
            editor.window = window
            guard let text = transcript(in: window.contentView) else { throw CocoaError(.coderInvalidValue) }
            text.selectedRanges = selected.compactMap { word in text.map.span(id: word.id).map { NSValue(range: $0.range) } }
            text.showSelectionBar(focus: true)
            guard text.selectionBarVisible else { throw CocoaError(.coderInvalidValue) }
            return nil
        }
        editor.selectedWordIDs = []
        if let suggested = editor.suggestedClips.first { shell.selection = .clip(suggested.id) }
        try await scene("live-suggested")
        shell.selection = .fullTake; editor.finding = true
        try await scene("live-finding")
        editor.finding = false; shell.selection = .clip(second.id)
        try await scene("live-export-clip", appearance: .aqua) { window in
            editor.window = window
            guard !editor.mediaExportable else { throw CocoaError(.coderInvalidValue) }
            editor.exportClipIDs = [second.id]
            editor.showExport = true
            await DebugConnectorRequests.wait { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet else { throw VoxClipError.exportFailed("The staged export sheet did not appear.") }
            return sheet
        }
        editor.showExport = false
        shell.selection = .fullTake
        editor.selectedWordIDs = Set(editor.words[12...15].map(\.id))
        editor.beginRewrite()
        await DebugConnectorRequests.wait { editor.rewrite != nil }
        guard let session = editor.rewrite else { throw CocoaError(.coderInvalidValue) }
        session.setInstruction("Make this clearer")
        await session.detectConnector(); await session.prepare()
        if let quote = session.quote { session.markEstimateShown(quote.id) }
        try await scene("live-rewrite")
        editor.closeRewrite(returnFocus: false)
        try ProjectJSON.encoder().encode(results).write(to: directory.appendingPathComponent("redesign-scenes.json"), options: .atomic)
        return results
    }
    private static func transcript(in view: NSView?) -> TranscriptNSTextView? {
        guard let view else { return nil }
        if let text = view as? TranscriptNSTextView { return text }
        return view.subviews.lazy.compactMap { transcript(in: $0) }.first
    }
}
#endif
