import Foundation
import Testing
@testable import VoxClipCore

/// Claude mode's settings (design.md §6.6): `clips.mode`, `clips.autopilot.count` and `clips.autopilot.capUSD`, replayed
/// from the shared vectors both Cores read (shared/fixtures/clips-mode/clips-mode-settings-cases.json).
@Suite(.offlineFixtures) struct ClipsModeSettingsTests {
    private struct Cases: Decodable {
        struct Expect: Decodable { let mode: String?; let count: Int; let capUSD: Int }
        struct Valid: Decodable { let name: String; let settings: JSONValue; let expect: Expect }
        struct Invalid: Decodable { let name: String; let settings: JSONValue }
        let schema: String
        let valid: [Valid]
        let invalid: [Invalid]
        let caseCount: Int
    }

    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/clips-mode/clips-mode-settings-cases.json"))
    }

    private func document(_ value: JSONValue) throws -> SettingsDocument {
        try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(value))
    }

    @Test func everyValidCaseLoadsReadsBackAndSavesUnchanged() async throws {
        let cases = try cases()
        #expect(cases.schema == "voxclip-clips-mode-settings-cases/1")
        #expect(cases.caseCount == cases.valid.count + cases.invalid.count)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-clips-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for item in cases.valid {
            let settings = try document(item.settings)
            try settings.validate()
            let read = settings.clipsAutopilot
            #expect(read.mode?.rawValue == item.expect.mode, "\(item.name)")
            #expect(read.count == item.expect.count, "\(item.name)")
            #expect(read.capUSD == item.expect.capUSD, "\(item.name)")
            // Round trip through the store: the three keys come back as written.
            let folder = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = JSONSettingsStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": folder.path]))
            try await store.save(settings)
            try await store.flush()
            let loaded = try await JSONSettingsStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": folder.path])).load()
            #expect(loaded.clipsAutopilot == read, "\(item.name)")
            for key in [ClipsMode.key, ClipsMode.countKey, ClipsMode.capKey] { #expect(loaded.values[key] == settings.values[key], "\(item.name) \(key)") }
        }
    }

    @Test func everyInvalidCaseIsRefused() throws {
        for item in try cases().invalid {
            #expect(throws: VoxClipError.self, "\(item.name)") { try document(item.settings).validate() }
        }
    }

    @Test func keysAreKnownWithTheSchemaDefaults() throws {
        #expect(SettingsDocument.isKnownKey(ClipsMode.key))
        #expect(SettingsDocument.isKnownKey(ClipsMode.countKey))
        #expect(SettingsDocument.isKnownKey(ClipsMode.capKey))
        #expect(SettingsDocument.defaults[ClipsMode.key] == nil)
        let shared = try FixtureLoader.sharedRoot()
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.appendingPathComponent("schemas/settings.schema.json"))) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let mode = try #require(properties[ClipsMode.key] as? [String: Any])
        #expect(Set(try #require(mode["enum"] as? [String])) == Set(ClipsMode.allCases.map(\.rawValue)))
        #expect(mode["default"] == nil)
        let count = try #require(properties[ClipsMode.countKey] as? [String: Any])
        #expect(try #require(count["enum"] as? [Int]) == ClipsMode.counts)
        #expect(count["default"] as? Int == ClipsMode.defaultCount)
        let cap = try #require(properties[ClipsMode.capKey] as? [String: Any])
        #expect(try #require(cap["enum"] as? [Int]) == ClipsMode.capsUSD)
        #expect(cap["default"] as? Int == ClipsMode.defaultCapUSD)
        #expect(SettingsDocument.defaults[ClipsMode.countKey] == .number(3))
        #expect(SettingsDocument.defaults[ClipsMode.capKey] == .number(2))
    }

    @Test func settingWritesTheThreeKeysAndRefusesOtherValues() throws {
        var settings = SettingsDocument()
        try settings.setClipsAutopilot(ClipsAutopilotSettings(mode: .claude, count: 5, capUSD: 0))
        try settings.validate()
        #expect(settings.values[ClipsMode.key] == .string("claude"))
        #expect(settings.clipsAutopilot == ClipsAutopilotSettings(mode: .claude, count: 5, capUSD: 0))
        #expect(settings.clipsAutopilot.summary == "✦ Claude does it all · top 5 · ≤$0")
        #expect(throws: VoxClipError.self) { try settings.setClipsAutopilot(ClipsAutopilotSettings(mode: .claude, count: 4, capUSD: 2)) }
        #expect(throws: VoxClipError.self) { try settings.setClipsAutopilot(ClipsAutopilotSettings(mode: .pick, count: 3, capUSD: 3)) }
        #expect(settings.clipsAutopilot.count == 5)
    }
}
