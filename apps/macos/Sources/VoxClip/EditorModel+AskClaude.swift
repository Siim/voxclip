import Foundation
import VoxClipCore
import VoxClipMedia

/// One row of an Ask Claude answer (design.md §6.8): the operation, what it shows, and whether it is in the project.
struct AskClaudeRow: Identifiable, Equatable {
    enum Status: Equatable {
        /// In the project: ▶ · Adjust · Undo.
        case applied
        /// Taken out again with its Undo.
        case undone
        /// Needs a paid click first: a voice rewrite or generated music, with its price.
        case paid(price: String)
        /// The editor cannot render it yet (a stretch's speed, translated captions); the row names the package that owes it.
        case later(String)
    }
    let operation: ClipAutopilotOperation
    var status: Status
    let title: String
    let detail: String
    /// "Claude chose the face at the left": the pre-picked answer to an ambiguous instruction.
    let choice: String?
    var id: String { operation.id }
}

/// The last Ask Claude request in this editor and its answer.
@MainActor @Observable final class AskClaudeRun {
    let instruction: String
    let selection: AskClaudeSelection
    let label: String
    var rows: [AskClaudeRow] = []
    var summary = ""
    var repairs: [String] = []
    /// The project before the answer applied; Undo reads the previous values of corrections and ducking from it.
    @ObservationIgnored var base: Project?
    init(instruction: String, selection: AskClaudeSelection, label: String) { self.instruction = instruction; self.selection = selection; self.label = label }
    var appliedCount: Int { rows.filter { $0.status == .applied }.count }
}

/// The editor's Ask Claude state (design.md §6.8): the inline field, the run, the timeline range and the open Adjust row.
@MainActor @Observable final class AskClaudeState {
    /// The field is open on this selection.
    var selection: AskClaudeSelection?
    var label = ""
    var text = ""
    var asking = false
    var progress: String?
    var error: String?
    var run: AskClaudeRun?
    /// The last range dragged on the timeline, in source seconds; ✦ Ask Claude in the timeline toolbar asks about it.
    var timeRange: ClosedRange<Double>?
    /// The row whose Adjust editor is open.
    var adjusting: String?
    /// The panel shows Ask Claude: set when it opens, cleared when another job is picked.
    var inView = false
    let confirmation = ConnectorConfirmation()
    @ObservationIgnored var task: Task<Void, Never>?
    var isOpen: Bool { selection != nil || run != nil }

    /// The example chips under the field: each only fills the field.
    static let chips: [(label: String, text: String)] = [
        ("Bleep it", "Bleep these words"), ("Blur the screen", "Blur the screen"), ("Add a title \u{201C}Day 1\u{201D}", "Add a title \u{201C}Day 1\u{201D}"),
        ("Arrow at the button", "Put an arrow at the button"), ("Emoji reaction", "Add an emoji reaction"), ("Slow-mo this bit", "Slow this bit down"),
        ("Zoom in", "Zoom in on this")]
}

extension EditorModel {
    // MARK: Opening

    /// ✦ Ask Claude is offered when an AI is chosen and the project can change.
    var canAskClaude: Bool { capabilities.edit && capabilities.ai && findConnector != nil && project.transcript != nil }

    /// The selection the selection bar's ✦ Ask Claude asks about: the selected words, in the open clip's tab.
    var askClaudeWordSelection: AskClaudeSelection? {
        guard let first = selectedIDs.first.flatMap(index), let last = selectedIDs.last.flatMap(index), first <= last else { return nil }
        return AskClaudeSelection(scope: .words(first...last), clipID: activeClip?.id)
    }

    /// Opens the inline field on `selection` in the right panel (no pop-up). Nothing is sent until ↵.
    func openAskClaude(_ selection: AskClaudeSelection) {
        guard canAskClaude, let scope = try? AskClaudeScope.resolve(selection, in: project) else { return }
        askClaude.selection = selection
        askClaude.label = askClaudeLabel(scope)
        askClaude.error = nil
        askClaude.adjusting = nil
        askClaude.inView = true
        app.shell.choosePanelJob(.askClaude, for: self)
        if !app.shell.viewerShown { app.shell.toggleViewer() }
        focusedPane = .panel
        paneFocusRequest += 1
        announce("Ask Claude about \(askClaude.label). Type what you want, then press Return.")
    }

