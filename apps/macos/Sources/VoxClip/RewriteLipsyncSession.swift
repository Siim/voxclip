import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

@MainActor @Observable final class RewriteLipsyncSession {
    struct Offer: Identifiable {
        let id: UUID
        let request: RenderRequest
        let windows: [LipsyncRenderWindow]
        let estimate: CostEstimate
        let recordID: String
        let dependencies: Set<Int>
        let isCurrent: @MainActor () -> Bool
        /// Rewrite's phrases use sync-3; a whole-clip revoice lipsync-2 or the sync-3 upgrade (ADR-R46).
        var model: WholeClipRevoice.Lipsync = .sync3
        /// False for a "Try Again · free": the earlier paid attempt's result is re-imported and nothing new is paid.
        var mayPay = true
        /// The windows (indices into `windows`) the click gets for free, marked by `refresh` (`RewriteLipsyncSession.freeWindows`):
        /// a result this session already got back over the same upload, which the window's imported index answers with
        /// nothing uploaded, or a stop's kept paid result (its phrase's Try Again · free). Their runs never pay, and the
        /// click charges only the other windows.
        var freeWindows: Set<Int> = []
        var phraseIDs: [Int] { windows.flatMap { $0.source.phraseIDs } }
        /// The whole estimate: what fal.ai bills for every window (a stop's line, a cancelled job).
        var price: String { estimate.usd.map(VoiceLabCostPresentation.format) ?? "Price unavailable" }
        /// Every window is free: the click buys nothing.
        var free: Bool { !windows.isEmpty && windows.indices.allSatisfy(freeWindows.contains) }
        /// What the click charges: the estimate less the free windows' share (each window is priced by its upload seconds,
        /// as the offers are made), zero when every window is free.
        var chargeUSD: Decimal? {
            guard !freeWindows.isEmpty else { return estimate.usd }
            if free { return 0 }
            guard let usd = estimate.usd else { return nil }
            let rate = request.timeline.sampleRate
            let seconds = windows.map { $0.uploadSeconds(sampleRate: rate) }
            let total = seconds.reduce(0, +)
            guard total > 0 else { return usd }
            let paid = seconds.indices.filter { !freeWindows.contains($0) }.reduce(0.0) { $0 + seconds[$1] }
            return usd * Decimal(paid / total)
        }
        /// The button's price: "free" when nothing new is bought, else what the click charges.
        var charge: String {
            if free { return "free" }
            return chargeUSD.map(VoiceLabCostPresentation.format) ?? "Price unavailable"
        }
    }
    /// A paid result this session got back, with what its upload was made from. An offer over the same window, model and
    /// upload (`LipsyncWindowPreparation.uploadRequest`) prepares the same inputs, which the window's imported index answers
    /// with that result: it stays reusable through Undo, Keep Original Video, a set-aside and a discarded result.
    private struct Reusable {
        let window: LipsyncRenderWindow
        let model: WholeClipRevoice.Lipsync
        let upload: RenderRequest
    }
    enum State: Equatable {
        case running(started: Date, progress: Double?)
        case done(seconds: Double, price: String)
        case failed(reason: String, price: String, mayBill: Bool)
        case cancelled(price: String)
    }
    struct Applied {
        let result: ImportedLipsyncResult
        let window: LipsyncRenderWindow
        let dependencies: Set<Int>
        /// How long its run took, for the done row.
        var seconds: Double = 0
    }
    /// A result that came back paid after its offer stopped being current, after a cancel, or after Rewrite stopped: it is
    /// kept (the window's imported index), never dropped as a cancel, and Try Again puts it in for free.
    struct SetAside: Error, Sendable { let cancelled: Bool }
    /// What a stopped row offers, in order (design.md, Takes: lip sync). Each one can succeed: a free retry only while the
    /// earlier paid job can still be had, a priced one with its price, and Keep Original Video.
    enum FailedAction: Equatable {
        /// Try Again: free when it re-imports the kept or still-fetchable paid result, else priced.
        case tryAgain(free: Bool)
        /// The kept result failed a check that would fail again, or fal.ai declined the media: a new paid job.
        case lipSyncAgain
        /// fal.ai is still finishing the earlier job: checking it again is free.
        case checkAgain
        /// The submit's answer was lost: only the user, after checking fal.ai, starts another paid job (it may charge twice).
        case checkedFal
        /// The key was refused (HTTP 401 or 403): Settings → Voice Lab.
        case settings
        case keepOriginal
    }
    struct Receipt {
        let id: UUID
        let phraseIDs: [Int]
        let estimate: CostEstimate
        var requestIDs: [String] = []
    }
    struct Backend {
        let offers: @MainActor () async throws -> ([Int: Offer], Offer?)
        let hasKey: @MainActor () async -> Bool
        let hasConsent: @MainActor () -> Bool
        let acceptConsent: @MainActor () -> Void
        let cap: @MainActor () async throws -> VoiceLabMonthlyCap?
        /// The window's lip sync: the request, window, consent record, model, whether it may pay (false for a free Try
        /// Again) and its progress.
        let run: @MainActor (RenderRequest, LipsyncRenderWindow, String, WholeClipRevoice.Lipsync, Bool, @escaping @Sendable (Double?) async -> Void) async throws -> ImportedLipsyncResult
        let changed: @MainActor () async -> Void
        /// One log line (an offer failure's kind, a result set aside): the app's log.
        var report: @MainActor (String) -> Void = { _ in }
    }

