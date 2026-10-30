#if DEBUG
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore

private final class RewriteQuoteClock: Sendable {
    let time = Mutex<Duration>(.zero)
    func now() -> Duration { time.withLock { $0 } }
    func advance(_ seconds: Double) { time.withLock { $0 += .seconds(seconds) } }
}

struct VoiceLabQuoteExpiryTests {
    @Test(arguments: [299.0, 300.0, 301.0])
    func rewriteExpiryDoesNotSendOrAutomaticallyRetry(seconds: Double) async throws {
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let clock = RewriteQuoteClock(); await service.useClock { clock.now() }
        let request = VoiceRewriteBudgetFixtures.rewrite(4, 10, 12)
        let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
        let connector = CapturingRewriteConnector(output: #"{"rewrite":"Hello"}"#)
        clock.advance(seconds)
        if seconds < 300 {
            let proposal = try await service.propose(request, connector: connector, model: "selected-model", authorization: .init(quote: quote, approved: true))
            #expect(!proposal.inRange)
            #expect(await connector.requests.count == 1)
        } else {
            await #expect(throws: VoiceLabError.consentRequired) {
                try await service.propose(request, connector: connector, model: "selected-model", authorization: .init(quote: quote, approved: true))
            }
            #expect(await connector.requests.isEmpty)
        }
    }
    @Test(arguments: [299.0, 300.0])
    func patchExpiryMatchesTheSameBoundary(seconds: Double) async throws {
        let service = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let clock = RewriteQuoteClock(); await service.useClock { clock.now() }
        let entries = [ClipWord(index: 0, text: "Hello", start: 0, end: 0.4)]
        let line = try #require(formatTranscript(entries).lines.first)
        let request = PatchRewriteRequest(id: UUID(), entries: entries,
            ranges: [.init(line: "[\(line.firstIndex)-\(line.lastIndex)]", minChars: 1, maxChars: 30)], instruction: "Improve", language: "en")
        let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
        let connector = CapturingRewriteConnector(output: #"{"edits":[]}"#)
        clock.advance(seconds)
        if seconds < 300 {
            _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: .init(quote: quote, approved: true))
            #expect(await connector.requests.count == 1)
        } else {
            await #expect(throws: VoiceLabError.consentRequired) {
                try await service.propose(request, connector: connector, model: "selected-model", authorization: .init(quote: quote, approved: true))
            }
            #expect(await connector.requests.isEmpty)
        }
    }
}
#endif