    func openAskClaudeOnSelection() { if let selection = askClaudeWordSelection { openAskClaude(selection) } }
    func openAskClaude(clip id: String) { openAskClaude(AskClaudeSelection(scope: .clip(id), clipID: id)) }
    func openAskClaudeOnTimeRange() {
        guard let range = askClaude.timeRange else { return }
        openAskClaude(AskClaudeSelection(scope: .time(range), clipID: activeClip?.id))
    }

    /// "“the invoice for March…”", "Clip 2" or "0:12–0:15".
    func askClaudeLabel(_ scope: AskClaudeScope) -> String {
        if scope.isClip, let id = scope.clipID { return clipNumber(id).map { "Clip \($0)" } ?? "this clip" }
        if !scope.isTime, let range = scope.words {
            let text = range.prefix(8).map { self.text(words[$0]) }.joined(separator: " ")
            return "\u{201C}\(text)\(range.count > 8 ? "\u{2026}" : "")\u{201D}"
        }
        return "\(Self.clock(scope.start))\u{2013}\(Self.clock(scope.end))"
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Stop while Claude works: the request is cancelled and the project stays as it was; the field keeps its text.
    func stopAskClaude() {
        askClaude.task?.cancel()
        askClaude.confirmation.cancel()
        askClaude.asking = false
        askClaude.progress = nil
        announce("Stopped. Nothing changed.")
    }

    func closeAskClaude() {
        askClaude.task?.cancel()
        askClaude.confirmation.cancel()
        askClaude.selection = nil
        askClaude.run = nil
        askClaude.adjusting = nil
        askClaude.asking = false
        askClaude.progress = nil
        askClaude.inView = false
        if app.shell.editor === self { app.shell.choosePanelJob(.captions, for: self) }
    }

    /// The cost line under the field: free on a CLI plan, a local server or Apple on-device; else what the key bills.
    var askClaudeCostLine: String {
        guard let provider = findConnector else { return "" }
        if provider.cliName != nil { return provider.id == "claude-code" ? "Free on your Claude plan" : "Free on your ChatGPT plan" }
        if provider.group == "apiKey" { return "Billed to your \(provider.label) key" }
        return "Free on this Mac"
    }

    // MARK: Asking

    func sendAskClaude() {
        let instruction = askClaude.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, canAskClaude, let selection = askClaude.selection, let shared = app.shared,
              let provider = findConnector, let lease = llmRuns.acquire() else { return }
        let state = askClaude, runs = llmRuns, snapshot = project
        let model = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        let connector = app.connector(provider.id)
        let source = mediaResolved ? URL(fileURLWithPath: project.media.source.absolutePath) : nil
        let hasVideo = project.media.source.video != nil
        let aspect = project.export.aspect.rawValue
        guard let scope = try? AskClaudeScope.resolve(selection, in: project) else { runs.release(lease); return }
        let wordCount = scope.words.map(\.count) ?? 0
        state.error = nil
        state.task?.cancel()
        state.task = Task { [self] in
            defer { state.asking = false; state.progress = nil; runs.release(lease) }
            do {
                guard try await app.authorizeConnectorRequest(provider, connector: connector, action: .askClaude, wordCount: wordCount,
                                                               confirmation: state.confirmation, verb: "Ask Claude",
                                                               isCurrent: { [self] in !isLeaving && project == snapshot }) else { return }
                state.asking = true
                state.progress = "Looking at the picture"
                announce("Asking Claude")
                let detections: [AskClaudeDetection]
                if let source, hasVideo { detections = (try? await ClipEffectVision.detect(source: source, start: scope.start, end: scope.end)) ?? [] }
                else { detections = [] }
                try Task.checkCancellation()
                state.progress = "Claude is working on it"
                let catalog = try LLMCatalog(shared: shared)
                let service = AskClaudeService(runner: LLMRunner(keys: app.secrets, catalog: catalog, log: app.log), prompt: try AskClaudePrompt.load(shared: shared), catalog: catalog)
                let result = try await service.ask(instruction, selection: selection, project: snapshot, detections: detections, aspect: aspect,
                                                   connector: connector, model: model)
                try Task.checkCancellation()
                guard project == snapshot else { state.error = "The project changed while Claude worked. Ask again."; return }
                var answer = result.answer
                state.progress = "Following what moves"
                if let source, hasVideo {
                    for (index, operation) in answer.operations.enumerated() {
                        guard case .effect(var effect) = operation.action, effect.kind.isTracked, effect.tracking != ClipEffect.Tracking.none else { continue }
                        effect.track = (try? await ClipEffectVision.track(source: source, effect: effect)) ?? []
                        answer.operations[index] = ClipAutopilotOperation(id: operation.id, decision: operation.decision, action: .effect(effect), reason: operation.reason)
                    }
                }
                try Task.checkCancellation()
                guard project == snapshot else { state.error = "The project changed while Claude worked. Ask again."; return }
                applyAskClaude(answer, instruction: instruction, selection: selection)
            } catch is CancellationError {} catch LLMError.cancelled {} catch {
                let message = await app.safeError(error, context: "ai:\(provider.label)")
                if !message.isEmpty { state.error = message }
            }
        }
    }

    /// Applies the free operations as one undo step and lists every operation as a row. Paid ones wait for their priced
    /// click; ones the editor cannot render yet are listed as later.
    func applyAskClaude(_ answer: AskClaudeAnswer, instruction: String, selection: AskClaudeSelection) {
        let run = AskClaudeRun(instruction: instruction, selection: selection, label: askClaude.label)
        run.summary = answer.summary
        run.repairs = answer.repairs
        run.base = project
        let paid = Set(answer.paid.map(\.id))
        let free = answer.operations.filter { !paid.contains($0.id) }
        var pending = Set<String>()
        if let applied = try? ClipAutopilotMapping.apply(free, to: project) {
            pending = Set(applied.pending.map(\.id))
            if applied.project != project { replace(applied.project, name: "Ask Claude") }
        } else {
            askClaude.error = "Claude's changes could not be applied. Try different wording."
            return
        }
        run.rows = answer.operations.map { operation in
            let status: AskClaudeRow.Status
            if paid.contains(operation.id) { status = .paid(price: askClaudePrice(operation)) }
            else if pending.contains(operation.id) { status = .later(Self.laterReason(operation)) }
            else { status = .applied }
            return AskClaudeRow(operation: operation, status: status, title: Self.rowTitle(operation), detail: rowDetail(operation),
                                choice: answer.choices[operation.id])
        }
        askClaude.run = run
        askClaude.selection = nil
        askClaude.text = ""
        let count = run.appliedCount
        announce(count == 0 ? "Claude made no changes" : count == 1 ? "Done, 1 change" : "Done, \(count) changes")
    }

    // MARK: Rows

    static func rowTitle(_ operation: ClipAutopilotOperation) -> String {
        switch operation.action {
        case .effect(let effect):
            switch effect.kind {
            case .bleep: return "Bleep"
            case .mute: return "Mute"
            case .blur: return effect.tracking == ClipEffect.Tracking.none ? "Blur" : "Blur, tracked"
            case .pixelate: return effect.tracking == ClipEffect.Tracking.none ? "Pixelate" : "Pixelate, tracked"
            case .title: return "Title"
            case .lowerThird: return "Lower third"
            case .sticker: return "Emoji"
            case .arrow: return "Arrow"
            case .circle: return "Circle"
            case .progress: return "Progress bar"
            case .freeze: return "Freeze frame"
            case .sound: return "Sound: \(effect.sound?.title ?? "effect")"
            }
        case .motion: return "Zoom in"
        case .edit(.correct): return "Fix a word"
        case .edit(.cutSelection): return "Jump cut"
        case .rewrite: return "Rewrite in your voice"
        case .stretch(_, _, _, let rate): return rate < 1 ? "Slow-mo \(Self.rate(rate))" : "Speed up \(Self.rate(rate))"
        case .translateCaptions(_, _, _, let language, _): return "Captions in \(Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language)"
        case .music: return "Music change"
        case .musicDucking: return "Duck the music"
        default: return operation.decision.rawValue.capitalized
        }
    }

    static func rate(_ value: Double) -> String { value == value.rounded() ? "\(Int(value))\u{00D7}" : String(format: "%.2g\u{00D7}", value) }

    func rowDetail(_ operation: ClipAutopilotOperation) -> String {
        let range: String
        switch operation.action {
        case .effect(let effect):
            range = "\(Self.clock(effect.start))\u{2013}\(Self.clock(effect.end))"
            if let text = effect.text { return "\u{201C}\(text)\u{201D} \u{00B7} \(range)" }
            if let ids = effect.wordIds { return "\(ids.count == 1 ? "1 word" : "\(ids.count) words") \u{00B7} \(range)" }
            return range
        case .motion(let cue): return "\(Self.clock(cue.sourceStart))\u{2013}\(Self.clock(cue.sourceEnd))"
        case .edit(.correct(let id, let text)): return "\(index(id).map { self.text(words[$0]) } ?? "") \u{2192} \(text)"
        case .edit(.cutSelection(let ids)): return ids.compactMap { id in index(id).map { self.text(words[$0]) } }.joined(separator: " ")
        case .rewrite(_, let text): return "\u{201C}\(text)\u{201D}"
        case .stretch(_, let start, let end, _): return "\(Self.clock(start))\u{2013}\(Self.clock(end))"
        case .translateCaptions(_, _, _, _, let text): return "\u{201C}\(text)\u{201D}"
        case .music(let cue): return cue.picked.mood
        default: return operation.reason
        }
    }

    static func laterReason(_ operation: ClipAutopilotOperation) -> String {
        switch operation.action {
        case .stretch: return "Speed for part of a clip arrives with Clip controls. Nothing changed."
        case .translateCaptions: return "Translated captions are not rendered yet. Nothing changed."
        case .musicDucking: return "This clip has no music to duck."
        default: return "Not available yet. Nothing changed."
        }
    }

    /// "Voice it · about $0.04": the rewrite's text priced at the text-to-speech rate; Rewrite confirms the exact price.
    func askClaudePrice(_ operation: ClipAutopilotOperation) -> String {
        switch operation.action {
        case .rewrite(_, let text):
            guard let shared = app.shared, let catalog = try? VoiceLabPriceCatalog.load(shared: shared),
                  let estimate = try? VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: "eleven_multilingual_v2",
                                                              units: Double(text.unicodeScalars.count), catalog: catalog),
                  let usd = estimate.usd else { return "Voice it \u{00B7} priced next" }
            return "Voice it \u{00B7} about $\(String(format: "%.2f", NSDecimalNumber(decimal: max(usd, 0.01)).doubleValue))"
        case .music: return "Find music \u{00B7} free library first"
        default: return ""
        }
    }

