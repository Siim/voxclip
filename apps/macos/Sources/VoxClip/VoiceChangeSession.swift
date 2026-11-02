import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

@MainActor @Observable final class VoiceChangeSession {
    private static var pendingSaves: [UUID: VoiceChangeSession] = [:]
    @ObservationIgnored private let recoveryID = UUID()
    enum Phase: Equatable {
        case idle, discovering, choosing, preparing, quoted, converting, reviewing, ready, accepted, stopped, failed
    }
    enum Failure: Error, Equatable {
        case stale, approvalRequired, expired, alreadyStarted, invalidReview, unsupportedScope, unavailable
    }
    struct Snapshot: Sendable {
        let project: Project
        let scope: RewriteScope
        let outputScope: VoiceLabOutputScope
        let source: URL
        let window: VoiceLabWindow
        let envelope: AudioEnvelope
        var language: String { project.transcript?.language ?? "en" }
        var sampleRate: Int { project.media.source.audio?.sampleRate ?? 48_000 }
        var title: String { scope == .fullTake ? "Change Full Take Voice" : "Change Passage Voice" }
    }
    struct Choices {
        let voices: [VoiceConsentRecord]
        let models: [VoiceLabModel]
    }
    struct Request: Sendable {
        let sourceRange: Range<Int64>
        let audio: Data
        let quote: VoiceLabQuote
    }
    struct Prepared: Sendable {
        let id: UUID
        let record: VoiceConsentRecord
        let modelID: String
        let seed: UInt32
        let requests: [Request]
        let preparedAt: Duration
        var estimate: CostEstimate { VoiceChangeSession.total(requests.map(\.quote.estimate)) }
    }
    struct Output: Sendable {
        let requestID: UUID
        let asset: VoiceLabAsset
        let receipt: VoiceLabReceipt
    }
    struct Unpublished {
        let result: VoiceLabAudioResult
        let request: Request
    }
    struct Payload {
        let segments: [VoiceLabSegment]
        let assets: [VoiceLabAsset]
        let voice: VoiceLabVoiceReference
    }
    struct Review {
        let project: Project
        let contract: VoiceLabPreparedRender
        let media: VoiceLabRenderInput?
        let play: @MainActor () throws -> Void
        let stop: @MainActor () -> Void
        let verify: @MainActor () throws -> Void
    }
    struct Backend {
        var discover: @MainActor (Snapshot) async throws -> Choices
        var prepare: @MainActor (Snapshot, String, String, UInt32) async throws -> Prepared
        var validate: @MainActor (Prepared) async throws -> Void
        var checkSpend: @MainActor ([VoiceLabQuote]) async throws -> Void
        var approve: @MainActor (Prepared) async throws -> Void
        var discard: @MainActor (Prepared) async -> Void
        var convert: @MainActor (Prepared, Request, @escaping VoiceLabTakeDispatchBoundary,
            @escaping @Sendable (UUID) async -> Void) async throws -> VoiceLabAudioResult
        var preserve: @MainActor (VoiceLabAudioResult, Request) throws -> Output
        var review: @MainActor (Snapshot, Prepared, [Output]) async throws -> Review
        var chargesChanged: @MainActor () async -> Void
    }

    let snapshot: Snapshot
    private(set) var phase = Phase.idle
    private(set) var voices: [VoiceConsentRecord] = []
    private(set) var models: [VoiceLabModel] = []
    private(set) var selectedVoiceID: String?
    private(set) var selectedModelID: String?
    private(set) var prepared: Prepared?
    private(set) var outputs: [Output] = []
    private(set) var unpublished: [Unpublished] = []
    private(set) var acceptedRequestIDs: Set<UUID> = []
    private(set) var dispatchedRequestIDs: Set<UUID> = []
    private(set) var problem = ""
    private(set) var review: Review?
    private(set) var spendWarnings: [VoiceLabSpendWarning] = []
    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private let commit: @MainActor (Review) throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Duration
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var open = true
    @ObservationIgnored private var active = false
    @ObservationIgnored private var approvedPreparedID: UUID?

