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
              language.map({ $0.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil }) ?? true else { throw VoxClipError.transcriptionLanguageUnsupported("Invalid model or language identifier") }
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
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(contentsOf: url))
    }
    func write(_ url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema); try container.encode(key, forKey: .key)
        try container.encode(createdAt, forKey: .createdAt); try container.encode(raw, forKey: .raw)
        try container.encode(providerResponse, forKey: .providerResponse)
        try container.encodeIfPresent(providerResponseBytes, forKey: .providerResponseBytes)
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
