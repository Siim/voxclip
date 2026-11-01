import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

@MainActor @Observable final class ClipTakePlan {
    enum Status: Equatable {
        case waiting, generating(String), ready, stopped(String), failed(String)
    }
    struct Take: Identifiable {
        let number: Int
        let row: VoiceLabTakeRow
        var id: UUID { row.id }
        var length: Double? { row.audio.map { Double($0.fit.plan.outputFrames) / Double($0.sampleRate) } }
        var fits: Bool { row.selectable && row.fits }
    }
    struct Phrase: Identifiable {
        let id: Int
        let indices: [Int]
        let text: String
        let window: VoiceLabWindow
        var status: Status = .waiting
        var takes: [Take] = []
        var selectedID: UUID?
        var selected: Take? { takes.first { $0.id == selectedID } }
        var originalLength: Double { window.end - window.start }
        var lengthDifference: Double? { selected?.length.map { $0 - originalLength } }
        var nextTakeNumber: Int {
            guard takes.count == 3 else { return takes.count + 1 }
            return takes.filter { $0.id != selectedID }.min { ($0.row.score ?? -1) < ($1.row.score ?? -1) }?.number ?? 3
        }
    }
    enum Failure: Error, Equatable {
        case placement(VoiceLabWindowRefusal), budget, spendingCap, unknownSpend, stale, noSelection
    }
    struct Acceptance {
        let segments: [VoiceLabSegment]
        let assets: [VoiceLabAsset]
        let voice: VoiceLabVoiceReference
    }
    struct Backend {
        var prepare: @MainActor ([VoiceLabTakeInput], [Int], Int) async throws -> VoiceLabTakeBatch
        var approve: @MainActor (VoiceLabTakeBatch, [Int]) async throws -> Void
        var execute: @MainActor (VoiceLabTakeBatch, Int, Int, @escaping @Sendable ([VoiceLabTakeRow]) async -> Void) async throws -> VoiceLabTakeRunResult
        var discard: @MainActor () async -> Void
        var invalidate: @MainActor () async -> Void
        var publish: @MainActor (Int, VoiceLabTakeRow, VoiceLabTakeInput, Date) async throws -> (VoiceLabPublishedTake, VoiceConsentRecord)
        var scratch: @MainActor (Int, UUID) async -> VoiceLabTakeScratch?
        var retire: @MainActor (Int, UUID) async -> Void

        init(runs: [VoiceLabTakeRun]) {
            prepare = { inputs, indices, candidates in
                try await VoiceLabTakeBatchRun(runs: indices.map { runs[$0] }).prepare(inputs, candidates: candidates)
            }
            approve = { batch, indices in try await VoiceLabTakeBatchRun(runs: indices.map { runs[$0] }).approve(batch) }
            execute = { batch, index, phrase, progress in
                try await runs[phrase].execute(batch.windows[index].quote, approved: true, keepingPreviousTakes: true, progress: progress)
            }
            discard = { for run in runs { await run.cancel(keepingTakes: true) } }
            invalidate = { for run in runs { await run.invalidate() } }
            publish = { phrase, row, input, date in try await runs[phrase].publishForAcceptance(row, input: input, at: date) }
            scratch = { phrase, take in await runs[phrase].scratch(for: take) }
            retire = { phrase, take in await runs[phrase].reject(take) }
        }
    }
    private(set) var phrases: [Phrase]
    private(set) var preparing = false
    private(set) var generating = false
    private(set) var publishing = false
    private(set) var problem = ""
    private(set) var estimate: CostEstimate?
    private(set) var cost: VoiceLabCostPresentation.Kind?
    private(set) var spent = VoiceLabTakeRunQuote.total(of: [], takes: 0)
    let audition: VoiceLabAudition
    @ObservationIgnored private var auditionTurn = UUID()
    @ObservationIgnored private var receivedInBatch: Set<UUID> = []
    @ObservationIgnored private(set) var invalidation: Task<Void, Never>?
    @ObservationIgnored private let project: Project
    @ObservationIgnored private let scope: VoiceLabOutputScope
    @ObservationIgnored private let makeInput: @MainActor (Phrase) async throws -> VoiceLabTakeInput
    @ObservationIgnored private let readCap: @MainActor () async throws -> VoiceLabMonthlyCap?
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var backend: Backend?
    @ObservationIgnored private var inputs: [VoiceLabTakeInput] = []
    @ObservationIgnored private var nextSeeds: [UInt32] = []
    @ObservationIgnored private var batch: VoiceLabTakeBatch?
    @ObservationIgnored private var batchIndices: [Int] = []
    @ObservationIgnored private var progress: VoiceLabTakeBatchProgress?
    @ObservationIgnored private var sent: Set<UUID> = []
    @ObservationIgnored private var madeRequests: Set<UUID> = []
    @ObservationIgnored private var charges: [CostEstimate] = []
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var runningPhrase: Int?
    var stillCurrent: Bool { !retired && isCurrent() }
    var approvalID: UUID? { batch?.id }