    /// The row's paid click: a rewrite opens Rewrite on its words with Claude's wording, where the take's exact price is
    /// one more inline click; music opens the Captions panel's Music section with the mood. Nothing is spent here.
    func runPaidAskClaudeRow(_ id: String) {
        guard let run = askClaude.run, let row = run.rows.first(where: { $0.id == id }) else { return }
        switch row.operation.action {
        case .rewrite(let scope, let text):
            runRewrite(scope: scope, instruction: "Say exactly: \(text)", verb: "Rewrite")
        case .music(let cue):
            app.shell.choosePanelJob(.captions, for: self)
            announce("Music: \(cue.picked.mood). Pick a track in Music.")
        default: return
        }
    }

    /// ▶: plays the row's stretch with half a second either side.
    func playAskClaudeRow(_ id: String) {
        guard let row = askClaude.run?.rows.first(where: { $0.id == id }), let range = Self.sourceRange(row.operation, words: words) else { return }
        previewStop = min(sourceDuration, range.upperBound + 0.5)
        seek(source: max(0, range.lowerBound - 0.5))
        preview.play(); isPlaying = preview.isPlaying
    }

    static func sourceRange(_ operation: ClipAutopilotOperation, words: [TimedWord]) -> ClosedRange<Double>? {
        switch operation.action {
        case .effect(let effect): return effect.start...effect.end
        case .motion(let cue): return cue.sourceStart...cue.sourceEnd
        case .stretch(_, let start, let end, _): return start...end
        case .edit(.correct(let id, _)):
            return words.first { $0.id == id }.map { $0.start...$0.end }
        case .edit(.cutSelection(let ids)):
            let found = words.filter { ids.contains($0.id) }
            guard let first = found.first, let last = found.last else { return nil }
            return first.start...last.end
        case .rewrite(.selection(let range), _):
            guard range.lowerBound >= 0, range.upperBound < words.count else { return nil }
            return words[range.lowerBound].start...words[range.upperBound].end
        default: return nil
        }
    }

