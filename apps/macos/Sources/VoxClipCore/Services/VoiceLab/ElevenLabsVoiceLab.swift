import Foundation

/// Explicit, region-bound Voice Lab transport. Mutations are sent once, including on 429/5xx.
public actor ElevenLabsVoiceLab {
    public nonisolated let region: ElevenLabsRegion
    private let keys: any KeyProvider
    private let session: URLSession
    private let logger: any Redacting
    private var discoveredModels: [String: VoiceLabModel] = [:]
    private var discoveredVoices: [String: VoiceLabVoice] = [:]
    private var subscription: VoiceLabSubscription?
    private var prepared: [UUID: VoiceLabQuote] = [:]
    private var preparedOrder: [UUID] = []
    private let maxUpload = 16 * 1_024 * 1_024
    private let maxResponse = 32 * 1_024 * 1_024

    public init(keys: any KeyProvider, region: ElevenLabsRegion, logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)) {
        self.keys = keys; self.region = region; self.logger = logger
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: configuration)
    }
    public init(keys: any KeyProvider, session: URLSession, region: ElevenLabsRegion = .default, logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)) {
        self.keys = keys; self.session = session; self.region = region; self.logger = logger
    }

    public func models() async throws -> [VoiceLabModel] {
        let data = try await send("v1/models", method: "GET", limit: 1_024 * 1_024)
        guard let rows = try? JSONSerialization.jsonObject(with: data.bytes) as? [[String: Any]] else { throw VoiceLabError.malformedResponse }
        let models = try rows.map { row -> VoiceLabModel in
            guard let id = row["model_id"] as? String, Self.safeID(id) else { throw VoiceLabError.malformedResponse }
            let languages = (row["languages"] as? [[String: Any]] ?? []).compactMap { $0["language_id"] as? String }
            return VoiceLabModel(id: id, name: row["name"] as? String ?? id, languages: languages,
                                 canSpeak: row["can_do_text_to_speech"] as? Bool == true,
                                 canConvert: row["can_do_voice_conversion"] as? Bool == true,
                                 maximumTextLength: row["maximum_text_length_per_request"] as? Int,
                                 characterCostMultiplier: (row["model_rates"] as? [String: Any])?["character_cost_multiplier"] as? Double)
        }
        guard !models.isEmpty else { throw VoiceLabError.malformedResponse }
        var indexed: [String: VoiceLabModel] = [:]
        for model in models {
            guard indexed.updateValue(model, forKey: model.id) == nil else { throw VoiceLabError.malformedResponse }
        }
        discoveredModels = indexed
        return models
    }

    public func plan() async throws -> VoiceLabSubscription {
        let data = try await send("v1/user/subscription", method: "GET", limit: 128 * 1_024)
        guard let row = try? JSONSerialization.jsonObject(with: data.bytes) as? [String: Any],
              let tier = row["tier"] as? String, let status = row["status"] as? String,
              let count = row["character_count"] as? Int, let limit = row["character_limit"] as? Int,
              let canClone = row["can_use_instant_voice_cloning"] as? Bool,
              let used = row["voice_slots_used"] as? Int, let voiceLimit = row["voice_limit"] as? Int,
              count >= 0, limit >= 0, used >= 0, voiceLimit >= 0 else { throw VoiceLabError.malformedResponse }
        let result = VoiceLabSubscription(tier: tier, status: status, characterCount: count, characterLimit: limit,
                                          nextResetUnix: row["next_character_count_reset_unix"] as? Int,
                                          canClone: canClone, voiceSlotsUsed: used, voiceLimit: voiceLimit)
        subscription = result
        return result
    }

    public func voices() async throws -> [VoiceLabVoice] {
        var result: [VoiceLabVoice] = []
        var cursor: String?
        var seen: Set<String> = []
        var seenVoiceIDs: Set<String> = []
        for _ in 0..<20 {
            try Task.checkCancellation()
            var components = URLComponents(url: region.baseURL.appendingPathComponent("v2/voices"), resolvingAgainstBaseURL: false)!
            if let cursor { components.queryItems = [URLQueryItem(name: "next_page_token", value: cursor)] }
            let data = try await send(components.url!, method: "GET", limit: 4 * 1_024 * 1_024)
            guard let row = try? JSONSerialization.jsonObject(with: data.bytes) as? [String: Any],
                  let voices = row["voices"] as? [[String: Any]], let more = row["has_more"] as? Bool else { throw VoiceLabError.malformedResponse }
            for item in voices {
                guard let id = item["voice_id"] as? String, Self.safeID(id), let name = item["name"] as? String,
                      let category = item["category"] as? String else { throw VoiceLabError.malformedResponse }
                let verification = item["voice_verification"] as? [String: Any] ?? [:]
                guard seenVoiceIDs.insert(id).inserted else { throw VoiceLabError.malformedResponse }
                result.append(VoiceLabVoice(id: id, name: name, category: category, isOwner: item["is_owner"] as? Bool == true,
                                            requiresVerification: verification["requires_verification"] as? Bool == true,
                                            isVerified: verification["is_verified"] as? Bool == true))
            }
            if !more { discoveredVoices = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); return result }
            guard let next = row["next_page_token"] as? String, !next.isEmpty, next.count <= 256, seen.insert(next).inserted else { throw VoiceLabError.malformedResponse }
            cursor = next
        }
        throw VoiceLabError.responseTooLarge
    }

    public func listOwnClones() async throws -> [VoiceLabVoice] {
        try await voices().filter { $0.isOwner && $0.category == "cloned" }
    }

    public func estimate(_ operation: VoiceLabOperation, units: Double, unit: String) throws -> CostEstimate {
        guard units.isFinite, units > 0, units <= 1_000_000 else { throw VoiceLabError.invalidInput }
        return CostEstimate(provider: "elevenlabs", operation: operation.rawValue, units: units, unit: unit,
                            basis: "Provider price and account-specific credits are unknown; review usage in ElevenLabs before approval.")
    }

    private func quote(_ operation: VoiceLabOperation, requestID: UUID, endpoint: String,
                       fields: [String], units: Double, unit: String,
                       languageMode: VoiceLabLanguageMode? = nil) throws -> VoiceLabQuote {
        let estimate = try estimate(operation, units: units, unit: unit)
        let value = VoiceLabQuote(id: UUID(), operation: operation, requestID: requestID, estimate: estimate,
                                  region: region, endpoint: endpoint, languageMode: languageMode,
                                  fingerprint: VoiceLabFingerprint.fields(fields))
        if preparedOrder.count == 32 { prepared.removeValue(forKey: preparedOrder.removeFirst()) }
        prepared[value.id] = value
        preparedOrder.append(value.id)
        return value
    }

    /// Preparation is local. Discovery and subscription reads must be initiated separately.
    public func prepareClone(name: String, sample: Data, mimeType: String, policy: OwnVoicePolicy,
                             requestID: UUID) throws -> VoiceLabQuote {
        try policy.validate()
        guard let subscription, subscription.canClone else { throw VoiceLabError.planUnavailable }
        guard subscription.voiceSlotsUsed < subscription.voiceLimit else { throw VoiceLabError.noVoiceSlots }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 100,
              !sample.isEmpty, sample.count <= maxUpload,
              ["audio/wav", "audio/mp4", "audio/mpeg", "audio/flac"].contains(mimeType) else { throw VoiceLabError.invalidInput }
        return try quote(.createClone, requestID: requestID, endpoint: "v1/voices/add",
                         fields: cloneFields(name, sample, mimeType, policy), units: 1, unit: "call")
    }

    public func prepareDelete(voiceID: String, policy: OwnVoicePolicy, requestID: UUID) throws -> VoiceLabQuote {
        try policy.validate()
        guard policy.cloneVoiceID == voiceID, Self.safeID(voiceID), let voice = discoveredVoices[voiceID],
              voice.isOwner, voice.category == "cloned" else { throw VoiceLabError.consentRequired }
        return try quote(.deleteClone, requestID: requestID, endpoint: "v1/voices/\(voiceID)",
                         fields: deleteFields(voiceID, policy), units: 1, unit: "call")
    }

    public func prepareSynthesis(text: String, modelID: String, voice: VoiceLabVoiceChoice,
                                 language: String, requestID: UUID) throws -> VoiceLabQuote {
        try voice.validate()
        let model = try selectedModel(modelID, language: language, speak: true)
        guard !text.isEmpty, text.unicodeScalars.count <= min(model.maximumTextLength ?? 5_000, 5_000),
              Self.safeID(voice.id) else { throw VoiceLabError.invalidInput }
        try selectedVoice(voice)
        return try quote(.textToSpeech, requestID: requestID, endpoint: "v1/text-to-speech/\(voice.id)/with-timestamps",
                         fields: speechFields(text, modelID, voice, language),
                         units: Double(text.unicodeScalars.count), unit: "characters",
                         languageMode: modelID == "eleven_multilingual_v2" ? .autoDetected(expected: language) : .explicit(language))
    }

    public func prepareConversion(audio: Data, modelID: String, voice: VoiceLabVoiceChoice,
                                  language: String, requestID: UUID) throws -> VoiceLabQuote {
        try voice.validate()
        _ = try selectedModel(modelID, language: language, speak: false)
        try selectedVoice(voice)
        try Self.validateWAV(audio, maxBytes: maxUpload)
        return try quote(.voiceChange, requestID: requestID, endpoint: "v1/voice-changer/\(voice.id)",
                         fields: conversionFields(audio, modelID, voice, language), units: 1, unit: "call",
                         languageMode: .autoDetected(expected: language))
    }

    private func cloneFields(_ name: String, _ sample: Data, _ mime: String, _ policy: OwnVoicePolicy) -> [String] {
        [region.rawValue, "v1/voices/add", name, mime, VoiceLabFingerprint.bytes(sample)] + VoiceLabFingerprint.policy(policy)
    }
    private func deleteFields(_ id: String, _ policy: OwnVoicePolicy) -> [String] {
        [region.rawValue, "v1/voices/\(id)", id] + VoiceLabFingerprint.policy(policy)
    }
    private func voiceFields(_ voice: VoiceLabVoiceChoice) -> [String] {
        switch voice {
        case .own(_, let policy): return [voice.id, "own"] + VoiceLabFingerprint.policy(policy)
        case .stock: return [voice.id, "stock"]
        }
    }
    private func speechFields(_ text: String, _ model: String, _ voice: VoiceLabVoiceChoice, _ language: String) -> [String] {
        [region.rawValue, "v1/text-to-speech/\(voice.id)/with-timestamps", "pcm_24000", text, model, language] + voiceFields(voice)
    }
    private func conversionFields(_ audio: Data, _ model: String, _ voice: VoiceLabVoiceChoice, _ language: String) -> [String] {
        [region.rawValue, "v1/voice-changer/\(voice.id)", "pcm_24000", VoiceLabFingerprint.bytes(audio), model, language] + voiceFields(voice)
    }

    private func claim(_ authorization: VoiceLabAuthorization, operation: VoiceLabOperation,
                       requestID: UUID, endpoint: String, fields: [String]) throws {
        let value = authorization.quote
        guard authorization.approved, value.operation == operation, value.requestID == requestID,
              value.region == region, value.endpoint == endpoint,
              value.fingerprint == VoiceLabFingerprint.fields(fields), prepared[value.id] == value else {
            throw VoiceLabError.consentRequired
        }
        prepared.removeValue(forKey: value.id)
        preparedOrder.removeAll { $0 == value.id }
    }

    public func createOwnClone(name: String, sample: Data, mimeType: String, policy: OwnVoicePolicy,
                               requestID: UUID, authorization: VoiceLabAuthorization) async throws -> VoiceLabCloneResult {
        try policy.validate()
        guard let subscription else { throw VoiceLabError.planUnavailable }
        guard subscription.canClone else { throw VoiceLabError.planUnavailable }
        guard subscription.voiceSlotsUsed < subscription.voiceLimit else { throw VoiceLabError.noVoiceSlots }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 100,
              !sample.isEmpty, sample.count <= maxUpload, ["audio/wav", "audio/mp4", "audio/mpeg", "audio/flac"].contains(mimeType) else { throw VoiceLabError.invalidInput }
        try claim(authorization, operation: .createClone, requestID: requestID, endpoint: "v1/voices/add",
                  fields: cloneFields(name, sample, mimeType, policy))
        let boundary = UUID().uuidString
        let suffix = ["audio/wav": "wav", "audio/mp4": "m4a", "audio/mpeg": "mp3", "audio/flac": "flac"][mimeType]!
        let body = try multipart(fields: [("name", name)], fileField: "files[]", filename: "own-voice.\(suffix)", mimeType: mimeType, file: sample, boundary: boundary)
        let reply = try await send("v1/voices/add", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)", limit: 128 * 1_024)
        guard let row = try? JSONSerialization.jsonObject(with: reply.bytes) as? [String: Any],
              let id = row["voice_id"] as? String, Self.safeID(id),
              let needsVerification = row["requires_verification"] as? Bool else { throw VoiceLabError.malformedResponse }
        return VoiceLabCloneResult(voiceID: id, requiresVerification: needsVerification, consentRecordID: policy.recordID,
                                   receipt: receipt("v1/voices/add", model: nil, voice: id, authorization: authorization, reply: reply))
    }

    public func deleteOwnClone(voiceID: String, policy: OwnVoicePolicy,
                               requestID: UUID, authorization: VoiceLabAuthorization) async throws -> VoiceLabReceipt {
        try policy.validate()
        guard policy.cloneVoiceID == voiceID else { throw VoiceLabError.consentRequired }
        guard Self.safeID(voiceID), let voice = discoveredVoices[voiceID], voice.isOwner, voice.category == "cloned" else { throw VoiceLabError.consentRequired }
        let path = "v1/voices/\(voiceID)"
        try claim(authorization, operation: .deleteClone, requestID: requestID, endpoint: path, fields: deleteFields(voiceID, policy))
        let reply = try await send(path, method: "DELETE", limit: 128 * 1_024)
        guard let row = try? JSONSerialization.jsonObject(with: reply.bytes) as? [String: Any],
              row["status"] as? String == "ok" else { throw VoiceLabError.malformedResponse }
        discoveredVoices.removeValue(forKey: voiceID)
        return receipt(path, model: nil, voice: voiceID, authorization: authorization, reply: reply)
    }

    public func synthesize(text: String, modelID: String, voice: VoiceLabVoiceChoice, language: String,
                           requestID: UUID, authorization: VoiceLabAuthorization) async throws -> VoiceLabAudioResult {
        try voice.validate()
        let model = try selectedModel(modelID, language: language, speak: true)
        let count = text.unicodeScalars.count
        guard count > 0, count <= min(model.maximumTextLength ?? 5_000, 5_000), Self.safeID(voice.id) else { throw VoiceLabError.invalidInput }
        try selectedVoice(voice)
        let path = "v1/text-to-speech/\(voice.id)/with-timestamps"
        try claim(authorization, operation: .textToSpeech, requestID: requestID, endpoint: path,
                  fields: speechFields(text, modelID, voice, language))
        var components = URLComponents(url: region.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var payload = ["text": text, "model_id": modelID]
        if modelID != "eleven_multilingual_v2" { payload["language_code"] = language }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let reply = try await send(components.url!, method: "POST", body: body, contentType: "application/json", limit: maxResponse)
        guard let row = try? JSONSerialization.jsonObject(with: reply.bytes) as? [String: Any],
              let base64 = row["audio_base64"] as? String, let pcm = Data(base64Encoded: base64) else { throw VoiceLabError.invalidAudio }
        try Self.validatePCM(pcm, maxBytes: maxResponse)
        let timing = try Self.parseAlignment(row["alignment"], text: text, duration: Double(pcm.count) / 48_000)
        return VoiceLabAudioResult(pcm: pcm, sampleRate: 24_000, alignment: timing,
                                   receipt: receipt(path, model: modelID, voice: voice.id, authorization: authorization, reply: reply))
    }

    /// A reviewed rewrite is generated only by this separate, explicitly approved call.
    public func synthesize(proposal: VoiceRewriteProposal, modelID: String, voice: VoiceLabVoiceChoice,
                           language: String, authorization: VoiceLabAuthorization) async throws -> VoiceLabAudioResult {
        try await synthesize(text: proposal.proposedText, modelID: modelID, voice: voice, language: language,
                             requestID: proposal.id, authorization: authorization)
    }

    public func convert(audio: Data, modelID: String, voice: VoiceLabVoiceChoice, language: String,
                        requestID: UUID, authorization: VoiceLabAuthorization) async throws -> VoiceLabAudioResult {
        try voice.validate()
        _ = try selectedModel(modelID, language: language, speak: false)
        try selectedVoice(voice)
        try Self.validateWAV(audio, maxBytes: maxUpload)
        guard Self.safeID(voice.id) else { throw VoiceLabError.invalidInput }
        let path = "v1/voice-changer/\(voice.id)"
        try claim(authorization, operation: .voiceChange, requestID: requestID, endpoint: path,
                  fields: conversionFields(audio, modelID, voice, language))
        var components = URLComponents(url: region.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        let boundary = UUID().uuidString
        let body = try multipart(fields: [("model_id", modelID)], fileField: "audio", filename: "source.wav", mimeType: "audio/wav", file: audio, boundary: boundary)
        let reply = try await send(components.url!, method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)", limit: maxResponse)
        if let type = reply.response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
           !["application/octet-stream", "audio/pcm", "audio/l16"].contains(type) { throw VoiceLabError.invalidAudio }
        try Self.validatePCM(reply.bytes, maxBytes: maxResponse)
        return VoiceLabAudioResult(pcm: reply.bytes, sampleRate: 24_000, alignment: nil,
                                   receipt: receipt(path, model: modelID, voice: voice.id, authorization: authorization, reply: reply))
    }

    private func selectedModel(_ id: String, language: String, speak: Bool) throws -> VoiceLabModel {
        guard Self.safeID(id), let model = discoveredModels[id], speak ? model.canSpeak : model.canConvert else { throw VoiceLabError.unsupportedModel }
        if speak && !model.supportsTimestampedTTS { throw VoiceLabError.unsupportedEndpoint }
        guard model.languages.contains(language) else { throw VoiceLabError.unsupportedModel }
        return model
    }
    private func selectedVoice(_ choice: VoiceLabVoiceChoice) throws {
        guard let voice = discoveredVoices[choice.id] else { throw VoiceLabError.invalidInput }
        switch choice {
        case .own(_, let policy): guard policy.cloneVoiceID == choice.id, voice.isOwner, voice.category == "cloned", !voice.requiresVerification || voice.isVerified else { throw VoiceLabError.consentRequired }
        case .stock:
            guard voice.category == "premade" || (voice.category == "generated" && voice.isOwner) else {
                throw VoiceLabError.consentRequired
            }
        }
    }
    private func receipt(_ path: String, model: String?, voice: String?, authorization: VoiceLabAuthorization, reply: Reply) -> VoiceLabReceipt {
        let remote = reply.response.value(forHTTPHeaderField: "request-id") ?? reply.response.value(forHTTPHeaderField: "x-request-id")
        return VoiceLabReceipt(provider: "elevenlabs", region: region, endpoint: path, modelID: model, voiceID: voice,
                               requestID: authorization.requestID, providerRequestID: remote)
    }
    private struct Reply { let bytes: Data; let response: HTTPURLResponse }
    private func send(_ path: String, method: String, body: Data? = nil, contentType: String? = nil, limit: Int) async throws -> Reply {
        try await send(region.baseURL.appendingPathComponent(path), method: method, body: body, contentType: contentType, limit: limit)
    }
    private func send(_ url: URL, method: String, body: Data? = nil, contentType: String? = nil, limit: Int) async throws -> Reply {
        try Task.checkCancellation()
        guard url.scheme == "https", url.host == region.baseURL.host, body?.count ?? 0 <= maxUpload + 1_024 else { throw VoiceLabError.invalidInput }
        guard let key = try await keys.key(for: "elevenlabs"), !key.isEmpty else { throw VoiceLabError.missingKey }
        await logger.register(secret: key)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 300
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("VoxClip/0.1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (stream, response) = try await session.bytes(for: request, delegate: VoiceLabNoRedirect())
            guard let http = response as? HTTPURLResponse else { throw VoiceLabError.malformedResponse }
            if let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), size > limit { throw VoiceLabError.responseTooLarge }
            var bytes = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard bytes.count < limit else { throw VoiceLabError.responseTooLarge }
                bytes.append(byte)
            }
            try Task.checkCancellation()
            guard (200..<300).contains(http.statusCode) else { throw Self.mapError(http.statusCode, bytes, path: url.path, method: method) }
            return Reply(bytes: bytes, response: http)
        } catch is CancellationError { throw VoiceLabError.cancelled }
        catch let error as VoiceLabError { throw error }
        catch { if Task.isCancelled { throw VoiceLabError.cancelled }; throw VoiceLabError.network }
    }
    private static func mapError(_ status: Int, _ body: Data, path: String, method: String) -> VoiceLabError {
        let text = String(decoding: body.prefix(16_384), as: UTF8.self).lowercased()
        if text.contains("quota") || text.contains("credit") { return .quotaExceeded }
        if status == 403 || (status == 401 && text.contains("permission")) {
            let permission: String
            switch (path, method) {
            case ("/v1/models", _): permission = "models_read"
            case ("/v1/user/subscription", _): permission = "user_read"
            case ("/v2/voices", _): permission = "voices_read"
            case ("/v1/voices/add", _): permission = "create_instant_voice_clone"
            case (_, "DELETE") where path.hasPrefix("/v1/voices/"): permission = "voices_write"
            case (_, _) where path.hasPrefix("/v1/text-to-speech/"): permission = "text_to_speech"
            case (_, _) where path.hasPrefix("/v1/voice-changer/"): permission = "speech_to_speech"
            default: permission = "unknown"
            }
            return .permissionMissing(permission)
        }
        if status == 401 { return .unauthorized }
        if status == 429 { return .rateLimited }
        if status == 422 && text.contains("output_format") { return .unsupportedFormat }
        return .providerFailure(status)
    }
    private static func safeID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }
    private func multipart(fields: [(String, String)], fileField: String, filename: String, mimeType: String, file: Data, boundary: String) throws -> Data {
        var result = Data()
        for (field, value) in fields {
            guard !value.contains("\r"), !value.contains("\n"), value.utf8.count <= 256 else { throw VoiceLabError.invalidInput }
            result.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n".utf8))
        }
        result.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        result.append(file)
        result.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard result.count <= maxUpload + 1_024 else { throw VoiceLabError.invalidInput }
        return result
    }
    private static func le32(_ bytes: Data, _ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }
    private static func wavLE16(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }
    private static func wavLE32(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }
    private static func wavTag(_ bytes: UnsafeRawBufferPointer, _ at: Int, _ tag: String) -> Bool {
        bytes[at..<(at + 4)].elementsEqual(tag.utf8)
    }
    private static func validateWAV(_ bytes: Data, maxBytes: Int) throws {
        guard bytes.count >= 44, bytes.count <= maxBytes else { throw VoiceLabError.unsupportedFormat }
        try bytes.withUnsafeBytes { raw in
            guard wavTag(raw, 0, "RIFF"), wavTag(raw, 8, "WAVE"),
                  wavLE32(raw, 4) == raw.count - 8 else { throw VoiceLabError.unsupportedFormat }
            var offset = 12
            var rate: Int?
            var samples: Int?
            while offset < raw.count {
                guard raw.count - offset >= 8 else { throw VoiceLabError.unsupportedFormat }
                let size = wavLE32(raw, offset + 4)
                let start = offset + 8
                let available = raw.count - start
                guard size <= available, (size & 1) <= available - size else { throw VoiceLabError.unsupportedFormat }
                if wavTag(raw, offset, "fmt ") {
                    guard rate == nil, size == 16 || size == 18,
                          wavLE16(raw, start) == 1, wavLE16(raw, start + 2) == 1,
                          wavLE16(raw, start + 14) == 16,
                          size == 16 || wavLE16(raw, start + 16) == 0 else { throw VoiceLabError.unsupportedFormat }
                    let parsedRate = wavLE32(raw, start + 4)
                    guard (8_000...96_000).contains(parsedRate),
                          wavLE32(raw, start + 8) == parsedRate * 2,
                          wavLE16(raw, start + 12) == 2 else { throw VoiceLabError.unsupportedFormat }
                    rate = parsedRate
                } else if wavTag(raw, offset, "data") {
                    guard samples == nil, size > 0, size.isMultiple(of: 2) else { throw VoiceLabError.unsupportedFormat }
                    samples = size / 2
                }
                offset = start + size + (size & 1)
            }
            guard let rate, let samples,
                  samples >= (rate + 49) / 50, samples <= rate * 290 else { throw VoiceLabError.unsupportedFormat }
        }
    }
    private static func validatePCM(_ pcm: Data, maxBytes: Int) throws {
        guard pcm.count >= 960, pcm.count <= maxBytes, pcm.count.isMultiple(of: 2) else { throw VoiceLabError.invalidAudio }
        // Raw samples may begin with any byte pattern, including FF FF. Reject only complete container headers.
        if pcm.count >= 44, pcm[0..<4].elementsEqual(Data("RIFF".utf8)), pcm[8..<12].elementsEqual(Data("WAVE".utf8)),
           le32(pcm, 4) == pcm.count - 8 { throw VoiceLabError.invalidAudio }
        if pcm.count >= 10, pcm[0..<3].elementsEqual(Data("ID3".utf8)), (2...4).contains(pcm[3]), pcm[4] < 0xFF,
           pcm[6..<10].allSatisfy({ $0 < 128 }),
           (6..<10).reduce(0, { ($0 << 7) | Int(pcm[$1]) }) <= pcm.count - 10 { throw VoiceLabError.invalidAudio }
        if pcm.count >= 8, pcm[0..<4].elementsEqual(Data("fLaC".utf8)),
           pcm[4] & 0x7F == 0, (Int(pcm[5]) << 16 | Int(pcm[6]) << 8 | Int(pcm[7])) == 34,
           pcm.count >= 42 { throw VoiceLabError.invalidAudio }
        if pcm.count >= 27, pcm[0..<4].elementsEqual(Data("OggS".utf8)), pcm[4] == 0,
           27 + Int(pcm[26]) <= pcm.count,
           27 + Int(pcm[26]) + pcm[27..<(27 + Int(pcm[26]))].reduce(0, { $0 + Int($1) }) <= pcm.count {
            throw VoiceLabError.invalidAudio
        }
        if pcm.count >= 16, pcm[4..<8].elementsEqual(Data("ftyp".utf8)),
           (Int(pcm[0]) << 24 | Int(pcm[1]) << 16 | Int(pcm[2]) << 8 | Int(pcm[3])) >= 16,
           (Int(pcm[0]) << 24 | Int(pcm[1]) << 16 | Int(pcm[2]) << 8 | Int(pcm[3])) <= pcm.count {
            throw VoiceLabError.invalidAudio
        }
        if let first = mp3FrameLength(pcm, offset: 0), first + 4 <= pcm.count,
           mp3FrameLength(pcm, offset: first) != nil { throw VoiceLabError.invalidAudio }
    }
    private static func mp3FrameLength(_ bytes: Data, offset: Int) -> Int? {
        guard offset + 4 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] & 0xE0 == 0xE0 else { return nil }
        let version = Int((bytes[offset + 1] >> 3) & 3), layer = (bytes[offset + 1] >> 1) & 3
        let bitrateIndex = Int(bytes[offset + 2] >> 4), rateIndex = Int((bytes[offset + 2] >> 2) & 3)
        guard version != 1, layer == 1, (1...14).contains(bitrateIndex), rateIndex < 3 else { return nil }
        let rates = [44_100, 48_000, 32_000]
        let kilobits = version == 3
            ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320][bitrateIndex]
            : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160][bitrateIndex]
        let rate = rates[rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        return (version == 3 ? 144_000 : 72_000) * kilobits / rate + Int((bytes[offset + 2] >> 1) & 1)
    }
    private static func parseAlignment(_ raw: Any?, text: String, duration: Double) throws -> [VoiceLabCharacterTiming] {
        guard let row = raw as? [String: Any], let characters = row["characters"] as? [String],
              let starts = row["character_start_times_seconds"] as? [Double],
              let ends = row["character_end_times_seconds"] as? [Double],
              !characters.isEmpty, characters.count == starts.count, starts.count == ends.count,
              characters.joined() == text else { throw VoiceLabError.invalidAlignment }
        var previous = 0.0
        return try characters.indices.map { index in
            let start = starts[index], end = ends[index]
            guard !characters[index].isEmpty, start.isFinite, end.isFinite, start >= previous, end >= start,
                  end <= duration + 0.05 else { throw VoiceLabError.invalidAlignment }
            previous = end
            return VoiceLabCharacterTiming(character: characters[index], start: start, end: end)
        }
    }
}

private final class VoiceLabNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
