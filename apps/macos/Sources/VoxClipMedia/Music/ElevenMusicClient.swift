import Foundation
import Synchronization
import VoxClipCore

/// A priced, not yet sent Eleven Music request. The inline "Make · $0.11" click that shows it is the approval; it is
/// used once and goes stale after ten minutes.
public struct MusicQuote: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let prompt: String
    public let lengthSeconds: Int
    public let estimate: CostEstimate
    public let createdAt: ContinuousClock.Instant
}

/// Eleven Music compose (doc/spec/music.md §3.2), verified against the API reference on 2026-11-04
/// (https://elevenlabs.io/docs/api-reference/music/compose): `POST /v1/music?output_format=mp3_44100_128` with
/// `xi-api-key`, a JSON body `{prompt, music_length_ms (3000–600000), model_id "music_v1", force_instrumental true}`;
/// the reply body is the audio file. VoxClip asks for at most five minutes. Price: $0.15 per minute
/// (https://elevenlabs.io/pricing/api), through the shared catalog. Each request is sent once, never retried; the spend
/// ledger records the estimate when the provider accepts it (a 2xx status), as Voice Lab does.
public final class ElevenMusicClient: Sendable {
    public static let path = "/v1/music"
    public static let outputFormat = "mp3_44100_128"
    public static let quoteLifetime: Duration = .seconds(600)
    public static let maximumReplyBytes = 40 * 1_024 * 1_024

    private let keys: any KeyProvider
    private let http: any MusicHTTP
    private let region: ElevenLabsRegion
    private let catalog: VoiceLabPriceCatalog
    private let spend: VoiceLabSpendLedger?
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let quotes = Mutex<[UUID: MusicQuote]>([:])

    public init(keys: any KeyProvider, catalog: VoiceLabPriceCatalog, spend: VoiceLabSpendLedger?, region: ElevenLabsRegion = .default,
                http: any MusicHTTP = URLSessionMusicHTTP(timeout: 300),
                clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.keys = keys; self.catalog = catalog; self.spend = spend; self.region = region; self.http = http; self.clock = clock
    }

    /// Prices a track as long as the clip, without sending anything.
    public func quote(prompt: String, clipSeconds: Double) throws -> MusicQuote {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_000 else { throw VoxClipError.providerError("The music prompt is empty or too long", provider: "elevenlabs") }
        let seconds = MusicPricing.lengthSeconds(forClip: clipSeconds)
        let quote = MusicQuote(id: UUID(), prompt: text, lengthSeconds: seconds,
                               estimate: try MusicPricing.estimate(seconds: seconds, catalog: catalog), createdAt: clock())
        quotes.withLock { $0[quote.id] = quote }
        return quote
    }

    /// The request exactly as sent; the key goes only in `xi-api-key`.
    public func request(for quote: MusicQuote, key: String) throws -> URLRequest {
        var components = URLComponents(url: region.baseURL.appendingPathComponent(Self.path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: Self.outputFormat)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["prompt": quote.prompt, "music_length_ms": quote.lengthSeconds * 1_000,
                                   "model_id": MusicPricing.model, "force_instrumental": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Sends the approved quote once and returns MP3 bytes. A stale, unknown or already used quote is refused before
    /// anything is sent; a failure is reported, never retried.
    public func compose(_ quote: MusicQuote) async throws -> Data {
        let fresh = quotes.withLock { quotes -> Bool in
            guard quotes[quote.id] == quote else { return false }
            quotes[quote.id] = nil
            return clock() - quote.createdAt <= Self.quoteLifetime
        }
        guard fresh else { throw VoxClipError.providerError("This price is out of date. Make it again to see the current price.", provider: "elevenlabs") }
        guard let key = try await keys.key(for: "elevenlabs"), !key.isEmpty else {
            throw VoxClipError.keyMissing("elevenlabs")
        }
        let request = try request(for: quote, key: key)
        let start = Date()
        let (data, response) = try await http.send(request)
        if (200..<300).contains(response.statusCode) { _ = await spend?.record(quote.estimate, at: start) }
        switch response.statusCode {
        case 200..<300:
            guard data.count >= 128, data.count <= Self.maximumReplyBytes, Self.looksLikeMP3(data) else {
                throw VoxClipError.providerError("Eleven Music sent audio VoxClip could not read", provider: "elevenlabs", status: response.statusCode)
            }
            return data
        case 401, 403: throw VoxClipError.keyRejected("elevenlabs", status: response.statusCode)
        case 402: throw VoxClipError.quotaExceeded("elevenlabs")
        case 429: throw VoxClipError.rateLimited("elevenlabs")
        default:
            throw VoxClipError.providerError(Self.detail(data) ?? "Eleven Music replied \(response.statusCode)", provider: "elevenlabs", status: response.statusCode)
        }
    }

    static func looksLikeMP3(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(3))
        return bytes.count == 3 && ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0))
    }

    /// The first validation message of a 4xx reply, shortened; never the request or key.
    static func detail(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let items = root["detail"] as? [[String: Any]], let message = items.first?["msg"] as? String { return "Eleven Music: " + String(message.prefix(200)) }
        if let detail = root["detail"] as? [String: Any], let message = detail["message"] as? String { return "Eleven Music: " + String(message.prefix(200)) }
        return nil
    }
}
