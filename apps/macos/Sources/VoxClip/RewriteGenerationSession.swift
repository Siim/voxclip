import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

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
    @ObservationIgnored var readMonthlyCap: (@MainActor () async throws -> VoiceLabMonthlyCap?)?
    @ObservationIgnored private var preparedCap: VoiceLabMonthlyCap?
    @ObservationIgnored private var activeQuote: VoiceLabTakeRunQuote?
    @ObservationIgnored private var approvedCost: VoiceLabCostPresentation.Kind?
    @ObservationIgnored private var confirmCost: (@MainActor (String) async -> Bool)?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var executionRevision: Int?
    @ObservationIgnored private var launchStarted = false
    @ObservationIgnored private var phaseBeforeLaunch: Phase = .idle
    @ObservationIgnored private var accepting = false
    @ObservationIgnored private var reviewedInputsCurrent = true
    private(set) var preparingQuote = false
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
    var readyToAccept: Bool { !accepting && reviewedInputsCurrent && inputsAreCurrent() && phase == .readyToAccept && selected?.selectable == true }
    var acceptTitle: String { selected.map { "Use Take \($0.index + 1)" } ?? "Use Take 1" }
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
        guard let audio = selected?.audio, audio.fit.plan.outputFrames > 0 else { return nil }
        return (audio.fit.plan.windowEnd - audio.fit.plan.windowStart) * Double(audio.sampleRate) / Double(audio.fit.plan.outputFrames)
    }
    var canRetime: Bool { VoiceLabRenderInput.supportsVideoMode(.zoomCover) && retimeFactor.map { (0.80...1.25).contains($0) } ?? false }
    var lengthCopy: String {
        guard let row = selected, let audio = row.audio, case .changedDuration(_, _, let residual) = audio.fit else { return "" }
        let seconds = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), abs(residual))
        return "Take \(row.index + 1) runs \(seconds) s \(residual >= 0 ? "longer" : "shorter") than the words it replaces. Choose how the video keeps up."
    }
    var retimeCopy: String {
        guard VoiceLabRenderInput.supportsVideoMode(.zoomCover) else { return "Retimed source video is not available in this build. Re-record this sentence instead." }
        guard canRetime, let factor = retimeFactor, let audio = selected?.audio else { return "Retiming is unavailable outside 0.80×–1.25×. Re-record this sentence instead." }
        return "\(factor < 1 ? "Slows" : "Speeds") these \(String(format: "%.1f", audio.fit.plan.windowEnd - audio.fit.plan.windowStart)) s of video \(factor < 1 ? "to" : "up to") \(String(format: "%.2f", factor))× and crops in slightly around your face. Nothing is sent."
    }
    static func pauseFitNote(_ seconds: Double) -> String {
        "pauses " + (seconds >= 0 ? "+" : "−") + String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), abs(seconds))
    }
    func play(_ row: VoiceLabTakeRow) async {
        guard row.selectable else { return }
        if audition.isPlaying && audition.takeId == row.id { audition.stop(); return }
        _ = select(row.id)
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
            selectedID = next?.id; videoChoice = nil
            if let next {
                phase = next.fits ? .readyToAccept : .lengthChanged
                announcement = "Rejected Take \(row.index + 1). Take \(next.index + 1) selected."
            } else {
                phase = .nonePassed
                announcement = "These takes didn't sound right. Try different wording or re-record."
            }
        }
        await run.reject(row.id)
    }
    @discardableResult func accept(into editor: EditorModel, localCommands: [EditCommand] = [], at date: Date = Date()) async -> Bool {
        guard !Task.isCancelled, readyToAccept, let input, let selected else { return false }
        let version = revision, project = editor.project
        accepting = true
        defer { accepting = false }
        do {
            var candidates: [VoiceLabCandidate] = [], assets: [VoiceLabAsset] = []
            var voice: VoiceLabVoiceReference?
            var selectedIndex: Int?
            for row in rows where row.selectable && (row.fits || row.id == selected.id) &&
                row.audio?.fit.plan.windowStart == selected.audio?.fit.plan.windowStart &&
                row.audio?.fit.plan.windowEnd == selected.audio?.fit.plan.windowEnd {
                let published: VoiceLabPublishedTake, record: VoiceConsentRecord
                #if DEBUG
                if let publishForTests { (published, record) = try await publishForTests(row, input, date) }
                else { (published, record) = try await run.publishForAcceptance(row, input: input, at: date) }
                #else
                (published, record) = try await run.publishForAcceptance(row, input: input, at: date)
                #endif
                try Task.checkCancellation()
                guard version == revision, inputsAreCurrent(), editor.project == project else { return false }
                let candidate = try VoiceLabRecipeBuilder.candidate(row: row, input: input, published: published,
                    record: record, createdAt: date, videoChoice: row.id == selected.id ? videoChoice : nil)
                if row.id == selected.id { selectedIndex = candidates.count }
                candidates.append(candidate)
                for asset in published.assets where !assets.contains(where: { $0.id == asset.id }) { assets.append(asset) }
                voice = VoiceLabVoiceReference(id: record.id, provider: record.provider, voiceId: record.voiceId,
                    consentRecordId: record.id, displayName: record.voiceName, status: .active)
            }
            guard version == revision, inputsAreCurrent(), editor.project == project, let voice, let selectedIndex,
                  let plan = selected.audio?.fit.plan else { return false }
            let segment = try VoiceLabRecipeBuilder.segment(id: UUID().uuidString.lowercased(), candidates: candidates,
                selected: selectedIndex, input: input, plan: plan)
            try editor.applyVoiceLab(.accept(segment, assets: assets, voice: voice), localCommands: localCommands)
            return true
        } catch is CancellationError {
        } catch { if version == revision { problem = RewriteSession.refusal(error) } }
        return false
    }
    var selected: VoiceLabTakeRow? { rows.first { $0.id == selectedID } }
    var canGenerate: Bool { !accepting && !preparingQuote && inputsAreCurrent() && selectedVoiceID != nil && selectedModelID != nil && phase != .generating }
    var canExecute: Bool { canGenerate && quote != nil && cost != nil }
    var dispatchIsCurrent: Bool { executionRevision == nil || executionRevision == revision }
    var inputsMatchCurrentSelection: Bool { input?.recordID == selectedVoiceID && input?.modelID == selectedModelID }
    func discover(language: String) async {
        guard inputsAreCurrent() else { return }
        do {
            let choices = try await run.discover(language: language)
            models = choices.models; voices = choices.voices
            if !voices.contains(where: { $0.id == selectedVoiceID }) { chooseVoice(nil) }
            if !models.contains(where: { $0.id == selectedModelID }) { chooseModel(nil) }
            if selectedVoiceID == nil { chooseVoice(voices.first?.id) }
            if selectedModelID == nil { chooseModel(models.first?.id) }
        } catch { problem = RewriteSession.refusal(error) }
    }
    func chooseVoice(_ id: String?) {
        guard id == nil || voices.contains(where: { $0.id == id }) else { return }
        guard id != selectedVoiceID else { return }
        selectedVoiceID = id; inputsChanged()
    }
    func chooseModel(_ id: String?) {
        guard id == nil || models.contains(where: { $0.id == id }) else { return }
        guard id != selectedModelID else { return }
        selectedModelID = id; inputsChanged()
    }
    func inputsChanged() {
        let execution = sending
        sending?.cancel(); sending = nil
        reviewedInputsCurrent = false
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
        requestQuote()
    }
    func requestQuote() {
        quotePreparation?.cancel()
        revision += 1; quote = nil; cost = nil; quotedInput = nil; preparingQuote = false
        quotePreparationFailed = false; problem = ""
        guard let prepareQuote else { return }
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
        phaseBeforeLaunch = phase; launchStarted = false
        self.quote = nil; cost = nil; phase = .generating
        executionRevision = revision
        let version = revision; let run = run
        sending = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dispatchWithCurrentCost({})
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
                self.executionRevision = nil
                self.review(result)
                self.requestQuote()
            } catch {
                guard self.revision == version else { return }
                if error is CancellationError { self.cancel(); return }
                self.executionRevision = nil
                self.phase = Task.isCancelled ? .cancelled : .failed
                self.problem = Task.isCancelled ? "" : RewriteSession.refusal(error)
            }
        }
    }
    func dispatchWithCurrentCost(_ start: @escaping @Sendable () throws -> Void) async throws {
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
                guard let confirmCost, await confirmCost(copy) else { throw CancellationError() }
                try Task.checkCancellation()
                guard revision == version, activeQuote == quote, inputsAreCurrent() else { throw CancellationError() }
                approvedCost = decision
                continue
            }
            try start()
            return
        }
    }
    private func beginLaunch(version: Int) async throws {
        try await dispatchWithCurrentCost({})
        try Task.checkCancellation()
        guard revision == version, executionRevision == version, inputsAreCurrent() else { throw CancellationError() }
        launchStarted = true
        updateRows([], version: version)
    }
    private func updateRows(_ rows: [VoiceLabTakeRow], version: Int) {
        guard revision == version else { return }
        if rows.isEmpty {
            audition.stop(); bestID = nil; selectedID = nil; videoChoice = nil
            input = quotedInput; quotedInput = nil
        }
        for row in rows where !self.rows.contains(where: { $0.id == row.id }) && row.selectable {
            announcement = "Take \(row.index + 1) ready."
        }
        self.rows = rows
    }
    func review(_ result: VoiceLabTakeRunResult, input: VoiceLabTakeInput? = nil) {
        launchStarted = false
        if let input { self.input = input }
        reviewedInputsCurrent = true
        rows = result.rows; bestID = result.best?.id; selectedID = nil; videoChoice = nil
        guard result.end == .completed || result.end == .earlyStop else {
            phase = result.end == .cancelled || result.end == .invalidated ? .cancelled : .failed
            return
        }
        guard let best = result.best else { phase = .nonePassed; announcement = "These takes didn't sound right. Try different wording or re-record."; return }
        selectedID = best.id
        phase = best.fits ? .readyToAccept : .lengthChanged
        announcement = Self.completionAnnouncement(count: rows.count, fittedTake: best.fits ? best.index + 1 : nil,
                                                  failed: rows.filter { !$0.selectable }.count)
    }
    static func completionAnnouncement(count: Int, fittedTake: Int?, failed: Int = 0) -> String {
        let failures = failed == 1 ? "one" : failed == 2 ? "two" : "\(failed)"
        if let fittedTake {
            return "Take \(fittedTake) fits." + (failed > 0 ? " \(failures.capitalized) failed the speech check." : "")
        }
        let ready = count == 3 ? "Three takes ready." : count == 1 ? "One take ready." : "Two takes ready."
        return failed > 0 ? "\(ready.dropLast()), \(failures) failed the speech check." : ready
    }
    @discardableResult func select(_ id: UUID) -> Bool {
        guard !accepting, [.lengthChanged, .readyToAccept, .nonePassed].contains(phase),
              let row = rows.first(where: { $0.id == id }), row.selectable else { return false }
        if selectedID == id { return true }
        audition.selectionChanged(to: id.uuidString)
        selectedID = id; videoChoice = nil
        phase = row.fits ? .readyToAccept : .lengthChanged
        return true
    }
    @discardableResult func chooseVideo(_ choice: VoiceLabVideoMode) -> Bool {
        guard !accepting, phase == .lengthChanged, selected?.selectable == true, choice == .retimed, canRetime else { return false }
        videoChoice = choice; phase = .readyToAccept
        return true
    }
    func cancel() {
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
        audition.stop()
        quotePreparation?.cancel(); quotePreparation = nil
        sending?.cancel(); sending = nil; revision += 1
        quote = nil; cost = nil; rows = []; bestID = nil; selectedID = nil; videoChoice = nil; problem = ""; phase = .idle
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
