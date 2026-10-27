import Foundation
import Testing
@testable import VoxClipCore

/// Reads one of the generated Voice Lab fixtures that `shared/fixtures/voice-lab/rewrite-README.md` describes.
enum VoiceRewriteBudgetFixtures {
    static func document(_ name: String) throws -> [String: Any] {
        let document = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/\(name)")) as? [String: Any])
        #expect(document["version"] as? Int == 1)
        return document
    }
    /// Builds text from scalar values, so a decomposed form stays explicit in the source.
    static func scalars(_ values: UInt32...) -> String {
        var text = ""
        text.unicodeScalars.append(contentsOf: values.compactMap(Unicode.Scalar.init))
        return text
    }
    static func rewrite(_ targetSeconds: Double = 4.1, _ minChars: Int = 10, _ maxChars: Int = 12) -> VoiceRewriteRequest {
        VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: [TimedWord(id: "w1", text: "Hi", start: 0, end: 0.3)],
                            instruction: "Improve", language: "en", targetSeconds: targetSeconds, minChars: minChars, maxChars: maxChars)
    }
    /// `rewrite-checks-cases.json`, read without test expectations so it can supply test arguments; `sharedRewriteChecks`
    /// fails when it is missing.
    static func checks() -> [String: Any] {
        guard let data = try? FixtureLoader.data("fixtures/voice-lab/rewrite-checks-cases.json"),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return document
    }
    /// ai.md §12.8: the shared answering-model rows, which every service replays.
    static let answers: [(ConnectorID, String, String, Bool)] = (checks()["answeredBy"] as? [[String: Any]] ?? []).compactMap { row in
        guard let connector = (row["connector"] as? String).flatMap(ConnectorID.init(rawValue:)), let selected = row["selected"] as? String,
              let answered = row["answered"] as? String, let accepted = row["accepted"] as? Bool else { return nil }
        return (connector, selected, answered, accepted)
    }
    /// A refusal, then truncation, after the model check, with the shared "declined to rewrite" copy (ai.md §12.8).
    static let stops: [(StopKind, String, LLMError, String)] = [
        (.refused(category: "cyber"), "selected-model", .refused(category: "cyber"), "The model declined to rewrite this recording."),
        (.truncated, "selected-model", .truncated, "The rewrite was incomplete. Please try again."),
        (.refused(category: nil), "other-model", .invalidOutput(reason: "The selected model changed."),
         "The model's answer wasn't in the expected format. Try again or pick another model."),
    ]
    /// Copies the catalogue and one prompt into a new shared root, so a test may change the prompt file.
    static func sharedCopy(_ prompt: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-prompt-binding-" + UUID().uuidString, isDirectory: true)
        for relative in ["catalog/llm-providers.json", prompt] {
            let target = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try FixtureLoader.sharedRoot().appendingPathComponent(relative), to: target)
        }
        return root
    }
}

/// Records every request and answers each with one canned reply; it never contacts a provider. The reply names `answered`
/// as its model when given, else the requested one, and ends with `stop`.
actor CapturingRewriteConnector: LLMConnector {
    nonisolated let id: ConnectorID
    let output: String
    let answered: String?
    let stop: StopKind
    let choices: [String]
    let context: Int?
    private(set) var requests: [LLMRequest] = []
    init(output: String, id: ConnectorID = .openai, answered: String? = nil, stop: StopKind = .complete, models: [String] = ["selected-model"],
         context: Int? = 64_000) {
        self.output = output; self.id = id; self.answered = answered; self.stop = stop; self.choices = models; self.context = context
    }
    func status() async -> ConnectorStatus { .ready }
    func models(refresh: Bool) async throws -> [LLMModel] { choices.map { LLMModel(id: $0, name: $0, contextTokens: context, source: .custom) } }
    func contextTokens(model: String) async -> Int? { context }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        requests.append(request)
        return RawCompletion(text: output, model: answered ?? model, stop: stop)
    }
}

