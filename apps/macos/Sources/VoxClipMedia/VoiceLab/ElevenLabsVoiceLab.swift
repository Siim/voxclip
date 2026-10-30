import Foundation
import VoxClipCore

/// Explicit, region-bound Voice Lab transport. Mutations are sent once, including on 429/5xx.
public actor ElevenLabsVoiceLab {
    public nonisolated let region: ElevenLabsRegion
    private let keys: any KeyProvider
    private let session: URLSession
    private let logger: any Redacting
    private let spend: VoiceLabSpendLedger?
    private var discoveredModels: [String: VoiceLabModel] = [:]
    private var discoveredVoices: [String: VoiceLabVoice] = [:]
    private var subscription: VoiceLabSubscription?
    private var prepared: [UUID: VoiceLabQuote] = [:]
    private var creatorBindings: [UUID: String] = [:]
    public func creatorKeyFingerprint() async throws -> String {
        guard let key = try await keys.key(for: "elevenlabs"), !key.isEmpty else { throw VoiceLabError.missingKey }
        return String(VoiceLabFingerprint.bytes(Data(key.utf8)).prefix(16))
    }
    public func validateCreationQuote(_ quote: VoiceLabQuote) async throws -> String {
        guard quote.operation == .createClone, prepared[quote.id] == quote, fresh(quote) else { throw VoiceLabError.consentRequired }
        let fingerprint = try await creatorKeyFingerprint()
        let plan = try await plan()
        guard plan.canClone else { throw VoiceLabError.planUnavailable }
        guard plan.voiceSlotsUsed < plan.voiceLimit else { throw VoiceLabError.noVoiceSlots }
        guard prepared[quote.id] == quote, fresh(quote) else { throw VoiceLabError.consentRequired }
        creatorBindings[quote.id] = fingerprint
        return fingerprint
    }
    private var preparedOrder: [UUID] = []
    private var approvedRuns: [UUID: Set<UUID>] = [:]
    private var now: @Sendable () -> Date = { Date() }
    private var monotonic: @Sendable () -> Duration = VoiceLabQuoteClock.continuousSource()
    private var deadlines: [UUID: Duration] = [:]
    private var discoveryRevision = 0
    private var prices: VoiceLabPriceCatalog?
    private var fixedBoundary: String?
    private var afterLastByte: (@Sendable () -> Void)?
    #if DEBUG
    private var enforceCapabilities = true
    private var dispatchHook: (@Sendable () async -> Void)?
    package func useDispatchHook(_ hook: @escaping @Sendable () async -> Void) { dispatchHook = hook }
    #endif
    #if DEBUG
    @_spi(Testing) public func useClock(_ clock: @escaping @Sendable () -> Date, monotonic: @escaping @Sendable () -> Duration) {
        now = clock; self.monotonic = monotonic
    }
    #endif
    private let maxUpload = 16 * 1_024 * 1_024
    /// Up to 25 clone files of at most `maxUpload` bytes each, with multipart framing.
    private let maxRequest = 25 * (16 * 1_024 * 1_024 + 1_024)
    private let maxResponse = 32 * 1_024 * 1_024

    /// `prices` defaults to `shared/catalog/voice-lab.json`, read on the first estimate. Each action the provider accepts is
    /// recorded in `spend`, `<data>/VoiceLab/spend.json` by default; voice-lab §3.1.
    public init(keys: any KeyProvider, region: ElevenLabsRegion, logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path),
                prices: VoiceLabPriceCatalog? = nil, spend: VoiceLabSpendLedger = VoiceLabSpendLedger(locations: DataLocations())) {
        self.keys = keys; self.region = region; self.logger = logger; self.prices = prices; self.spend = spend
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: configuration)
    }
    #if DEBUG
    package init(keys: any KeyProvider, session: URLSession, region: ElevenLabsRegion = .default, logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path),
         prices: VoiceLabPriceCatalog? = nil, spend: VoiceLabSpendLedger? = nil, enforceCapabilities: Bool = false) {
        self.keys = keys; self.session = session; self.region = region; self.logger = logger; self.prices = prices; self.spend = spend
        self.enforceCapabilities = enforceCapabilities
    }
    #endif
    private func capability(_ policy: OwnVoicePolicy) throws -> VoiceOperationCapability? {
        if let capability = policy.capability { return capability }
        #if DEBUG
        if !enforceCapabilities { return nil }
        #endif
        throw VoiceLabError.consentRequired
    }
    private func capability(_ voice: VoiceLabVoiceChoice) throws -> VoiceOperationCapability? {
        if case .own(_, let policy) = voice { return try capability(policy) }
        return nil
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
                                 characterCostMultiplier: try Self.characterCostMultiplier(row["model_rates"]))
        }
        guard !models.isEmpty else { throw VoiceLabError.malformedResponse }
        var indexed: [String: VoiceLabModel] = [:]
        for model in models {
            guard indexed.updateValue(model, forKey: model.id) == nil else { throw VoiceLabError.malformedResponse }
        }
        discoveredModels = indexed
        discoveryRevision += 1
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
            components.queryItems = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "next_page_token", value: cursor)) }
            let data = try await send(components.url!, method: "GET", limit: 4 * 1_024 * 1_024)
            guard let row = try? JSONSerialization.jsonObject(with: data.bytes) as? [String: Any],
                  let voices = row["voices"] as? [[String: Any]], let more = row["has_more"] as? Bool else { throw VoiceLabError.malformedResponse }
            for item in voices {
                guard let id = item["voice_id"] as? String, Self.safeID(id) else { throw VoiceLabError.malformedResponse }
                guard let name = item["name"] as? String, let category = item["category"] as? String else { continue }
                let verification = item["voice_verification"] as? [String: Any] ?? [:]
                guard seenVoiceIDs.insert(id).inserted else { throw VoiceLabError.malformedResponse }
                result.append(VoiceLabVoice(id: id, name: name, category: category, isOwner: item["is_owner"] as? Bool == true,
                                            requiresVerification: verification["requires_verification"] as? Bool == true,
                                            isVerified: verification["is_verified"] as? Bool == true,
                                            consentRecordID: (item["labels"] as? [String: String])?["voxclip_record_id"],
                                            createdAt: (item["created_at_unix"] as? NSNumber).flatMap { number in
                                                let seconds = number.doubleValue
                                                return CFGetTypeID(number) != CFBooleanGetTypeID() && seconds.isFinite && seconds >= 0 && seconds <= 253_402_300_799
                                                    ? Date(timeIntervalSince1970: seconds) : nil
                                            }))
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

    /// The catalog estimate (voice-lab §3.2) for `units` of an ElevenLabs operation: seconds of audio, characters
    /// (Unicode scalars) of text or one call. TTS uses the selected model's discovered character multiplier, so call
    /// `models()` first; `candidates` prices a run of takes (§8.6), although each take is still quoted on its own.
    public func estimate(_ operation: VoiceLabOperation, modelID: String?, units: Double, candidates: Int = 1) throws -> CostEstimate {
        let priced: VoiceLabPricedOperation
        switch operation {
        case .createClone: priced = .elevenLabsCreateClone
        case .deleteClone: priced = .elevenLabsDeleteClone
        case .textToSpeech: priced = .elevenLabsTextToSpeech
        case .voiceChange: priced = .elevenLabsVoiceChange
        case .speechToText: priced = .elevenLabsSpeechToText
        }
        let catalog = try prices ?? VoiceLabPriceCatalog.load(shared: SharedResources.locate())
        prices = catalog
        return try VoiceLabPricing.estimate(operation: priced, model: modelID, units: units, candidates: candidates,
                                            characterMultiplier: modelID.flatMap { discoveredModels[$0]?.characterCostMultiplier },
                                            catalog: catalog)
    }

    private func quote(_ operation: VoiceLabOperation, requestID: UUID, endpoint: String,
                       fields: [String], model: String? = nil, units: Double,
                       languageMode: VoiceLabLanguageMode? = nil, guardAudioHash: String? = nil) throws -> VoiceLabQuote {
        guard units > 0 else { throw VoiceLabError.invalidInput }
        let estimate = try estimate(operation, modelID: model, units: units)
        let value = VoiceLabQuote(id: UUID(), operation: operation, requestID: requestID, estimate: estimate,
                                  region: region, endpoint: endpoint, languageMode: languageMode,
                                  fingerprint: VoiceLabFingerprint.fields(fields), guardAudioHash: guardAudioHash,
                                  preparedAt: now(), modelID: model)
        if preparedOrder.count >= 32 {
            guard let oldest = preparedOrder.first(where: { candidate in !approvedRuns.values.contains(where: { $0.contains(candidate) }) }) else { throw VoiceLabError.invalidInput }
            prepared.removeValue(forKey: oldest); preparedOrder.removeAll { $0 == oldest }
            deadlines.removeValue(forKey: oldest)
        }
        prepared[value.id] = value
        deadlines[value.id] = monotonic() + .seconds(300)
        preparedOrder.append(value.id)
        return value
    }

    /// Preparation is local. Discovery and subscription reads must be initiated separately.
    public func prepareClone(_ request: VoiceLabCloneRequest, policy: OwnVoicePolicy, requestID: UUID) throws -> VoiceLabQuote {
        try policy.validate()
        guard let subscription, subscription.canClone else { throw VoiceLabError.planUnavailable }
        guard subscription.voiceSlotsUsed < subscription.voiceLimit else { throw VoiceLabError.noVoiceSlots }
        return try quote(.createClone, requestID: requestID, endpoint: "v1/voices/add",
                         fields: cloneUpload(request, policy).fields, units: 1)
    }

    public func prepareDelete(voiceID: String, policy: OwnVoicePolicy, requestID: UUID) throws -> VoiceLabQuote {
        try policy.validate()
        guard policy.cloneVoiceID == voiceID, Self.safeID(voiceID), let voice = discoveredVoices[voiceID],
              voice.isOwner, voice.category == "cloned" else { throw VoiceLabError.consentRequired }
        return try quote(.deleteClone, requestID: requestID, endpoint: "v1/voices/\(voiceID)",
                         fields: deleteFields(voiceID, policy), units: 1)
    }

    func prepareOperationDeletion(_ operation: VoiceOperation, requestID: UUID) async throws -> VoiceLabQuote {
        guard let voiceID = operation.remoteVoiceID, operation.region == region else { throw VoiceConsentError.invalidRecord }
        let fingerprint = try await creatorKeyFingerprint()
        guard operation.creatorKeyFingerprint == nil || operation.creatorKeyFingerprint == fingerprint else { throw VoiceConsentError.creatorMismatch }
        discoveredVoices[voiceID] = VoiceLabVoice(id: voiceID, name: "", category: "cloned", isOwner: true, requiresVerification: false, isVerified: false)
        let policy = OwnVoicePolicy(recordID: operation.recordID, cloneVoiceID: voiceID, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let quote = try prepareDelete(voiceID: voiceID, policy: policy, requestID: requestID)
        creatorBindings[quote.id] = fingerprint
        return quote
    }

    public func prepareConsentDeletion(_ record: VoiceConsentRecord, requestID: UUID) async throws -> VoiceLabQuote {
        try record.validate()
        let fingerprint = try await creatorKeyFingerprint()
        guard (record.region ?? .default) == region, record.creatorKeyFingerprint == nil || record.creatorKeyFingerprint == fingerprint else { throw VoiceConsentError.creatorMismatch }
        guard record.status != .deleted else { throw VoiceConsentError.inactive }
        discoveredVoices[record.voiceId] = VoiceLabVoice(id: record.voiceId, name: record.voiceName, category: "cloned", isOwner: true,
                                                      requiresVerification: record.status == .verificationRequired, isVerified: record.status == .active)
        let policy = OwnVoicePolicy(recordID: record.id, cloneVoiceID: record.voiceId, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let quote = try prepareDelete(voiceID: record.voiceId, policy: policy, requestID: requestID)
        creatorBindings[quote.id] = fingerprint
        return quote
    }

    public func prepareSynthesis(text: String, modelID: String, voice: VoiceLabVoiceChoice, language: String,
                                 options: VoiceLabSpeechOptions, requestID: UUID) throws -> VoiceLabQuote {
        try voice.validate()
        let model = try selectedModel(modelID, language: language, speak: true)
        guard !text.isEmpty, text.unicodeScalars.count <= min(model.maximumTextLength ?? 5_000, 5_000),
              Self.safeID(voice.id) else { throw VoiceLabError.invalidInput }
        try selectedVoice(voice)
        return try quote(.textToSpeech, requestID: requestID, endpoint: "v1/text-to-speech/\(voice.id)/with-timestamps",
                         fields: speechFields(text, modelID, voice, language, options),
                         model: modelID, units: Double(text.unicodeScalars.count),
                         languageMode: modelID == "eleven_multilingual_v2" ? .autoDetected(expected: language) : .explicit(language))
    }

    public func prepareConversion(audio: Data, modelID: String, voice: VoiceLabVoiceChoice, language: String,
                                  seed: UInt32, cleanAudioOn: Bool, requestID: UUID) throws -> VoiceLabQuote {
        try voice.validate()
        _ = try selectedModel(modelID, language: language, speak: false)
        try selectedVoice(voice)
        let format = try Self.validateWAV(audio, maxBytes: maxUpload)
        return try quote(.voiceChange, requestID: requestID, endpoint: "v1/voice-changer/\(voice.id)",
                         fields: conversionFields(audio, modelID, voice, language, seed, cleanAudioOn),
                         model: modelID, units: Double(format.frames) / Double(format.rate),
                         languageMode: .autoDetected(expected: language), guardAudioHash: VoiceLabFingerprint.bytes(audio))
    }

    /// WAV only until spike S5: 1–25 complete mono PCM16 files of 5–30 s, 10–240 s in total, with exactly one consent statement.
    private func cloneUpload(_ request: VoiceLabCloneRequest, _ policy: OwnVoicePolicy) throws -> (fields: [String], parts: [Part]) {
        let name = Self.trimWhiteSpace(request.displayName)
        let seconds = request.createdAt.timeIntervalSince1970.rounded(.down)
        let consent = request.samples.filter { $0.role == .consentStatement }
        // §6.1 display name: 1 to 60 Unicode scalars after trimming Unicode White_Space, with no control character
        // (General Category Cc) left in it; the trimmed name is sent and bound.
        guard (1...60).contains(name.unicodeScalars.count), !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              request.language.range(of: #"\A[a-z]{2,3}\z"#, options: .regularExpression) != nil,
              seconds >= 0, seconds <= 253_402_300_799, (1...25).contains(request.samples.count), consent.count == 1 else {
            throw VoiceLabError.invalidInput
        }
        var total = 0.0
        for sample in request.samples {
            guard let format = try? Self.validateWAV(sample.wav, maxBytes: maxUpload),
                  format.frames >= 5 * format.rate, format.frames <= 30 * format.rate else { throw VoiceLabError.invalidInput }
            total += Double(format.frames) / Double(format.rate)
        }
        guard total >= 10, total <= 240 else { throw VoiceLabError.invalidInput }
        let created = Date(timeIntervalSince1970: seconds).formatted(.iso8601)
        let consentHash = VoiceLabFingerprint.bytes(consent[0].wav)
        if let nonce = request.recoveryNonce, UUID(uuidString: nonce) == nil { throw VoiceLabError.invalidInput }
        var fields = [region.rawValue, "v1/voices/add", name, request.language, created, String(request.removeBackgroundNoise), String(request.samples.count)]
        if let nonce = request.recoveryNonce { fields.append(nonce) }
        for (index, sample) in request.samples.enumerated() {
            fields += [String(index), sample.role.rawValue, VoiceLabFingerprint.bytes(sample.wav)]
        }
        var parts: [Part] = [.text("name", "\(name) (VoxClip)"), .file("files", "consent-statement.wav", consent[0].wav)]
        for (index, sample) in request.samples.filter({ $0.role == .training }).enumerated() {
            parts.append(.file("files", "sample-\(index < 8 ? "0" : "")\(index + 2).wav", sample.wav))
        }
        var labels = "{\"language\":\"\(request.language)\"}"
        var description = "VoxClip own-voice clone. Consent sha256:\(consentHash). Created \(created)."
        if let nonce = request.recoveryNonce {
            labels = "{\"language\":\"\(request.language)\",\"voxclip_record_id\":\"\(nonce)\"}"
            description += " VoxClip request \(nonce)."
        }
        parts += [.text("remove_background_noise", String(request.removeBackgroundNoise)), .text("description", description), .text("labels", labels)]
        return (fields + VoiceLabFingerprint.policy(policy), parts)
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
    private func speechFields(_ text: String, _ model: String, _ voice: VoiceLabVoiceChoice, _ language: String, _ options: VoiceLabSpeechOptions) -> [String] {
        // Trimmed context is never empty, so "" stands for an omitted field.
        [region.rawValue, "v1/text-to-speech/\(voice.id)/with-timestamps", "pcm_24000", text, model, language, String(options.seed),
         model == "eleven_v3" ? "" : Self.speechContext(options.previousText, previous: true) ?? "",
         model == "eleven_v3" ? "" : Self.speechContext(options.nextText, previous: false) ?? ""] + voiceFields(voice)
    }
    /// Removes Unicode White_Space at both ends. Foundation's whitespace sets differ: they also hold U+200B.
    private static func trimWhiteSpace(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        return String(scalars[first...last])
    }
    /// Voice-lab §8.5 context: Unicode White_Space is removed at both ends, then the last (previous) or first (next)
    /// 300 Unicode scalars are kept. If they hold White_Space, a word split by the cut is dropped first. Then the cut
    /// moves until it splits no cluster: previous text drops orphaned marks and joiners, next text drops a partial
    /// cluster back to its base. Nil means the field is omitted.
    private static func speechContext(_ text: String?, previous: Bool) -> String? {
        guard let text else { return nil }
        let scalars = Array(text.unicodeScalars)
        func space(_ index: Int) -> Bool { scalars[index].properties.isWhitespace }
        /// Combining marks (General Category M), ZWJ and variation selectors extend the cluster before them.
        func extends(_ index: Int) -> Bool {
            let scalar = scalars[index]
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
            }
        }
        /// A cut before `index` splits a cluster when that scalar extends one or follows a ZWJ.
        func splits(_ index: Int) -> Bool { extends(index) || scalars[index - 1].value == 0x200D }
        var start = 0, end = scalars.count
        while start < end && space(start) { start += 1 }
        while end > start && space(end - 1) { end -= 1 }
        if end - start > 300 {
            if previous { start = end - 300 } else { end = start + 300 }
            if (start..<end).contains(where: space) {
                if previous && !space(start - 1) { while start < end && !space(start) { start += 1 } }
                if !previous && !space(end) { while end > start && !space(end - 1) { end -= 1 } }
            }
            if previous {
                while start < end && splits(start) { start += 1 }
            } else {
                while end > start && splits(end) { end -= 1 }
            }
        }
        guard start < end else { return nil }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars[start..<end])
        return String(kept)
    }
    private func conversionFields(_ audio: Data, _ model: String, _ voice: VoiceLabVoiceChoice, _ language: String,
                                  _ seed: UInt32, _ cleanAudioOn: Bool) -> [String] {
        [region.rawValue, "v1/voice-changer/\(voice.id)", "pcm_24000", VoiceLabFingerprint.bytes(audio), model, language,
         String(seed), String(cleanAudioOn)] + voiceFields(voice)
    }

    private func claim(_ authorization: VoiceLabAuthorization, operation: VoiceLabOperation,
                       requestID: UUID, endpoint: String, fields: [String]) throws {
        let value = authorization.quote
        guard authorization.approved, value.operation == operation, value.requestID == requestID,
              value.region == region, value.endpoint == endpoint,
              value.fingerprint == VoiceLabFingerprint.fields(fields), prepared[value.id] == value,
              fresh(value) || approvedRuns.values.contains(where: { $0.contains(value.id) }),
              try estimate(operation, modelID: value.modelID, units: value.estimate.units) == value.estimate else {
            throw VoiceLabError.consentRequired
        }
        prepared.removeValue(forKey: value.id)
        deadlines.removeValue(forKey: value.id)
        preparedOrder.removeAll { $0 == value.id }
    }

    func modelRevision() -> Int { discoveryRevision }
    private func fresh(_ quote: VoiceLabQuote) -> Bool {
        guard prepared[quote.id] == quote, let deadline = deadlines[quote.id] else { return false }
        return monotonic() < deadline
    }
    func quotesAreFresh(_ quotes: [VoiceLabQuote]) -> Bool { !quotes.isEmpty && quotes.allSatisfy { fresh($0) } }
    func approveRun(_ id: UUID, quotes: [VoiceLabQuote]) throws {
        guard approvedRuns[id] == nil, !quotes.isEmpty,
              quotesAreFresh(quotes) else { throw VoiceLabError.consentRequired }
        approvedRuns[id] = Set(quotes.map(\.id))
    }
    func discardRun(_ id: UUID, quotes: [VoiceLabQuote]) {
        for quote in quotes { prepared.removeValue(forKey: quote.id); deadlines.removeValue(forKey: quote.id) }
        let ids = Set(quotes.map(\.id))
        preparedOrder.removeAll { ids.contains($0) }
        approvedRuns.removeValue(forKey: id)
    }
    func prepareQA(language: String, requestID: UUID) throws -> VoiceLabQuote {
        guard language.range(of: #"\A[a-z]{2,3}\z"#, options: .regularExpression) != nil else { throw VoiceLabError.invalidInput }
        return try quote(.speechToText, requestID: requestID, endpoint: "v1/speech-to-text",
                         fields: [region.rawValue, "scribe_v2", language, String(VoiceLabTakeProcessing.maximumQASeconds)],
                         model: "scribe_v2", units: VoiceLabTakeProcessing.maximumQASeconds, languageMode: .explicit(language))
    }
    public func prepareConsentVerification(wav: Data, language: String, requestID: UUID) throws -> VoiceLabQuote {
        _ = try VoiceConsentAudio.pcm16k(wav)
        guard ["en", "et"].contains(language) else { throw VoiceLabError.invalidInput }
        let seconds = Double((wav.count - 44) / 2) / 16_000
        return try quote(.speechToText, requestID: requestID, endpoint: "v1/speech-to-text",
            fields: [region.rawValue, "scribe_v2", language, VoiceLabFingerprint.bytes(wav)],
            model: "scribe_v2", units: seconds, languageMode: .explicit(language))
    }
    public func transcribeConsentStatement(wav: Data, language: String, authorization: VoiceLabAuthorization) async throws -> RawTranscript {
        _ = try VoiceConsentAudio.pcm16k(wav)
        let boundary = newBoundary()
        let parts: [Part] = [.text("model_id", "scribe_v2"), .text("language_code", language),
            .text("tag_audio_events", "false"), .text("diarize", "false"), .text("timestamps_granularity", "word"), .file("file", "statement.wav", wav)]
        let body = try multipart(parts, boundary: boundary, limit: maxRequest)
        try claim(authorization, operation: .speechToText, requestID: authorization.requestID, endpoint: "v1/speech-to-text",
            fields: [region.rawValue, "scribe_v2", language, VoiceLabFingerprint.bytes(wav)])
        let reply = try await send("v1/speech-to-text", method: "POST", body: body,
            contentType: "multipart/form-data; boundary=\"\(boundary)\"", limit: maxResponse, billing: authorization)
        let mapper = ElevenLabsTranscriber(keys: keys, region: region, logger: logger)
        return try await mapper.mapResponse(reply.bytes, diarize: false)
    }
    func transcribeQA(_ samples: [Float], rate: Int, language: String, authorization: VoiceLabAuthorization,
                      capability: VoiceOperationCapability) async throws -> (words: [VoiceLabWord], receipt: VoiceLabReceipt) {
        guard rate == 24_000, !samples.isEmpty, samples.count <= Int(VoiceLabTakeProcessing.maximumQASeconds) * rate else { throw VoiceLabError.invalidAudio }
        let wav = try VoiceLabTakeWAV.encode(samples, rate: rate)
        let boundary = newBoundary()
        let parts: [Part] = [.text("model_id", "scribe_v2"), .text("language_code", language),
                            .text("tag_audio_events", "false"), .text("diarize", "false"),
                            .text("timestamps_granularity", "word"), .file("file", "qa.wav", wav)]
        let body = try multipart(parts, boundary: boundary, limit: maxRequest)
        try Task.checkCancellation()
        try claim(authorization, operation: .speechToText, requestID: authorization.requestID, endpoint: "v1/speech-to-text",
                  fields: [region.rawValue, "scribe_v2", language, String(VoiceLabTakeProcessing.maximumQASeconds)])
        let reply = try await send("v1/speech-to-text", method: "POST", body: body,
            contentType: "multipart/form-data; boundary=\"\(boundary)\"", limit: maxResponse, billing: authorization, capability: capability)
        guard let object = try? JSONSerialization.jsonObject(with: reply.bytes) as? [String: Any],
              let detected = object["language_code"] as? String, let words = object["words"] as? [[String: Any]] else { throw VoiceLabError.malformedResponse }
        let catalog = try BundledModelCatalog(shared: SharedResources.locate())
        guard try await catalog.normalizeLanguage(detected) == language else { throw VoiceLabError.malformedResponse }
        var result: [VoiceLabWord] = []
        var previous = 0.0
        for word in words where word["type"] as? String == "word" {
            guard let text = word["text"] as? String, !text.isEmpty, let start = word["start"] as? Double, let end = word["end"] as? Double,
                  start.isFinite, end.isFinite, start >= previous, end > start, end <= Double(samples.count) / Double(rate) else { throw VoiceLabError.malformedResponse }
            result.append(VoiceLabWord(text: text, start: start, end: end, synthetic: true)); previous = end
        }
        return (result, receipt("v1/speech-to-text", model: "scribe_v2", voice: nil, authorization: authorization, reply: reply))
    }

    public func createOwnClone(_ request: VoiceLabCloneRequest, policy: OwnVoicePolicy,
                               requestID: UUID, authorization: VoiceLabAuthorization) async throws -> VoiceLabCloneResult {
        try policy.validate()
        let capability = try capability(policy)
        guard let subscription else { throw VoiceLabError.planUnavailable }
        guard subscription.canClone else { throw VoiceLabError.planUnavailable }
        guard subscription.voiceSlotsUsed < subscription.voiceLimit else { throw VoiceLabError.noVoiceSlots }
        let upload = try cloneUpload(request, policy)
        let boundary = newBoundary()
        let body = try multipart(upload.parts, boundary: boundary, limit: maxRequest)
        try claim(authorization, operation: .createClone, requestID: requestID, endpoint: "v1/voices/add", fields: upload.fields)
        let reply = try await send("v1/voices/add", method: "POST", body: body, contentType: "multipart/form-data; boundary=\"\(boundary)\"", limit: 128 * 1_024,
                                   billing: authorization, capability: capability)
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
        let reply = try await send(path, method: "DELETE", limit: 128 * 1_024, billing: authorization)
        guard let row = try? JSONSerialization.jsonObject(with: reply.bytes) as? [String: Any],
              row["status"] as? String == "ok" else { throw VoiceLabError.malformedResponse }
        discoveredVoices.removeValue(forKey: voiceID)
        return receipt(path, model: nil, voice: voiceID, authorization: authorization, reply: reply)
    }

    public func synthesize(text: String, modelID: String, voice: VoiceLabVoiceChoice, language: String, options: VoiceLabSpeechOptions,
                           requestID: UUID, authorization: VoiceLabAuthorization) async throws -> VoiceLabAudioResult {
        try Task.checkCancellation()
        try voice.validate()
        let capability = try capability(voice)
        let model = try selectedModel(modelID, language: language, speak: true)
        let count = text.unicodeScalars.count
        guard count > 0, count <= min(model.maximumTextLength ?? 5_000, 5_000), Self.safeID(voice.id) else { throw VoiceLabError.invalidInput }
        try selectedVoice(voice)
        let path = "v1/text-to-speech/\(voice.id)/with-timestamps"
        var components = URLComponents(url: region.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        // Voice settings are spec constants (§8.5), not caller choices.
        var payload: [String: Any] = ["text": text, "model_id": modelID, "voice_settings": ["stability": 0.5, "similarity_boost": 0.8],
                                      "seed": Int(options.seed), "apply_text_normalization": "auto"]
        if modelID != "eleven_multilingual_v2" { payload["language_code"] = language }
        if modelID != "eleven_v3" {
            if let previous = Self.speechContext(options.previousText, previous: true) { payload["previous_text"] = previous }
            if let next = Self.speechContext(options.nextText, previous: false) { payload["next_text"] = next }
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        try claim(authorization, operation: .textToSpeech, requestID: requestID, endpoint: path,
                  fields: speechFields(text, modelID, voice, language, options))
        let reply = try await send(components.url!, method: "POST", body: body, contentType: "application/json", limit: maxResponse, billing: authorization, capability: capability)
        guard let row = try? JSONSerialization.jsonObject(with: reply.bytes) as? [String: Any],
              let base64 = row["audio_base64"] as? String, let pcm = Data(base64Encoded: base64) else { throw VoiceLabError.invalidAudio }
        try Self.validatePCM(pcm, maxBytes: maxResponse)
        let timing = try Self.parseAlignment(row["alignment"], text: text, duration: Double(pcm.count) / 48_000)
        return VoiceLabAudioResult(pcm: pcm, sampleRate: 24_000, alignment: timing,
                                   receipt: receipt(path, model: modelID, voice: voice.id, authorization: authorization, reply: reply))
    }

    /// A reviewed rewrite is generated only by this separate, explicitly approved call.
    public func synthesize(proposal: VoiceRewriteProposal, modelID: String, voice: VoiceLabVoiceChoice, language: String,
                           options: VoiceLabSpeechOptions, authorization: VoiceLabAuthorization) async throws -> VoiceLabAudioResult {
        try await synthesize(text: proposal.proposedText, modelID: modelID, voice: voice, language: language, options: options,
                             requestID: proposal.id, authorization: authorization)
    }

    public func convert(audio: Data, modelID: String, voice: VoiceLabVoiceChoice, language: String, seed: UInt32, cleanAudioOn: Bool,
                        requestID: UUID, authorization: VoiceLabAuthorization) async throws -> VoiceLabAudioResult {
        try voice.validate()
        let capability = try capability(voice)
        _ = try selectedModel(modelID, language: language, speak: false)
        try selectedVoice(voice)
        try Self.validateWAV(audio, maxBytes: maxUpload)
        guard Self.safeID(voice.id) else { throw VoiceLabError.invalidInput }
        let path = "v1/voice-changer/\(voice.id)"
        var components = URLComponents(url: region.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        let boundary = newBoundary()
        // Voice settings are spec constants (§7.3). Clean audio already removed the noise, so it is not removed twice.
        let body = try multipart([.file("audio", "audio.wav", audio), .text("model_id", modelID),
                                  .text("voice_settings", #"{"stability":0.5,"similarity_boost":0.75}"#),
                                  .text("seed", String(seed)), .text("remove_background_noise", String(!cleanAudioOn))],
                                 boundary: boundary, limit: maxUpload + 1_024)
        try claim(authorization, operation: .voiceChange, requestID: requestID, endpoint: path,
                  fields: conversionFields(audio, modelID, voice, language, seed, cleanAudioOn))
        let reply = try await send(components.url!, method: "POST", body: body, contentType: "multipart/form-data; boundary=\"\(boundary)\"", limit: maxResponse,
                                   billing: authorization, capability: capability)
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
                               requestID: authorization.requestID, providerRequestID: remote, spendWarning: reply.spendWarning)
    }
    /// Starts recording the approved quote's estimate; voice-lab §3.1. The record runs detached, off this actor and the main
    /// actor, so the caller's cancellation cannot stop it. Its warning is logged and never fails the action. Nil without a ledger.
    private func record(_ authorization: VoiceLabAuthorization, at start: Date) -> Task<VoiceLabSpendWarning?, Never>? {
        guard let spend else { return nil }
        let estimate = authorization.estimate, logger = self.logger
        return Task.detached {
            let warning = await spend.record(estimate, at: start)
            if let warning { await logger.write(LogEntry(level: .warn, category: "voice-lab", message: "Spend ledger: \(warning)")) }
            return warning
        }
    }
    /// Tests cancel here, after the last byte of a reply and before `send` returns it.
    func runAfterLastByte(_ hook: (@Sendable () -> Void)?) { afterLastByte = hook }
    private struct Reply { let bytes: Data; let response: HTTPURLResponse; let spendWarning: VoiceLabSpendWarning? }
    private func send(_ path: String, method: String, body: Data? = nil, contentType: String? = nil, limit: Int,
                      billing: VoiceLabAuthorization? = nil, capability: VoiceOperationCapability? = nil) async throws -> Reply {
        try await send(region.baseURL.appendingPathComponent(path), method: method, body: body, contentType: contentType, limit: limit, billing: billing, capability: capability)
    }
    /// `billing` is the approved action the request runs. Its 2xx status line is the provider's acceptance, so the estimate is
    /// recorded once from then on however the body ends, and the record finishes before `send` returns or throws (§3.1).
    private func send(_ url: URL, method: String, body: Data? = nil, contentType: String? = nil, limit: Int,
                      billing: VoiceLabAuthorization? = nil, capability: VoiceOperationCapability? = nil) async throws -> Reply {
        try Task.checkCancellation()
        guard url.scheme == "https", url.host == region.baseURL.host, body?.count ?? 0 <= maxRequest else { throw VoiceLabError.invalidInput }
        guard let key = try await keys.key(for: "elevenlabs"), !key.isEmpty else { throw VoiceLabError.missingKey }
        if let billing, let expected = creatorBindings.removeValue(forKey: billing.quote.id) {
            guard String(VoiceLabFingerprint.bytes(Data(key.utf8)).prefix(16)) == expected else { throw VoiceConsentError.creatorMismatch }
        }
        await logger.register(secret: key)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 300
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("VoxClip/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let permit: VoiceOperationDispatch?
        if let capability {
            guard let billing else { throw VoiceLabError.consentRequired }
            permit = try await capability.consume(billing.quote)
        } else { permit = nil }
        defer { permit?.finish() }
        #if DEBUG
        if capability != nil { await dispatchHook?() }
        #endif
        let relay = VoiceLabHTTPStream(limit: limit)
        let transport = session.dataTask(with: request)
        transport.delegate = relay
        let start = Date()
        var recording: Task<VoiceLabSpendWarning?, Never>?
        do {
            try Task.checkCancellation()
            if let permit { try await permit.start { transport.resume() } } else { transport.resume() }
            defer { transport.cancel() }
            var response: HTTPURLResponse?
            var bytes = Data()
            try await withTaskCancellationHandler {
                for try await event in relay.stream {
                    switch event {
                    case .response(let http):
                        response = http
                        if let billing, (200..<300).contains(http.statusCode) { recording = record(billing, at: start) }
                        if let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), size > limit { throw VoiceLabError.responseTooLarge }
                    case .data(let data):
                        try Task.checkCancellation()
                        guard data.count <= limit - bytes.count else { throw VoiceLabError.responseTooLarge }
                        bytes.append(data)
                    }
                }
            } onCancel: { transport.cancel() }
            guard relay.completed(bytes: bytes.count) else {
                try Task.checkCancellation()
                throw VoiceLabError.malformedResponse
            }
            guard let http = response else { throw VoiceLabError.malformedResponse }
            afterLastByte?()
            if method == "DELETE", url.path.hasPrefix("/v1/voices/"), http.statusCode == 404 {
                return Reply(bytes: Data("{\"status\":\"ok\"}".utf8), response: http, spendWarning: nil)
            }
            // A complete 2xx reply is kept even if the task was cancelled after its last byte.
            guard (200..<300).contains(http.statusCode) else {
                try Task.checkCancellation()
                throw Self.mapError(http.statusCode, bytes, path: url.path, method: method)
            }
            return Reply(bytes: bytes, response: http, spendWarning: await recording?.value)
        } catch {
            if recording == nil, let billing, let response = relay.receivedResponse, (200..<300).contains(response.statusCode) {
                recording = record(billing, at: start)
            }
            // An accepted action is counted before its error reaches the caller.
            _ = await recording?.value
            if error is CancellationError { throw VoiceLabError.cancelled }
            if let error = error as? VoiceLabError { throw error }
            if error is VoiceConsentError { throw error }
            if Task.isCancelled { throw VoiceLabError.cancelled }
            throw VoiceLabError.network
        }
    }
    private static func mapError(_ status: Int, _ body: Data, path: String, method: String) -> VoiceLabError {
        let text = String(decoding: body.prefix(16_384), as: UTF8.self).lowercased()
        if text.contains("quota") || text.contains("credit") { return .quotaExceeded }
        if status == 403 {
            if text.contains("subscription_required") { return .subscriptionRequired }
            if text.contains("feature_not_available") { return .featureUnavailable }
            if text.contains("voice_access_denied") { return .voiceAccessDenied }
            if text.contains("model_access_denied") { return .modelAccessDenied }
        }
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
    /// `\A…\z`, not `^…$`: ICU lets `$` match before a final line break, which would put "voice\n" into a path.
    private static func safeID(_ value: String) -> Bool { value.range(of: #"\A[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil }
    /// `model_rates.character_cost_multiplier`, the credit multiplier for TTS (§3.2). Absent or null rates mean 1; anything
    /// but a number from 0.01 to 100 is malformed, as on Windows.
    private static func characterCostMultiplier(_ rates: Any?) throws -> Double? {
        guard let rates, !(rates is NSNull) else { return nil }
        guard let object = rates as? [String: Any] else { throw VoiceLabError.malformedResponse }
        guard let value = object["character_cost_multiplier"] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              VoiceLabPricing.characterMultiplierRange.contains(number.doubleValue) else { throw VoiceLabError.malformedResponse }
        return number.doubleValue
    }
    /// Tests fix the boundary so whole multipart bodies can be compared with the shared request goldens.
    func useMultipartBoundary(_ boundary: String) { fixedBoundary = boundary }
    /// Windows Core uses the same form and quoting, so both write the same bytes for the same boundary.
    private func newBoundary() -> String {
        fixedBoundary ?? "voxclip-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    /// Multipart parts in send order. Text parts carry no Content-Type; a file part has Content-Disposition, then
    /// Content-Type, as on Windows.
    private enum Part { case text(String, String), file(String, String, Data) }
    private func multipart(_ parts: [Part], boundary: String, limit: Int) throws -> Data {
        var result = Data()
        for part in parts {
            switch part {
            case .text(let field, let value):
                guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }), value.utf8.count <= 256 else { throw VoiceLabError.invalidInput }
                result.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n".utf8))
            case .file(let field, let filename, let file):
                result.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
                result.append(file)
                result.append(Data("\r\n".utf8))
            }
        }
        result.append(Data("--\(boundary)--\r\n".utf8))
        guard result.count <= limit else { throw VoiceLabError.invalidInput }
        return result
    }
    private static func le32(_ bytes: Data, _ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }
    @discardableResult
    package static func validateWAV(_ bytes: Data, maxBytes: Int) throws -> (rate: Int, frames: Int) {
        try VoiceConsentAudio.validateWAV(bytes, maxBytes: maxBytes)
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
