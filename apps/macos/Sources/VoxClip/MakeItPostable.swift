import AppKit
import Foundation
import Observation
import VoxClipCore

// ✦ Make it postable (doc/design.md §6.10): one click on a clip lets Claude decide everything at extra high effort (the
// planner, ai.md §16), applies every decision as one undo step within an upfront spend cap, and shows one review with ▶,
// Undo or Change per decision, the post text with Copy, and Export. Questions never block: the plan already follows
// Claude's answer, and the review says "Claude chose X · Change".

/// How clips should be made, as far as Make it postable needs it. **Seam:** track/v2-captions-style adds `ClipStyle`
/// (`project.clipStyle`); when it merges, `EditorModel.makeItStyle` reads it here (captions → `captionPreference`,
/// `music` → `generatedMusic`, `shapes`, `rewording` → `rewrites`). Until then the Auto preset's defaults apply.
struct MakeItStyle: Equatable {
    /// The creator's caption preference; nil fields leave the choice to Claude.
    var captionPreference: ClipAutopilotCaptionPreference?
    /// Eleven Music may generate a track when no free one fits (ClipStyle `music: auto`).
    var generatedMusic = true
    /// Music at all (ClipStyle `music: off` turns it off).
    var music = true
    /// Rewrites in the creator's voice (ClipStyle `rewording: off` turns them off).
    var rewrites = true
    /// The shapes Export renders in one click.
    var shapes: [AspectRatio] = [.landscape, .portrait]

    static let auto = MakeItStyle()
}

/// The outside world a run talks to. The app builds the real one (`MakeItServices.live`); tests and the smoke pass stubs.
struct MakeItServices {
    /// The checked plan for a request (a clip, or a series), at extra high effort through the chosen AI.
    var plan: @MainActor (_ request: ClipAutopilotRequest, _ editor: EditorModel) async throws -> ClipAutopilotSeries
    /// Voices one rewrite within `budget` (USD); returns what happened. The live one drives Rewrite's own session.
    var voice: @MainActor (_ rewrite: MakeItRewriteRequest, _ editor: EditorModel) async -> MakeItRewriteOutcome
    /// Whether a voice can be made at all now: Voice Lab on with an ElevenLabs key (no money is involved in the check).
    var voiceAvailable: @MainActor (_ editor: EditorModel) async -> Bool
}

/// One rewrite for the voice step.
struct MakeItRewriteRequest {
    let range: ClosedRange<Int>
    let text: String
    let clipID: String
    /// What this rewrite may still spend, USD; nil means no paid step may run.
    let budget: Decimal?
}

/// What voicing one rewrite came to.
struct MakeItRewriteOutcome: Equatable {
    enum Result: Equatable {
        /// Applied in the creator's voice; `segments` are the Voice Lab segments it added.
        case voiced(segments: [String])
        /// It stopped before a step past the cap. Paid takes stay in Rewrite.
        case overCap(nextUSD: Decimal?)
        /// Rewrite needs the creator (a voice to make, a consent, a stuck phrase). Its panel stays open.
        case needsYou(String)
        /// No voice can be made here (Voice Lab off, no key): nothing was sent.
        case unavailable(String)
    }
    var result: Result
    /// USD this rewrite spent.
    var spent: Decimal = 0
    /// Phrases whose chosen take only has a join-loudness advisory (autopilot accepts it; the row says so).
    var joinNotes: [Int] = []
}

/// How a decision is taken back on its own (the review's Undo).
enum MakeItInverse {
    case edits([EditCommand])
    case captions(CaptionSettings)
    case motion(id: String, previous: MotionCue?)
    case share(clipID: String, previous: String?)
    case music(clipID: String?, previous: ProjectMusic?)
    case voice(segments: [String])
}

/// Where a decision's Change goes.
enum MakeItChange: Equatable {
    case captions, music, motion, rename, post, hook
    case phrase(ClosedRange<Int>)
    case question(Int)
}

/// One line of the review.
struct MakeItRow: Identifiable, Equatable {
    enum Kind: Equatable { case decision, choice, question, note }
    let id: String
    var kind: Kind = .decision
    var text: String
    var detail: String = ""
    /// ▶ jumps here (source seconds) and plays.
    var play: Double?
    var undoable = false
    var change: MakeItChange?
    var undone = false
    /// A question's other answers.
    var options: [String] = []
}