/// Prompt strings are compared as UTF-8 bytes, because Swift `==` treats canonically equivalent strings as equal.
func expectGoldenRequest(_ sent: LLMRequest, _ expected: JSONValue, label: String) {
    #expect(sent.feature.rawValue == expected[ai: "feature"].aiString, "\(label): feature")
    #expect(Array(sent.system.utf8) == Array((expected[ai: "system"].aiString ?? "").utf8), "\(label): system")
    #expect(Array((sent.cachedBlock ?? "").utf8) == Array((expected[ai: "cachedBlock"].aiString ?? "").utf8), "\(label): cachedBlock")
    #expect(Array(sent.instruction.utf8) == Array((expected[ai: "instruction"].aiString ?? "").utf8), "\(label): instruction")
    #expect(sent.schemaName == expected[ai: "schemaName"].aiString, "\(label): schemaName")
    #expect(sent.schema == expected[ai: "schema"], "\(label): schema")
    #expect(sent.effort?.rawValue == expected[ai: "effort"].aiString, "\(label): effort")
    #expect(sent.language == expected[ai: "language"].aiString, "\(label): language")
}

/// voice-lab §8.9.1: the quote is `est()` of the whole rendered request, in tokens, at no known price.
func expectGoldenEstimate(_ estimate: CostEstimate, _ expected: JSONValue, operation: String, label: String) {
    #expect(estimate == CostEstimate(provider: "openai", operation: operation, units: expected[ai: "units"].aiDouble ?? -1,
                                     unit: expected[ai: "unit"].aiString ?? "", basis: expected[ai: "basis"].aiString ?? ""), "\(label): estimate")
}

/// ai.md §12.8: the case's send has the stated output cap, fits the smallest context the generator found, and a context one
/// token smaller refuses it before any send.
func expectGoldenPreflight(_ sent: LLMRequest, _ preflight: JSONValue, output: String, label: String,
                           propose: (CapturingRewriteConnector) async throws -> Void) async throws {
    #expect(sent.maxOutputTokens == preflight[ai: "maxOutputTokens"].aiInt, "\(label): maxOutputTokens")
    let smallest = try #require(preflight[ai: "smallestContext"].aiInt)
    let fits = CapturingRewriteConnector(output: output, context: smallest)
    try await propose(fits)
    #expect(await fits.requests.count == 1, "\(label): the smallest context fits")
    let refuses = CapturingRewriteConnector(output: output, context: smallest - 1)
    do {
        try await propose(refuses)
        Issue.record("\(label): a context one token smaller must refuse the send")
    } catch LLMError.contextTooLong {}
    #expect(await refuses.requests.isEmpty, "\(label): nothing sent")
}

