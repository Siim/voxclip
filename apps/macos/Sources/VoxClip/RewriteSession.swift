import AppKit
import Observation
import VoxClipCore
import VoxClipMedia

enum RewriteEntry { case selection, context, menu, shortcut, insertWords }
enum RewriteEntryAction { case unavailable, turnOnVoiceLab, openPassage }
enum RewriteEntryPolicy {
    static var buildEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    static func resolve(_ entry: RewriteEntry, enabled: Bool, editable: Bool, selection: Bool, internalBuild: Bool = buildEnabled) -> RewriteEntryAction {
        guard internalBuild, entry != .insertWords else { return .unavailable }
        if !enabled { return entry == .menu && editable ? .turnOnVoiceLab : .unavailable }
        return editable && selection ? .openPassage : .unavailable
    }
}

struct RewriteConnector {
    let connector: any LLMConnector
    let model: String
    let name: String
    let group: String
    let plan: String
}

@MainActor final class ConnectorConsentWait {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var operation: Task<Void, Never>?
    func confirm(_ consent: @escaping @MainActor () async -> Bool) async -> Bool {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                operation = Task { [weak self] in
                    let approved = await consent()
                    self?.finish(approved)
                }
            }
        } onCancel: {
            Task { @MainActor [self] in
                operation?.cancel(); operation = nil; finish(false)
            }
        }
    }
    private func finish(_ approved: Bool) {
        let pending = continuation
        continuation = nil; operation = nil
        pending?.resume(returning: approved)
    }
}

@MainActor final class RewriteApprovalSheet {
    private let alert = NSAlert()
    private let parent: NSWindow
    init(title: String, copy: String, parent: NSWindow) {
        self.parent = parent
        alert.messageText = title; alert.informativeText = copy
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
    }
    func confirm() async -> Bool {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            let response = await alert.beginSheetModal(for: parent)
            return !Task.isCancelled && response == .alertFirstButtonReturn
        } onCancel: {
            Task { @MainActor [self] in
                if alert.window.sheetParent === parent { parent.endSheet(alert.window, returnCode: .abort) }
            }
        }
    }
}

@MainActor @Observable final class RewriteSession {
    let editor: EditorModel
    let project: Project
    let transcript: [TimedWord]
    let source: [TimedWord]
    let scope: VoiceLabOutputScope
    let envelope: AudioEnvelope?
    let connector: RewriteConnector?
    let prices: VoiceLabPriceCatalog?
    let synthesisModel: String?
    let header: String
    private(set) var isOpen = true
    private(set) var isProposing = false
    private(set) var instruction = ""
    private(set) var newWords: String
    private(set) var problem = ""
    private(set) var readiness: ConnectorStatus?
    private(set) var review: RewriteReview?
    private(set) var quote: VoiceRewriteQuote?
    private(set) var estimate: VoiceLabCostPresentation.Kind?
    private(set) var revision = 0
    #if DEBUG
    private(set) var generation: RewriteGenerationSession?
    func configureGeneration(client: ElevenLabsVoiceLab, store: VoiceConsentStore, speaker: VoiceSpeakerCheck) {
        generation?.invalidate()
        let region = client.region
        let run = VoiceLabTakeRun(client: client, store: store, speaker: speaker, dispatchIfCurrent: { [weak self] start in
            try await MainActor.run {
                guard self?.generationIsCurrent(region: region) == true else { throw VoiceLabError.consentRequired }
                try start()
            }
        }) { [weak self] in
            await self?.generationIsCurrent(region: region) ?? false
        }
        generation = RewriteGenerationSession(run: run) { [weak self] in self?.generationIsCurrent(region: region) ?? false }
    }
    private func generationIsCurrent(region: ElevenLabsRegion) -> Bool {
        current && !isProposing && editor.app.bool("voiceLab.providerConsent.elevenlabs") &&
            editor.app.bool("voiceLab.betaNoticeAccepted") &&
            editor.app.string("transcription.elevenlabs.region", fallback: "default") == region.rawValue &&
            (generation?.input == nil || generation?.inputsMatchCurrentSelection == true)
    }
    #endif
    private var shownQuoteID: UUID?
    @ObservationIgnored private let service: VoiceRewriteService?
    @ObservationIgnored private let connectorIsCurrent: @MainActor () -> Bool
    @ObservationIgnored private let consent: @MainActor () async -> Bool
    @ObservationIgnored private var request: VoiceRewriteRequest?
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var sending: Task<Bool, Never>?