    private(set) var offers: [Int: Offer] = [:]
    private(set) var allOffer: Offer?
    private(set) var states: [Int: State] = [:]
    private(set) var applied: [Int: Applied] = [:]
    private(set) var receipts: [Receipt] = []
    private(set) var refreshing = false
    private(set) var keyAvailable = false
    private(set) var consentAccepted = false
    private(set) var monthlyCap: VoiceLabMonthlyCap?
    private(set) var problem = ""
    private(set) var usingTakes = false
    /// The error behind each phrase's `.failed` state, for the whole clip's stop and its log line (its real case).
    @ObservationIgnored private(set) var errors: [Int: any Error] = [:]
    /// Phrases whose last paid attempt failed with its result kept: their Try Again re-imports it for free.
    private(set) var freeRetries: Set<Int> = []
    /// Phrases whose kept paid result failed one of the import's checks in this run: the same file would fail it again, so
    /// their row offers Keep Original Video and a priced Lip Sync Again, never a free Try Again (a restart with a fixed
    /// build re-imports it for free before paying).
    private(set) var repeatingChecks: Set<Int> = []
    /// The last offers refresh failed for a reason other than a change in the takes: the row offers Prepare Lip Sync Again.
    private(set) var offersFailed = false
    @ObservationIgnored var backend: Backend?
    @ObservationIgnored var automaticallyRefreshOffers = true
    @ObservationIgnored private var pending: [Offer] = []
    @ObservationIgnored private var active: Offer?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var currentRun: Task<ImportedLipsyncResult, any Error>?
    @ObservationIgnored private var turn = UUID()
    @ObservationIgnored private var invalidated: Set<UUID> = []
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var refreshAfterUse = false
    /// The paid results this session got back (`Reusable`), newest last.
    @ObservationIgnored private var reusable: [Reusable] = []

    var running: Bool { operation != nil }
    /// Waits for the queued jobs to finish (a whole-clip revoice's lip sync, RewriteWholeClip.swift).
    func waitForRun() async { await operation?.value }
    var enabled: Bool { backend != nil }
    var hasPaidWork: Bool { !applied.isEmpty || running }
    static let firstUse = "fal.ai receives this phrase's video and new audio. VoxClip asks fal.ai to delete the result after download, which your key's permissions must allow; uploads and results expire after one hour. Clicking Lip Sync approves the transfer and charge."

    /// The failed row's line (design.md, Takes: lip sync): what happened, then what fal.ai charged and whether Try Again is free.
    static func failureLine(phrase: Int, reason: String, price: String, mayBill: Bool, free: Bool, unconfirmed: Bool = false,
                            setAside: Bool = false) -> String {
        if setAside { return "Phrase \(phrase + 1): \(reason) fal.ai charged for the job (estimated cost: \(price))." }
        let lead = "Couldn't lip sync phrase \(phrase + 1): \(reason)"
        if unconfirmed { return lead }
        guard mayBill else { return lead + " No new lip-sync charge." }
        return lead + " fal.ai accepted the job (estimated cost: \(price))." + (free ? " Try Again checks the same job for free." : "")
    }

    /// The phrase's failed line from its state, or nil when it hasn't failed.
    func failureLine(_ phrase: Int) -> String? {
        guard case .failed(let reason, let price, let mayBill) = states[phrase] else { return nil }
        return Self.failureLine(phrase: phrase, reason: reason, price: price, mayBill: mayBill, free: freeRetries.contains(phrase),
                                unconfirmed: submissionUnconfirmed(phrase),
                                setAside: (errors[phrase] as? LipsyncAttemptFailure)?.error is SetAside)
    }

