import Foundation

public actor FalLipsyncProvider: LipsyncProvider {
    public nonisolated let id = "fal"
    public nonisolated let models = [
        LipsyncModel(provider: "fal", id: "fal-ai/latentsync", tier: .fast, supportsRemap: false),
        LipsyncModel(provider: "fal", id: "fal-ai/sync-lipsync/v2:lipsync-2", tier: .quality, supportsRemap: true),
        LipsyncModel(provider: "fal", id: "fal-ai/sync-lipsync/v2:lipsync-2-pro", tier: .quality, supportsRemap: true),
        LipsyncModel(provider: "fal", id: "fal-ai/sync-lipsync/v3", tier: .best, supportsRemap: true)
    ]
    private struct Entry {
        let job: LipsyncJob
        let quote: LipsyncQuote
        let started: Duration
        var billing: LipsyncBillingStatus = .accepted
        var cancelled = false
        var cleanup: LipsyncCleanupStatus = .pending
        var spendWarning: VoiceLabSpendWarning?
        var polls = 0
        var terminal: LipsyncState?
        var result: URL?
        var pollTask: Task<LipsyncHTTPResponse, any Error>?
        var downloadTask: Task<Void, any Error>?
        var waiting = false
        var cancelling = false
        var cleaning = false
        var lease: LipsyncProviderQueue.Lease?
    }
    private let owner = UUID()
    private let keys: any KeyProvider
    private let http: any LipsyncHTTPClient
    private let logger: any Redacting
    private let spend: VoiceLabSpendLedger?
    private let now: @Sendable () -> Date
    private let monotonic: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let queue: LipsyncProviderQueue
    private var prices: VoiceLabPriceCatalog?
    private var quotes: [UUID: LipsyncQuote] = [:]
    private var entries: [String: Entry] = [:]
    private var active: String?
    private var submitting = false
    private var uncertain: UUID?
    private var diagnostic: (any LipsyncDiagnosticSink)?

    public func setDiagnostic(_ sink: (any LipsyncDiagnosticSink)?) { diagnostic = sink }

    /// The provider's clock (a test's fixed one), for what fal.ai still keeps (`LipsyncAttempt.refetchable`).
    public func date() -> Date { now() }

    public nonisolated var rewriteModel: LipsyncModel { models[3] }

    public init(keys: any KeyProvider, prices: VoiceLabPriceCatalog? = nil,
                logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path),
                spend: VoiceLabSpendLedger = VoiceLabSpendLedger(locations: DataLocations())) {
        self.keys = keys; self.prices = prices; self.logger = logger; self.spend = spend
        self.http = URLSessionLipsyncHTTPClient(); self.now = { Date() }
        self.monotonic = VoiceLabQuoteClock.continuousSource(); self.sleep = { try await Task.sleep(for: $0) }
        self.queue = .shared
    }

    package init(keys: any KeyProvider, prices: VoiceLabPriceCatalog, http: any LipsyncHTTPClient,
                 logger: any Redacting, spend: VoiceLabSpendLedger? = nil,
                 now: @escaping @Sendable () -> Date, monotonic: @escaping @Sendable () -> Duration,
                 sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.keys = keys; self.prices = prices; self.http = http; self.logger = logger; self.spend = spend
        self.now = now; self.monotonic = monotonic; self.sleep = sleep
        self.queue = LipsyncProviderQueue()
    }

    public func estimate(_ model: LipsyncModel, seconds: Double, fps: Double) async throws -> CostEstimate {
        try validate(model, seconds: seconds, fps: fps)
        if prices == nil {
            let shared = try SharedResources.locate()
            prices = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json")))
        }
        guard let prices else { throw VoxClipError.sharedResourcesMissing }
        let selection = model.id.split(separator: ":", maxSplits: 1).map(String.init)
        return try VoiceLabPricing.estimate(operation: .falLipsync(endpoint: selection[0]),
                                           model: selection.count == 2 ? selection[1] : nil, units: seconds, catalog: prices)
    }

    public func quote(model: LipsyncModel, video: LipsyncSignedInput, audio: LipsyncSignedInput,
                      options: LipsyncOptions, fps: Double) async throws -> LipsyncQuote {
        try validate(model, seconds: max(video.durationSeconds, audio.durationSeconds), fps: fps)
        guard video.contentType == "video/mp4", audio.contentType == "audio/wav",
              options.seed == nil || model.id == "fal-ai/latentsync",
              model.supportsRemap || (options.syncMode == .cutOff && abs(video.durationSeconds - audio.durationSeconds) <= 1 / fps)
        else { throw LipsyncError.invalidInput }
        let amount = try await estimate(model, seconds: max(video.durationSeconds, audio.durationSeconds), fps: fps)
        guard let usd = amount.usd, usd > 0, amount.basis != "unknown" else { throw LipsyncError.invalidInput }
        let fingerprint = try await keyFingerprint()
        let current = now()
        guard min(video.expiresAt, audio.expiresAt) > current.addingTimeInterval(LipsyncLimits.deadlineSeconds + 120) else {
            throw LipsyncError.expiredQuote
        }
        quotes = quotes.filter { $0.value.expiresAt > current }
        guard quotes.count < 64 else { throw LipsyncError.busy }
        let quote = LipsyncQuote(model: model, video: video, audio: audio, options: options, fps: fps, estimate: amount,
                                 expiresAt: current.addingTimeInterval(LipsyncLimits.quoteLifetimeSeconds),
                                 keyFingerprint: fingerprint, issuedAt: monotonic(), owner: owner)
        quotes[quote.id] = quote
        return quote
    }

    public func approve(_ quote: LipsyncQuote, consentStore: VoiceConsentStore, recordID: String,
                        acceptsPaidJob: Bool, acceptsMediaTransfer: Bool) async throws -> LipsyncApproval {
        guard acceptsPaidJob, acceptsMediaTransfer, quotes[quote.id] == quote else { throw LipsyncError.approvalRequired }
        try fresh(quote)
        quotes.removeValue(forKey: quote.id)
        let record = try await consentStore.load(recordID)
        try await consentStore.validateUse(record)
        guard try await keyFingerprint() == quote.keyFingerprint else { throw LipsyncError.approvalRequired }
        try fresh(quote)
        return LipsyncApproval(quote: quote, store: consentStore, record: record)
    }

    public func submit(_ model: LipsyncModel, video: URL, audio: URL, options: LipsyncOptions) async throws -> LipsyncJob {
        throw LipsyncError.approvalRequired
    }

    public func approvedProvider(using approval: LipsyncApproval) async throws -> any LipsyncProvider {
        let quote = approval.quote
        try fresh(quote)
        return ApprovedLipsyncProvider(provider: self, quote: quote, approval: approval)
    }

    public func submit(_ quote: LipsyncQuote, approval: LipsyncApproval) async throws -> LipsyncJob {
        if entries.count >= 64,
           let oldest = entries.values.filter({ $0.cleanup == .completed && $0.pollTask == nil && $0.downloadTask == nil })
               .sorted(by: { $0.job.submittedAt == $1.job.submittedAt ? $0.job.remoteID < $1.job.remoteID : $0.job.submittedAt < $1.job.submittedAt }).first {
            entries.removeValue(forKey: oldest.job.remoteID)
        }
        guard active == nil, !submitting, uncertain == nil, entries.count < 64 else { throw LipsyncError.busy }
        try fresh(quote)
        submitting = true
        defer { submitting = false }
        let lease = try await queue.acquire(account: id)
        do { return try await dispatch(quote, approval: approval, lease: lease) }
        catch {
            if uncertain != quote.id { await queue.release(lease) }
            throw error
        }
    }

    private func dispatch(_ quote: LipsyncQuote, approval: LipsyncApproval, lease: LipsyncProviderQueue.Lease) async throws -> LipsyncJob {
        try fresh(quote)
        let permit = try await approval.consume(quote)
        defer { permit.finish() }
        let key = try await credential()
        guard VoiceLabFingerprint.bytes(Data(key.utf8)) == quote.keyFingerprint else { throw LipsyncError.approvalRequired }
        try fresh(quote)
        try Task.checkCancellation()
        var body: [String: Any] = ["video_url": quote.video.url.absoluteString, "audio_url": quote.audio.url.absoluteString,
                                   "enable_safety_checker": true]
        let selection = quote.model.id.split(separator: ":", maxSplits: 1).map(String.init)
        if selection[0] == "fal-ai/latentsync" {
            body["guidance_scale"] = 1.0
            if let seed = quote.options.seed { body["seed"] = seed }
        } else {
            body["sync_mode"] = quote.options.syncMode.rawValue
            if selection.count == 2 { body["model"] = selection[1] }
        }
        await logger.register(secret: quote.video.url.absoluteString)
        await logger.register(secret: quote.audio.url.absoluteString)
        var request = request(URL(string: "https://queue.fal.run/\(selection[0])")!, method: "POST", key: key)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("{\"expiration_duration_seconds\":3600}", forHTTPHeaderField: "X-Fal-Object-Lifecycle-Preference")
        try fresh(quote)
        try Task.checkCancellation()
        uncertain = quote.id
        await diagnostic?.record(.init(stage: .submit))
        let response: LipsyncHTTPResponse
        do {
            var received = try await http.send(request, limit: LipsyncLimits.maximumJSONBytes, permit: permit)
            for attempt in 1...2 where received.status == 429 || (500...599).contains(received.status) {
                uncertain = nil
                try await sleep(.seconds(attempt))
                try fresh(quote)
                try Task.checkCancellation()
                uncertain = quote.id
                received = try await http.send(request, limit: LipsyncLimits.maximumJSONBytes, permit: permit)
            }
            response = received
        }
        catch {
            if error is VoiceConsentError {
                uncertain = nil
                throw error
            }
            await log("submit-uncertain")
            await diagnostic?.record(.init(stage: .failure, error: .submissionUncertain))
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw LipsyncError.submissionUncertain
        }
        guard (200...299).contains(response.status) else {
            if (400...599).contains(response.status) {
                uncertain = nil
                throw LipsyncError.http(response.status)
            }
            throw LipsyncError.submissionUncertain
        }
        guard let document = try? json(response) else { throw LipsyncError.submissionUncertain }
        guard let remoteID = document["request_id"] as? String, UUID(uuidString: remoteID) != nil,
              entries[remoteID] == nil,
              let status = (document["status_url"] as? String).flatMap(URL.init(string:)),
              let result = (document["response_url"] as? String).flatMap(URL.init(string:)),
              let cancel = (document["cancel_url"] as? String).flatMap(URL.init(string:)) else { throw LipsyncError.submissionUncertain }
        do {
            try LipsyncURLPolicy.queue(status, model: quote.model, requestID: remoteID, suffix: "/status")
            try LipsyncURLPolicy.queue(result, model: quote.model, requestID: remoteID, suffix: "")
            try LipsyncURLPolicy.queue(cancel, model: quote.model, requestID: remoteID, suffix: "/cancel")
        } catch { throw LipsyncError.submissionUncertain }
        let job = LipsyncJob(model: quote.model, remoteID: remoteID, statusURL: status, responseURL: result,
                             cancelURL: cancel, submittedAt: now())
        entries[remoteID] = Entry(job: job, quote: quote, started: monotonic(), lease: lease)
        active = remoteID; uncertain = nil
        if let spend { entries[remoteID]?.spendWarning = await spend.record(quote.estimate, at: job.submittedAt) }
        await log("accepted")
        await diagnostic?.record(.init(stage: .submit, requestID: remoteID, status: response.status))
        if Task.isCancelled { await self.cancel(job) }
        return job
    }

    public func status(quoteID: UUID) -> LipsyncJobStatus? {
        if uncertain == quoteID {
            return LipsyncJobStatus(quoteID: quoteID, job: nil, billing: .submissionUncertain, cancelled: false,
                                    cleanup: .pending, spendWarning: nil)
        }
        guard let entry = entries.values.first(where: { $0.quote.id == quoteID }) else { return nil }
        return LipsyncJobStatus(quoteID: quoteID, job: entry.job, billing: entry.billing, cancelled: entry.cancelled,
                                cleanup: entry.cleanup, spendWarning: entry.spendWarning)
    }

    public func quote(for job: LipsyncJob) throws -> LipsyncQuote { try entry(job).quote }

    public func poll(_ job: LipsyncJob) async throws -> LipsyncState {
        try Task.checkCancellation()
        var current = try entry(job)
        guard !current.cancelled else { throw CancellationError() }
        if let terminal = current.terminal { return terminal }
        guard current.pollTask == nil else { throw LipsyncError.busy }
        guard current.polls < LipsyncLimits.maximumPolls, elapsed(current) < LipsyncLimits.deadlineSeconds else {
            await cancel(job); throw LipsyncError.deadlineExceeded
        }
        current.polls += 1; entries[job.remoteID] = current
        guard let url = job.statusURL else { throw LipsyncError.invalidResponse }
        let response = try await fetch(job, url: url)
        let body = try json(response)
        let stage: LipsyncDiagnosticEvent.Stage = body["status"] as? String == "IN_QUEUE" ? .queued :
            body["status"] as? String == "COMPLETED" ? .completed : .running
        await diagnostic?.record(.init(stage: stage, requestID: job.remoteID, status: response.status, seconds: elapsed(current)))
        try stillActive(job)
        if providerError(body) {
            return try await terminal(job, state: .failed(code: "provider_error", message: "Lip sync failed. Your original media and edits are safe."))
        }
        switch body["status"] as? String {
        case "IN_QUEUE":
            let position = body["queue_position"] as? Int
            guard position == nil || (0...1_000_000).contains(position!) else { throw LipsyncError.invalidResponse }
            return .queued(position: position)
        case "IN_PROGRESS": return .running(progress: nil)
        case "COMPLETED":
            guard let url = job.responseURL else { throw LipsyncError.invalidResponse }
            let result = try json(try await fetch(job, url: url))
            try stillActive(job)
            guard !providerError(result) else {
                return try await terminal(job, state: .failed(code: "provider_error", message: "Lip sync failed. Your original media and edits are safe."))
            }
            guard let video = result["video"] as? [String: Any], let text = video["url"] as? String,
                  let output = URL(string: text), video["content_type"] == nil || video["content_type"] as? String == "video/mp4"
            else { throw LipsyncError.invalidResponse }
            if let bytes = video["file_size"] {
                guard let count = bytes as? Int, (1...LipsyncLimits.maximumVideoBytes).contains(count) else { throw LipsyncError.responseTooLarge }
            }
            try LipsyncURLPolicy.result(output)
            entries[job.remoteID]?.result = output
            await logger.register(secret: output.absoluteString)
            try stillActive(job)
            return try await terminal(job, state: .done(output))
        default: throw LipsyncError.invalidResponse
        }
    }

    public func wait(_ job: LipsyncJob, onState: @escaping @Sendable (LipsyncState) async -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        let initial = try entry(job)
        guard !initial.cancelled else { throw CancellationError() }
        if case .done(let result) = initial.terminal { return result }
        guard !initial.waiting else { throw LipsyncError.busy }
        entries[job.remoteID]?.waiting = true
        defer { entries[job.remoteID]?.waiting = false }
        do {
            return try await withTaskCancellationHandler {
                for _ in 0..<LipsyncLimits.maximumPolls {
                    try Task.checkCancellation()
                    let current = try entry(job)
                    guard !current.cancelled else { throw CancellationError() }
                    let seconds = elapsed(current) < 120 ? 5.0 : 15.0
                    guard elapsed(current) + seconds <= LipsyncLimits.deadlineSeconds else { throw LipsyncError.deadlineExceeded }
                    try await sleep(.seconds(seconds))
                    let state = try await poll(job)
                    try stillActive(job)
                    try Task.checkCancellation()
                    await onState(state)
                    try stillActive(job)
                    switch state {
                    case .done(let result): return result
                    case .failed: throw LipsyncError.invalidMedia
                    default: continue
                    }
                }
                throw LipsyncError.deadlineExceeded
            } onCancel: { Task { await self.cancel(job) } }
        } catch {
            if Task.isCancelled || error is CancellationError || error as? LipsyncError == .deadlineExceeded { await cancel(job) }
            throw error
        }
    }

    public func cancel(_ job: LipsyncJob) async {
        guard var current = try? entry(job), !current.cancelling, !current.cancelled else { return }
        current.cancelled = true; current.cancelling = true; current.result = nil
        current.pollTask?.cancel(); current.downloadTask?.cancel()
        current.billing = .cancellationRequested
        entries[job.remoteID] = current
        defer { entries[job.remoteID]?.cancelling = false }
        guard let url = job.cancelURL else { return }
        do {
            let key = try await credential(for: current.quote)
            let request = request(url, method: "PUT", key: key)
            let http = http
            let response = try await Task { try await http.send(request, limit: LipsyncLimits.maximumJSONBytes, permit: nil) }.value
            let body = try json(response, accepts: [200, 202, 400, 404])
            await diagnostic?.record(.init(stage: .cancel, requestID: job.remoteID, status: response.status, seconds: elapsed(current)))
            if response.status == 200, body["status"] as? String == "OK" {
                entries[job.remoteID]?.billing = .removedBeforeRun
                entries[job.remoteID]?.terminal = .failed(code: "cancelled", message: "")
                if active == job.remoteID { active = nil }
                await release(job)
            } else if response.status == 400, body["status"] as? String == "ALREADY_COMPLETED" {
                entries[job.remoteID]?.billing = .alreadyCompleted
                entries[job.remoteID]?.terminal = .failed(code: "cancelled", message: "")
                if active == job.remoteID { active = nil }
                await release(job)
            }
        } catch { await log("cancel-unconfirmed") }
    }

    public func download(_ result: URL, to file: URL) async throws {
        try LipsyncURLPolicy.result(result)
        guard let current = entries.values.first(where: { $0.result == result && !$0.cancelled && $0.cleanup != .completed }),
              current.downloadTask == nil else { throw LipsyncError.unknownJob }
        var request = URLRequest(url: result)
        request.setValue("video/mp4", forHTTPHeaderField: "Accept")
        let http = http
        let task = Task { try await http.download(request, to: file, limit: LipsyncLimits.maximumVideoBytes) }
        entries[current.job.remoteID]?.downloadTask = task
        defer { entries[current.job.remoteID]?.downloadTask = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        do { try Task.checkCancellation(); try stillActive(current.job) }
        catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    public func cleanup(_ job: LipsyncJob) async {
        guard var current = try? entry(job), current.cleanup != .completed, !current.cleaning,
              current.pollTask == nil, current.downloadTask == nil,
              current.terminal != nil || current.cancelled else { return }
        current.cleaning = true; entries[job.remoteID] = current
        defer { entries[job.remoteID]?.cleaning = false }
        let key: String
        do { key = try await credential(for: current.quote) } catch {
            entries[job.remoteID]?.cleanup = .failed
            await diagnostic?.record(.init(stage: .failure, requestID: job.remoteID, error: .network))
            await log("cleanup-unconfirmed reason=key")
            return
        }
        if let status = await deletePayloads(requestID: job.remoteID, key: key) {
            entries[job.remoteID]?.cleanup = .completed
            await diagnostic?.record(.init(stage: .cleanup, requestID: job.remoteID, status: status, seconds: elapsed(current)))
            entries[job.remoteID]?.result = nil
            if active == job.remoteID { active = nil }
            await release(job)
        } else {
            entries[job.remoteID]?.cleanup = .failed
            await diagnostic?.record(.init(stage: .failure, requestID: job.remoteID, error: .network))
        }
    }

    /// `DELETE https://api.fal.ai/v1/models/requests/{id}/payloads` (fal.ai's Platform API): 200 with
    /// `{"cdn_delete_results":[{"link":…,"exception":null}]}` deletes the request's payloads and its output files; each
    /// `exception` is null on success. Only output files go; fal.ai never deletes a request's input files this way (they
    /// expire with the upload's one-hour lifecycle). The key needs `models:requests:write` and `assets:write` (fal.ai's
    /// FULL preset). Returns the confirmed status, or nil after logging why not (the HTTP status, never a URL or key).
    private func deletePayloads(requestID: String, key: String) async -> Int? {
        guard UUID(uuidString: requestID) != nil else { return nil }
        let url = URL(string: "https://api.fal.ai/v1/models/requests/\(requestID)/payloads")!
        let response: LipsyncHTTPResponse
        do { response = try await http.send(request(url, method: "DELETE", key: key), limit: LipsyncLimits.maximumJSONBytes, permit: nil) }
        catch {
            // The error's case only (network, invalidResponse, unsafeURL, responseTooLarge…), never a URL or a key.
            await log("cleanup-unconfirmed reason=\((error as? LipsyncError).map { "\($0)" } ?? "network")")
            return nil
        }
        guard response.status == 200 else {
            await log("cleanup-unconfirmed status=\(response.status)")
            return nil
        }
        guard let body = try? json(response), let results = body["cdn_delete_results"] as? [[String: Any]],
              results.allSatisfy({ $0["link"] is String && $0["exception"] is NSNull }) else {
            let failed = ((try? json(response))?["cdn_delete_results"] as? [[String: Any]])?.filter { !($0["exception"] is NSNull) }.count
            await log("cleanup-unconfirmed status=200 reason=\(failed.map { "exceptions=\($0)" } ?? "body")")
            return nil
        }
        return response.status
    }

    /// Deletes a recovered attempt's payloads at fal.ai after its result was imported (`refetch`): no job entry is needed.
    @discardableResult public func cleanup(requestID: String) async -> Bool {
        guard let key = try? await credential() else {
            await log("cleanup-unconfirmed reason=key")
            return false
        }
        return await deletePayloads(requestID: requestID, key: key) != nil
    }

    /// Fetches a finished request's result again by its request ID, for free (`GET https://queue.fal.run/{owner}/{app}/requests/{id}`,
    /// fal.ai's queue API: kept for the output's lifecycle, an hour here), and downloads its video to `file`. The paid
    /// attempt's sidecar keeps only the request ID and the model; the signed result URL is read here and never stored.
    public func refetch(requestID: String, model: LipsyncModel, to file: URL) async throws {
        guard models.contains(model), UUID(uuidString: requestID) != nil else { throw LipsyncError.invalidInput }
        let key = try await credential()
        let app = model.id.hasPrefix("fal-ai/latentsync") ? "fal-ai/latentsync" : "fal-ai/sync-lipsync"
        let url = URL(string: "https://queue.fal.run/\(app)/requests/\(requestID)")!
        try LipsyncURLPolicy.queue(url, model: model, requestID: requestID, suffix: "")
        let body = try json(try await http.send(request(url, method: "GET", key: key), limit: LipsyncLimits.maximumJSONBytes, permit: nil))
        guard !providerError(body), let video = body["video"] as? [String: Any], let text = video["url"] as? String,
              let output = URL(string: text), video["content_type"] == nil || video["content_type"] as? String == "video/mp4"
        else { throw LipsyncError.invalidResponse }
        if let bytes = video["file_size"] {
            guard let count = bytes as? Int, (1...LipsyncLimits.maximumVideoBytes).contains(count) else { throw LipsyncError.responseTooLarge }
        }
        try LipsyncURLPolicy.result(output)
        await logger.register(secret: output.absoluteString)
        var download = URLRequest(url: output)
        download.setValue("video/mp4", forHTTPHeaderField: "Accept")
        try await http.download(download, to: file, limit: LipsyncLimits.maximumVideoBytes)
        await log("refetched")
    }

    /// One `lipsync` log line from the result import (a check's name and numbers; never URLs, keys or file names).
    public func note(_ line: String) async {
        await logger.write(LogEntry(level: .info, category: "lipsync", message: await logger.redact(line)))
    }

    private func validate(_ model: LipsyncModel, seconds: Double, fps: Double) throws {
        guard models.contains(model) else { throw LipsyncError.unsupportedModel }
        guard seconds.isFinite, (3...300).contains(seconds), fps.isFinite, (1...120).contains(fps) else { throw LipsyncError.invalidInput }
    }

    private func fresh(_ quote: LipsyncQuote) throws {
        guard quote.owner == owner else { throw LipsyncError.approvalRequired }
        let age = monotonic() - quote.issuedAt
        guard age >= .zero, age < .seconds(LipsyncLimits.quoteLifetimeSeconds), now() < quote.expiresAt,
              min(quote.video.expiresAt, quote.audio.expiresAt) > now().addingTimeInterval(LipsyncLimits.deadlineSeconds + 120)
        else { throw LipsyncError.expiredQuote }
    }

    private func credential() async throws -> String {
        guard let raw = try await keys.key(for: "fal"), !raw.isEmpty, raw.utf8.count <= 4_096,
              raw.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw LipsyncError.missingKey }
        await logger.register(secret: raw)
        return raw
    }
    private func credential(for quote: LipsyncQuote) async throws -> String {
        let key = try await credential()
        guard VoiceLabFingerprint.bytes(Data(key.utf8)) == quote.keyFingerprint else { throw LipsyncError.missingKey }
        return key
    }
    private func keyFingerprint() async throws -> String {
        let key = try await credential()
        return VoiceLabFingerprint.bytes(Data(key.utf8))
    }
    private func request(_ url: URL, method: String, key: String) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 30
        request.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func json(_ response: LipsyncHTTPResponse, accepts: Set<Int> = Set(200...299)) throws -> [String: Any] {
        guard accepts.contains(response.status) else { throw LipsyncError.http(response.status) }
        guard response.body.count <= LipsyncLimits.maximumJSONBytes else { throw LipsyncError.responseTooLarge }
        guard response.contentType == "application/json" || response.contentType?.hasSuffix("+json") == true,
              let result = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw LipsyncError.invalidResponse }
        return result
    }
    private func providerError(_ body: [String: Any]) -> Bool {
        ["error", "error_type"].contains { key in body[key].map { !($0 is NSNull) } ?? false }
    }
    private func entry(_ job: LipsyncJob) throws -> Entry {
        guard let result = entries[job.remoteID], result.job == job else { throw LipsyncError.unknownJob }
        return result
    }
    private func stillActive(_ job: LipsyncJob) throws {
        try Task.checkCancellation()
        guard try !entry(job).cancelled else { throw CancellationError() }
    }
    private func elapsed(_ entry: Entry) -> Double {
        let age = monotonic() - entry.started
        return max(0, Double(age.components.seconds) + Double(age.components.attoseconds) / 1e18)
    }
    private func terminal(_ job: LipsyncJob, state: LipsyncState) async throws -> LipsyncState {
        entries[job.remoteID]?.terminal = state
        if active == job.remoteID { active = nil }
        await release(job)
        try stillActive(job)
        return state
    }
    private func release(_ job: LipsyncJob) async {
        if let lease = entries[job.remoteID]?.lease {
            entries[job.remoteID]?.lease = nil
            await queue.release(lease)
        }
    }
    private func fetch(_ job: LipsyncJob, url: URL) async throws -> LipsyncHTTPResponse {
        let current = try entry(job)
        let key = try await credential(for: current.quote)
        try stillActive(job); try Task.checkCancellation()
        guard entries[job.remoteID]?.pollTask == nil else { throw LipsyncError.busy }
        let remaining = LipsyncLimits.deadlineSeconds - elapsed(try entry(job))
        guard remaining > 0 else { await cancel(job); throw LipsyncError.deadlineExceeded }
        var request = request(url, method: "GET", key: key)
        request.timeoutInterval = min(30, remaining)
        let http = http
        let task = Task { try await http.send(request, limit: LipsyncLimits.maximumJSONBytes, permit: nil) }
        entries[job.remoteID]?.pollTask = task
        defer { entries[job.remoteID]?.pollTask = nil }
        do {
            let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try stillActive(job)
            guard elapsed(try entry(job)) < LipsyncLimits.deadlineSeconds else {
                await cancel(job); throw LipsyncError.deadlineExceeded
            }
            return response
        } catch {
            if elapsed(try entry(job)) >= LipsyncLimits.deadlineSeconds {
                await cancel(job); throw LipsyncError.deadlineExceeded
            }
            throw error
        }
    }
    private func log(_ event: String) async {
        await logger.write(LogEntry(level: .info, category: "lipsync", message: await logger.redact("lipsync provider=fal event=\(event)")))
    }
}

