import Foundation
import Testing

/// The AI settings page no longer shows "Snap clip edges to sentence boundaries", and Find Clips no longer reads the
/// setting: its replies are whole lines, so the toggle changed nothing (`SnapToLinesSettingTests` keeps old files
/// loading). The settings window opens a real window, so the page is checked in its source.
@Suite struct SettingsSnapToggleTests {
    private func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoxClip", isDirectory: true)
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func theToggleIsGoneAndFindClipsDoesNotReadIt() throws {
        let settings = try source("SettingsView.swift")
        #expect(!settings.contains("Snap clip edges") && !settings.contains("llm.clips.snapToLines"))
        #expect(!(try source("EditorModel.swift")).contains("llm.clips.snapToLines"))
    }
}
