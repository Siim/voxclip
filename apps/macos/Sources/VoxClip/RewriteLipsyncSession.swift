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
        let run: @MainActor (RenderRequest, LipsyncRenderWindow, String, @escaping @Sendable (Double?) async -> Void) async throws -> ImportedLipsyncResult
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
    @ObservationIgnored var backend: Backend?
    @ObservationIgnored private var pending: [Offer] = []
    @ObservationIgnored private var active: Offer?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var currentRun: Task<ImportedLipsyncResult, any Error>?
    @ObservationIgnored private var turn = UUID()
    @ObservationIgnored private var invalidated: Set<UUID> = []

    var running: Bool { operation != nil }
    var enabled: Bool { backend != nil }
    var hasPaidWork: Bool { !applied.isEmpty || running }

    func refresh() async {
        guard let backend, !refreshing, !usingTakes else { return }
        let revision = turn
        refreshing = true
        defer { refreshing = false }
        keyAvailable = await backend.hasKey()
        consentAccepted = backend.hasConsent()
        do {
            monthlyCap = try await backend.cap()
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

    func start(_ offer: Offer) {
        guard let backend, keyAvailable, !usingTakes, offer.isCurrent(),
              offer.phraseIDs.allSatisfy({ !isRunning($0) && applied[$0] == nil }) else { return }
        backend.acceptConsent(); consentAccepted = true
        receipts.append(Receipt(id: offer.id, phraseIDs: offer.phraseIDs, estimate: offer.estimate))
        for phrase in offer.phraseIDs { states[phrase] = .running(started: Date(), progress: nil) }
        pending.append(offer)
        if operation == nil { operation = Task { [weak self] in await self?.drain() } }
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
                    let run = Task { try await backend.run(offer.request, window, offer.recordID) { [weak self] progress in
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

    func finishUseTakes() { usingTakes = false }

    static func reason(_ error: any Error) -> String {
        if error as? LipsyncPreparationError == .noClearFace { return "No clear face in this part." }
        if error as? LipsyncError == .missingKey { return "Lip sync needs your fal.ai key." }
        if error as? LipsyncError == .submissionUncertain { return "The submission response was lost. Check fal.ai before trying another paid job." }
        if case LipsyncError.http(let status) = error { return "fal.ai returned HTTP \(status)." }
        return "The job could not be completed. Your original video and edits are safe."
    }
}
