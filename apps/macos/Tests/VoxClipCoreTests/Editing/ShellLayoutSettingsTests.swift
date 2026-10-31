import Foundation
import Testing
@testable import VoxClipCore

/// The Mac shell's dragged sizes (impl-plan V1a, item 18): `ui.layout.*` keys that are
/// known, validated and have no shared default, and the pre-v2 right-column width that
/// leaves the file once the app drops it.
@Suite struct ShellLayoutSettings {
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

    @Test func theRetiredRightColumnWidthLeavesTheFileOnSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-shell-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        try Data(#"{"schema":"voxclip-settings/1","ui.rightColumnWidth":500,"ui.layout.rightWidth":420}"#.utf8).write(to: locations.settings)
        let store = JSONSettingsStore(locations: locations)
        var settings = try await store.load()
        #expect(settings.values["ui.rightColumnWidth"] == .number(500))
        settings.values.removeValue(forKey: "ui.rightColumnWidth")
        try await store.save(settings)
        try await store.flush()
        let disk = try JSONDecoder().decode(SettingsDocument.self, from: Data(contentsOf: locations.settings))
        #expect(disk.values["ui.rightColumnWidth"] == nil)
        #expect(disk.values["ui.layout.rightWidth"] == .number(420))
    }
}
