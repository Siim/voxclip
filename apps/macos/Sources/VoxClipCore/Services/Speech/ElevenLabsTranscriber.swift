import Foundation
import Synchronization

/// User-selected batch cloud adapter; transcription §8. Keys are supplied, never discovered or logged.
public actor ElevenLabsTranscriber: Transcriber {
    public nonisolated let engine: TranscriptEngine = .elevenlabs
    public nonisolated let region: ElevenLabsRegion
    private let keys: any KeyProvider
    private let session: URLSession
    private let catalog: BundledModelCatalog?
    private let sleep: @Sendable (Double) async throws -> Void
    private let logger: any Redacting
    public init(keys: any KeyProvider, region: ElevenLabsRegion, logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)) {
        self.keys = keys
        self.region = region
        self.logger = logger
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300; config.timeoutIntervalForResource = 7200
        session = URLSession(configuration: config)
        catalog = (try? SharedResources.locate()).map { BundledModelCatalog(shared: $0) }
        sleep = { try await Task.sleep(for: .seconds($0)) }
    }
    public init(keys: any KeyProvider, settings: SettingsDocument, logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)) async {
        let region = await ElevenLabsRegion.from(settings: settings, logger: logger)
        self.init(keys: keys, region: region, logger: logger)
    }
    public init(keys: any KeyProvider, session: URLSession, region: ElevenLabsRegion = .default, catalog: BundledModelCatalog? = nil, sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }, logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)) {
        self.keys = keys; self.session = session; self.region = region; self.catalog = catalog; self.sleep = sleep; self.logger = logger
    }
    public init(keys: any KeyProvider, settings: SettingsDocument, session: URLSession, catalog: BundledModelCatalog? = nil, sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }, logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)) async {
        let region = await ElevenLabsRegion.from(settings: settings, logger: logger)
        self.init(keys: keys, session: session, region: region, catalog: catalog, sleep: sleep, logger: logger)
    }
    public nonisolated func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .native, verbatim: true, autoLanguage: true, maxDurationSeconds: 36_000, maxUploadBytes: 3_000_000_000, onDevice: false) }
    public func supports(_ language: LanguageChoice, model: String?) async -> Bool {
        switch language {
        case .auto: true
        case .forced(let code): code.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
        }
    }
    public func readiness(for plan: TranscriptionPlan) async -> Readiness {
        guard await supports(plan.language, model: plan.model) else { return .unsupportedLanguage("Invalid language code") }
        guard let key = try? await keys.key(for: "elevenlabs"), !key.isEmpty else { return .needsKey(provider: "elevenlabs") }
        return .ready
    }
    public func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws { try Task.checkCancellation() }
    public func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        let request = try await normalizedRequest(request)
        let key = cacheKey(request)
        let directory = request.audio.wav16k.deletingLastPathComponent().appendingPathComponent("transcripts")
        return try await transcribeWithCache(request, cacheURL: key.url(in: directory), progress: progress).raw
    }
    func normalizedRequest(_ request: TranscriptionRequest) async throws -> TranscriptionRequest {
        try await SpeechRawCacheKey.normalizedRequest(request, catalog: catalog)
    }
    func transcribeWithCache(_ request: TranscriptionRequest, cacheURL: URL, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> (raw: RawTranscript, fromCache: Bool) {
        do {
            let request = try await normalizedRequest(request)
            let bytes = try await validateRequest(request)
            let key = cacheKey(request)
            if let entry = try? SpeechRawCacheEntry.read(cacheURL), entry.key == key, entry.schema == "voxclip-raw-transcript/1" {
                if let raw = entry.matchingRaw(for: key) {
                    guard raw.tokens.contains(where: { ($0.kind ?? .word) == .word }) else { throw VoxClipError.noSpeech }
                    return (raw, true)
                }
                if let data = try entry.providerData() {
                    return (try await mapAndCache(data, request: request, key: key, url: cacheURL), true)
                }
            }
            guard let catalog else { throw VoxClipError.sharedResourcesMissing }
            _ = try await catalog.models()
            guard let apiKey = try await keys.key(for: "elevenlabs"), !apiKey.isEmpty else { throw VoxClipError.keyMissing("elevenlabs") }
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SpeechRawCacheEntry.setAside(cacheURL, unlessPlaceholderFor: key)
            try SpeechRawCacheEntry(key: key, raw: nil, providerResponse: nil).write(cacheURL)
            let raw = try await performTranscription(request, cacheURL: cacheURL, bytes: bytes, key: apiKey, progress: progress)
            return (raw, false)
        }
        catch {
            if Task.isCancelled || error is CancellationError { throw VoxClipError.cancelled }
            throw error
        }
    }
    private func validateRequest(_ request: TranscriptionRequest) async throws -> Int {
        try Task.checkCancellation()
        guard request.plan.engine == engine, await supports(request.plan.language, model: request.plan.model) else { throw SpeechErrorCopy.unsupported(engine, language: request.plan.language) }
        guard request.plan.model == nil || request.plan.model == "scribe_v2" else { throw VoxClipError.transcriptionFailed("ElevenLabs requires the scribe_v2 model") }
        guard request.audio.durationSeconds.isFinite, request.audio.durationSeconds >= 0.1 else { throw VoxClipError.noSpeech }
        let bytes = try request.audio.wav16k.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard request.audio.durationSeconds <= 36_000, bytes <= 3_000_000_000 else { throw VoxClipError.mediaTooLong(SpeechErrorCopy.duration(request.audio.durationSeconds)) }
        try Self.validateOptions(request.plan.options)
        return bytes
    }
    private func performTranscription(_ request: TranscriptionRequest, cacheURL: URL, bytes: Int, key: String, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        try Task.checkCancellation()
        await logger.register(secret: key)
        await Log(logger: logger).write(.info, category: "transcribe", message: "engine=elevenlabs model=scribe_v2 bytes=\(bytes) duration=\(request.audio.durationSeconds)")
        let boundary = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let body = try Self.multipart(request, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }
        var upload = URLRequest(url: region.baseURL.appendingPathComponent("v1/speech-to-text"))
        upload.httpMethod = "POST"
        upload.timeoutInterval = 300
        upload.setValue(key, forHTTPHeaderField: "xi-api-key")
        upload.setValue("application/json", forHTTPHeaderField: "Accept")
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.setValue("VoxClip/\(AppVersion.current) (macOS \(SpeechRuntimeVersion.macOS); arm64)", forHTTPHeaderField: "User-Agent")
        let reporter = SpeechProgressThrottle(callback: progress)
        defer { reporter.cancel() }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                reporter.report(TranscriptionProgress(stage: .uploading, fraction: 0))
                let delegate = ScribeUploadDelegate { sent, total in
                    reporter.report(TranscriptionProgress(stage: sent >= total ? .transcribing : .uploading, fraction: sent >= total ? nil : Double(sent) / Double(max(1, total))))
                }
                let (data, response) = try await uploadBody(upload, file: body, delegate: delegate)
                guard let http = response as? HTTPURLResponse else { throw VoxClipError.providerError("invalid response", provider: "ElevenLabs") }
                await Log(logger: logger).write(.info, category: "transcribe", message: "engine=elevenlabs status=\(http.statusCode) attempt=\(attempt + 1)")
                if (200..<300).contains(http.statusCode) {
                    let raw = try await mapAndCache(data, request: request, key: cacheKey(request), url: cacheURL)
                    await reporter.finish()
                    return raw
                }
                try Task.checkCancellation()
                let failure = Self.providerError(status: http.statusCode, data: data, key: key, region: region)
                if case .providerError(let detail, _, _) = failure {
                    await Log(logger: logger).write(.warn, category: "transcribe", message: "engine=elevenlabs status=\(http.statusCode) detail=\(detail)")
                }
                if attempt < 2 && (http.statusCode == 429 || http.statusCode >= 500), failure.code != .quotaExceeded {
                    try await sleep(SpeechHTTPFailure.delay(http.value(forHTTPHeaderField: "Retry-After")) ?? Double(1 << attempt))
                    continue
                }
                throw failure
            } catch let error as URLError {
                if Task.isCancelled || error.code == .cancelled { throw VoxClipError.cancelled }
                guard attempt < 2 else { throw VoxClipError.offline }
                try await sleep(Double(1 << attempt))
            } catch is CancellationError { throw VoxClipError.cancelled }
        }
        throw VoxClipError.offline
    }
    private func cacheKey(_ request: TranscriptionRequest) -> SpeechRawCacheKey {
        SpeechRawCacheKey(request: request, identity: EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2"))
    }
    private func mapAndCache(_ data: Data, request: TranscriptionRequest, key: SpeechRawCacheKey, url: URL) async throws -> RawTranscript {
        let response = try? JSONDecoder().decode(JSONValue.self, from: data)
        await cachePaidResponse(SpeechRawCacheEntry(key: key, raw: nil, providerResponse: response, providerResponseBytes: data), at: url)
        try Task.checkCancellation()
        let raw = try await mapResponse(data, diarize: request.plan.options.diarize)
        await cachePaidResponse(SpeechRawCacheEntry(key: key, raw: raw, providerResponse: response, providerResponseBytes: data), at: url)
        guard raw.tokens.contains(where: { ($0.kind ?? .word) == .word }) else { throw VoxClipError.noSpeech }
        return raw
    }

    private func cachePaidResponse(_ entry: SpeechRawCacheEntry, at url: URL) async {
        for attempt in 0..<3 {
            do {
                try entry.write(url)
                return
            } catch {
                if attempt < 2 { try? await sleep(Double(attempt + 1) * 0.05) }
            }
        }
        await Log(logger: logger).write(.warn, category: "transcribe", message: "engine=elevenlabs cacheWriteFailed attempts=3 paidResponseRetainedForImport=true")
    }

    private func uploadBody(_ request: URLRequest, file: URL, delegate: ScribeUploadDelegate) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
            group.addTask { try await self.session.upload(for: request, fromFile: file, delegate: delegate) }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                if !delegate.connected.withLock({ $0 }) { throw URLError(.timedOut) }
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() { if let result { return result } }
            throw URLError(.networkConnectionLost)
        }
    }

    public func mapResponse(_ data: Data, diarize: Bool) async throws -> RawTranscript {
        struct Response: Decodable {
            struct Word: Decodable { let text: String; let type: String; let start: Double?; let end: Double?; let logprob: Double?; let speaker_id: String? }
            let language_code: String
            let language_probability: Double?
            let words: [Word]
            let transcription_id: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw VoxClipError.providerError("unexpected response shape", provider: "ElevenLabs", status: 200) }
        let unknownTypes = Set(response.words.map(\.type)).subtracting(["word", "spacing", "audio_event"])
        for type in unknownTypes.sorted() {
            let safe = type.range(of: "^[a-z_]{1,32}$", options: .regularExpression) == nil ? "unrecognized" : type
            await Log(logger: logger).write(.warn, category: "transcribe", message: "engine=elevenlabs unknownWordType=\(safe)")
        }
        let tokens = response.words.compactMap { word -> RawToken? in
            guard word.type == "word" || word.type == "audio_event" else { return nil }
            return RawToken(text: SpeechText.trim(word.text), start: word.start, end: word.end, conf: word.type == "word" ? word.logprob.map { min(1, max(0, exp($0))) } : nil, speaker: diarize ? word.speaker_id : nil, kind: word.type == "audio_event" ? .event : nil)
        }
        let language: String
        guard let catalog else { throw VoxClipError.sharedResourcesMissing }
        language = try await catalog.normalizeLanguage(response.language_code)
        if let identifier = response.transcription_id, identifier.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil {
            await Log(logger: logger).write(.info, category: "transcribe", message: "engine=elevenlabs transcription_id=\(identifier) words=\(tokens.count)")
        }
        return RawTranscript(engine: EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2"), grouping: GroupingRule(end: .lastToken, conf: .single, bracketEvents: false), tokens: tokens, language: language, languageProbability: response.language_probability, verbatim: true, timing: .native, providerRequestID: response.transcription_id)
    }

    private static func validateOptions(_ options: TranscriptionOptions) throws {
        if let count = options.numSpeakers, !options.diarize || !(1...32).contains(count) { throw VoxClipError.transcriptionFailed("Speaker count needs diarization and a value from 1 to 32") }
        guard options.keyterms.count <= 1000 else { throw VoxClipError.transcriptionFailed("At most 1000 keyterms are allowed") }
        for term in options.keyterms {
            guard !SpeechText.trim(term).isEmpty, term.unicodeScalars.count < 50, term.split(whereSeparator: { $0.isWhitespace }).count <= 5,
                  !term.contains(where: { "<>{}[]\\\r\n".contains($0) }) else { throw VoxClipError.transcriptionFailed("Invalid keyterm: \(term)") }
        }
    }
    static func multipart(_ request: TranscriptionRequest, boundary: String) throws -> URL {
        let options = request.plan.options
        try validateOptions(options)
        let url = request.audio.wav16k.deletingLastPathComponent().appendingPathComponent("scribe-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: url)
        do {
            func write(_ string: String) throws { try output.write(contentsOf: Data(string.utf8)) }
            func part(_ name: String, _ value: String) throws { try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n") }
            try part("model_id", "scribe_v2")
            if case .forced(let code) = request.plan.language { try part("language_code", SpeechText.primaryLanguage(code)) }
            try part("timestamps_granularity", "word")
            try part("tag_audio_events", "true")
            try part("diarize", options.diarize ? "true" : "false")
            if let count = options.numSpeakers { try part("num_speakers", String(count)) }
            for term in options.keyterms { try part("keyterms", term) }
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
            let input = try FileHandle(forReadingFrom: request.audio.wav16k)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: chunk) }
            try write("\r\n--\(boundary)--\r\n")
            try output.close()
            return url
        } catch { try? output.close(); try? FileManager.default.removeItem(at: url); throw error }
    }

    static func providerError(status: Int, data: Data, key: String, region: ElevenLabsRegion = .default) -> VoxClipError {
        let body = String(decoding: data, as: UTF8.self)
        let lower = body.lowercased()
        if lower.contains("quota") || lower.contains("credit") { return .quotaExceeded("ElevenLabs") }
        if status == 403 || status == 401 && lower.contains("permission") { return .keyPermissionMissing }
        if status == 401 { return .keyRejected("ElevenLabs", status: status) }
        if status == 429 { return .rateLimited("elevenlabs") }
        var message = "The request could not be completed."
        var authentication = false
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String { message = detail }
            else if let detail = object["detail"] as? [[String: Any]], let validation = detail.first?["msg"] as? String { message = validation }
            // ElevenLabs also answers {"detail": {"status": "...", "message": "..."}}.
            else if let detail = object["detail"] as? [String: Any] {
                if let text = (detail["message"] as? String) ?? (detail["status"] as? String) { message = text }
                authentication = detail["type"] as? String == "authentication_error" || [detail["code"], detail["status"]].contains { $0 as? String == "invalid_api_key" }
            }
        }
        // A residency host only knows keys from its own Enterprise workspace; ordinary keys fail there.
        if region.isResidency, authentication || status == 400 || status == 401 {
            message = "\(message) ElevenLabs \(region.rawValue.uppercased()) residency needs a key from a data-residency workspace; most accounts use Region: Default"
        } else if authentication { return .keyRejected("ElevenLabs", status: status) }
        let safe = Redactor(knownSecrets: [key]).redact(message.replacingOccurrences(of: key, with: "[REDACTED]"))
        return .providerError(String(safe.prefix(200)), provider: "ElevenLabs", status: status)
    }
}

final class ScribeUploadDelegate: NSObject, URLSessionTaskDelegate {
    let connected = Mutex(false)
    let callback: @Sendable (Int64, Int64) -> Void
    init(callback: @escaping @Sendable (Int64, Int64) -> Void) { self.callback = callback }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        connected.withLock { $0 = true }
        callback(totalBytesSent, totalBytesExpectedToSend)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.host == task.originalRequest?.url?.host && request.url?.scheme == task.originalRequest?.url?.scheme ? request : nil)
    }
}
