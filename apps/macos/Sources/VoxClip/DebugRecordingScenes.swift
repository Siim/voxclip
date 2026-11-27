#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

@MainActor enum DebugRecordingScenes {
    static func capture(app: AppModel, root: URL, directory: URL) async throws -> [DebugUISuite.Result] {
        let fixture = root.appendingPathComponent("fixtures/recordings/reference-recordings.voxclip")
        var project = try JSONProjectStore.decode(Data(contentsOf: fixture))
        let parts: [ClipPart] = [
            .init(id: "opening", startWordId: "r2.w1", endWordId: "r2.w11"),
            .init(id: "setup", startWordId: "w1", endWordId: "w7"),
            .init(id: "notes", startWordId: "w8", endWordId: "w13"),
            .init(id: "reporting", startWordId: "r2.w18", endWordId: "r2.w21"),
            .init(id: "closing", startWordId: "w18", endWordId: "w27")
        ]
        let clip = ClipRange(id: "recording-story", startWordId: "w1", endWordId: "r2.w21", parts: parts)
        project.edits.clips = [clip]
        project.edits.activeClipId = clip.id
        project.media.spokenSources?[0].gainDb = -1.8
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .clip(clip.id))
        guard let editor = shell.editor, let other = editor.recordingRegions.last else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        shell.setExplorerExpanded(.outline, true)
        shell.layout.timelineVisible = true
        shell.layout.rememberExplorerWidth(300)
        var results: [DebugUISuite.Result] = []

        func snapshot<Content: View>(_ frame: String, _ content: Content, size: NSSize) async throws {
            let name = "recordings-frame-\(frame)"
            try await DebugUISuite.snapshot(content.environment(app), name: name, size: size,
                appearance: .darkAqua, directory: directory, active: true, checkRightColumn: false)
            results.append(.init(name: name, passed: true))
        }
        let workspace = NSSize(width: 1440, height: 900)
        editor.showsCuts = false
        try await snapshot("2", WorkspaceView(shell: shell), size: workspace)
        try await snapshot("5", TimelineCanvas(model: editor, shell: shell), size: NSSize(width: 1170, height: 465))
        editor.showsCuts = true
        try await snapshot("5-source", TimelineCanvas(model: editor, shell: shell), size: NSSize(width: 1170, height: 465))
        editor.showsCuts = false
        try await snapshot("7", WorkspaceView(shell: shell), size: workspace)

        editor.selectedStoryPartID = parts[1].id
        editor.pickPart(from: other)
        editor.selectedWordIDs = ["r2.w12", "r2.w13", "r2.w14", "r2.w15", "r2.w16", "r2.w17"]
        try await snapshot("A", TranscriptColumn(model: editor, shell: shell), size: NSSize(width: 780, height: 590))
        editor.partPickKey = nil
        editor.selectedWordIDs = []
        editor.chooseRecordingTranscript(.all, announceChange: false)
        try await snapshot("B", TranscriptColumn(model: editor, shell: shell), size: NSSize(width: 960, height: 590))

        guard !editor.recordingVersions(of: parts[1]).isEmpty else { throw CocoaError(.coderInvalidValue) }
        try await snapshot("D", RecordingPartVersions(editor: editor, part: parts[1], expanded: true).padding(12),
            size: NSSize(width: 460, height: 330))
        return results
    }
}
#endif
