import Foundation
import Testing
@testable import VoxClipCore

private struct JoinAdvisoryCase: Decodable, Sendable {
    let name: String
    let qa: [String: JSONValue]
    let valid: Bool
}
private struct JoinAdvisoryDocument: Decodable {
    let schema: String
    let baseProject: String
    let caseCount: Int
    let cases: [JoinAdvisoryCase]
}

@Suite("Shared join advisory recipes", .offlineFixtures)
struct VoiceLabJoinAdvisoryRecipeTests {
    private static let document = try? FixtureLoader.decode(JoinAdvisoryDocument.self,
        at: "fixtures/voice-lab/join-advisory-cases.json")

    @Test(arguments: Self.document?.cases ?? [], [3, 4])
    fileprivate func sharedRecipe(_ vector: JoinAdvisoryCase, version: Int) throws {
        let document = try #require(Self.document)
        #expect(document.schema == "voxclip-voice-lab-join-advisory-cases/1")
        #expect(document.cases.count == document.caseCount && document.caseCount == 16)
        let base = try FixtureLoader.data("fixtures/voice-lab/\(document.baseProject)")
        var root = try #require(JSONSerialization.jsonObject(with: base) as? [String: Any])
        root["schemaVersion"] = version
        var lab = try #require(root["voiceLab"] as? [String: Any])
        var segments = try #require(lab["segments"] as? [[String: Any]])
        var segment = segments[0]
        var candidates = try #require(segment["candidates"] as? [[String: Any]])
        var recipe = try #require(candidates[0]["recipe"] as? [String: Any])
        var qa = try #require(recipe["qa"] as? [String: Any])
        let patch = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(vector.qa)) as? [String: Any])
        qa.merge(patch) { _, new in new }
        recipe["qa"] = qa; candidates[0]["recipe"] = recipe; segment["candidates"] = candidates
        var summary = try #require(segment["qa"] as? [String: Any])
        for key in summary.keys { summary[key] = qa[key] }
        segment["qa"] = summary; segments[0] = segment; lab["segments"] = segments; root["voiceLab"] = lab
        let data = try JSONSerialization.data(withJSONObject: root)
        if !vector.valid {
            #expect(throws: (any Error).self) { try JSONProjectStore.decode(data) }
            return
        }
        let project = try JSONProjectStore.decode(data)
        let encoded = try JSONProjectStore.encode(project)
        let roundTrip = try JSONProjectStore.decode(encoded)
        #expect(try JSONProjectStore.encode(roundTrip) == encoded)
        let prepared = try VoiceLabRenderContract.prepare(roundTrip, scope: .full, labelPosition: .topRight)
        try prepared.verify(project: roundTrip, scope: .full, labelPosition: .topRight)
        let accepted = try #require(prepared.selectedSegmentRecipes.first?.recipe.qa)
        if let advisory = vector.qa["joinAdvisory"] {
            let saved = try #require(accepted.joinAdvisory)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            #expect(try JSONDecoder().decode(JSONValue.self, from: encoder.encode(saved)) == advisory)
        } else {
            #expect(accepted.joinAdvisory == nil)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("\"joinAdvisory\""))
        }
    }
}