extension FalLipsyncProvider {
    public func prepareApprovedUpload(video: LipsyncUploadFile, audio: LipsyncUploadFile, options: LipsyncOptions,
                                      fps: Double, consentStore: VoiceConsentStore, recordID: String,
                                      acceptsPaidJob: Bool, acceptsMediaTransfer: Bool,
                                      model chosen: LipsyncModel? = nil) async throws -> (LipsyncQuote, LipsyncApproval) {
        guard acceptsPaidJob, acceptsMediaTransfer, video.contentType == "video/mp4", audio.contentType == "audio/wav" else {
            throw LipsyncError.approvalRequired
        }
        // Rewrite's phrases use sync-3; a whole-clip revoice picks lipsync-2 or sync-3 (ADR-R46). Only this provider's models.
        let model = chosen ?? rewriteModel
        guard models.contains(model) else { throw LipsyncError.invalidInput }
        try validate(model, seconds: max(video.durationSeconds, audio.durationSeconds), fps: fps)
        let record = try await consentStore.load(recordID)
        try await consentStore.validateUse(record)
        let fingerprint = try await keyFingerprint()
        let permit = try await consentStore.dispatchPermit(record, requestID: UUID())
        defer { permit.finish() }
        let key = try await credential()
        let uploadedVideo = try await upload(video, key: key, permit: permit)
        let uploadedAudio = try await upload(audio, key: key, permit: permit)
        guard try await keyFingerprint() == fingerprint else { throw LipsyncError.missingKey }
        let quote = try await quote(model: model, video: uploadedVideo, audio: uploadedAudio, options: options, fps: fps)
        let approval = try await approve(quote, consentStore: consentStore, recordID: recordID,
                                         acceptsPaidJob: acceptsPaidJob, acceptsMediaTransfer: acceptsMediaTransfer)
        return (quote, approval)
    }