    /// The failed row's actions, in order. Every stop has one that can succeed.
    func failedActions(_ phrase: Int) -> [FailedAction] {
        guard case .failed = states[phrase] else { return [] }
        if submissionUnconfirmed(phrase) { return [.checkedFal, .keepOriginal] }
        let error = errors[phrase].map(Self.cause)
        if error as? LipsyncError == .stillRunning { return [.checkAgain, .keepOriginal] }
        if freeRetries.contains(phrase) { return [.tryAgain(free: true), .keepOriginal] }
        if repeatingChecks.contains(phrase) { return [.keepOriginal, .lipSyncAgain] }
        if let unsent = errors[phrase] as? LipsyncNotSubmitted, unsent.queueRefused, case LipsyncError.http(let status) = unsent.error {
            switch status {
            case 401, 403: return [.settings, .tryAgain(free: false)]
            case 422: return [.keepOriginal, .lipSyncAgain]
            default: break
            }
        }
        // A stop on this Mac that the same inputs meet again (no clear face, a source that can't be prepared, a part outside
        // the limits) has no Try Again: only the user's change of take or wording can pass it. A missing key passes once it
        // is added; an unwritable file once the disk has room.
        if let error, Self.isLocal(error) {
            switch error as? LipsyncError {
            case .missingKey: return [.settings, .tryAgain(free: false)]
            case .unsafeFile: break
            default: return [.keepOriginal]
            }
        }
        return [.tryAgain(free: false), .keepOriginal]
    }

    /// What actually failed behind a lip sync's wrappers.
    static func cause(_ error: any Error) -> any Error {
        if let failure = error as? LipsyncAttemptFailure { return cause(failure.error) }
        if let unsent = error as? LipsyncNotSubmitted { return cause(unsent.error) }
        return error
    }

    func previewFailed() { problem = "Couldn't play the lip-synced preview. Your takes and original video are safe." }

    var allDisclosure: String? {
        guard let offer = allOffer else { return nil }
        if offer.free { return Self.freeLine(phrases: offer.phraseIDs.count) }
        let sent = offer.windows.indices.filter { !offer.freeWindows.contains($0) }.reduce(0) { $0 + offer.windows[$1].source.phraseIDs.count }
        var lines = ["Uploads \(sent) phrases' prepared video and new audio to fal.ai (sync-3) with your key. Exports say “Lip movement generated with AI.”"]
        let back = offer.phraseIDs.count - sent
        if back > 0 { lines.append((back == 1 ? "One phrase gets" : "\(back) phrases get") + " its paid lip sync back, for free.") }
        if !consentAccepted { lines.append(Self.firstUse) }
        if let warning = capWarning(for: offer) { lines.append(warning) }
        return lines.joined(separator: "\n")
    }

    /// An offer whose every window is free: what its click does.
    static func freeLine(phrases: Int) -> String {
        "Gets back the lip sync already paid for \(phrases == 1 ? "this phrase's" : "these phrases'") takes. Nothing new is uploaded or charged."
    }

    /// The windows of `offer` (indices) whose paid result this session already got over the same window, model and upload:
    /// the window's imported index answers them, for free.
    func reusedWindows(_ offer: Offer) -> Set<Int> {
        guard !reusable.isEmpty else { return [] }
        let upload = LipsyncWindowPreparation.uploadRequest(offer.request)
        return Set(offer.windows.indices.filter { index in
            reusable.contains { $0.window == offer.windows[index] && $0.model == offer.model && $0.upload == upload }
        })
    }

    /// The windows of `offer` its click gets for free: the reused ones, and those with a phrase whose stop kept its paid
    /// result (Try Again · free).
    func freeWindows(_ offer: Offer) -> Set<Int> {
        reusedWindows(offer).union(offer.windows.indices.filter { offer.windows[$0].source.phraseIDs.contains(where: freeRetries.contains) })
    }

    private func marked(_ offer: Offer) -> Offer {
        var offer = offer
        offer.freeWindows = freeWindows(offer)
        return offer
    }

    /// The offers on screen priced again after a stop's free retry changed (Keep Original Video).
    private func remark() {
        offers = offers.mapValues { marked($0) }; allOffer = allOffer.map { marked($0) }
    }

    /// A paid result came back for `window` of `offer`: the same inputs get it again for free.
    private func remember(_ window: LipsyncRenderWindow, of offer: Offer) {
        let upload = LipsyncWindowPreparation.uploadRequest(offer.request)
        reusable.removeAll { $0.window == window && $0.model == offer.model && $0.upload == upload }
        reusable.append(Reusable(window: window, model: offer.model, upload: upload))
    }

    /// The result `window` was reused for is gone from this Mac (its file was removed or changed): the next offer is priced.
    private func forget(_ window: LipsyncRenderWindow, of offer: Offer) {
        let upload = LipsyncWindowPreparation.uploadRequest(offer.request)
        reusable.removeAll { $0.window == window && $0.model == offer.model && $0.upload == upload }
    }

