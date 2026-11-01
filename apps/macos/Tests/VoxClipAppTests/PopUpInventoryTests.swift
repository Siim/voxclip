import Foundation
import Testing

/// Inline actions, not pop-ups (impl-plan §13.1, the user's decision of 1 November 2026): no new `.sheet`, `.alert`,
/// `.confirmationDialog`, `NSAlert`, `beginSheetModal` or `runModal` for editor work. Each one left in the app's sources
/// is listed here with why it may stay (a system file picker, a Settings page) or the package that replaces it, so a
/// new one fails until someone decides where it belongs. A replaced one may simply go.
@Suite("Pop-up inventory")
struct PopUpInventoryTests {
    /// Pop-up calls per source file under Sources/VoxClip (each `NSAlert(`, `runModal(` and so on counts, even on one line),
    /// with the reason each may stay for now.
    static let allowed: [String: (count: Int, why: String)] = [
        "EditorModel.swift": (1, "Locate…'s NSOpenPanel: a system file picker"),
        "ExportJob.swift": (1, "the Export job's folder NSOpenPanel: a system file picker"),
        "SettingsView.swift": (4, "Settings pages: two NSOpenPanels, the licences and privacy text sheets"),
        "LocalModelsView.swift": (1, "Settings model download confirmation; editor downloads are inline"),
        "VoiceLabSettings.swift": (1, "Settings-only saved-voice deletion; enrollment is inline"),
        "EditorView.swift": (1, "the onboarding tour; editor jobs are inline"),
        "VoxClipApp.swift": (3, "Open's system picker and ownerless Help privacy alert"),
    ]
    static let patterns = [".sheet(", ".alert(", ".confirmationDialog(", "NSAlert(", "beginSheetModal", "runModal("]

    @Test func everyPopUpLeftIsListedWithItsReasonOrOwner() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoxClip")
        // Every folder under the sources (Services, Design), not just the top level.
        let walk = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let files = walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100 && files.contains { $0.deletingLastPathComponent().lastPathComponent == "Services" })
        for file in files where !file.lastPathComponent.hasPrefix("Debug") {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            let count = lines.reduce(0) { (total: Int, line: Substring) -> Int in
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { return total }
                let calls: Int = Self.patterns.reduce(0) { (sum: Int, pattern: String) -> Int in sum + code.components(separatedBy: pattern).count - 1 }
                return total + calls
            }
            let name = file.lastPathComponent
            #expect(count <= (Self.allowed[name]?.count ?? 0), "\(name) has \(count) pop-up call sites; allowed \(Self.allowed[name].map { "\($0.count): \($0.why)" } ?? "none") (impl-plan §13.1)")
        }
    }
}
