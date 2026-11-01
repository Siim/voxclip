import Foundation
import Testing

/// Inline actions, not pop-ups (impl-plan §13.1, the user's decision of 1 November 2026): no new `.sheet`, `.alert`,
/// `.confirmationDialog`, `NSAlert`, `beginSheetModal` or `runModal` for editor work. Each one left in the app's sources
/// is listed here with why it may stay (a system file picker, a Settings page) or the package that replaces it, so a
/// new one fails until someone decides where it belongs. A replaced one may simply go.
@Suite("Pop-up inventory")
struct PopUpInventoryTests {
    /// Call sites per source file, with the reason each may stay for now.
    static let allowed: [String: (count: Int, why: String)] = [
        "EditorModel.swift": (1, "Locate…'s NSOpenPanel: a system file picker"),
        "ExportJob.swift": (1, "the Export job's folder NSOpenPanel: a system file picker"),
        "SettingsView.swift": (4, "Settings pages: two NSOpenPanels, the licences and privacy text sheets"),
        "LocalModelsView.swift": (1, "the model download confirmation; Settings › Models (origin .settings) and VT's transcription sheet"),
        "SpeakerModelLibrary.swift": (1, "the own-voice check download confirmation in Settings; V16 makes it an inline row in the Voice job"),
        "VoiceLabSettings.swift": (4, "Settings › Voice Lab's Turn on Voice Lab? alert (V16, low priority); CreateVoiceSheet and VoiceLabRequestSheet (V16, V17)"),
        "EditorView.swift": (4, "TranscriptionSheet (VT), the Voice Lab opt-in sheet (V16), the shortcuts sheet (V11b's ⌘K) and the tour (Home frame 7)"),
        "TranscriptionSheet.swift": (1, "the transcription consent sheet (VT)"),
        "HomeView.swift": (2, "the Sign in to {provider} NSAlert (V11b: an inline row in the harness picker)"),
        "VoxClipApp.swift": (5, "Open's NSOpenPanel; Help › What Leaves This Mac (no owner yet); Transcribe again? (VT, v5 f25)"),
        "RewriteSession.swift": (2, "RewriteApprovalSheet: API-key sends and the privacy consent (V12), takes and ElevenLabs (V18)"),
    ]
    static let patterns = [".sheet(", ".alert(", ".confirmationDialog(", "NSAlert(", "beginSheetModal", "runModal("]

    @Test func everyPopUpLeftIsListedWithItsReasonOrOwner() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoxClip")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 100)
        for file in files where !file.lastPathComponent.hasPrefix("Debug") {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            let count = lines.filter { line in
                let code = line.trimmingCharacters(in: .whitespaces)
                return !code.hasPrefix("//") && Self.patterns.contains { code.contains($0) }
            }.count
            let name = file.lastPathComponent
            #expect(count <= (Self.allowed[name]?.count ?? 0), "\(name) has \(count) pop-up call sites; allowed \(Self.allowed[name].map { "\($0.count): \($0.why)" } ?? "none") (impl-plan §13.1)")
        }
    }
}
