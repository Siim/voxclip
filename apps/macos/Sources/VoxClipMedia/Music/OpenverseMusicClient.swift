import Foundation
import Synchronization
import VoxClipCore

/// The one network seam the music sources use; tests pass hand-written fixture replies, never a live call.
public protocol MusicHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral, cookie-less HTTPS transport with a reply size limit.
public struct URLSessionMusicHTTP: MusicHTTP {
    private let session: URLSession
    public init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 300)
        session = URLSession(configuration: configuration)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme == "https" else { throw VoxClipError.providerError("Music sources use HTTPS only") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
                throw VoxClipError.providerError("The music source replied without HTTPS")
            }
            return (data, http)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut].contains(error.code) {
            throw VoxClipError.offline
        }
    }
}

/// Openverse audio search for free library music; doc/spec/music.md §3.1.
/// `GET https://api.openverse.org/v1/audio/?q=…&license=cc0,by,pdm&category=music&page_size=…`, anonymous.
/// Only CC0, CC BY and Public Domain Mark results are kept (nc, nd and sa never), each search is cached per query so one
/// suggestion sends one search, and a 429 blocks further searches until its Retry-After (or a doubling back-off) passes.
public final class OpenverseMusicClient: Sendable {
    public static let endpoint = URL(string: "https://api.openverse.org/v1/audio/")!
    public static let allowedLicenses: Set<String> = ["cc0", "by", "pdm"]
    public static let pageSize = 20
    public static let maximumDownloadBytes = 60 * 1_024 * 1_024
    static let minimumBackoff: Duration = .seconds(15)
    static let maximumBackoff: Duration = .seconds(600)

    private struct PageKey: Hashable {
        let query: String
        let page: Int
        let sound: Bool
    }

    private struct State {
        var cache: [PageKey: MusicCatalogPage] = [:]
        var blockedUntil: ContinuousClock.Instant?
        var backoff: Duration = OpenverseMusicClient.minimumBackoff
    }
    private let http: any MusicHTTP
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex(State())

    public init(http: any MusicHTTP = URLSessionMusicHTTP(timeout: 20), clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.http = http; self.clock = clock
    }

