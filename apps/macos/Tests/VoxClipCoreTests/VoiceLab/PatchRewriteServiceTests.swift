import Foundation
import Testing
@testable import VoxClipCore

/// Builds requests from `shared/fixtures/voice-lab/patch-rewrite-cases.json` and the LLM request goldens.
enum PatchRewriteFixtures {
    static func entries(_ value: JSONValue) throws -> [ClipWord] {
        try value.aiArray.map { entry in
            ClipWord(index: try #require(entry[ai: "index"].aiInt), text: try #require(entry[ai: "text"].aiString),
                     start: try #require(entry[ai: "start"].aiDouble), end: try #require(entry[ai: "end"].aiDouble))
        }
    }
    static func ranges(_ value: JSONValue) throws -> [PatchRewriteLineRange] {
        try value.aiArray.map { range in
            PatchRewriteLineRange(line: try #require(range[ai: "line"].aiString), minChars: try #require(range[ai: "minChars"].aiInt),
                                  maxChars: try #require(range[ai: "maxChars"].aiInt))
        }
    }
    static func document() throws -> JSONValue {
        let document = try FixtureLoader.decode(JSONValue.self, at: "fixtures/voice-lab/patch-rewrite-cases.json")
        #expect(document[ai: "version"].aiInt == 1)
        return document
    }
    /// A case may bring its own `entries` and `ranges`.
    static func request(_ document: JSONValue, instruction: String? = nil, entries: JSONValue = .null, ranges: JSONValue = .null) throws -> PatchRewriteRequest {
        PatchRewriteRequest(id: UUID(), entries: try self.entries(entries == .null ? document[ai: "entries"] : entries),
                            ranges: try self.ranges(ranges == .null ? document[ai: "ranges"] : ranges),
                            instruction: instruction ?? "I said 2024; it's 2025.", language: document[ai: "language"].aiString ?? "en")
    }
    static func stop(_ item: JSONValue) -> StopKind {
        switch item[ai: "stop"].aiString {
        case "refused": .refused(category: nil)
        case "truncated": .truncated
        default: .complete
        }
    }
    static func propose(_ request: PatchRewriteRequest, reply: String, stop: StopKind = .complete) async throws -> (PatchRewriteProposal, CapturingRewriteConnector) {
        let service = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = CapturingRewriteConnector(output: reply, stop: stop)
        let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
        let proposal = try await service.propose(request, connector: connector, model: "selected-model", authorization: PatchRewriteAuthorization(quote: quote, approved: true))
        return (proposal, connector)
    }
    /// The same reply through `VoiceRewriteService`, for a passage of the case's words: both services read a reply with one
    /// strict parse, so they agree on what is invalid output.
    static func rewrite(_ id: String, reply: String, stop: StopKind, expected: JSONValue, patch: PatchRewriteRequest) async throws {
        let words = patch.entries.map { TimedWord(id: "w\($0.index)", text: $0.text, start: $0.start, end: $0.end) }
        let request = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: words, instruction: patch.instruction,
                                          language: patch.language, targetSeconds: 4.0, minChars: 10, maxChars: 40)
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = CapturingRewriteConnector(output: reply, stop: stop)
        let authorization = VoiceRewriteAuthorization(quote: try await service.prepare(request, connector: .openai, model: "selected-model"), approved: true)
        if let error = expected[ai: "error"].aiString {
            do { _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: authorization); Issue.record("\(id): rewrite \(error)") }
            catch let failure as LLMError { #expect(failure.caseName == error, "\(id): rewrite \(error)") }
            return
        }
        let proposal = try await service.propose(request, connector: connector, model: "selected-model", authorization: authorization)
        #expect(Array(proposal.proposedText.unicodeScalars) == Array((expected[ai: "rewrite"].aiString ?? "").unicodeScalars), "\(id): rewrite kept as sent")
        #expect(proposal.proposedLength == expected[ai: "proposedLength"].aiInt, "\(id): rewrite length")
    }
}

/// `patch-rewrite-requests.json`: the case goes through `PatchRewriteService`, and the request it sends must match.
func patchRewriteGoldenRequest(_ item: JSONValue, label: String) async throws {
    let input = item[ai: "input"]
    let request = PatchRewriteRequest(id: UUID(), entries: try PatchRewriteFixtures.entries(input[ai: "entries"]),
                                      ranges: try PatchRewriteFixtures.ranges(input[ai: "ranges"]),
                                      instruction: try #require(input[ai: "instruction"].aiString), language: try #require(input[ai: "language"].aiString))
    let service = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
    let connector = CapturingRewriteConnector(output: #"{"edits":[]}"#)
    let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
    expectGoldenEstimate(quote.estimate, item[ai: "expected"][ai: "estimate"], operation: "patchRewrite", label: label)
    _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: PatchRewriteAuthorization(quote: quote, approved: true))
    let sent = try #require(await connector.requests.first)
    expectGoldenRequest(sent, item[ai: "expected"][ai: "request"], label: label)
    #expect(sent.tag == "patch-rewrite", "\(label): tag")
    try await expectGoldenPreflight(sent, item[ai: "expected"][ai: "preflight"], output: #"{"edits":[]}"#, label: label) { stub in
        let next = try await service.prepare(request, connector: .openai, model: "selected-model")
        _ = try await service.propose(request, connector: stub, model: "selected-model", authorization: PatchRewriteAuthorization(quote: next, approved: true))
    }
}

@Suite("Fix with AI patch rewrite")
struct PatchRewriteServiceTests {
    @Test func sharedBehaviourCases() async throws {
        let document = try PatchRewriteFixtures.document()
        let cases = document[ai: "cases"].aiArray
        #expect(cases.count == 82)
        for item in cases {
            let id = try #require(item[ai: "id"].aiString)
            let expected = item[ai: "expected"]
            let instruction: String = try #require(item[ai: "instruction"].aiString)
            let request = try PatchRewriteFixtures.request(document, instruction: instruction, entries: item[ai: "entries"], ranges: item[ai: "ranges"])
            let reply = try #require(item[ai: "reply"].aiString)
            if id.hasPrefix("json-keys-") {
                let valid = expected[ai: "error"] == .null
                #expect((CanonicalResponseParser.strictDecode(reply) != nil) == valid, "\(id): strict reply")
                #expect((CanonicalResponseParser.envelope(reply) != nil) == valid, "\(id): strict envelope")
            }
            let stop = PatchRewriteFixtures.stop(item)
            if item[ai: "rewriteExpected"] != .null {
                try await PatchRewriteFixtures.rewrite(id, reply: reply, stop: stop, expected: item[ai: "rewriteExpected"], patch: request)
            }
            if let error = expected[ai: "error"].aiString {
                do { _ = try await PatchRewriteFixtures.propose(request, reply: reply, stop: stop); Issue.record("\(id): expected \(error)") }
                catch let failure as LLMError { #expect(failure.caseName == error, "\(id): \(error)") }
                continue
            }
            let (proposal, connector) = try await PatchRewriteFixtures.propose(request, reply: reply, stop: stop)
            #expect(await connector.requests.count == 1, "\(id): one send")
            #expect(proposal.unknownLines == expected[ai: "unknownLines"].aiInt, "\(id): unknownLines")
            #expect(proposal.duplicateLines == expected[ai: "duplicateLines"].aiInt, "\(id): duplicateLines")
            #expect(proposal.malformedItems == expected[ai: "malformedItems"].aiInt, "\(id): malformedItems")
            #expect(proposal.checkThisMessage == document[ai: "copy"][ai: "checkThis"].aiString, "\(id): badge copy")
            let edits = expected[ai: "edits"].aiArray
            try #require(proposal.edits.count == edits.count, "\(id): edit count")
            for (edit, want) in zip(proposal.edits, edits) {
                #expect(edit.line == want[ai: "line"].aiString, "\(id): line")
                #expect(Array(edit.text.unicodeScalars) == Array((want[ai: "text"].aiString ?? "").unicodeScalars), "\(id): text kept as sent")
                #expect(edit.reason == want[ai: "reason"].aiString, "\(id): reason")
                #expect(edit.length == want[ai: "length"].aiInt, "\(id): length")
                #expect(edit.inRange == want[ai: "inRange"].aiBool, "\(id): inRange")
                #expect(edit.checkThis == want[ai: "checkThis"].aiBool, "\(id): checkThis")
                #expect(edit.isDeletion == want[ai: "isDeletion"].aiBool, "\(id): isDeletion")
            }
        }
    }

    @Test(arguments: VoiceRewriteBudgetFixtures.answers)
    func onlyTheQuotedModelMayAnswer(_ answer: (ConnectorID, String, String, Bool)) async throws {
        let service = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = CapturingRewriteConnector(output: #"{"edits":[]}"#, id: answer.0, answered: answer.2, models: [answer.1])
        let request = try PatchRewriteFixtures.request(try PatchRewriteFixtures.document())
        let quote = try await service.prepare(request, connector: answer.0, model: answer.1)
        do {
            let proposal = try await service.propose(request, connector: connector, model: answer.1, authorization: PatchRewriteAuthorization(quote: quote, approved: true))
            #expect(answer.3 && proposal.model == answer.2, "\(answer)")
        } catch LLMError.invalidOutput { #expect(!answer.3, "\(answer)") }
        #expect(await connector.requests.count == 1)
    }

    @Test(arguments: VoiceRewriteBudgetFixtures.stops)
    func stopIsATypedErrorAfterTheModelCheck(_ stop: (StopKind, String, LLMError, String)) async throws {
        let service = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = CapturingRewriteConnector(output: #"{"edits":[]}"#, answered: stop.1, stop: stop.0)
        let request = try PatchRewriteFixtures.request(try PatchRewriteFixtures.document())
        let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
        await #expect(throws: stop.2) {
            try await service.propose(request, connector: connector, model: "selected-model", authorization: PatchRewriteAuthorization(quote: quote, approved: true))
        }
    }

    @Test func quoteBindsThePromptFileButNotItsLineEndings() async throws {
        let root = try VoiceRewriteBudgetFixtures.sharedCopy("prompts/patch-rewrite.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("prompts/patch-rewrite.json")
        let original = try String(contentsOf: path, encoding: .utf8)
        #expect(original.hasPrefix("{") && !original.unicodeScalars.contains("\r"))
        let service = PatchRewriteService(shared: SharedResources(root: root))
        let connector = CapturingRewriteConnector(output: #"{"edits":[]}"#)
        let request = try PatchRewriteFixtures.request(try PatchRewriteFixtures.document())
        let authorization = PatchRewriteAuthorization(quote: try await service.prepare(request, connector: .openai, model: "selected-model"), approved: true)
        // One more space changes no rendered field, yet the quote is for other prompt bytes, so nothing is sent.
        try ("{ " + original.dropFirst()).write(to: path, atomically: true, encoding: .utf8)
        await #expect(throws: VoiceLabError.consentRequired) {
            try await service.propose(request, connector: connector, model: "selected-model", authorization: authorization)
        }
        #expect(await connector.requests.isEmpty)
        // CRLF line endings are the same prompt, so the unused quote still sends.
        try original.replacingOccurrences(of: "\n", with: "\r\n").write(to: path, atomically: true, encoding: .utf8)
        _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: authorization)
        #expect(await connector.requests.count == 1)
    }

    @Test func promptIsThePatchEditsSchemaWithTheBadgeCopy() throws {
        let prompt = try FixtureLoader.decode(JSONValue.self, at: "prompts/patch-rewrite.json")
        let line: JSONValue = .object(["type": .string("string")])
        let item: JSONValue = .object(["type": .string("object"), "additionalProperties": .bool(false),
                                       "required": .array([.string("line"), .string("text"), .string("reason")]),
                                       "properties": .object(["line": line, "text": line, "reason": line])])
        let schema: JSONValue = .object(["type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("edits")]),
                                         "properties": .object(["edits": .object(["type": .string("array"), "items": item])])])
        #expect(prompt[ai: "schemaVersion"].aiInt == 1 && prompt[ai: "promptVersion"].aiInt == 1)
        #expect(prompt[ai: "schemaName"].aiString == "patch_edits")
        #expect(prompt[ai: "schema"] == schema && CanonicalResponseParser.validateSchemaSubset(schema))
        #expect(prompt[ai: "messages"][ai: "checkThis"].aiString == (try PatchRewriteFixtures.document())[ai: "copy"][ai: "checkThis"].aiString)
        #expect(prompt[ai: "messages"][ai: "checkThis"].aiString == "Check this: it adds something you didn't say.")
    }

    @Test func requestBoundsAreInvalidInput() async throws {
        let document = try PatchRewriteFixtures.document()
        let base = try PatchRewriteFixtures.request(document)
        let entries = base.entries, ranges = base.ranges
        var swapped = ranges; swapped.swapAt(0, 1)
        var reindexed = entries; reindexed[1].index = reindexed[0].index
        var untimed = entries; untimed[2].end = -1
        let bad: [(String, PatchRewriteRequest)] = [
            ("no entries", PatchRewriteRequest(id: base.id, entries: [], ranges: [], instruction: base.instruction, language: "en")),
            ("missing range", PatchRewriteRequest(id: base.id, entries: entries, ranges: Array(ranges.dropLast()), instruction: base.instruction, language: "en")),
            ("extra range", PatchRewriteRequest(id: base.id, entries: entries, ranges: ranges + [PatchRewriteLineRange(line: "[90-91]", minChars: 1, maxChars: 2)], instruction: base.instruction, language: "en")),
            ("ranges out of order", PatchRewriteRequest(id: base.id, entries: entries, ranges: swapped, instruction: base.instruction, language: "en")),
            ("minChars 0", PatchRewriteRequest(id: base.id, entries: entries, ranges: [PatchRewriteLineRange(line: ranges[0].line, minChars: 0, maxChars: 5)] + ranges.dropFirst(), instruction: base.instruction, language: "en")),
            ("min above max", PatchRewriteRequest(id: base.id, entries: entries, ranges: [PatchRewriteLineRange(line: ranges[0].line, minChars: 6, maxChars: 5)] + ranges.dropFirst(), instruction: base.instruction, language: "en")),
            ("max above 5000", PatchRewriteRequest(id: base.id, entries: entries, ranges: [PatchRewriteLineRange(line: ranges[0].line, minChars: 1, maxChars: 5_001)] + ranges.dropFirst(), instruction: base.instruction, language: "en")),
            ("blank instruction", PatchRewriteRequest(id: base.id, entries: entries, ranges: ranges, instruction: " \n\t", language: "en")),
            ("long instruction", PatchRewriteRequest(id: base.id, entries: entries, ranges: ranges, instruction: String(repeating: "x", count: 1_001), language: "en")),
            ("language", PatchRewriteRequest(id: base.id, entries: entries, ranges: ranges, instruction: base.instruction, language: "en\n")),
            ("repeated index", PatchRewriteRequest(id: base.id, entries: reindexed, ranges: ranges, instruction: base.instruction, language: "en")),
            ("bad timing", PatchRewriteRequest(id: base.id, entries: untimed, ranges: ranges, instruction: base.instruction, language: "en")),
        ]
        let service = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = CapturingRewriteConnector(output: #"{"edits":[]}"#)
        let authorization = PatchRewriteAuthorization(quote: try await service.prepare(base, connector: .openai, model: "selected-model"), approved: true)
        for (label, request) in bad {
            do { _ = try await service.prepare(request, connector: .openai, model: "selected-model"); Issue.record("Expected invalidInput: \(label)") }
            catch VoiceLabError.invalidInput {}
            do { _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: authorization); Issue.record("Expected invalidInput from propose: \(label)") }
            catch VoiceLabError.invalidInput {}
        }
        #expect(await connector.requests.isEmpty)
    }

    @Test(arguments: ["entryText", "entryTiming", "range", "instruction", "language", "connector", "model", "same"])
    func quoteBindsTheWholeRequest(_ field: String) async throws {
        let document = try PatchRewriteFixtures.document()
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let service = PatchRewriteService(shared: shared)
        let base = try PatchRewriteFixtures.request(document)
        let quote = try await service.prepare(base, connector: field == "connector" ? .anthropic : .openai, model: "selected-model")
        var entries = base.entries, ranges = base.ranges
        if field == "entryText" { entries[0].text = "Then" }
        if field == "entryTiming" { entries[0].end += 0.01 }
        if field == "range" { ranges[1] = PatchRewriteLineRange(line: ranges[1].line, minChars: ranges[1].minChars, maxChars: ranges[1].maxChars + 1) }
        let changed = PatchRewriteRequest(id: base.id, entries: entries, ranges: ranges, instruction: field == "instruction" ? "I said 2023." : base.instruction,
                                          language: field == "language" ? "et" : base.language)
        let connector = CapturingRewriteConnector(output: #"{"edits":[]}"#)
        let authorization = PatchRewriteAuthorization(quote: quote, approved: true)
        do {
            _ = try await service.propose(changed, connector: connector, model: field == "model" ? "other-model" : "selected-model", authorization: authorization)
            #expect(field == "same")
        } catch VoiceLabError.consentRequired { #expect(field != "same") }
        #expect(await connector.requests.count == (field == "same" ? 1 : 0))
        // A refused check sends nothing and leaves the quote usable; a send consumes it.
        let replayAllowed = field != "same" && field != "connector"
        do { _ = try await service.propose(base, connector: connector, model: "selected-model", authorization: authorization); #expect(replayAllowed, "\(field): replay") }
        catch VoiceLabError.consentRequired { #expect(!replayAllowed, "\(field): replay") }
        #expect(await connector.requests.count == (field == "connector" ? 0 : 1))
    }

    @Test func declinedApprovalAndReplaySendNothing() async throws {
        let document = try PatchRewriteFixtures.document()
        let service = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let request = try PatchRewriteFixtures.request(document)
        let connector = CapturingRewriteConnector(output: #"{"edits":[]}"#)
        let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
        do { _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: PatchRewriteAuthorization(quote: quote, approved: false)); Issue.record("Expected consentRequired") }
        catch VoiceLabError.consentRequired {}
        #expect(await connector.requests.isEmpty)
        let proposal = try await service.propose(request, connector: connector, model: "selected-model", authorization: PatchRewriteAuthorization(quote: quote, approved: true))
        #expect(proposal.edits.isEmpty)
        let sent = try #require(await connector.requests.first)
        #expect(sent.feature == .voiceRewrite && sent.schemaName == "patch_edits" && sent.tag == "patch-rewrite")
        do { _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: PatchRewriteAuthorization(quote: quote, approved: true)); Issue.record("Expected replay refusal") }
        catch VoiceLabError.consentRequired {}
        #expect(await connector.requests.count == 1)
    }

    @Test func rangeTemplateWithoutItsPlaceholdersIsAMissingResource() throws {
        guard case .object(var root) = try FixtureLoader.decode(JSONValue.self, at: "prompts/patch-rewrite.json"),
              case .object(var templates) = root["request"] else { Issue.record("patch-rewrite.json has no request templates"); return }
        templates["rangeLine"] = .string("{line} is fine.")
        root["request"] = .object(templates)
        let request = try PatchRewriteFixtures.request(try PatchRewriteFixtures.document())
        let transcript = try formatTranscript(request.entries)
        #expect(throws: VoxClipError.sharedResourcesMissing) {
            _ = try PatchRewriteService.requestText(request, transcript: transcript, prompt: .object(root))
        }
    }
}
