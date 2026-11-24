import Foundation

public enum VoxConvoPublishError: LocalizedError, Equatable, Sendable {
    case unavailable, invalidResponse, expired, denied, unauthorized, tooLarge, processingFailed, timedOut, invalidVideo, postUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "VoxConvo device publishing is unavailable right now."
        case .invalidResponse: "Something went wrong. Try again."
        case .expired: "The code expired. Try again."
        case .denied: "Connection was declined on voxconvo.com."
        case .unauthorized: "Your VoxConvo connection expired. Connect again."
        case .tooLarge: "This video is too large for VoxConvo."
        case .processingFailed: "VoxConvo couldn't process this video."
        case .timedOut: "VoxConvo didn't finish processing the video in time."
        case .invalidVideo: "The finished video is no longer available. Export it again."
        case .postUnconfirmed: "VoxConvo didn't confirm the post. Check your profile before trying again to avoid a duplicate."
        }
    }
}

public struct VoxConvoDeviceCode: Sendable {
    public let displayCode: String
    public let verificationURL: URL
    fileprivate let deviceCode: String
    fileprivate let interval: Int
    fileprivate let expires: ContinuousClock.Instant
}

public struct VoxConvoAccount: Equatable, Sendable {
    public let handle: String
}

public struct VoxConvoPublishDraft: Sendable {
    public let file: URL
    public let duration: Double
    public let text: String
    public let transcript: String
    public let words: [CaptionWord]

    public init(file: URL, duration: Double, text: String, transcript: String, words: [CaptionWord]) {
        self.file = file; self.duration = duration; self.text = text; self.transcript = transcript; self.words = words
    }
}

public struct VoxConvoUploadedVideo: Sendable {
    fileprivate let file: URL
    fileprivate let sessionDigest: String
    fileprivate let converted: String
    fileprivate let readyAt: Date

    public func isReusable(file: URL, session: String) -> Bool {
        self.file == file && sessionDigest == SpeechSHA256.hex(Data(session.utf8)) && Date().timeIntervalSince(readyAt) < 86_400
    }
}

public enum VoxConvoPublishProgress: Sendable { case uploading(Int), processing }

public struct VoxConvoPublishing: Sendable {
    public static let accountKey = "voxconvo-session"
    private static let webOrigin = URL(string: "https://voxconvo.com")!
    private let apiOrigin: URL
    private let http: URLSession
    private let pause: @Sendable (Int) async throws -> Void

    public init() {
        self.init(apiOrigin: URL(string: "https://api.voxconvo.com")!, pause: { try await Task.sleep(for: .seconds($0)) })
    }

    init(apiOrigin: URL, pause: @escaping @Sendable (Int) async throws -> Void) {
        self.apiOrigin = apiOrigin; self.pause = pause
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCache = nil; config.urlCredentialStorage = nil
        http = URLSession(configuration: config)
    }

