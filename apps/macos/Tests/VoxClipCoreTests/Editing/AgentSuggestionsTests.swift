import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct AgentSuggestionsTests {
    private struct Vectors: Decodable {
        let projects: [String: JSONValue]
        let cases: [Vector]
    }

    private struct Vector: Decodable {
        let id: String
        let project: String
        let platform: String?
        let lengthSeconds: Int
        let transcribing: AgentSuggestions.Transcription?
        let exported: Bool?
        let next: [String]?
        let expected: [JSONValue]
        let composerReason: String?
    }

    @Test func sharedVectorsReplayExactly() throws {
        let vectors = try FixtureLoader.decode(Vectors.self, at: "fixtures/agent-chat/suggestion-cases.json")
        #expect(!vectors.cases.isEmpty)
        for vector in vectors.cases {
            let raw = try #require(vectors.projects[vector.project])
            let project = try ProjectJSON.decode(JSONEncoder().encode(raw))
            let state = AgentSuggestions.State(project: project, lengthSeconds: vector.lengthSeconds, platform: vector.platform,
                                               transcribing: vector.transcribing, exportedSinceLastChange: vector.exported ?? false,
                                               next: vector.next ?? [])
            let actual = try JSONDecoder().decode([JSONValue].self, from: JSONEncoder().encode(AgentSuggestions.chips(state: state)))
            #expect(actual == vector.expected, "\(vector.id)")
            #expect(state.composerReason == vector.composerReason, "\(vector.id)")
        }
    }
}
