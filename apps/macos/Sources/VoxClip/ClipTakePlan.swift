import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

@MainActor private final class ClipTakeVoicePool {
    let session = VoiceLabVoiceCheckSession()
    var value = VoiceLabShortTakePool()
}

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
        /// Paid audio that failed before the checks: no checked mix, so it plays as the provider returned it.
        var notChecked: Bool { row.audio == nil && row.generated != nil }
        /// Every take with audio can be heard, checked or not.
        var playable: Bool { row.audio != nil || notChecked }
    }
    struct Phrase: Identifiable {
        let id: Int
        let indices: [Int]
        let text: String
        var audioTags: [VoiceLabAudioTag] = []
        let window: VoiceLabWindow
        var status: Status = .waiting
        var takes: [Take] = []
        var selectedID: UUID?
        var explicitlySelected = false
        var videoChoice: VoiceLabVideoMode?
        var estimatedVoicedSeconds: Double?
        var selected: Take? { takes.first { $0.id == selectedID } }
        var bestMeasured: Take? {
            takes.filter { $0.row.automaticallySelectable && $0.row.qa?.values.speakerScore?.isFinite == true }
                .max { ($0.row.score ?? 0) < ($1.row.score ?? 0) }
        }
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
    private struct PreparedVideoSelection {
        let choices: [UUID: VoiceLabVideoMode]
        let acceptance: Acceptance
        let render: PreparedVideoDurationRender
    }
    struct Backend {
        var prepare: @MainActor ([VoiceLabTakeInput], [Int], Int) async throws -> VoiceLabTakeBatch
        var approve: @MainActor (VoiceLabTakeBatch, [Int]) async throws -> Void
        var execute: @MainActor (VoiceLabTakeBatch, Int, Int, @escaping @Sendable ([VoiceLabTakeRow]) async -> Void) async throws -> VoiceLabTakeRunResult
        var finishVoice: @MainActor () async -> [UUID: VoiceLabTakeRow]
        var discard: @MainActor () async -> Void
        var invalidate: @MainActor () async -> Void
        var publish: @MainActor (Int, VoiceLabTakeRow, VoiceLabTakeInput, Date) async throws -> (VoiceLabPublishedTake, VoiceConsentRecord)
        var scratch: @MainActor (Int, UUID) async -> VoiceLabTakeScratch?
        /// The stored paid audio of a take with no checked mix (it failed before the checks).
        var paidAudio: @MainActor (Int, UUID) async -> URL?
        var retire: @MainActor (Int, UUID) async -> Void

        init(runs: [VoiceLabTakeRun]) {
            let pool = ClipTakeVoicePool()
            prepare = { inputs, indices, candidates in
                try await VoiceLabTakeBatchRun(runs: indices.map { runs[$0] }).prepare(inputs, candidates: candidates)
            }
            approve = { batch, indices in
                pool.value = VoiceLabShortTakePool(session: pool.session, retryPhrase: indices.count == 1 ? indices.first : nil)
                try await VoiceLabTakeBatchRun(runs: indices.map { runs[$0] }).approve(batch)
            }
            execute = { batch, index, phrase, progress in
                try await runs[phrase].execute(batch.windows[index].quote, approved: true, keepingPreviousTakes: true, shortTakePool: pool.value, phraseID: phrase, progress: progress)
            }
            finishVoice = { await pool.value.finish() }
            discard = { for run in runs { await run.cancel(keepingTakes: true) } }
            invalidate = {
                for run in runs { await run.invalidate() }
                await pool.session.reset()
            }
            publish = { phrase, row, input, date in try await runs[phrase].publishForAcceptance(row, input: input, at: date) }
            scratch = { phrase, take in await runs[phrase].scratch(for: take) }
            paidAudio = { phrase, take in await runs[phrase].paidAudioURL(for: take) }
            retire = { phrase, take in await runs[phrase].reject(take) }
        }
    }
    private(set) var phrases: [Phrase]
    private(set) var preparing = false
    private(set) var generating = false
    private(set) var publishing = false
    private(set) var preparingVideo = false
    private(set) var problem = ""
    private(set) var estimate: CostEstimate?
    private(set) var cost: VoiceLabCostPresentation.Kind?
    private(set) var spent = VoiceLabTakeRunQuote.total(of: [], takes: 0)
    let audition: VoiceLabAudition
    @ObservationIgnored private var auditionTurn = UUID()
    @ObservationIgnored private var receivedInBatch: Set<UUID> = []
    @ObservationIgnored private var fatalPhrases: Set<Int> = []
    @ObservationIgnored private(set) var invalidation: Task<Void, Never>?
    @ObservationIgnored private let project: Project
    @ObservationIgnored private let scope: VoiceLabOutputScope
    @ObservationIgnored private let makeInput: @MainActor (Phrase) async throws -> VoiceLabTakeInput
    @ObservationIgnored private let readCap: @MainActor () async throws -> VoiceLabMonthlyCap?
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var contextIsCurrent: @MainActor () -> Bool = { true }
    @ObservationIgnored private var validateContextInputs: @MainActor ([VoiceLabTakeInput]) throws -> Void = { _ in }
    @ObservationIgnored private let acceptedChargesChanged: @MainActor () async -> Void
    @ObservationIgnored private var backend: Backend?
    @ObservationIgnored var prepareDurationRender: VideoDurationRenderPreparer?
    @ObservationIgnored private var preparedVideoSelection: PreparedVideoSelection?
    @ObservationIgnored private(set) var videoPreparationFailure: (any Error)?
    @ObservationIgnored private var videoRevision = UUID()
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
    /// The speech model the plan's later quotes use, once `changeModel` replaced the one its inputs were decoded with.
    @ObservationIgnored private(set) var modelID: String?
    var stillCurrent: Bool { !retired && isCurrent() && contextIsCurrent() }
    var isRetired: Bool { retired }
    var approvalID: UUID? { batch?.id }
    static let minimumGeneratedSpeechSeconds = Double(SpeakerAudio.windowSize) / 16_000
    private var videoChoices: [UUID: VoiceLabVideoMode] {
        Dictionary(uniqueKeysWithValues: phrases.compactMap { phrase in
            guard let selected = phrase.selected, selected.row.selectable, let choice = phrase.videoChoice else { return nil }
            return (selected.id, choice)
        })
    }
    private var selectedPhrases: [Phrase] { phrases.filter { $0.selected?.row.selectable == true } }
    var canAccept: Bool {
        guard stillCurrent, !generating, !preparing, !publishing, !preparingVideo,
              !selectedPhrases.isEmpty, selectedPhrases.allSatisfy({ phrase in
                  phrase.selected?.row.requiresJoinAdvisoryAcceptance == false &&
                      phrase.videoChoice.map { videoAvailability(phrase: phrase.id).allows($0) } == true
              }) else { return false }
        return !selectedPhrases.contains(where: { $0.videoChoice == .retimed }) || preparedVideoSelection?.choices == videoChoices
    }
    /// The next step that keeps selected takes from being used (design.md, T3 footer), nil when nothing is selected or
    /// they can be used. "Left out until a take fits." belongs to a phrase none of whose takes passed, not to a missing
    /// duration choice.
    var acceptanceBlocker: String? {
        guard stillCurrent, !generating, !preparing, !publishing, !selectedPhrases.isEmpty, !canAccept else { return nil }
        let missing = selectedPhrases.filter { phrase in
            phrase.selected?.row.requiresJoinAdvisoryAcceptance == false &&
                phrase.videoChoice.map { videoAvailability(phrase: phrase.id).allows($0) } != true
        }.map { $0.id + 1 }
        if !missing.isEmpty { return "Choose the video duration for \(Self.phraseList(missing))." }
        if preparingVideo { return "Preparing the matched video…" }
        return problem.isEmpty ? nil : problem
    }
    /// "phrase 2", "phrases 2 and 4", "phrases 1, 2 and 4".
    static func phraseList(_ numbers: [Int]) -> String {
        let names = numbers.map(String.init)
        guard let last = names.last else { return "" }
        return names.count == 1 ? "phrase \(last)" : "phrases \(names.dropLast().joined(separator: ", ")) and \(last)"
    }

    func videoAvailability(phrase: Int) -> VideoDurationChoiceAvailability {
        let row = phrases.indices.contains(phrase) ? phrases[phrase].selected?.row : nil
        return VideoDurationChoiceAvailability(row: row, sourceSampleRate: project.media.source.audio?.sampleRate ?? 48_000,
            rendererReady: prepareDurationRender != nil && VoiceLabRenderInput.supportsVideoMode(.zoomCover))
    }

    @discardableResult func chooseVideo(_ choice: VoiceLabVideoMode, phrase: Int) -> Bool {
        guard stillCurrent, !generating, !preparing, !publishing, !preparingVideo, phrases.indices.contains(phrase),
              videoAvailability(phrase: phrase).allows(choice) else { return false }
        if phrases[phrase].videoChoice == choice { return true }
        clearPreparedVideo()
        phrases[phrase].videoChoice = choice
        return true
    }

    private func clearPreparedVideo() {
        videoRevision = UUID(); preparedVideoSelection = nil
        videoPreparationFailure = nil
    }

    func prepareVideoChoices(at date: Date = Date()) async {
        guard stillCurrent, !generating, !preparing, !publishing, !preparingVideo,
              !selectedPhrases.isEmpty, selectedPhrases.allSatisfy({ $0.videoChoice != nil }),
              selectedPhrases.contains(where: { $0.videoChoice == .retimed }) else { return }
        if preparedVideoSelection?.choices == videoChoices { return }
        let turn = videoRevision, choices = videoChoices
        preparingVideo = true
        defer { preparingVideo = false }
        do {
            let output = try await publishSelection(at: date)
            let proposed = try VoiceLabEditCommand.acceptAll(segments: output.segments, assets: output.assets, voice: output.voice)
                .applying(to: project, outputScope: scope)
            let render = try await VideoDurationRenderReadiness.prepare(proposed, scope: scope, using: prepareDurationRender)
            try Task.checkCancellation()
            guard stillCurrent, turn == videoRevision, choices == videoChoices else { throw Failure.stale }
            preparedVideoSelection = PreparedVideoSelection(choices: choices, acceptance: output, render: render)
            problem = ""
        } catch {
            if turn == videoRevision {
                preparedVideoSelection = nil; videoPreparationFailure = error; problem = Self.copy(error)
            }
        }
    }

    init(project: Project, scope: VoiceLabOutputScope, envelope: AudioEnvelope, hunks: [VoiceLabDiffHunk],
         makeInput: @escaping @MainActor (Phrase) async throws -> VoiceLabTakeInput,
         readCap: @escaping @MainActor () async throws -> VoiceLabMonthlyCap? = { nil },
         isCurrent: @escaping @MainActor () -> Bool = { true }, audition: VoiceLabAudition = VoiceLabAudition(),
         acceptedChargesChanged: @escaping @MainActor () async -> Void = {}) throws {
        var final = project
        for id in hunks.filter({ $0.kind == .cut }).flatMap(\.sourceWordIds) where !final.edits.cutWordIds.contains(id) {
            final.edits.cutWordIds.append(id)
        }
        self.project = final; self.scope = scope; self.makeInput = makeInput; self.readCap = readCap; self.isCurrent = isCurrent
        self.audition = audition
        self.acceptedChargesChanged = acceptedChargesChanged
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
                phrases.append(Phrase(id: phrases.count, indices: indices, text: words.joined(separator: " "),
                    audioTags: VoiceLabAudioTags.shifted(hunk.audioTags, by: window.leftBridgeWordIds.compactMap { texts[$0] }.flatMap { EditingPrimitives.splitWords($0) }.count), window: window))
            }
        }
        guard (1...VoiceLabTakeBatch.maximumWindows).contains(phrases.count) else { throw VoiceLabError.invalidInput }
        var final = project
        final.edits.cutWordIds += hunks.filter { $0.kind == .cut }.flatMap(\.sourceWordIds)
        try VoiceLabRenderContract.validatePlacement(final, scope: scope, windows: phrases.map(\.window))
        let estimates = try validateSpeechAvailability(phrases, project: final, scope: scope)
        for index in phrases.indices { phrases[index].estimatedVoicedSeconds = estimates[phrases[index].id] }
        return phrases
    }

    /// Advisory only: measured VAD output decides per-take versus pooled QA after synthesis.
    @discardableResult static func validateSpeechAvailability(_ phrases: [Phrase], project: Project,
                                                              scope: VoiceLabOutputScope) throws -> [Int: Double] {
        let rate = (try? VoiceLabLengthBudget.generatedRate(project: project).charactersPerSecond)
            ?? VoiceLabLengthBudget.providerRateFloor
        var estimates: [Int: Double] = [:]
        for phrase in phrases {
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: phrase.window)
            let meter = try VoiceLabFitMeter.measure(text: phrase.text, window: phrase.window, incomingSilence: silence.incoming,
                outgoingSilence: silence.outgoing, rate: max(rate, VoiceLabLengthBudget.providerRateFloor), newWords: phrase.text)
            let estimate = try VoiceLabLengthBudget.generatedVoicedSeconds(text: phrase.text, rate: rate)
            estimates[phrase.id] = min(estimate, meter.upperBoundSeconds * VoiceLabLengthBudget.generatedVoicedFraction)
        }
        return estimates
    }

    func connect(_ backend: Backend) { precondition(self.backend == nil); self.backend = backend }

    func bindSpeechContext(_ validateInputs: @escaping @MainActor ([VoiceLabTakeInput]) throws -> Void,
                           current: @escaping @MainActor () -> Bool) {
        validateContextInputs = validateInputs
        contextIsCurrent = current
    }

    func canExpandTimingShortPhrase(_ index: Int) -> Bool {
        guard phrases.indices.contains(index), inputs.indices.contains(index), let row = phrases[index].selected?.row else { return false }
        let options = VoiceLabVideoDurationOptions(row: row, sourceSampleRate: inputs[index].sourceSampleRate)
        return !options.allows(.source) && !options.allows(.retimed) && (options.retimeFactor ?? 0) > 1
    }

    func replaceSpeechContext(hunks: [VoiceLabDiffHunk], envelope: AudioEnvelope, phrase index: Int) async throws {
        guard stillCurrent, !preparing, !generating, !publishing, !preparingVideo, operation == nil,
              let backend, phrases.indices.contains(index),
              (phrases[index].selected == nil || phrases[index].selected?.row.voiceCheck.evidence?.mode == .unmeasured ||
                  canExpandTimingShortPhrase(index)),
              inputs.count == phrases.count, nextSeeds.count == phrases.count else { throw Failure.stale }
        let prepared = try Self.preparePlan(project: project, scope: scope, envelope: envelope, hunks: hunks)
        guard prepared.count == phrases.count,
              zip(prepared, phrases).allSatisfy({ fresh, old in
                  fresh.id == old.id && fresh.indices == old.indices && (old.id == index ||
                      (fresh.text.utf8.elementsEqual(old.text.utf8) && fresh.window == old.window))
              }) else { throw Failure.stale }
        stopAudition(); clearPreparedVideo()
        revision += 1; batch = nil; cost = nil; estimate = nil
        let version = revision
        preparing = true
        do {
            await backend.discard()
            try checkCurrent(version)
            let input = try await makeInput(prepared[index])
            try checkCurrent(version)
            guard input.text.utf8.elementsEqual(prepared[index].text.utf8), input.window == prepared[index].window else {
                throw Failure.stale
            }
            var updated = inputs
            updated[index] = input
            try validateContextInputs(updated)
            var windows = phrases.map { phrase in
                guard phrase.id != index, let fit = phrase.selected?.row.audio?.fit.plan else { return prepared[phrase.id].window }
                var window = phrase.window
                window.start = fit.windowStart; window.end = fit.windowEnd
                window.startSample = fit.windowStartSample; window.endSample = fit.windowEndSample
                return window
            }
            windows[index] = prepared[index].window
            try validate(windows)
            for take in phrases[index].takes {
                await backend.retire(index, take.id)
                try checkCurrent(version)
            }
            phrases[index] = prepared[index]
            inputs = updated; nextSeeds[index] = input.seed
            problem = ""; preparing = false
        } catch {
            preparing = false
            throw error
        }
        await prepareQuote(indices: [index], decoding: false, candidates: 1)
    }

    #if DEBUG
    func showFixture(_ state: String) {
        if ["ready", "none-passed", "length-changed", "cancelled", "generating"].contains(state) {
            let estimate = CostEstimate(provider: "elevenlabs", operation: "textToSpeech", units: Double(phrases.count), unit: "take",
                usd: Decimal(phrases.count) / 100, basis: "fixture")
            spent = VoiceLabTakeRunQuote.total(of: [estimate], takes: phrases.count)
        }
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
        await prepareQuote(indices: phrases.map(\.id), decoding: true, candidates: 1)
    }

    func prepareSpeechContext(phrase: Int) async {
        guard phrases.indices.contains(phrase) else { return }
        await prepareQuote(indices: [phrase], decoding: true, candidates: 1)
    }

    /// Moves the plan's later quotes to another speech model and keeps every take already made, paid or not. Each take
    /// keeps the model it was made with (its receipt), and the held quote, priced for the old model, is dropped, so the
    /// next Try another prices the new one. Refused while anything runs.
    func changeModel(_ id: String) -> Bool {
        guard !generating, !preparing, !publishing, !preparingVideo, !retired, operation == nil else { return false }
        stopAudition()
        inputs = inputs.map { input in
            let changed = input.replacingModel(id)
            return id == "eleven_v4" ? changed.replacingPace(1) : changed
        }
        modelID = id
        revision += 1; batch = nil; batchIndices = []; progress = nil; cost = nil; estimate = nil
        return true
    }
    /// The input a take was made from, on the model its receipt names.
    private func input(for row: VoiceLabTakeRow, phrase: Int) -> VoiceLabTakeInput {
        let input = inputs[phrase].replacingPace(row.receipt?.pace ?? row.quote?.synthesis.pace ?? 1)
        guard let model = row.receipt?.modelID, model != input.modelID else { return input }
        return input.replacingModel(model)
    }

    func prepareAnother(phrase index: Int) async {
        guard phrases.indices.contains(index), inputs.indices.contains(index) else { return }
        await prepareQuote(indices: [index], decoding: false, candidates: 1)
    }

    private func retryPace(phrase index: Int) throws -> Double? {
        let input = inputs[index]
        guard input.modelID != "eleven_v4" else { return 1 }
        guard let selected = phrases[index].selected, let audio = selected.row.audio,
              !VoiceLabVideoDurationOptions(row: selected.row, sourceSampleRate: input.sourceSampleRate).allows(.source),
              !audio.trimmed.isEmpty else { return input.pace }
        let measured = Double(audio.trimmed.count) / Double(audio.sampleRate)
        return try VoiceLabPaceMatching.match(seconds: measured, oldPace: selected.row.receipt?.pace ?? selected.row.quote?.synthesis.pace ?? 1,
            window: input.window, incomingSilence: input.incomingSilence, outgoingSilence: input.outgoingSilence,
            sourceSampleRate: input.sourceSampleRate, supportsPace: input.modelID != "eleven_v4").pace
    }

    func phrasePace(_ index: Int) -> Double? {
        guard inputs.indices.contains(index) else { return nil }
        if batch != nil, batchIndices.contains(index) { return inputs[index].pace }
        return try? retryPace(phrase: index)
    }

    private func prepareQuote(indices: [Int], decoding: Bool, candidates: Int) async {
        guard !preparing, !generating, !publishing, !preparingVideo, !retired, operation == nil, let backend else { return }
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
                    for phrase in phrases {
                        let input = try await makeInput(phrase)
                        decoded.append(modelID.map { input.replacingModel($0) } ?? input); try checkCurrent(version)
                    }
                    guard decoded.map(\.window) == phrases.map(\.window), decoded.map(\.text) == phrases.map(\.text), decoded.map(\.audioTags) == phrases.map(\.audioTags) else { throw Failure.stale }
                    inputs = decoded
                    nextSeeds = decoded.map { $0.seed &+ UInt32(candidates) }
                } else {
                    for index in indices {
                        let input = inputs[index]
                        let pace = try retryPace(phrase: index)
                        inputs[index] = VoiceLabTakeInput(text: input.text, modelID: input.modelID, recordID: input.recordID,
                            language: input.language, seed: nextSeeds[index], contentKey: input.contentKey, source: input.source,
                            sourceEnvelope: input.sourceEnvelope, sourceSampleRate: input.sourceSampleRate, items: input.items,
                            cutWordIDs: input.cutWordIDs, window: input.window, incomingSilence: input.incomingSilence,
                            outgoingSilence: input.outgoingSilence, cleanAudioOn: input.cleanAudioOn, providerConsent: input.providerConsent, pace: pace, audioTags: input.audioTags)
                        nextSeeds[index] &+= UInt32(candidates)
                    }
                }
                try validate(inputs.map(\.window))
                try validateContextInputs(inputs)
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
        guard approved, !generating, !preparing, !publishing, !preparingVideo, !retired, operation == nil, let batch, let backend else { return }
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
                try validateContextInputs(inputs)
                try await backend.approve(batch, batchIndices)
                for (offset, phrase) in batchIndices.enumerated() {
                    try checkCurrent(version)
                    runningPhrase = phrase
                    fatalPhrases.remove(phrase)
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
                        fatalPhrases.insert(phrase)
                        phrases[phrase].status = .failed(problem.isEmpty ? Self.failureCopy(result) : problem)
                        let failure = result.failure ?? result.rows.last?.failure
                        let reason: String
                        if failure == .provider(.invalidAlignment) {
                            let model: String
                            switch inputs[phrase].modelID {
                            case "eleven_v4": model = "Eleven v4"
                            case "eleven_v3": model = "Eleven v3"
                            default: model = "The speech model"
                            }
                            reason = "\(model) replies can't be checked yet."
                        } else { reason = problem.isEmpty ? Self.failureCopy(result) : problem }
                        for later in batchIndices.dropFirst(offset + 1) {
                            let unsent = phrases[later].takes.isEmpty ? "Nothing sent for this phrase." : "No new take sent for this phrase."
                            let next = failure == .provider(.invalidAlignment) ? " Try again after the timing issue is resolved." : ""
                            phrases[later].status = .stopped("Stopped: \(reason) \(unsent)\(next)")
                        }
                        break
                    }
                    if phrases[phrase].takes.contains(where: { $0.row.voiceCheck == .waiting }) {
                        phrases[phrase].status = .generating("waiting for the voice check")
                    } else {
                        phrases[phrase].status = phrases[phrase].selected != nil ? .ready : .failed(problem.isEmpty ? Self.failureCopy(result) : problem)
                    }
                }
            } catch {
                if revision == version {
                    problem = Self.copy(error)
                    if let phrase = runningPhrase {
                        fatalPhrases.insert(phrase)
                        phrases[phrase].status = .failed(problem)
                    }
                }
            }
            await finishVoiceChecks(batch: batch, version: version)
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
        if preparingVideo { clearPreparedVideo() }
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
        clearPreparedVideo()
        guard !retired else { return }
        retired = true; revision += 1; operation?.cancel(); batch = nil; cost = nil
        let backend = backend
        let operation = operation
        invalidation = Task { [weak self] in
            await backend?.invalidate()
            await operation?.value
            guard let self else { return }
            generating = false; preparing = false; runningPhrase = nil; self.operation = nil
        }
    }

    @discardableResult func select(take: UUID, phrase: Int) -> Bool {
        guard !generating, !preparing, !publishing, !preparingVideo, !retired, isCurrent(), phrases.indices.contains(phrase),
              phrases[phrase].takes.contains(where: { $0.id == take && $0.row.selectable && !$0.row.requiresJoinAdvisoryAcceptance }) else { return false }
        stopAudition()
        if phrases[phrase].selectedID != take {
            clearPreparedVideo()
            phrases[phrase].videoChoice = nil
        }
        phrases[phrase].selectedID = take
        phrases[phrase].explicitlySelected = true
        return true
    }

    @discardableResult func useAnyway(take: UUID, phrase: Int, at date: Date = Date()) -> Bool {
        guard !generating, !preparing, !publishing, !preparingVideo, !retired, isCurrent(), phrases.indices.contains(phrase),
              let index = phrases[phrase].takes.firstIndex(where: { $0.id == take }),
              let row = try? phrases[phrase].takes[index].row.acceptingJoinAdvisory(at: date) else { return false }
        phrases[phrase].takes[index] = Take(number: phrases[phrase].takes[index].number, row: row)
        return select(take: take, phrase: phrase)
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

    /// Plays one take's checked mix, failed or not, without selecting it: a failed take stays left out, but the user can
    /// hear what the checks refused. Toggles like `play(phrase:)`. A take that failed before the checks has no mix, so
    /// its paid audio plays as the provider returned it (`Phrase.Take.notChecked`).
    func play(take id: UUID, phrase: Int) async {
        guard stillCurrent, !generating, !preparing, !publishing, phrases.indices.contains(phrase),
              let take = phrases[phrase].takes.first(where: { $0.id == id }), take.playable else { return }
        if take.notChecked {
            let wasPlaying = audition.isPlaying && audition.takeId == id
            stopAudition()
            guard !wasPlaying else { return }
            let turn = auditionTurn
            guard let url = await backend?.paidAudio(phrase, id), turn == auditionTurn, stillCurrent,
                  phrases[phrase].takes.contains(where: { $0.id == id }), !generating, !preparing, !publishing else { return }
            do { try audition.play(paidAudio: url, takeId: id, selectionId: String(phrase)) }
            catch { problem = Self.copy(error) }
            return
        }
        let wasPlaying = audition.isPlaying && audition.takeId == id
        stopAudition()
        guard !wasPlaying else { return }
        let turn = auditionTurn
        guard let audio = await backend?.scratch(phrase, id), turn == auditionTurn, stillCurrent,
              phrases[phrase].takes.contains(where: { $0.id == id }), !generating, !preparing, !publishing else { return }
        do { try audition.play(audio, takeId: id, selectionId: String(phrase)) }
        catch { problem = Self.copy(error) }
    }

    func dispatch(_ request: UUID, start: @escaping @Sendable () throws -> Void) async throws {
        let version = revision
        try checkCurrent(version)
        try validateContextInputs(inputs)
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
                await acceptedChargesChanged()
            }
            guard (revision == version || stopping), !retired, isCurrent() else {
                await backend?.retire(phrase, row.id)
                continue
            }
            if let existing = phrases[phrase].takes.firstIndex(where: { $0.id == row.id }) {
                let number = phrases[phrase].takes[existing].number
                let previous = phrases[phrase].takes[existing].row
                let retained: VoiceLabTakeRow
                if let acceptance = previous.acceptedJoinAdvisory, row.qa?.joinSeams == acceptance.seams,
                   let accepted = try? row.acceptingJoinAdvisory(at: acceptance.acceptedAt) {
                    retained = accepted
                } else { retained = row }
                phrases[phrase].takes[existing] = Take(number: number, row: retained)
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
        if phrases[phrase].explicitlySelected {
            if let row = phrases[phrase].selected?.row, row.selectable, !row.requiresJoinAdvisoryAcceptance { return }
            phrases[phrase].explicitlySelected = false
        }
        let best = phrases[phrase].bestMeasured
        if best?.id != phrases[phrase].selectedID {
            clearPreparedVideo()
            phrases[phrase].videoChoice = nil
            phrases[phrase].selectedID = best?.id
        }
    }

    private func finishVoiceChecks(batch: VoiceLabTakeBatch, version: Int) async {
        guard let backend else { return }
        let checked = await backend.finishVoice()
        for phrase in phrases.indices {
            let rows = phrases[phrase].takes.compactMap { checked[$0.id] }
            if !rows.isEmpty { await receive(rows, phrase: phrase, batch: batch, version: version) }
            guard (revision == version || stopping), stillCurrent else { continue }
            guard !rows.isEmpty else { continue }
            // Preserve fatal/provider errors and Stop's specific message even after local checks drain.
            switch phrases[phrase].status {
            case .failed where fatalPhrases.contains(phrase): continue
            case .stopped: continue
            default: break
            }
            if !phrases[phrase].takes.contains(where: { $0.row.voiceCheck == .waiting }) {
                let available = phrases[phrase].takes.contains { $0.row.selectable }
                phrases[phrase].status = available ? .ready : .failed(Self.failureCopy(rows))
            }
        }
    }

    func acceptance(at date: Date = Date()) async throws -> Acceptance {
        stopAudition()
        guard stillCurrent else { invalidate(); throw Failure.stale }
        guard canAccept else { throw Failure.noSelection }
        if selectedPhrases.contains(where: { $0.videoChoice == .retimed }) {
            let turn = videoRevision, choices = videoChoices
            preparingVideo = true
            defer { preparingVideo = false }
            let output = try await publishSelection(at: date)
            let proposed = try VoiceLabEditCommand.acceptAll(segments: output.segments, assets: output.assets, voice: output.voice)
                .applying(to: project, outputScope: scope)
            let render = try await VideoDurationRenderReadiness.prepare(proposed, scope: scope, using: prepareDurationRender)
            try Task.checkCancellation()
            guard stillCurrent, turn == videoRevision, choices == videoChoices else { throw Failure.stale }
            preparedVideoSelection = PreparedVideoSelection(choices: choices, acceptance: output, render: render)
            return output
        }
        return try await publishSelection(at: date)
    }

    private func publishSelection(at date: Date) async throws -> Acceptance {
        stopAudition()
        let version = revision
        try checkCurrent(version)
        try validateContextInputs(inputs)
        guard !generating, !preparing, !publishing, let backend else { throw Failure.stale }
        publishing = true
        defer { publishing = false }
        let selected = selectedPhrases
        guard !selected.isEmpty, selected.allSatisfy({ phrase in
            phrase.videoChoice.map { videoAvailability(phrase: phrase.id).allows($0) } == true
        }) else { throw Failure.noSelection }
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
            guard let row = phrase.selected?.row, row.selectable, !row.requiresJoinAdvisoryAcceptance,
                  let fit = row.audio?.fit.plan else { throw Failure.noSelection }
            let made = input(for: row, phrase: phrase.id)
            let (published, record) = try await backend.publish(phrase.id, row, made, date)
            try checkCurrent(version)
            let candidate = try VoiceLabRecipeBuilder.candidate(row: row, input: made, published: published,
                                                               record: record, createdAt: date, videoChoice: phrase.videoChoice)
            segments.append(try VoiceLabRecipeBuilder.segment(id: UUID().uuidString.lowercased(), candidates: [candidate],
                selected: 0, input: made, plan: fit))
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
        guard version == revision, stillCurrent else { throw Failure.stale }
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
        case Failure.noSelection: "Choose a valid video duration for every selected passage before using takes."
        case is RewriteSpeechContextReview.Failure, is VoiceLabSpeechContextPlan.Failure:
            RewriteSpeechContextReview.copy(error)
        case Failure.placement(.geometry(let error)): RewriteSession.refusal(error)
        case Failure.placement(let reason): reason.copy ?? "These phrases cannot be voiced together. Edit the words or leave one out."
        case is CancellationError: "Stopped. Finished takes are kept."
        default: RewriteSession.refusal(error)
        }
    }
    private static func failureCopy(_ result: VoiceLabTakeRunResult) -> String {
        switch result.failure ?? result.rows.last?.failure {
        case .consent(let error): TakeFailurePresentation.reason(for: .consent(error))
        case .provider(let error): TakeFailurePresentation.reason(for: .provider(error))
        default: "These takes didn't sound right. Edit the words or try again."
        }
    }
    private static func failureCopy(_ rows: [VoiceLabTakeRow]) -> String {
        if let failure = rows.compactMap(\.failure).first(where: { failure in
            switch failure { case .consent, .provider: true; default: false }
        }) { return TakeFailurePresentation.reason(for: failure) }
        return "These takes didn't sound right. Edit the words or try again."
    }
}
