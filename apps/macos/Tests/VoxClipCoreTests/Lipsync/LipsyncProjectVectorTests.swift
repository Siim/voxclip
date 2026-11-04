import Foundation
import Testing
@testable import VoxClipCore

/// The shared lip-synced Rewrite project (voice-lab.md §8.9): one `cut_off` segment over the source video and one `remap`
/// segment over a cut, from the independent generator's `lipsync-project-cases.json` and `lipsync-render-v3.voxclip`.
/// The Windows Core replays the same files and refuses to render a selected lip-synced segment; Mac prepares every one.
@Suite(.offlineFixtures) struct LipsyncProjectVectorTests {
    struct Cases: Decodable {
        struct Segment: Decodable {
            let id: String; let candidate: Int; let syncMode: String; let baseMode: String; let assetId: String
            let windowStartSample: Int64; let windowEndSample: Int64; let outputSamples: Int64; let plainCandidate: Int
        }
        struct Render: Decodable { let id: String; let selected: [String: Int]; let windows: String?; let mac: String? }
        struct Invalid: Decodable { let id: String; let segment: String; let error: String }
        let schema: String; let caseCount: Int; let project: String
        let segments: [Segment]; let renders: [Render]; let invalid: [Invalid]
    }
    private let raw: Data
    private let cases: Cases
    init() throws {
        cases = try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/voice-lab/lipsync-project-cases.json"))
        raw = try FixtureLoader.data("fixtures/voice-lab/\(cases.project)")
    }

    @Test func casesHaveTheirSchemaAndCount() throws {
        let keys = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/lipsync-project-cases.json")) as? [String: Any]).keys
        #expect(Set(keys) == ["schema", "caseCount", "project", "segments", "renders", "invalid"])
        #expect(cases.schema == "voxclip-lipsync-project/1" && cases.caseCount == 12)
        #expect(cases.segments.count + cases.renders.count + cases.invalid.count == cases.caseCount)
    }

    @Test func lipSyncedRecipesValidateAndSaveUnchanged() throws {
        let project = try JSONProjectStore.decode(raw)
        try VoiceLabProject.validate(project)
        try VoiceLabRenderValidation.validate(project)
        for row in cases.segments {
            let segment = try #require(project.voiceLab.segments.first { $0.id == row.id })
            let video = try #require(segment.candidates[row.candidate].recipe?.video)
            #expect(video.mode == .lipsync && video.syncMode == row.syncMode && video.assetId == row.assetId, "\(row.id)")
            #expect(video.windowStartSample == row.windowStartSample && video.windowEndSample == row.windowEndSample, "\(row.id)")
            #expect(video.outputSamples == row.outputSamples && video.lipsyncBase.mode.rawValue == row.baseMode, "\(row.id)")
            #expect(segment.candidates[row.plainCandidate].recipe?.video == video.lipsyncBase, "\(row.id)")
        }
        let saved = try JSONProjectStore.encode(project)
        let before = try #require(JSONSerialization.jsonObject(with: raw) as? NSDictionary)
        let after = try #require(JSONSerialization.jsonObject(with: saved) as? NSDictionary)
        #expect(before == after, "a save changed the lip-synced project")
        #expect(try JSONProjectStore.encode(JSONProjectStore.decode(saved)) == saved)
    }

    @Test func everySelectionPreparesOnMac() throws {
        for row in cases.renders {
            var project = try JSONProjectStore.decode(raw)
            for (id, index) in row.selected.sorted(by: { $0.key < $1.key }) { project = try VoiceLabProject.selectCandidate(index, id: id, in: project) }
            #expect(row.mac == nil)
            let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
            #expect(prepared.selectedSegmentRecipes.allSatisfy { VoiceLabRenderInput.supportsVideoRecipe($0.recipe.video) }, "\(row.id)")
        }
    }

    @Test func invalidLipSyncedRecipesAreRefusedWithTheSharedError() throws {
        let document = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let invalid = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/lipsync-project-cases.json")) as? [String: Any])["invalid"] as? [[String: Any]]
        for (row, json) in zip(cases.invalid, try #require(invalid)) {
            var changed = document
            var voice = changed["voiceLab"] as! [String: Any]
            var segments = voice["segments"] as! [[String: Any]]
            let position = try #require(segments.firstIndex { $0["id"] as? String == row.segment })
            var candidates = segments[position]["candidates"] as! [[String: Any]]
            var recipe = candidates[0]["recipe"] as! [String: Any]
            var video = recipe["video"] as! [String: Any]
            for (key, value) in json["set"] as! [String: Any] { video[key] = value }
            recipe["video"] = video; candidates[0]["recipe"] = recipe; segments[position]["candidates"] = candidates
            voice["segments"] = segments; changed["voiceLab"] = voice
            var refusal: (any Error)?
            do {
                let project = try JSONProjectStore.decode(JSONSerialization.data(withJSONObject: changed))
                try VoiceLabProject.validate(project)
                try VoiceLabRenderValidation.validate(project)
            } catch { refusal = error }
            let code = (refusal as? VoiceLabProjectError).map { String(describing: $0) }
            #expect(code == row.error, "\(row.id): \(String(describing: refusal))")
        }
    }
}