/// One clip's run, from the click to the review.
@MainActor @Observable final class MakeItRun {
    enum Phase: Equatable {
        case planning, applying, ready, stopped, failed(String)
    }
    let clipID: String
    /// The click's approved ceiling, USD; nil when nothing can cost anything.
    let cap: Decimal?
    let startedAt = Date()
    var phase = Phase.planning
    /// Progress lines, newest last: "Reading the clip…", "Cutting 6 fillers…", "Voicing 2 fixes…", "Picking music…".
    var lines: [String] = []
    var plan: ClipAutopilotPlan?
    var rows: [MakeItRow] = []
    var spent: Decimal = 0
    var editedSeconds = 0.0
    var postText = ""
    var hook = ""
    var copied = false
    var exported: [URL] = []
    /// A question row whose options show.
    var openQuestion: Int?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var inverses: [String: MakeItInverse] = [:]
    @ObservationIgnored var cancelled = false

    init(clipID: String, cap: Decimal?) { self.clipID = clipID; self.cap = cap }

    var running: Bool { phase == .planning || phase == .applying }
    /// What the run may still spend.
    var remaining: Decimal? { cap.map { max(0, $0 - spent) } }
    func line(_ text: String) { if lines.last != text { lines.append(text) } }
}

/// The editor's Make it postable state: the runs by clip, the queue of a series, and the scores the planner gave.
@MainActor @Observable final class MakeItController {
    private(set) var runs: [String: MakeItRun] = [:]
    /// The clip the panel shows.
    var shownClipID: String?
    /// "✦ Make top 3 postable": the clips still waiting, best first.
    private(set) var queue: [String] = []
    /// The series the panel lists while it runs and after: ranked clips.
    private(set) var series: [String] = []
    /// The planner's score and verdict by clip, which rank Suggested and show on its rows.
    private(set) var scores: [String: (score: Int, verdict: ClipAutopilotPlan.Verdict)] = [:]
    /// Whether a voice can be made, checked as the panel or a row shows (no request is made).
    private(set) var voiceReady = false
    @ObservationIgnored var services: MakeItServices?
    @ObservationIgnored var style: MakeItStyle?
    @ObservationIgnored private var queueTask: Task<Void, Never>?

    var shown: MakeItRun? { shownClipID.flatMap { runs[$0] } }
    var active: MakeItRun? { runs.values.first { $0.running } }
    func run(for clipID: String) -> MakeItRun? { runs[clipID] }

    func refreshVoiceReady(_ editor: EditorModel) async {
        let services = services ?? .live
        voiceReady = await services.voiceAvailable(editor)
    }

    func record(score: Int, verdict: ClipAutopilotPlan.Verdict, for clipID: String) { scores[clipID] = (score, verdict) }
    func forget(_ clipID: String) { runs[clipID] = nil; scores[clipID] = nil; if shownClipID == clipID { shownClipID = nil } }
    func insert(_ run: MakeItRun) { runs[run.clipID] = run; shownClipID = run.clipID }
    func setSeries(_ ids: [String]) { series = ids; queue = ids }
    func dequeue() -> String? { queue.isEmpty ? nil : queue.removeFirst() }
    func clearQueue() { queue = []; queueTask?.cancel(); queueTask = nil }
    func holdQueue(_ task: Task<Void, Never>) { queueTask = task }
    /// Waits until the series' queue has run (the smoke and tests).
    func waitForQueue() async { await queueTask?.value }
}

extension EditorModel {
    /// The clip style Make it postable follows (the seam above).
    var makeItStyle: MakeItStyle { makeIt.style ?? .auto }

    // MARK: Price