/// `voice-rewrite-requests.json`: the case goes through `VoiceRewriteService`, and the request it sends must match.
func voiceRewriteGoldenRequest(_ item: JSONValue, label: String) async throws {
    let input = item[ai: "input"]
    let words = try input[ai: "sourceWords"].aiArray.map { word in
        TimedWord(id: try #require(word[ai: "id"].aiString), text: try #require(word[ai: "text"].aiString),
                  start: try #require(word[ai: "start"].aiDouble), end: try #require(word[ai: "end"].aiDouble))
    }
    let request = VoiceRewriteRequest(id: UUID(), scope: try #require(VoiceRewriteScope(rawValue: input[ai: "scope"].aiString ?? "")),
                                      sourceWords: words, instruction: try #require(input[ai: "instruction"].aiString),
                                      language: try #require(input[ai: "language"].aiString),
                                      targetSeconds: try #require(input[ai: "targetSeconds"].aiDouble),
                                      minChars: try #require(input[ai: "minChars"].aiInt), maxChars: try #require(input[ai: "maxChars"].aiInt))
    let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
    let connector = CapturingRewriteConnector(output: #"{"rewrite":"Fine."}"#)
    let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
    expectGoldenEstimate(quote.estimate, item[ai: "expected"][ai: "estimate"], operation: "voiceRewrite", label: label)
    _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
    let sent = try #require(await connector.requests.first)
    expectGoldenRequest(sent, item[ai: "expected"][ai: "request"], label: label)
    try await expectGoldenPreflight(sent, item[ai: "expected"][ai: "preflight"], output: #"{"rewrite":"Fine."}"#, label: label) { stub in
        let next = try await service.prepare(request, connector: .openai, model: "selected-model")
        _ = try await service.propose(request, connector: stub, model: "selected-model", authorization: VoiceRewriteAuthorization(quote: next, approved: true))
    }
}

@Suite("Voice rewrite length budget")
struct VoiceRewriteBudgetTests {
    @Test func sharedTextLengthCases() throws {
        let cases = try #require(VoiceRewriteBudgetFixtures.document("text-length-cases.json")["cases"] as? [[String: Any]])
        #expect(cases.count == 39)
        for item in cases {
            let id = try #require(item["id"] as? String)
            let text = try #require(item["text"] as? String)
            #expect(text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ") == item["scalars"] as? String, "\(id): decoded scalars")
            #expect(VoiceLabTextLength.length(text) == item["length"] as? Int, "\(id)")
        }
    }

    /// `rewrite-checks-cases.json` (ai.md §12.8): the answering model, the model id, the output cap and the context fit, each
    /// just below, at and just above its bound. Model ids also go through both services' prepare.
    @Test func sharedRewriteChecks() async throws {
        let document = try VoiceRewriteBudgetFixtures.document("rewrite-checks-cases.json")
        let policy = AITokenPolicy(try LLMCatalog(shared: SharedResources(root: try FixtureLoader.sharedRoot())).document[ai: "policy"])
        #expect(document["contextSafetyFactor"] as? Double == policy.safetyFactor)
        let answers = try #require(document["answeredBy"] as? [[String: Any]])
        #expect(answers.count == 37 && VoiceRewriteBudgetFixtures.answers.count == 37)
        for (connector, selected, answered, accepted) in VoiceRewriteBudgetFixtures.answers {
            #expect(VoiceLabLLMChecks.answeredBy(connector, selected: selected, answered: answered) == accepted, "\(connector) \(selected) \(answered)")
        }
        let models = try #require(document["modelIds"] as? [[String: Any]])
        #expect(models.count == 16)
        let rewrites = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let patches = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let patch = try PatchRewriteFixtures.request(try PatchRewriteFixtures.document())
        for row in models {
            let id = try #require(row["id"] as? String), model = try #require(row["model"] as? String), valid = try #require(row["valid"] as? Bool)
            #expect(VoiceLabLLMChecks.isValidModel(model) == valid, "\(id)")
            do {
                _ = try await rewrites.prepare(VoiceRewriteBudgetFixtures.rewrite(), connector: .openai, model: model)
                #expect(valid, "\(id): the rewrite quote is prepared")
            } catch VoiceLabError.invalidInput { #expect(!valid, "\(id): the rewrite quote is refused") }
            do {
                _ = try await patches.prepare(patch, connector: .openai, model: model)
                #expect(valid, "\(id): the Fix with AI quote is prepared")
            } catch VoiceLabError.invalidInput { #expect(!valid, "\(id): the Fix with AI quote is refused") }
        }
        let caps = try #require(document["outputCaps"] as? [[String: Any]])
        #expect(caps.count == 12)
        for row in caps {
            let id = try #require(row["id"] as? String)
            #expect(VoiceLabLLMChecks.maxOutputTokens(sourceTokens: try #require(row["sourceTokens"] as? Int), promptCap: try #require(row["promptCap"] as? Int),
                                                      connectorCap: row["connectorCap"] as? Int) == row["maxOutputTokens"] as? Int, "\(id)")
        }
        let contexts = try #require(document["contexts"] as? [[String: Any]])
        #expect(contexts.count == 12)
        for row in contexts {
            let id = try #require(row["id"] as? String)
            #expect(VoiceLabLLMChecks.contextFits(context: try #require(row["context"] as? Int), required: try #require(row["required"] as? Int),
                                                  safetyFactor: policy.safetyFactor) == row["fits"] as? Bool, "\(id)")
        }
    }

    /// ai.md §12.8: the output cap is checked when the quote is prepared. Apple caps output at 1,500 tokens, and this
    /// 3,999-byte source is ⌈3,999 / 2.2⌉ = 1,818 tokens.
    @Test func outputCapIsCheckedWhenTheQuoteIsPrepared() async throws {
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let words = (0..<400).map { TimedWord(id: "w\($0)", text: "abcdefghi", start: Double($0), end: Double($0) + 0.5) }
        let request = VoiceRewriteRequest(id: UUID(), scope: .fullTake, sourceWords: words, instruction: "", language: "en",
                                          targetSeconds: 120, minChars: 1, maxChars: 5_000)
        await #expect(throws: LLMError.contextTooLong) { _ = try await service.prepare(request, connector: .appleFoundation, model: "system") }
        _ = try await service.prepare(request, connector: .openai, model: "selected-model")
    }

    /// voice-lab §3.1: an LLM send's quote has basis `unknown` and no price, so it reaches the no-price confirmation.
    @Test func quoteWithoutAPriceAsksForConfirmation() async throws {
        let rewrite = try await VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
            .prepare(VoiceRewriteBudgetFixtures.rewrite(), connector: .openai, model: "selected-model").estimate
        let patch = try await PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
            .prepare(try PatchRewriteFixtures.request(try PatchRewriteFixtures.document()), connector: .openai, model: "selected-model").estimate
        for (estimate, operation) in [(rewrite, "voiceRewrite"), (patch, "patchRewrite")] {
            #expect(estimate.operation == operation && estimate.unit == "token" && estimate.basis == "unknown")
            #expect(estimate.usd == nil && estimate.credits == nil)
            #expect(VoiceLabCostPresentation.kind(estimate, isLipSync: false, providerName: "OpenAI") ==
                    .confirm("VoxClip can't tell what this costs. Check OpenAI's pricing."))
        }
    }

    @Test(arguments: [(0.0, 10, 12), (-1.0, 10, 12), (Double.nan, 10, 12), (Double.infinity, 10, 12), ((600.0).nextUp, 10, 12),
                      (4.1, 0, 12), (4.1, 13, 12), (4.1, 10, 5_001)])
    func budgetOutsideItsBoundsIsInvalidInput(_ budget: (Double, Int, Int)) async throws {
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let request = VoiceRewriteBudgetFixtures.rewrite(budget.0, budget.1, budget.2)
        do { _ = try await service.prepare(request, connector: .openai, model: "selected-model"); Issue.record("Expected invalidInput for \(budget)") }
        catch VoiceLabError.invalidInput {}
        let connector = CapturingRewriteConnector(output: #"{"rewrite":"Hello"}"#)
        let valid = try await service.prepare(VoiceRewriteBudgetFixtures.rewrite(), connector: .openai, model: "selected-model")
        do {
            _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: VoiceRewriteAuthorization(quote: valid, approved: true))
            Issue.record("Expected invalidInput for \(budget)")
        } catch VoiceLabError.invalidInput {}
        #expect(await connector.requests.isEmpty)
    }

    @Test func budgetBoundsAreInclusive() async throws {
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        for budget in [(600.0, 5_000, 5_000), (Double.leastNonzeroMagnitude, 1, 1), (0.05, 1, 5_000)] {
            _ = try await service.prepare(VoiceRewriteBudgetFixtures.rewrite(budget.0, budget.1, budget.2), connector: .openai, model: "selected-model")
        }
    }

    @Test(arguments: [(17, 17, true), (18, 30, false), (1, 16, false)])
    func proposalCarriesCoresOwnLengthInsideOrOutsideTheRange(_ range: (Int, Int, Bool)) async throws {
        // 4 + 3 + 6 + 4 letters and digits; the second word has a precomposed O-tilde and the third a decomposed o-tilde.
        let text = "Tere, " + VoiceRewriteBudgetFixtures.scalars(0xD5) + "ie! To" + VoiceRewriteBudgetFixtures.scalars(0x303) + "esti 2025."
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = CapturingRewriteConnector(output: #"{"rewrite":""# + text + #""}"#)
        let request = VoiceRewriteBudgetFixtures.rewrite(2.5, range.0, range.1)
        let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
        let proposal = try await service.propose(request, connector: connector, model: "selected-model", authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
        #expect(Array(proposal.proposedText.unicodeScalars) == Array(text.unicodeScalars))
        #expect(proposal.proposedLength == 17 && proposal.inRange == range.2)
        let sent = try #require(await connector.requests.first)
        #expect(sent.instruction.hasSuffix("about 2.5 seconds to say, which is \(range.0) to \(range.1) letters and digits. Spaces and punctuation are not counted. Write natural wording that stays inside this range."))
    }

    @Test(arguments: VoiceRewriteBudgetFixtures.answers)
    func onlyTheQuotedModelMayAnswer(_ answer: (ConnectorID, String, String, Bool)) async throws {
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = CapturingRewriteConnector(output: #"{"rewrite":"Hello there"}"#, id: answer.0, answered: answer.2, models: [answer.1])
        let request = VoiceRewriteBudgetFixtures.rewrite()
        let quote = try await service.prepare(request, connector: answer.0, model: answer.1)
        do {
            let proposal = try await service.propose(request, connector: connector, model: answer.1, authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
            #expect(answer.3 && proposal.model == answer.2, "\(answer)")
        } catch LLMError.invalidOutput { #expect(!answer.3, "\(answer)") }
        #expect(await connector.requests.count == 1)
    }

    @Test(arguments: VoiceRewriteBudgetFixtures.stops)
    func stopIsATypedErrorAfterTheModelCheck(_ stop: (StopKind, String, LLMError, String)) async throws {
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = CapturingRewriteConnector(output: #"{"rewrite":"Hello there"}"#, answered: stop.1, stop: stop.0)
        let request = VoiceRewriteBudgetFixtures.rewrite()
        let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
        await #expect(throws: stop.2) {
            try await service.propose(request, connector: connector, model: "selected-model", authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
        }
        #expect(stop.2.userMessage(label: "OpenAI", feature: .voiceRewrite, includeEditsSaved: false) == stop.3)
    }

    @Test func quoteBindsThePromptFileButNotItsLineEndings() async throws {
        let root = try VoiceRewriteBudgetFixtures.sharedCopy("prompts/voice-rewrite.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("prompts/voice-rewrite.json")
        let original = try String(contentsOf: path, encoding: .utf8)
        #expect(original.hasPrefix("{") && !original.unicodeScalars.contains("\r"))
        let service = VoiceRewriteService(shared: SharedResources(root: root))
        let connector = CapturingRewriteConnector(output: #"{"rewrite":"Hello there"}"#)
        let request = VoiceRewriteBudgetFixtures.rewrite()
        let authorization = VoiceRewriteAuthorization(quote: try await service.prepare(request, connector: .openai, model: "selected-model"), approved: true)
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

    @Test func lengthTemplateWithoutItsPlaceholdersIsAMissingResource() throws {
        guard case .object(var root) = try FixtureLoader.decode(JSONValue.self, at: "prompts/voice-rewrite.json"),
              case .object(var templates) = root["request"] else { Issue.record("voice-rewrite.json has no request templates"); return }
        templates["lengthLine"] = .string("Keep it short.")
        root["request"] = .object(templates)
        #expect(throws: VoxClipError.sharedResourcesMissing) {
            _ = try VoiceRewriteService.requestText(VoiceRewriteBudgetFixtures.rewrite(), source: "Hi", prompt: .object(root))
        }
    }
}
