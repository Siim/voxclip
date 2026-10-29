import Foundation

/// Runs one selected connector/model and returns inert review data. It never invokes Voice Lab generation.
public actor VoiceRewriteService {
    private let shared: SharedResources
    private var active = false
    private var prepared: [UUID: VoiceRewriteQuote] = [:]
    private var preparedOrder: [UUID] = []
    private var preparedAt: [UUID: Date] = [:]
    private var now: @Sendable () -> Date = { Date() }
    #if DEBUG
    @_spi(Testing) public func useClock(_ clock: @escaping @Sendable () -> Date) { now = clock }
    #endif
    public init(shared: SharedResources) { self.shared = shared }

    /// `est()` of the whole rendered request, in tokens, with no known price (voice-lab §8.9.1). It checks the request first.
    public func estimate(_ input: VoiceRewriteRequest, connector: ConnectorID) throws -> CostEstimate {
        try validate(input)
        return try estimate(try render(input), connector: connector)
    }

    public func prepare(_ input: VoiceRewriteRequest, connector: ConnectorID, model: String) throws -> VoiceRewriteQuote {
        try validate(input)
        guard VoiceLabLLMChecks.isValidModel(model) else { throw VoiceLabError.invalidInput }
        let rendered = try render(input)
        _ = try maxOutputTokens(rendered, source: input.sourceWords.map(\.text).joined(separator: " "), connector: connector,
                                catalog: try LLMCatalog(shared: shared))
        let value = VoiceRewriteQuote(id: UUID(), requestID: input.id, connector: connector, model: model,
                                      estimate: try estimate(rendered, connector: connector),
                                      fingerprint: try fingerprint(input, connector: connector, model: model, prompt: rendered.promptSHA256))
        if preparedOrder.count == 32 { prepared.removeValue(forKey: preparedOrder.removeFirst()) }
        prepared[value.id] = value
        preparedAt = preparedAt.filter { prepared[$0.key] != nil }
        preparedAt[value.id] = now()
        preparedOrder.append(value.id)
        return value
    }

    private func validate(_ input: VoiceRewriteRequest) throws {
        guard !input.sourceWords.isEmpty, input.sourceWords.count <= 3_000,
              input.sourceWords.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              input.instruction.utf8.count <= 1_000,
              input.targetSeconds.isFinite, input.targetSeconds > 0, input.targetSeconds <= 600,
              input.minChars >= 1, input.minChars <= input.maxChars, input.maxChars <= 5_000 else { throw VoiceLabError.invalidInput }
        let source = input.sourceWords.map(\.text).joined(separator: " ")
        guard !AIText.trim(source).isEmpty, source.utf8.count <= 20_000,
              input.language.range(of: #"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil else { throw VoiceLabError.invalidInput }
    }

    /// `prompt` is the prompt file's SHA-256 after CRLF→LF.
    private func fingerprint(_ input: VoiceRewriteRequest, connector: ConnectorID, model: String, prompt: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return VoiceLabFingerprint.fields([VoiceLabFingerprint.bytes(try encoder.encode(input)), connector.rawValue, model,
                                           "voice_rewrite_proposal", prompt])
    }

    /// The prompt, read once, and the request rendered from it.
    private struct Rendered {
        let document: JSONValue
        let promptSHA256: String
        let system: String
        let schemaName: String
        let cachedBlock: String
        let instruction: String
    }

    private func render(_ input: VoiceRewriteRequest) throws -> Rendered {
        let prompt = try VoiceLabLLMChecks.readPrompt(shared, "prompts/voice-rewrite.json")
        let document = prompt.document
        guard document[ai: "schemaVersion"].aiInt == 1,
              let system = document[ai: "system"].aiString,
              let schemaName = document[ai: "schemaName"].aiString,
              CanonicalResponseParser.validateSchemaSubset(document[ai: "schema"]) else { throw VoxClipError.sharedResourcesMissing }
        let text = try Self.requestText(input, source: input.sourceWords.map(\.text).joined(separator: " "), prompt: document)
        return Rendered(document: document, promptSHA256: prompt.sha256, system: system, schemaName: schemaName,
                        cachedBlock: text.cachedBlock, instruction: text.instruction)
    }

    private func estimate(_ rendered: Rendered, connector: ConnectorID) throws -> CostEstimate {
        try VoiceLabLLMChecks.estimate(shared, connector: connector, operation: "voiceRewrite",
                                       request: rendered.system + rendered.cachedBlock + rendered.instruction)
    }

    /// The send's output cap (ai.md §12.8), checked when the quote is prepared and again before the send.
    private func maxOutputTokens(_ rendered: Rendered, source: String, connector: ConnectorID, catalog: LLMCatalog) throws -> Int {
        let policy = AITokenPolicy(catalog.document[ai: "policy"])
        guard let cap = VoiceLabLLMChecks.maxOutputTokens(sourceTokens: policy.estimate(source),
                                                          promptCap: rendered.document[ai: "maxOutputTokens"].aiInt ?? 16_000,
                                                          connectorCap: catalog.connector(connector)[ai: "maxOutputTokensCap"].aiInt) else {
            throw LLMError.contextTooLong
        }
        return cap
    }

    /// Renders the request from the shared prompt's templates (voice-lab §8.9.1); no prompt text lives in code.
    static func requestText(_ input: VoiceRewriteRequest, source: String, prompt: JSONValue) throws -> (cachedBlock: String, instruction: String) {
        let templates = prompt[ai: "request"]
        guard let sourceBlock = templates[ai: "sourceBlock"].aiString, let requestBlock = templates[ai: "instructionBlock"].aiString,
              let returnLine = templates[ai: "returnLine"].aiString, let lengthLine = templates[ai: "lengthLine"].aiString,
              ["{scope}", "{language}", "{source}"].allSatisfy({ sourceBlock.contains($0) }), requestBlock.contains("{instruction}"),
              ["{targetSeconds}", "{minChars}", "{maxChars}"].allSatisfy({ lengthLine.contains($0) }) else { throw VoxClipError.sharedResourcesMissing }
        // User text goes in last, so it is never read as a placeholder.
        let block = sourceBlock.replacingOccurrences(of: "{scope}", with: input.scope.rawValue)
            .replacingOccurrences(of: "{language}", with: input.language).replacingOccurrences(of: "{source}", with: source)
        let length = lengthLine.replacingOccurrences(of: "{targetSeconds}", with: toFixed1(input.targetSeconds))
            .replacingOccurrences(of: "{minChars}", with: String(input.minChars)).replacingOccurrences(of: "{maxChars}", with: String(input.maxChars))
        let request = AIText.trim(input.instruction)
        let parts = (request.isEmpty ? [] : [requestBlock.replacingOccurrences(of: "{instruction}", with: request)]) + [returnLine + "\n" + length]
        return (block, parts.joined(separator: "\n\n"))
    }

    public func propose(_ input: VoiceRewriteRequest, connector: any LLMConnector, model: String,
                        authorization: VoiceRewriteAuthorization) async throws -> VoiceRewriteProposal {
        guard !active else { throw LLMError.unavailable(reason: "A rewrite is already running.") }
        active = true
        defer { active = false }
        try Task.checkCancellation()
        try validate(input)
        let rendered = try render(input)
        let quote = authorization.quote
        guard authorization.approved, quote.requestID == input.id, quote.connector == connector.id, quote.model == model,
              quote.fingerprint == (try fingerprint(input, connector: connector.id, model: model, prompt: rendered.promptSHA256)),
              prepared[quote.id] == quote, let date = preparedAt[quote.id], now() < date.addingTimeInterval(300) else { throw VoiceLabError.consentRequired }
        let source = input.sourceWords.map(\.text).joined(separator: " ")
        let document = rendered.document
        let catalog = try LLMCatalog(shared: shared)
        guard case .ready = await connector.status() else { throw LLMError.unavailable(reason: "The selected connector is not ready.") }
        let choices = try await connector.models(refresh: false)
        guard choices.contains(where: { $0.id == model }) else { throw LLMError.modelNotFound(model) }
        let context = try await catalog.resolvedContextTokens(connector: connector, model: model, models: choices)
        let policy = AITokenPolicy(catalog.document[ai: "policy"])
        let maxOutput = try maxOutputTokens(rendered, source: source, connector: connector.id, catalog: catalog)
        let required = VoiceLabLLMChecks.requiredTokens(policy, text: rendered.system + rendered.cachedBlock + rendered.instruction,
                                                        schema: try document[ai: "schema"].aiCompact(), maxOutputTokens: maxOutput)
        guard VoiceLabLLMChecks.contextFits(context: context, required: required, safetyFactor: policy.safetyFactor) else {
            throw LLMError.contextTooLong
        }
        let request = LLMRequest(feature: .voiceRewrite, system: rendered.system, cachedBlock: rendered.cachedBlock, instruction: rendered.instruction,
                                 schemaName: rendered.schemaName, schema: document[ai: "schema"], maxOutputTokens: maxOutput,
                                 effort: .medium, timeout: catalog.timeout(for: connector.id, feature: .voiceRewrite),
                                 language: input.language, tag: "voice-rewrite")
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
        guard let rewrite = parsed.object[ai: "rewrite"].aiString,
              !AIText.trim(rewrite).isEmpty, rewrite.utf8.count <= 20_000,
              rewrite.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) == nil,
              !rewrite.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" }) else {
            throw LLMError.invalidOutput(reason: "The rewrite is not a plain spoken passage.")
        }
        let length = VoiceLabTextLength.length(rewrite)
        return VoiceRewriteProposal(id: UUID(), scope: input.scope, sourceWords: input.sourceWords,
                                    sourceText: source, proposedText: rewrite, connector: connector.id,
                                    model: completion.model, providerRequestID: completion.requestID,
                                    proposedLength: length, inRange: (input.minChars...input.maxChars).contains(length))
    }
}
