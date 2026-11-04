import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/music/music-wire-cases.json; the C# twin replays the same file.
@Suite(.offlineFixtures) struct MusicProjectWireTests {
    private struct Patch: Decodable {
        let path: String
        let value: JSONValue?
        let remove: Bool?
    }
    private struct WireCase: Decodable {
        let id: String
        let patches: [Patch]
        let tooNew: Bool?
    }
    private struct Cases: Decodable {
        let format: String
        let valid: [WireCase]
        let invalid: [WireCase]
    }
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/music/music-wire-cases.json"))
    }

    private func replacing(_ original: JSONValue, path: ArraySlice<String>, patch: Patch) throws -> JSONValue {
        guard let key = path.first else { return patch.value ?? .null }
        switch original {
        case .object(var object):
            if path.count == 1 {
                if patch.remove == true { object.removeValue(forKey: key) } else { object[key] = patch.value ?? .null }
            } else {
                object[key] = try replacing(#require(object[key]), path: path.dropFirst(), patch: patch)
            }
            return .object(object)
        case .array(var array):
            let index = try #require(Int(key))
            array[index] = path.count == 1 ? (patch.value ?? .null) : try replacing(array[index], path: path.dropFirst(), patch: patch)
            return .array(array)
        default:
            throw VoxClipError.projectUnreadable("Invalid fixture patch")
        }
    }

    private func data(_ item: WireCase) throws -> Data {
        var value = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/music/music-project.voxclip"))
        for patch in item.patches {
            value = try replacing(value, path: patch.path.split(separator: "/").map(String.init)[...], patch: patch)
        }
        return try JSONEncoder().encode(value)
    }

    @Test func formatIsItsOwnFile() throws {
        #expect(try cases().format == "voxclip-music-wire-cases/1")
    }

    @Test func validCorpusRoundTripsAtV4AndOmitsEmptyMusic() throws {
        for item in try cases().valid {
            let project = try ProjectJSON.decode(data(item))
            #expect(project.schemaVersion == 4, "\(item.id)")
            let encoded = try ProjectJSON.encode(project)
            #expect(try ProjectJSON.decode(encoded) == project, "\(item.id)")
            #expect(try JSONProjectStore.decode(JSONProjectStore.encode(project)) == project, "\(item.id)")
            let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            if project.music.isEmpty { #expect(raw["music"] == nil, "\(item.id)") }
            for entry in (raw["music"] as? [[String: Any]]) ?? [] {
                // Every key is written, null included, so both Cores read each entry the same way.
                #expect(entry.count == 15, "\(item.id)")
            }
        }
    }

    @Test func invalidCorpusIsRejected() throws {
        for item in try cases().invalid {
            let input = try data(item)
            if item.tooNew == true {
                #expect(throws: VoxClipError.projectTooNew, "\(item.id)") { try ProjectJSON.decode(input) }
            } else {
                #expect(throws: (any Error).self, "\(item.id)") { try ProjectJSON.decode(input) }
                #expect(throws: (any Error).self, "\(item.id)") { try JSONProjectStore.decode(input) }
            }
        }
    }

    @Test func legacyProjectWithoutMusicSavesUnchangedAndPromotesOnFirstTrack() throws {
        let input = try FixtureLoader.data("fixtures/projects/interview-take.voxclip")
        let original = try ProjectJSON.decode(input)
        #expect(original.schemaVersion == 1 && original.music.isEmpty)
        let saved = try #require(JSONSerialization.jsonObject(with: ProjectJSON.encode(original)) as? [String: Any])
        #expect(saved["music"] == nil && saved["schemaVersion"] as? Int == 1)
        let track = ProjectMusic(id: "music-a", clipId: nil,
                                 asset: MusicAsset(file: original.id + "/music-own.wav", sha256: String(repeating: "c", count: 64), durationSeconds: 30),
                                 source: .file, title: "own", license: .own)
        var promoted = try MusicProject.setting(track, clipId: nil, in: original)
        #expect(promoted.schemaVersion == 4 && promoted.music == [track])
        #expect(try ProjectJSON.decode(ProjectJSON.encode(promoted)) == promoted)
        promoted = try MusicProject.setting(nil, clipId: nil, in: promoted)
        #expect(promoted.music.isEmpty && promoted.schemaVersion == 4)
        var legacy = original
        legacy.music = [track]
        #expect(throws: MusicProjectError.unsupportedVersion) { try ProjectJSON.encode(legacy) }
    }

    @Test func removingAClipRemovesItsTrackButKeepsTheFullVideoTrack() throws {
        var project = try ProjectJSON.decode(FixtureLoader.data("fixtures/music/music-project.voxclip"))
        #expect(project.music.map(\.id) == ["music-main", "music-full"])
        try project.applyEditing(.removeClip(id: "clip-main"))
        #expect(project.music.map(\.id) == ["music-full"])
        #expect(try ProjectJSON.decode(ProjectJSON.encode(project)) == project)
    }

    @Test func creditLinesFollowTheLicense() throws {
        let project = try ProjectJSON.decode(FixtureLoader.data("fixtures/music/music-project.voxclip"))
        let library = try #require(project.music.first)
        #expect(library.creditLine == "Music: \"Synthetic calm intro\" by Synthetic artist is licensed under CC BY 3.0.")
        #expect(MusicCredits.postText("Watch this", music: library) == "Watch this\n\nMusic: \"Synthetic calm intro\" by Synthetic artist is licensed under CC BY 3.0.")
        #expect(MusicCredits.postText(MusicCredits.postText("Watch this", music: library), music: library).components(separatedBy: "Music:").count == 2)
        var own = library
        own.source = .file; own.license = .own
        #expect(own.creditLine == nil && MusicCredits.postText("Hi", music: own) == "Hi")
        var cc0 = library
        cc0.license = .cc0; cc0.attribution = nil
        #expect(cc0.creditLine?.contains("(CC0) https://example.com/track/1") == true)
        let generated = try #require(project.music.last)
        #expect(generated.creditLine?.hasSuffix("made with Eleven Music.") == true)
    }
}
