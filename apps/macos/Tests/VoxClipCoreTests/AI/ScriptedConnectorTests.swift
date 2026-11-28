import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct ScriptedConnectorTests {
    @Test func returnsRepliesInOrderAndFailsWhenTheScriptRunsOut() async throws {
        let connector = ScriptedConnector(replies: [.string("first"), .string("second")])
        let request = LLMRequest(feature: .test, system: "", instruction: "Test the script",
                                 schemaName: "test", schema: .null, maxOutputTokens: 1,
                                 timeout: .seconds(1), tag: "scripted-test")

        #expect(try await connector.send(request, model: "fixture").object == .string("first"))
        #expect(try await connector.send(request, model: "fixture").object == .string("second"))
        await #expect(throws: ScriptedConnector.Exhausted.self) {
            try await connector.send(request, model: "fixture")
        }
        #expect(await connector.requests.map(\.instruction) == Array(repeating: request.instruction, count: 3))
    }
}