    /// The click's upfront cap (design.md §6.10): the voice for up to the planner's rewrite limit on this clip's length
    /// (first takes plus the same again for automatic fixes, which Rewrite's own allowance spends), plus a generated track
    /// for the clip's length when the style allows one. Nil when nothing can cost anything: no voice can be made and no
    /// track may be generated.
    func makeItCap(clipID: String) -> Decimal? {
        guard let shared = app.shared, let clip = project.edits.clips.first(where: { $0.id == clipID }),
              let lower = index(clip.startWordId), let upper = index(clip.endWordId), lower <= upper else { return nil }
        let style = makeItStyle
        var total = Decimal(0)
        var priced = false
        if style.rewrites, makeIt.voiceReady, let prompt = try? ClipAutopilotPrompt(shared: shared),
           let catalog = try? VoiceLabPriceCatalog.load(shared: shared) {
            let clipWords = words[lower...upper].filter { $0.kind == .word && !cutWordIDs.contains($0.id) }
            let limit = min(prompt.limits.maxRewrites * prompt.limits.maxRewriteTextWords, clipWords.count)
            let averageCharacters = clipWords.isEmpty ? 6 : Double(clipWords.reduce(0) { $0 + text($1).count }) / Double(clipWords.count)
            let characters = (Double(limit) * (averageCharacters + 1)).rounded(.up)
            if limit > 0, let estimate = try? VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: VoiceLabWordingFit.modelID,
                                                                        units: characters, catalog: catalog), let usd = estimate.usd {
                total += usd * 2
                priced = true
            }
        }
        if style.music, style.generatedMusic, let catalog = try? VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent(ClipAutopilotPricing.musicCatalogPath))),
           let estimate = try? VoiceLabPricing.estimate(operation: ClipAutopilotPricing.musicOperation, model: nil,
                                                         units: editedDuration(clip).rounded(.up), catalog: catalog), let usd = estimate.usd {
            total += usd
            priced = true
        }
        return priced && total > 0 ? total : nil
    }

    /// "✦ Make it postable · up to $0.42", or without an amount when nothing can cost anything.
    func makeItTitle(clipID: String) -> String {
        guard let cap = makeItCap(clipID: clipID) else { return "✦ Make it postable" }
        return "✦ Make it postable · up to " + Self.makeItDollars(cap)
    }

    /// Cents, rounded up: a ceiling never reads lower than it is.
    nonisolated static func makeItDollars(_ usd: Decimal) -> String {
        var value = usd * 100, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .up)
        let cents = NSDecimalNumber(decimal: rounded).intValue
        return String(format: "$%d.%02d", cents / 100, cents % 100)
    }

    // MARK: Entry points

    /// ✦ Make it postable can run on this clip: AI editing is available and the clip has words to keep.
    func canMakeItPostable(_ clipID: String) -> Bool {
        guard capabilities.ai, capabilities.edit, makeIt.active == nil,
              let clip = project.edits.clips.first(where: { $0.id == clipID }),
              let lower = index(clip.startWordId), let upper = index(clip.endWordId), lower <= upper else { return false }
        return words[lower...upper].contains { $0.kind == .word && !cutWordIDs.contains($0.id) }
    }

    /// The click: a suggestion is kept first, in the same undo step as everything the run applies. The click approves
    /// the cap shown on the button; the run never spends past it.
    func makeItPostable(_ clipID: String) {
        guard canMakeItPostable(clipID) else { return }
        let cap = makeItCap(clipID: clipID)
        let run = MakeItRun(clipID: clipID, cap: cap)
        makeIt.insert(run)
        beginUndoGroup("Make it postable")
        if isSuggestion(clipID) { _ = keepForRowAction(clipID) }
        undoGroup?.ownsEdits = false
        _ = setScope(clipID)
        onShowMakeIt?()
        run.task = Task { [weak self] in await self?.perform(run) }
    }

    /// "✦ Make top 3 postable": the best three suggestions by score, one after another, each its own run.
    func makeTopPostable(_ count: Int = 3) {
        let ranked = suggestedClips.prefix(count).map(\.id)
        guard !ranked.isEmpty, makeIt.active == nil, capabilities.ai, capabilities.edit else { return }
        makeIt.setSeries(Array(ranked))
        let task = Task { [weak self] in
            guard let self else { return }
            while let next = makeIt.dequeue() {
                guard !Task.isCancelled, canMakeItPostable(next) else { continue }
                makeItPostable(next)
                await makeIt.run(for: next)?.task?.value
                if makeIt.run(for: next)?.phase == .stopped { makeIt.clearQueue(); break }
            }
        }
        makeIt.holdQueue(task)
    }

    /// Stop: the run ends at its next safe point and keeps what it applied.
    func stopMakeIt() {
        guard let run = makeIt.active else { return }
        run.cancelled = true
        makeIt.clearQueue()
        run.line("Stopping after this step…")
    }

    var canMakeTopPostable: Bool { !suggestedClips.isEmpty && makeIt.active == nil && capabilities.ai && capabilities.edit }

    // MARK: The run

    private func perform(_ run: MakeItRun) async {
        let services = makeIt.services ?? .live
        defer { endUndoGroup(); if run.running { run.phase = .stopped } }
        run.line("Reading the clip…")
        guard let request = makeItRequest(run.clipID) else { run.phase = .failed("This clip has no words to plan."); return }
        let series: ClipAutopilotSeries
        do { series = try await services.plan(request, self) }
        catch is CancellationError { run.phase = .stopped; return }
        catch LLMError.cancelled { run.phase = .stopped; return }
        catch {
            let message = await app.safeError(error, context: "ai:make-it")
            run.phase = .failed(message.isEmpty ? "Claude couldn't plan this clip. Nothing was changed." : message)
            return
        }
        guard let plan = series.plans.first else { run.phase = .failed("Claude found nothing to keep in this clip. Nothing was changed."); return }
        run.plan = plan
        makeIt.record(score: plan.score, verdict: plan.verdict, for: run.clipID)
        guard !makeItStopped(run) else { run.phase = .stopped; return }
        run.phase = .applying
        undoGroup?.ownsEdits = true
        await apply(plan, run: run, services: services)
        guard run.phase == .applying else { return }
        run.phase = makeItStopped(run) ? .stopped : .ready
        run.line(run.cancelled ? "Stopped. What was done is kept." : "Ready to post.")
        announce(run.cancelled ? "Stopped. What was done is kept." : "Ready to post. Score \(plan.score) of 10.")
    }

    /// Stop was pressed, or an undo landed while the run held its step: the run ends at its next safe point.
    private func makeItStopped(_ run: MakeItRun) -> Bool {
        if undoGroup?.interrupted == true { run.cancelled = true }
        return run.cancelled
    }

    /// The planner's request for one clip: its span, the project's edits and the style's caption preference.
    func makeItRequest(_ clipID: String) -> ClipAutopilotRequest? {
        guard let transcript = project.transcript, let clip = project.edits.clips.first(where: { $0.id == clipID }),
              let lower = index(clip.startWordId), let upper = index(clip.endWordId), lower <= upper else { return nil }
        return ClipAutopilotRequest(transcript: transcript, edits: project.edits, mode: .clip(lower...upper),
                                    captionPreference: makeItStyle.captionPreference)
    }

    /// Applies a plan: cuts, captions, zooms and post text in one change; then each rewrite in the creator's voice; then
    /// the music. Every step stops early once the run is cancelled, keeping what is done.
    private func apply(_ plan: ClipAutopilotPlan, run: MakeItRun, services: MakeItServices) async {
        guard let shared = app.shared, let fonts = try? ClipAutopilotFonts.load(shared: shared),
              let operations = try? ClipAutopilotMapping.operations(for: plan, clipID: run.clipID, project: project, fonts: fonts) else {
            run.phase = .failed("This plan no longer fits the clip. Nothing was changed."); return
        }
        let style = makeItStyle
        var rows: [MakeItRow] = []
        let cuts = operations.filter { $0.decision == .cut || $0.decision == .pauseCut }
        if !cuts.isEmpty {
            let fillers = plan.cuts.allSatisfy { $0.kind == .filler } && operations.allSatisfy { $0.decision != .pauseCut }
            run.line(fillers ? "Cutting \(cuts.count) \(cuts.count == 1 ? "filler" : "fillers")…" : "Making \(cuts.count) \(cuts.count == 1 ? "cut" : "cuts")…")
        }
        // The edits the editor applies itself, in one change.
        var next = project
        for operation in operations {
            guard let (inverse, row) = makeItStep(operation, plan: plan, in: &next) else { continue }
            if let inverse { run.inverses[operation.id] = inverse }
            if let row { rows.append(row) }
        }
        replace(next, name: "Make it postable")
        run.editedSeconds = editedDuration(project.edits.clips.first { $0.id == run.clipID })
        run.postText = project.share.captions[run.clipID] ?? ""
        run.hook = plan.hook
        // Rewrites, in the creator's voice, each through Rewrite's own takes.
        let rewrites = operations.filter { $0.decision == .rewrite }
        if !rewrites.isEmpty, !makeItStopped(run) {
            run.line("Voicing \(rewrites.count) \(rewrites.count == 1 ? "fix" : "fixes")…")
            for operation in rewrites where !makeItStopped(run) {
                guard case .rewrite(let scope, let text) = operation.action, case .selection(let range) = scope else { continue }
                rows.append(await voiceStep(operation, range: range, text: text, run: run, services: services, allowed: style.rewrites))
            }
        }
        // Music, once the clip's length is final.
        if let operation = operations.first(where: { $0.decision == .music }), case .music(let cue) = operation.action, !makeItStopped(run) {
            if style.music {
                run.line("Picking music…")
                rows.append(await musicStep(cue, run: run, generated: style.generatedMusic))
            }
        }
        if let hook = operations.first(where: { $0.decision == .hook }), case .hook(_, let text) = hook.action {
            rows.append(MakeItRow(id: hook.id, kind: .choice, text: "Claude chose the hook “\(text)”", detail: "Shown in the first 2 s once title cards ship; copy it into your post meanwhile.", change: .hook))
        }
        for (index, question) in plan.questions.enumerated() {
            rows.append(MakeItRow(id: "question-\(index)", kind: .question, text: question.question, detail: "Claude chose “\(question.answer)”",
                                  change: .question(index), options: question.options.filter { $0 != question.answer }))
        }
        run.rows = rows
        run.editedSeconds = editedDuration(project.edits.clips.first { $0.id == run.clipID })
        run.postText = MusicCredits.postText(project.share.captions[run.clipID] ?? run.postText, music: MusicProject.entry(for: run.clipID, in: project))
    }

    /// One pure operation applied to `project`, with how to take it back and its review row; nil for the operations a
    /// later step owns (rewrites, music, the hook).
    private func makeItStep(_ operation: ClipAutopilotOperation, plan: ClipAutopilotPlan, in project: inout Project) -> (MakeItInverse?, MakeItRow?)? {
        let words = project.transcript?.words ?? []
        func start(_ ids: [String]) -> Double? { ids.compactMap { id in words.first { $0.id == id }?.start }.min() }
        switch operation.action {
        case .edit(let command):
            let before = project
            guard (try? project.applyEditing(command)) != nil, project != before else { return (nil, nil) }
            switch command {
            case .cutSelection(let ids):
                let text = ids.compactMap { id in words.first { $0.id == id }.map { project.edits.corrections[$0.id] ?? $0.text } }.joined(separator: " ")
                let isPause = operation.decision == .pauseCut
                return (.edits([.restoreSelection(ids: ids)]), MakeItRow(id: operation.id, text: isPause ? "Tightened a pause" : "Cut “\(text)”",
                    detail: operation.reason, play: start(ids).map { max(0, $0 - 1.5) } ?? pausePlay(ids.first, in: before), undoable: true))
            case .updateClip(let id, _, _):
                guard let old = before.edits.clips.first(where: { $0.id == id }), let lower = words.firstIndex(where: { $0.id == old.startWordId }),
                      let upper = words.firstIndex(where: { $0.id == old.endWordId }) else { return (nil, nil) }
                let seconds = editedSeconds(of: id, in: project)
                return (.edits([.updateClip(id: id, startIndex: lower, endIndex: upper)]),
                        MakeItRow(id: operation.id, text: "Tightened the clip to \(durationLabel(seconds))", play: words[safe: plan.startWord]?.start, undoable: true))
            case .renameClip(let id, let title):
                let old = before.edits.clips.first { $0.id == id }?.title
                return (.edits([.renameClip(id: id, title: old)]), MakeItRow(id: operation.id, kind: .choice, text: "Claude chose the title “\(title ?? "")”", undoable: true, change: .rename))
            case .addClip(let clip):
                return (.edits([.removeClip(id: clip.id)]), MakeItRow(id: operation.id, text: "Added the clip", undoable: true))
            default:
                return (nil, nil)
            }
        case .captions(let settings, let pendingFont):
            let previous = project.captions
            project.captions = settings
            let styles = app.shared.flatMap { try? CaptionStyleLibrary(shared: $0).styles } ?? []
            let name = styles.first { $0.id == settings.styleId }?.name ?? settings.styleId
            let font = pendingFont.map { " · \($0.family) \($0.weight) once bundled" } ?? ""
            let casing: String = switch plan.captions.textCase { case .upper: "UPPER"; case .lower: "lower"; case .asSaid: "as said" }
            return (.captions(previous), MakeItRow(id: operation.id, kind: .choice,
                text: "Claude chose \(name) captions, \(casing), \(plan.captions.wordsPerCaption) per line\(font)", undoable: true, change: .captions))
        case .motion(let cue):
            let previous = project.motionCues.first { $0.id == cue.id }
            let kept = project.motionCues.filter { $0.id != cue.id }
            guard let changed = try? ContextDemoProject.settingMotionCues(kept + [cue], in: project) else { return (nil, nil) }
            project = changed
            return (.motion(id: cue.id, previous: previous), MakeItRow(id: operation.id, text: "Zoom to \(String(format: "%.2f", cue.keyframes.first?.scale ?? 1))×",
                detail: operation.reason, play: max(0, cue.sourceStart - 1), undoable: true, change: .motion))
        case .shareText(let clipID, let text):
            let previous = project.share.captions[clipID]
            project.share.captions[clipID] = text
            return (.share(clipID: clipID, previous: previous), nil)
        case .rewrite, .music, .hook:
            return nil
        }
    }

    private func pausePlay(_ id: String?, in project: Project) -> Double? {
        guard let id, let pause = pauseIndex[id] else { return nil }
        return max(0, pause.start - 1.5)
    }

    private func editedSeconds(of clipID: String, in project: Project) -> Double {
        project.edits.clips.first { $0.id == clipID }.map { editedDuration($0) } ?? 0
    }

    private func voiceStep(_ operation: ClipAutopilotOperation, range: ClosedRange<Int>, text: String, run: MakeItRun,
                           services: MakeItServices, allowed: Bool) async -> MakeItRow {
        let play = words[safe: range.lowerBound].map { max(0, $0.start - 1) }
        var row = MakeItRow(id: operation.id, text: "Rewrote “\(text)”", detail: operation.reason, play: play, change: .phrase(range))
        guard allowed else { row.kind = .note; row.text = "Claude suggests “\(text)”"; row.detail = "This clip style keeps your words."; return row }
        let outcome = await services.voice(MakeItRewriteRequest(range: range, text: text, clipID: run.clipID, budget: run.remaining), self)
        run.spent += outcome.spent
        switch outcome.result {
        case .voiced(let segments):
            run.inverses[operation.id] = .voice(segments: segments)
            row.undoable = true
            row.text = "Voiced “\(text)” in your voice"
            if !outcome.joinNotes.isEmpty { row.detail = "Join may sound slightly louder · ▶" }
        case .overCap(let next):
            row.kind = .note
            row.text = "Kept your words for “\(text)”"
            row.detail = "The next take (\(next.map(Self.makeItDollars) ?? "price unknown")) would pass this click's cap. Your paid takes stay in Rewrite."
        case .needsYou(let reason):
            row.kind = .note
            row.text = "“\(text)” needs you"
            row.detail = reason
        case .unavailable(let reason):
            row.kind = .note
            row.text = "Claude suggests “\(text)”"
            row.detail = reason
        }
        return row
    }

    private func musicStep(_ cue: ClipAutopilotMusicCue, run: MakeItRun, generated: Bool) async -> MakeItRow {
        let previous = MusicProject.entry(for: run.clipID, in: project)
        var row = MakeItRow(id: "music", kind: .choice, text: "Claude chose music “\(cue.picked.title)”", detail: cue.picked.reason, change: .music)
        guard renderedActiveClipID == run.clipID || setScope(run.clipID), renderedActiveClipID == run.clipID else {
            row.kind = .note; row.detail = "Open the clip, then choose music."; return row
        }
        let panel = musicPanel
        panel.suggest(MusicBrief(mood: cue.picked.mood, query: cue.picked.mood, prompt: cue.picked.prompt, reason: cue.picked.reason), model: self)
        await panel.settled()
        let free = panel.candidates.first { $0.source != .generated }
        var candidate = free
        if candidate == nil, generated, let made = panel.candidates.first(where: { $0.source == .generated }),
           let usd = made.estimate?.usd, let remaining = run.remaining, usd <= remaining {
            candidate = made
        }
        guard let candidate, !makeItStopped(run) else {
            row.kind = .note
            row.text = "No free track fit “\(cue.picked.mood)”"
            row.detail = generated ? "A generated track would pass this click's cap. Change to pick one." : "Change to pick one from the library or your folder."
            return row
        }
        panel.use(candidate, model: self)
        await panel.settled()
        guard let entry = MusicProject.entry(for: run.clipID, in: project), entry != previous else {
            let reason: String = if case .failed(let message) = panel.phase { message } else { "" }
            panel.dismissFailure()
            row.kind = .note; row.detail = (reason.isEmpty ? "The track couldn't be added." : reason) + " Change to try another."; return row
        }
        if candidate.source == .generated { run.spent += candidate.estimate?.usd ?? 0 }
        panel.setGain(-cue.picked.underVoiceDb, model: self)
        run.inverses["music"] = .music(clipID: run.clipID, previous: previous)
        row.text = "Claude chose music “\(entry.title)”" + (candidate.source == .generated ? " (generated)" : "")
        row.detail = [cue.picked.reason, "\(Int(cue.picked.underVoiceDb.rounded())) dB under your voice"].filter { !$0.isEmpty }.joined(separator: " · ")
        row.undoable = true
        return row
    }

    // MARK: The review's actions

    /// ▶: jumps to the decision and plays.
    func makeItPlay(_ row: MakeItRow) {
        guard let time = row.play else { return }
        seek(source: time)
        preview.play(); isPlaying = preview.isPlaying
    }

    /// Undo on one row: takes back that decision only, as its own undo step.
    func makeItUndo(_ rowID: String, in run: MakeItRun) {
        guard let inverse = run.inverses[rowID], let index = run.rows.firstIndex(where: { $0.id == rowID }), !run.rows[index].undone else { return }
        let name = "Undo " + run.rows[index].text
        guard undoInverse(inverse, name: name) else { return }
        run.rows[index].undone = true
        run.inverses[rowID] = nil
        run.editedSeconds = editedDuration(project.edits.clips.first { $0.id == run.clipID })
        announce("Undone.")
    }

    /// Undo all: every decision still applied, taken back as one undo step.
    func makeItUndoAll(_ run: MakeItRun) {
        guard !run.running else { return }
        let ids = run.rows.filter { !$0.undone && run.inverses[$0.id] != nil }.map(\.id)
        beginUndoGroup("Undo Make it postable")
        undoGroup?.ownsEdits = true
        for id in ids.reversed() { makeItUndo(id, in: run) }
        // Inverses without a row (the post text) go too.
        for (id, inverse) in run.inverses { _ = undoInverse(inverse, name: "Undo Make it postable"); run.inverses[id] = nil }
        endUndoGroup()
        makeIt.forget(run.clipID)
        announce("Make it postable undone.")
    }

    private func undoInverse(_ inverse: MakeItInverse, name: String) -> Bool {
        switch inverse {
        case .edits(let commands): return apply(commands, name: name)
        case .captions(let settings):
            var next = project; next.captions = settings; replace(next, name: name); return true
        case .motion(let id, let previous):
            let kept = project.motionCues.filter { $0.id != id } + (previous.map { [$0] } ?? [])
            guard let next = try? ContextDemoProject.settingMotionCues(kept, in: project) else { return false }
            replace(next, name: name); return true
        case .share(let clipID, let previous):
            var next = project; next.share.captions[clipID] = previous; replace(next, name: name); return true
        case .music(let clipID, let previous):
            guard let next = try? MusicProject.setting(previous, clipId: clipID, in: project) else { return false }
            replace(next, name: name); return true
        case .voice(let segments):
            var next = project
            let output = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
            for id in segments { next = (try? VoiceLabEditCommand.setEnabled(segmentID: id, enabled: false).applying(to: next, outputScope: output)) ?? next }
            guard next != project else { return false }
            replace(next, name: name); return true
        }
    }

    /// Change: opens the section that owns the decision.
    func makeItChange(_ change: MakeItChange, run: MakeItRun) {
        switch change {
        case .captions, .music: _ = setScope(run.clipID); onShowPanelJob?(.captions)
        case .motion: _ = setScope(run.clipID); onShowPanelJob?(.motion)
        case .rename: onRenameClip?(run.clipID)
        case .post: copyMakeItPostText(run)
        case .hook:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(run.hook, forType: .string)
            announce("Hook copied.")
        case .phrase(let range):
            if let rewrite, rewrite.isOpen, rewrite.rewriteScope == .selection(range) { onShowPanelJob?(.rewrite); return }
            _ = setScope(run.clipID)
            runRewrite(scope: .selection(range))
        case .question(let index): run.openQuestion = run.openQuestion == index ? nil : index
        }
    }

    /// A question's other answer: this clip's decisions are taken back and Claude plans it again with that answer.
    func makeItAnswer(_ answer: String, question index: Int, run: MakeItRun) {
        guard let plan = run.plan, plan.questions.indices.contains(index), !run.running else { return }
        let question = plan.questions[index].question
        makeItUndoAll(run)
        makeItNote = "For “\(question)” the creator chose “\(answer)”."
        makeItPostable(run.clipID)
    }

    func copyMakeItPostText(_ run: MakeItRun) {
        let text = [run.postText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        run.copied = true
        announce("Post text copied.")
    }

    /// Export: one click, in the style's shapes, with the post text (and the music credit) copied beside it.
    func makeItExport(_ run: MakeItRun) {
        guard canExport, mediaExportable, !exporting else { return }
        let folder = ExportSelection.folder(project.export.folder ?? app.string("export.folder", fallback: "~/Movies/VoxClip"))
        copyMakeItPostText(run)
        beginExport(targets: [.clip(run.clipID)], folder: folder, aspects: makeItStyle.shapes)
    }

    /// The review's headline: "Ready to post · 0:46 · score 8/10".
    func makeItHeadline(_ run: MakeItRun) -> String {
        switch run.phase {
        case .planning: return "Claude is making \(scopeName(run.clipID)) postable…"
        case .applying: return "Applying Claude's decisions…"
        case .stopped: return "Stopped · what was done is kept"
        case .failed: return "Nothing was changed"
        case .ready:
            let score = run.plan.map { " · score \($0.score)/10" } ?? ""
            return "Ready to post · \(durationLabel(run.editedSeconds))" + score
        }
    }

    /// The footer's next step.
    func makeItNextStep(_ run: MakeItRun) -> String {
        switch run.phase {
        case .planning, .applying: return "Next: wait, or Stop to keep what's done."
        case .failed: return "Next: try again, or edit the clip yourself."
        case .stopped, .ready:
            if exporting { return "Next: wait for the export." }
            if !run.exported.isEmpty { return "Next: paste the post text where you post." }
            return "Next: Export. The post text is copied with it."
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - One undo step over a run

/// A run of project changes that undo as one step (`EditorModel.replace`). While `ownsEdits` is false (Make it postable
/// waits for Claude) an edit by the creator closes what the group holds as its own step and goes on as theirs.
@MainActor final class EditorUndoGroup {
    let name: String
    /// The project before the group's first change since it began or last flushed.
    var base: Project?
    var ownsEdits = true
    /// An undo or redo landed while it was open.
    var interrupted = false
    init(name: String) { self.name = name }
}

extension EditorModel {
    func beginUndoGroup(_ name: String) {
        if let open = undoGroup { flush(open) }
        undoGroup = EditorUndoGroup(name: name)
    }
    /// Registers what the group changed as one step, named for it.
    func endUndoGroup() {
        guard let group = undoGroup else { return }
        flush(group)
        undoGroup = nil
    }
    func flush(_ group: EditorUndoGroup) {
        guard let base = group.base, base != project else { group.base = nil; return }
        group.base = nil
        // A run ends in a task, outside any event: the step is its own top-level group.
        let opens = undoManager.map { $0.groupingLevel == 0 } ?? false
        if opens { undoManager?.beginUndoGrouping() }
        undoManager?.registerUndo(withTarget: self) { model in model.replace(base, name: group.name, restoringSnapshot: true) }
        undoManager?.setActionName(group.name)
        if opens { undoManager?.endUndoGrouping() }
        #if DEBUG
        undoSteps += 1
        #endif
    }
}

// MARK: - The live services

extension MakeItServices {
    /// The app's own: the planner through the chosen AI (an API-key send asks inline first, as every send does), and the
    /// voice through Rewrite's session with automatic takes.
    @MainActor static var live: MakeItServices {
        MakeItServices(
            plan: { request, editor in try await editor.makeItPlanLive(request) },
            voice: { rewrite, editor in await MakeItRewriteDriver(editor: editor, request: rewrite).run() },
            voiceAvailable: { editor in
                guard editor.app.voiceLabRewriteEnabled else { return false }
                return await editor.app.providerKeyStore.hasKey(for: "elevenlabs")
            })
    }
}

extension EditorModel {
    /// The planner through the chosen AI, holding the project's AI lease while it runs.
    func makeItPlanLive(_ request: ClipAutopilotRequest) async throws -> ClipAutopilotSeries {
        guard let shared = app.shared, let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) else {
            throw LLMError.noConnector
        }
        let connector = app.connector(provider.id)
        let model = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        guard let lease = llmRuns.acquire() else { throw VoxClipError.providerError("Another AI request on this project is still running. Try again when it finishes.", provider: provider.id) }
        defer { llmRuns.release(lease) }
        let words = request.transcript.words.filter { $0.kind == .word }.count
        guard try await app.authorizeConnectorRequest(provider, connector: connector, action: .findClips, wordCount: words,
                                                      confirmation: sendConfirmation, verb: "Make it postable") else { throw CancellationError() }
        let catalog = LLMCatalog(document: try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))))
        let service = ClipAutopilotService(runner: LLMRunner(keys: app.secrets, catalog: catalog, log: app.log), shared: shared)
        var input = request
        if let note = makeItNote { input.note = note; makeItNote = nil }
        return try await service.plan(input, connector: connector, model: model).series
    }
}