    public static func searchURL(query: String, pageSize: Int = OpenverseMusicClient.pageSize, page: Int = 1, sound: Bool = false) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "license", value: "cc0,by,pdm")]
        if !sound { components.queryItems?.append(URLQueryItem(name: "category", value: "music")) }
        components.queryItems?.append(URLQueryItem(name: "page_size", value: String(pageSize)))
        if page > 1 { components.queryItems?.append(URLQueryItem(name: "page", value: String(page))) }
        return components.url!
    }

    /// Playable library candidates for `query`, best first for the brief's keywords and the clip's length.
    public func search(_ query: String, keywords: Set<String> = [], clipSeconds: Double = 0) async throws -> [MusicCandidate] {
        try await searchPage(query, keywords: keywords, clipSeconds: clipSeconds).candidates
    }

    public func searchPage(_ query: String, keywords: Set<String> = [], clipSeconds: Double = 0, page: Int = 1, sound: Bool = false) async throws -> MusicCatalogPage {
        let page = max(1, page)
        let key = PageKey(query: query.lowercased(), page: page, sound: sound)
        func rankedPage(_ result: MusicCatalogPage) -> MusicCatalogPage {
            MusicCatalogPage(candidates: sound ? result.candidates : Self.ranked(result.candidates, keywords: keywords, clipSeconds: clipSeconds), nextPage: result.nextPage)
        }
        let cached: MusicCatalogPage? = try state.withLock { state in
            if let found = state.cache[key] { return found }
            if let until = state.blockedUntil, clock() < until {
                throw VoxClipError.rateLimited("The free music library asked VoxClip to wait. Try again in a minute.")
            }
            return nil
        }
        if let cached { return rankedPage(cached) }
        var request = URLRequest(url: Self.searchURL(query: query, page: page, sound: sound))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        if response.statusCode == 429 {
            let wait = Self.retryAfter(response)
            state.withLock { state in
                let backoff = wait ?? state.backoff
                state.blockedUntil = clock() + backoff
                state.backoff = min(Self.maximumBackoff, state.backoff * 2)
            }
            throw VoxClipError.rateLimited("The free music library asked VoxClip to wait. Try again in a minute.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw VoxClipError.providerError("The free music library replied \(response.statusCode)", provider: "openverse", status: response.statusCode)
        }
        let result = try Self.parsePage(data, page: page, sound: sound)
        state.withLock { state in
            state.cache[key] = result
            state.backoff = Self.minimumBackoff
            state.blockedUntil = nil
        }
        return rankedPage(result)
    }

    static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let text = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(text.trimmingCharacters(in: .whitespaces)),
              seconds >= 0 else { return nil }
        return .seconds(min(seconds, 3_600))
    }

    /// Keeps only CC0, CC BY and PDM music with an HTTPS file and landing page, a known audio type and some length.
    public static func parse(_ data: Data) throws -> [MusicCandidate] {
        try parsePage(data, page: 1).candidates
    }

    static func parsePage(_ data: Data, page: Int, sound: Bool = false) throws -> MusicCatalogPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = root["results"] as? [[String: Any]] else {
            throw VoxClipError.providerError("The free music library sent an unreadable reply", provider: "openverse")
        }
        let pageCount = root["page_count"] as? Int ?? 0
        return MusicCatalogPage(candidates: results.compactMap { candidate($0, sound: sound) }, nextPage: pageCount > page ? page + 1 : nil)
    }

    static func candidate(_ row: [String: Any], sound: Bool = false) -> MusicCandidate? {
        guard let id = row["id"] as? String, !id.isEmpty, id.count <= 64,
              let licenseText = (row["license"] as? String)?.lowercased(), allowedLicenses.contains(licenseText),
              let license = MusicLicense(rawValue: licenseText),
              (row["mature"] as? Bool) != true,
              let file = (row["url"] as? String).flatMap(URL.init(string:)), file.scheme == "https", file.host != nil,
              let landing = row["foreign_landing_url"] as? String, landing.hasPrefix("https://"), landing.count <= 2_048,
              !landing.contains(where: \.isWhitespace), URL(string: landing)?.host != nil,
              let fileExtension = fileExtension(row["filetype"] as? String, url: file) else { return nil }
        let category = row["category"] as? String
        if sound {
            guard row["category"] == nil || row["category"] is NSNull || category == "sound_effect" else { return nil }
        } else if category != nil && category != "music" { return nil }
        let duration = (row["duration"] as? NSNumber).map { $0.doubleValue / 1_000 }
        if sound {
            guard let duration, duration > 0 && duration <= 30 else { return nil }
        } else if let duration, !duration.isFinite || duration < 10 || duration > ProjectMusic.maximumDuration { return nil }
        let title = clipped(row["title"] as? String, 200) ?? "Untitled"
        let creator = clipped(row["creator"] as? String, 200)
        let attribution = clipped(row["attribution"] as? String, 1_000)
        guard license != .by || attribution != nil else { return nil }
        let tags = ((row["tags"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        let genres = (row["genres"] as? [String]) ?? []
        return MusicCandidate(id: "openverse-" + id, source: .library, title: title, creator: creator, license: license,
                              attribution: attribution, sourceUrl: landing, audioURL: file, fileExtension: fileExtension,
                              durationSeconds: duration, tags: Array((genres + tags).prefix(24)))
    }

    static func clipped(_ text: String?, _ limit: Int) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let visible = trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return visible.isEmpty ? nil : String(String.UnicodeScalarView(visible).prefix(limit))
    }

    static func fileExtension(_ filetype: String?, url: URL) -> String? {
        switch (filetype ?? url.pathExtension).lowercased() {
        case "mp3", "mp32", "mpeg": "mp3"
        case "wav", "wave": "wav"
        case "flac": "flac"
        case "m4a", "aac", "mp4": "m4a"
        case "aif", "aiff": "aiff"
        default: nil
        }
    }

    /// Best first: instrumental tags, matching words, long enough not to loop; vocals last. Ties keep Openverse order.
    static func ranked(_ candidates: [MusicCandidate], keywords: Set<String>, clipSeconds: Double) -> [MusicCandidate] {
        func score(_ candidate: MusicCandidate) -> Int {
            let text = ([candidate.title] + candidate.tags).joined(separator: " ").lowercased()
            let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            var value = words.intersection(keywords).count * 2
            if words.contains("instrumental") { value += 3 }
            if !words.isDisjoint(with: ["vocal", "vocals", "singer", "lyrics", "song", "rap"]) { value -= 3 }
            if let duration = candidate.durationSeconds, duration >= clipSeconds { value += 1 }
            return value
        }
        return candidates.enumerated().sorted { lhs, rhs in
            let (left, right) = (score(lhs.element), score(rhs.element))
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Downloads a chosen track; only called when the user (or the one-click plan) uses it.
    public func download(_ candidate: MusicCandidate) async throws -> Data {
        guard candidate.source == .library, let url = candidate.audioURL, url.scheme == "https" else {
            throw VoxClipError.providerError("This track has no download", provider: "openverse")
        }
        var request = URLRequest(url: url)
        request.setValue("audio/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw VoxClipError.providerError("The track's host replied \(response.statusCode)", provider: "openverse", status: response.statusCode)
        }
        guard !data.isEmpty, data.count <= Self.maximumDownloadBytes else {
            throw VoxClipError.providerError("The track is empty or larger than 60 MB", provider: "openverse")
        }
        if let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(), type.hasPrefix("text/") || type.contains("json") {
            throw VoxClipError.providerError("The track's host did not send audio", provider: "openverse")
        }
        return data
    }
}
