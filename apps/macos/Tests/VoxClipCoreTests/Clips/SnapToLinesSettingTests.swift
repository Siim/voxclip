import Foundation
import Testing
@testable import VoxClipCore

/// "Snap clip edges to sentence boundaries" is gone from Settings: Find Clips replies in whole lines, so its edges are
/// always on sentence boundaries. A settings file an older VoxClip wrote with `llm.clips.snapToLines` still loads without
/// error, and the key is kept on save, as every key the app doesn't use is.
@Suite struct SnapToLinesSettingTests {
    @Test(arguments: [true, false])
    func anOldSettingsFileWithTheKeyStillLoads(_ snap: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-snap-setting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        try FileManager.default.createDirectory(at: locations.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = #"{"schema":"voxclip-settings/1","llm.connector":"claude-code","llm.clips.snapToLines":\#(snap)}"#
        try Data(old.utf8).write(to: locations.settings)
        let store = JSONSettingsStore(locations: locations)
        let loaded = try await store.load()
        #expect(await store.lastLoadError == nil, "not treated as damaged")
        #expect(loaded.values["llm.clips.snapToLines"] == .bool(snap) && loaded.values["llm.connector"] == .string("claude-code"))
        try await store.save(loaded)
        try await store.flush()
        let saved = try JSONDecoder().decode(SettingsDocument.self, from: Data(contentsOf: locations.settings))
        #expect(saved == loaded)
        // A wrong type is still refused, as the shared schema's boolean says.
        #expect(throws: (any Error).self) { try SettingsDocument(values: ["llm.clips.snapToLines": .string("yes")]).validate() }
    }

    /// Find Clips always snaps: its request's default.
    @Test func findClipsSnaps() {
        let preset = ClipPreset(id: .best, label: "Best", instruction: "", minSeconds: 20, maxSeconds: 60, maxClips: 5, noOverlap: true)
        let request = ClipFinderRequest(transcript: Transcript(words: [], durationSeconds: 0, engine: EngineRef(id: .elevenlabs, engineVersion: "fixture"),
                                                               rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0)),
                                        preset: preset)
        #expect(request.snap)
    }
}
