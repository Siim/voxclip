import Foundation
import Testing
@testable import VoxClipCore

/// The Mac shell's dragged sizes (impl-plan V1a, item 18): `ui.layout.*` keys that are
/// known, validated and have no shared default. The pre-v2 right-column width stays a
/// known key; the app retires it at launch (WorkspaceLayoutTests).
@Suite(.offlineFixtures) struct ShellLayoutSettings {
    @Test func layoutSizesAreKnownAndValidated() throws {
        for key in ["ui.layout.explorerWidth", "ui.layout.rightWidth", "ui.layout.timelineHeight"] {
            #expect(SettingsDocument.isKnownKey(key))
            #expect(SettingsDocument.defaults[key] == nil)
            try SettingsDocument(values: [key: .number(300)]).validate()
            try SettingsDocument(values: [key: .null]).validate()
            #expect(throws: VoxClipError.self) { try SettingsDocument(values: [key: .string("wide")]).validate() }
            #expect(throws: VoxClipError.self) { try SettingsDocument(values: [key: .number(5000)]).validate() }
        }
        #expect(SettingsDocument.isKnownKey("ui.rightColumnWidth"))
    }

    /// The timeline's track height (impl-plan V9, §3.4): S, M or L by name, no shared default.
    @Test func trackHeightIsAKnownChoice() throws {
        let key = "ui.layout.trackHeight"
        #expect(SettingsDocument.isKnownKey(key))
        #expect(SettingsDocument.defaults[key] == nil)
        for choice in ["small", "medium", "large"] { try SettingsDocument(values: [key: .string(choice)]).validate() }
        #expect(throws: VoxClipError.self) { try SettingsDocument(values: [key: .string("huge")]).validate() }
        #expect(throws: VoxClipError.self) { try SettingsDocument(values: [key: .number(36)]).validate() }
    }
}
