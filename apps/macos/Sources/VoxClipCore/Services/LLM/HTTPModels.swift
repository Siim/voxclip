import Foundation

extension HTTPConnector {
    public func selectModel(_ model: String?) { selectedModel = model }

    public func models(refresh: Bool) async throws -> [LLMModel] {
        if cachedModels == nil, let cacheURL { cachedModels = await AIModelCache.shared.load(id: id, from: cacheURL) }
        if !refresh { return cachedModels ?? catalog.curatedModels(for: id) }
        do {
            let result = try await refreshModels(timeout: 15)
            cachedModels = result
            refreshWarning = nil
            if let cacheURL { await AIModelCache.shared.save(result, id: id, to: cacheURL) }
            return result
        } catch {
            if Task.isCancelled || (error as? LLMError) == .cancelled { throw LLMError.cancelled }
            let failure = error as? LLMError ?? .network
            let label = catalog.connector(id)[ai: "label"].aiString ?? id.rawValue
            refreshWarning = await log.redact("Couldn't refresh: \(failure.userMessage(label: label) ?? "")")
            await log.write(LogEntry(level: .warn, category: "llm", message: await log.redact("llm connector=\(id.rawValue) model-list error=\(failure.code.rawValue)")))
            return cachedModels ?? catalog.curatedModels(for: id)
        }
    }

    func refreshModels(timeout: Double) async throws -> [LLMModel] {
        let modelList = catalog.connector(id)[ai: "modelList"]
        let path = modelList[ai: "path"].aiString ?? "/v1/models"
        var query = (modelList[ai: "query"].aiObject ?? [:]).sorted { $0.key < $1.key }.compactMap { key, value in value.aiString.map { URLQueryItem(name: key, value: $0) } }
        var all: [JSONValue] = []
        var seenCursors: Set<String> = []
        for _ in 0..<100 {
            let page = try await fetch(path: path, query: query, timeout: timeout)
            let items = modelList[ai: "items"].aiString ?? "data"
            guard case .array(let entries) = page[ai: items] else { throw LLMError.invalidOutput(reason: "missing model list") }
            all += entries
            let pagination = modelList[ai: "pagination"]
            let cursorField = pagination[ai: "cursorField"].aiString
            guard let cursorField, let cursor = page[ai: cursorField].aiString, !cursor.isEmpty,
                  (id != .anthropic || page[ai: "has_more"].aiBool == true), seenCursors.insert(cursor).inserted else { break }
            let parameter = pagination[ai: "cursorParam"].aiString ?? "after_id"
            query.removeAll { $0.name == parameter }
            query.append(URLQueryItem(name: parameter, value: cursor))
        }
        if id == .openai { all.sort { ($0[ai: "created"].aiDouble ?? 0) > ($1[ai: "created"].aiDouble ?? 0) } }
        var discovered: [LLMModel] = []
        var seen: Set<String> = []
        for item in all {
            var modelID = item[ai: id == .gemini || id == .ollama ? "name" : "id"].aiString ?? ""
            if id == .gemini && modelID.hasPrefix("models/") { modelID = String(modelID.dropFirst(7)) }
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { continue }
            let lower = modelID.lowercased()
            let exclusions: [String]
            switch id {
            case .anthropic:
                details[modelID] = item
                guard item[ai: "capabilities"][ai: "structured_outputs"][ai: "supported"].aiBool != false else { continue }
                exclusions = []
            case .openai:
                guard modelID.hasPrefix("gpt-") || modelID.range(of: #"^o[0-9]"#, options: .regularExpression) != nil else { continue }
                exclusions = ["audio", "realtime", "live", "voice", "transcribe", "tts", "image", "search", "embedding", "moderation", "instruct"]
            case .xai:
                guard modelID.hasPrefix("grok-") else { continue }
                exclusions = ["image", "imagine", "video", "vision", "tts", "stt", "voice", "audio", "realtime", "live", "transcribe"]
            case .gemini:
                guard modelID.hasPrefix("gemini-"), item[ai: "supportedGenerationMethods"].aiArray.contains(.string("generateContent")) else { continue }
                exclusions = ["embedding", "image", "tts", "audio", "live", "aqa"]
            case .ollama, .lmstudio: exclusions = ["embed"]
            default: exclusions = []
            }
            guard !exclusions.contains(where: lower.contains) else { continue }
            var context: Int?
            if id == .ollama {
                let info = try await fetch(path: "/api/show", body: .object(["model": .string(modelID)]), timeout: timeout)
                details[modelID] = info
                if info[ai: "capabilities"] != .null && !info[ai: "capabilities"].aiArray.contains(.string("completion")) { continue }
                context = info[ai: "model_info"].aiObject?.first { $0.key.hasSuffix(".context_length") }?.value.aiInt
            } else if id == .anthropic { context = item[ai: "max_input_tokens"].aiInt }
            else if id == .gemini { context = item[ai: "inputTokenLimit"].aiInt }
            if let context { contexts[modelID] = context }
            let name = item[ai: "display_name"].aiString ?? item[ai: "displayName"].aiString ?? modelID
            discovered.append(LLMModel(id: modelID, name: name, contextTokens: context, source: .discovered))
        }
        if id == .ollama || id == .lmstudio { return discovered }
        let curated = catalog.curatedModels(for: id)
        let present = Set(discovered.map(\.id))
        var merged = curated.compactMap { model -> LLMModel? in
            guard present.contains(model.id) else { return nil }
            let found = discovered.first { $0.id == model.id }
            return LLMModel(id: model.id, name: model.name, tier: model.tier, contextTokens: found?.contextTokens ?? model.contextTokens, source: .curated)
        }
        let curatedIDs = Set(curated.map(\.id))
        merged += discovered.filter { !curatedIDs.contains($0.id) }
        if let selectedModel, !present.contains(selectedModel) {
            let previous = cachedModels?.first { $0.id == selectedModel } ?? curated.first { $0.id == selectedModel }
            merged.append(LLMModel(id: selectedModel, name: "\(previous?.name ?? selectedModel) (not listed for this key)", tier: previous?.tier, contextTokens: previous?.contextTokens, source: previous?.source ?? .custom))
        }
        return merged
    }
}

private actor AIModelCache {
    static let shared = AIModelCache()

    func load(id: ConnectorID, from url: URL) -> [LLMModel]? {
        guard let data = try? Data(contentsOf: url), let value = CanonicalResponseParser.envelope(data),
              let encoded = try? value[ai: id.rawValue][ai: "models"].aiEncoded() else { return nil }
        return try? JSONDecoder().decode([LLMModel].self, from: encoded)
    }

    func save(_ models: [LLMModel], id: ConnectorID, to url: URL) {
        do {
            let existing = (try? Data(contentsOf: url)).flatMap { CanonicalResponseParser.envelope($0) }
            var document = existing?.aiObject ?? [:]
            let encodedModels = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(models))
            document[id.rawValue] = .object(["fetchedAt": UTCTimestamp.string(from: Date()).map { .string($0) } ?? .null, "models": encodedModels])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONValue.object(document).aiEncoded().write(to: url, options: .atomic)
        } catch {}
    }
}
