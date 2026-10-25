import Foundation

/// Runs one selected connector/model and returns inert review data. It never invokes Voice Lab generation.
public actor VoiceRewriteService {
    private let shared: SharedResources
    private var active = false
    private var prepared: [UUID: VoiceRewriteQuote] = [:]
    private var preparedOrder: [UUID] = []
    public init(shared: SharedResources) { self.shared = shared }

    public func estimate(_ input: VoiceRewriteRequest, connector: ConnectorID) throws -> CostEstimate {
        let source = input.sourceWords.map(\.text).joined(separator: " ")
        guard !source.isEmpty, source.utf8.count <= 20_000 else { throw VoiceLabError.invalidInput }
        return CostEstimate(provider: connector.rawValue, operation: "voiceRewrite", units: Double(AIText.estimate(source + input.instruction)),
                            unit: "estimated input tokens", basis: "Provider price and final token usage are unknown.")
    }

    public func prepare(_ input: VoiceRewriteRequest, connector: ConnectorID, model: String) throws -> VoiceRewriteQuote {
        try validate(input)
        guard !model.isEmpty, model.utf8.count <= 256 else { throw VoiceLabError.invalidInput }
        let estimate = try estimate(input, connector: connector)
        let value = VoiceRewriteQuote(id: UUID(), requestID: input.id, connector: connector, model: model,
                                      estimate: estimate, fingerprint: try fingerprint(input, connector: connector, model: model))
        if preparedOrder.count == 32 { prepared.removeValue(forKey: preparedOrder.removeFirst()) }
        prepared[value.id] = value
        preparedOrder.append(value.id)
        return value
    }

    private func validate(_ input: VoiceRewriteRequest) throws {
        guard !input.sourceWords.isEmpty, input.sourceWords.count <= 3_000,
              input.sourceWords.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              input.instruction.utf8.count <= 1_000 else { throw VoiceLabError.invalidInput }
        let source = input.sourceWords.map(\.text).joined(separator: " ")
        guard !AIText.trim(source).isEmpty, source.utf8.count <= 20_000,
              input.language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else { throw VoiceLabError.invalidInput }
    }

    private func fingerprint(_ input: VoiceRewriteRequest, connector: ConnectorID, model: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let prompt = try Data(contentsOf: shared.root.appendingPathComponent("prompts/voice-rewrite.json"))
        return VoiceLabFingerprint.fields([VoiceLabFingerprint.bytes(try encoder.encode(input)), connector.rawValue, model,
                                           "voice_rewrite_proposal", VoiceLabFingerprint.bytes(prompt)])
    }

    public func propose(_ input: VoiceRewriteRequest, connector: any LLMConnector, model: String,
                        authorization: VoiceRewriteAuthorization) async throws -> VoiceRewriteProposal {
        guard !active else { throw LLMError.unavailable(reason: "A rewrite is already running.") }
        active = true
        defer { active = false }
        try Task.checkCancellation()
        let quote = authorization.quote
        guard authorization.approved, quote.requestID == input.id, quote.connector == connector.id,
              quote.model == model, quote.fingerprint == (try fingerprint(input, connector: connector.id, model: model)),
              prepared[quote.id] == quote else { throw VoiceLabError.consentRequired }
        try validate(input)
        let source = input.sourceWords.map(\.text).joined(separator: " ")
        guard !AIText.trim(source).isEmpty, source.utf8.count <= 20_000,
              input.language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else { throw VoiceLabError.invalidInput }
        let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("prompts/voice-rewrite.json")))
        let catalog = try LLMCatalog(shared: shared)
        guard document[ai: "schemaVersion"].aiInt == 1,
              let system = document[ai: "system"].aiString,
              let schemaName = document[ai: "schemaName"].aiString,
              CanonicalResponseParser.validateSchemaSubset(document[ai: "schema"]) else { throw VoxClipError.sharedResourcesMissing }
        guard case .ready = await connector.status() else { throw LLMError.unavailable(reason: "The selected connector is not ready.") }
        let choices = try await connector.models(refresh: false)
        guard choices.contains(where: { $0.id == model }) else { throw LLMError.modelNotFound(model) }
        let context = await connector.contextTokens(model: model) ?? choices.first(where: { $0.id == model })?.contextTokens
            ?? catalog.curatedModels(for: connector.id).first(where: { $0.id == model })?.contextTokens ?? 4_096
        let policy = AITokenPolicy(catalog.document[ai: "policy"])
        let sourceTokens = policy.estimate(source)
        let outputCeiling = min(document[ai: "maxOutputTokens"].aiInt ?? 16_000,
                                catalog.connector(connector.id)[ai: "maxOutputTokensCap"].aiInt ?? 16_000)
        let maxOutput = min(outputCeiling, max(512, Int(ceil(Double(sourceTokens) * 1.5))))
        guard maxOutput >= sourceTokens else { throw LLMError.contextTooLong }
        let sourceBlock = "SOURCE TRANSCRIPT (\(input.scope.rawValue), \(input.language)):\n\(source)"
        let instruction = "USER EDIT REQUEST:\n\(input.instruction)\n\nReturn rewritten spoken words for the entire selected source."
        let estimated = policy.estimate(system + sourceBlock + instruction) + maxOutput + policy.estimate(try document[ai: "schema"].aiCompact())
        guard estimated < Int(Double(context) * policy.safetyFactor) else { throw LLMError.contextTooLong }
        let request = LLMRequest(feature: .voiceRewrite, system: system, cachedBlock: sourceBlock, instruction: instruction,
                                 schemaName: schemaName, schema: document[ai: "schema"], maxOutputTokens: maxOutput,
                                 effort: .medium, timeout: catalog.timeout(for: connector.id, feature: .voiceRewrite),
                                 language: input.language, tag: "voice-rewrite")
        try Task.checkCancellation()
        guard prepared.removeValue(forKey: quote.id) != nil else { throw VoiceLabError.consentRequired }
        preparedOrder.removeAll { $0 == quote.id }
        let completion: RawCompletion
        do { completion = try await connector.send(request, model: model) }
        catch is CancellationError { throw LLMError.cancelled }
        try Task.checkCancellation()
        guard completion.model == model else { throw LLMError.invalidOutput(reason: "The selected model changed.") }
        let parsed = try CanonicalResponseParser.validate(completion, schema: request.schema)
        guard let rewrite = parsed.object[ai: "rewrite"].aiString,
              !AIText.trim(rewrite).isEmpty, rewrite.utf8.count <= 20_000,
              rewrite.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) == nil,
              !rewrite.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 }) else {
            throw LLMError.invalidOutput(reason: "The rewrite is not a plain spoken passage.")
        }
        return VoiceRewriteProposal(id: UUID(), scope: input.scope, sourceWords: input.sourceWords,
                                    sourceText: source, proposedText: rewrite, connector: connector.id,
                                    model: model, providerRequestID: completion.requestID)
    }
}
