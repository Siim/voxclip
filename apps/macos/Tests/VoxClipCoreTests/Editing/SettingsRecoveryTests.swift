import Foundation
import Testing
@testable import VoxClipCore

@Suite struct EditingSettingsRecovery {
    @Test(arguments: ["malformed", "invalid", "schema", "missing-schema", "wrong-shape"])
    func damagedSettingsRecoverPersistAndCanBeSaved(_ kind: String) async throws {
        let directory = try EditingPersistence().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        var object: [String: JSONValue] = [
            "schema": .string("voxclip-settings/1"), "general.appearance": .string("dark"),
            "cache.limitGB": .number(3), "update.htmlURL": .string("http://github.com/not-https"),
            "llm.model.openai": .string("saved-model"), "future.preference": .object(["keep": .bool(true)]),
            "update.autoCheck": .bool(false)
        ]
        if kind == "schema" { object["schema"] = .string("invalid-schema") }
        if kind == "missing-schema" { object.removeValue(forKey: "schema") }
        let original: Data
        if kind == "malformed" { original = Data("{broken".utf8) }
        else { original = try JSONEncoder().encode(kind == "wrong-shape" ? JSONValue.array([]) : .object(object)) }
        try original.write(to: locations.settings)
        let logger = EditingTestLogger(), store = JSONSettingsStore(locations: locations, logger: logger)
        async let first = store.load()
        async let second = store.load()
        let (recovered, cached) = try await (first, second)
        #expect(recovered == cached)
        try recovered.validate()
        #expect(recovered["cache.limitGB"] == .number(5))
        #expect(recovered["update.htmlURL"] == .null)
        if kind != "malformed" && kind != "wrong-shape" {
            #expect(recovered["general.appearance"] == .string("dark"))
            #expect(recovered.modelID(for: "openai") == "saved-model")
            #expect(recovered.values["future.preference"] == object["future.preference"])
            #expect(recovered["update.autoCheck"] == .bool(false))
        } else { #expect(recovered == SettingsDocument()) }
        #expect(await store.lastLoadError == .projectUnreadable("Damaged settings were set aside; valid preferences were recovered"))
        let entries = await logger.entries
        #expect(entries.count == 1 && entries[0].level == .warn && entries[0].category == "settings")
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings.json.damaged-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
        #expect(try JSONDecoder().decode(SettingsDocument.self, from: Data(contentsOf: locations.settings)) == recovered)
        let freshStore = JSONSettingsStore(locations: locations)
        #expect(try await freshStore.load() == recovered)
        #expect(await freshStore.lastLoadError == nil)
        #expect(await store.lastWriteError == nil)
        var changed = recovered
        changed["general.appearance"] = .string("light")
        try await store.save(changed)
        try await store.flush()
        let reopened = try await JSONSettingsStore(locations: locations).load()
        #expect(reopened == changed)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
    }

    @Test func recoveredSettingsWriteFailurePreservesOriginalAndReportsCoreError() async throws {
        let directory = try EditingPersistence().temporaryDirectory()
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locations.settings.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = Data("{\"schema\":\"voxclip-settings/1\",\"update.autoCheck\":false,\"cache.limitGB\":3,\"future.preference\":{\"keep\":true}}".utf8)
        try original.write(to: locations.settings)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locations.settings.path)
        let store = JSONSettingsStore(locations: locations)
        let failure = VoxClipError.projectUnreadable("Could not persist recovered settings")
        await #expect(throws: failure) { try await store.load() }
        #expect(await store.lastLoadError == failure)
        #expect(await store.lastWriteError == "Settings could not be saved")
        #expect(try Data(contentsOf: locations.settings) == original)
        func backups() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings.json.damaged-") }
        }
        #expect(try backups().count == 1)
        let backup = try #require(backups().first)
        #expect(try Data(contentsOf: backup) == original)
        let recovered = try await store.load()
        #expect(recovered["update.autoCheck"] == .bool(false))
        #expect(recovered.values["cache.limitGB"] == nil)
        #expect(recovered["future.preference"] == .object(["keep": .bool(true)]))
        #expect(await store.lastLoadError == failure)
        #expect(await store.lastWriteError == "Settings could not be saved")
        #expect(try backups().count == 1)
        let writeFailure = VoxClipError.projectUnreadable("Settings could not be saved")
        await #expect(throws: writeFailure) { try await store.flush() }
        #expect(try backups().count == 1)
        var changed = recovered
        changed["general.appearance"] = .string("light")
        try await store.save(changed)
        #expect(try await store.load() == changed)
        await #expect(throws: writeFailure) { try await store.flush() }
        #expect(await store.lastLoadError == failure)
        #expect(await store.lastWriteError == "Settings could not be saved")
        #expect(try backups().count == 1)
        #expect(try Data(contentsOf: locations.settings) == original)
        #expect(try Data(contentsOf: backup) == original)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locations.settings.path)
        #expect(try await store.load() == changed)
        try await store.flush()
        #expect(await store.lastWriteError == nil)
        #expect(await store.lastLoadError == failure)
        #expect(try await JSONSettingsStore(locations: locations).load() == changed)
        #expect(try backups().count == 1)
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func updateURLsRequireHTTPSAndExactGitHubHost() async throws {
        let directory = try EditingPersistence().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        let store = JSONSettingsStore(locations: locations)
        for value in [JSONValue.null, .string("https://github.com/owner/repo/releases/tag/v1.0.0")] {
            try await store.save(SettingsDocument(values: ["update.htmlURL": value]))
            try await store.flush()
        }
        let original = try Data(contentsOf: locations.settings)
        for value in ["http://github.com/release", "https://github.com.evil.example/release", "https://evil.example/github.com", "https://github.com@evil.example/release", "https://user@github.com/release", "//github.com/release", "not a URL", "https:github.com/release"] {
            await #expect(throws: VoxClipError.self) { try await store.save(SettingsDocument(values: ["update.htmlURL": .string(value)])) }
        }
        await #expect(throws: VoxClipError.self) { try await store.save(SettingsDocument(values: ["future.number": .number(.nan)])) }
        #expect(try Data(contentsOf: locations.settings) == original)
    }

    /// update.lastCheckAt is written in the canonical form (editing.md §10.1), and the whole-second text earlier builds
    /// wrote still saves, loads and parses.
    @Test func updateCheckTimesKeepTheCanonicalAndEarlierForms() async throws {
        let directory = try EditingPersistence().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        let store = JSONSettingsStore(locations: locations)
        let checked = Date(timeIntervalSince1970: 1_792_998_000.25)
        #expect(UTCTimestamp.string(from: checked) == "2026-10-26T07:00:00.250Z")
        for text in [try #require(UTCTimestamp.string(from: checked)), checked.ISO8601Format()] {
            try await store.save(SettingsDocument(values: ["update.lastCheckAt": .string(text)]))
            try await store.flush()
            #expect(try await JSONSettingsStore(locations: locations).load()["update.lastCheckAt"] == .string(text))
            #expect(UTCTimestamp.date(from: text, allowingOffset: true) != nil)
        }
        await #expect(throws: VoxClipError.self) { try await store.save(SettingsDocument(values: ["update.lastCheckAt": .string("yesterday")])) }
    }

    @Test func settingsReadFailuresUseCoreErrors() async throws {
        let directory = try EditingPersistence().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        try FileManager.default.createDirectory(at: locations.settings, withIntermediateDirectories: false)
        await #expect(throws: VoxClipError.projectUnreadable("Could not read settings")) {
            try await JSONSettingsStore(locations: locations).load()
        }
    }
}
