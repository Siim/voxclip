#if DEBUG
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
    @ObservationIgnored private let run: VoiceLabTakeRun
    @ObservationIgnored private let inputsAreCurrent: @MainActor () -> Bool
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var accepting = false
    @ObservationIgnored var publishForTests: (@MainActor (VoiceLabTakeRow, VoiceLabTakeInput, Date) async throws -> (VoiceLabPublishedTake, VoiceConsentRecord))?
    init(run: VoiceLabTakeRun, inputsAreCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.run = run; self.inputsAreCurrent = inputsAreCurrent
    }
    var readyToAccept: Bool { !accepting && inputsAreCurrent() && phase == .readyToAccept && selected?.selectable == true }
    var acceptTitle: String { selected.map { "Use Take \($0.index + 1)" } ?? "Use Take 1" }
    @discardableResult func accept(into editor: EditorModel, at date: Date = Date()) async -> Bool {
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
                if let publishForTests { (published, record) = try await publishForTests(row, input, date) }
                else { (published, record) = try await run.publishForAcceptance(row, input: input, at: date) }
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
            try editor.applyVoiceLab(.accept(segment, assets: assets, voice: voice))
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
        } catch { problem = RewriteSession.refusal(error) }
    }
    func chooseVoice(_ id: String?) {
        guard id == nil || voices.contains(where: { $0.id == id }) else { return }
        invalidate(); selectedVoiceID = id
    }
    func chooseModel(_ id: String?) {
        guard id == nil || models.contains(where: { $0.id == id }) else { return }
        invalidate(); selectedModelID = id
    }
    func prepare(_ input: VoiceLabTakeInput, cap: VoiceLabMonthlyCap? = nil) async {
        guard selectedVoiceID == input.recordID, selectedModelID == input.modelID, canGenerate else { return }
        invalidate(); self.input = input; phase = .preparing
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
        self.rows = rows
    }
    func review(_ result: VoiceLabTakeRunResult, input: VoiceLabTakeInput? = nil) {
        if let input { self.input = input }
        rows = result.rows; bestID = result.best?.id; selectedID = nil; videoChoice = nil
        guard result.end == .completed || result.end == .earlyStop else {
            phase = result.end == .cancelled || result.end == .invalidated ? .cancelled : .failed
            return
        }
        guard let best = result.best else { phase = .nonePassed; return }
        if best.fits { selectedID = best.id; phase = .readyToAccept }
        else { phase = .lengthChanged }
    }
    @discardableResult func select(_ id: UUID) -> Bool {
        guard !accepting, [.lengthChanged, .readyToAccept, .nonePassed].contains(phase),
              let row = rows.first(where: { $0.id == id }), row.selectable else { return false }
        selectedID = id; videoChoice = nil
        phase = row.fits ? .readyToAccept : .lengthChanged
        return true
    }
    @discardableResult func chooseVideo(_ choice: VoiceLabVideoMode) -> Bool {
        guard !accepting, phase == .lengthChanged, selected?.selectable == true, choice == .retimed || choice == .lipsync else { return false }
        videoChoice = choice; phase = .readyToAccept
        return true
    }
    func cancel() {
        sending?.cancel(); revision += 1; quote = nil; selectedID = nil; phase = .cancelled
        enqueueCleanup(cancelled: true)
    }
    func invalidate() {
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
#endif
