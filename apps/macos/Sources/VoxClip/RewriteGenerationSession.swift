import Darwin
import Foundation
import Observation
import VoxClipCore
import VoxClipMedia
#if canImport(stdio_h) && canImport(xlocale)
import stdio_h
import xlocale
#endif

@MainActor @Observable final class RewriteGenerationSession {
    enum Phase: Equatable {
        case idle, preparing, awaitingApproval, generating, nonePassed, failed, cancelled, lengthChanged, readyToAccept
    }
    private(set) var phase: Phase = .idle
    private(set) var voices: [VoiceConsentRecord] = []
    private(set) var models: [VoiceLabModel] = []
    private(set) var selectedVoiceID: String?
    private(set) var selectedModelID: String?
    private(set) var input: VoiceLabTakeInput?
    private(set) var quote: VoiceLabTakeRunQuote?
    private(set) var cost: VoiceLabCostPresentation.Kind?
    private(set) var rows: [VoiceLabTakeRow] = []
    private(set) var bestID: UUID?
    private(set) var selectedID: UUID?
    private(set) var videoChoice: VoiceLabVideoMode?
    private(set) var runFailure: VoiceLabTakeFailure?
    private(set) var preparingVideo = false
    @ObservationIgnored var prepareDurationRender: VideoDurationRenderPreparer?
    @ObservationIgnored private var videoRevision = UUID()
    @ObservationIgnored private var preparedVideoAcceptance: PreparedVideoAcceptance?
    private struct VideoAcceptance {
        let original: Project
        let review: Project
        let proposed: Project
        let scope: VoiceLabOutputScope
        let segment: VoiceLabSegment
        let assets: [VoiceLabAsset]
        let voice: VoiceLabVoiceReference
    }
    private struct PreparedVideoAcceptance {
        let takeID: UUID
        let acceptance: VideoAcceptance
        let render: PreparedVideoDurationRender
    }
    private(set) var problem = ""
    private(set) var announcement = ""
    let audition = VoiceLabAudition()
    @ObservationIgnored private var autoplayed: Set<UUID> = []
    @ObservationIgnored private let run: VoiceLabTakeRun
    @ObservationIgnored private let inputsAreCurrent: @MainActor () -> Bool
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var quotePreparation: Task<Void, Never>?
    @ObservationIgnored var prepareQuote: (@MainActor () async -> Void)?
    @ObservationIgnored var onInputsChanged: (@MainActor () -> Void)?
    @ObservationIgnored var readMonthlyCap: (@MainActor () async throws -> VoiceLabMonthlyCap?)?
    @ObservationIgnored private var preparedCap: VoiceLabMonthlyCap?
    @ObservationIgnored private var activeQuote: VoiceLabTakeRunQuote?
    @ObservationIgnored private var approvedCost: VoiceLabCostPresentation.Kind?
    @ObservationIgnored private var confirmCost: (@MainActor (String) async -> Bool)?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var executionRevision: Int?
    @ObservationIgnored private var launchStarted = false
    @ObservationIgnored private var approvalDeclined = false
    @ObservationIgnored private var phaseBeforeLaunch: Phase = .idle
    @ObservationIgnored private var accepting = false
    @ObservationIgnored private var reviewedInputsCurrent = true
    private(set) var preparingQuote = false
    @ObservationIgnored var validatePlacement: (@MainActor (VoiceLabWindow) throws -> Void) = { _ in }
    private(set) var quotePreparationFailed = false
    @ObservationIgnored private var quotedInput: VoiceLabTakeInput?
    #if DEBUG
    private var fixture = false
    @ObservationIgnored var publishForTests: (@MainActor (VoiceLabTakeRow, VoiceLabTakeInput, Date) async throws -> (VoiceLabPublishedTake, VoiceConsentRecord))?
    @ObservationIgnored var prepareForTests: (@MainActor (VoiceLabTakeInput) async throws -> VoiceLabTakeRunQuote)?
    @ObservationIgnored var executeForTests: (@MainActor (VoiceLabTakeRunQuote, @Sendable ([VoiceLabTakeRow]) async -> Void, @Sendable () async throws -> Void) async throws -> VoiceLabTakeRunResult)?
    func finishGenerationForTests() async { await sending?.value; await quotePreparation?.value }
    func finishQuotePreparationForTests() async { await quotePreparation?.value }
    func showFixture(_ state: String, voice: VoiceConsentRecord) {
        fixture = true
        voices = state == "no-voice" ? [] : [voice]
        models = [.init(id: "eleven_multilingual_v2", name: "Multilingual v2", languages: ["en"], canSpeak: true, canConvert: false, maximumTextLength: 5_000, characterCostMultiplier: 1)]
        selectedVoiceID = voices.first?.id; selectedModelID = models.first?.id
        let changed = state == "length-changed"
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: 24_000, windowStart: 1, windowEnd: 2, windowStartSample: 48_000, windowEndSample: 96_000,
            outputFrames: changed ? 57_600 : 24_000, words: [.init(text: "Clearer", start: 0.1, end: 0.8, synthetic: true)])
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0, roomTone: nil,
            fit: changed ? .changedDuration(plan, naturalOut: 2.4, residualSeconds: 1.4) : .exact(plan))
        let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10, speakerScore: 0.9), failures: [])
        let passing = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, audio: audio, qa: qa, score: 0.9)
        let failed = VoiceLabTakeRow(id: UUID(), index: 1, seed: 2, failure: .qa([.transcript]))
        review(.init(rows: state == "none-passed" ? [failed] : [passing, failed], end: .completed))
        switch state {
        case "no-voice": rows = []; selectedID = nil; phase = .idle
        case "generating": rows = [passing]; phase = .generating
        case "provider-error": fail("ElevenLabs rejected the key (401). Your edits are saved.")
        case "cost-confirmation":
            rows = []; selectedID = nil; phase = .awaitingApproval
            cost = .confirm("VoxClip can't tell what this costs. Check ElevenLabs's pricing.")
        case "cancelled": phase = .cancelled; selectedID = nil
        default: break
        }
    }
    #endif
    var needsPreparation: Bool {
        #if DEBUG
        if fixture { return false }
        #endif
        return quote == nil && rows.isEmpty && selectedVoiceID != nil && selectedModelID != nil
    }
    init(run: VoiceLabTakeRun, inputsAreCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.run = run; self.inputsAreCurrent = inputsAreCurrent
    }
    var readyToAccept: Bool {
        guard !accepting, !preparingVideo, reviewedInputsCurrent, inputsAreCurrent(), phase == .readyToAccept,
              selected?.selectable == true, let videoChoice, videoAvailability.allows(videoChoice) else { return false }
        return videoChoice == .source || preparedVideoAcceptance?.takeID == selectedID
    }
    var videoAvailability: VideoDurationChoiceAvailability {
        VideoDurationChoiceAvailability(row: selected, sourceSampleRate: input?.sourceSampleRate ?? 48_000,
            rendererReady: prepareDurationRender != nil && VoiceLabRenderInput.supportsVideoMode(.zoomCover))
    }
    private func clearVideoChoice() {
        videoRevision = UUID(); videoChoice = nil; preparedVideoAcceptance = nil
    }
    var acceptTitle: String { selected.map { "Use Take \($0.index + 1)" } ?? "Use Take" }
    var buttonTitle: String { generationButtonTitle(rows.isEmpty ? "Generate Takes" : "Generate Again") }
    func generationButtonTitle(_ action: String, takes: Int? = nil) -> String {
        let amount = quote?.estimate.usd.map { $0 == 0 ? "" : VoiceLabCostPresentation.format($0) } ?? ""
        return VoiceLabCostPresentation.buttonTitle(action, takes: takes, kind: .inline(amount))
    }
    func fail(_ text: String) {
        preparingQuote = false
        quotePreparationFailed = true
        if rows.isEmpty { phase = .failed }
        problem = text
    }
    var retimeFactor: Double? {
        videoAvailability.options?.retimeFactor
    }
    var canRetime: Bool { videoAvailability.allows(.retimed) }
    var lengthCopy: String {
        guard let row = selected, let audio = row.audio, case .changedDuration(_, _, let residual) = audio.fit else { return "" }
        let seconds = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), abs(residual))
        return "Take \(row.index + 1) runs \(seconds) s \(residual >= 0 ? "longer" : "shorter") than the words it replaces. Choose how the video keeps up."
    }
    var retimeCopy: String {
        if let reason = videoAvailability.changedReason { return reason }
        guard canRetime, let factor = retimeFactor, let audio = selected?.audio else { return "Retiming is unavailable outside 0.80×–1.25×. Re-record this sentence instead." }
        return "\(factor < 1 ? "Slows" : "Speeds") these \(String(format: "%.1f", audio.fit.plan.windowEnd - audio.fit.plan.windowStart)) s of video \(factor < 1 ? "to" : "up to") \(String(format: "%.2f", factor))× and applies a centered 1.12× crop. Nothing is sent."
    }
    static func pauseFitNote(_ seconds: Double) -> String {
        let sign = seconds >= 0 ? "+" : "−"
        let magnitude = abs(seconds)
        let required = withVaList([magnitude]) { vsnprintf_l(nil, 0, nil, "%.1f", $0) }
        precondition(required >= 0)
        let byteCount: Int = Int(required)
        let capacity: Int = byteCount + 1
        var buffer = [CChar](repeating: 0, count: capacity)
        let written = withVaList([magnitude]) { vsnprintf_l(&buffer, capacity, nil, "%.1f", $0) }
        precondition(written == required)
        let bytes = buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
        let number = String(decoding: bytes, as: UTF8.self)
        return "pauses \(sign)\(number) s"
    }
    func play(_ row: VoiceLabTakeRow) async {
        guard row.selectable else { return }
        if audition.isPlaying && audition.takeId == row.id { audition.stop(); return }
        guard select(row.id) else { return }
        do {
            guard let scratch = await run.scratch(for: row.id), selectedID == row.id, inputsAreCurrent() else { return }
            try audition.play(scratch, takeId: row.id, selectionId: row.id.uuidString)
        } catch { problem = RewriteSession.refusal(error) }
    }
    func autoplayBest() async {
        guard let best = takeToAutoplay() else { return }
        await play(best)
    }
    func takeToAutoplay() -> VoiceLabTakeRow? {
        guard selectedID == bestID, let best = rows.first(where: { $0.id == bestID }), autoplayed.insert(best.id).inserted else { return nil }
        return best
    }
    func reject(_ row: VoiceLabTakeRow) async {
        audition.stop(); rows.removeAll { $0.id == row.id }
        let next = VoiceLabTakeRunResult(rows: rows, end: .completed).best
        bestID = next?.id
        if selectedID == row.id {
            clearVideoChoice()
            selectedID = next?.id; videoChoice = nil
            if let next {
                phase = next.fits ? .readyToAccept : .lengthChanged
                announcement = "Rejected Take \(row.index + 1). Take \(next.index + 1) selected."
            } else {
                phase = .nonePassed
                announcement = Self.completionAnnouncement(rows: rows, fittedTake: nil)
            }
        }
        await run.reject(row.id)
    }
    /// Publishes the selected take and applies it with `localCommands` as one edit. `wrap` runs that one synchronous edit,
    /// so the caller can tell its own change from an edit the user makes while the take publishes (`RewriteSession.follow`).
    @discardableResult func accept(into editor: EditorModel, localCommands: [EditCommand] = [], at date: Date = Date(),
                                   wrap: (() throws -> Void) throws -> Void = { try $0() }) async -> Bool {
        guard !Task.isCancelled, readyToAccept else { return false }
        let version = revision, turn = videoRevision, chosenID = selectedID
        audition.stop()
        accepting = true
        defer { accepting = false }
        do {
            let output = try await publishVideoSelection(into: editor, localCommands: localCommands, at: date)
            let render: PreparedVideoDurationRender?
            if videoChoice == .retimed {
                render = try await VideoDurationRenderReadiness.prepare(output.proposed, scope: output.scope, using: prepareDurationRender)
            } else { render = nil }
            try Task.checkCancellation()
            guard version == revision, turn == videoRevision, chosenID == selectedID,
                  inputsAreCurrent(), reviewedInputsCurrent, editor.project == output.original,
                  try editor.voiceLabReviewProject(localCommands: localCommands) == output.review else { return false }
            try withExtendedLifetime(render) {
                try wrap { try editor.applyVoiceLab(.accept(output.segment, assets: output.assets, voice: output.voice), localCommands: localCommands) }
            }
            return true
        } catch is CancellationError {
        } catch { if version == revision { problem = RewriteSession.refusal(error) } }
        return false
    }

    private func publishVideoSelection(into editor: EditorModel, localCommands: [EditCommand], at date: Date) async throws -> VideoAcceptance {
        guard let input, let row = selected, row.selectable, let plan = row.audio?.fit.plan,
              let choice = videoChoice, videoAvailability.allows(choice) else { throw VoiceLabProjectError.videoModeUnsupported }
        let version = revision, turn = videoRevision, original = editor.project
        let review = try editor.voiceLabReviewProject(localCommands: localCommands)
        let scope = original.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
        var window = input.window
        window.start = plan.windowStart; window.end = plan.windowEnd
        window.startSample = plan.windowStartSample; window.endSample = plan.windowEndSample
        try editor.validateVoiceLabPlacement(window, localCommands: localCommands)
        let published: VoiceLabPublishedTake, record: VoiceConsentRecord
        #if DEBUG
        if let publishForTests { (published, record) = try await publishForTests(row, input, date) }
        else { (published, record) = try await run.publishForAcceptance(row, input: input, at: date) }
        #else
        (published, record) = try await run.publishForAcceptance(row, input: input, at: date)
        #endif
        try Task.checkCancellation()
        guard version == revision, turn == videoRevision, inputsAreCurrent(), reviewedInputsCurrent,
              editor.project == original, selectedID == row.id else { throw VoiceLabProjectError.staleRenderContract }
        let candidate = try VoiceLabRecipeBuilder.candidate(row: row, input: input, published: published,
            record: record, createdAt: date, videoChoice: choice)
        let segment = try VoiceLabRecipeBuilder.segment(id: UUID().uuidString.lowercased(), candidates: [candidate], selected: 0, input: input, plan: plan)
        let voice = VoiceLabVoiceReference(id: record.id, provider: record.provider, voiceId: record.voiceId,
            consentRecordId: record.id, displayName: record.voiceName, status: .active)
        let proposed = try VoiceLabEditCommand.accept(segment, assets: published.assets, voice: voice).applying(to: review, outputScope: scope)
        return VideoAcceptance(original: original, review: review, proposed: proposed, scope: scope,
            segment: segment, assets: published.assets, voice: voice)
    }

    func prepareVideoChoice(into editor: EditorModel, localCommands: [EditCommand] = [], at date: Date = Date()) async {
        guard !accepting, !preparingVideo, reviewedInputsCurrent, inputsAreCurrent(), videoChoice == .retimed,
              videoAvailability.allows(.retimed), let selectedID else { return }
        if let prepared = preparedVideoAcceptance, prepared.takeID == selectedID,
           prepared.acceptance.original == editor.project,
           (try? editor.voiceLabReviewProject(localCommands: localCommands)) == prepared.acceptance.review { return }
        let turn = videoRevision
        preparingVideo = true
        defer { preparingVideo = false }
        do {
            let output = try await publishVideoSelection(into: editor, localCommands: localCommands, at: date)
            let render = try await VideoDurationRenderReadiness.prepare(output.proposed, scope: output.scope, using: prepareDurationRender)
            try Task.checkCancellation()
            guard turn == videoRevision, reviewedInputsCurrent, inputsAreCurrent(), self.selectedID == selectedID,
                  editor.project == output.original, try editor.voiceLabReviewProject(localCommands: localCommands) == output.review
            else { throw VoiceLabProjectError.staleRenderContract }
            preparedVideoAcceptance = PreparedVideoAcceptance(takeID: selectedID, acceptance: output, render: render)
            problem = ""
        } catch {
            if turn == videoRevision { preparedVideoAcceptance = nil; problem = RewriteSession.refusal(error) }
        }
    }
    var selected: VoiceLabTakeRow? { rows.first { $0.id == selectedID } }
    var canGenerate: Bool { !accepting && !preparingVideo && !preparingQuote && inputsAreCurrent() && selectedVoiceID != nil && selectedModelID != nil && phase != .generating }
    var canExecute: Bool { canGenerate && quote != nil && cost != nil }
    var dispatchIsCurrent: Bool { executionRevision == nil || executionRevision == revision }
    var inputsMatchCurrentSelection: Bool { input?.recordID == selectedVoiceID && input?.modelID == selectedModelID }
    func discover(language: String) async {
        guard inputsAreCurrent() else { return }
        let version = revision
        do {
            let choices = try await run.discover(language: language)
            guard version == revision, inputsAreCurrent(), !Task.isCancelled else { return }
            models = choices.models; voices = choices.voices
            if !voices.contains(where: { $0.id == selectedVoiceID }) { chooseVoice(nil) }
            if !models.contains(where: { $0.id == selectedModelID }) { chooseModel(nil) }
            if selectedVoiceID == nil { chooseVoice(voices.first?.id) }
            if selectedModelID == nil { chooseModel(VoiceLabModel.patchDefault(models)?.id) }
        } catch { problem = RewriteSession.refusal(error) }
    }
    func chooseVoice(_ id: String?) {
        guard id == nil || voices.contains(where: { $0.id == id }) else { return }
        guard id != selectedVoiceID else { return }
        selectedVoiceID = id; inputsChanged()
    }
    /// Moves a plan with paid takes to another model and keeps its takes: true when it moved, false when it could not
    /// (the model stays, so paid takes are never dropped by a model change), nil without paid takes, which leaves the
    /// ordinary invalidation.
    @ObservationIgnored var changeModelKeepingTakes: (@MainActor (String) -> Bool?)?
    func chooseModel(_ id: String?) {
        guard id == nil || models.contains(where: { $0.id == id }) else { return }
        guard id != selectedModelID else { return }
        if let id, let kept = changeModelKeepingTakes?(id) {
            if kept { selectedModelID = id }
            return
        }
        selectedModelID = id; inputsChanged()
    }
    func inputsChanged(prepareNewQuote: Bool = true) {
        clearVideoChoice()
        onInputsChanged?()
        let execution = sending
        sending?.cancel(); sending = nil
        reviewedInputsCurrent = false
        announcement = "These takes no longer match the current inputs. Review the changes before using a take."
        if phase == .generating {
            let retained = selected ?? VoiceLabTakeRunResult(rows: rows, end: .completed).best
            phase = retained.map { $0.fits ? .readyToAccept : .lengthChanged } ?? (rows.isEmpty ? .idle : .nonePassed)
        }
        let previous = cleanup; let run = run; let executionRevision = executionRevision
        cleanup = Task { [weak self] in
            await previous?.value
            await run.cancel(keepingTakes: true)
            await execution?.value
            if self?.executionRevision == executionRevision { self?.executionRevision = nil }
        }
        requestQuote(prepareNewQuote: prepareNewQuote)
    }
    func requestQuote(prepareNewQuote: Bool = true) {
        quotePreparation?.cancel()
        revision += 1; quote = nil; cost = nil; quotedInput = nil; preparingQuote = false
        quotePreparationFailed = false; problem = ""
        guard prepareNewQuote, let prepareQuote else { return }
        quotePreparation = Task {
            guard !Task.isCancelled else { return }
            await prepareQuote()
        }
    }
    func reservePreparation() -> Int? {
        guard !Task.isCancelled, canGenerate else { return nil }
        revision += 1; quote = nil; cost = nil; quotedInput = nil; problem = ""; preparingQuote = true; quotePreparationFailed = false
        if rows.isEmpty { phase = .preparing }
        return revision
    }
    func preparationIsCurrent(_ reservation: Int) -> Bool { reservation == revision && inputsAreCurrent() && !Task.isCancelled }
    func prepare(_ input: VoiceLabTakeInput, cap: VoiceLabMonthlyCap? = nil, reservation: Int? = nil) async {
        guard selectedVoiceID == input.recordID, selectedModelID == input.modelID else { return }
        if let reservation { guard preparationIsCurrent(reservation), preparingQuote else { return } }
        else { guard reservePreparation() != nil else { return } }
        let version = revision
        defer { if version == revision { preparingQuote = false } }
        await cleanup?.value
        guard version == revision else { return }
        do {
            try validatePlacement(input.window)
            let quote: VoiceLabTakeRunQuote
            #if DEBUG
            if let prepareForTests { quote = try await prepareForTests(input) }
            else { quote = try await run.prepare(input) }
            #else
            quote = try await run.prepare(input)
            #endif
            guard version == revision else { return }
            self.quote = quote; quotedInput = input
            preparedCap = cap
            cost = VoiceLabCostPresentation.kind(quote.estimate, isLipSync: false, providerName: "ElevenLabs", cap: cap)
            if rows.isEmpty { self.input = input; phase = .awaitingApproval }
        } catch {
            guard version == revision else { return }
            fail(RewriteSession.refusal(error))
        }
    }
    func approve(_ approved: Bool, confirmation: (@MainActor (String) async -> Bool)? = nil) {
        guard approved, canGenerate, let quote else { return }
        activeQuote = quote; approvedCost = confirmation == nil ? cost : nil; confirmCost = confirmation
        phaseBeforeLaunch = phase; launchStarted = false; approvalDeclined = false
        self.quote = nil; cost = nil; phase = .generating
        executionRevision = revision
        let version = revision; let run = run
        sending = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dispatchWithCurrentCost({}, committingLaunch: false)
                let progress: @Sendable ([VoiceLabTakeRow]) async -> Void = { rows in
                    await self.updateRows(rows, version: version)
                }
                let started: @Sendable () async throws -> Void = { try await self.beginLaunch(version: version) }
                let result: VoiceLabTakeRunResult
                #if DEBUG
                if let executeForTests { result = try await executeForTests(quote, progress, started) }
                else { result = try await run.execute(quote, approved: true, progress: progress, started: started) }
                #else
                result = try await run.execute(quote, approved: true, progress: progress, started: started)
                #endif
                guard self.revision == version else { return }
                if self.approvalDeclined, !self.launchStarted { self.retainDeclinedQuote(); return }
                guard self.launchStarted else {
                    self.executionRevision = nil
                    self.phase = self.phaseBeforeLaunch
                    self.runFailure = result.failure
                    self.problem = result.failure.map { TakeFailurePresentation.reason(for: $0) } ?? "Take generation did not start. No failure reason is available."
                    self.announcement = "No new takes were made. " + self.problem
                    return
                }
                self.executionRevision = nil
                self.review(result)
                if result.best != nil, result.end == .completed || result.end == .earlyStop { self.requestQuote() }
            } catch {
                guard self.revision == version else { return }
                if self.approvalDeclined, !self.launchStarted { self.retainDeclinedQuote(); return }
                if error is CancellationError { self.cancel(); return }
                self.executionRevision = nil
                self.phase = Task.isCancelled ? .cancelled : .failed
                if let failure = error as? VoiceLabError { self.runFailure = .provider(failure) }
                else if let failure = error as? VoiceConsentError { self.runFailure = .consent(failure) }
                else { self.runFailure = nil }
                self.problem = Task.isCancelled ? "" : self.runFailure.map { TakeFailurePresentation.reason(for: $0) } ?? RewriteSession.refusal(error)
                self.announcement = Task.isCancelled ? "Take generation stopped." : "Take generation stopped. No take can be used from this review. " + self.problem
            }
        }
    }
    func dispatchWithCurrentCost(_ start: @escaping @Sendable () throws -> Void, committingLaunch: Bool = true) async throws {
        guard let quote = activeQuote, let version = executionRevision else { throw VoiceLabError.consentRequired }
        while true {
            try Task.checkCancellation()
            let cap: VoiceLabMonthlyCap?
            if let readMonthlyCap { cap = try await readMonthlyCap() }
            else { cap = preparedCap }
            try Task.checkCancellation()
            guard revision == version, activeQuote == quote, inputsAreCurrent() else { throw CancellationError() }
            let decision = VoiceLabCostPresentation.kind(quote.estimate, isLipSync: false, providerName: "ElevenLabs", cap: cap)
            if case .confirm(let copy) = decision, decision != approvedCost {
                guard let confirmCost else { throw CancellationError() }
                let approved = await confirmCost(copy)
                try Task.checkCancellation()
                guard revision == version, activeQuote == quote, inputsAreCurrent() else { throw CancellationError() }
                guard approved else { approvalDeclined = true; throw CancellationError() }
                approvedCost = decision
                continue
            }
            try start()
            if committingLaunch, !launchStarted {
                launchStarted = true
                updateRows([], version: version)
            }
            return
        }
    }
    private func beginLaunch(version: Int) async throws {
        try await dispatchWithCurrentCost({}, committingLaunch: false)
        try Task.checkCancellation()
        guard revision == version, executionRevision == version, inputsAreCurrent() else { throw CancellationError() }
    }
    private func retainDeclinedQuote() {
        quote = activeQuote
        activeQuote = nil; executionRevision = nil; approvedCost = nil; confirmCost = nil
        cost = quote.map { VoiceLabCostPresentation.kind($0.estimate, isLipSync: false, providerName: "ElevenLabs", cap: preparedCap) }
        phase = phaseBeforeLaunch
        sending = nil
    }
    private func updateRows(_ rows: [VoiceLabTakeRow], version: Int) {
        guard revision == version else { return }
        if rows.isEmpty {
            audition.stop(); bestID = nil; selectedID = nil; videoChoice = nil
            runFailure = nil; problem = ""
            input = quotedInput; quotedInput = nil
        }
        for row in rows where !self.rows.contains(where: { $0.id == row.id }) && row.selectable {
            announcement = row.fits ? "Take \(row.index + 1) fits." : "Take \(row.index + 1) passed checks but needs a timing change."
        }
        self.rows = rows
    }
    func review(_ result: VoiceLabTakeRunResult, input: VoiceLabTakeInput? = nil) {
        clearVideoChoice()
        launchStarted = false
        if let input { self.input = input }
        reviewedInputsCurrent = true
        rows = result.rows; bestID = result.best?.id; selectedID = nil; videoChoice = nil
        runFailure = result.failure
        problem = result.failure.map { TakeFailurePresentation.reason(for: $0) } ?? ""
        guard result.end == .completed || result.end == .earlyStop else {
            phase = result.end == .cancelled || result.end == .invalidated ? .cancelled : .failed
            let status = result.end == .invalidated ? "These takes are no longer current." : "Take generation stopped."
            announcement = status + " No take can be used from this review." + (problem.isEmpty ? "" : " " + problem)
            return
        }
        guard let best = result.best else {
            phase = .nonePassed
            announcement = Self.completionAnnouncement(rows: rows, fittedTake: nil)
            if !problem.isEmpty, !announcement.contains(problem) { announcement += " " + problem }
            return
        }
        selectedID = best.id
        phase = best.fits ? .readyToAccept : .lengthChanged
        announcement = Self.completionAnnouncement(rows: rows, fittedTake: best.fits ? best.index + 1 : nil)
    }
    static func completionAnnouncement(rows: [VoiceLabTakeRow], fittedTake: Int?) -> String {
        let checked = rows.filter(\.selectable)
        let fitting = checked.filter(\.fits)
        var parts: [String] = []
        if let fittedTake, fitting.contains(where: { $0.index + 1 == fittedTake }) {
            parts.append("Take \(fittedTake) fits.")
        } else if !fitting.isEmpty {
            parts.append("\(countWord(fitting.count)) \(fitting.count == 1 ? "take fits" : "takes fit").")
        } else if !checked.isEmpty {
            parts.append("No take fits yet. \(countWord(checked.count)) \(checked.count == 1 ? "take passed" : "takes passed") checks but \(checked.count == 1 ? "needs" : "need") a timing change.")
        } else {
            parts.append("No usable takes.")
        }
        let excluded = rows.filter { !$0.selectable }
        if !excluded.isEmpty { parts.append("\(countWord(excluded.count)) \(excluded.count == 1 ? "take" : "takes") left out.") }
        for reason in excluded.compactMap({ TakeFailurePresentation.reason(for: $0) }) where !parts.contains(reason) { parts.append(reason) }
        return parts.joined(separator: " ")
    }
    private static func countWord(_ count: Int) -> String {
        switch count { case 1: "One"; case 2: "Two"; case 3: "Three"; default: "\(count)" }
    }
    @discardableResult func select(_ id: UUID) -> Bool {
        guard !accepting, !preparingVideo, reviewedInputsCurrent, inputsAreCurrent(), [.lengthChanged, .readyToAccept, .nonePassed].contains(phase),
              let row = rows.first(where: { $0.id == id }), row.selectable else { return false }
        if selectedID == id { return true }
        audition.selectionChanged(to: id.uuidString)
        clearVideoChoice()
        selectedID = id
        phase = row.fits ? .readyToAccept : .lengthChanged
        return true
    }
    @discardableResult func chooseVideo(_ choice: VoiceLabVideoMode) -> Bool {
        guard !accepting, !preparingVideo, reviewedInputsCurrent, inputsAreCurrent(),
              [.lengthChanged, .readyToAccept].contains(phase), selected?.selectable == true,
              videoAvailability.allows(choice) else { return false }
        if videoChoice == choice { return true }
        clearVideoChoice()
        videoChoice = choice; phase = .readyToAccept
        return true
    }
    func cancel() {
        if preparingVideo { clearVideoChoice() }
        let execution = sending
        sending = nil
        if launchStarted { audition.stop() }
        quotePreparation?.cancel(); quotePreparation = nil
        execution?.cancel(); revision += 1; quote = nil; cost = nil; quotedInput = nil; preparingQuote = false
        activeQuote = nil; approvedCost = nil; confirmCost = nil
        if launchStarted { selectedID = nil; phase = .cancelled }
        else if phase == .generating { phase = phaseBeforeLaunch }
        let previous = cleanup; let run = run; let executionRevision = executionRevision
        cleanup = Task { [weak self] in
            await previous?.value
            await run.cancel(keepingTakes: true)
            await execution?.value
            if self?.executionRevision == executionRevision { self?.executionRevision = nil }
        }
        requestQuote()
    }
    func invalidate() {
        clearVideoChoice()
        audition.stop()
        quotePreparation?.cancel(); quotePreparation = nil
        sending?.cancel(); sending = nil; revision += 1
        quote = nil; cost = nil; rows = []; bestID = nil; selectedID = nil; videoChoice = nil; runFailure = nil; problem = ""; phase = .idle
        announcement = ""
        input = nil; quotedInput = nil; preparingQuote = false
        activeQuote = nil; approvedCost = nil; confirmCost = nil
        enqueueCleanup()
    }
    private func enqueueCleanup() {
        let previous = cleanup; let run = run
        cleanup = Task {
            await previous?.value
            await run.invalidate()
        }
    }
}