    // MARK: Undo

    /// Takes one applied row out as its own undo step; the other rows stay.
    func undoAskClaudeRow(_ id: String) {
        guard let run = askClaude.run, let index = run.rows.firstIndex(where: { $0.id == id }), run.rows[index].status == .applied,
              let next = try? undone([run.rows[index].operation], base: run.base, from: project) else { return }
        replace(next, name: "Undo \(run.rows[index].title)")
        run.rows[index].status = .undone
        if askClaude.adjusting == id { askClaude.adjusting = nil }
        announce("Undid \(run.rows[index].title)")
    }

    /// Undo all: every applied row out in one step.
    func undoAllAskClaude() {
        guard let run = askClaude.run else { return }
        let applied = run.rows.filter { $0.status == .applied }
        guard !applied.isEmpty, let next = try? undone(applied.map(\.operation), base: run.base, from: project) else { return }
        replace(next, name: "Undo Ask Claude")
        for index in run.rows.indices where run.rows[index].status == .applied { run.rows[index].status = .undone }
        askClaude.adjusting = nil
        announce("Undid all of Claude's changes")
    }

    /// `project` with `operations` taken out: their effects and zooms removed, corrections, cuts and ducking back to `base`.
    func undone(_ operations: [ClipAutopilotOperation], base: Project?, from project: Project) throws -> Project {
        var next = project
        var effects = Set<String>(), cues = Set<String>()
        for operation in operations {
            switch operation.action {
            case .effect(let effect): effects.insert(effect.id)
            case .motion(let cue): cues.insert(cue.id)
            case .edit(.correct(let id, _)): next.edits.corrections[id] = base?.edits.corrections[id]
            case .edit(.cutSelection(let ids)):
                let before = Set(base?.edits.cutWordIds ?? [])
                next.edits.cutWordIds.removeAll { ids.contains($0) && !before.contains($0) }
            case .musicDucking(let clip, _):
                if var entry = MusicProject.entry(for: clip, in: next), let original = base.flatMap({ MusicProject.entry(for: clip, in: $0) }) {
                    entry.ducking = original.ducking
                    next = try MusicProject.setting(entry, clipId: clip, in: next)
                }
            default: break
            }
        }
        next = try ClipEffects.removing(effects, from: next)
        if !cues.isEmpty { next = try ContextDemoProject.settingMotionCues(next.motionCues.filter { !cues.contains($0.id) }, in: next) }
        return next
    }

