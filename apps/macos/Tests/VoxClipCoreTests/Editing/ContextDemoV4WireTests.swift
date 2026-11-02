import Foundation
import Testing
@testable import VoxClipCore

@Suite struct ContextDemoV4WireTests {
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
    private struct Legacy: Decodable {
        let version: Int
        let path: String
    }
    private struct Cases: Decodable {
        let valid: [WireCase]
        let invalid: [WireCase]
        let legacy: [Legacy]
    }
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/context-demo/wire-cases.json"))
    }
    private func fixture() throws -> Data { try FixtureLoader.data("fixtures/context-demo/v4-project.voxclip") }

    private func replacing(_ original: JSONValue, path: ArraySlice<String>, patch: Patch) throws -> JSONValue {
        guard let key = path.first else { return patch.value ?? .null }
        switch original {
        case .object(var object):
            if path.count == 1 {
                if patch.remove == true { object.removeValue(forKey: key) }
                else { object[key] = patch.value ?? .null }
            } else {
                object[key] = try replacing(#require(object[key]), path: path.dropFirst(), patch: patch)
            }
            return .object(object)
        case .array(var array):
            let index = try #require(Int(key))
            array[index] = try replacing(array[index], path: path.dropFirst(), patch: patch)
            return .array(array)
        default:
            throw VoxClipError.projectUnreadable("Invalid fixture patch")
        }
    }

    private func data(_ item: WireCase) throws -> Data {
        var value = try JSONDecoder().decode(JSONValue.self, from: fixture())
        for patch in item.patches {
            let path = patch.path.split(separator: "/").map(String.init)
            value = try replacing(value, path: path[...], patch: patch)
        }
        return try JSONEncoder().encode(value)
    }

    @Test func sharedValidCorpusRoundTripsWithoutChangingVersion() throws {
        for item in try cases().valid {
            let project = try ProjectJSON.decode(data(item))
            #expect(project.schemaVersion == 4, "\(item.id)")
            let encoded = try ProjectJSON.encode(project)
            #expect(try ProjectJSON.decode(encoded) == project, "\(item.id)")
            #expect(try JSONProjectStore.decode(JSONProjectStore.encode(project)) == project, "\(item.id)")
            if project.contextDemo == nil {
                let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                #expect(raw["contextDemo"] == nil)
            }
            if project.motionCues.isEmpty {
                let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                #expect(raw["motionCues"] == nil)
            }
        }
    }

    @Test func strictSharedInvalidCorpusRejectsBeforeNormalization() throws {
        for item in try cases().invalid {
            let input = try data(item)
            if item.tooNew == true {
                #expect(throws: VoxClipError.projectTooNew, "\(item.id)") { try ProjectJSON.decode(input) }
                #expect(throws: VoxClipError.projectTooNew, "\(item.id)") { try JSONProjectStore.decode(input) }
            } else {
                #expect(throws: (any Error).self, "\(item.id)") { try ProjectJSON.decode(input) }
                #expect(throws: (any Error).self, "\(item.id)") { try JSONProjectStore.decode(input) }
            }
        }
    }

    @Test func realLegacyDocumentsPreserveVersionAndAbsentFieldShapes() throws {
        for item in try cases().legacy {
            let input = try FixtureLoader.data(item.path)
            let original = try ProjectJSON.decode(input)
            let encoded = try ProjectJSON.encode(original)
            let saved = try ProjectJSON.decode(encoded)
            let before = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
            let after = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(saved == original)
            #expect(saved.schemaVersion == item.version && saved.contextDemo == nil && saved.motionCues.isEmpty)
            #expect(after["contextDemo"] == nil && after["motionCues"] == nil)
            #expect(Set(after.keys) == Set(before.keys))
            let voiceBefore = try #require(before["voiceLab"] as? [String: Any])
            let voiceAfter = try #require(after["voiceLab"] as? [String: Any])
            #expect(Set(voiceBefore.keys) == Set(voiceAfter.keys))
            #expect(try JSONProjectStore.decode(JSONProjectStore.encode(original)).schemaVersion == item.version)
        }
    }

    @Test func version4KeepsFullV3VoiceSemanticsAndNeverDowngrades() throws {
        let input = try FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip")
        let original = try ProjectJSON.decode(input)
        var upgraded = original
        upgraded.schemaVersion = 4
        let saved = try ProjectJSON.decode(ProjectJSON.encode(upgraded))
        #expect(saved.voiceLab == original.voiceLab)
        #expect(try VoiceLabProject.upgradeToV3(saved).schemaVersion == 4)
        #expect(try ContextDemoProject.upgradeToV4(saved) == saved)
        var invalidPolicy = saved
        invalidPolicy.voiceLab.cleanAudio = nil
        #expect(throws: (any Error).self) { try ProjectJSON.encode(invalidPolicy) }
    }

    @Test func onlyFeatureMutationPromotesLegacyAndRemovingFeatureDoesNotDowngrade() throws {
        let original = try ProjectJSON.decode(fixture())
        var legacy = original
        legacy.schemaVersion = 1
        legacy.contextDemo = nil
        legacy.motionCues = []
        legacy.voiceLab = ProjectVoiceLab()
        #expect(try ProjectJSON.decode(ProjectJSON.encode(legacy)).schemaVersion == 1)
        let changed = try ContextDemoProject.settingMotionCues(original.motionCues, in: legacy)
        #expect(changed.schemaVersion == 4 && changed.voiceLab.cleanAudio != nil)
        #expect(legacy.schemaVersion == 1 && legacy.motionCues.isEmpty)
        #expect(try ProjectJSON.decode(ProjectJSON.encode(changed)).motionCues == original.motionCues)
        let removed = try ContextDemoProject.settingMotionCues([], in: changed)
        #expect(removed.schemaVersion == 4 && removed.motionCues.isEmpty)
        var invalid = changed
        invalid.schemaVersion = 3
        #expect(throws: (any Error).self) { try ProjectJSON.encode(invalid) }
        invalid = original
        invalid.media.source.contentKey = String(repeating: "c", count: 64)
        #expect(throws: (any Error).self) { try ProjectJSON.encode(invalid) }
    }

    @Test func legacyPaidSegmentsRequireReviewInsteadOfLosingTheirPolicy() throws {
        let legacy = try ProjectJSON.decode(FixtureLoader.data("fixtures/voice-lab/passage-project.voxclip"))
        let before = try ProjectJSON.encode(legacy)
        let current = try ProjectJSON.decode(fixture())
        #expect(throws: VoiceLabProjectError.legacySegmentsNeedReview) {
            try ContextDemoProject.settingMotionCues(current.motionCues, in: legacy)
        }
        #expect(legacy.schemaVersion == 2)
        #expect(try ProjectJSON.encode(legacy) == before)
    }

    @Test func explicitSidecarCodecDoesNotAttachAnotherSource() throws {
        let original = try ProjectJSON.decode(fixture())
        let document = try #require(original.contextDemo)
        #expect(try ContextDemoCodec.decode(ContextDemoCodec.encode(document)) == document)
        let legacy = try ProjectJSON.decode(FixtureLoader.data("fixtures/projects/interview-take.voxclip"))
        #expect(legacy.contextDemo == nil && legacy.schemaVersion == 1)
    }
}
