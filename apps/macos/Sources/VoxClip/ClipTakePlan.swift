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
        /// Where a take's audio came from: the cloned voice, or the user's own microphone (MicrophoneTake.swift).
        enum Source: Equatable { case clonedVoice, microphone }
        let number: Int
        let row: VoiceLabTakeRow
        var source: Source = .clonedVoice
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
        var text: String
        var audioTags: [VoiceLabAudioTag] = []
        let window: VoiceLabWindow
        var status: Status = .waiting
        var takes: [Take] = []
        var selectedID: UUID?
        var explicitlySelected = false
        /// Kept as recorded: the phrase's takes stay listed, none is used (automatic fixes' fallback or Keep original words).
        var leftOut = false
        /// Settled for this Rewrite: the use-time guard refused the phrase's speech (voice-lab §6.9), and no retry can
        /// change that. Nothing is priced or sent for it again; its row offers Say it myself and Keep as recorded, and Use
        /// keeps its original words. The value is the stop, said once.
        var blocked: String?
        /// Takes made before the phrase's expression changed, listed as "Before expression" and never chosen automatically.
        var beforeExpression: Set<UUID> = []
        var videoChoice: VoiceLabVideoMode?
        var estimatedVoicedSeconds: Double?
        /// The card's segment (PhraseOwnWords.swift): Suggested, My words or Say it myself. Switching keeps every take.
        var wording: PhraseWording = .suggested
        /// The user's own words for the phrase's change, between its bridge words; nil until My words is first chosen.
        var ownWords: String?
        var selected: Take? { takes.first { $0.id == selectedID } }
        var originalLength: Double { window.end - window.start }
        var lengthDifference: Double? { selected?.length.map { $0 - originalLength } }
        var nextTakeNumber: Int {
            guard takes.count == 3 else { return takes.count + 1 }
            return takes.filter { $0.id != selectedID }.min { ($0.row.score ?? -1) < ($1.row.score ?? -1) }?.number ?? 3
        }
    }
    enum Failure: Error, Equatable {
        /// `index` is the refused hunk's index in the plan's hunks.
        case placement(VoiceLabWindowRefusal, index: Int), spendingCap, unknownSpend, stale, noSelection
        /// The reviewed changes place no phrase to voice.
        case nothingToVoice
        /// More phrases than one run voices (`maximumPhrases`); `count` is how many the changes placed.
        case tooManyPhrases(count: Int)
        /// A later part of an approved run was quoted again just before it ran and no longer matched what was priced.
        case priceChanged
        /// These phrases' takes can't go into the video (their render recipe or the project refuses them); Use keeps
        /// them as recorded and goes on with the rest (`RewriteSession.acceptTakes`).
        case unusable(phrases: [Int])
    }
    /// The most phrases one run prices and voices. A run of more than `VoiceLabTakeBatch.maximumWindows` phrases is priced
    /// and approved once, then voiced part by part (`PricedPart`).
    nonisolated static let maximumPhrases = VoiceLabTakeBatch.maximumRunPhrases
    /// A later part of a priced run: its phrases and the batch they were priced as. Only the run's first part holds its
    /// quotes until the approval (`ElevenLabsVoiceLab` keeps at most 32 outstanding quotes); each later part is quoted
    /// again just before it runs, and runs under the run's one approval only when that quote equals this one's inputs
    /// and estimate.
    private struct PricedPart {
        let indices: [Int]
        let priced: VoiceLabTakeBatch
    }
    struct Acceptance {
        let segments: [VoiceLabSegment]
        let assets: [VoiceLabAsset]
        /// nil when every selected take is the user's own microphone take, which uses no clone.
        let voice: VoiceLabVoiceReference?
        var videoAssets: [VoiceLabVideoAsset] = []
        /// The phrase of each segment, in order, so a segment that can't go into the video names its phrase.
        var phraseIDs: [Int] = []
        /// These segments alone, with only the assets they use.
        func only(_ indices: [Int]) -> Acceptance {
            let kept = indices.filter(segments.indices.contains)
            let picked = kept.map { segments[$0] }
            let encoder = JSONEncoder()
            let text = String(decoding: (try? encoder.encode(picked)) ?? Data(), as: UTF8.self)
            func uses(_ id: String) -> Bool { text.contains("\"" + id + "\"") }
            var result = Acceptance(segments: picked, assets: assets.filter { uses($0.id) }, voice: voice,
                                    videoAssets: videoAssets.filter { uses($0.id) })
            result.phraseIDs = kept.compactMap { phraseIDs.indices.contains($0) ? phraseIDs[$0] : nil }
            return result
        }
    }
    private struct PreparedVideoSelection {
        let choices: [UUID: VoiceLabVideoMode]
        let acceptance: Acceptance
        let render: PreparedVideoDurationRender
    }
    struct Backend {
        var prepare: @MainActor ([VoiceLabTakeInput], [Int], Int) async throws -> VoiceLabTakeBatch
        /// The Bool is true for a later part of an approved run: the run's short-take pool carries on.
        var approve: @MainActor (VoiceLabTakeBatch, [Int], Bool) async throws -> Void
        var execute: @MainActor (VoiceLabTakeBatch, Int, Int, @escaping @Sendable ([VoiceLabTakeRow]) async -> Void) async throws -> VoiceLabTakeRunResult
        var finishVoice: @MainActor () async -> [UUID: VoiceLabTakeRow]
        var discard: @MainActor () async -> Void
        /// Drops the unsent quotes of these phrases' runs and keeps their takes: a priced later part of a run.
        var release: @MainActor ([Int]) async -> Void
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
            approve = { batch, indices, continuing in
                if !continuing {
                    pool.value = VoiceLabShortTakePool(session: pool.session, retryPhrase: indices.count == 1 ? indices.first : nil)
                }
                try await VoiceLabTakeBatchRun(runs: indices.map { runs[$0] }).approve(batch)
            }
            execute = { batch, index, phrase, progress in
                try await runs[phrase].execute(batch.windows[index].quote, approved: true, keepingPreviousTakes: true, shortTakePool: pool.value, phraseID: phrase, progress: progress)
            }
            finishVoice = { await pool.value.finish() }
            discard = { for run in runs { await run.cancel(keepingTakes: true) } }
            release = { indices in for index in indices { await runs[index].cancel(keepingTakes: true) } }
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
    /// The take panel's problem line; `failure` is the error behind it, for its next steps (RewriteNextSteps.swift).
    private(set) var problem = "" { didSet { if problem.isEmpty { failure = nil } } }
    private(set) var failure: (any Error)?
    private func report(_ error: any Error) {
        problem = Self.copy(error); failure = error
        if !problem.isEmpty { onFailure?(error) }
    }
    /// Each failure the plan reports, for the Rewrite's release log line (`RewriteSession.logFailure`).
    @ObservationIgnored var onFailure: (@MainActor (any Error) -> Void)?
    /// Phrases kept as recorded because their takes can't go into the video (`Failure.unusable`), for the session's line.
    @ObservationIgnored var onUnusable: (@MainActor ([Int]) -> Void)?
    #if DEBUG
    /// What publishing returns for a phrase, changed (the Rewrite smoke's S-render-recipe: a take whose recipe can't be made).
    @ObservationIgnored var publishOverride: ((Int, VoiceLabPublishedTake) -> VoiceLabPublishedTake)?
    #endif
    private(set) var estimate: CostEstimate?
    private(set) var cost: VoiceLabCostPresentation.Kind?
    private(set) var spent = VoiceLabTakeRunQuote.total(of: [], takes: 0)
    let audition: VoiceLabAudition
    let lipsync = RewriteLipsyncSession()
    /// Automatic fixes and expression changes add takes beside the old ones: a fourth take never replaces a paid one.
    var keepsEveryTake = false
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
    @ObservationIgnored private(set) var inputs: [VoiceLabTakeInput] = []
    @ObservationIgnored private var takeInputs: [UUID: VoiceLabTakeInput] = [:]
    /// The user's own microphone takes, by take ID: kept on this Mac, published at Use (MicrophoneTake.swift).
    @ObservationIgnored private var microphoneTakes: [UUID: MicrophoneTake] = [:]
    /// Where microphone takes are written: the project's Voice Lab folders, as for paid takes.
    @ObservationIgnored var microphoneStorage: VoiceLabTakeStorage?
    @ObservationIgnored var onMeasuredTakesChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var nextSeeds: [UInt32] = []
    /// The held quote: a run's first part until the approval, then the part that runs. Dropping it drops the later parts.
    @ObservationIgnored private var batch: VoiceLabTakeBatch? { didSet { if batch == nil { laterParts = [] } } }
    @ObservationIgnored private var batchIndices: [Int] = []
    /// The priced parts of the held run after `batch`, in source order (`PricedPart`).
    @ObservationIgnored private var laterParts: [PricedPart] = []
    /// Every phrase the held run prices: `batch`'s and its later parts'.
    private var runIndices: [Int] { batchIndices + laterParts.flatMap(\.indices) }
    /// What the later parts of the held run add to `batch`'s estimate.
    private var laterEstimates: [CostEstimate] { laterParts.map(\.priced.estimate) }
    /// "Pricing phrase 12 of 34…" while a price is prepared, nil otherwise.
    private(set) var preparationStep: String?
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
        return !selectedPhrases.contains(where: { $0.videoChoice == .retimed || $0.videoChoice == .cut }) || preparedVideoSelection?.choices == videoChoices
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
    nonisolated static func phraseList(_ numbers: [Int]) -> String {
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
        guard !lipsync.blocksMutation(phrase) else { return false }
        clearPreparedVideo()
        phrases[phrase].videoChoice = choice
        return true
    }

    /// [Prepare Video Again]: forgets the failed attempt so the same choices are prepared once more.
    func retryVideoPreparation() {
        guard !preparingVideo, videoPreparationFailure != nil else { return }
        videoPreparationFailure = nil; problem = ""
    }

    private func clearPreparedVideo() {
        videoRevision = UUID(); preparedVideoSelection = nil
        videoPreparationFailure = nil
    }

    /// Every selected phrase has a duration, one of them cuts or matches the video, and that video is neither prepared
    /// for these choices nor failed for them: Use waits for `prepareVideoChoices`.
    var needsVideoPreparation: Bool {
        !selectedPhrases.isEmpty && selectedPhrases.allSatisfy({ $0.videoChoice != nil })
            && selectedPhrases.contains(where: { $0.videoChoice == .retimed || $0.videoChoice == .cut })
            && preparedVideoSelection?.choices != videoChoices && videoPreparationFailure == nil
    }

    /// Prepares the cut or matched video of the selected takes. A selection that changes while it runs (another phrase's
    /// take or duration) makes that attempt stale; the newest choices are prepared next, so Use never waits on a
    /// preparation nobody runs.
    func prepareVideoChoices(at date: Date = Date()) async {
        // One preparation at a time: a caller arriving while one runs waits for it (then prepares newer choices, if
        // any) instead of returning early, so "prepare, then refresh lip sync" and Use never act on half-prepared video.
        while let running = videoPreparation {
            await running.value
            if videoPreparation == running { videoPreparation = nil }
        }
        guard needsVideoPreparation else { return }
        let task = Task { await runVideoPreparation(at: date) }
        videoPreparation = task
        await task.value
        if videoPreparation == task { videoPreparation = nil }
    }
    private var videoPreparation: Task<Void, Never>?

    private func runVideoPreparation(at date: Date) async {
        var attempted = false
        while stillCurrent, !generating, !preparing, !publishing, !preparingVideo, needsVideoPreparation, !Task.isCancelled {
            let turn = videoRevision, choices = videoChoices
            preparingVideo = true; attempted = true
            do {
                let output = try await publishSelection(at: date)
                let proposed = try VoiceLabEditCommand.acceptAll(segments: output.segments, assets: output.assets, voice: output.voice)
                    .applying(to: project, outputScope: scope)
                let render = try await VideoDurationRenderReadiness.prepare(proposed, scope: scope, using: prepareDurationRender)
                try Task.checkCancellation()
                guard stillCurrent, turn == videoRevision, choices == videoChoices else { throw Failure.stale }
                preparedVideoSelection = PreparedVideoSelection(choices: choices, acceptance: output, render: render)
                problem = ""
            } catch Failure.unusable(let phrases) where turn == videoRevision {
                // A take that can't go into the video keeps its phrase as recorded here as at Use (MVP32 Clip 7), and
                // the other phrases' video is prepared next.
                preparingVideo = false
                for phrase in phrases { leaveOut(phrase: phrase) }
                onUnusable?(phrases)
                continue
            } catch {
                if turn == videoRevision {
                    preparedVideoSelection = nil; videoPreparationFailure = error; report(error)
                }
            }
            preparingVideo = false
        }
        // A duration the session chose while this ran was refused; it is chosen now.
        if attempted { onMeasuredTakesChanged?() }
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
        // The patch budget is advisory (voice-lab.md §8.2): the Rewrite panel advises and the user chooses before a plan.
        let placed = VoiceLabWindowPlanner.placeAll(project: project, scope: scope, envelope: envelope, hunks: hunks)
        let texts = Dictionary(RewriteSession.corrected(project).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var phrases: [Phrase] = []
        for result in placed {
            switch result {
            case .refused(let index, _, let reason): throw Failure.placement(reason, index: index)
            case .placed(let indices, let hunk, let window):
                let words = window.leftBridgeWordIds.compactMap { texts[$0] } + hunk.newTokens + window.rightBridgeWordIds.compactMap { texts[$0] }
                phrases.append(Phrase(id: phrases.count, indices: indices, text: words.joined(separator: " "),
                    audioTags: VoiceLabAudioTags.shifted(hunk.audioTags, by: window.leftBridgeWordIds.compactMap { texts[$0] }.flatMap { EditingPrimitives.splitWords($0) }.count), window: window))
            }
        }
        guard !phrases.isEmpty else { throw Failure.nothingToVoice }
        guard phrases.count <= maximumPhrases else { throw Failure.tooManyPhrases(count: phrases.count) }
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
        if ["ready", "none-passed", "length-changed", "cancelled", "generating", "guard-blocked"].contains(state) {
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
        // The use-time guard blocked the last phrase, or every phrase: no take was made for it (RewriteSettledPhrases.swift).
        if state == "guard-blocked" || state == "guard-all-blocked" {
            let blocked = state == "guard-all-blocked" ? Array(phrases.indices) : Array(phrases.indices.suffix(1))
            for index in blocked {
                phrases[index].takes = []
                block(phrase: index, reason: Self.blockedCopy(.consent(.voiceOwnerMismatch)))
            }
        }
        // A price that failed reading the source (the log's rangeOutsideMedia): nothing was made or sent.
        if state == "range-outside-media" {
            for index in phrases.indices { phrases[index].takes = []; phrases[index].selectedID = nil; phrases[index].status = .waiting }
            report(VoiceLabSourceAudioError.rangeOutsideMedia)
        }
        if state == "provider-error" { problem = "ElevenLabs rejected the key (401). Your edits are saved." }
        if state == "cost-confirmation" { problem = "VoxClip can't tell what this costs. Check ElevenLabs' pricing." }
    }
    #endif

    func prepare() async {
        await prepareQuote(indices: voiceableIndices, decoding: true, candidates: 1)
    }
    /// The phrases a price and a run cover: every phrase not settled as blocked.
    var voiceableIndices: [Int] { phrases.filter { $0.blocked == nil }.map(\.id) }
    /// Every phrase is blocked or kept as recorded, with at least one blocked: nothing is left to price.
    var settledWithBlocks: Bool {
        phrases.contains { $0.blocked != nil } && phrases.allSatisfy { $0.blocked != nil || $0.leftOut }
    }
    /// Settles phrase `index` for this Rewrite (`Phrase.blocked`): its stop is said once and nothing is priced for it again.
    func block(phrase index: Int, reason: String) {
        guard phrases.indices.contains(index) else { return }
        stopAudition()
        phrases[index].blocked = reason
        phrases[index].status = .failed(reason)
        phrases[index].selectedID = nil; phrases[index].videoChoice = nil; phrases[index].explicitlySelected = false
    }
    /// Each phrase the guard settles while takes run, for the session to keep it settled in a later plan of this Rewrite.
    @ObservationIgnored var onBlocked: (@MainActor (Int, String) -> Void)?

    func prepareSpeechContext(phrase: Int) async {
        guard phrases.indices.contains(phrase), phrases[phrase].blocked == nil else { return }
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
        let input = (takeInputs[row.id] ?? inputs[phrase]).replacingPace(row.receipt?.pace ?? row.quote?.synthesis.pace ?? 1)
        guard let model = row.receipt?.modelID, model != input.modelID else { return input }
        return input.replacingModel(model)
    }
    func measuredInput(take: UUID) -> VoiceLabTakeInput? { takeInputs[take] }

    func prepareAnother(phrase index: Int) async {
        guard phrases.indices.contains(index), inputs.indices.contains(index), phrases[index].blocked == nil else { return }
        await prepareQuote(indices: [index], decoding: false, candidates: 1)
    }

    /// The words a rewording of this phrase must begin and end with (voice-lab §8.4), as its take input spells them; nil
    /// when its window has none or before the plan decoded its inputs.
    func bridge(phrase index: Int) -> VoiceLabFitBridge? {
        guard inputs.indices.contains(index) else { return nil }
        return (try? VoiceLabFitBridge(input: inputs[index])).flatMap { $0 }
    }

    /// Puts a new wording on one phrase and prices a take of it. A wording without the phrase's bridge words can't be
    /// placed or priced: it is refused, and the phrase keeps its words (false).
    @discardableResult func prepareRewording(_ text: String, phrase index: Int) async -> Bool {
        guard stillCurrent, phrases.indices.contains(index), phrases[index].blocked == nil, !generating, !preparing, !publishing, !preparingVideo else { return false }
        if let bridge = bridge(phrase: index), !bridge.keeps(text) { return false }
        phrases[index].audioTags = VoiceLabAudioTags.reanchored(phrases[index].audioTags, from: phrases[index].text, to: text)
        phrases[index].text = text
        clearPreparedVideo()
        await prepareQuote(indices: [index], decoding: true, candidates: 1)
        return true
    }

    func keepSelectedWording(phrase index: Int) {
        guard !generating, !preparing, !publishing, phrases.indices.contains(index),
              let selected = phrases[index].selected, let input = takeInputs[selected.id] else { return }
        phrases[index].text = input.text; phrases[index].audioTags = input.audioTags
        inputs[index] = input
        revision += 1; batch = nil; batchIndices = []; cost = nil; estimate = nil
        clearPreparedVideo()
    }

    /// Keeps the phrase as recorded: no take is used for it, and every take stays listed (design.md R2 "Automatic fixes").
    func leaveOut(phrase index: Int) {
        guard phrases.indices.contains(index), !lipsync.blocksMutation(index) else { return }
        stopAudition(); clearPreparedVideo()
        phrases[index].leftOut = true; phrases[index].selectedID = nil; phrases[index].videoChoice = nil
        phrases[index].explicitlySelected = false
    }
    /// Undo of `leaveOut`: the best passing take is chosen again, if there is one.
    func restore(phrase index: Int) {
        guard phrases.indices.contains(index), phrases[index].leftOut else { return }
        phrases[index].leftOut = false
        phrases[index].selectedID = chooseAutomatically(phrase: index)
        onMeasuredTakesChanged?()
    }
    /// A new expression for one phrase (design.md R2 "Expressions"): only this phrase's text tags change, its takes so far
    /// stay listed as "Before expression", and a fresh quote is prepared for it alone. Other phrases keep their takes.
    func prepareExpression(_ tags: [VoiceLabAudioTag], phrase index: Int) async {
        guard stillCurrent, phrases.indices.contains(index), !generating, !preparing, !publishing, !preparingVideo,
              !lipsync.blocksMutation(index) else { return }
        stopAudition()
        phrases[index].audioTags = tags
        phrases[index].beforeExpression.formUnion(phrases[index].takes.map(\.id))
        if phrases[index].selectedID != nil { clearPreparedVideo() }
        phrases[index].selectedID = nil; phrases[index].videoChoice = nil; phrases[index].explicitlySelected = false
        keepsEveryTake = true
        await prepareQuote(indices: spent.units > 0 ? [index] : phrases.map(\.id), decoding: true, candidates: 1)
    }
    /// Whether a take's own length fits its slot with the source video or a cut, selected or not: a take that failed its
    /// checks still says whether its length fits.
    func lengthFits(take: Take) -> Bool {
        let options = VoiceLabVideoDurationOptions(fit: take.row.audio?.fit, sourceSampleRate: project.media.source.audio?.sampleRate ?? 48_000,
            assetSampleRate: take.row.audio?.sampleRate ?? 0)
        return options.allows(.source) || (prepareDurationRender != nil && options.allows(.cut))
    }
    /// Whether some video duration (keep source, cut or match) can carry this take, selected or not.
    func durationAvailable(take: Take) -> Bool {
        let availability = VideoDurationChoiceAvailability(row: take.row.selectable ? take.row : nil,
            sourceSampleRate: project.media.source.audio?.sampleRate ?? 48_000,
            rendererReady: prepareDurationRender != nil && VoiceLabRenderInput.supportsVideoMode(.zoomCover))
        return [VoiceLabVideoMode.source, .cut, .retimed].contains(where: availability.allows)
    }
    /// The order passing takes are offered in (design.md R2): one a video duration can carry first, then the one
    /// closest to the slot, then the better voice score.
    private func ranked(_ takes: [Take], phrase index: Int) -> [Take] {
        let slot = phrases[index].originalLength
        let keyed = takes.map { take -> (take: Take, usable: Bool, distance: Double, score: Double) in
            (take, durationAvailable(take: take), take.length.map { abs($0 - slot) } ?? .infinity, take.row.score ?? 0)
        }
        return keyed.sorted { left, right in
            if left.usable != right.usable { return left.usable }
            if left.usable { return left.score != right.score ? left.score > right.score : left.distance < right.distance }
            return left.distance != right.distance ? left.distance < right.distance : left.score > right.score
        }.map(\.take)
    }
    /// The take chosen automatically (ADR-R37, ADR-R39): only measured passing takes, never one made before the expression
    /// changed. Among usable takes the best score wins, as before; when no duration can carry any of them, the one closest
    /// to the slot, so the automatic fixes reword from the nearest take. A take whose only issue is a join advisory is
    /// chosen when it ranks best, after any clean take at the same rank (ADR-R39: Claude makes the best decision, the user
    /// only listens).
    func automaticTake(phrase index: Int) -> Take? {
        guard phrases.indices.contains(index) else { return nil }
        let phrase = phrases[index]
        let measured = phrase.takes.filter {
            $0.row.selectable && $0.row.qa?.values.speakerScore?.isFinite == true && !phrase.beforeExpression.contains($0.id)
                && (!$0.row.requiresJoinAdvisoryAcceptance || (try? $0.row.acceptingJoinAdvisory(at: Date())) != nil)
        }
        let order = ranked(measured, phrase: index)
        let usable = order.filter { durationAvailable(take: $0) }
        let pool = usable.isEmpty ? order : usable
        return pool.first { !$0.row.hasJoinAdvisory } ?? pool.first
    }
    /// Makes the automatic choice for a phrase: its advisory, if any, is accepted now, as the user's click once did.
    private func chooseAutomatically(phrase index: Int, at date: Date = Date()) -> UUID? {
        guard let best = automaticTake(phrase: index) else { return nil }
        if best.row.requiresJoinAdvisoryAcceptance {
            guard let slot = phrases[index].takes.firstIndex(where: { $0.id == best.id }),
                  let accepted = try? best.row.acceptingJoinAdvisory(at: date) else { return nil }
            phrases[index].takes[slot] = Take(number: best.number, row: accepted, source: best.source)
        }
        return best.id
    }
    /// The passing take a phrase with none chosen offers for the user's one click ([Choose Take N] in the footer): a take
    /// the automatic choice may not pick, such as one whose voice couldn't be measured (ADR-R37: it needs the user's
    /// explicit click). Choosing a take with a join advisory accepts it (ADR-R39).
    func offeredTake(phrase index: Int) -> Take? {
        guard phrases.indices.contains(index), !phrases[index].leftOut, phrases[index].selected == nil else { return nil }
        let phrase = phrases[index]
        let passing = phrase.takes.filter { $0.row.selectable }
        let current = passing.filter { !phrase.beforeExpression.contains($0.id) }
        return ranked(current.isEmpty ? passing : current, phrase: index).first
    }
    /// The duration choices the selected take allows, in the panel's order.
    func validVideoChoices(phrase index: Int) -> [VoiceLabVideoMode] {
        guard phrases.indices.contains(index), phrases[index].selected?.row.selectable == true else { return [] }
        let availability = videoAvailability(phrase: index)
        return [VoiceLabVideoMode.source, .cut, .retimed].filter(availability.allows)
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
            sourceSampleRate: input.sourceSampleRate, supportsPace: input.modelID != "eleven_v4", hardJoinSmoothing: true,
            sourceItems: input.items, sourceEnvelope: input.sourceEnvelope, generatedText: input.text, pauseProfile: input.pauseProfile,
            audioTags: VoiceLabAudioTags.recorded(input.audioTags, modelID: input.modelID) ?? []).pace
    }

    func phrasePace(_ index: Int) -> Double? {
        guard inputs.indices.contains(index) else { return nil }
        if batch != nil, runIndices.contains(index) { return inputs[index].pace }
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
                        if phrases.count > 1 { preparationStep = "Reading phrase \(phrase.id + 1) of \(phrases.count)…" }
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
                            outgoingSilence: input.outgoingSilence, cleanAudioOn: input.cleanAudioOn, providerConsent: input.providerConsent, pace: pace,
                            hardJoinSmoothing: input.hardJoinSmoothing, audioTags: input.audioTags)
                        nextSeeds[index] &+= UInt32(candidates)
                        inputs[index].pauseProfile = input.pauseProfile
                    }
                }
                try validate(inputs.map(\.window))
                try validateContextInputs(inputs)
                // Every phrase settled as blocked: the inputs serve Say it myself, and there is nothing to price.
                if indices.isEmpty {
                    if revision == version { preparing = false; preparationStep = nil }
                    return
                }
                try Self.validateRun(indices.map { inputs[$0] })
                // A run of more than one batch is priced part by part. The later parts are priced first and release their
                // quotes, so the first part, which holds its quotes until the approval, is quoted last and freshest.
                let parts = Self.parts(indices)
                var later: [PricedPart] = []
                for part in parts.dropFirst() {
                    preparationStep = "Pricing phrases \(part[0] + 1)–\(part[part.count - 1] + 1) of \(phrases.count)…"
                    let priced = try await backend.prepare(part.map { inputs[$0] }, part, candidates)
                    await backend.release(part)
                    try checkCurrent(version)
                    later.append(PricedPart(indices: part, priced: priced))
                }
                if parts.count > 1 { preparationStep = "Pricing phrases \(parts[0][0] + 1)–\(parts[0][parts[0].count - 1] + 1) of \(phrases.count)…" }
                let quoted = try await backend.prepare(parts[0].map { inputs[$0] }, parts[0], candidates)
                try checkCurrent(version)
                try await hold(quoted, indices: parts[0], later: later, version: version)
            } catch {
                await backend.discard()
                if revision == version { report(error) }
            }
            if revision == version { preparing = false; preparationStep = nil }
        }
        await operation?.value
        if revision == version { operation = nil }
        onMeasuredTakesChanged?()
    }

    private func hold(_ quoted: VoiceLabTakeBatch, indices: [Int], later: [PricedPart], version: Int) async throws {
        let cap = try await readCap()
        try checkCurrent(version)
        batch = quoted; batchIndices = indices; progress = VoiceLabTakeBatchProgress(batch: quoted)
        laterParts = later
        let total = Self.sum([quoted.estimate] + laterEstimates)
        estimate = total
        cost = VoiceLabCostPresentation.kind(total, isLipSync: false, providerName: VoiceLabTakeBatch.providerName, cap: cap)
    }

    /// Consecutive parts of at most `VoiceLabTakeBatch.maximumWindows` phrases, in source order.
    static func parts(_ indices: [Int]) -> [[Int]] {
        stride(from: 0, to: indices.count, by: VoiceLabTakeBatch.maximumWindows).map {
            Array(indices[$0..<min($0 + VoiceLabTakeBatch.maximumWindows, indices.count)])
        }
    }
    /// `VoiceLabTakeBatch.validate(_:)` over a whole run: one voice record, language, model and source, in source order with
    /// a gap between neighbours. Each neighbouring pair is a batch of two, so the rules hold across the parts' seams too.
    static func validateRun(_ inputs: [VoiceLabTakeInput]) throws {
        guard !inputs.isEmpty, inputs.count <= maximumPhrases else { throw VoiceLabError.invalidInput }
        try VoiceLabTakeBatch.validate([inputs[0]])
        for index in inputs.indices.dropFirst() { try VoiceLabTakeBatch.validate([inputs[index - 1], inputs[index]]) }
    }
    /// The summed take-run estimate: unknown when any part's is.
    static func sum(_ estimates: [CostEstimate]) -> CostEstimate {
        VoiceLabTakeRunQuote.total(of: estimates, takes: Int(estimates.reduce(0) { $0 + $1.units }))
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
                try await checkCap(Self.sum([batch.estimate] + laterEstimates), version: version)
                try validateContextInputs(inputs)
                try await backend.approve(batch, batchIndices, false)
                var part = batch
                run: while true {
                    for (offset, phrase) in batchIndices.enumerated() {
                        try checkCurrent(version)
                        runningPhrase = phrase
                        fatalPhrases.remove(phrase)
                        phrases[phrase].status = .generating("Phrase \(phrase + 1) of \(phrases.count)…")
                        let remaining = progress?.remainingEstimate ?? part.estimate
                        try await checkCap(Self.sum([remaining] + laterEstimates), version: version)
                        let running = part
                        let result = try await backend.execute(running, offset, phrase) { [weak self] rows in
                            await self?.receive(rows, phrase: phrase, batch: running, version: version)
                        }
                        await receive(result.rows, phrase: phrase, batch: running, version: version)
                        try checkCurrent(version)
                        try progress?.finish(window: offset, result: result)
                        if result.end == .cancelled || result.end == .invalidated { throw CancellationError() }
                        if result.end == .blocked {
                            // The guard settled this phrase; nothing was sent for it, and the run goes on (voice-lab §6.9).
                            let reason = Self.blockedCopy(result.failure)
                            block(phrase: phrase, reason: reason)
                            onBlocked?(phrase, reason)
                            continue
                        }
                        if result.end == .fatal {
                            fatalPhrases.insert(phrase)
                            phrases[phrase].status = .failed(problem.isEmpty ? Self.failureCopy(result) : problem)
                            // Only an account, key, consent or stop failure ends a run; timing never does (voice-lab §8.5).
                            let failure = result.failure ?? result.rows.last?.failure
                            let reason = problem.isEmpty ? Self.failureCopy(result) : problem
                            let next = failure.flatMap(Self.nextStep).map { " " + $0 } ?? ""
                            stopLater(after: offset, reason: "\(reason)", next: next)
                            break run
                        }
                        if phrases[phrase].takes.contains(where: { $0.row.voiceCheck == .waiting }) {
                            phrases[phrase].status = .generating("waiting for the voice check")
                        } else {
                            phrases[phrase].status = phrases[phrase].selected != nil ? .ready : .failed(problem.isEmpty ? Self.failureCopy(result) : problem)
                        }
                    }
                    runningPhrase = nil
                    guard !laterParts.isEmpty else { break run }
                    part = try await continueRun(version: version)
                }
            } catch {
                if revision == version {
                    report(error)
                    if let phrase = runningPhrase {
                        fatalPhrases.insert(phrase)
                        phrases[phrase].status = .failed(problem)
                    }
                }
            }
            await finishVoiceChecks(batch: self.batch ?? batch, version: version)
            await backend.discard()
            if revision == version { generating = false; runningPhrase = nil; self.batch = nil; cost = nil }
        }
        await operation?.value
        if revision == version { operation = nil }
        onMeasuredTakesChanged?()
    }

    /// Quotes the run's next part again and runs it under the run's one approval: only when the new quote has exactly the
    /// inputs and estimate the user approved; otherwise nothing more is sent (`Failure.priceChanged`).
    private func continueRun(version: Int) async throws -> VoiceLabTakeBatch {
        guard let backend, let next = laterParts.first else { throw Failure.stale }
        let candidates = next.priced.windows.first?.quote.takes.count ?? 1
        let quoted: VoiceLabTakeBatch
        do {
            try validateContextInputs(inputs)
            quoted = try await backend.prepare(next.indices.map { inputs[$0] }, next.indices, candidates)
            try checkCurrent(version)
            guard quoted.windows.map(\.input) == next.priced.windows.map(\.input), quoted.estimate == next.priced.estimate else {
                await backend.release(next.indices)
                throw Failure.priceChanged
            }
        } catch {
            if revision == version { stopLater(after: batchIndices.count - 1, reason: Self.copy(error), next: "") }
            throw error
        }
        laterParts.removeFirst()
        batch = quoted; batchIndices = next.indices; progress = VoiceLabTakeBatchProgress(batch: quoted)
        try await backend.approve(quoted, next.indices, true)
        return quoted
    }
    /// Marks the phrases after `offset` of the running part, and every later part's, as stopped with nothing more sent.
    private func stopLater(after offset: Int, reason: String, next: String) {
        for later in Array(batchIndices.dropFirst(offset + 1)) + laterParts.flatMap(\.indices) {
            let unsent = phrases[later].takes.isEmpty ? "Nothing sent for this phrase." : "No new take sent for this phrase."
            phrases[later].status = .stopped("Stopped: \(reason) \(unsent)\(next)")
        }
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
        operation = nil; generating = false; preparing = false; preparationStep = nil; runningPhrase = nil; batch = nil; cost = nil
        stopping = false
    }

    func invalidate() {
        lipsync.stop()
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
            generating = false; preparing = false; preparationStep = nil; runningPhrase = nil; self.operation = nil
        }
    }

    /// The user's choice of a passing take. Choosing one with a join advisory accepts the advisory (ADR-R39).
    @discardableResult func select(take: UUID, phrase: Int, at date: Date = Date()) -> Bool {
        if phrases.indices.contains(phrase), phrases[phrase].selectedID != take, lipsync.blocksMutation(phrase) { return false }
        guard !generating, !preparing, !publishing, !preparingVideo, !retired, isCurrent(), phrases.indices.contains(phrase),
              let index = phrases[phrase].takes.firstIndex(where: { $0.id == take && $0.row.selectable }) else { return false }
        let chosen = phrases[phrase].takes[index]
        if chosen.row.requiresJoinAdvisoryAcceptance {
            guard let row = try? chosen.row.acceptingJoinAdvisory(at: date) else { return false }
            phrases[phrase].takes[index] = Take(number: chosen.number, row: row, source: chosen.source)
        }
        stopAudition()
        if phrases[phrase].selectedID != take {
            clearPreparedVideo()
            phrases[phrase].videoChoice = nil
        }
        phrases[phrase].selectedID = take
        phrases[phrase].explicitlySelected = true
        phrases[phrase].leftOut = false
        if let microphone = microphoneTakes[take] {
            phrases[phrase].text = microphone.text; phrases[phrase].audioTags = []
        } else if let input = takeInputs[take] {
            if phrases[phrase].text != input.text || phrases[phrase].audioTags != input.audioTags {
                keepSelectedWording(phrase: phrase)
            }
            phrases[phrase].text = input.text; phrases[phrase].audioTags = input.audioTags
        }
        onMeasuredTakesChanged?()
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
        catch { report(error) }
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
            catch { report(error) }
            return
        }
        let wasPlaying = audition.isPlaying && audition.takeId == id
        stopAudition()
        guard !wasPlaying else { return }
        let turn = auditionTurn
        var found = microphoneTakes[id]?.scratch
        if found == nil { found = await backend?.scratch(phrase, id) }
        guard let audio = found, turn == auditionTurn, stillCurrent,
              phrases[phrase].takes.contains(where: { $0.id == id }), !generating, !preparing, !publishing else { return }
        do { try audition.play(audio, takeId: id, selectionId: String(phrase)) }
        catch { report(error) }
    }

    func dispatch(_ request: UUID, start: @escaping @Sendable () throws -> Void) async throws {
        let version = revision
        try checkCurrent(version)
        try validateContextInputs(inputs)
        guard generating, let remaining = progress?.remainingEstimate(from: request) else { throw Failure.stale }
        do { try await checkCap(Self.sum([remaining] + laterEstimates), version: version) }
        catch {
            if revision == version { report(error) }
            throw VoiceLabError.consentRequired
        }
        try start()
    }

    func scratch(take: UUID, phrase: Int) async -> VoiceLabTakeScratch? {
        guard stillCurrent, phrases.indices.contains(phrase), phrases[phrase].takes.contains(where: { $0.id == take && $0.row.selectable }) else { return nil }
        var scratch = microphoneTakes[take]?.scratch
        if scratch == nil { scratch = await backend?.scratch(phrase, take) }
        return stillCurrent ? scratch : nil
    }

    private func receive(_ rows: [VoiceLabTakeRow], phrase: Int, batch: VoiceLabTakeBatch, version: Int) async {
        for row in rows {
            if takeInputs[row.id] == nil, inputs.indices.contains(phrase) { takeInputs[row.id] = inputs[phrase] }
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
            if phrases[phrase].takes.count >= 3, !keepsEveryTake {
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
        guard !lipsync.blocksMutation(phrase) else { return }
        if phrases[phrase].leftOut { return }
        if phrases[phrase].explicitlySelected {
            if let row = phrases[phrase].selected?.row, row.selectable, !row.requiresJoinAdvisoryAcceptance { return }
            phrases[phrase].explicitlySelected = false
        }
        let best = chooseAutomatically(phrase: phrase)
        if best != phrases[phrase].selectedID {
            clearPreparedVideo()
            phrases[phrase].videoChoice = nil
            phrases[phrase].selectedID = best
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
        defer { lipsync.finishUseTakes() }
        try await lipsync.waitForUseTakes()
        guard stillCurrent else { invalidate(); throw Failure.stale }
        guard canAccept else { throw Failure.noSelection }
        let output = try applyingLipsync(to: await publishSelection(at: date))
        if selectedPhrases.contains(where: { $0.videoChoice == .retimed || $0.videoChoice == .cut }) || !output.videoAssets.isEmpty {
            let turn = videoRevision, choices = videoChoices
            preparingVideo = true
            defer { preparingVideo = false }
            let proposed = try VoiceLabEditCommand.acceptAll(segments: output.segments, assets: output.assets, voice: output.voice)
                .applying(to: project, outputScope: scope, videoAssets: output.videoAssets)
            let render = try await VideoDurationRenderReadiness.prepare(proposed, scope: scope, using: prepareDurationRender)
            try Task.checkCancellation()
            guard stillCurrent, turn == videoRevision, choices == videoChoices else { throw Failure.stale }
            preparedVideoSelection = PreparedVideoSelection(choices: choices, acceptance: output, render: render)
        }
        return output
    }

    private func publishSelection(at date: Date, onlyChosen: Bool = false) async throws -> Acceptance {
        stopAudition()
        let version = revision
        try checkCurrent(version)
        try validateContextInputs(inputs)
        guard !generating, !preparing, !publishing, let backend else { throw Failure.stale }
        publishing = true
        defer {
            publishing = false
            // Lip sync's publish can refuse a video preparation that an automatic choice started meanwhile (ADR-R39: no
            // click follows to start it again); it starts once this one ends, so Use never waits on a preparation nobody runs.
            if onlyChosen, !preparingVideo, videoPreparation == nil, needsVideoPreparation { Task { await prepareVideoChoices() } }
        }
        let selected = selectedPhrases.filter { !onlyChosen || $0.videoChoice != nil }
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
        var phraseIDs: [Int] = []
        for phrase in selected {
            phraseIDs.append(phrase.id)
            guard let row = phrase.selected?.row, row.selectable, !row.requiresJoinAdvisoryAcceptance,
                  let fit = row.audio?.fit.plan else { throw Failure.noSelection }
            if let microphone = microphoneTakes[row.id] {
                guard let storage = microphoneStorage else { throw Failure.stale }
                let published = try MicrophoneTakeMaker.publish(microphone, storage: storage, at: date)
                segments.append(try usable(phrase: phrase.id) {
                    let candidate = try VoiceLabRecordedTake.candidate(row: row, input: microphone.input, published: published,
                        model: microphone.model, createdAt: date, videoChoice: phrase.videoChoice)
                    return try VoiceLabRecordedTake.segment(id: UUID().uuidString.lowercased(), candidate: candidate,
                        input: microphone.input, plan: fit)
                })
                for asset in published.assets where !assets.contains(where: { $0.id == asset.id }) { assets.append(asset) }
                continue
            }
            let made = input(for: row, phrase: phrase.id)
            var (published, record) = try await backend.publish(phrase.id, row, made, date)
            #if DEBUG
            if let publishOverride { published = publishOverride(phrase.id, published) }
            #endif
            try checkCurrent(version)
            segments.append(try usable(phrase: phrase.id) {
                let candidate = try VoiceLabRecipeBuilder.candidate(row: row, input: made, published: published,
                                                                   record: record, createdAt: date, videoChoice: phrase.videoChoice)
                return try VoiceLabRecipeBuilder.segment(id: UUID().uuidString.lowercased(), candidates: [candidate],
                    selected: 0, input: made, plan: fit)
            })
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
        guard !segments.isEmpty else { throw Failure.noSelection }
        var acceptance = Acceptance(segments: segments, assets: assets, voice: voice)
        acceptance.phraseIDs = phraseIDs
        return acceptance
    }

    /// One phrase's segment, or `Failure.unusable` naming the phrase when its take can't be made into a render recipe
    /// (MVP32 Clip 7: Use stopped on such a take with only a button that repeated it). The cause is logged.
    private func usable(phrase: Int, _ build: () throws -> VoiceLabSegment) throws -> VoiceLabSegment {
        do { return try build() } catch let error where !(error is Failure) && !(error is CancellationError) {
            onFailure?(error)
            throw Failure.unusable(phrases: [phrase])
        }
    }

    // MARK: Own words and own takes (PhraseOwnWords.swift, MicrophoneTake.swift)

    func chooseWording(_ wording: PhraseWording, phrase index: Int) {
        guard phrases.indices.contains(index), phrases[index].wording != wording else { return }
        if wording == .ownWords, phrases[index].ownWords == nil { phrases[index].ownWords = PhraseWording.change(of: phrases[index]) }
        phrases[index].wording = wording
    }
    /// Typing the user's own words drops a held quote of this phrase that is not paid yet; no take is ever dropped.
    func editOwnWords(_ text: String, phrase index: Int) {
        guard phrases.indices.contains(index), phrases[index].ownWords != text else { return }
        phrases[index].ownWords = text
        guard batch != nil, runIndices.contains(index), !generating, !preparing, operation == nil else { return }
        revision += 1; batch = nil; batchIndices = []; progress = nil; cost = nil; estimate = nil
    }
    /// The words of the held quote when it is for `phrase` alone: what [Make take · ≈ $x] would voice.
    func quotedText(phrase index: Int) -> String? {
        guard batch != nil, batchIndices == [index], inputs.indices.contains(index) else { return nil }
        return inputs[index].text
    }
    /// Whether the held quote already voices `text` for this phrase, alone or with the others.
    func quotes(_ text: String, phrase index: Int) -> Bool {
        batch != nil && runIndices.contains(index) && inputs.indices.contains(index) && inputs[index].text == text
    }
    func microphoneTake(_ id: UUID) -> MicrophoneTake? { microphoneTakes[id] }
    /// Lists the user's own take beside the phrase's other takes; Record again replaces `replacing` when it is not used.
    @discardableResult func addMicrophoneTake(_ take: MicrophoneTake, phrase index: Int, replacing: UUID? = nil) -> Bool {
        guard stillCurrent, phrases.indices.contains(index), !generating, !publishing, !preparingVideo else {
            Task { await take.scratch.invalidate() }
            return false
        }
        stopAudition()
        keepsEveryTake = true
        microphoneTakes[take.row.id] = take; takeInputs[take.row.id] = take.input
        if let replacing, replacing != phrases[index].selectedID, microphoneTakes[replacing] != nil,
           let at = phrases[index].takes.firstIndex(where: { $0.id == replacing }) {
            phrases[index].takes[at] = Take(number: phrases[index].takes[at].number, row: take.row, source: .microphone)
            let old = microphoneTakes.removeValue(forKey: replacing); takeInputs[replacing] = nil
            Task { await old?.scratch.invalidate() }
        } else {
            let number = (phrases[index].takes.map(\.number).max() ?? 0) + 1
            phrases[index].takes.append(Take(number: number, row: take.row, source: .microphone))
        }
        if case .generating = phrases[index].status {} else { phrases[index].status = .ready }
        onMeasuredTakesChanged?()
        return true
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
    nonisolated static func copy(_ error: any Error) -> String {
        switch error {
        case Failure.spendingCap: "Your ElevenLabs spending limit was reached. Finished takes are kept."
        case Failure.unknownSpend: "VoxClip can't check your ElevenLabs spending limit. Nothing more was sent."
        case Failure.stale: "The rewrite changed. Make a fresh takes plan before sending anything."
        case Failure.noSelection: "Choose a valid video duration for every selected passage before using takes."
        case Failure.nothingToVoice: "None of these changes needs a new take. Apply the text changes, or rewrite a part with spoken changes."
        case Failure.tooManyPhrases(let count):
            "These changes make \(count) phrases to voice. Up to \(maximumPhrases) can be voiced in one run: voice the first changes now and rewrite the rest after."
        case Failure.unusable(let phrases):
            "\(phraseList(phrases.map { $0 + 1 }).prefix(1).uppercased() + phraseList(phrases.map { $0 + 1 }).dropFirst()) couldn't be made part of the video, so \(phrases.count == 1 ? "it keeps" : "they keep") your original audio."
        case Failure.priceChanged:
            "The price of the next phrases changed while takes were made, so nothing more was sent. Finished takes are kept. Get a fresh price for the rest."
        case is RewriteSpeechContextReview.Failure, is VoiceLabSpeechContextPlan.Failure:
            RewriteSpeechContextReview.copy(error)
        case Failure.placement(.geometry(let error), _): RewriteSession.refusal(error)
        case Failure.placement(let reason, _): reason.copy ?? "These phrases cannot be voiced together. Edit the words or leave one out."
        case is CancellationError: "Stopped. Finished takes are kept."
        default: RewriteSession.refusal(error)
        }
    }
    /// The one fix for a failure that ended a run (voice-lab §8.2.2): what the user does, then the phrase's take again.
    static func nextStep(_ failure: VoiceLabTakeFailure) -> String? {
        guard case .provider(let error) = failure else { return nil }
        switch error {
        case .quotaExceeded: return "Add credit to your ElevenLabs account, then choose Price a take."
        case .unauthorized, .missingKey: return "Check the ElevenLabs key in Settings, then choose Price a take."
        case .permissionMissing: return "Give the ElevenLabs key the Text to Speech permission, then choose Price a take."
        case .rateLimited, .network, .providerFailure: return "Choose Price a take to send it again."
        default: return nil
        }
    }
    /// A blocked phrase's stop, said once on its row (design.md R2 "Not your voice here").
    static func blockedCopy(_ failure: VoiceLabTakeFailure?) -> String {
        if case .consent(.speakerMismatch)? = failure {
            return "There isn't enough speech near this phrase to check that it's your voice. Nothing sent for this phrase."
        }
        return (VoiceConsentError.voiceOwnerMismatch.errorDescription ?? "") + " Nothing sent for this phrase."
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

extension ClipTakePlan {
    private struct LipsyncBinding: Equatable {
        let takeID: UUID?
        let video: VoiceLabVideoMode?
        let text: String
    }

    private var lipsyncBindings: [Int: LipsyncBinding] {
        Dictionary(uniqueKeysWithValues: phrases.map {
            ($0.id, LipsyncBinding(takeID: $0.selectedID, video: $0.videoChoice, text: $0.text))
        })
    }

    func makeLipsyncOffers() async throws -> ([Int: RewriteLipsyncSession.Offer], RewriteLipsyncSession.Offer?) {
        // A running preparation finishes first, so its render serves the offers instead of a second one being prepared.
        if let running = videoPreparation { await running.value }
        guard stillCurrent, !generating, !preparing, let prepareDurationRender else { throw Failure.stale }
        let bindings = lipsyncBindings
        let chosen = selectedPhrases.filter { $0.videoChoice != nil }
        let eligible = chosen.filter { lipsync.applied[$0.id] == nil && !lipsync.isRunning($0.id) }
        guard !eligible.isEmpty else { return ([:], nil) }
        // The cut or matched video prepared for these exact choices is the one lip sync uploads; the same choices are
        // never prepared twice. Without one (only kept-source durations, or a phrase still unchosen) it is prepared here.
        let request: RenderRequest, recordID: String
        if let prepared = preparedVideoSelection, prepared.choices == videoChoices, chosen.count == selectedPhrases.count {
            request = prepared.render.request; recordID = prepared.acceptance.voice?.consentRecordId ?? inputs.first?.recordID ?? ""
        } else {
            let base = try await publishSelection(at: Date(), onlyChosen: true)
            let proposed = try VoiceLabEditCommand.acceptAll(segments: base.segments, assets: base.assets, voice: base.voice)
                .applying(to: project, outputScope: scope, videoAssets: base.videoAssets)
            request = try await prepareDurationRender(proposed, scope)
            recordID = base.voice?.consentRecordId ?? inputs.first?.recordID ?? ""
        }
        guard stillCurrent, bindings == lipsyncBindings, !recordID.isEmpty, let input = request.voiceLab else { throw Failure.stale }
        let plan = input.prepared.outputPlan, rate = Int(plan.sampleRate)
        let total = plan.totalSourceSamples
        let windows = try eligible.map { phrase -> LipsyncWindow in
            guard let fit = phrase.selected?.row.audio?.fit.plan else { throw Failure.noSelection }
            return try LipsyncWindow.make(seamIn: fit.windowStartSample, seamOut: fit.windowEndSample,
                totalSamples: total, sampleRate: rate, phraseID: phrase.id)
        }
        let catalog = try VoiceLabPriceCatalog.load(shared: SharedResources.locate())
        func offer(_ windows: [LipsyncRenderWindow]) throws -> RewriteLipsyncSession.Offer {
            let estimates = try windows.map {
                try VoiceLabPricing.estimate(operation: .falLipsync(endpoint: "fal-ai/sync-lipsync/v3"), model: nil,
                    units: $0.seconds(sampleRate: plan.sampleRate), catalog: catalog)
            }
            guard estimates.allSatisfy({ $0.usd != nil }) else { throw Failure.unknownSpend }
            let estimate = CostEstimate(provider: "fal", operation: "lipsync", units: estimates.reduce(0) { $0 + $1.units },
                unit: "second", usd: estimates.reduce(Decimal(0)) { $0 + ($1.usd ?? 0) }, basis: estimates[0].basis)
            let dependencies = Set(phrases.filter { phrase in
                windows.contains { $0.source.startSample < phrase.window.endSample && $0.source.endSample > phrase.window.startSample }
            }.map(\.id))
            let bound = bindings.filter { dependencies.contains($0.key) }
            return RewriteLipsyncSession.Offer(id: UUID(), request: request, windows: windows, estimate: estimate,
                recordID: recordID, dependencies: dependencies, isCurrent: { [weak self] in
                    guard let self, stillCurrent else { return false }
                    return lipsyncBindings.filter { dependencies.contains($0.key) } == bound
                })
        }
        var individual: [Int: RewriteLipsyncSession.Offer] = [:]
        for window in windows {
            individual[window.phraseIDs[0]] = try offer(LipsyncRenderWindow.jobs(windows: [window], plan: plan))
        }
        return (individual, try offer(LipsyncRenderWindow.jobs(windows: windows, plan: plan)))
    }

    private func applyingLipsync(to output: Acceptance) throws -> Acceptance {
        var segments = output.segments, videoAssets: [VoiceLabVideoAsset] = []
        let chosen = selectedPhrases.filter { $0.videoChoice != nil }
        guard chosen.count == segments.count else { throw Failure.stale }
        for (index, phrase) in chosen.enumerated() {
            guard let applied = lipsync.applied[phrase.id] else { continue }
            let selected = segments[index].selectedCandidateIndex
            guard var recipe = segments[index].candidates[selected].recipe else { throw Failure.stale }
            recipe.video = recipe.video.addingLipsync(assetID: applied.result.asset.id,
                requestID: applied.result.provenance.requestID, sourceWindow: applied.window.source,
                syncMode: applied.result.provenance.syncMode)
            segments[index].candidates[selected].recipe = recipe
            if !videoAssets.contains(where: { $0.id == applied.result.asset.id }) { videoAssets.append(applied.result.asset) }
        }
        var result = Acceptance(segments: segments, assets: output.assets, voice: output.voice, videoAssets: videoAssets)
        result.phraseIDs = output.phraseIDs
        return result
    }

    func lipsyncPreview() async throws -> RenderRequest {
        guard let prepareDurationRender else { throw Failure.stale }
        let output = try applyingLipsync(to: await publishSelection(at: Date(), onlyChosen: true))
        let proposed = try VoiceLabEditCommand.acceptAll(segments: output.segments, assets: output.assets, voice: output.voice)
            .applying(to: project, outputScope: scope, videoAssets: output.videoAssets)
        return try await prepareDurationRender(proposed, scope)
    }
}
