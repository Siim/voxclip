import Foundation

public struct VoiceLabWordingFitQuote: Sendable, Equatable {
    public let id: UUID
    public let estimate: CostEstimate
    let fingerprint: String
}

public actor VoiceLabWordingFitService {
    private let shared: SharedResources
    private var prepared: [UUID: (VoiceLabWordingFitQuote, Duration)] = [:]
    private let now: @Sendable () -> Duration = VoiceLabQuoteClock.continuousSource()
    public init(shared: SharedResources) { self.shared = shared }

    public func request(_ phrases: [VoiceLabFitPhrase], connector: ConnectorID, language: String) throws -> LLMRequest {
        guard !phrases.isEmpty, phrases.count <= 60, Set(phrases.map(\.ordinal)).count == phrases.count,
              phrases.allSatisfy({ $0.ordinal > 0 && !$0.original.isEmpty && !$0.proposed.isEmpty &&
                  $0.original.utf8.count <= 20_000 && $0.proposed.utf8.count <= 20_000 &&
                  $0.estimateSeconds.isFinite && $0.estimateSeconds > 0 && $0.slotSeconds.isFinite && $0.slotSeconds > 0 &&
                  ["longer", "shorter"].contains($0.direction) && $0.target.minimum > 0 && $0.target.maximum >= $0.target.minimum &&
                  $0.target.maximum <= 2_000 && ($0.measuredSeconds.map { $0.isFinite && $0 > 0 } ?? true) }),
              language.range(of: #"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil else {
            throw VoiceLabError.invalidInput
        }
        let document = try VoiceLabLLMChecks.readPrompt(shared, "prompts/voice-rewrite-fit.json").document
        guard document[ai: "schemaVersion"].aiInt == 1, let system = document[ai: "system"].aiString,
              let name = document[ai: "schemaName"].aiString,
              CanonicalResponseParser.validateSchemaSubset(document[ai: "schema"]) else { throw VoxClipError.sharedResourcesMissing }
        let templates = document[ai: "request"]
        func fill(_ key: String, _ values: [String: String]) throws -> String {
            guard let template = templates[ai: key].aiString else { throw VoxClipError.sharedResourcesMissing }
            return template.replacing(#/\{([A-Za-z]+)\}/#) { match in values[String(match.1)] ?? String(match.0) }
        }
        let lines = try phrases.map { phrase in
            let count = EditingPrimitives.splitWords(phrase.proposed).count
            let difference = phrase.direction == "longer" ? max(1, phrase.target.minimum - count) : max(1, count - phrase.target.maximum)
            let direction = try fill(phrase.direction + "PhraseLine", ["differenceWords": String(difference)])
            var line = try fill("phraseLine", ["ordinal": String(phrase.ordinal), "original": phrase.original,
                "proposed": phrase.proposed, "estimateSeconds": toFixed1(phrase.estimateSeconds), "slotSeconds": toFixed1(phrase.slotSeconds),
                "directionLine": direction, "minimumWords": String(phrase.target.minimum), "maximumWords": String(phrase.target.maximum),
                "paceLine": phrase.calibrated ? templates[ai: "calibratedPaceLine"].aiString ?? "" : ""])
            if let measured = phrase.measuredSeconds {
                line += "\n" + (try fill("measuredPhraseLine", ["measuredSeconds": toFixed1(measured), "slotSeconds": toFixed1(phrase.slotSeconds)]))
            }
            return line
        }
        let cached = try fill("sourceBlock", ["language": language, "phrases": lines.joined(separator: "\n\n")])
        let instruction = try fill(phrases.contains { $0.measuredSeconds != nil } ? "measuredFeedbackBlock" : "fitFeedbackBlock", [:])
        guard (system + cached + instruction).utf8.count <= 100_000 else { throw VoiceLabError.invalidInput }
        let catalog = try LLMCatalog(shared: shared)
        let policy = AITokenPolicy(catalog.document[ai: "policy"])
        let proposed = phrases.map(\.proposed).joined(separator: " ")
        guard let output = VoiceLabLLMChecks.maxOutputTokens(sourceTokens: policy.estimate(proposed),
            promptCap: document[ai: "maxOutputTokens"].aiInt ?? 16_000,
            connectorCap: catalog.connector(connector)[ai: "maxOutputTokensCap"].aiInt) else { throw LLMError.contextTooLong }
        return LLMRequest(feature: .voiceRewrite, system: system, cachedBlock: cached, instruction: instruction,
            schemaName: name, schema: document[ai: "schema"], maxOutputTokens: output, effort: .medium,
            timeout: catalog.timeout(for: connector, feature: .voiceRewrite), language: language, tag: "voice-rewrite-fit")
    }

    public func prepare(_ phrases: [VoiceLabFitPhrase], connector: ConnectorID, model: String, language: String) throws -> VoiceLabWordingFitQuote {
        guard VoiceLabLLMChecks.isValidModel(model) else { throw VoiceLabError.invalidInput }
        let request = try request(phrases, connector: connector, language: language)
        let quote = VoiceLabWordingFitQuote(id: UUID(),
            estimate: try VoiceLabLLMChecks.estimate(shared, connector: connector, operation: "voiceRewrite",
                request: request.system + (request.cachedBlock ?? "") + request.instruction),
            fingerprint: try fingerprint(phrases, connector: connector, model: model, language: language))
        prepared = prepared.filter { now() < $0.value.1 + .seconds(300) }
        if prepared.count >= 32, let first = prepared.keys.first { prepared.removeValue(forKey: first) }
        prepared[quote.id] = (quote, now())
        return quote
    }

    private func fingerprint(_ phrases: [VoiceLabFitPhrase], connector: ConnectorID, model: String, language: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let prompt = try VoiceLabLLMChecks.readPrompt(shared, "prompts/voice-rewrite-fit.json")
        return VoiceLabFingerprint.fields([VoiceLabFingerprint.bytes(try encoder.encode(phrases)), connector.rawValue, model, language, prompt.sha256])
    }

    public func propose(_ phrases: [VoiceLabFitPhrase], connector: any LLMConnector, model: String, language: String,
                        quote: VoiceLabWordingFitQuote, approved: Bool) async throws -> [VoiceLabFitUpdate] {
        try Task.checkCancellation()
        guard approved, let saved = prepared[quote.id], saved.0 == quote, now() < saved.1 + .seconds(300),
              quote.fingerprint == (try fingerprint(phrases, connector: connector.id, model: model, language: language)) else { throw VoiceLabError.consentRequired }
        let request = try request(phrases, connector: connector.id, language: language)
        guard case .ready = await connector.status() else { throw LLMError.unavailable(reason: "The selected connector is not ready.") }
        let models = try await connector.models(refresh: false)
        guard models.contains(where: { $0.id == model }) else { throw LLMError.modelNotFound(model) }
        let catalog = try LLMCatalog(shared: shared)
        let policy = AITokenPolicy(catalog.document[ai: "policy"])
        let context = try await catalog.resolvedContextTokens(connector: connector, model: model, models: models)
        let required = VoiceLabLLMChecks.requiredTokens(policy, text: request.system + (request.cachedBlock ?? "") + request.instruction,
            schema: try request.schema.aiCompact(), maxOutputTokens: request.maxOutputTokens)
        guard VoiceLabLLMChecks.contextFits(context: context, required: required, safetyFactor: policy.safetyFactor) else { throw LLMError.contextTooLong }
        try Task.checkCancellation()
        guard prepared.removeValue(forKey: quote.id) != nil else { throw VoiceLabError.consentRequired }
        let completion = try await connector.send(request, model: model)
        try Task.checkCancellation()
        guard VoiceLabLLMChecks.answeredBy(connector.id, selected: model, answered: completion.model) else { throw LLMError.invalidOutput(reason: "The selected model changed.") }
        let object = try CanonicalResponseParser.validate(completion, schema: request.schema).object
        let rows = object[ai: "phrases"].aiArray
        let updates = try rows.map { row -> VoiceLabFitUpdate in
            guard let ordinal = row[ai: "ordinal"].aiInt, row[ai: "ordinal"].aiDouble == Double(ordinal), let action = row[ai: "action"].aiString,
                  let text = row[ai: "text"].aiString, text.utf8.count <= 20_000,
                  action == "keepOriginal" ? text.isEmpty : (!AIText.trim(text).isEmpty &&
                    text == VoiceLabAudioTags.sanitizedRequest(text, modelID: "") &&
                    text.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) == nil &&
                    !text.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" }) else {
                throw LLMError.invalidOutput(reason: "The fit reply is not a plain spoken phrase.")
            }
            return VoiceLabFitUpdate(ordinal: ordinal, keepOriginal: action == "keepOriginal", text: text)
        }
        guard updates.count == phrases.count, Set(updates.map(\.ordinal)) == Set(phrases.map(\.ordinal)) else {
            throw LLMError.invalidOutput(reason: "The fit reply changed phrases that were not requested.")
        }
        return updates
    }
}
