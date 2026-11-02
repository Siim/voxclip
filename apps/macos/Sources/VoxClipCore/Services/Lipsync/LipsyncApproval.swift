import Foundation

public enum LipsyncError: Error, Sendable, Equatable {
    case approvalRequired, expiredQuote, invalidInput, unsupportedModel, busy, unknownJob
    case unsafeURL, invalidResponse, responseTooLarge, invalidMedia, unsafeFile
    case missingKey, network, http(Int), submissionUncertain, deadlineExceeded
}

public struct LipsyncSignedInput: Sendable, Equatable {
    public let url: URL
    public let sha256: String
    public let durationSeconds: Double
    public let contentType: String
    public let byteCount: Int
    public let expiresAt: Date

    public init(url: URL, sha256: String, durationSeconds: Double, contentType: String, byteCount: Int) throws {
        let expiresAt = try LipsyncURLPolicy.signedInputExpiry(url)
        guard sha256.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil,
              durationSeconds.isFinite, (3...300).contains(durationSeconds),
              ["video/mp4", "audio/wav"].contains(contentType), byteCount > 0,
              byteCount <= (contentType == "video/mp4" ? LipsyncLimits.maximumVideoBytes : 64 * 1_024 * 1_024)
        else { throw LipsyncError.invalidInput }
        self.url = url; self.sha256 = sha256; self.durationSeconds = durationSeconds
        self.contentType = contentType; self.byteCount = byteCount; self.expiresAt = expiresAt
    }
}

public enum LipsyncLimits {
    public static let maximumVideoBytes = 512 * 1_024 * 1_024
    public static let maximumJSONBytes = 1_024 * 1_024
    public static let maximumPolls = 140
    public static let deadlineSeconds: Double = 1_800
    public static let quoteLifetimeSeconds: Double = 300
}

public struct LipsyncQuote: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let model: LipsyncModel
    public let video: LipsyncSignedInput
    public let audio: LipsyncSignedInput
    public let options: LipsyncOptions
    public let fps: Double
    public let estimate: CostEstimate
    public let expiresAt: Date
    public var outputDurationSeconds: Double {
        options.syncMode == .remap ? audio.durationSeconds : min(video.durationSeconds, audio.durationSeconds)
    }
    let keyFingerprint: String
    let issuedAt: Duration
    let owner: UUID

    init(model: LipsyncModel, video: LipsyncSignedInput, audio: LipsyncSignedInput, options: LipsyncOptions,
         fps: Double, estimate: CostEstimate, expiresAt: Date, keyFingerprint: String, issuedAt: Duration, owner: UUID) {
        self.id = UUID(); self.model = model; self.video = video; self.audio = audio; self.options = options
        self.fps = fps; self.estimate = estimate; self.expiresAt = expiresAt; self.keyFingerprint = keyFingerprint
        self.issuedAt = issuedAt; self.owner = owner
    }
}

public actor LipsyncApproval {
    let quote: LipsyncQuote
    private let store: VoiceConsentStore
    private let record: VoiceConsentRecord
    private var consumed = false

    init(quote: LipsyncQuote, store: VoiceConsentStore, record: VoiceConsentRecord) {
        self.quote = quote; self.store = store; self.record = record
    }

    func consume(_ supplied: LipsyncQuote) async throws -> VoiceDispatchPermit {
        guard !consumed, supplied == quote else { throw LipsyncError.approvalRequired }
        consumed = true
        return try await store.dispatchPermit(record, requestID: quote.id)
    }
}

enum LipsyncURLPolicy {
    static let resultHosts: Set<String> = ["fal.media", "v1.fal.media", "v2.fal.media", "v3.fal.media", "v3b.fal.media"]

    static func components(_ url: URL) throws -> URLComponents {
        guard url.absoluteString.utf8.count <= 8_192,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              value.scheme == "https", let host = value.host, host == host.lowercased(),
              !host.hasSuffix("."), value.user == nil, value.password == nil, value.fragment == nil,
              value.port == nil || value.port == 443, !value.path.isEmpty,
              !value.percentEncodedPath.lowercased().contains("%2f"),
              !value.percentEncodedPath.lowercased().contains("%5c"),
              !value.path.contains("\\"), !value.path.split(separator: "/").contains("..")
        else { throw LipsyncError.unsafeURL }
        return value
    }

    static func signedInputExpiry(_ url: URL) throws -> Date {
        let value = try components(url)
        guard let host = value.host,
              host.range(of: #"\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\.s3(?:\.[a-z]{2}-[a-z]+-[1-9])?\.amazonaws\.com\z"#,
                         options: .regularExpression) != nil else { throw LipsyncError.unsafeURL }
        var query: [String: String] = [:]
        for item in value.queryItems ?? [] {
            guard query[item.name] == nil, let text = item.value, !text.isEmpty else { throw LipsyncError.unsafeURL }
            query[item.name] = text
        }
        guard query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256", query["X-Amz-Credential"] != nil,
              let signature = query["X-Amz-Signature"],
              signature.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil,
              query["versionId"].map({ $0 != "null" }) == true,
              query["X-Amz-SignedHeaders"] == "host", let seconds = query["X-Amz-Expires"].flatMap(Int.init),
              (1...604_800).contains(seconds), let timestamp = query["X-Amz-Date"]
        else { throw LipsyncError.unsafeURL }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; formatter.isLenient = false
        guard let start = formatter.date(from: timestamp), formatter.string(from: start) == timestamp else { throw LipsyncError.unsafeURL }
        return start.addingTimeInterval(Double(seconds))
    }

    static func result(_ url: URL) throws {
        let value = try components(url)
        guard let host = value.host, resultHosts.contains(host), value.path.hasPrefix("/files/") else { throw LipsyncError.unsafeURL }
    }

    static func queue(_ url: URL, model: LipsyncModel, requestID: String, suffix: String) throws {
        let value = try components(url)
        let app = model.id.hasPrefix("fal-ai/latentsync") ? "fal-ai/latentsync" : "fal-ai/sync-lipsync"
        guard value.host == "queue.fal.run", value.query == nil,
              value.percentEncodedPath == "/\(app)/requests/\(requestID)\(suffix)" else { throw LipsyncError.unsafeURL }
    }
}