    public func beginConnection() async throws -> VoxConvoDeviceCode {
        let (status, reply) = try await json("api/auth/device/code", body: ["client_id": .string("voxclip"), "scope": .string("post:video")])
        if status == 404 || status == 501 { throw VoxConvoPublishError.unavailable }
        try accept(status)
        guard let rawCode = reply[ai: "user_code"].aiString, let deviceCode = reply[ai: "device_code"].aiString,
              !deviceCode.isEmpty, deviceCode.utf8.count <= 512, let expires = reply[ai: "expires_in"].aiInt,
              (1...3_600).contains(expires) else { throw VoxConvoPublishError.invalidResponse }
        let code = rawCode.replacingOccurrences(of: "-", with: "").uppercased()
        guard code.utf8.count == 8, code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw VoxConvoPublishError.invalidResponse
        }
        var url = URLComponents(url: Self.webOrigin.appendingPathComponent("device"), resolvingAgainstBaseURL: false)
        url?.queryItems = [URLQueryItem(name: "user_code", value: code)]
        guard let verificationURL = url?.url else { throw VoxConvoPublishError.invalidResponse }
        let interval = min(60, max(1, reply[ai: "interval"].aiInt ?? 5))
        return VoxConvoDeviceCode(displayCode: code.prefix(4) + "-" + code.suffix(4), verificationURL: verificationURL,
            deviceCode: deviceCode, interval: interval, expires: .now.advanced(by: .seconds(expires)))
    }

    public func waitForApproval(_ code: VoxConvoDeviceCode) async throws -> String {
        var interval = code.interval
        while ContinuousClock.now < code.expires {
            let remaining = ContinuousClock.now.duration(to: code.expires).components.seconds
            try await pause(min(interval, max(1, Int(remaining) + 1)))
            try Task.checkCancellation()
            guard ContinuousClock.now < code.expires else { break }
            let result: (Int, JSONValue)
            do {
                result = try await json("api/auth/device/token", body: ["client_id": .string("voxclip"), "device_code": .string(code.deviceCode),
                    "grant_type": .string("urn:ietf:params:oauth:grant-type:device_code")])
            } catch let error as URLError where error.code == .timedOut {
                interval = min(3_600, interval * 2)
                continue
            }
            guard ContinuousClock.now < code.expires else { break }
            let (status, reply) = result
            if status == 200 {
                guard reply[ai: "token_type"].aiString?.lowercased() == "bearer", reply[ai: "scope"].aiString == "post:video",
                      let token = reply[ai: "access_token"].aiString, Self.validToken(token) else { throw VoxConvoPublishError.invalidResponse }
                return token
            }
            switch reply[ai: "error"].aiString {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw VoxConvoPublishError.expired
            case "access_denied": throw VoxConvoPublishError.denied
            default: throw VoxConvoPublishError.invalidResponse
            }
        }
        throw VoxConvoPublishError.expired
    }

    public func account(session: String) async throws -> VoxConvoAccount? {
        let (status, reply) = try await json("api/auth/get-session", session: session)
        try accept(status)
        guard reply[ai: "user"][ai: "id"].aiString?.isEmpty == false else { throw VoxConvoPublishError.unauthorized }
        let data = try await graphQL("query { getMyAccount { accountId handle name profileImage } }", session: session)
        let account = data[ai: "getMyAccount"]
        if account == .null { return nil }
        guard let handle = account[ai: "handle"].aiString, !handle.isEmpty, handle.utf8.count <= 10,
              handle.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw VoxConvoPublishError.invalidResponse
        }
        return VoxConvoAccount(handle: handle)
    }

    public func disconnect(session: String) async throws {
        let (status, _) = try await json("api/auth/sign-out", body: [:], session: session)
        if status != 401 { try accept(status) }
    }

    public func prepare(_ draft: VoxConvoPublishDraft, session: String,
                        progress: @escaping @Sendable (VoxConvoPublishProgress) -> Void) async throws -> VoxConvoUploadedVideo {
        guard (0...1_000_000).contains(draft.duration) else { throw VoxConvoPublishError.invalidVideo }
        let job = try await upload(draft, session: session, progress: progress)
        progress(.processing)
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(300, 120 + 1.5 * draft.duration)))
        var incompleteSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let (status, reply) = try await json("video-job/\(job)", session: session)
            if status != 404 { try accept(status) }
            switch (status, reply[ai: "status"].aiString) {
            case (_, "failed"): throw VoxConvoPublishError.processingFailed
            case (200, "completed"):
                if let url = reply[ai: "s3Url"].aiString, let parts = URLComponents(string: url),
                   parts.scheme == "https", parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.fragment == nil {
                    return VoxConvoUploadedVideo(file: draft.file, sessionDigest: SpeechSHA256.hex(Data(session.utf8)), converted: url, readyAt: Date())
                }
                incompleteSince = incompleteSince ?? .now
            case (404, _): incompleteSince = incompleteSince ?? .now
            case (200, "pending"), (200, "processing"): incompleteSince = nil
            default: throw VoxConvoPublishError.invalidResponse
            }
            if let incompleteSince, incompleteSince.duration(to: .now) >= .seconds(10) { throw VoxConvoPublishError.processingFailed }
            try await pause(2)
        }
        throw VoxConvoPublishError.timedOut
    }

    public func post(_ draft: VoxConvoPublishDraft, uploaded: VoxConvoUploadedVideo, session: String) async throws -> URL {
        guard uploaded.isReusable(file: draft.file, session: session) else { throw VoxConvoPublishError.invalidVideo }
        let words: [JSONValue] = draft.words.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }.map {
            .object(["word": .string($0.text), "start": .number($0.start), "end": .number($0.end), "conf": .null])
        }
        let timestamps = String(decoding: try JSONEncoder().encode(words), as: UTF8.self)
        let text = try SharePostText.composerText(draft.text, destination: .voxConvo, disclosureLine: nil)
        let variables: [String: JSONValue] = ["d": .object(["text": .string(text), "transcript": .string(draft.transcript),
            "wordTimestamps": .string(timestamps), "video": .object(["converted": .string(uploaded.converted)])])]
        do {
            let data = try await graphQL("mutation createNew($d: NewPostInput!) { createNew(newPostData: $d) { postId handle video { converted } } }",
                variables: variables, session: session)
            guard let id = data[ai: "createNew"][ai: "postId"].aiInt, id > 0 else { throw VoxConvoPublishError.postUnconfirmed }
            return Self.webOrigin.appendingPathComponent("post/\(id)")
        } catch VoxConvoPublishError.unauthorized {
            throw VoxConvoPublishError.unauthorized
        } catch {
            throw VoxConvoPublishError.postUnconfirmed
        }
    }

    private func upload(_ draft: VoxConvoPublishDraft, session: String,
                        progress: @escaping @Sendable (VoxConvoPublishProgress) -> Void) async throws -> String {
        let attributes = try draft.file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard draft.file.pathExtension.lowercased() == "mp4", attributes.isRegularFile == true, let bytes = attributes.fileSize, bytes > 0 else {
            throw VoxConvoPublishError.invalidVideo
        }
        let directory = try ScratchCleanup.createExportDirectory(in: FileManager.default.temporaryDirectory)
        defer { ScratchCleanup.discardExportDirectory(directory) }
        let file = directory.url.appendingPathComponent("upload")
        let boundary = "VoxClip-" + UUID().uuidString
        try multipart(draft, file: file, boundary: boundary)
        var request = try self.request("upload-video", method: "POST", session: session, timeout: max(180, Double(bytes) / 500))
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        progress(.uploading(0))
        let (data, response) = try await http.upload(for: request, fromFile: file, delegate: VoxConvoRequestDelegate(progress: progress))
        let (status, reply) = try parse(data, response)
        try accept(status)
        guard reply[ai: "success"].aiBool == true, let job = reply[ai: "jobId"].aiString, UUID(uuidString: job) != nil else {
            throw VoxConvoPublishError.invalidResponse
        }
        return job
    }

    private func multipart(_ draft: VoxConvoPublishDraft, file: URL, boundary: String) throws {
        let parts = [("prerendered", "true"), ("words", "[]"), ("transcript", draft.transcript),
            ("subtitleConfig", #"{"style":"none","position":{"x":50,"y":80},"size":{"width":400,"fontSize":18}}"#)]
        let head = parts.map { "--\(boundary)\r\nContent-Disposition: form-data; name=\"\($0.0)\"\r\n\r\n\($0.1)\r\n" }.joined()
        let video = "--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"VoxClip.mp4\"\r\nContent-Type: video/mp4\r\n\r\n"
        try Data((head + video).utf8).write(to: file)
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: draft.file)
        defer { try? input.close() }
        try output.seekToEnd()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    private func graphQL(_ query: String, variables: [String: JSONValue] = [:], session: String) async throws -> JSONValue {
        let (status, reply) = try await json("graphql", body: ["query": .string(query), "variables": .object(variables)], session: session)
        try accept(status)
        guard reply[ai: "errors"].aiArray.isEmpty, reply[ai: "data"].aiObject != nil else { throw VoxConvoPublishError.invalidResponse }
        return reply[ai: "data"]
    }

    private func json(_ path: String, body: [String: JSONValue]? = nil, session: String? = nil) async throws -> (Int, JSONValue) {
        var request = try self.request(path, method: body == nil ? "GET" : "POST", session: session, timeout: 15)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await http.data(for: request, delegate: VoxConvoRequestDelegate())
        return try parse(data, response)
    }

    private func request(_ path: String, method: String, session: String?, timeout: Double) throws -> URLRequest {
        var request = URLRequest(url: apiOrigin.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if let session {
            guard Self.validToken(session) else { throw VoxConvoPublishError.unauthorized }
            request.setValue("Bearer " + session, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func validToken(_ value: String) -> Bool {
        (1...4_096).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    private func parse(_ data: Data, _ response: URLResponse) throws -> (Int, JSONValue) {
        guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else { throw VoxConvoPublishError.invalidResponse }
        return (response.statusCode, (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null)
    }

    private func accept(_ status: Int) throws {
        if status == 401 { throw VoxConvoPublishError.unauthorized }
        if status == 413 { throw VoxConvoPublishError.tooLarge }
        guard (200...299).contains(status) else { throw VoxConvoPublishError.invalidResponse }
    }
}

private final class VoxConvoRequestDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let progress: (@Sendable (VoxConvoPublishProgress) -> Void)?
    init(progress: (@Sendable (VoxConvoPublishProgress) -> Void)? = nil) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress?(.uploading(Int(min(100, Double(totalBytesSent) * 100 / Double(totalBytesExpectedToSend)))))
    }
}
