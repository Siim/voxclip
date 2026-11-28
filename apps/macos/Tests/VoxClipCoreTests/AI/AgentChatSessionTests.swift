import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) @MainActor struct AgentChatSessionTests {
    private func reply(_ say: String, done: Bool = true, calls: [JSONValue] = []) -> JSONValue {
        .object(["say": .string(say), "calls": .array(calls), "done": .bool(done)])
    }

    private func session(_ connector: ScriptedConnector, budget: Int = 8) throws -> AgentChatSession {
        let project = try ProjectJSON.decode(FixtureLoader.data("fixtures/projects/clip-from-long-take.voxclip"))
        return try AgentChatSession(project: project, shared: SharedResources.locate(), connector: connector,
                                    model: "fixture", feature: .test, stepBudget: budget)
    }

    @Test func deliversRefusalsAndStopsAtTheStepBudget() async throws {
        let call: JSONValue = .object(["tool": .string("export"), "args": .object([:])])
        let step = reply("Working", done: false, calls: [call])
        let connector = ScriptedConnector(replies: [step, step, reply("No export was made.")])
        let session = try session(connector, budget: 2)

        await session.send(.init(text: "Export this"))

        let requests = await connector.requests
        #expect(requests.count == 2)
        #expect(requests.last?.instruction.contains("Unknown tool: export") == true)
        #expect(session.status == .budget(2))
        let turn = try #require(session.project.agentThread?.turns.last)
        #expect(turn.state == .stopped)
        #expect(turn.steps.map(\.ok) == [false, false])
        #expect(turn.changes.isEmpty)

        await session.resume()
        #expect(session.status == .finished)
        #expect(session.project.agentThread?.turns.map(\.id) == [turn.id])
    }

    @Test func steersTheNextRequestAndQueuesTheNextTurn() async throws {
        let (entered, started) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let first = reply("Working", done: false)
        let done = reply("Ready")
        let connector = ScriptedConnector(script: [
            { _, model in
                started.yield(())
                for await _ in released { break }
                return .init(object: first, model: model, stop: .complete)
            },
            { _, model in .init(object: done, model: model, stop: .complete) },
            { _, model in .init(object: done, model: model, stop: .complete) }
        ])
        let session = try session(connector)
        let sending = Task { await session.send(.init(text: "Start")) }
        for await _ in entered { break }
        await session.send(.init(text: "Queued separately"))
        await session.steer(.init(text: "Change direction"))
        release.yield(())
        await sending.value

        let requests = await connector.requests
        #expect(requests.count == 3)
        #expect(requests[1].instruction.contains("The user added while you worked:\n"))
        #expect(requests[1].instruction.contains("Change direction"))
        #expect(!requests[1].instruction.contains("Queued separately"))
        #expect(session.project.agentThread?.turns.map(\.request.text) == ["Start", "Queued separately"])
    }

    @Test func discardsTheInFlightReplyOnStop() async throws {
        let (entered, started) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let forbidden: JSONValue = .object(["tool": .string("export"), "args": .object([:])])
        let late = reply("Never display this", calls: [forbidden])
        let connector = ScriptedConnector(script: [{ _, model in
            started.yield(())
            for await _ in released { break }
            return .init(object: late, model: model, stop: .complete)
        }])
        let session = try session(connector)
        let sending = Task { await session.send(.init(text: "Start")) }
        for await _ in entered { break }
        session.stop()
        release.yield(())
        await sending.value

        #expect(session.status == .stopped)
        #expect(session.project.agentThread?.turns.last?.steps.isEmpty == true)
        #expect(session.project.agentThread?.turns.last?.summary.isEmpty == true)
    }

    @Test func correctsAnInvalidReplyThenChecksAnUnsupportedClaimOnce() async throws {
        let claim = reply("Added music.")
        let connector = ScriptedConnector(replies: [.null, claim, claim])
        let session = try session(connector, budget: 1)

        await session.send(.init(text: "Find a soundtrack"))

        let requests = await connector.requests
        #expect(requests.count == 3)
        #expect(requests[1].instruction.contains("did not match agent_step"))
        #expect(requests[2].instruction.contains("no music change was made"))
        #expect(session.project.agentThread?.turns.last?.check?.lines == ["Claude said it added music, but nothing changed there."])
    }
}
