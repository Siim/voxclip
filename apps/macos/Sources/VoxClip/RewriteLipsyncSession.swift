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
        var phraseIDs: [Int] { windows.flatMap { $0.source.phraseIDs } }
        var price: String { estimate.usd.map(VoiceLabCostPresentation.format) ?? "Price unavailable" }
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
        let run: @MainActor (RenderRequest, LipsyncRenderWindow, String, WholeClipRevoice.Lipsync, @escaping @Sendable (Double?) async -> Void) async throws -> ImportedLipsyncResult
        let changed: @MainActor () async -> Void
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
    @ObservationIgnored var backend: Backend?
    @ObservationIgnored private var pending: [Offer] = []
    @ObservationIgnored private var active: Offer?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var currentRun: Task<ImportedLipsyncResult, any Error>?
    @ObservationIgnored private var turn = UUID()
    @ObservationIgnored private var invalidated: Set<UUID> = []
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var refreshAfterUse = false

    var running: Bool { operation != nil }
    /// Waits for the queued jobs to finish (a whole-clip revoice's lip sync, RewriteWholeClip.swift).
    func waitForRun() async { await operation?.value }
    var enabled: Bool { backend != nil }
    var hasPaidWork: Bool { !applied.isEmpty || running }
    static let firstUse = "fal.ai receives this phrase's video and new audio. VoxClip deletes uploads and results after download where its API allows; inputs expire after one hour. Clicking Lip Sync approves the transfer and charge."

    func previewFailed() { problem = "Couldn't play the lip-synced preview. Your takes and original video are safe." }

    var allDisclosure: String? {
        guard let offer = allOffer else { return nil }
        var lines = ["Uploads \(offer.phraseIDs.count) phrases' prepared video and new audio to fal.ai (sync-3) with your key. Exports say “Lip movement generated with AI.”"]
        if !consentAccepted { lines.append(Self.firstUse) }
        if let warning = capWarning(for: offer) { lines.append(warning) }
        return lines.joined(separator: "\n")
    }

    func refresh() async {
        guard let backend, !usingTakes else { return }
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
            guard revision == turn, offers.values.allSatisfy({ $0.isCurrent() }) else { return }
            self.offers = offers; self.allOffer = all; problem = ""
        } catch {
            guard revision == turn else { return }
            offers = [:]; allOffer = nil
            problem = "Choose a passing take and its video duration to prepare lip sync. Nothing was uploaded."
        }
    }

    func capWarning(for offer: Offer) -> String? {
        guard let cap = monthlyCap, let cost = offer.estimate.usd, cap.spent + cost > cap.limit else { return nil }
        return VoiceLabCostPresentation.capWarning(cap: cap.limit, providerName: "fal.ai")
    }

    /// Queues `offer`; false when it can't start (no key, Use running, a stale or already started offer), so a caller
    /// never reads an earlier attempt's state as this one's.
    @discardableResult func start(_ offer: Offer) -> Bool {
        guard let backend, keyAvailable, !usingTakes, offer.isCurrent(),
              !receipts.contains(where: { $0.id == offer.id }),
              offer.phraseIDs.allSatisfy({ !isRunning($0) && applied[$0] == nil }) else { return false }
        backend.acceptConsent(); consentAccepted = true
        receipts.append(Receipt(id: offer.id, phraseIDs: offer.phraseIDs, estimate: offer.estimate))
        for phrase in offer.phraseIDs { states[phrase] = .running(started: Date(), progress: nil); errors[phrase] = nil }
        pending.append(offer)
        if operation == nil { operation = Task { [weak self] in await self?.drain() } }
        return true
    }

    private func drain() async {
        defer { operation = nil; active = nil; currentRun = nil }
        while !pending.isEmpty, !Task.isCancelled, let backend {
            let offer = pending.removeFirst()
            active = offer
            let started = ContinuousClock.now
            do {
                guard offer.isCurrent() else { throw CancellationError() }
                for window in offer.windows {
                    try Task.checkCancellation()
                    guard offer.isCurrent(), !invalidated.contains(offer.id) else { throw CancellationError() }
                    let run = Task { try await backend.run(offer.request, window, offer.recordID, offer.model) { [weak self] progress in
                        await self?.progress(progress, phrases: window.source.phraseIDs)
                    } }
                    currentRun = run
                    let result = try await withTaskCancellationHandler { try await run.value } onCancel: { run.cancel() }
                    currentRun = nil
                    try Task.checkCancellation()
                    guard !run.isCancelled, offer.isCurrent(), !invalidated.contains(offer.id) else { throw CancellationError() }
                    let duration = started.duration(to: .now).components
                    let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                    for phrase in window.source.phraseIDs {
                        applied[phrase] = Applied(result: result, window: window, dependencies: offer.dependencies)
                        states[phrase] = .done(seconds: seconds, price: result.provenance.estimate.usd.map(VoiceLabCostPresentation.format) ?? offer.price)
                    }
                    if let index = receipts.firstIndex(where: { $0.id == offer.id }) { receipts[index].requestIDs.append(result.provenance.requestID) }
                }
            } catch {
                for phrase in offer.phraseIDs where applied[phrase] == nil {
                    if Task.isCancelled || error is CancellationError { states[phrase] = .cancelled(price: offer.price) }
                    else {
                        let local = error is LipsyncPreparationError || error as? LipsyncError == .missingKey
                        let reason = Self.reason(error)
                        states[phrase] = .failed(reason: reason, price: offer.price, mayBill: !local)
                        errors[phrase] = error
                    }
                }
            }
            await backend.changed()
            active = nil
            invalidated.remove(offer.id)
            await refresh()
        }
    }

    private func progress(_ value: Double?, phrases: [Int]) {
        for phrase in phrases {
            if case .running(let started, _) = states[phrase] { states[phrase] = .running(started: started, progress: value) }
        }
    }

    func isRunning(_ phrase: Int) -> Bool {
        if case .running = states[phrase] { return true }
        return false
    }

    func blocksMutation(_ phrase: Int) -> Bool {
        applied.values.contains { $0.dependencies.contains(phrase) } ||
            (active.map { !invalidated.contains($0.id) && $0.dependencies.contains(phrase) } ?? false) || pending.contains { $0.dependencies.contains(phrase) }
    }

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
        let cancelled = pending.filter { $0.phraseIDs.contains(phrase) }
        pending.removeAll { $0.phraseIDs.contains(phrase) }
        for offer in cancelled {
            for id in offer.phraseIDs { states[id] = .cancelled(price: offer.price) }
        }
    }

    func stop() {
        turn = UUID(); currentRun?.cancel(); operation?.cancel()
        for offer in pending { for id in offer.phraseIDs { states[id] = .cancelled(price: offer.price) } }
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

    static func reason(_ error: any Error) -> String {
        if let local = error as? LipsyncPreparationError, let copy = local.errorDescription { return copy }
        if error as? LipsyncError == .invalidInput { return "This part is outside the lip sync's limits (3 s to 5 min of video). Your original video is unchanged." }
        if error as? LipsyncError == .missingKey { return "Lip sync needs your fal.ai key." }
        if error as? LipsyncError == .submissionUncertain { return "The submission response was lost. Check fal.ai before trying another paid job." }
        if case LipsyncError.http(let status) = error { return "fal.ai returned HTTP \(status)." }
        return "The job could not be completed. Your original video and edits are safe."
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
            cap: { cap }, run: { _, _, _, _, _ in throw CancellationError() }, changed: {})
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