    init(snapshot: Snapshot, backend: Backend, isCurrent: @escaping @MainActor () -> Bool,
         commit: @escaping @MainActor (Review) throws -> Void,
         now: @escaping @Sendable () -> Duration = VoiceLabQuoteClock.continuousSource()) {
        self.snapshot = snapshot; self.backend = backend; self.isCurrent = isCurrent; self.commit = commit; self.now = now
    }
    var busy: Bool { active }
    var current: Bool { open && isCurrent() }
    var canClose: Bool { !busy && unpublished.isEmpty }
    var hasPaidWork: Bool { !dispatchedRequestIDs.isEmpty || !acceptedRequestIDs.isEmpty || !outputs.isEmpty }
    var canPrepare: Bool { current && !busy && !hasPaidWork && selectedVoiceID != nil && selectedModelID != nil }
    var canGenerate: Bool { current && !busy && phase == .quoted && prepared != nil && !hasPaidWork }
    var canAccept: Bool { current && !busy && phase == .ready && review != nil }
    static func recoverable(for project: Project) -> [VoiceChangeSession] {
        pendingSaves.values.filter { $0.snapshot.project.id == project.id &&
            $0.snapshot.project.media.source.contentKey == project.media.source.contentKey }
    }
    var acceptedEstimate: CostEstimate {
        Self.total(prepared?.requests.filter { acceptedRequestIDs.contains($0.quote.requestID) }.map(\.quote.estimate) ?? [])
    }
    var costCopy: String {
        guard let estimate = prepared?.estimate else { return "Prepare an exact cost before sending audio." }
        return estimate.usd.map { "Estimated " + VoiceLabCostPresentation.format($0) } ?? "Price unavailable. ElevenLabs may charge for this conversion."
    }
    var chargeCopy: String {
        guard !acceptedRequestIDs.isEmpty else {
            return dispatchedRequestIDs.isEmpty ? "Nothing has been sent for conversion." : "A dispatch was attempted. Its billing status may be unknown; check ElevenLabs before trying again."
        }
        let amount = acceptedEstimate.usd.map(VoiceLabCostPresentation.format) ?? "an unknown amount"
        return "ElevenLabs accepted \(acceptedRequestIDs.count) request(s), estimated \(amount). Stopping or rejecting does not refund accepted requests."
    }
    func chooseVoice(_ id: String?) {
        guard !busy, !hasPaidWork, id == nil || voices.contains(where: { $0.id == id }) else { return }
        selectedVoiceID = id; clearQuote()
    }
    func chooseModel(_ id: String?) {
        guard !busy, !hasPaidWork, id == nil || models.contains(where: { $0.id == id }) else { return }
        selectedModelID = id; clearQuote()
    }
    private func clearQuote() {
        revision = UUID(); prepared = nil; approvedPreparedID = nil; problem = ""; phase = .choosing
    }
    func startDiscovery() { launch { await $0.discover() } }
    func startPreparation() { launch { await $0.prepare() } }
    func startGeneration(approvedQuoteID: UUID) { launch { await $0.generate(approvedQuoteID: approvedQuoteID) } }
    func startAcceptance() { launch { await $0.accept() } }
    func startLocalReview() { launch { await $0.retryLocalReview() } }
    private func launch(_ work: @escaping @MainActor (VoiceChangeSession) async -> Void) {
        guard !busy, operation == nil else { return }
        operation = Task { [self] in
            await work(self)
            operation = nil
        }
    }
    func discover() async {
        guard current, !busy, !hasPaidWork else { return }
        active = true; phase = .discovering; problem = ""
        let turn = revision
        defer { active = false }
        do {
            let choices = try await backend.discover(snapshot)
            try requireCurrent(turn)
            voices = choices.voices; models = choices.models
            selectedVoiceID = nil; selectedModelID = nil; prepared = nil; phase = .choosing
        } catch { finish(error) }
    }
    func prepare() async {
        guard canPrepare, let voice = selectedVoiceID, let model = selectedModelID else { return }
        active = true; phase = .preparing; problem = ""; prepared = nil
        let turn = revision
        defer { active = false }
        do {
            let value = try await backend.prepare(snapshot, voice, model, UInt32.random(in: .min ... .max))
            try requireCurrent(turn)
            guard !value.requests.isEmpty, value.record.id == voice, value.modelID == model,
                  Set(value.requests.map { $0.quote.requestID }).count == value.requests.count,
                  value.requests.allSatisfy({ $0.quote.operation == .voiceChange && $0.quote.modelID == model &&
                      $0.quote.endpoint == "v1/voice-changer/\(value.record.voiceId)" &&
                      $0.quote.guardAudioHash == VoiceLabFingerprint.bytes($0.audio) }) else { throw Failure.approvalRequired }
            try Self.validateCoverage(value.requests, window: snapshot.window)
            try await backend.checkSpend(value.requests.map(\.quote))
            try requireCurrent(turn)
            prepared = value; phase = .quoted
        } catch { finish(error) }
    }
    func generate(approvedQuoteID: UUID) async {
        guard canGenerate, let prepared, approvedQuoteID == prepared.id else { return }
        active = true; phase = .converting; problem = ""
        let turn = revision
        defer { active = false }
        do {
            try requireFresh(prepared)
            try await backend.validate(prepared)
            try requireCurrent(turn)
            try await backend.approve(prepared)
            try requireCurrent(turn)
            approvedPreparedID = prepared.id
            for request in prepared.requests {
                try requireCurrent(turn)
                let result = try await backend.convert(prepared, request, { [weak self] requestID, start in
                    guard let self else { throw CancellationError() }
                    try await self.dispatch(requestID, prepared: prepared, turn: turn, start: start)
                }, { [self] requestID in await recordAcceptance(requestID, prepared: prepared) })
                guard dispatchedRequestIDs.contains(request.quote.requestID) else { throw Failure.approvalRequired }
                unpublished.append(Unpublished(result: result, request: request))
                Self.pendingSaves[recoveryID] = self
                let output = try backend.preserve(result, request)
                outputs.append(output); unpublished.removeAll { $0.request.quote.requestID == request.quote.requestID }
                if unpublished.isEmpty { Self.pendingSaves.removeValue(forKey: recoveryID) }
                if let warning = result.spendWarning { spendWarnings.append(warning) }
                try requireCurrent(turn)
                guard output.requestID == request.quote.requestID, result.receipt.requestID == request.quote.requestID,
                      result.receipt.voiceID == prepared.record.voiceId, result.receipt.modelID == prepared.modelID,
                      result.receipt.region == request.quote.region, result.receipt.endpoint == request.quote.endpoint else { throw Failure.invalidReview }
            }
            phase = .reviewing
            let value = try await backend.review(snapshot, prepared, outputs)
            try requireCurrent(turn)
            try value.verify()
            try value.contract.verify(project: value.project, scope: snapshot.outputScope, labelPosition: value.contract.disclosure.position)
            review = value; phase = .ready
        } catch { finish(error) }
        await backend.discard(prepared)
    }
    private func dispatch(_ requestID: UUID, prepared: Prepared, turn: UUID,
                          start: @escaping @Sendable () throws -> Void) async throws {
        try requireCurrent(turn)
        guard approvedPreparedID == prepared.id else { throw Failure.approvalRequired }
        if dispatchedRequestIDs.isEmpty { try requireFresh(prepared) }
        guard let index = prepared.requests.firstIndex(where: { $0.quote.requestID == requestID }),
              !dispatchedRequestIDs.contains(requestID), index == dispatchedRequestIDs.count else { throw Failure.alreadyStarted }
        try await backend.validate(prepared)
        try requireCurrent(turn)
        try await backend.checkSpend(Array(prepared.requests[index...]).map(\.quote))
        try requireCurrent(turn)
        if dispatchedRequestIDs.isEmpty { try requireFresh(prepared) }
        dispatchedRequestIDs.insert(requestID)
        try start()
    }
    private func recordAcceptance(_ requestID: UUID, prepared: Prepared) async {
        guard prepared.requests.contains(where: { $0.quote.requestID == requestID }),
              acceptedRequestIDs.insert(requestID).inserted else { return }
        await backend.chargesChanged()
    }
    func accept() async {
        guard canAccept, let review, let prepared else { return }
        active = true; problem = ""
        let turn = revision
        defer { active = false }
        do {
            try await backend.validate(prepared)
            try requireCurrent(turn)
            try review.verify()
            try review.contract.verify(project: review.project, scope: snapshot.outputScope, labelPosition: review.contract.disclosure.position)
            try commit(review)
            review.stop(); phase = .accepted; open = false
        } catch { finish(error) }
    }
    func retrySaving() {
        guard !busy, !unpublished.isEmpty else { return }
        problem = ""
        while let pending = unpublished.first {
            do {
                outputs.append(try backend.preserve(pending.result, pending.request))
                unpublished.removeFirst()
            } catch { problem = Self.copy(error); return }
        }
        Self.pendingSaves.removeValue(forKey: recoveryID)
    }
    func retryLocalReview() async {
        guard current, !busy, let prepared, unpublished.isEmpty,
              outputs.count == prepared.requests.count, !outputs.isEmpty else { return }
        active = true; phase = .reviewing; problem = ""
        let turn = revision
        defer { active = false }
        do {
            try await backend.validate(prepared)
            try requireCurrent(turn)
            let value = try await backend.review(snapshot, prepared, outputs)
            try requireCurrent(turn)
            try value.verify()
            try value.contract.verify(project: value.project, scope: snapshot.outputScope, labelPosition: value.contract.disclosure.position)
            review?.stop(); review = value; phase = .ready
        } catch { finish(error) }
    }
    func playReview() {
        guard canAccept, let review else { return }
        do { try review.verify(); try review.play() } catch { problem = Self.copy(error) }
    }
    func cancel() {
        revision = UUID(); operation?.cancel(); review?.stop()
        if phase != .accepted { phase = .stopped }
        problem = ""
    }
    @discardableResult func close() -> Bool {
        cancel()
        guard !busy else {
            problem = "Wait for the stopped request to settle. Any paid audio and billing evidence will be kept here."
            return false
        }
        guard unpublished.isEmpty else {
            problem = "Save the paid audio locally before closing this review. It will not be uploaded or generated again."
            return false
        }
        open = false
        return true
    }
    private func requireCurrent(_ turn: UUID) throws {
        try Task.checkCancellation()
        guard revision == turn, current else { throw Failure.stale }
    }
    private func requireFresh(_ value: Prepared) throws {
        let age = now() - value.preparedAt
        guard age >= .zero, age < .seconds(300) else { throw Failure.expired }
    }
    private func finish(_ error: any Error) {
        if phase == .stopped { return }
        if error is CancellationError || (error as? VoiceLabError) == .cancelled || (error as? VoiceConsentError) == .cancelled {
            phase = .stopped; problem = ""
        } else {
            phase = .failed; problem = Self.copy(error)
        }
    }
    static func validateCoverage(_ requests: [Request], window: VoiceLabWindow) throws {
        var cursor = window.startSample
        for request in requests {
            guard request.sourceRange.lowerBound == cursor, request.sourceRange.upperBound > cursor else { throw Failure.approvalRequired }
            cursor = request.sourceRange.upperBound
        }
        guard cursor == window.endSample else { throw Failure.approvalRequired }
    }
    static func copy(_ error: any Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .stale: return "The source, scope, voice, account or settings changed. Nothing was applied. Open a new voice change to prepare a new quote."
            case .expired: return "This quote expired. Nothing was applied. Prepare and approve a new quote; conversion never retries automatically."
            case .alreadyStarted: return "This request already started. It will not be sent again."
            case .approvalRequired: return "This conversion no longer matches its approved quote. Nothing was applied."
            case .invalidReview: return "This conversion could not pass review. Your original media, edits and saved paid audio are unchanged."
            case .unsupportedScope: return "Choose an uncut passage or an uncut full take. Existing AI replacements and cuts cannot be converted by this workflow yet."
            case .unavailable: return "Voice changing needs the verified conversion and local review services. Nothing was sent."
            }
        }
        return RewriteSession.refusal(error)
    }
    nonisolated static func total(_ estimates: [CostEstimate]) -> CostEstimate {
        CostEstimate(provider: "elevenlabs", operation: "voiceChange", units: estimates.reduce(0) { $0 + $1.units },
            unit: "second", usd: estimates.allSatisfy({ $0.usd != nil }) ? estimates.reduce(Decimal.zero) { $0 + ($1.usd ?? 0) } : nil,
            credits: estimates.allSatisfy({ $0.credits != nil }) ? estimates.reduce(0) { $0 + ($1.credits ?? 0) } : nil,
            basis: "sum-of-voice-change-quotes")
    }
}
