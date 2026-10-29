import Foundation

/// Fix with AI (voice-lab §8.1, path 3): one selected connector and model, one approved send, and validated, inert line edits.
/// It never edits a project, invokes Voice Lab generation or asks again by itself.
public actor PatchRewriteService {
    private let shared: SharedResources
    private var active = false
    private var prepared: [UUID: PatchRewriteQuote] = [:]
    private var preparedOrder: [UUID] = []
    private var preparedAt: [UUID: Duration] = [:]
    private var now: @Sendable () -> Duration = VoiceLabQuoteClock.continuousSource()
    #if DEBUG
    @_spi(Testing) public func useClock(_ clock: @escaping @Sendable () -> Duration) { now = clock }
    #endif
    public init(shared: SharedResources) { self.shared = shared }

    /// `est()` of the whole rendered request, in tokens, with no known price (voice-lab §8.1). It checks the request first.
    public func estimate(_ input: PatchRewriteRequest, connector: ConnectorID) throws -> CostEstimate {
        try estimate(try render(input, transcript: try validate(input)), connector: connector)
    }

    public func prepare(_ input: PatchRewriteRequest, connector: ConnectorID, model: String) throws -> PatchRewriteQuote {
        let transcript = try validate(input)
        guard VoiceLabLLMChecks.isValidModel(model) else { throw VoiceLabError.invalidInput }
        let rendered = try render(input, transcript: transcript)
        _ = try maxOutputTokens(rendered, transcript: transcript, connector: connector, catalog: try LLMCatalog(shared: shared))
        let value = PatchRewriteQuote(id: UUID(), requestID: input.id, connector: connector, model: model,
                                      estimate: try estimate(rendered, connector: connector),
                                      fingerprint: try fingerprint(input, connector: connector, model: model, prompt: rendered.promptSHA256))
        if preparedOrder.count == 32 { prepared.removeValue(forKey: preparedOrder.removeFirst()) }
        prepared[value.id] = value
        preparedAt = preparedAt.filter { prepared[$0.key] != nil }
        preparedAt[value.id] = now()
        preparedOrder.append(value.id)
        return value
    }

    /// Checks every input bound and returns the request's transcript lines (ai.md §11.3), one per range.
    private func validate(_ input: PatchRewriteRequest) throws -> FormattedTranscript {
        guard (1...3_000).contains(input.entries.count), input.entries[0].index >= 0,
              zip(input.entries, input.entries.dropFirst()).allSatisfy({ $0.index < $1.index }),
              input.entries.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && !AIText.trim($0.text).isEmpty }),
              input.entries.map(\.text).joined(separator: " ").utf8.count <= 20_000,
              !AIText.trim(input.instruction).isEmpty, input.instruction.utf8.count <= 1_000,
              input.language.range(of: #"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil,
              input.ranges.allSatisfy({ $0.minChars >= 1 && $0.minChars <= $0.maxChars && $0.maxChars <= 5_000 }) else { throw VoiceLabError.invalidInput }
        let transcript = try formatTranscript(input.entries)
        guard transcript.lines.map({ "[\($0.firstIndex)-\($0.lastIndex)]" }) == input.ranges.map(\.line) else { throw VoiceLabError.invalidInput }
        return transcript
    }

    /// `prompt` is the prompt file's SHA-256 after CRLF→LF.
    private func fingerprint(_ input: PatchRewriteRequest, connector: ConnectorID, model: String, prompt: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return VoiceLabFingerprint.fields([VoiceLabFingerprint.bytes(try encoder.encode(input)), connector.rawValue, model,
                                           "patch_edits", prompt])
    }

    /// The prompt, read once, and the request rendered from it.
    private struct Rendered {
        let document: JSONValue
        let promptSHA256: String
        let system: String
        let schemaName: String
        let checkThisMessage: String
        let cachedBlock: String
        let instruction: String
    }

    private func render(_ input: PatchRewriteRequest, transcript: FormattedTranscript) throws -> Rendered {
        let prompt = try VoiceLabLLMChecks.readPrompt(shared, "prompts/patch-rewrite.json")
        let document = prompt.document
        guard document[ai: "schemaVersion"].aiInt == 1,
              let system = document[ai: "system"].aiString,
              let schemaName = document[ai: "schemaName"].aiString,
              let checkThisMessage = document[ai: "messages"][ai: "checkThis"].aiString,
              CanonicalResponseParser.validateSchemaSubset(document[ai: "schema"]) else { throw VoxClipError.sharedResourcesMissing }
        let text = try Self.requestText(input, transcript: transcript, prompt: document)
        return Rendered(document: document, promptSHA256: prompt.sha256, system: system, schemaName: schemaName,
                        checkThisMessage: checkThisMessage, cachedBlock: text.cachedBlock, instruction: text.instruction)
    }

    private func estimate(_ rendered: Rendered, connector: ConnectorID) throws -> CostEstimate {
        try VoiceLabLLMChecks.estimate(shared, connector: connector, operation: "patchRewrite",
                                       request: rendered.system + rendered.cachedBlock + rendered.instruction)
    }

    /// The send's output cap (ai.md §12.8), checked when the quote is prepared and again before the send.
    private func maxOutputTokens(_ rendered: Rendered, transcript: FormattedTranscript, connector: ConnectorID, catalog: LLMCatalog) throws -> Int {
        let policy = AITokenPolicy(catalog.document[ai: "policy"])
        guard let cap = VoiceLabLLMChecks.maxOutputTokens(sourceTokens: policy.estimate(transcript.rendered),
                                                          promptCap: rendered.document[ai: "maxOutputTokens"].aiInt ?? 16_000,
                                                          connectorCap: catalog.connector(connector)[ai: "maxOutputTokensCap"].aiInt) else {
            throw LLMError.contextTooLong
        }
        return cap
    }

    /// Renders the request from the shared prompt (voice-lab §8.1): the clip finder's transcript block, then one range per line
    /// and the instruction. No prompt text lives in code.
    static func requestText(_ input: PatchRewriteRequest, transcript: FormattedTranscript, prompt: JSONValue) throws -> (cachedBlock: String, instruction: String) {
        let templates = prompt[ai: "request"]
        guard let prefix = prompt[ai: "transcriptBlock"][ai: "prefix"].aiString, let suffix = prompt[ai: "transcriptBlock"][ai: "suffix"].aiString,
              let rangesLine = templates[ai: "rangesLine"].aiString, let rangeLine = templates[ai: "rangeLine"].aiString,
              let instructionLine = templates[ai: "instructionLine"].aiString,
              ["{line}", "{minChars}", "{maxChars}"].allSatisfy({ rangeLine.contains($0) }),
              instructionLine.contains("{instruction}") else { throw VoxClipError.sharedResourcesMissing }
        let ranges = input.ranges.map { range in
            rangeLine.replacingOccurrences(of: "{line}", with: range.line).replacingOccurrences(of: "{minChars}", with: String(range.minChars))
                .replacingOccurrences(of: "{maxChars}", with: String(range.maxChars))
        }
        let instruction = instructionLine.replacingOccurrences(of: "{instruction}", with: AIText.trim(input.instruction))
        return (prefix + transcript.rendered + suffix, ([rangesLine] + ranges).joined(separator: "\n") + "\n\n" + instruction)
    }

    public func propose(_ input: PatchRewriteRequest, connector: any LLMConnector, model: String,
                        authorization: PatchRewriteAuthorization) async throws -> PatchRewriteProposal {
        guard !active else { throw LLMError.unavailable(reason: "A rewrite is already running.") }
        active = true
        defer { active = false }
        try Task.checkCancellation()
        let transcript = try validate(input)
        let rendered = try render(input, transcript: transcript)
        let quote = authorization.quote
        guard authorization.approved, quote.requestID == input.id, quote.connector == connector.id, quote.model == model,
              quote.fingerprint == (try fingerprint(input, connector: connector.id, model: model, prompt: rendered.promptSHA256)),
              prepared[quote.id] == quote, let date = preparedAt[quote.id], now() < date + .seconds(300) else { throw VoiceLabError.consentRequired }
        let document = rendered.document
        let catalog = try LLMCatalog(shared: shared)
        guard case .ready = await connector.status() else { throw LLMError.unavailable(reason: "The selected connector is not ready.") }
        let choices = try await connector.models(refresh: false)
        guard choices.contains(where: { $0.id == model }) else { throw LLMError.modelNotFound(model) }
        let context = try await catalog.resolvedContextTokens(connector: connector, model: model, models: choices)
        let policy = AITokenPolicy(catalog.document[ai: "policy"])
        let maxOutput = try maxOutputTokens(rendered, transcript: transcript, connector: connector.id, catalog: catalog)
        let required = VoiceLabLLMChecks.requiredTokens(policy, text: rendered.system + rendered.cachedBlock + rendered.instruction,
                                                        schema: try document[ai: "schema"].aiCompact(), maxOutputTokens: maxOutput)
        guard VoiceLabLLMChecks.contextFits(context: context, required: required, safetyFactor: policy.safetyFactor) else {
            throw LLMError.contextTooLong
        }
        // A Voice Lab rewrite send, so each connector makes it once, like the passage rewrite.
        let request = LLMRequest(feature: .voiceRewrite, system: rendered.system, cachedBlock: rendered.cachedBlock, instruction: rendered.instruction,
                                 schemaName: rendered.schemaName, schema: document[ai: "schema"], maxOutputTokens: maxOutput,
                                 effort: .medium, timeout: catalog.timeout(for: connector.id, feature: .voiceRewrite),
                                 language: input.language, tag: "patch-rewrite")
        try Task.checkCancellation()
        guard prepared.removeValue(forKey: quote.id) != nil else { throw VoiceLabError.consentRequired }
        preparedAt.removeValue(forKey: quote.id)
        preparedOrder.removeAll { $0 == quote.id }
        let completion: RawCompletion
        do { completion = try await connector.send(request, model: model) }
        catch is CancellationError { throw LLMError.cancelled }
        try Task.checkCancellation()
        // Then a truncated or refused reply is its own error (ai.md §12.8).
        guard VoiceLabLLMChecks.answeredBy(connector.id, selected: model, answered: completion.model) else {
            throw LLMError.invalidOutput(reason: "The selected model changed.")
        }
        let parsed = try CanonicalResponseParser.validate(completion, schema: request.schema)
        let result = PatchRewriteValidator.validate(parsed.object[ai: "edits"].aiArray, ranges: input.ranges,
                                                    sources: input.entries.map(\.text) + [input.instruction])
        // The whole reply keeps the 20,000-byte rule: the kept edits' texts hold at most that much together (§8.1).
        guard result.edits.reduce(0, { $0 + $1.text.utf8.count }) <= PatchRewriteValidator.maxTextBytes else {
            throw LLMError.invalidOutput(reason: "The edits hold more than 20,000 bytes of text.")
        }
        return PatchRewriteProposal(id: UUID(), edits: result.edits, unknownLines: result.unknownLines,
                                    duplicateLines: result.duplicateLines, malformedItems: parsed.droppedItems + result.malformedItems,
                                    checkThisMessage: rendered.checkThisMessage, connector: connector.id, model: completion.model,
                                    providerRequestID: completion.requestID)
    }
}