    func refresh() async {
        guard automaticallyRefreshOffers, let backend, !usingTakes else { return }
        guard !refreshing else { refreshAgain = true; return }
        let revision = turn
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain { refreshAgain = false; Task { await self.refresh() } }
        }
        keyAvailable = await backend.hasKey()
        consentAccepted = backend.hasConsent()
        do {
            monthlyCap = try await backend.cap()
            // Use started while the key and cap were read: offers would publish and prepare beside it. They are made
            // after Use if it fails.
            guard !usingTakes else { refreshAfterUse = true; return }
            let (offers, all) = try await backend.offers()
            guard revision == turn else { return }
            // Offers made over takes that changed meanwhile are never shown: the refresh after that change makes fresh ones.
            guard offers.values.allSatisfy({ $0.isCurrent() }) else { self.offers = [:]; allOffer = nil; return }
            // Windows this session already got a paid result for are priced "free": the run puts that result back.
            self.offers = offers.mapValues { marked($0) }
            self.allOffer = all.flatMap { $0.phraseIDs.contains(where: submissionUnconfirmed) ? nil : marked($0) }
            problem = ""; offersFailed = false
        } catch ClipTakePlan.Failure.stale, ClipTakePlan.Failure.lipsyncBusy {
            // The takes changed while the offers were made (a reworded phrase is priced, a take is made): they end
            // quietly, and the refresh after that change makes fresh ones.
            guard revision == turn else { return }
            offers = [:]; allOffer = nil
        } catch {
            guard revision == turn else { return }
            // What actually failed (the matched render, the consent record, the price catalog, the spend check), logged
            // with its kind, and Prepare Lip Sync Again on the row.
            offers = [:]; allOffer = nil
            problem = ClipTakePlan.copy(error); offersFailed = true
            backend.report("lipsync offers failure " + RewriteSession.failureKind(error))
        }
    }

    /// The offers changed under the plan (an autosave, a take or its duration): an offer on screen is stale.
    var hasStaleOffer: Bool { offers.values.contains { !$0.isCurrent() } || allOffer.map { !$0.isCurrent() } == true }

    func requireKey() async throws {
        guard let backend else { throw ClipTakePlan.Failure.noLipsyncOffer }
        let available = await backend.hasKey()
        try Task.checkCancellation()
        keyAvailable = available
        guard available else { throw LipsyncError.missingKey }
    }

    func capWarning(for offer: Offer) -> String? {
        guard let cap = monthlyCap, let cost = offer.chargeUSD, cost > 0, cap.spent + cost > cap.limit else { return nil }
        return VoiceLabCostPresentation.capWarning(cap: cap.limit, providerName: "fal.ai")
    }

    /// Queues `offer`; false when it can't start (no key, Use running, a stale or already started offer), so a caller
    /// never reads an earlier attempt's state as this one's.
    @discardableResult func start(_ offer: Offer) -> Bool {
        do { try startChecked(offer); return true } catch { return false }
    }

    /// A row's or Lip Sync All's button: starts `offer`, or says on the row why it can't and makes fresh offers.
    func press(_ offer: Offer) {
        do { try startChecked(offer) }
        catch {
            problem = Self.refusal(error)
            Task { await refresh() }
        }
    }

    /// The user checked fal.ai's request history after a lost submit answer and asks for another paid job, which may be
    /// charged twice. Only the row's own button calls this; automatic runs never do.
    func startAfterCheckingFal(_ offer: Offer) throws {
        let cleared = offer.phraseIDs.filter(submissionUnconfirmed)
        for phrase in cleared { errors[phrase] = nil }
        do { try startChecked(offer) }
        catch {
            for phrase in cleared { errors[phrase] = LipsyncError.submissionUncertain }
            throw error
        }
    }

    /// The row's I Checked fal.ai button: `startAfterCheckingFal`, or why it can't start, on the row.
    func pressAfterCheckingFal(_ offer: Offer) {
        do { try startAfterCheckingFal(offer) }
        catch {
            problem = Self.refusal(error)
            Task { await refresh() }
        }
    }

    /// Keep Original Video: the stop is dismissed and the phrase keeps its own video (nothing kept is deleted).
    func keepOriginal(_ phrase: Int) {
        guard case .failed = states[phrase] else { return }
        states.removeValue(forKey: phrase); errors[phrase] = nil
        freeRetries.remove(phrase); repeatingChecks.remove(phrase)
        remark()
    }

    /// Puts back lip syncs applied earlier (a whole clip's `Applied` entries), when nothing runs, none of their phrases is
    /// applied or running, and each entry's window and dependencies are those of `offer` (the current offer over the same
    /// phrases, else Lip Sync All's), which is still current. False changes nothing.
    @discardableResult func restore(_ entries: [Int: Applied], matching offer: Offer? = nil) -> Bool {
        guard !entries.isEmpty, operation == nil, pending.isEmpty, active == nil, !usingTakes,
              !entries.keys.contains(where: { applied[$0] != nil || isRunning($0) }),
              let reference = offer ?? allOffer, reference.isCurrent(), Set(reference.phraseIDs) == Set(entries.keys),
              entries.values.allSatisfy({ reference.windows.contains($0.window) && $0.dependencies == reference.dependencies })
        else { return false }
        for (phrase, entry) in entries {
            applied[phrase] = entry
            states[phrase] = .done(seconds: entry.seconds, price: entry.result.provenance.estimate.usd.map(VoiceLabCostPresentation.format) ?? reference.price)
            errors[phrase] = nil; freeRetries.remove(phrase); repeatingChecks.remove(phrase)
        }
        return true
    }

    func startChecked(_ offer: Offer) throws {
        try Task.checkCancellation()
        guard offer.isCurrent() else { throw ClipTakePlan.Failure.stale }
        guard let backend, !offer.phraseIDs.isEmpty else { throw ClipTakePlan.Failure.noLipsyncOffer }
        guard keyAvailable else { throw LipsyncError.missingKey }
        guard !offer.phraseIDs.contains(where: submissionUnconfirmed) else { throw LipsyncError.submissionUncertain }
        guard !usingTakes, !offer.phraseIDs.contains(where: isRunning) else { throw ClipTakePlan.Failure.lipsyncBusy }
        guard !receipts.contains(where: { $0.id == offer.id }), offer.phraseIDs.allSatisfy({ applied[$0] == nil }) else {
            throw ClipTakePlan.Failure.lipsyncAlreadyStarted
        }
        // The button said which windows are free: one it counted on that no longer is makes fresh offers first.
        guard offer.freeWindows.isSubset(of: freeWindows(offer)) else { throw ClipTakePlan.Failure.stale }
        var offer = offer
        // A free Try Again re-imports the paid attempt's kept result and never pays (design.md, Stopped); so does a window
        // this session already got back paid. Each window's run decides its own (`drain`): Lip Sync All pays for the rest.
        offer.mayPay = offer.mayPay && !offer.free
        backend.acceptConsent(); consentAccepted = true
        receipts.append(Receipt(id: offer.id, phraseIDs: offer.phraseIDs, estimate: offer.estimate))
        problem = ""
        for phrase in offer.phraseIDs { states[phrase] = .running(started: Date(), progress: nil); errors[phrase] = nil }
        pending.append(offer)
        if operation == nil { operation = Task { [weak self] in await self?.drain() } }
    }

    /// Ends an offer's remaining windows after one stopped: they never ran.
    private struct Stopped: Error {}

    private func drain() async {
        defer { operation = nil; active = nil; currentRun = nil }
        while !pending.isEmpty, !Task.isCancelled, let backend {
            let offer = pending.removeFirst()
            active = offer
            let started = ContinuousClock.now
            var ran: Set<Int> = []
            do {
                for (index, window) in offer.windows.enumerated() {
                    try Task.checkCancellation()
                    guard offer.isCurrent(), !invalidated.contains(offer.id) else { throw CancellationError() }
                    let phrases = window.source.phraseIDs
                    ran.formUnion(phrases)
                    // A free window never pays: a stop's free Try Again re-imports its kept paid result, and a reused one puts
                    // back the result this session already got for the same upload.
                    let retried = phrases.contains(where: freeRetries.contains)
                    let reused = offer.freeWindows.contains(index) && !retried
                    let mayPay = offer.mayPay && !retried && !reused
                    let run = Task { try await backend.run(offer.request, window, offer.recordID, offer.model, mayPay) { [weak self] progress in
                        await self?.progress(progress, phrases: phrases)
                    } }
                    currentRun = run
                    let result: ImportedLipsyncResult
                    do { result = try await withTaskCancellationHandler { try await run.value } onCancel: { run.cancel() } }
                    catch {
                        currentRun = nil
                        if reused, error is LipsyncRecoveryFailed { forget(window, of: offer) }
                        // Only this window's phrases ran: the failure, its charge and its free retry are theirs alone.
                        fail(phrases, offer: offer, mayPay: mayPay, reused: reused, error: error)
                        throw Stopped()
                    }
                    currentRun = nil
                    remember(window, of: offer)
                    if let receipt = receipts.firstIndex(where: { $0.id == offer.id }) { receipts[receipt].requestIDs.append(result.provenance.requestID) }
                    // A result that came back was paid for: it goes in, or it is kept for a free Try Again. Never a cancel.
                    guard !run.isCancelled, !Task.isCancelled, offer.isCurrent(), !invalidated.contains(offer.id) else {
                        setAside(result, phrases: phrases, offer: offer, cancelled: run.isCancelled || Task.isCancelled)
                        throw Stopped()
                    }
                    let duration = started.duration(to: .now).components
                    let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                    for phrase in phrases {
                        freeRetries.remove(phrase); repeatingChecks.remove(phrase)
                        applied[phrase] = Applied(result: result, window: window, dependencies: offer.dependencies, seconds: seconds)
                        states[phrase] = .done(seconds: seconds, price: result.provenance.estimate.usd.map(VoiceLabCostPresentation.format) ?? offer.price)
                    }
                }
            } catch {
                // Phrases of windows that never ran were never sent: they go back to their offers, with no charge.
                for phrase in offer.phraseIDs where !ran.contains(phrase) && applied[phrase] == nil {
                    states.removeValue(forKey: phrase); errors[phrase] = nil
                }
            }
            await backend.changed()
            active = nil
            invalidated.remove(offer.id)
            await refresh()
        }
    }

    /// A window's run failed: its phrases' stop, what fal.ai may have charged and whether Try Again is free. `mayPay` is
    /// the window's own (false for a free Try Again or a reused window); `reused` when it was to put an earlier result back.
    private func fail(_ phrases: [Int], offer: Offer, mayPay: Bool, reused: Bool, error: any Error) {
        let failure = error as? LipsyncAttemptFailure
        for phrase in phrases where applied[phrase] == nil {
            // A job fal.ai accepted is never shown as a plain cancel, even when Rewrite stopped: it may have billed.
            if failure == nil, (Task.isCancelled || error is CancellationError) && error as? LipsyncError != .submissionUncertain {
                // A cancelled reuse sent nothing: the phrase goes back to its free offer.
                if reused { states.removeValue(forKey: phrase); errors[phrase] = nil }
                else { states[phrase] = .cancelled(price: offer.price) }
                continue
            }
            if let failure, failure.freeRetry, failure.error is CancellationError {
                // The cancel or stop landed after fal.ai finished the job: billed, its result waits at fal.ai and its record
                // is on disk, so Try Again fetches it for free. Never "fal.ai may still charge" with a priced Try Again.
                let aside = SetAside(cancelled: true)
                states[phrase] = .failed(reason: Self.reason(aside), price: VoiceLabCostPresentation.format(failure.attempt.estimate.usd ?? 0),
                                         mayBill: mayPay)
                freeRetries.insert(phrase); repeatingChecks.remove(phrase)
                errors[phrase] = LipsyncAttemptFailure(error: aside, attempt: failure.attempt, freeRetry: true)
                continue
            }
            // A failed free Try Again charged nothing new; its earlier attempt's charge was already shown.
            // fal.ai can have charged only for a job it was sent: not before the submit, nor for a free Try Again.
            let reason = reused && error is LipsyncRecoveryFailed ? Self.reuseGone : Self.reason(error)
            states[phrase] = .failed(reason: reason, price: failure.map { VoiceLabCostPresentation.format($0.attempt.estimate.usd ?? 0) } ?? offer.price,
                                     mayBill: mayPay && (failure != nil || error as? LipsyncError == .submissionUncertain))
            // A kept result that failed a check fails it again in this run: no free Try Again for it.
            let check = failure?.error is LipsyncResultCheck
            let free = (failure?.freeRetry == true && !check) || (error as? LipsyncRecoveryFailed)?.settled == false
                || error as? LipsyncError == .stillRunning
            if free { freeRetries.insert(phrase) } else { freeRetries.remove(phrase) }
            if check { repeatingChecks.insert(phrase) } else { repeatingChecks.remove(phrase) }
            errors[phrase] = error
        }
    }

    /// A paid result came back after its offer stopped being current, after a cancel, or after Rewrite stopped. It is in the
    /// window's imported index already, so Try Again over the same inputs puts it in for free; the row says it was charged.
    /// A result the user discarded (Discard Lip Sync) goes back to the offers, still findable by the same inputs.
    private func setAside(_ result: ImportedLipsyncResult, phrases: [Int], offer: Offer, cancelled: Bool) {
        let discarded = invalidated.contains(offer.id)
        backend?.report("lipsync result set-aside reason=\(discarded ? "discarded" : cancelled ? "cancelled" : "stale")")
        if discarded {
            for phrase in phrases { states.removeValue(forKey: phrase); errors[phrase] = nil; freeRetries.remove(phrase) }
            return
        }
        let attempt = LipsyncAttempt(imported: result)
        let price = result.provenance.estimate.usd.map(VoiceLabCostPresentation.format) ?? offer.price
        let reason = SetAside(cancelled: cancelled)
        for phrase in phrases {
            states[phrase] = .failed(reason: Self.reason(reason), price: price, mayBill: true)
            freeRetries.insert(phrase); repeatingChecks.remove(phrase)
            errors[phrase] = LipsyncAttemptFailure(error: reason, attempt: attempt, freeRetry: true)
        }
    }

    private func progress(_ value: Double?, phrases: [Int]) {
        for phrase in phrases {
            if case .running(let started, _) = states[phrase] { states[phrase] = .running(started: started, progress: value) }
        }
    }

    func submissionUnconfirmed(_ phrase: Int) -> Bool { errors[phrase] as? LipsyncError == .submissionUncertain }

    func isRunning(_ phrase: Int) -> Bool {
        if case .running = states[phrase] { return true }
        return false
    }

    func blocksMutation(_ phrase: Int) -> Bool {
        applied.values.contains { $0.dependencies.contains(phrase) } ||
            (active.map { !invalidated.contains($0.id) && $0.dependencies.contains(phrase) } ?? false) || pending.contains { $0.dependencies.contains(phrase) }
    }

    /// Undo: the phrase keeps its own video. The paid result stays in the window's imported index and in `reusable`, so the
    /// next Lip Sync over the same takes reads "free" and puts it back; a fresh render needs a change of take or wording.
    func undo(_ phrase: Int) {
        guard let result = applied[phrase] else { return }
        let affected = applied.filter { $0.value.result.asset.id == result.result.asset.id }.map(\.key)
        for id in affected { applied.removeValue(forKey: id); states.removeValue(forKey: id) }
    }

    func invalidate(_ phrase: Int) {
        let affected = applied.filter { $0.value.dependencies.contains(phrase) }.map(\.key)
        for id in affected { applied.removeValue(forKey: id); states.removeValue(forKey: id) }
        if let active, active.dependencies.contains(phrase) { invalidated.insert(active.id); currentRun?.cancel() }
        let cancelled = pending.filter { $0.dependencies.contains(phrase) }
        pending.removeAll { $0.dependencies.contains(phrase) }
        for id in cancelled.flatMap(\.phraseIDs) { states.removeValue(forKey: id) }
        offers = [:]; allOffer = nil; turn = UUID()
    }

    func cancel(_ phrase: Int) {
        if active?.phraseIDs.contains(phrase) == true { currentRun?.cancel() }
        // A queued offer never ran: its phrases go back to their offers, with nothing charged.
        let cancelled = pending.filter { $0.phraseIDs.contains(phrase) }
        pending.removeAll { $0.phraseIDs.contains(phrase) }
        for id in cancelled.flatMap(\.phraseIDs) { states.removeValue(forKey: id) }
    }

    func stop() {
        turn = UUID(); currentRun?.cancel(); operation?.cancel()
        for id in pending.flatMap(\.phraseIDs) { states.removeValue(forKey: id) }
        pending = []; offers = [:]; allOffer = nil
    }

    func waitForUseTakes() async throws {
        usingTakes = true
        await operation?.value
        try Task.checkCancellation()
    }

    func finishUseTakes() {
        usingTakes = false
        if refreshAfterUse { refreshAfterUse = false; Task { await refresh() } }
    }

    /// Failed on this Mac before anything reached fal.ai, and would fail the same way again: the window can't be prepared,
    /// is outside the lip sync's limits, a local file is unsafe, or the key is missing.
    static func isLocal(_ error: any Error) -> Bool {
        if error is LipsyncPreparationError { return true }
        guard let local = error as? LipsyncError else { return false }
        return [.missingKey, .invalidInput, .unsafeFile].contains(local)
    }

    /// Why a button didn't start: the plan's own copy, else the lip sync's.
    static func refusal(_ error: any Error) -> String {
        error is ClipTakePlan.Failure || error is CancellationError ? ClipTakePlan.copy(error) : reason(error)
    }

    /// A reused window whose earlier result is no longer on this Mac (its file was removed or changed).
    static let reuseGone = "The lip sync fal.ai made earlier for these takes is no longer on this Mac."

    static func reason(_ error: any Error) -> String {
        if let failure = error as? LipsyncAttemptFailure { return reason(failure.error) }
        if let aside = error as? SetAside {
            return aside.cancelled ? "Lip sync finished before the cancel reached fal.ai. It's kept: Try Again puts it in for free."
                : "Lip sync finished after the takes changed. It's kept: Try Again puts it in for free."
        }
        if let unsent = error as? LipsyncNotSubmitted {
            if unsent.queueRefused, case LipsyncError.http(let status) = unsent.error, let declined = declined(status) {
                return "The lip-sync request was declined. " + declined
            }
            return (unsent.queueRefused ? "The lip-sync request was declined. " : "Stopped before submitting a lip-sync job. ") + reason(unsent.error)
        }
        if let check = error as? LipsyncResultCheck { return check.copy }
        if let failed = error as? LipsyncRecoveryFailed {
            if case LipsyncError.providerFailed(let type) = failed.error { return "fal.ai failed the earlier lip-sync job (\(type)). Nothing new was paid." }
            if !failed.settled { return "VoxClip couldn't reach fal.ai's earlier result just now. Nothing new was paid; Try Again checks it again for free." }
            return "VoxClip couldn't get fal.ai's earlier result back (fal.ai keeps it for an hour). Nothing new was paid."
        }
        if let local = error as? LipsyncPreparationError, let copy = local.errorDescription { return copy }
        if case LipsyncError.providerFailed(let type) = error { return "fal.ai failed the lip-sync job (\(type)) and may still charge for it." }
        if error as? LipsyncError == .stillRunning { return "fal.ai is still finishing the earlier lip sync of this part. Nothing new was paid; checking again is free." }
        if error as? LipsyncError == .busy { return "Another lip sync is still running on fal.ai. Nothing was uploaded or charged; try again when it finishes." }
        if error as? LipsyncError == .unsafeFile { return "VoxClip couldn't write the lip-sync files on this Mac (is the disk full?). Your original video is unchanged." }
        if error as? LipsyncError == .invalidInput { return "This part is outside the lip sync's limits (3 s to 5 min of video). Your original video is unchanged." }
        if error as? LipsyncError == .missingKey { return "Lip sync needs your fal.ai key." }
        if error as? LipsyncError == .invalidResponse { return "VoxClip couldn't read the response from fal.ai." }
        if error as? LipsyncError == .invalidMedia { return "The media didn't pass the lip-sync file checks." }
        if error as? LipsyncError == .submissionUncertain { return "VoxClip couldn't confirm whether fal.ai accepted the job or charged for it. Check the request history in your fal.ai account before starting another paid job." }
        if case LipsyncError.http(let status) = error { return "fal.ai returned HTTP \(status)." }
        return "The job could not be completed. Your original video and edits are safe."
    }

    /// fal.ai's refusal of the submit, by status: a key to check, credit to add, or media it can't use.
    private static func declined(_ status: Int) -> String? {
        switch status {
        case 401: "fal.ai didn't accept your key (HTTP 401). Check it in Settings → Voice Lab."
        case 403: "Your fal.ai key isn't allowed to run this lip sync (HTTP 403). Check it in Settings → Voice Lab."
        case 402: "Your fal.ai account needs credit (HTTP 402). Add credit at fal.ai, then try again."
        case 422: "fal.ai couldn't use this part's video and audio (HTTP 422)."
        default: nil
        }
    }

    #if DEBUG
    func showFixture(_ state: String, project: Project, phrases: [ClipTakePlan.Phrase]) throws {
        let plan = try VoiceLabOutputPlanner.build(project, scope: .full)
        let request = RenderRequest(sourceURL: URL(fileURLWithPath: "/synthetic/lipsync.mp4"),
            plan: EditPlan(sampleRate: plan.sampleRate, totalSamples: plan.totalSourceSamples,
                kept: [MediaInterval(startSample: 0, endSample: plan.totalSourceSamples)]),
            output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        let windows = try phrases.map { phrase in
            try LipsyncWindow.make(seamIn: phrase.window.startSample, seamOut: phrase.window.endSample,
                totalSamples: plan.totalSourceSamples, sampleRate: Int(plan.sampleRate), phraseID: phrase.id)
        }
        func offer(_ windows: [LipsyncRenderWindow]) -> Offer {
            let seconds = windows.reduce(0) { $0 + $1.seconds(sampleRate: plan.sampleRate) }
            let estimate = CostEstimate(provider: "fal", operation: "lipsync", units: seconds, unit: "second",
                usd: Decimal(seconds) * 8 / 60, basis: "offline fixture")
            return Offer(id: UUID(), request: request, windows: windows, estimate: estimate,
                recordID: "fixture", dependencies: Set(windows.flatMap { $0.source.phraseIDs }), isCurrent: { true })
        }
        let individual = try Dictionary(uniqueKeysWithValues: windows.map { window in
            (window.phraseIDs[0], offer(try LipsyncRenderWindow.jobs(windows: [window], plan: plan)))
        })
        let all = ["lipsync-running", "lipsync-done", "lipsync-waiting"].contains(state) ? nil : offer(try LipsyncRenderWindow.jobs(windows: windows, plan: plan))
        offers = individual; allOffer = all
        keyAvailable = state != "lipsync-missing-key"
        consentAccepted = state != "lipsync-first-use"
        monthlyCap = state == "lipsync-first-use" ? VoiceLabMonthlyCap(limit: Decimal(string: "0.1")!, spent: 0) : nil
        let key = keyAvailable, consent = consentAccepted, cap = monthlyCap
        backend = .init(offers: { (individual, all) }, hasKey: { key }, hasConsent: { consent }, acceptConsent: {},
            cap: { cap }, run: { _, _, _, _, _, _ in throw CancellationError() }, changed: {})
        usingTakes = state == "lipsync-waiting"
        for phrase in phrases {
            let price = individual[phrase.id]?.price ?? "$0.40"
            switch state {
            case "lipsync-running", "lipsync-waiting": states[phrase.id] = .running(started: Date().addingTimeInterval(-12), progress: 0.4)
            case "lipsync-done": states[phrase.id] = .done(seconds: 34, price: price)
            case "lipsync-failed": states[phrase.id] = .failed(reason: "fal.ai returned HTTP 503.", price: price, mayBill: true)
            case "lipsync-cancelled": states[phrase.id] = .cancelled(price: price)
            default: break
            }
        }
    }
    #endif
}
