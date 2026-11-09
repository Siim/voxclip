import CryptoKit
import Foundation
import Testing
@testable import VoxClipCore

/// shared/fixtures/rewrite-thread/request-cases.json: "Talk back to Claude" (design.md §6.3, ai.md §12.12, ADR-R50). Each
/// request renders byte for byte as the independent generator renders it, and each stub reply checks as it expects.
@Suite(.offlineFixtures) struct RewriteFollowupReplayTests {
    private static func fixture() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/rewrite-thread/request-cases.json"))
    }
    private static func prompt() throws -> RewriteFollowupPrompt { try RewriteFollowupPrompt.load(shared: SharedResources.locate()) }
    private static func input(_ value: JSONValue) -> RewriteFollowupRequest {
        RewriteFollowupRequest(kind: value[ai: "kind"].aiString == "versions" ? .versions : .reply, scope: value[ai: "scope"].aiString ?? "",
                               language: value[ai: "language"].aiString ?? "", source: value[ai: "source"].aiString ?? "",
                               ordinal: value[ai: "ordinal"].aiInt ?? 0, recorded: value[ai: "recorded"].aiString ?? "",
                               versions: value[ai: "versions"].aiArray.compactMap(\.aiString), messages: value[ai: "messages"].aiArray.compactMap(\.aiString))
    }

    @Test("The fixture is current for the prompt file and holds exactly its keys and counts")
    func fixtureIsCurrent() throws {
        let fixture = try Self.fixture()
        let sha = SHA256.hash(data: try FixtureLoader.data("prompts/rewrite-followup.json")).map { String(format: "%02x", $0) }.joined()
        #expect(fixture[ai: "promptSha256"].aiString == sha)
        #expect(fixture[ai: "schema"].aiString == "voxclip-rewrite-thread-cases/1")
        guard case .object(let keys) = fixture else { Issue.record("not an object"); return }
        #expect(Set(keys.keys) == ["schema", "promptSha256", "requestCount", "replyCount", "requests", "replies"])
        #expect(fixture[ai: "requests"].aiArray.count == fixture[ai: "requestCount"].aiInt && fixture[ai: "requestCount"].aiInt == 5)
        #expect(fixture[ai: "replies"].aiArray.count == fixture[ai: "replyCount"].aiInt && fixture[ai: "replyCount"].aiInt == 6)
    }

    @Test("Each request carries the recorded words, every version and every message in order, as the generator renders it")
    func requestsReplay() throws {
        let prompt = try Self.prompt()
        for item in try Self.fixture()[ai: "requests"].aiArray {
            let id = item[ai: "id"].aiString ?? ""
            let input = Self.input(item[ai: "input"]), expected = item[ai: "expected"]
            let request = try prompt.request(input, timeout: .seconds(60))
            #expect(request.system == expected[ai: "system"].aiString, "\(id) system")
            #expect(request.cachedBlock == expected[ai: "cachedBlock"].aiString, "\(id) cached block")
            #expect(request.instruction == expected[ai: "instruction"].aiString, "\(id) instruction")
            #expect(request.schemaName == expected[ai: "schemaName"].aiString && request.tag == expected[ai: "tag"].aiString, "\(id) schema")
            #expect(request.maxOutputTokens == expected[ai: "maxOutputTokens"].aiInt && request.feature == .voiceRewrite && request.effort == .xhigh)
            // In order: the recorded words, then each version, then each message, the newest last.
            var cursor = request.instruction.startIndex
            for part in [input.recorded.isEmpty ? "" : input.recorded] + input.versions + input.messages where !part.isEmpty {
                guard let found = request.instruction.range(of: part, range: cursor..<request.instruction.endIndex) else {
                    Issue.record("\(id): \(part) is missing or out of order"); break
                }
                cursor = found.upperBound
            }
        }
    }

    @Test("Stub replies check as the fixture expects: the note cut to 20 words, at most two short next steps, refusals")
    func repliesReplay() throws {
        let prompt = try Self.prompt()
        for item in try Self.fixture()[ai: "replies"].aiArray {
            let id = item[ai: "id"].aiString ?? ""
            let input = Self.input(item[ai: "input"]), expect = item[ai: "expect"]
            if expect[ai: "error"].aiString == "invalidOutput" {
                #expect(throws: LLMError.self, "\(id)") { try prompt.reply(item[ai: "reply"], for: input) }
                continue
            }
            let reply = try prompt.reply(item[ai: "reply"], for: input)
            #expect(reply.texts == expect[ai: "texts"].aiArray.compactMap(\.aiString), "\(id) texts")
            #expect(reply.note == expect[ai: "note"].aiString, "\(id) note")
            #expect(reply.nextSteps == expect[ai: "nextSteps"].aiArray.compactMap(\.aiString), "\(id) next steps")
        }
    }

    @Test("A request with no message or no version is refused before anything is sent")
    func emptyRequestsAreRefused() throws {
        let prompt = try Self.prompt()
        let good = RewriteFollowupRequest(scope: "passage", language: "en", source: "a b c", ordinal: 1, recorded: "a", versions: ["b"], messages: ["c"])
        _ = try prompt.request(good, timeout: .seconds(1))
        var none = good; none.messages = []
        var blank = good; blank.messages = ["  "]
        var noVersion = good; noVersion.versions = []
        for input in [none, blank, noVersion] { #expect(throws: VoiceLabError.self) { try prompt.request(input, timeout: .seconds(1)) } }
    }

    @Test("The service sends one request through the runner and returns the checked reply")
    func serviceWithStubConnector() async throws {
        let shared = try SharedResources.locate(), catalog = try LLMCatalog(shared: shared)
        let reply = #"{"text":"My travel pass got its first buyer. I was so happy. Then I found out it was a scammer.","note":"The joy is about the sale now.","nextSteps":["More suspense before the scammer"]}"#
        let connector = FollowupConnector(reply: reply)
        let service = RewriteFollowupService(runner: LLMRunner(keys: FollowupKeys(), catalog: catalog, log: FollowupLog()), prompt: try Self.prompt(), catalog: catalog)
        let input = RewriteFollowupRequest(scope: "passage", language: "en", source: "Somebody purchased my product. I was quite happy.", ordinal: 1,
                                           recorded: "Somebody purchased my product. I was quite happy.",
                                           versions: ["My travel pass got its first buyer. A scammer. I was so happy."],
                                           messages: ["It reads like I was happy about the scammer. I was happy about the sale."])
        let result = try await service.send(input, connector: connector, model: "m")
        #expect(result.texts == ["My travel pass got its first buyer. I was so happy. Then I found out it was a scammer."])
        #expect(result.note == "The joy is about the sale now." && result.nextSteps == ["More suspense before the scammer"])
        let sent = await connector.sent
        #expect(sent.count == 1 && sent.first?.tag == "rewrite-followup" && sent.first?.instruction.contains(input.messages[0]) == true)
    }
}

private struct FollowupKeys: KeyProvider { func key(for provider: String) async throws -> String? { nil } }
private actor FollowupLog: Redacting {
    func register(secret: String) {}
    func redact(_ message: String) -> String { message }
    func write(_ entry: LogEntry) {}
}
private actor FollowupConnector: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    var sent: [LLMRequest] = []
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { 200_000 }
    func send(_ request: LLMRequest, model: String) throws -> RawCompletion {
        sent.append(request)
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}
