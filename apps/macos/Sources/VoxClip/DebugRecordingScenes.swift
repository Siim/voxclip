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
        project.edits.clips = []
        project.edits.activeClipId = nil
        project.media.spokenSources?[0].gainDb = -1.8
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        guard let editor = shell.editor, let primary = editor.recordingRegions.first,
              let other = editor.recordingRegions.last else { throw CocoaError(.coderInvalidValue) }
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
        editor.otherRecordingLinesExpanded = false
        guard editor.activeClip == nil, editor.canStartFromRecording(primary) else { throw CocoaError(.coderInvalidValue) }
        try await snapshot("1", WorkspaceView(shell: shell), size: workspace)

        editor.startFromRecording(primary)
        guard let started = editor.activeClip, !editor.recordingOmittedLines.isEmpty,
              let line = editor.recordingLineWithVersions(at: "w1") else { throw CocoaError(.coderInvalidValue) }
        shell.choose(.clip(started.id))
        try await snapshot("2", WorkspaceView(shell: shell), size: workspace)

        editor.showRecordingLineVersions(line)
        try await snapshot("3", WorkspaceView(shell: shell), size: workspace)
        let compact = NSSize(width: 1280, height: 900)
        shell.layout.windowWidth = Double(compact.width)
        shell.layout.rememberRightWidth(360)
        guard shell.layout.rightVisible, shell.layout.rightWidth == 360 else { throw CocoaError(.coderInvalidValue) }
        try await snapshot("3-1280-right-360", WorkspaceView(shell: shell), size: compact)
        shell.layout.windowWidth = Double(workspace.width)
        shell.layout.rememberRightWidth(WorkspaceLayout.rightColumnWidth(windowWidth: Double(workspace.width)))

        editor.useRecordingLineVersion(line, key: other.key)
        editor.otherRecordingLinesExpanded = true
        editor.chooseRecordingTranscript(.recording(other.key), announceChange: false)
        guard let punchline = editor.otherRecordingLines.first(where: { $0.startWordId == "r2.w18" }),
              editor.recordingPlacement(punchline) == "w23" else { throw CocoaError(.coderInvalidValue) }
        try await snapshot("4", WorkspaceView(shell: shell), size: workspace)

        var disabled = editor.project
        let openingOnly = ClipRange(id: "recording-opening", startWordId: "w1", endWordId: "w13")
        disabled.edits.clips = [openingOnly]
        disabled.edits.activeClipId = openingOnly.id
        editor.replace(disabled, name: "Set up disabled recording actions", restoresRecordingScope: true)
        shell.choose(.clip(openingOnly.id))
        guard editor.otherRecordingLines.contains(punchline), editor.recordingPlacement(punchline) == nil else {
            throw CocoaError(.coderInvalidValue)
        }
        try await snapshot("7", WorkspaceView(shell: shell), size: workspace)

        project.edits.clips = [clip]
        project.edits.activeClipId = clip.id
        editor.replace(project, name: "Set up recording timeline", restoresRecordingScope: true)
        shell.choose(.clip(clip.id))
        editor.otherRecordingLinesExpanded = false
        try await snapshot("5", TimelineCanvas(model: editor, shell: shell), size: NSSize(width: 1170, height: 465))
        editor.showsCuts = true
        try await snapshot("5-source", TimelineCanvas(model: editor, shell: shell), size: NSSize(width: 1170, height: 465))
        editor.showsCuts = false

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