    // MARK: Adjust

    /// The effect a row added, as the project has it now (after any Adjust).
    func askClaudeEffect(_ id: String) -> ClipEffect? {
        guard let row = askClaude.run?.rows.first(where: { $0.id == id }), case .effect(let effect) = row.operation.action else { return nil }
        return project.clipEffects.first { $0.id == effect.id }
    }

    /// Replaces an applied effect with `change` applied, as one undo step ("Adjust Blur").
    func adjustAskClaudeEffect(_ id: String, name: String? = nil, _ change: (inout ClipEffect) -> Void) {
        guard let current = askClaudeEffect(id) else { return }
        var effect = current
        change(&effect)
        effect.start = max(0, effect.start)
        if effect.end <= effect.start + 0.05 { effect.end = effect.start + 0.05 }
        if effect.kind == .freeze { effect.end = min(effect.end, effect.start + ClipEffect.maximumFreezeSeconds) }
        if let sound = effect.sound { effect.end = effect.start + sound.durationSeconds }
        if let rect = effect.rect { effect.rect = rect.clamped }
        // A moved or nudged tracked rect holds still until it is tracked again.
        if effect.rect != current.rect || effect.start != current.start || effect.end != current.end, effect.kind.isTracked { effect.track = [] }
        guard effect != current, (try? ClipEffects.validate(effect, projectId: project.id)) != nil,
              let next = try? ClipEffects.adding([effect], to: project) else { return }
        replace(next, name: name ?? "Adjust \(Self.rowTitle(ClipAutopilotOperation(id: id, decision: .overlay, action: .effect(effect), reason: "")))")
    }

