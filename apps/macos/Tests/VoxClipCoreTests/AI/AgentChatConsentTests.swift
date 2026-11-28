import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) @MainActor struct AgentChatConsentTests {
    @Test(arguments: [ConnectorID.openai, .anthropic, .claudeCode])
    func keySendsAskOnceWithoutStartingTheFirstRequest(_ id: ConnectorID) async throws {
        let project = try ProjectJSON.decode(FixtureLoader.data("fixtures/projects/clip-from-long-take.voxclip"))
        let done: JSONValue = .object(["say": .string("Ready"), "done": .bool(true), "calls": .array([])])
        let connector = ScriptedConnector(id: id, authMethod: "api_key", replies: [done, done])
        let session = try AgentChatSession(project: project, shared: SharedResources.locate(), connector: connector,
                                           model: "fixture", estimatedUSD: 0.02...0.06)
        await session.send(.init(text: "Look at this clip"))

        guard case .approvalRequired(let approval) = session.status else { Issue.record("Expected inline approval"); return }
        #expect(approval.action == .agentChat)
        #expect(approval.connector == id)
        #expect(approval.estimatedUSD == 0.02...0.06)
        #expect(await connector.requests.isEmpty)
        #expect(session.project.agentThread == nil)

        await session.respond(to: approval, allow: true)
        await session.send(.init(text: "Look again"))
        let requests = await connector.requests
        #expect(requests.map(\.feature) == [.agentChat, .agentChat])
        let arguments = requests.first?.schema[ai: "properties"][ai: "calls"][ai: "items"][ai: "properties"][ai: "args"]
        #expect(arguments?[ai: "additionalProperties"] == .bool(false))
        #expect(arguments?[ai: "required"] == .array([.string("json")]))
        #expect(session.project.agentThread?.turns.count == 2)
    }
}
