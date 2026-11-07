import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/voice-lab/whole-clip-revoice-wire-cases.json (ADR-R46; the C# twin WholeClipRevoiceWireTests replays the
/// same file). The chip is Media's, so only the C# replay checks it.
@Suite(.offlineFixtures) struct WholeClipRevoiceWireReplayTests {
    private struct Patch: Decodable {
        let path: String
        let value: JSONValue?
        let remove: Bool?
    }
    private struct WireCase: Decodable {
        let id: String
        let patches: [Patch]
        let tooNew: Bool?
        let revoiced: Bool?
        let kinds: [String]?
        let postText: String?
    }
    private struct Cases: Decodable {
        let format: String
        let project: String
        let clipId: String
        let valid: [WireCase]
        let invalid: [WireCase]
    }
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/voice-lab/whole-clip-revoice-wire-cases.json"))
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

    private func data(_ item: WireCase, project: String) throws -> Data {
        var value = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(project))
        for patch in item.patches {
            value = try replacing(value, path: patch.path.split(separator: "/").map(String.init)[...], patch: patch)
        }
        return try JSONEncoder().encode(value)
    }

    @Test func formatIsItsOwnFile() throws {
        #expect(try cases().format == "voxclip-whole-clip-revoice-wire/1")
    }

    @Test func validCorpusOpensRendersItsDisclosureAndSavesUnchanged() throws {
        let file = try cases()
        #expect(file.valid.count == 14)
        for item in file.valid {
            let project = try JSONProjectStore.decode(data(item, project: file.project))
            try VoiceLabProject.validate(project)
            let encoded = try JSONProjectStore.encode(project)
            #expect(try JSONProjectStore.encode(JSONProjectStore.decode(encoded)) == encoded, "\(item.id)")
            let revoiced: Bool = WholeClipRevoice.isRevoiced(clipId: file.clipId, in: project)
            #expect(revoiced == item.revoiced, "\(item.id)")
            let disclosure = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight).disclosure
            #expect(disclosure.required, "\(item.id)")
            #expect(disclosure.kinds == item.kinds, "\(item.id)")
            #expect(disclosure.postText == item.postText, "\(item.id)")
            let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let voiceLab = try #require(raw["voiceLab"] as? [String: Any])
            for entry in (voiceLab["wholeClipRevoices"] as? [[String: Any]]) ?? [] {
                #expect(entry.count == 10, "\(item.id): every key is written, null included")
            }
            if project.voiceLab.wholeClipRevoices == nil { #expect(voiceLab["wholeClipRevoices"] == nil, "\(item.id)") }
        }
    }

    @Test func invalidCorpusIsRejected() throws {
        let file = try cases()
        #expect(file.invalid.count == 43)
        for item in file.invalid {
            let input = try data(item, project: file.project)
            if item.tooNew == true {
                #expect(throws: VoxClipError.projectTooNew, "\(item.id)") { try ProjectJSON.decode(input) }
                continue
            }
            let refused: Bool = (try? JSONProjectStore.decode(input)).map { project in (try? VoiceLabProject.validate(project)) == nil } ?? true
            #expect(refused, "\(item.id)")
        }
    }
}