    /// Changes what a blur or pixelate follows. Hold still keeps its rect; a face or the moving subject is tracked again on
    /// this Mac (Vision), then stored as one undo step.
    func retrackAskClaudeEffect(_ id: String, tracking: ClipEffect.Tracking) {
        guard let current = askClaudeEffect(id), current.kind.isTracked, current.tracking != tracking else { return }
        guard tracking != ClipEffect.Tracking.none, mediaResolved, project.media.source.video != nil else {
            adjustAskClaudeEffect(id, name: "Hold the blur still") { $0.tracking = tracking; $0.track = [] }
            return
        }
        let source = URL(fileURLWithPath: project.media.source.absolutePath)
        var effect = current
        effect.tracking = tracking
        askClaude.progress = "Following what moves"
        Task { [self] in
            defer { askClaude.progress = nil }
            let track = (try? await ClipEffectVision.track(source: source, effect: effect)) ?? []
            guard askClaudeEffect(id) == current else { return }
            adjustAskClaudeEffect(id, name: "Track the blur") { $0.tracking = tracking; $0.track = track }
        }
    }

    /// The Adjust row's effect, when it has a rect to drag on the viewer.
    var askClaudeAdjustingRect: (id: String, effect: ClipEffect)? {
        guard let id = askClaude.adjusting, let effect = askClaudeEffect(id), effect.kind.usesRect else { return nil }
        return (id, effect)
    }

    /// A press on an effect in the FX lane opens its Adjust editor, from the run that made it.
    func adjustAskClaudeEffect(fromTimeline effectID: String) {
        guard let run = askClaude.run, let row = run.rows.first(where: { row in
            if case .effect(let effect) = row.operation.action { effect.id == effectID } else { false }
        }), row.status == .applied else { return }
        askClaude.adjusting = row.id
        askClaude.inView = true
        app.shell.choosePanelJob(.askClaude, for: self)
    }

    // MARK: Timeline

    /// The FX lane's Ask Claude effects in the open scope, on the timeline's axis, with their labels.
    func timelineEffects(on axis: TimelineAxis) -> [TimelineMotionCue] {
        // Full Take spans the whole recording.
        let bounds = scopeSourceRange ?? 0...max(0, sourceDuration)
        let pieces = timelinePieces
        return ClipEffects.rendered(in: project, clipID: activeClip?.id).flatMap { effect -> [TimelineMotionCue] in
            let label = Self.rowTitle(ClipAutopilotOperation(id: effect.id, decision: .overlay, action: .effect(effect), reason: ""))
            let lower = max(bounds.lowerBound, effect.start), upper = min(bounds.upperBound, effect.end)
            guard upper > lower else { return [] }
            if axis == .source { return [TimelineMotionCue(id: effect.id, range: lower..<upper, label: label)] }
            let cue = MotionCue(id: effect.id, clipID: activeClip?.id ?? "full", sourceStart: lower, sourceEnd: upper)
            return cue.mappedIntervals(in: pieces).map { TimelineMotionCue(id: effect.id, range: $0.edited, label: label) }
        }
    }
}
