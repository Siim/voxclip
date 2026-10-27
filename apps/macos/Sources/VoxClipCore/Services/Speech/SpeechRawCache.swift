import Foundation

public protocol SpeechCacheIdentityProviding: Sendable {
    func cacheIdentity(for plan: TranscriptionPlan) async throws -> EngineRef
}

struct SpeechRawCacheKey: Codable, Equatable, Sendable {
    let engine: TranscriptEngine
    let model: String?
    let modelSha256: String?
    let adapterVersion: Int
    let language: String?
    let locale: String?
    let diarize: Bool
    let numSpeakers: Int?
    let keyterms: [String]
    let dtw: Bool
    let audioTrackIndex: Int
    static func normalizedRequest(_ request: TranscriptionRequest, catalog: BundledModelCatalog?) async throws -> TranscriptionRequest {
        guard case .forced(let code) = request.plan.language else { return request }
        guard code.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
            throw VoxClipError.transcriptionLanguageUnsupported(SpeechErrorCopy.engineName(request.plan.engine), language: "the selected model or language identifier")
        }
        let primary = SpeechText.primaryLanguage(code)
        let language: String
        if let catalog { language = try await catalog.normalizeLanguage(primary) }
        else { language = primary }
        var normalized = request
        if request.plan.engine == .appleSpeech, let region = code.firstIndex(of: "-") {
            normalized.plan.language = .forced(language + code[region...])
        } else { normalized.plan.language = .forced(language) }
        return normalized
    }
    init(request: TranscriptionRequest, identity: EngineRef) {
        engine = identity.id; model = identity.modelId; modelSha256 = identity.modelSha256; adapterVersion = 1
        if case .forced(let code) = request.plan.language { language = SpeechText.primaryLanguage(code) } else { language = nil }
        locale = identity.locale; diarize = request.plan.options.diarize; numSpeakers = request.plan.options.numSpeakers
        keyterms = request.plan.options.keyterms.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        dtw = request.plan.options.dtw; audioTrackIndex = request.audio.audioTrackIndex
    }
    func canonicalData() throws -> Data {
        let object: [String: Any] = ["engine": engine.rawValue, "model": model as Any? ?? NSNull(), "modelSha256": modelSha256 as Any? ?? NSNull(), "adapterVersion": adapterVersion,
            "language": language as Any? ?? NSNull(), "locale": locale as Any? ?? NSNull(), "diarize": diarize, "numSpeakers": numSpeakers as Any? ?? NSNull(), "keyterms": keyterms, "dtw": dtw, "audioTrackIndex": audioTrackIndex]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    func digest() throws -> String { SpeechSHA256.hex(try canonicalData()) }
    func url(in directory: URL) throws -> URL {
        guard model.map({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil }) ?? true,
              language.map({ $0.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil }) ?? true else { throw VoxClipError.transcriptionLanguageUnsupported(SpeechErrorCopy.engineName(engine), language: "the selected model or language identifier") }
        let digest = try digest()
        return directory.appendingPathComponent("\(engine.rawValue)-\(model ?? "none")-\(language ?? "auto")-\(digest.prefix(8)).json")
    }
    func encode(to encoder: any Encoder) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: canonicalData())
        try value.encode(to: encoder)
    }
}

struct SpeechRawCacheEntry: Codable, Sendable {
    var schema = "voxclip-raw-transcript/1"
    let key: SpeechRawCacheKey
    var createdAt = Date()
    let raw: RawTranscript?
    let providerResponse: JSONValue?
    var providerResponseBytes: Data? = nil
    func matchingRaw(for expected: SpeechRawCacheKey) -> RawTranscript? {
        guard schema == "voxclip-raw-transcript/1", key == expected, let raw,
              !raw.tokens.isEmpty, raw.adapterVersion == key.adapterVersion, raw.engine.id == key.engine,
              raw.engine.modelId == key.model, raw.engine.modelSha256 == key.modelSha256 else { return nil }
        return raw
    }
    func providerData() throws -> Data? {
        if let providerResponseBytes { return providerResponseBytes }
        return try providerResponse.map { try JSONEncoder().encode($0) }
    }
    static func read(_ url: URL) throws -> Self {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .utcTimestamp
        decoder.userInfo[modified] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return try decoder.decode(Self.self, from: Data(contentsOf: url))
    }
    /// Moves the file at `url` aside as `<name>.unreadable-<unix ms>` unless it is the placeholder for `key`, so a paid
    /// response that no longer decodes, or that belongs to another key or schema, is kept instead of overwritten. The
    /// move never replaces an existing file.
    static func setAside(_ url: URL, unlessPlaceholderFor key: SpeechRawCacheKey) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let entry = try? read(url), entry.schema == "voxclip-raw-transcript/1", entry.key == key,
           entry.raw == nil, entry.providerResponse == nil, entry.providerResponseBytes == nil { return }
        var milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        while FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable-\(milliseconds)").path) { milliseconds += 1 }
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(milliseconds)"))
    }
    func write(_ url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .utcTimestamp; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema); try container.encode(key, forKey: .key)
        try container.encode(createdAt, forKey: .createdAt); try container.encode(raw, forKey: .raw)
        try container.encode(providerResponse, forKey: .providerResponse)
        try container.encodeIfPresent(providerResponseBytes, forKey: .providerResponseBytes)
    }
    private static let modified = CodingUserInfoKey(rawValue: "voxclip.rawCacheModified")!
    private enum CodingKeys: String, CodingKey { case schema, key, createdAt, raw, providerResponse, providerResponseBytes }
}

extension SpeechRawCacheEntry {
    /// Reads `createdAt` leniently: a missing date, or one in another format, falls back to the file's modification
    /// date, so a date-format change alone never makes a paid response unreadable (editing.md §10.1).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        key = try container.decode(SpeechRawCacheKey.self, forKey: .key)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? (decoder.userInfo[Self.modified] as? Date) ?? Date()
        raw = try container.decodeIfPresent(RawTranscript.self, forKey: .raw)
        providerResponse = try container.decodeIfPresent(JSONValue.self, forKey: .providerResponse)
        providerResponseBytes = try container.decodeIfPresent(Data.self, forKey: .providerResponseBytes)
    }
}

actor SpeechJobGate {
    static let shared = SpeechJobGate()
    private var localJobs = 0
    private var cloudJobs = 0
    private var keys: Set<String> = []
    func acquire(local: Bool, key: String) async throws {
        while keys.contains(key) || (local ? localJobs >= 1 : cloudJobs >= 2) { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        keys.insert(key)
        if local { localJobs += 1 } else { cloudJobs += 1 }
    }
    func release(local: Bool, key: String) {
        keys.remove(key)
        if local { localJobs -= 1 } else { cloudJobs -= 1 }
    }
}