    init(editor: EditorModel, range: ClosedRange<Int>, envelope: AudioEnvelope?, connector: RewriteConnector?,
         prices: VoiceLabPriceCatalog? = nil, synthesisModel: String? = nil,
         consent: @escaping @MainActor () async -> Bool = { false }, connectorIsCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.editor = editor; project = editor.project
        transcript = editor.words.map { (word: TimedWord) -> TimedWord in
            var corrected = word
            if word.kind == .word { corrected.text = editor.text(word) }
            return corrected
        }
        source = Array(transcript[range])
        scope = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
        self.envelope = envelope; self.connector = connector; self.prices = prices; self.synthesisModel = synthesisModel
        self.consent = consent; self.connectorIsCurrent = connectorIsCurrent
        service = editor.app.shared.map(VoiceRewriteService.init)
        newWords = source.filter { $0.kind == .word }.map(\.text).joined(separator: " ")
        header = "\(source.filter { $0.kind == .word }.count) words at \(timecode(source.first?.start ?? 0))"
        refreshReview()
    }
    var current: Bool { isOpen && editor.capabilities.edit && editor.project == project && connectorIsCurrent() && editor.app.bool("voiceLab.enabled") }
    var canPropose: Bool { current && !isProposing && !editor.llmRuns.isBusy && quote != nil && shownQuoteID == quote?.id }
    var proposalButton: String {
        guard let connector, let estimate else { return "Rewrite" }
        if connector.group == "cli" { return "Rewrite" }
        if connector.group == "local" { return "Rewrite · No charge" }
        return VoiceLabCostPresentation.buttonTitle("Rewrite", kind: estimate)
    }
    var estimateCopy: String {
        guard let estimate else { return "" }
        switch estimate { case .inline(let text): return text.isEmpty ? "No charge." : text; case .confirm(let text): return text }
    }
    var sendLine: String {
        guard let connector else { return "Choose a connector in Settings → AI." }
        let count: Int = source.filter { $0.kind == .word }.count
        switch connector.group {
        case "apiKey": return "Sends these \(count) words to \(connector.name) with your key."
        case "cli": return "Sends these \(count) words to \(connector.name) with your sign-in. Counts toward your \(connector.plan)."
        default: return "Runs on this Mac. Nothing leaves it."
        }
    }
    var localAction: String? {
        guard let diff = review?.diff, !diff.hunks.isEmpty, diff.hunks.allSatisfy({ $0.kind != .voice }) else { return nil }
        return diff.hunks.contains { $0.kind == .textOnly } ? "Apply Correction" : "Apply Cuts"
    }
    func setInstruction(_ text: String) {
        invalidate()
        instruction = text
        problem = ""
        schedulePreparation()
    }
    private func schedulePreparation() {
        let currentRevision = revision
        preparing = Task { [weak self] in await self?.prepare(revision: currentRevision) }
    }
    func detectConnector() async {
        guard current, let connector else { return }
        let result: ConnectorStatus?
        if let provider = editor.app.providers.first(where: { $0.id == connector.connector.id.rawValue }) {
            result = await editor.app.connectorStatus(provider, using: connector.connector)
        } else { result = await connector.connector.status() }
        guard !Task.isCancelled, current else { return }
        readiness = result
    }
    func setReadinessProblem(_ text: String) { problem = text }
    func prepare(revision expected: Int? = nil) async {
        let expected = expected ?? revision
        guard current, let connector, let service else { return }
        do {
            guard let envelope, let first = source.first(where: { $0.kind == .word }), let last = source.last(where: { $0.kind == .word }) else {
                problem = "Find the original video before rewriting speech. Your edits are saved."; return
            }
            let window = try VoiceLabWindowPlanner.place(project: project, scope: scope, envelope: envelope, firstWordId: first.id, lastWordId: last.id)
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: window)
            let rate = try VoiceLabLengthBudget.rate(transcript: transcript).charactersPerSecond
            let range = try VoiceLabLengthBudget.passage(window: window, transcript: transcript, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, rate: rate)
            let words = source.filter { $0.kind == .word }
            let input = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: words, instruction: instruction,
                language: project.transcript?.language ?? "en", targetSeconds: range.targetSeconds, minChars: range.minChars, maxChars: range.maxChars)
            let prepared = try await service.prepare(input, connector: connector.connector.id, model: connector.model)
            guard !Task.isCancelled, current, revision == expected else { return }
            request = input; quote = prepared
            estimate = VoiceLabCostPresentation.kind(prepared.estimate, isLipSync: false, providerName: connector.name)
        } catch is CancellationError {} catch {
            if current && revision == expected { problem = Self.refusal(error) }
        }
    }
    func markEstimateShown(_ id: UUID) {
        if current && quote?.id == id { shownQuoteID = id }
    }
    @discardableResult func propose(_ approvedQuote: VoiceRewriteQuote, affirmative: Bool) async -> Bool {
        guard canPropose, affirmative, quote == approvedQuote, let input = request, let connector, let service,
              let lease = editor.llmRuns.acquire() else { return false }
        let runs = editor.llmRuns
        let expected = revision
        isProposing = true; shownQuoteID = nil; problem = ""
        let task = Task { [self] () -> Bool in
            defer { runs.release(lease); isProposing = false }
            do {
                if connector.group != "local", !(await ConnectorConsentWait().confirm(consent)) { return false }
                guard !Task.isCancelled, current, revision == expected, quote == approvedQuote, request?.id == input.id else { return false }
                let result = try await service.propose(input, connector: connector.connector, model: connector.model,
                    authorization: VoiceRewriteAuthorization(quote: approvedQuote, approved: true))
                guard !Task.isCancelled, current, revision == expected else { return false }
                newWords = result.proposedText
                quote = nil; estimate = nil; request = nil
                refreshReview()
                return true
            } catch is CancellationError { return false } catch {
                if current && revision == expected { problem = await editor.app.safeError(error, context: "ai:Rewrite") }
                return false
            }
        }
        sending = task
        let result = await task.value
        if current && revision == expected {
            quote = nil; estimate = nil; request = nil
            await prepare(revision: expected)
        }
        return result
    }
    func edit(_ text: String) {
        guard isOpen else { return }
        invalidate(); newWords = text; problem = ""; refreshReview()
        schedulePreparation()
    }
    private func invalidate() {
        #if DEBUG
        generation?.invalidate()
        #endif
        revision += 1; preparing?.cancel(); sending?.cancel()
        quote = nil; estimate = nil; shownQuoteID = nil; request = nil
    }
    private func refreshReview() {
        do { review = try RewriteReview.build(self) }
        catch VoiceLabWordDiffError.tokenLimit { review = nil; problem = VoiceLabPatchBudget.disabledCopy }
        catch { review = nil; problem = Self.refusal(error) }
    }
    @discardableResult func applyLocalChanges() -> Bool {
        guard current, !isProposing, localAction != nil, let review else { return false }
        var commands: [EditCommand] = []
        for hunk in review.diff.hunks {
            if hunk.kind == .cut {
                let ids = hunk.sourceWordIds.filter { !editor.cutWordIDs.contains($0) }
                if !ids.isEmpty { commands.append(.cutSelection(ids: ids)) }
            } else if hunk.kind == .textOnly {
                for (id, text) in zip(hunk.sourceWordIds, hunk.correctedTexts) { commands.append(.correct(id: id, text: text)) }
            }
        }
        return editor.apply(commands, name: localAction ?? "Rewrite")
    }
    func close() {
        guard isOpen else { return }
        isOpen = false; invalidate()
    }
    static func refusal(_ error: any Error) -> String {
        if let geometry = error as? VoiceLabGeometryError, let isStart = geometry.takeEdgeIsStart {
            return "This change is too close to the \(isStart ? "start" : "end") of the take to blend in. Re-record this sentence instead."
        }
        switch error {
        case VoiceLabGeometryError.insertionUnsupported: return "Inserting words isn't available yet. Your edits are saved."
        case VoiceLabGeometryError.roomToneUnavailable: return "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in."
        case is VoiceLabGeometryError: return "This change can't be placed in this take. Your edits are saved."
        case is VoiceLabLengthBudgetError: return "There isn't enough timed speech to estimate this change. Your edits are saved."
        default: return UserMessages.message(error)
        }
    }
}
