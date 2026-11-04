import Foundation
import Testing

/// Inline actions, not pop-ups (impl-plan §13.1, the user's decision of 1 November 2026): no new `.sheet`, `.alert`,
/// `.confirmationDialog`, `NSAlert`, `beginSheetModal`, `runModal` or popover for editor work. Windows and system file
/// importers are counted too. Each one left in the app's sources
/// is listed here with why it may stay (a system file picker, a Settings page) or the package that replaces it, so a
/// new one fails until someone decides where it belongs. A replaced one may simply go.
@Suite("Pop-up inventory", .offlineFixtures)
struct PopUpInventoryTests {
    /// Pop-up calls per source file under Sources/VoxClip (each `NSAlert(`, `runModal(` and so on counts, even on one line),
    /// with the reason each may stay for now.
    static let allowed: [String: (count: Int, why: String)] = [
        "EditorModel.swift": (1, "Locate…'s NSOpenPanel: a system file picker"),
        "ExportJob.swift": (1, "the Export job's folder NSOpenPanel: a system file picker"),
        "MusicSection.swift": (1, "the Music section's Add a file… NSOpenPanel: a system file picker"),
        "SettingsView.swift": (4, "Settings pages: two NSOpenPanels, the licences and privacy text sheets"),
        "LocalModelsView.swift": (1, "Settings model download confirmation; editor downloads are inline"),
        "VoiceLabSettings.swift": (1, "Settings-only saved-voice deletion; enrollment is inline"),
        "EditorView.swift": (1, "the onboarding tour; editor jobs are inline"),
        "VoxClipApp.swift": (4, "Open's system picker, ownerless Help privacy alert and the Settings window"),
        "ContextDemoPanel.swift": (1, "Code-project folder selection uses the system folder picker; setup and editing stay inline"),
        "ContextDemoBrowserSession.swift": (1, "The explicitly approved webpage capture needs its own exact window/process target; review and editing stay in the Context demo job"),
        "EditorShell.swift": (1, "Pre-existing Find Clips chooser at the clip bar; impl-plan item 17, outside this motion-editor replacement"),
        "ExplorerView.swift": (1, "Pre-existing Find Clips chooser at Suggested; same chooser as the clip-bar entry, impl-plan item 17"),
        "ClipBar.swift": (1, "Pre-existing compact Ask field below 440 pt; impl-plan section 3.5, outside this motion-editor replacement"),
    ]
    static let patterns = [".sheet(", ".alert(", ".confirmationDialog(", "NSAlert(", "beginSheetModal", "runModal(",
                           "NSPopover(", ".popover(", "NSWindow(", ".fileImporter("]

    static func popUpCount(in source: String) -> Int {
        source.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { return total }
            return total + patterns.reduce(0) { $0 + code.components(separatedBy: $1).count - 1 }
        }
    }

    @Test func motionHasNoPopupAllowanceAndNewPresentationFamiliesAreCounted() {
        #expect(Self.allowed["MotionCuePanel.swift"] == nil)
        #expect(Self.popUpCount(in: "let editor = NSPopover()") == 1)
        #expect(Self.popUpCount(in: ".popover(isPresented: $open) {}") == 1)
        #expect(Self.popUpCount(in: "let capture = NSWindow(contentRect: bounds)") == 1)
        #expect(Self.popUpCount(in: ".fileImporter(isPresented: $open) {}") == 1)
        #expect(Self.popUpCount(in: "// NSPopover()\nNSPopover(); NSWindow()") == 2)
        #expect(Self.allowed["ContextDemoPanel.swift"]?.why.contains("system folder picker") == true)
        #expect(Self.allowed["ContextDemoBrowserSession.swift"]?.why.contains("exact window/process target") == true)
    }

    @Test func everyPopUpLeftIsListedWithItsReasonOrOwner() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoxClip")
        // Every folder under the sources (Services, Design), not just the top level.
        let walk = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let files = walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100 && files.contains { $0.deletingLastPathComponent().lastPathComponent == "Services" })
        for file in files where !file.lastPathComponent.hasPrefix("Debug") {
            let count = Self.popUpCount(in: try String(contentsOf: file, encoding: .utf8))
            let name = file.lastPathComponent
            #expect(count <= (Self.allowed[name]?.count ?? 0), "\(name) has \(count) pop-up call sites; allowed \(Self.allowed[name].map { "\($0.count): \($0.why)" } ?? "none") (impl-plan §13.1)")
        }
    }
}
