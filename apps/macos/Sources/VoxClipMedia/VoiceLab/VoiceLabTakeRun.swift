import Foundation
import Synchronization
import VoxClipCore

private final class VoiceLabRunDispatch: Sendable {
    private struct State { var started = false; var retired = false }
    private let state = Mutex(State())
    var started: Bool { state.withLock { $0.started } }
    func start() { state.withLock { $0.started = true } }
    func retire() -> Bool {
        state.withLock { state in
            guard state.started, !state.retired else { return false }
            state.retired = true
            return true
        }
    }
}

public actor VoiceLabTakeRun {
    private struct Pending: Sendable {
        let quote: VoiceLabTakeRunQuote
        let input: VoiceLabTakeInput
        let record: VoiceConsentRecord
        let preflight: VoiceLabTakePreflight
        let source: VoiceLabSourceExcerpt
        let sourceSpeech: [Float]
        let modelRevision: Int
        /// Pinned in the client by a take batch's one approval (`approve(_:)`), so `execute` skips its own approval.
        var approvedAhead = false
    }
    private enum Abort: Error { case invalidated }
    private let client: ElevenLabsVoiceLab
    private let store: VoiceConsentStore
    private let speaker: VoiceSpeakerCheck
    private let useGuard: VoiceUseGuard
    private let inputsAreCurrent: @Sendable () async -> Bool
    private let storage: VoiceLabTakeStorage
    private var scratches: [UUID: VoiceLabTakeScratch] = [:]
    private var paidAssets: [UUID: VoiceLabAsset] = [:]
    private let dispatchIfCurrent: VoiceLabDispatchBoundary
    private nonisolated let dispatchRevision = Mutex(0)
    private var pending: Pending?
    private var task: Task<VoiceLabTakeRunResult, Never>?
    private var runningID: UUID?
    private var executionOwner: UUID?
    private var revision = 0
    private var stop: VoiceLabTakeRunEnd = .cancelled
    #if DEBUG
    private var executeHook: (@Sendable (String) async -> Void)?
    package func useExecuteHook(_ hook: @escaping @Sendable (String) async -> Void) { executeHook = hook }
    /// The ID of the set `prepare(_:)` holds for `execute`, so tests can see a batch's rollback.
    package var preparedSetID: UUID? { pending?.quote.id }
    #endif
    public init(client: ElevenLabsVoiceLab, store: VoiceConsentStore, speaker: VoiceSpeakerCheck,
                storage: VoiceLabTakeStorage,
                dispatchIfCurrent: @escaping VoiceLabDispatchBoundary,
                inputsAreCurrent: @escaping @Sendable () async -> Bool) {
        self.client = client; self.store = store; self.speaker = speaker; useGuard = VoiceUseGuard(store: store, check: speaker)
        self.inputsAreCurrent = inputsAreCurrent
        self.dispatchIfCurrent = dispatchIfCurrent
        self.storage = storage
    }
    public func scratch(for takeId: UUID) -> VoiceLabTakeScratch? { scratches[takeId] }
    public func paidAsset(for takeId: UUID) -> VoiceLabAsset? { paidAssets[takeId] }
    public func publishForAcceptance(_ row: VoiceLabTakeRow, input: VoiceLabTakeInput, at date: Date) async throws -> (VoiceLabPublishedTake, VoiceConsentRecord) {
        let version = revision
        guard row.selectable, let scratch = scratches[row.id], scratch.isValid,
              await inputsAreCurrent(), version == revision else { throw VoiceLabError.consentRequired }
        let record = try await store.load(input.recordID)
        try await store.validateUse(record)
        guard version == revision, scratch.isValid, await inputsAreCurrent(), version == revision,
              let receipt = row.receipt, receipt.voiceID == record.voiceId else { throw VoiceLabError.consentRequired }
        let publication = try scratch.fitted.publish(projectId: storage.projectId,
            assetId: UUID().uuidString.lowercased(), paidRoot: storage.paidRoot, createdAt: date,
            requestId: receipt.requestID.uuidString, seed: row.seed, gainDb: scratch.audio.gainDb)
        return (VoiceLabPublishedTake(assets: publication.assets, audio: publication.audio, outDuration: publication.outDuration,
            words: publication.words, chunks: publication.chunks), record)
    }
    public func reject(_ takeId: UUID) async { await scratches.removeValue(forKey: takeId)?.invalidate() }
    public func discover(language: String) async throws -> (models: [VoiceLabModel], voices: [VoiceConsentRecord]) {
        guard await inputsAreCurrent() else { throw VoiceLabError.consentRequired }
        let models = try await client.models().filter { $0.supportsTimestampedTTS && $0.languages.contains(language) }
        let remote = try await client.listOwnClones()
        let voices = try await store.activeVoices().filter { record in
            record.statement.language == language && remote.contains { $0.id == record.voiceId && (!$0.requiresVerification || $0.isVerified) }
        }
        return (models, voices)
    }
    public func prepare(_ input: VoiceLabTakeInput) async throws -> VoiceLabTakeRunQuote {
        guard task == nil, executionOwner == nil, runningID == nil else { throw VoiceLabError.consentRequired }
        revision += 1
        dispatchRevision.withLock { $0 = revision }
        let currentRevision = revision
        if let pending {
            self.pending = nil
            await client.discardRun(pending.quote.id, quotes: pending.quote.takes.flatMap { [$0.synthesis, $0.qa] })
        }
        try Task.checkCancellation()
        guard revision == currentRevision else { throw Abort.invalidated }
        try FileManager.default.createDirectory(at: storage.scratchRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record = try await store.load(input.recordID)
        try await store.validateUse(record)
        guard input.providerConsent, input.language == record.statement.language,
              speaker.supports(language: input.language), speaker.embedder?.modelID == record.speaker.model,
              speaker.threshold == record.speaker.threshold else { throw VoiceConsentError.speakerUnavailable }
        let preflight = try VoiceLabTakeProcessing.preflight(input)
        let resampled = try VoiceLabSourceAudio.resample(input.source, from: Double(input.sourceSampleRate), to: 24_000)
        let rate = input.sourceSampleRate
        let center = Int((input.window.startSample + input.window.endSample) / 2)
        let start = max(0, center - 5 * rate), end = min(input.source.totalFrames, start + 10 * rate)
        guard let speech = input.source.samples(start..<end) else { throw VoiceLabError.invalidInput }
        let sourceSpeech = VoiceConsentAudio.resample(Array(speech), rate: rate)
        let id = UUID()
        var takes: [VoiceLabTakeQuote] = []
        var quotes: [VoiceLabQuote] = []
        do {
            for index in 0..<VoiceLabPricing.maximumCandidates {
                let options = input.options(take: index)
                let speech = try await client.prepareSynthesis(text: input.text, modelID: input.modelID,
                    voice: .own(voiceID: record.voiceId, policy: policy(record)), language: input.language, options: options, requestID: UUID())
                quotes.append(speech)
                let qa = try await client.prepareQA(language: input.language, requestID: UUID())
                quotes.append(qa)
                takes.append(VoiceLabTakeQuote(index: index, seed: options.seed, synthesis: speech, qa: qa))
            }
            let modelRevision = await client.modelRevision()
            guard revision == currentRevision, await inputsAreCurrent(), revision == currentRevision else { throw Abort.invalidated }
            let quote = VoiceLabTakeRunQuote(id: id, takes: takes, preparedAt: quotes.map(\.preparedAt).min() ?? Date())
            pending = Pending(quote: quote, input: input, record: record, preflight: preflight, source: resampled,
                              sourceSpeech: sourceSpeech, modelRevision: modelRevision)
            return quote
        } catch {
            await client.discardRun(id, quotes: quotes)
            throw error
        }
    }
    /// Pins this run's prepared set under a take batch's one approval (voice-lab §8.6 with several hunks, `VoiceLabTakeBatchRun`).
    /// Every quote must still be fresh. The client then holds the set, so it neither expires nor is evicted while the
    /// batch's earlier windows run, and `execute(_:approved:progress:started:)` later runs it without a second approval.
    /// Nothing is sent. A quote that is not this run's prepared set, a set already pinned, and a run that is executing are
    /// refused (`consentRequired`). `cancel()`, a new `prepare(_:)` and a launch that ends before any dispatch drop the pin.
    public func approve(_ quote: VoiceLabTakeRunQuote) async throws {
        guard task == nil, runningID == nil, executionOwner == nil, let value = pending, value.quote == quote, !value.approvedAhead
        else { throw VoiceLabError.consentRequired }
        let currentRevision = revision
        let quotes = quote.takes.flatMap { [$0.synthesis, $0.qa] }
        guard await client.quotesAreFresh(quotes), revision == currentRevision, executionOwner == nil else { throw VoiceLabError.consentRequired }
        try await client.approveRun(quote.id, quotes: quotes)
        guard revision == currentRevision, executionOwner == nil, pending?.quote == quote else {
            await client.unapproveRun(quote.id)
            throw VoiceLabError.consentRequired
        }
        pending?.approvedAhead = true
    }
    public func execute(_ quote: VoiceLabTakeRunQuote, approved: Bool,
                        progress: @escaping @Sendable ([VoiceLabTakeRow]) async -> Void = { _ in },
                        started: @escaping @Sendable () async throws -> Void = {}) async throws -> VoiceLabTakeRunResult {
        guard approved, task == nil, runningID == nil, executionOwner == nil, let value = pending, value.quote == quote else { throw VoiceLabError.consentRequired }
        let owner = UUID()
        executionOwner = owner
        let currentRevision = revision
        runningID = quote.id
        pending = nil
        stop = .cancelled
        let quotes = quote.takes.flatMap { [$0.synthesis, $0.qa] }
        let dispatch = VoiceLabRunDispatch()
        do {
            // A set pinned by a batch approval was fresh when the user approved the batch, and the client holds it since.
            let fresh: Bool
            if value.approvedAhead { fresh = true } else { fresh = await client.quotesAreFresh(quotes) }
            try await checkpoint("clock", revision: currentRevision)
            guard fresh else { throw VoiceLabError.consentRequired }
            try await validate(value, revision: currentRevision)
            try await checkpoint("validation", revision: currentRevision)
            if !value.approvedAhead { try await client.approveRun(quote.id, quotes: quotes) }
            try await checkpoint("approval", revision: currentRevision)
            try await checkpoint("launch", revision: currentRevision)
            try await started()
            try reservation(currentRevision)
        } catch {
            await release(owner: owner, quote: quote, retaining: revision == currentRevision ? value : nil)
            throw error
        }
        let operation = Task { await self.perform(value, revision: currentRevision, dispatch: dispatch, progress: progress) }
        task = operation; runningID = quote.id
        let result = await withTaskCancellationHandler { await operation.value } onCancel: {
            operation.cancel()
        }
        await release(owner: owner, quote: quote, retaining: !dispatch.started && revision == currentRevision ? value : nil)
        return result
    }
    private func release(owner: UUID, quote: VoiceLabTakeRunQuote, retaining value: Pending? = nil) async {
        guard executionOwner == owner else { return }
        if var value {
            value.approvedAhead = false
            pending = value
            await client.unapproveRun(quote.id)
        } else {
            await client.discardRun(quote.id, quotes: quote.takes.flatMap { [$0.synthesis, $0.qa] })
        }
        guard executionOwner == owner else { return }
        task = nil; runningID = nil; executionOwner = nil
    }
    public func cancel(keepingTakes: Bool = false) async {
        stop = .cancelled; revision += 1; task?.cancel()
        dispatchRevision.withLock { $0 = revision }
        if !keepingTakes {
            let retired = Array(scratches.values)
            scratches.removeAll()
            for scratch in retired { await scratch.invalidate() }
        }
        if let pending {
            self.pending = nil
            await client.discardRun(pending.quote.id, quotes: pending.quote.takes.flatMap { [$0.synthesis, $0.qa] })
        }
    }
    public func invalidate() async {
        await cancel()
        stop = .invalidated
    }
    private func validate(_ value: Pending, revision expected: Int) async throws {
        try reservation(expected)
        let current = await inputsAreCurrent()
        try await checkpoint("inputs", revision: expected)
        guard current else { throw Abort.invalidated }
        let modelRevision = await client.modelRevision()
        try await checkpoint("model", revision: expected)
        guard modelRevision == value.modelRevision else { throw Abort.invalidated }
        try await speaker.embedder?.validateAvailability()
        try await checkpoint("embedder", revision: expected)
        try await store.validateUse(value.record)
        try await checkpoint("consent", revision: expected)
        let record = try await store.load(value.record.id)
        try await checkpoint("record", revision: expected)
        guard record == value.record else { throw VoiceConsentError.inactive }
    }
    private func reservation(_ expected: Int) throws {
        try Task.checkCancellation()
        guard revision == expected, runningID != nil else { throw Abort.invalidated }
    }
    private func checkpoint(_ name: String, revision expected: Int) async throws {
        #if DEBUG
        await executeHook?(name)
        #endif
        try reservation(expected)
    }
    private func perform(_ value: Pending, revision expected: Int, dispatch: VoiceLabRunDispatch,
                         progress: @escaping @Sendable ([VoiceLabTakeRow]) async -> Void) async -> VoiceLabTakeRunResult {
        var rows: [VoiceLabTakeRow] = []
        for take in value.quote.takes {
            do { try await validate(value, revision: expected) }
            catch { return VoiceLabTakeRunResult(rows: rows, end: end(error)) }
            var receipt: VoiceLabReceipt?
            var qaReceipt: VoiceLabReceipt?
            var generated: VoiceLabAudioResult?
            var audio: VoiceLabTakeAudio?
            let synthesisAccepted = VoiceLabRequestAcceptance(), qaAccepted = VoiceLabRequestAcceptance()
            do {
                let authorization = try await useGuard.authorize(quote: take.synthesis, contentKey: value.input.contentKey,
                    recordID: value.record.id, speech16k: value.sourceSpeech, approved: true)
                try await authorization.capability?.bindDispatch(boundary(revision: expected, dispatch: dispatch))
                try await validate(value, revision: expected)
                let result = try await client.synthesize(text: value.input.text, modelID: value.input.modelID,
                    voice: .own(voiceID: value.record.voiceId, policy: authorization), language: value.input.language,
                    options: value.input.options(take: take.index), requestID: take.synthesis.requestID,
                    authorization: VoiceLabAuthorization(quote: take.synthesis, approved: true), acceptance: synthesisAccepted)
                receipt = result.receipt
                generated = result
                let storage = storage
                let paid = try await Task.detached(priority: .utility) {
                    try VoiceLabAssetStore.write(pcm16: result.pcm, sampleRate: result.sampleRate, projectId: storage.projectId,
                        assetId: UUID().uuidString.lowercased(), paidRoot: storage.paidRoot, createdAt: Date())
                }.value
                paidAssets[take.synthesis.requestID] = paid
                try await validate(value, revision: expected)
                let analysis = try VoiceLabTakeProcessing.process(result, input: value.input, preflight: value.preflight)
                let snapshot = try VoiceLabAssets.preparePaid(asset: paid, projectId: storage.projectId, paidRoot: storage.paidRoot, scratchRoot: storage.scratchRoot)
                let fitted = try VoiceLabSilenceFit.prepare(snapshot: snapshot, paidAsset: paid, fit: analysis.fit,
                    window: value.input.window, sourceSampleRate: value.input.sourceSampleRate)
                let scratch = try VoiceLabAudioRenderer.stageTake(fitted: fitted, analysis: analysis, input: value.input,
                    sourceAtAssetRate: value.source, scratchRoot: storage.scratchRoot)
                scratches[take.synthesis.requestID] = scratch
                let processed = scratch.audio
                audio = processed
                let vector: [Float]
                do {
                    guard processed.trimmed.count >= processed.sampleRate * 3 else { throw VoiceConsentError.speakerMismatch }
                    vector = try await speaker.embedding(VoiceConsentAudio.resample(processed.trimmed, rate: processed.sampleRate))
                }
                catch VoiceConsentError.speakerMismatch {
                    let peak = try VoiceLabLoudness.samplePeakDbfs(processed.mixed)
                    let jump = try VoiceLabLoudness.lufsJumpLu(processed.mixed, sampleRate: processed.sampleRate, seamSamples: processed.seams)
                    let qa = VoiceLabTakeQAResult(values: VoiceLabQA(lufsJumpLu: jump, peakDbfs: peak), failures: [.speaker])
                    rows.append(VoiceLabTakeRow(id: take.synthesis.requestID, index: take.index, seed: take.seed, receipt: receipt,
                        audio: processed, qa: qa, failure: .qa([.speaker]), generated: generated, quote: take))
                    await progress(rows)
                    continue
                }
                guard let owner = VoiceConsentRecord.decodeEmbedding(value.record.speaker.embedding) else { throw VoiceConsentError.invalidRecord }
                let score = try VoiceSpeakerCheck.cosine(owner, vector)
                try await validate(value, revision: expected)
                let store = store
                let capability = VoiceOperationCapability(quote: take.qa, reserve: {
                    try await store.dispatchPermit(value.record, requestID: take.qa.requestID)
                }) { try await self.validate(value, revision: expected) }
                try await capability.bindDispatch(boundary(revision: expected, dispatch: dispatch))
                let recognized = try await client.transcribeQA(processed.mixed, rate: processed.sampleRate,
                    language: value.input.language, authorization: VoiceLabAuthorization(quote: take.qa, approved: true), capability: capability,
                    acceptance: qaAccepted)
                qaReceipt = recognized.receipt
                try await validate(value, revision: expected)
                let lower = Double(processed.patchRange.lowerBound) / Double(processed.sampleRate)
                let upper = Double(processed.patchRange.upperBound) / Double(processed.sampleRate)
                let inside = recognized.words.filter { ($0.start + $0.end) / 2 >= lower && ($0.start + $0.end) / 2 < upper }.map(\.text)
                let qa = try VoiceLabTakeQuality.evaluate(expected: value.input.text, recognized: inside, mixed: processed.mixed,
                    sampleRate: processed.sampleRate, seams: processed.seams, speakerScore: score, threshold: value.record.speaker.threshold)
                let flatness = try VoiceLabLoudness.flatness(processed.trimmed, sampleRate: processed.sampleRate)
                let rank = try VoiceLabTakeQuality.rank(fit: processed.fit, windowSeconds: value.input.window.end - value.input.window.start,
                    matchRatio: qa.values.transcriptMatch ?? 0, flatness: flatness)
                rows.append(VoiceLabTakeRow(id: take.synthesis.requestID, index: take.index, seed: take.seed, receipt: receipt,
                    audio: processed, qa: qa, score: rank, failure: qa.passed ? nil : .qa(qa.failures),
                    qaReceipt: qaReceipt, generated: generated, quote: take))
                await progress(rows)
                do { try await validate(value, revision: expected) }
                catch { return VoiceLabTakeRunResult(rows: rows, end: end(error)) }
                if qa.passed, case .exact = processed.fit { return VoiceLabTakeRunResult(rows: rows, end: .earlyStop) }
            } catch {
                guard dispatch.started else { return VoiceLabTakeRunResult(rows: [], end: end(error)) }
                // A request the provider accepted is in the spend ledger even when its reply failed and left no receipt.
                var accepted = Set<UUID>()
                if synthesisAccepted.accepted { accepted.insert(take.synthesis.requestID) }
                if qaAccepted.accepted { accepted.insert(take.qa.requestID) }
                rows.append(VoiceLabTakeRow(id: take.synthesis.requestID, index: take.index, seed: take.seed, receipt: receipt,
                    audio: audio, failure: failure(error), qaReceipt: qaReceipt, generated: generated, quote: take, accepted: accepted))
                await progress(rows)
                if fatal(error) { return VoiceLabTakeRunResult(rows: rows, end: end(error)) }
            }
        }
        return VoiceLabTakeRunResult(rows: rows, end: .completed)
    }
    private func policy(_ record: VoiceConsentRecord) -> OwnVoicePolicy {
        OwnVoicePolicy(recordID: record.id, cloneVoiceID: record.voiceId, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
    }
    private func boundary(revision expected: Int, dispatch run: VoiceLabRunDispatch) -> VoiceLabDispatchBoundary {
        let dispatch = dispatchIfCurrent
        return { [self] start in
            try await dispatch {
                try self.dispatchRevision.withLock { revision in
                    guard revision == expected else { throw Abort.invalidated }
                    try start()
                    run.start()
                }
            }
            if run.retire() { await self.retirePreviousTakes() }
        }
    }
    private func retirePreviousTakes() async {
        let retired = Array(scratches.values)
        scratches.removeAll(); paidAssets.removeAll()
        for scratch in retired { await scratch.invalidate() }
    }
    private func fatal(_ error: any Error) -> Bool {
        if error is VoiceConsentError || error is CancellationError || error is Abort || Task.isCancelled { return true }
        guard let error = error as? VoiceLabError else { return false }
        switch error {
        case .unauthorized, .permissionMissing, .missingKey, .quotaExceeded, .consentRequired, .speakerMismatch, .cancelled, .invalidAlignment: return true
        default: return false
        }
    }
    private func end(_ error: any Error) -> VoiceLabTakeRunEnd {
        if error is Abort { return .invalidated }
        if error is CancellationError || Task.isCancelled { return stop }
        if let error = error as? VoiceLabError, error == .cancelled { return .cancelled }
        return .fatal
    }
    private func failure(_ error: any Error) -> VoiceLabTakeFailure {
        if error is CancellationError || Task.isCancelled { return .provider(.cancelled) }
        if let error = error as? VoiceLabError { return .provider(error) }
        if let error = error as? VoiceConsentError { return .consent(error) }
        if error is VoiceLabGeometryError { return .invalidAlignment }
        return .invalidAudio
    }
}
