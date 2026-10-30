import Foundation

extension HTTPConnector {
    func makeRequest(_ canonical: LLMRequest, model: String) async throws -> URLRequest {
        let configuration = catalog.connector(id)
        let modelConfiguration = configuration[ai: "models"].aiArray.first { $0[ai: "id"].aiString == model } ?? .null
        let discovered = details[model] ?? .null
        let maximum = min(canonical.maxOutputTokens, configuration[ai: "maxOutputTokensCap"].aiInt ?? canonical.maxOutputTokens)
        let schema = try JSONSerialization.jsonObject(with: canonical.schema.aiEncoded())
        let schemaFormat: [String: Any] = ["type": "json_schema", "json_schema": ["name": canonical.schemaName, "strict": true, "schema": schema]]
        let user = aiUserContent(canonical)
        let messages: [[String: Any]] = [["role": "system", "content": canonical.system], ["role": "user", "content": user]]
        var body: [String: Any]
        var path = configuration[ai: "generate"][ai: "path"].aiString ?? ""
        var beta: String?
        switch id {
        case .anthropic:
            let custom = modelConfiguration == .null
            let unsupportedSchema = custom && discovered[ai: "capabilities"][ai: "structured_outputs"][ai: "supported"].aiBool == false
            var instruction = canonical.instruction
            if unsupportedSchema { instruction += "\n\nReply with only a JSON object that matches this JSON Schema: \(try aiCompactCanonicalSchema(canonical.schema))" }
            var content: [[String: Any]] = []
            if let cached = canonical.cachedBlock { content.append(["type": "text", "text": cached, "cache_control": ["type": "ephemeral"]]) }
            content.append(["type": "text", "text": instruction])
            var output: [String: Any] = [:]
            if !unsupportedSchema { output["format"] = ["type": "json_schema", "schema": schema] }
            let effortAllowed = modelConfiguration[ai: "effort"].aiBool == true || discovered[ai: "capabilities"][ai: "effort"][ai: "supported"].aiBool == true || (custom && model.range(of: #"^claude-(opus|sonnet|haiku|fable)-5"#, options: .regularExpression) != nil)
            if effortAllowed, let effort = canonical.effort { output["effort"] = effort.rawValue }
            body = ["model": model, "max_tokens": maximum, "system": canonical.system, "messages": [["role": "user", "content": content]]]
            body["output_config"] = output
            // A Voice Lab rewrite is billed for the quoted model only, so it never asks for a fallback (ai.md §12.8).
            if canonical.feature != .voiceRewrite && betaAvailable && modelConfiguration[ai: "serverSideFallback"].aiBool == true {
                beta = configuration[ai: "serverSideFallback"][ai: "betaHeader"].aiString
                body["fallbacks"] = "default"
            }
        case .openai:
            var content: [[String: Any]] = []
            if let cached = canonical.cachedBlock { content.append(["type": "input_text", "text": cached]) }
            content.append(["type": "input_text", "text": canonical.instruction])
            body = ["model": model, "instructions": canonical.system, "input": [["role": "user", "content": content]],
                    "text": ["format": ["type": "json_schema", "name": canonical.schemaName, "strict": true, "schema": schema]],
                    "max_output_tokens": maximum, "store": false]
            let effortAllowed = modelConfiguration[ai: "effort"].aiBool == true || (modelConfiguration == .null && model.range(of: #"^(gpt-5|gpt-6|o[0-9])"#, options: .regularExpression) != nil)
            if effortAllowed, let effort = canonical.effort { body["reasoning"] = ["effort": effort.rawValue] }
            if let block = canonical.cachedBlock { body["prompt_cache_key"] = "voxclip-" + AIHash.sha256(block).prefix(16) }
        case .xai:
            body = ["model": model, "max_completion_tokens": maximum, "messages": messages, "response_format": schemaFormat]
        case .gemini:
            let stripped = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            path = path.replacingOccurrences(of: "{model}", with: escapedModel(stripped))
            var parts: [[String: Any]] = []
            if let cached = canonical.cachedBlock { parts.append(["text": cached]) }
            parts.append(["text": canonical.instruction])
            // 2026-10-30: https://ai.google.dev/api/generate-content does not confirm responseFormat GA for every curated model; retain responseJsonSchema.
            var generation: [String: Any] = ["maxOutputTokens": maximum, "responseMimeType": "application/json", "responseJsonSchema": schema]
            if stripped.range(of: #"^gemini-([3-9]|[1-9][0-9]+)([.-]|$)"#, options: .regularExpression) != nil, let effort = canonical.effort {
                generation["thinkingConfig"] = ["thinkingLevel": effort.rawValue.uppercased()]
            }
            body = ["systemInstruction": ["parts": [["text": canonical.system]]], "contents": [["role": "user", "parts": parts]],
                    "generationConfig": generation]
        case .ollama:
            let context = contexts[model] ?? 4096
            let policy = AITokenPolicy(catalog.document[ai: "policy"])
            let needed = policy.estimate(canonical.system) + policy.estimate(canonical.cachedBlock ?? "") + policy.estimate(canonical.instruction) + policy.estimate(try canonical.schema.aiCompact()) + maximum + 256
            guard needed <= context else { throw LLMError.contextTooLong }
            let computed = min(context, max(8192, ((needed + 1023) / 1024) * 1024))
            body = ["model": model, "stream": false, "messages": messages, "format": schema,
                    "options": ["num_ctx": computed, "num_predict": maximum, "temperature": 0], "keep_alive": "10m"]
            let capabilities = discovered[ai: "capabilities"].aiArray.compactMap(\.aiString)
            if discovered[ai: "capabilities"] != .null && !capabilities.contains("completion") { throw LLMError.noModels }
            let thinkingValues = discovered[ai: "thinking"][ai: "values"].aiArray
            if thinkingValues.contains(.bool(false)) { body["think"] = false }
            else if let lowest = ["low", "medium", "high"].first(where: { thinkingValues.contains(.string($0)) }) { body["think"] = lowest }
        case .lmstudio:
            body = ["model": model, "max_tokens": maximum, "temperature": 0, "messages": messages, "response_format": schemaFormat]
        default: throw LLMError.noConnector
        }
        var request = try await authorizedRequest(url: endpoint(path), timeout: aiDurationSeconds(canonical.timeout))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        return request
    }

    func parseResponse(_ value: JSONValue, requestedModel: String, response: HTTPURLResponse) throws -> RawCompletion {
        var stop: StopKind = .complete
        var text = ""
        var usage = LLMUsage()
        let requestHeader = catalog.connector(id)[ai: "requestIdHeader"].aiString
        let requestID = requestHeader.flatMap { response.value(forHTTPHeaderField: $0) }
        let model = value[ai: "model"].aiString ?? requestedModel
        switch id {
        case .anthropic:
            switch value[ai: "stop_reason"].aiString {
            case "max_tokens", "model_context_window_exceeded": stop = .truncated
            case "refusal": stop = .refused(category: value[ai: "stop_details"][ai: "category"].aiString)
            default: break
            }
            text = value[ai: "content"].aiArray.filter { $0[ai: "type"].aiString == "text" }.compactMap { $0[ai: "text"].aiString }.joined()
            usage = LLMUsage(input: value[ai: "usage"][ai: "input_tokens"].aiInt, output: value[ai: "usage"][ai: "output_tokens"].aiInt, cacheRead: value[ai: "usage"][ai: "cache_read_input_tokens"].aiInt, cacheWrite: value[ai: "usage"][ai: "cache_creation_input_tokens"].aiInt)
        case .openai:
            if value[ai: "status"].aiString == "incomplete" {
                stop = value[ai: "incomplete_details"][ai: "reason"].aiString == "content_filter" ? .refused(category: "content_filter") : .truncated
            }
            if value[ai: "status"].aiString == "failed" {
                let code = value[ai: "error"][ai: "code"].aiString ?? ""
                switch code {
                case "rate_limit_exceeded": throw LLMError.rateLimited(retryAfter: nil)
                case "invalid_prompt", "bio_policy", "misalignment_policy_violation", "image_content_policy_violation":
                    throw LLMError.refused(category: code)
                case "data_residency_mismatch":
                    throw LLMError.unavailable(reason: "OpenAI can't serve this request in the configured data region.")
                case "invalid_image", "invalid_image_format", "invalid_base64_image", "invalid_image_url", "image_too_large", "image_too_small", "image_parse_error", "invalid_image_mode", "image_file_too_large", "unsupported_image_media_type", "empty_image_file", "failed_to_download_image", "image_file_not_found":
                    throw LLMError.badRequest(status: 400, message: "OpenAI couldn't process an image in the request.")
                default: throw LLMError.server(status: 500)
                }
            }
            for item in value[ai: "output"].aiArray where item[ai: "type"].aiString == "message" {
                for content in item[ai: "content"].aiArray {
                    if content[ai: "type"].aiString == "output_text" { text += content[ai: "text"].aiString ?? "" }
                    if content[ai: "type"].aiString == "refusal" { stop = .refused(category: nil) }
                }
            }
            usage = LLMUsage(input: value[ai: "usage"][ai: "input_tokens"].aiInt, output: value[ai: "usage"][ai: "output_tokens"].aiInt, cacheRead: value[ai: "usage"][ai: "input_tokens_details"][ai: "cached_tokens"].aiInt)
        case .xai, .lmstudio:
            let choice = value[ai: "choices"].aiArray.first ?? .null
            if choice[ai: "finish_reason"].aiString == "length" { stop = .truncated }
            if choice[ai: "message"][ai: "refusal"] != .null { stop = .refused(category: nil) }
            text = choice[ai: "message"][ai: "content"].aiString ?? ""
            usage = LLMUsage(input: value[ai: "usage"][ai: "prompt_tokens"].aiInt, output: value[ai: "usage"][ai: "completion_tokens"].aiInt, cacheRead: value[ai: "usage"][ai: "prompt_tokens_details"][ai: "cached_tokens"].aiInt)
        case .gemini:
            let candidate = value[ai: "candidates"].aiArray.first ?? .null
            if let reason = value[ai: "promptFeedback"][ai: "blockReason"].aiString, !reason.isEmpty {
                stop = .refused(category: reason)
            } else {
                let reason = candidate[ai: "finishReason"].aiString ?? ""
                switch reason {
                case "STOP": break
                case "MAX_TOKENS", "CONTINUATION": stop = .truncated
                case "SAFETY", "RECITATION", "LANGUAGE", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "OTHER", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER", "IMAGE_RECITATION", "ESCALATION": stop = .refused(category: reason)
                case "PUP_LIMITED_DISABLED": throw LLMError.unavailable(reason: "Google Gemini has limited or disabled this account for prohibited use.")
                default: throw LLMError.server(status: 500)
                }
            }
            text = candidate[ai: "content"][ai: "parts"].aiArray.filter { $0[ai: "thought"].aiBool != true }.compactMap { $0[ai: "text"].aiString }.joined()
            let visible = value[ai: "usageMetadata"][ai: "candidatesTokenCount"].aiInt
            let thoughts = value[ai: "usageMetadata"][ai: "thoughtsTokenCount"].aiInt
            let total = (visible ?? 0).addingReportingOverflow(thoughts ?? 0)
            let output = visible == nil && thoughts == nil || total.overflow ? nil : total.partialValue
            usage = LLMUsage(input: value[ai: "usageMetadata"][ai: "promptTokenCount"].aiInt, output: output, cacheRead: value[ai: "usageMetadata"][ai: "cachedContentTokenCount"].aiInt)
        case .ollama:
            text = value[ai: "message"][ai: "content"].aiString ?? ""
            if value[ai: "done_reason"].aiString == "length" { stop = .truncated }
            usage = LLMUsage(input: value[ai: "prompt_eval_count"].aiInt, output: value[ai: "eval_count"].aiInt)
        default: throw LLMError.noConnector
        }
        return RawCompletion(text: text, model: model, stop: stop, usage: usage, requestID: requestID)
    }

    func mapError(_ value: JSONValue, status: Int, model: String) async -> LLMError {
        let error = value[ai: "error"]
        let raw = error[ai: "message"].aiString ?? error.aiString ?? "The provider rejected the request."
        let message = AIText.prefix(await log.redact(raw), utf16: 200)
        let lower = raw.lowercased()
        let code = error[ai: "code"].aiString ?? ""
        let type = error[ai: "type"].aiString ?? ""
        let reasons = error[ai: "details"].aiArray.compactMap { $0[ai: "reason"].aiString }
        if (status == 401 || status == 403), keyDestination == nil {
            let label = catalog.connector(id)[ai: "label"].aiString ?? id.rawValue
            return .unavailable(reason: "\(label) rejected the request (\(status)).")
        }
        if keyDestination != nil,
           status == 401 || status == 403 || type == "authentication_error" || (id == .gemini && reasons.contains("API_KEY_INVALID")) || (id == .xai && status == 400 && lower.contains("api key")) { return .unauthorized }
        if type == "billing_error" || status == 402 || code == "insufficient_quota" || type == "insufficient_quota" { return .quotaExceeded }
        if id == .lmstudio && lower.contains("no models loaded") { return .noModels }
        if status == 413 || code == "context_length_exceeded" || lower.contains("prompt is too long") || lower.contains("too many tokens") || lower.contains("maximum context length") || lower.contains("too long") || (id == .gemini && lower.contains("maximum number of tokens")) { return .contextTooLong }
        if status == 404 || code == "model_not_found" || (id == .ollama && lower.contains("not found")) { return .modelNotFound(model) }
        if id == .gemini && status == 504 { return .timeout }
        if status == 429 { return .rateLimited(retryAfter: nil) }
        if (status == 503 || status == 529 || type == "overloaded_error") && id != .ollama { return .overloaded }
        if status >= 500 { return .server(status: status) }
        return .badRequest(status: status, message: message)
    }

    func retryDelay(response: HTTPURLResponse, value: JSONValue) -> Double? {
        if let milliseconds = response.value(forHTTPHeaderField: "retry-after-ms"), let number = Double(milliseconds), number.isFinite { return max(0, number / 1000) }
        if let header = response.value(forHTTPHeaderField: "retry-after") {
            if let number = Double(header), number.isFinite { return max(0, number) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return max(0, date.timeIntervalSinceNow) }
        }
        for detail in value[ai: "error"][ai: "details"].aiArray {
            if let delay = detail[ai: "retryDelay"].aiString, let number = Double(delay.replacingOccurrences(of: "s", with: "")), number.isFinite { return max(0, number) }
        }
        return nil
    }
}
