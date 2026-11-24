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
        /// fal.ai's own failure of the job (`error_type`), once its status or result said so.
        var providerFailure: LipsyncError?
        /// The last non-2xx status or result answer's `Retry-After`.
        var retryAfter: Double?
    }
    private let owner = UUID()
    private let keys: any KeyProvider
    private let http: any LipsyncHTTPClient
    private let logger: any Redacting
    private let spend: VoiceLabSpendLedger?
    private let onCleanupDenial: (@Sendable (String) async -> Void)?
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
    /// The account's lip-sync slot, taken before the uploads (`prepareApprovedUpload`) and handed to the submit.
    private var reserved: LipsyncProviderQueue.Lease?
    private var diagnostic: (any LipsyncDiagnosticSink)?
    /// A status or result fetch that fails transiently is tried again this many times in a row before the wait gives up.
    static let pollRetries = 6

    public func setDiagnostic(_ sink: (any LipsyncDiagnosticSink)?) { diagnostic = sink }

    /// The provider's clock (a test's fixed one), for what fal.ai still keeps (`LipsyncAttempt.refetchable`).
    public func date() -> Date { now() }

    public nonisolated var rewriteModel: LipsyncModel { models[3] }

    public init(keys: any KeyProvider, prices: VoiceLabPriceCatalog? = nil,
                logger: any Redacting = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path),
                spend: VoiceLabSpendLedger = VoiceLabSpendLedger(locations: DataLocations()),
                onCleanupDenial: (@Sendable (String) async -> Void)? = nil) {
        self.keys = keys; self.prices = prices; self.logger = logger; self.spend = spend
        self.onCleanupDenial = onCleanupDenial
        self.http = URLSessionLipsyncHTTPClient(); self.now = { Date() }
        self.monotonic = VoiceLabQuoteClock.continuousSource(); self.sleep = { try await Task.sleep(for: $0) }
        self.queue = .shared
    }

    /// `queue` is the account's one-job slot: a test's own, shared by the providers it makes; the app's is `.shared`.
    package init(keys: any KeyProvider, prices: VoiceLabPriceCatalog, http: any LipsyncHTTPClient,
                 logger: any Redacting, spend: VoiceLabSpendLedger? = nil,
                 now: @escaping @Sendable () -> Date, monotonic: @escaping @Sendable () -> Duration,
                 sleep: @escaping @Sendable (Duration) async throws -> Void, queue: LipsyncProviderQueue? = nil,
                 onCleanupDenial: (@Sendable (String) async -> Void)? = nil) {
        self.keys = keys; self.prices = prices; self.http = http; self.logger = logger; self.spend = spend
        self.onCleanupDenial = onCleanupDenial
        self.now = now; self.monotonic = monotonic; self.sleep = sleep
        self.queue = queue ?? LipsyncProviderQueue(clock: monotonic)
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
        let lease: LipsyncProviderQueue.Lease
        do {
            guard active == nil, !submitting, uncertain == nil, entries.count < 64 else { throw LipsyncError.busy }
            try fresh(quote)
            lease = try await reserveSlot()
            reserved = nil
        } catch {
            await releaseReservation()
            throw error
        }
        submitting = true
        defer { submitting = false }
        do { return try await dispatch(quote, approval: approval, lease: lease) }
        catch {
            // A refused, failed or uncertain submit gives the slot back: an uncertain one stays blocked by this provider's
            // own flag and the session's (it never resubmits by itself), and holding the account's slot protects nothing.
            await queue.release(lease)
            throw error
        }
    }

    /// Takes the account's one lip-sync slot (voice-lab §9.6), or throws `busy` at once while another run holds it.
    private func reserveSlot() async throws -> LipsyncProviderQueue.Lease {
        if let reserved { return reserved }
        let lease = try await queue.reserve(account: id, for: LipsyncLimits.deadlineSeconds)
        reserved = lease
        return lease
    }

    private func releaseReservation() async {
        guard let lease = reserved else { return }
        reserved = nil
        await queue.release(lease)
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
        let (job, status, rebuilt) = try await submitToQueue(request, quote: quote, permit: permit)
        entries[job.remoteID] = Entry(job: job, quote: quote, started: monotonic(), lease: lease)
        active = job.remoteID; uncertain = nil
        // The slot is the job's until its deadline and the result's download; a lease no one gives back ends then.
        await queue.renew(lease, for: LipsyncLimits.deadlineSeconds + 300)
        if let spend { entries[job.remoteID]?.spendWarning = await spend.record(quote.estimate, at: job.submittedAt) }
        await log("accepted")
        if rebuilt > 0 { await log("receipt-urls-rebuilt count=\(rebuilt)") }
        await diagnostic?.record(.init(stage: .submit, requestID: job.remoteID, status: status))
        if Task.isCancelled { await self.cancel(job) }
        return job
    }

    /// The paid POST (voice-lab §9.4 step 6). fal.ai answers 429 (rate limit) and 503 (no capacity) before it queues
    /// anything: those are tried again at most twice, after 1 s and 2 s or the answer's `Retry-After` (up to 30 s), then
    /// stop as not submitted. Any other 4xx (408 and 499 aside) is final and free. A lost answer, a 500, 502, 504 or any
    /// other reply after the body was sent can't prove fal.ai didn't queue a billed job: the charge is unknown.
    private func submitToQueue(_ request: URLRequest, quote: LipsyncQuote, permit: VoiceDispatchPermit) async throws -> (LipsyncJob, Int, Int) {
        try fresh(quote)
        try Task.checkCancellation()
        await diagnostic?.record(.init(stage: .submit))
        var retries = 0
        while true {
            try fresh(quote)
            try Task.checkCancellation()
            uncertain = quote.id
            let response: LipsyncHTTPResponse
            do {
                response = try await http.send(request, limit: LipsyncLimits.maximumJSONBytes, permit: permit)
            } catch let error as VoiceConsentError {
                uncertain = nil
                throw error
            } catch {
                let failure = await uncertainSubmission(status: nil)
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw failure
            }
            let status = response.status
            if status == 429 || status == 503 || ((400...499).contains(status) && status != 408 && status != 499) {
                uncertain = nil
                await diagnostic?.record(.init(stage: .submit, status: status, error: .http(status)))
                if status == 429 || status == 503, retries < 2 {
                    retries += 1
                    try await sleep(.seconds(max(Double(retries), min(response.retryAfter ?? 0, 30))))
                    continue
                }
                throw LipsyncError.http(status)
            }
            do {
                let (job, rebuilt) = try queueReceipt(response, model: quote.model)
                return (job, status, rebuilt)
            } catch { throw await uncertainSubmission(status: status) }
        }
    }

    private func uncertainSubmission(status: Int?) async -> LipsyncError {
        await log("submit-uncertain")
        await diagnostic?.record(.init(stage: .failure, status: status, error: .submissionUncertain))
        return .submissionUncertain
    }

    /// The accepted job from a 2xx receipt, and how many follow-up URLs were built from the queue path. The request ID is
    /// what fal.ai bills under: once a valid one is read, a follow-up URL that is missing, null or fails the exact
    /// `queue.fal.run/<owner>/<app>/requests/<id>` check is built from that path instead (its host and path are fixed and
    /// safe, and the key only ever goes there), so a known paid job is never dropped as "charge unknown".
    private func queueReceipt(_ response: LipsyncHTTPResponse, model: LipsyncModel) throws -> (LipsyncJob, Int) {
        let document = try json(response)
        guard let remoteID = document["request_id"] as? String, UUID(uuidString: remoteID) != nil,
              entries[remoteID] == nil else { throw LipsyncError.invalidResponse }
        var rebuilt = 0
        func followUpURL(_ field: String, suffix: String) -> URL {
            let path = LipsyncURLPolicy.queuePath(model: model, requestID: remoteID, suffix: suffix)
            let built = URL(string: "https://queue.fal.run\(path)")!
            guard let value = document[field], !(value is NSNull) else { return built }
            guard let text = value as? String, let supplied = URL(string: text),
                  (try? LipsyncURLPolicy.queue(supplied, model: model, requestID: remoteID, suffix: suffix)) != nil else {
                rebuilt += 1
                return built
            }
            return supplied
        }
        let job = LipsyncJob(model: model, remoteID: remoteID, statusURL: followUpURL("status_url", suffix: "/status"),
            responseURL: followUpURL("response_url", suffix: ""), cancelURL: followUpURL("cancel_url", suffix: "/cancel"),
            submittedAt: now())
        return (job, rebuilt)
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
        let (body, status) = try await fetchJSON(job, url: url, stage: "status")
        let stage: LipsyncDiagnosticEvent.Stage = body["status"] as? String == "IN_QUEUE" ? .queued :
            body["status"] as? String == "COMPLETED" ? .completed : .running
        await diagnostic?.record(.init(stage: stage, requestID: job.remoteID, status: status, seconds: elapsed(current)))
        try stillActive(job)
        if providerError(body) { return try await providerFailed(job, body) }
        switch body["status"] as? String {
        case "IN_QUEUE":
            let position = body["queue_position"] as? Int
            guard position == nil || (0...1_000_000).contains(position!) else { throw LipsyncError.invalidResponse }
            return .queued(position: position)
        case "IN_PROGRESS": return .running(progress: nil)
        case "COMPLETED":
            guard let url = job.responseURL else { throw LipsyncError.invalidResponse }
            let (result, _) = try await fetchJSON(job, url: url, stage: "result")
            try stillActive(job)
            guard !providerError(result) else { return try await providerFailed(job, result) }
            let output = try resultVideo(result)
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
                // A status or result fetch that fails for a passing reason (the network, a timeout, a body VoxClip couldn't
                // read, 408, 429, 5xx) is tried again after a backoff, within the deadline and the poll budget; a job is
                // never given up for one blip while fal.ai keeps working on it (and billing it).
                var failures = 0
                for _ in 0..<LipsyncLimits.maximumPolls {
                    try Task.checkCancellation()
                    let current = try entry(job)
                    guard !current.cancelled else { throw CancellationError() }
                    let seconds = failures == 0 ? (elapsed(current) < 120 ? 5.0 : 15.0) : Self.backoff(failures, retryAfter: current.retryAfter)
                    guard elapsed(current) + seconds <= LipsyncLimits.deadlineSeconds else { throw LipsyncError.deadlineExceeded }
                    try await sleep(.seconds(seconds))
                    let state: LipsyncState
                    do { state = try await poll(job) }
                    catch let error as LipsyncError where error.isTransient && failures < Self.pollRetries {
                        failures += 1
                        continue
                    }
                    failures = 0
                    try stillActive(job)
                    try Task.checkCancellation()
                    await onState(state)
                    try stillActive(job)
                    switch state {
                    case .done(let result): return result
                    case .failed: throw entries[job.remoteID]?.providerFailure ?? LipsyncError.providerFailed("provider_error")
                    default: continue
                    }
                }
                throw LipsyncError.deadlineExceeded
            } onCancel: { Task { await self.cancel(job) } }
        } catch {
            if Task.isCancelled || error is CancellationError || error as? LipsyncError == .deadlineExceeded { await cancel(job) }
            // The run stops tracking a job it gave up polling: the slot goes back (the attempt's record keeps the request
            // for a free check later), and a later run's recovery asks fal.ai where the job is.
            else { await untrack(job) }
            throw error
        }
    }

    /// The wait before the `failures`-th try of a failed status or result fetch: 5, 10, 20, 40, then 60 s, or the answer's
    /// `Retry-After` when that is longer.
    static func backoff(_ failures: Int, retryAfter: Double?) -> Double {
        let doubling = 5 * pow(2, Double(max(0, failures - 1)))
        return max(min(doubling, 60), retryAfter ?? 0)
    }

    /// The job is finished at fal.ai (terminal `.done`): it is billed, and its result must be kept, not cancelled or deleted.
    public func isDone(_ job: LipsyncJob) -> Bool {
        if case .done = (try? entry(job))?.terminal { return true }
        return false
    }

    /// The run stops tracking `job` (it gave up polling it, or it ended): the account's slot goes back. The job's entry
    /// stays, so its status, cleanup and billing still answer.
    public func untrack(_ job: LipsyncJob) async {
        if active == job.remoteID { active = nil }
        await release(job)
    }

    public func cancel(_ job: LipsyncJob) async {
        guard var current = try? entry(job), !current.cancelling, !current.cancelled else { return }
        // A finished job is billed and its result is the paid output: a cancel that lands after fal.ai finished only stops
        // the caller, never the import that keeps the result.
        if case .done = current.terminal { return }
        current.cancelled = true; current.cancelling = true; current.result = nil
        current.pollTask?.cancel(); current.downloadTask?.cancel()
        current.billing = .cancellationRequested
        entries[job.remoteID] = current
        await requestCancel(job, current: current)
        entries[job.remoteID]?.cancelling = false
        // Whatever fal.ai answered (a 202 may still finish and bill), the run stops tracking the job.
        await untrack(job)
    }

    private func requestCancel(_ job: LipsyncJob, current: Entry) async {
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
            await untrack(job)
            return
        }
        let finishedResult = if case .done = current.terminal { true } else { false }
        if let status = await deletePayloads(requestID: job.remoteID, key: key, finishedResult: finishedResult) {
            entries[job.remoteID]?.cleanup = .completed
            await diagnostic?.record(.init(stage: .cleanup, requestID: job.remoteID, status: status, seconds: elapsed(current)))
            entries[job.remoteID]?.result = nil
        } else {
            entries[job.remoteID]?.cleanup = .failed
            await diagnostic?.record(.init(stage: .failure, requestID: job.remoteID, error: .network))
        }
        // The job ended (terminal or cancelled): whether or not fal.ai confirmed the delete, the slot goes back.
        await untrack(job)
    }

    /// `DELETE https://api.fal.ai/v1/models/requests/{id}/payloads` (fal.ai's Platform API): 200 with
    /// `{"cdn_delete_results":[{"link":…,"exception":null}]}` deletes the request's payloads and its output files; each
    /// `exception` is null on success. Only output files go; fal.ai never deletes a request's input files this way (they
    /// expire with the upload's one-hour lifecycle). The key needs `models:requests:write` and `assets:write` (fal.ai's
    /// FULL preset). Returns the confirmed status, or nil after logging why not (the HTTP status, never a URL or key).
    private func deletePayloads(requestID: String, key: String, finishedResult: Bool) async -> Int? {
        guard UUID(uuidString: requestID) != nil else { return nil }
        let url = URL(string: "https://api.fal.ai/v1/models/requests/\(requestID)/payloads")!
        let response: LipsyncHTTPResponse
        // Its own task, as `cancel` does: a cleanup after a cancel runs in the cancelled task, which would refuse the send.
        let http = http, delete = request(url, method: "DELETE", key: key)
        do { response = try await Task { try await http.send(delete, limit: LipsyncLimits.maximumJSONBytes, permit: nil) }.value }
        catch {
            // The error's case only (network, invalidResponse, unsafeURL, responseTooLarge…), never a URL or a key.
            await log("cleanup-unconfirmed reason=\((error as? LipsyncError).map { "\($0)" } ?? "network")")
            return nil
        }
        guard response.status == 200 else {
            if finishedResult, response.status == 401 || response.status == 403 {
                await onCleanupDenial?(VoiceLabFingerprint.bytes(Data(key.utf8)))
            }
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
        return await deletePayloads(requestID: requestID, key: key, finishedResult: true) != nil
    }

    /// Fetches an earlier paid request's result again by its request ID, for free, and downloads its video to `file`. It asks
    /// the request's status first (`GET https://queue.fal.run/{owner}/{app}/requests/{id}/status`): while fal.ai still queues
    /// or runs it, it keeps polling until `deadline` (the job's own, 30 minutes from its submit), then throws `stillRunning`
    /// (checking again later is free). A finished request's result (`GET …/requests/{id}`) is kept for the output's
    /// lifecycle, an hour here. A job fal.ai failed throws `providerFailed`; one it no longer knows answers HTTP 404. The
    /// paid attempt's sidecar keeps only the request ID and the model; the signed result URL is read here and never stored.
    public func refetch(requestID: String, model: LipsyncModel, to file: URL, until deadline: Date,
                        onState: @escaping @Sendable (LipsyncState) async -> Void = { _ in }) async throws {
        guard models.contains(model), UUID(uuidString: requestID) != nil else { throw LipsyncError.invalidInput }
        let key = try await credential()
        func queueURL(_ suffix: String) throws -> URL {
            let url = URL(string: "https://queue.fal.run" + LipsyncURLPolicy.queuePath(model: model, requestID: requestID, suffix: suffix))!
            try LipsyncURLPolicy.queue(url, model: model, requestID: requestID, suffix: suffix)
            return url
        }
        let statusURL = try queueURL("/status"), resultURL = try queueURL("")
        let started = now()
        var failures = 0, finished = false, retryAfter: Double?
        for poll in 0..<LipsyncLimits.maximumPolls {
            try Task.checkCancellation()
            if poll > 0 {
                let seconds = failures == 0 ? (now().timeIntervalSince(started) < 120 ? 5.0 : 15.0) : Self.backoff(failures, retryAfter: retryAfter)
                guard now().addingTimeInterval(seconds) < deadline else { throw LipsyncError.stillRunning }
                try await sleep(.seconds(seconds))
            }
            let response: LipsyncHTTPResponse, body: [String: Any]
            do {
                response = try await http.send(request(statusURL, method: "GET", key: key), limit: LipsyncLimits.maximumJSONBytes, permit: nil)
            } catch let error as LipsyncError where error.isTransient && failures < Self.pollRetries {
                await pollFailed(stage: "status", status: nil, error: error)
                failures += 1
                continue
            } catch {
                await pollFailed(stage: "status", status: nil, error: error)
                throw error
            }
            retryAfter = response.retryAfter
            do { body = try json(response) }
            catch let error as LipsyncError where error.isTransient && failures < Self.pollRetries {
                await pollFailed(stage: "status", status: response.status, error: error)
                failures += 1
                continue
            } catch {
                await pollFailed(stage: "status", status: response.status, error: error)
                throw error
            }
            failures = 0
            if providerError(body) { throw LipsyncError.providerFailure(body["error_type"]) }
            switch body["status"] as? String {
            case "IN_QUEUE": await onState(.queued(position: present(body["queue_position"]) as? Int))
            case "IN_PROGRESS": await onState(.running(progress: nil))
            case "COMPLETED": finished = true
            default: throw LipsyncError.invalidResponse
            }
            if finished { break }
        }
        guard finished else { throw LipsyncError.stillRunning }
        let body: [String: Any]
        var status: Int?
        do {
            let response = try await http.send(request(resultURL, method: "GET", key: key), limit: LipsyncLimits.maximumJSONBytes, permit: nil)
            status = response.status
            body = try json(response)
        } catch {
            await pollFailed(stage: "result", status: status, error: error)
            throw error
        }
        if providerError(body) { throw LipsyncError.providerFailure(body["error_type"]) }
        let output = try resultVideo(body)
        await logger.register(secret: output.absoluteString)
        await onState(.done(output))
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
        guard LipsyncHTTPResponse.isJSON(response.contentType),
              let result = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw LipsyncError.invalidResponse }
        return result
    }
    private func providerError(_ body: [String: Any]) -> Bool {
        ["error", "error_type"].contains { key in body[key].map { !($0 is NSNull) } ?? false }
    }
    /// A JSON value, with an explicit null read as absent.
    private func present(_ value: Any?) -> Any? { value is NSNull ? nil : value }
    /// A finished result's video URL (fal.ai's File: `url`, and the optional `content_type`, `file_name`, `file_size`,
    /// each of which may be null). The download's own Content-Type and `ftyp` checks still apply.
    private func resultVideo(_ result: [String: Any]) throws -> URL {
        guard let video = result["video"] as? [String: Any], let text = video["url"] as? String, let output = URL(string: text)
        else { throw LipsyncError.invalidResponse }
        if let type = present(video["content_type"]) { guard type as? String == "video/mp4" else { throw LipsyncError.invalidResponse } }
        if let bytes = present(video["file_size"]) {
            guard let count = bytes as? Int, (1...LipsyncLimits.maximumVideoBytes).contains(count) else { throw LipsyncError.responseTooLarge }
        }
        try LipsyncURLPolicy.result(output)
        return output
    }
    /// fal.ai failed the job: its sanitized `error_type` is kept for `wait`, and the job is terminal.
    private func providerFailed(_ job: LipsyncJob, _ body: [String: Any]) async throws -> LipsyncState {
        entries[job.remoteID]?.providerFailure = LipsyncError.providerFailure(body["error_type"])
        return try await terminal(job, state: .failed(code: "provider_error", message: "Lip sync failed. Your original media and edits are safe."))
    }
    /// A status or result fetch for `job`, with its HTTP status; a failure is logged with its stage, status and case.
    private func fetchJSON(_ job: LipsyncJob, url: URL, stage: String) async throws -> ([String: Any], Int) {
        var status: Int?
        do {
            let response = try await fetch(job, url: url)
            status = response.status
            entries[job.remoteID]?.retryAfter = response.retryAfter
            return (try json(response), response.status)
        } catch {
            await pollFailed(stage: stage, status: status, error: error)
            throw error
        }
    }
    /// `lipsync provider=fal event=poll-failed stage=status|result status=<n> reason=<case>` (no URLs, bodies or keys).
    private func pollFailed(stage: String, status: Int?, error: any Error) async {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        let reason: String
        switch error as? LipsyncError {
        case .http?: reason = "http"
        case .providerFailed?: reason = "providerFailed"
        case let known?: reason = "\(known)"
        case nil: reason = "network"
        }
        await log("poll-failed stage=\(stage) status=\(status.map(String.init) ?? "unknown") reason=\(reason)")
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
        // The account's one lip-sync slot is taken before anything is uploaded: a slot another run holds refuses here, at
        // once, with nothing sent. `submit` uses it; any failure before that gives it back.
        _ = try await reserveSlot()
        do {
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
        } catch {
            await releaseReservation()
            throw error
        }
    }

    private func upload(_ file: LipsyncUploadFile, key: String, permit: VoiceDispatchPermit) async throws -> LipsyncSignedInput {
        try Task.checkCancellation()
        let initiatedAt = now()
        var stage = LipsyncDiagnosticEvent.Stage.uploadInitiate
        var status: Int?
        do {
            var initiate = request(URL(string: "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")!, method: "POST", key: key)
            initiate.setValue("application/json", forHTTPHeaderField: "Content-Type")
            initiate.setValue("{\"expiration_duration_seconds\":3600}", forHTTPHeaderField: "X-Fal-Object-Lifecycle")
            initiate.httpBody = try JSONSerialization.data(withJSONObject: [
                "file_name": file.contentType == "video/mp4" ? "window.mp4" : "mixed.wav", "content_type": file.contentType
            ])
            let initiation = try await http.send(initiate, limit: LipsyncLimits.maximumJSONBytes, permit: permit)
            status = initiation.status
            let body = try json(initiation)
            guard let target = (body["upload_url"] as? String).flatMap(URL.init(string:)),
                  let result = (body["file_url"] as? String).flatMap(URL.init(string:)) else { throw LipsyncError.invalidResponse }
            let components = try LipsyncURLPolicy.components(target)
            guard let host = components.host, LipsyncURLPolicy.resultHosts.contains(host) || host == "storage.fal.ai" else {
                throw LipsyncError.unsafeURL
            }
            try LipsyncURLPolicy.result(result)
            await logger.register(secret: target.absoluteString)
            await logger.register(secret: result.absoluteString)
            await diagnostic?.record(.init(stage: stage, status: status, seconds: now().timeIntervalSince(initiatedAt)))
            stage = .upload; status = nil
            try Task.checkCancellation()
            var upload = URLRequest(url: target)
            upload.httpMethod = "PUT"; upload.httpBody = file.data
            upload.setValue(file.contentType, forHTTPHeaderField: "Content-Type")
            let response = try await http.send(upload, limit: LipsyncLimits.maximumJSONBytes, permit: permit)
            status = response.status
            guard (200...299).contains(response.status) else { throw LipsyncError.http(response.status) }
            await diagnostic?.record(.init(stage: stage, status: status, seconds: now().timeIntervalSince(initiatedAt), bytes: file.data.count))
            return try LipsyncSignedInput(uploadedURL: result, file: file, expiresAt: initiatedAt.addingTimeInterval(3600))
        } catch let error as LipsyncError {
            await log("upload-failed stage=\(stage.rawValue) status=\(status.map(String.init) ?? "unknown") reason=\(error)")
            await diagnostic?.record(.init(stage: stage, status: status, seconds: now().timeIntervalSince(initiatedAt),
                                           bytes: stage == .upload ? file.data.count : nil, error: error))
            throw error
        }
    }
}