    init(project: Project, scope: VoiceLabOutputScope, envelope: AudioEnvelope, hunks: [VoiceLabDiffHunk],
         makeInput: @escaping @MainActor (Phrase) async throws -> VoiceLabTakeInput,
         readCap: @escaping @MainActor () async throws -> VoiceLabMonthlyCap? = { nil },
         isCurrent: @escaping @MainActor () -> Bool = { true }, audition: VoiceLabAudition = VoiceLabAudition()) throws {
        var final = project
        final.edits.cutWordIds += hunks.filter { $0.kind == .cut }.flatMap(\.sourceWordIds)
        self.project = final; self.scope = scope; self.makeInput = makeInput; self.readCap = readCap; self.isCurrent = isCurrent
        self.audition = audition
        phrases = try Self.preparePlan(project: project, scope: scope, envelope: envelope, hunks: hunks)
    }

    static func preparePlan(project: Project, scope: VoiceLabOutputScope, envelope: AudioEnvelope,
                            hunks: [VoiceLabDiffHunk]) throws -> [Phrase] {
        guard VoiceLabPatchBudget.evaluate(hunks: hunks, transcript: project.transcript?.words ?? []).flag != .reRecordInstead else {
            throw Failure.budget
        }
        let placed = VoiceLabWindowPlanner.placeAll(project: project, scope: scope, envelope: envelope, hunks: hunks)
        let texts = Dictionary(RewriteSession.corrected(project).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var phrases: [Phrase] = []
        for result in placed {
            switch result {
            case .refused(_, _, let reason): throw Failure.placement(reason)
            case .placed(let indices, let hunk, let window):
                let words = window.leftBridgeWordIds.compactMap { texts[$0] } + hunk.newTokens + window.rightBridgeWordIds.compactMap { texts[$0] }
                phrases.append(Phrase(id: phrases.count, indices: indices, text: words.joined(separator: " "), window: window))
            }
        }
        guard (1...VoiceLabTakeBatch.maximumWindows).contains(phrases.count) else { throw VoiceLabError.invalidInput }
        var final = project
        final.edits.cutWordIds += hunks.filter { $0.kind == .cut }.flatMap(\.sourceWordIds)
        try VoiceLabRenderContract.validatePlacement(final, scope: scope, windows: phrases.map(\.window))
        return phrases
    }

    func connect(_ backend: Backend) { precondition(self.backend == nil); self.backend = backend }

    #if DEBUG
    func showFixture(_ state: String) {
        for index in phrases.indices {
            let window = phrases[index].window
            let changed = state == "length-changed"
            let frames = Int64(EditingPrimitives.jsRound((window.end - window.start + (changed ? 1.4 : 0)) * 24_000))
            let fit = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
                trimStartFrame: 0, trimEndFrame: frames, windowStart: window.start, windowEnd: window.end,
                windowStartSample: window.startSample, windowEndSample: window.endSample, outputFrames: frames,
                words: [.init(text: phrases[index].text, start: 0.1, end: max(0.2, Double(frames) / 24_000 - 0.1), synthetic: true)])
            let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0, roomTone: nil,
                fit: changed ? .changedDuration(fit, naturalOut: Double(frames) / 24_000, residualSeconds: 1.4) : .exact(fit))
            let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10, speakerScore: 0.9), failures: [])
            let passing = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, audio: audio, qa: qa, score: 0.9)
            let failed = VoiceLabTakeRow(id: UUID(), index: 1, seed: 2, failure: .qa([.transcript]))
            phrases[index].takes = state == "none-passed" ? [Take(number: 1, row: failed)] : [Take(number: 1, row: passing), Take(number: 2, row: failed)]
            phrases[index].selectedID = state == "none-passed" ? nil : passing.id
            phrases[index].status = .ready
            if state == "generating" { phrases[index].status = .generating("Phrase \(index + 1) of \(phrases.count)…"); generating = true }
            if state == "cancelled" { phrases[index].status = .stopped("Take 2 stopped.") }
            if state == "none-passed" { phrases[index].status = .failed("These takes didn't sound right. Edit the words or try again.") }
        }
        if state == "provider-error" { problem = "ElevenLabs rejected the key (401). Your edits are saved." }
        if state == "cost-confirmation" { problem = "VoxClip can't tell what this costs. Check ElevenLabs' pricing." }
    }
    #endif

    func prepare() async {
        await prepareQuote(indices: phrases.map(\.id), decoding: true, candidates: VoiceLabPricing.maximumCandidates)
    }

    func prepareAnother(phrase index: Int) async {
        guard phrases.indices.contains(index), inputs.indices.contains(index) else { return }
        await prepareQuote(indices: [index], decoding: false, candidates: 1)
    }

    private func prepareQuote(indices: [Int], decoding: Bool, candidates: Int) async {
        guard !preparing, !generating, !publishing, !retired, operation == nil, let backend else { return }
        stopAudition()
        preparing = true; problem = ""; batch = nil; cost = nil; revision += 1
        let version = revision
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try checkCurrent(version)
                try validate(phrases.map(\.window))
                await backend.discard()
                try checkCurrent(version)
                if decoding {
                    var decoded: [VoiceLabTakeInput] = []
                    for phrase in phrases { decoded.append(try await makeInput(phrase)); try checkCurrent(version) }
                    guard decoded.map(\.window) == phrases.map(\.window), decoded.map(\.text) == phrases.map(\.text) else { throw Failure.stale }
                    inputs = decoded
                    nextSeeds = decoded.map { $0.seed &+ UInt32(candidates) }
                } else {
                    for index in indices {
                        let input = inputs[index]
                        inputs[index] = VoiceLabTakeInput(text: input.text, modelID: input.modelID, recordID: input.recordID,
                            language: input.language, seed: nextSeeds[index], contentKey: input.contentKey, source: input.source,
                            sourceEnvelope: input.sourceEnvelope, sourceSampleRate: input.sourceSampleRate, items: input.items,
                            cutWordIDs: input.cutWordIDs, window: input.window, incomingSilence: input.incomingSilence,
                            outgoingSilence: input.outgoingSilence, cleanAudioOn: input.cleanAudioOn, providerConsent: input.providerConsent)
                        nextSeeds[index] &+= UInt32(candidates)
                    }
                }
                try validate(inputs.map(\.window))
                let requested = indices.map { inputs[$0] }
                try VoiceLabTakeBatch.validate(requested)
                let quoted = try await backend.prepare(requested, indices, candidates)
                try checkCurrent(version)
                try await hold(quoted, indices: indices, version: version)
            } catch {
                await backend.discard()
                if revision == version { problem = Self.copy(error) }
            }
            if revision == version { preparing = false }
        }
        await operation?.value
        if revision == version { operation = nil }
    }

    private func hold(_ quoted: VoiceLabTakeBatch, indices: [Int], version: Int) async throws {
        let cap = try await readCap()
        try checkCurrent(version)
        batch = quoted; batchIndices = indices; progress = VoiceLabTakeBatchProgress(batch: quoted)
        estimate = quoted.estimate; cost = quoted.kind(cap: cap)
    }

    func start(approved: Bool) async {
        await start(approved: approved, quoteID: approvalID)
    }

    func start(approved: Bool, quoteID: UUID?) async {
        guard approved, !generating, !preparing, !publishing, !retired, operation == nil, let batch, let backend else { return }
        guard quoteID == batch.id else { return }
        stopAudition()
        generating = true; problem = ""; receivedInBatch = []
        let version = revision
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try checkCurrent(version)
                try validate(phrases.map(\.window))
                try await checkCap(batch.estimate, version: version)
                try await backend.approve(batch, batchIndices)
                for (offset, phrase) in batchIndices.enumerated() {
                    try checkCurrent(version)
                    runningPhrase = phrase
                    phrases[phrase].status = .generating("Phrase \(phrase + 1) of \(phrases.count)…")
                    let remaining = progress?.remainingEstimate ?? batch.estimate
                    try await checkCap(remaining, version: version)
                    let result = try await backend.execute(batch, offset, phrase) { [weak self] rows in
                        await self?.receive(rows, phrase: phrase, batch: batch, version: version)
                    }
                    await receive(result.rows, phrase: phrase, batch: batch, version: version)
                    try checkCurrent(version)
                    try progress?.finish(window: offset, result: result)
                    if result.end == .cancelled || result.end == .invalidated { throw CancellationError() }
                    if result.end == .fatal {
                        phrases[phrase].status = .failed(problem.isEmpty ? Self.failureCopy(result) : problem)
                        break
                    }
                    phrases[phrase].status = phrases[phrase].selected != nil ? .ready : .failed(problem.isEmpty ? Self.failureCopy(result) : problem)
                }
            } catch {
                if revision == version {
                    problem = Self.copy(error)
                    if let phrase = runningPhrase { phrases[phrase].status = .failed(problem) }
                }
            }
            await backend.discard()
            if revision == version { generating = false; runningPhrase = nil; self.batch = nil; cost = nil }
        }
        await operation?.value
        if revision == version { operation = nil }
    }

    func tryAnother(phrase: Int, approved: Bool) async {
        await tryAnother(phrase: phrase, approved: approved, quoteID: approvalID)
    }

    func tryAnother(phrase: Int, approved: Bool, quoteID: UUID?) async {
        guard batchIndices == [phrase], batch?.windows.count == 1 else { return }
        await start(approved: approved, quoteID: quoteID)
    }

    func stop() async {
        stopAudition()
        guard preparing || generating else { return }
        stopping = true; revision += 1; operation?.cancel()
        if let phrase = runningPhrase {
            let number = phrases[phrase].nextTakeNumber
            phrases[phrase].status = .stopped("Take \(number) stopped.")
        }
        await backend?.discard()
        await operation?.value
        operation = nil; generating = false; preparing = false; runningPhrase = nil; batch = nil; cost = nil
        stopping = false
    }

    func invalidate() {
        stopAudition()
        guard !retired else { return }
        retired = true; revision += 1; operation?.cancel(); batch = nil; cost = nil
        let backend = backend
        let operation = operation
        invalidation = Task { await backend?.invalidate(); await operation?.value }
    }

    @discardableResult func select(take: UUID, phrase: Int) -> Bool {
        guard !generating, !preparing, !publishing, !retired, isCurrent(), phrases.indices.contains(phrase),
              phrases[phrase].takes.contains(where: { $0.id == take && $0.row.selectable }) else { return false }
        stopAudition()
        phrases[phrase].selectedID = take
        return true
    }

    func stopAudition() {
        auditionTurn = UUID()
        audition.stop()
    }

    func play(phrase: Int) async {
        guard stillCurrent, !generating, !preparing, !publishing, phrases.indices.contains(phrase),
              let take = phrases[phrase].selected else { return }
        let wasPlaying = audition.isPlaying && audition.takeId == take.id
        stopAudition()
        guard !wasPlaying else { return }
        let turn = auditionTurn
        guard let audio = await scratch(take: take.id, phrase: phrase), turn == auditionTurn, stillCurrent,
              phrases[phrase].selectedID == take.id, !generating, !preparing, !publishing else { return }
        do { try audition.play(audio, takeId: take.id, selectionId: String(phrase)) }
        catch { problem = Self.copy(error) }
    }

    func dispatch(_ request: UUID, start: @escaping @Sendable () throws -> Void) async throws {
        let version = revision
        try checkCurrent(version)
        guard generating, let remaining = progress?.remainingEstimate(from: request) else { throw Failure.stale }
        do { try await checkCap(remaining, version: version) }
        catch {
            if revision == version { problem = Self.copy(error) }
            throw VoiceLabError.consentRequired
        }
        try start()
    }

    func scratch(take: UUID, phrase: Int) async -> VoiceLabTakeScratch? {
        guard stillCurrent, phrases.indices.contains(phrase), phrases[phrase].takes.contains(where: { $0.id == take && $0.row.selectable }) else { return nil }
        let scratch = await backend?.scratch(phrase, take)
        return stillCurrent ? scratch : nil
    }

    private func receive(_ rows: [VoiceLabTakeRow], phrase: Int, batch: VoiceLabTakeBatch, version: Int) async {
        for row in rows {
            let newIDs = row.acceptedRequestIDs.subtracting(sent)
            if !newIDs.isEmpty {
                charges.append(batch.estimate(of: newIDs)); sent.formUnion(newIDs)
                for take in batch.windows.flatMap(\.quote.takes) where newIDs.contains(take.synthesis.requestID) {
                    madeRequests.insert(take.synthesis.requestID)
                }
                spent = VoiceLabTakeRunQuote.total(of: charges, takes: madeRequests.count)
            }
            guard (revision == version || stopping), !retired, isCurrent() else {
                await backend?.retire(phrase, row.id)
                continue
            }
            guard receivedInBatch.insert(row.id).inserted else { continue }
            guard !phrases[phrase].takes.contains(where: { $0.id == row.id }) else { continue }
            if phrases[phrase].takes.count == 3 {
                let number = phrases[phrase].nextTakeNumber
                if let replaced = phrases[phrase].takes.firstIndex(where: { $0.number == number }) {
                    let evicted = phrases[phrase].takes[replaced].id
                    await backend?.retire(phrase, evicted)
                    guard (revision == version || stopping), !retired, isCurrent() else {
                        await backend?.retire(phrase, row.id)
                        continue
                    }
                    phrases[phrase].takes[replaced] = Take(number: number, row: row)
                }
            } else {
                phrases[phrase].takes.append(Take(number: phrases[phrase].takes.count + 1, row: row))
            }
        }
        guard (revision == version || stopping), !retired, isCurrent() else { return }
        let best = phrases[phrase].takes.filter { $0.row.selectable }.max { ($0.row.score ?? 0) < ($1.row.score ?? 0) }
        if let best { phrases[phrase].selectedID = best.id }
    }

    func acceptance(at date: Date = Date()) async throws -> Acceptance {
        stopAudition()
        let version = revision
        try checkCurrent(version)
        guard !generating, !preparing, !publishing, let backend else { throw Failure.stale }
        publishing = true
        defer { publishing = false }
        let selected = phrases.filter { $0.selected?.fits == true }
        guard !selected.isEmpty else { throw Failure.noSelection }
        let windows = try selected.map { phrase -> VoiceLabWindow in
            guard let fit = phrase.selected?.row.audio?.fit.plan else { throw Failure.noSelection }
            var window = phrase.window
            window.start = fit.windowStart; window.end = fit.windowEnd
            window.startSample = fit.windowStartSample; window.endSample = fit.windowEndSample
            return window
        }
        try validate(windows)
        var segments: [VoiceLabSegment] = [], assets: [VoiceLabAsset] = []
        var voice: VoiceLabVoiceReference?
        for phrase in selected {
            guard let row = phrase.selected?.row, row.fits, let fit = row.audio?.fit.plan else { throw Failure.noSelection }
            let (published, record) = try await backend.publish(phrase.id, row, inputs[phrase.id], date)
            try checkCurrent(version)
            let candidate = try VoiceLabRecipeBuilder.candidate(row: row, input: inputs[phrase.id], published: published,
                                                               record: record, createdAt: date, videoChoice: nil)
            segments.append(try VoiceLabRecipeBuilder.segment(id: UUID().uuidString.lowercased(), candidates: [candidate],
                selected: 0, input: inputs[phrase.id], plan: fit))
            for asset in published.assets {
                if let previous = assets.first(where: { $0.id == asset.id }) {
                    guard previous == asset else { throw VoiceLabProjectError.invalidAsset }
                } else { assets.append(asset) }
            }
            let reference = VoiceLabVoiceReference(id: record.id, provider: record.provider, voiceId: record.voiceId,
                consentRecordId: record.id, displayName: record.voiceName, status: .active)
            guard voice == nil || voice == reference else { throw Failure.stale }
            voice = reference
        }
        guard let voice else { throw Failure.noSelection }
        return Acceptance(segments: segments, assets: assets, voice: voice)
    }

    private func validate(_ windows: [VoiceLabWindow]) throws {
        try VoiceLabRenderContract.validatePlacement(project, scope: scope, windows: windows)
    }
    private func checkCurrent(_ version: Int) throws {
        try Task.checkCancellation()
        guard version == revision, !retired, isCurrent() else { throw Failure.stale }
    }
    private func checkCap(_ estimate: CostEstimate, version: Int) async throws {
        let cap = try await readCap()
        try checkCurrent(version)
        guard let cap else { return }
        guard let usd = estimate.usd else { throw Failure.unknownSpend }
        guard cap.spent + usd <= cap.limit else { throw Failure.spendingCap }
    }
    static func copy(_ error: any Error) -> String {
        switch error {
        case Failure.spendingCap: "Your ElevenLabs spending limit was reached. Finished takes are kept."
        case Failure.unknownSpend: "VoxClip can't check your ElevenLabs spending limit. Nothing more was sent."
        case Failure.budget: "These changes re-voice too many words. Leave a phrase out or re-record."
        case Failure.stale: "The rewrite changed. Make a fresh takes plan before sending anything."
        case Failure.noSelection: "Choose a take that fits before using takes."
        case Failure.placement(.geometry(let error)): RewriteSession.refusal(error)
        case Failure.placement(let reason): reason.copy ?? "These phrases cannot be voiced together. Edit the words or leave one out."
        case is CancellationError: "Stopped. Finished takes are kept."
        default: RewriteSession.refusal(error)
        }
    }
    private static func failureCopy(_ result: VoiceLabTakeRunResult) -> String {
        switch result.failure ?? result.rows.last?.failure {
        case .consent(let error): RewriteSession.refusal(error)
        case .provider(let error): RewriteSession.refusal(error)
        default: "These takes didn't sound right. Edit the words or try again."
        }
    }
}
