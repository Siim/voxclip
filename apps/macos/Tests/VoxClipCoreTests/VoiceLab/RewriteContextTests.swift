import Foundation
import Testing
@testable import VoxClipCore

struct RewriteContextTests {
    @Test func sharedContextResolution() async throws {
        let rows = try #require(VoiceRewriteBudgetFixtures.document("rewrite-checks-cases.json")["contextResolution"] as? [[String: Any]])
        let catalog = try LLMCatalog(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        #expect(rows.count == 7)
        for row in rows {
            let connectorID = try #require((row["connector"] as? String).flatMap(ConnectorID.init(rawValue:)))
            let model = try #require(row["model"] as? String)
            let connector = CapturingRewriteConnector(output: #"{"rewrite":"Fine."}"#, id: connectorID, models: [model], context: row["connectorContext"] as? Int)
            let models = [LLMModel(id: model, name: model, contextTokens: row["modelContext"] as? Int, source: .custom)]
            let context = try await catalog.resolvedContextTokens(connector: connector, model: model, models: models)
            #expect(context == row["context"] as? Int, "\(row["id"] ?? "?")")
            guard let count = row["sourceWordCount"] as? Int else { continue }
            let source = (0..<count).map { (index: Int) -> TimedWord in
                let start: Double = Double(index) / 10
                return TimedWord(id: "w\(index)", text: "word", start: start, end: start + 0.05)
            }
            let rewrite = VoiceRewriteRequest(id: UUID(), scope: .fullTake, sourceWords: source, instruction: "Improve", language: "en",
                                              targetSeconds: 150, minChars: 1, maxChars: 5000)
            let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
            do {
                let quote = try await service.prepare(rewrite, connector: connectorID, model: model)
                _ = try await service.propose(rewrite, connector: connector, model: model, authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
                #expect(row["fits"] as? Bool == true)
            } catch LLMError.contextTooLong {
                #expect(row["fits"] as? Bool == false)
            }
            let entries = source.enumerated().map { index, word in
                ClipWord(index: index, text: word.text, start: word.start, end: word.end)
            }
            let lines = try formatTranscript(entries).lines
            let ranges = lines.map { PatchRewriteLineRange(line: "[\($0.firstIndex)-\($0.lastIndex)]", minChars: 1, maxChars: 5000) }
            let patch = PatchRewriteRequest(id: UUID(), entries: entries, ranges: ranges, instruction: "Improve", language: "en")
            let patches = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
            let patchConnector = CapturingRewriteConnector(output: #"{"edits":[]}"#, id: connectorID, models: [model], context: nil)
            do {
                let quote = try await patches.prepare(patch, connector: connectorID, model: model)
                _ = try await patches.propose(patch, connector: patchConnector, model: model, authorization: PatchRewriteAuthorization(quote: quote, approved: true))
                #expect(row["fits"] as? Bool == true)
            } catch LLMError.contextTooLong {
                #expect(row["fits"] as? Bool == false)
            }
        }
    }
}
