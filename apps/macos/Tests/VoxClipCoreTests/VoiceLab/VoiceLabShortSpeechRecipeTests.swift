import Foundation
import Testing
@testable import VoxClipCore

private struct ShortSpeechRecipeCase: Decodable, Sendable {
    let name: String
    let qa: [String: JSONValue]
    let error: String?
}
private struct ShortSpeechRecipeDocument: Decodable {
    let schema: String
    let baseProject: String
    let caseCount: Int
    let cases: [ShortSpeechRecipeCase]
}

@Suite("Shared short-speech recipe evidence")
struct VoiceLabShortSpeechRecipeTests {
    private static let document = try? FixtureLoader.decode(ShortSpeechRecipeDocument.self,
        at: "fixtures/voice-lab/short-speech-recipe-cases.json")

    @Test func independentFixtureEnvelope() throws {
        let document = try #require(Self.document)
        let data = try FixtureLoader.data("fixtures/voice-lab/short-speech-recipe-cases.json")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["schema", "baseProject", "caseCount", "cases"])
        #expect(document.schema == "voxclip-voice-lab-short-speech-recipe-cases/1")
        #expect(document.baseProject == "passage-render-v3.voxclip")
        #expect(document.caseCount == 27)
        #expect(document.cases.count == document.caseCount)
        #expect(Set(document.cases.map(\.name)).count == document.caseCount)
    }

    @Test(arguments: Self.document?.cases ?? [], [3, 4])
    fileprivate func sharedRecipe(_ vector: ShortSpeechRecipeCase, version: Int) throws {
        let data = try projectData(vector, version: version)
        if vector.error != nil {
            // Core error taxonomies differ; both readers must refuse every invalid vector.
            do {
                _ = try JSONProjectStore.decode(data)
                Issue.record("Accepted invalid short-speech recipe: \(vector.name), v\(version)")
            } catch let error as VoxClipError {
                #expect(error.code == .projectUnreadable)
            } catch let error as VoiceLabProjectError {
                #expect(error == .qaRejected || error == .invalidSegment)
            }
            return
        }
        let project = try JSONProjectStore.decode(data)
        try VoiceLabProject.validate(project)
        let encoded = try JSONProjectStore.encode(project)
        let roundTrip = try JSONProjectStore.decode(encoded)
        #expect(try JSONProjectStore.encode(roundTrip) == encoded)
        let prepared = try VoiceLabRenderContract.prepare(roundTrip, scope: .full, labelPosition: .topRight)
        try prepared.verify(project: roundTrip, scope: .full, labelPosition: .topRight)
        #expect(prepared.outputPlan.outputSamples == 7_000)
        #expect(prepared.disclosure.required)
        #expect(abs(prepared.disclosure.outputAISeconds - 0.7) < 0.000_001)
        let recipe = try #require(prepared.selectedSegmentRecipes.first?.recipe)
        #expect(prepared.selectedSegmentRecipes.count == 1)
        if let evidence = vector.qa["shortSpeech"] {
            let actual = try #require(recipe.qa.shortSpeech)
            let actualJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(actual))
            #expect(actualJSON == evidence)
            if actual.mode == .unmeasured {
                #expect(recipe.qa.speakerScore == nil)
                #expect(recipe.qa.speakerPassed == false)
            }
        } else {
            #expect(recipe.qa.shortSpeech == nil)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("\"shortSpeech\""))
        }
    }

    private func projectData(_ vector: ShortSpeechRecipeCase, version: Int) throws -> Data {
        let document = try #require(Self.document)
        let data = try FixtureLoader.data("fixtures/voice-lab/\(document.baseProject)")
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["schemaVersion"] = version
        var lab = try #require(root["voiceLab"] as? [String: Any])
        var segments = try #require(lab["segments"] as? [[String: Any]])
        var segment = try #require(segments.first)
        var candidates = try #require(segment["candidates"] as? [[String: Any]])
        var candidate = try #require(candidates.first)
        var recipe = try #require(candidate["recipe"] as? [String: Any])
        var qa = try #require(recipe["qa"] as? [String: Any])
        let overrides = try JSONEncoder().encode(vector.qa)
        qa.merge(try #require(JSONSerialization.jsonObject(with: overrides) as? [String: Any])) { _, new in new }
        recipe["qa"] = qa; candidate["recipe"] = recipe; candidates[0] = candidate
        var segmentQA = try #require(segment["qa"] as? [String: Any])
        segmentQA["speakerScore"] = qa["speakerScore"]
        segment["qa"] = segmentQA; segment["candidates"] = candidates; segments[0] = segment
        lab["segments"] = segments; root["voiceLab"] = lab
        return try JSONSerialization.data(withJSONObject: root)
    }
}
