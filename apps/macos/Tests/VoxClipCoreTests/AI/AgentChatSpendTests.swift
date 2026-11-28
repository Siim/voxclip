import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) @MainActor struct AgentChatSpendTests {
    private struct Replay: Decodable {
        let project: String
        let request: String
        let replies: [JSONValue]
        let accepted: [Bool]
        let offered: [AgentTurn.Offer.Kind]
    }

    @Test func everySpendAttemptOffersOrRefusesWithoutTouchingTheLedger() async throws {
        let replay = try FixtureLoader.decode(Replay.self, at: "fixtures/agent-chat/replays/spend-attempts.json")
        let project = try ProjectJSON.decode(FixtureLoader.data(replay.project))
        let shared = try SharedResources.locate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = VoiceLabSpendLedger(url: directory.appendingPathComponent("spend.json"))
        let at = Date(timeIntervalSince1970: 1_795_790_000)
        let before = await ledger.read()
        let monthly = await ledger.total(provider: "elevenlabs", at: at)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RejectAgentNetwork.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        var purchaseCount = 0
        let session = try AgentChatSession(project: project, shared: shared, connector: ScriptedConnector(replies: replay.replies),
                                           model: "fixture", feature: .test, context: .init(capLeft: 2))
        let purchases = AgentOffers(project: { session.project }, update: session.updateProject, shared: shared, capLeft: { 2 },
                                    purchase: { _, _ in
            purchaseCount += 1
            _ = try await network.data(from: URL(string: "https://example.invalid/")!)
            return .bought(assetID: "unreachable")
        })

        await session.send(.init(text: replay.request))

        let turn = try #require(session.project.agentThread?.turns.last)
        #expect(turn.steps.map(\.ok) == replay.accepted)
        #expect(turn.offers.map(\.kind) == replay.offered)
        #expect(turn.offers.allSatisfy { $0.state == .offered })
        #expect(purchaseCount == 0)
        #expect(await ledger.read() == before)
        #expect(await ledger.total(provider: "elevenlabs", at: at) == monthly)
        #expect(withExtendedLifetime(purchases) { !FileManager.default.fileExists(atPath: directory.path) })
    }

    @Test func routesOnlyAnExplicitAffordableClickAndUsesItsReceiptOnce() async throws {
        let replay = try FixtureLoader.decode(Replay.self, at: "fixtures/agent-chat/replays/spend-attempts.json")
        let project = try ProjectJSON.decode(FixtureLoader.data(replay.project))
        let shared = try SharedResources.locate()
        let session = try AgentChatSession(project: project, shared: shared, connector: ScriptedConnector(replies: replay.replies),
                                           model: "fixture", feature: .test, context: .init(capLeft: 2))
        var count = 0
        var limit: Decimal = 0
        var opened: AgentTurn.Offer?
        let offers = AgentOffers(project: { session.project }, update: session.updateProject, shared: shared, capLeft: { limit },
                                 openRewrite: { opened = $0 }, purchase: { offer, approved in
            #expect(offer.kind == .generateMusic)
            #expect(approved == Decimal(string: "0.01"))
            count += 1
            return .bought(assetID: "persisted-track")
        })
        await session.send(.init(text: replay.request))
        let music = try #require(session.project.agentThread?.turns.last?.offers.first)
        #expect(await offers.buy(offerId: music.id) == .overCap(Decimal(string: "0.01")!))
        #expect(count == 0)
        limit = 2
        #expect(await offers.buy(offerId: music.id) == .bought("persisted-track"))
        #expect(await offers.buy(offerId: music.id) == .unavailable)
        #expect(count == 1)
        let turn = try #require(session.project.agentThread?.turns.last)
        #expect(turn.offers.first?.assetId == "persisted-track")
        #expect(turn.events.last?.kind == .bought)
        let revoice = try #require(turn.offers.first(where: { $0.kind == .revoice }))
        #expect(await offers.buy(offerId: revoice.id) == .openedRewrite)
        #expect(opened?.words == revoice.words)
        #expect(count == 1)
    }
}

private final class RejectAgentNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Issue.record("Agent attempted a network request")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}
