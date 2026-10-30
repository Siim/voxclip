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
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var accepting = false
    #if DEBUG
    private var fixture = false
    @ObservationIgnored var publishForTests: (@MainActor (VoiceLabTakeRow, VoiceLabTakeInput, Date) async throws -> (VoiceLabPublishedTake, VoiceConsentRecord))?
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
    var readyToAccept: Bool { !accepting && inputsAreCurrent() && phase == .readyToAccept && selected?.selectable == true }
    var acceptTitle: String { selected.map { "Use Take \($0.index + 1)" } ?? "Use Take 1" }
    var buttonTitle: String { VoiceLabCostPresentation.buttonTitle(rows.isEmpty ? "Generate Takes" : "Generate Again", kind: cost ?? .confirm("")) }
    func fail(_ text: String) { phase = .failed; problem = text }
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
        if selectedID == row.id { selectedID = nil; videoChoice = nil; phase = .nonePassed }
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
    var canGenerate: Bool { inputsAreCurrent() && selectedVoiceID != nil && selectedModelID != nil && phase != .generating && phase != .preparing }
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
        invalidate(); selectedVoiceID = id
    }
    func chooseModel(_ id: String?) {
        guard id == nil || models.contains(where: { $0.id == id }) else { return }
        guard id != selectedModelID else { return }
        invalidate(); selectedModelID = id
    }
    func reservePreparation() -> Int? {
        guard canGenerate else { return nil }
        invalidate(); phase = .preparing
        return revision
    }
    func preparationIsCurrent(_ reservation: Int) -> Bool { reservation == revision && inputsAreCurrent() && !Task.isCancelled }
    func prepare(_ input: VoiceLabTakeInput, cap: VoiceLabMonthlyCap? = nil, reservation: Int? = nil) async {
        guard selectedVoiceID == input.recordID, selectedModelID == input.modelID else { return }
        if let reservation { guard preparationIsCurrent(reservation), phase == .preparing else { return } }
        else { guard reservePreparation() != nil else { return } }
        self.input = input
        let version = revision
        await cleanup?.value
        guard version == revision else { return }
        do {
            let quote = try await run.prepare(input)
            guard version == revision else { return }
            self.quote = quote
            cost = VoiceLabCostPresentation.kind(quote.estimate, isLipSync: false, providerName: "ElevenLabs", cap: cap)
            phase = .awaitingApproval
        } catch {
            guard version == revision else { return }
            phase = .failed; problem = RewriteSession.refusal(error)
        }
    }
    func approve(_ approved: Bool) {
        guard approved, phase == .awaitingApproval, let quote else { return }
        self.quote = nil; phase = .generating
        let version = revision; let run = run
        sending = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await run.execute(quote, approved: true) { rows in
                    await self.updateRows(rows, version: version)
                }
                guard self.revision == version else { return }
                self.review(result)
            } catch {
                guard self.revision == version else { return }
                self.phase = Task.isCancelled ? .cancelled : .failed
                self.problem = Task.isCancelled ? "" : RewriteSession.refusal(error)
            }
        }
    }
    private func updateRows(_ rows: [VoiceLabTakeRow], version: Int) {
        guard revision == version else { return }
        for row in rows where !self.rows.contains(where: { $0.id == row.id }) && row.selectable {
            announcement = "Take \(row.index + 1) ready."
        }
        self.rows = rows
    }
    func review(_ result: VoiceLabTakeRunResult, input: VoiceLabTakeInput? = nil) {
        if let input { self.input = input }
        rows = result.rows; bestID = result.best?.id; selectedID = nil; videoChoice = nil
        guard result.end == .completed || result.end == .earlyStop else {
            phase = result.end == .cancelled || result.end == .invalidated ? .cancelled : .failed
            return
        }
        guard let best = result.best else { phase = .nonePassed; announcement = "These takes didn't sound right. Try different wording or re-record."; return }
        selectedID = best.id
        phase = best.fits ? .readyToAccept : .lengthChanged
        announcement = Self.completionAnnouncement(count: rows.count, fittedTake: best.fits ? best.index + 1 : nil)
        if rows.contains(where: { !$0.selectable }) {
            if !best.fits && rows.count == 3 { announcement = "Three takes ready, one failed the speech check." }
            else { announcement += " One failed the speech check." }
        }
    }
    static func completionAnnouncement(count: Int, fittedTake: Int?) -> String {
        if let fittedTake { return "Take \(fittedTake) fits." }
        return count == 3 ? "Three takes ready." : count == 1 ? "One take ready." : "Two takes ready."
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
        audition.stop()
        sending?.cancel(); revision += 1; quote = nil; selectedID = nil; phase = .cancelled
        enqueueCleanup(cancelled: true)
    }
    func invalidate() {
        audition.stop()
        sending?.cancel(); sending = nil; revision += 1
        quote = nil; cost = nil; rows = []; bestID = nil; selectedID = nil; videoChoice = nil; problem = ""; phase = .idle
        input = nil
        enqueueCleanup(cancelled: false)
    }
    private func enqueueCleanup(cancelled: Bool) {
        let previous = cleanup; let run = run
        cleanup = Task {
            await previous?.value
            if cancelled { await run.cancel() } else { await run.invalidate() }
        }
    }
}