    private func upload(_ file: LipsyncUploadFile, key: String, permit: VoiceDispatchPermit) async throws -> LipsyncSignedInput {
        try Task.checkCancellation()
        let initiatedAt = now()
        var initiate = request(URL(string: "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")!, method: "POST", key: key)
        initiate.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initiate.setValue("{\"expiration_duration_seconds\":3600}", forHTTPHeaderField: "X-Fal-Object-Lifecycle")
        initiate.httpBody = try JSONSerialization.data(withJSONObject: ["file_name": file.contentType == "video/mp4" ? "window.mp4" : "mixed.wav", "content_type": file.contentType])
        let body = try json(await http.send(initiate, limit: LipsyncLimits.maximumJSONBytes, permit: permit))
        guard let target = (body["upload_url"] as? String).flatMap(URL.init(string:)),
              let result = (body["file_url"] as? String).flatMap(URL.init(string:)) else { throw LipsyncError.invalidResponse }
        let components = try LipsyncURLPolicy.components(target)
        guard let host = components.host, LipsyncURLPolicy.resultHosts.contains(host) || host == "storage.fal.ai" else {
            throw LipsyncError.unsafeURL
        }
        try LipsyncURLPolicy.result(result)
        await logger.register(secret: target.absoluteString)
        await logger.register(secret: result.absoluteString)
        var upload = URLRequest(url: target)
        upload.httpMethod = "PUT"; upload.httpBody = file.data; upload.timeoutInterval = 120
        upload.setValue(file.contentType, forHTTPHeaderField: "Content-Type")
        let response = try await http.send(upload, limit: LipsyncLimits.maximumJSONBytes, permit: permit)
        await diagnostic?.record(.init(stage: .upload, status: response.status, seconds: now().timeIntervalSince(initiatedAt), bytes: file.data.count))
        guard (200...299).contains(response.status) else { throw LipsyncError.http(response.status) }
        return try LipsyncSignedInput(uploadedURL: result, file: file, expiresAt: initiatedAt.addingTimeInterval(3600))
    }
}
