#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import VoxClipMedia

actor RewriteFixtureConnector: LLMConnector {
    nonisolated let id: ConnectorID
    private(set) var discoveries = 0
    private(set) var statuses = 0
    private(set) var sends = 0
    /// The requests sent, in order.
    private(set) var requests: [LLMRequest] = []
    let failure: Bool
    let hold: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(id: ConnectorID = .ollama, failure: Bool = false, hold: Bool = false) { self.id = id; self.failure = failure; self.hold = hold }
    func status() -> ConnectorStatus { discoveries += 1; statuses += 1; return .ready }
    func knownCLIAuthMethod() async -> String? { "plan" }
    func models(refresh: Bool) -> [LLMModel] {
        discoveries += 1
        return [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128_000, source: .curated)]
    }
    func contextTokens(model: String) -> Int? { discoveries += 1; return 128_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        sends += 1
        requests.append(request)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if failure { throw LLMError.invalidOutput(reason: "Fixture proposal failed.") }
        return RawCompletion(text: RewriteFixtureReply.text(for: request), model: model, stop: .complete)
    }
    func counts() -> (discoveries: Int, sends: Int) { (discoveries, sends) }
    func release() { continuation?.resume(); continuation = nil }
}

/// The fixture connectors' canned Rewrite replies (impl-plan V13). A selection's passage request gets "A clearer passage";
/// a clip's or Full take's `patch_edits` request gets `edits` for its lines: by default one edit that cuts the first word
/// of the first line the request lists.
enum RewriteFixtureReply {
    /// One `[a-b]` line of a request's transcript block, with its words as the model read them.
    struct Line: Sendable {
        let label: String
        let words: [String]
    }
    /// The lines of a `patch_edits` request's transcript block (`formatTranscript`: "[a-b] m:ss text").
    static func lines(of request: LLMRequest) -> [Line] {
        (request.cachedBlock ?? "").split(separator: "\n").compactMap { row -> Line? in
            let parts = row.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let label = parts.first, label.hasPrefix("["), label.hasSuffix("]") else { return nil }
            return Line(label: String(label), words: parts.dropFirst(2).map(String.init))
        }
    }
    /// A `patch_edits` reply with `edits`: (line label, new text, reason).
    static func patch(_ edits: [(line: String, text: String, reason: String)]) -> String {
        let items = edits.map { ["line": $0.line, "text": $0.text, "reason": $0.reason] }
        let data = (try? JSONSerialization.data(withJSONObject: ["edits": items], options: [.sortedKeys])) ?? Data("{\"edits\":[]}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
    static func text(for request: LLMRequest) -> String {
        guard request.tag == "patch-rewrite" else { return "{\"rewrite\":\"A clearer passage\"}" }
        guard let first = lines(of: request).first(where: { $0.words.count > 1 }) else { return patch([]) }
        return patch([(first.label, first.words.dropFirst().joined(separator: " "), "Cut a slip")])
    }
}

@MainActor private final class RewriteTestState {
    var session: RewriteSession?
    var connectorCurrent = true
    var consentCalls = 0
    var beforeDiscovery = false
}

@MainActor private final class HeldRewriteConsent {
    var started = false
    var completed = false
    private var continuation: CheckedContinuation<Bool, Never>?
    func confirm() async -> Bool {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { completed = true; continuation?.resume(returning: true); continuation = nil }
}

@MainActor enum DebugRewrite {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        for action in [ConnectorConsentAction.findClips, .rewrite] {
            for provider in app.providers.filter({ ["anthropic", "claude-code", "codex"].contains($0.id) }) {
                for method in ["plan", "api_key"] {
                    let actual = provider.consentCopy(action: action, wordCount: 7, authMethod: method)
                    let expected: String
                    if provider.group == "apiKey" {
                        expected = action == .rewrite ? "Rewrite sends these 7 words (no audio or video) to \(provider.label) using your API key." : "Find clips sends this project's transcript (7 words, no audio or video) to \(provider.label) using your API key."
                    } else {
                        let name = provider.id == "claude-code" ? "Claude Code" : "Codex"
                        let vendor = provider.id == "claude-code" ? "Anthropic" : "OpenAI"
                        let plan = provider.id == "claude-code" ? "Claude" : "ChatGPT"
                        let first = "VoxClip will run your installed \(name) with your own sign-in. "
                        let second = action == .rewrite ? "These words are sent to \(vendor) " : "The transcript is sent to \(vendor) "
                        let billing = method == "api_key" ? "and billed to the API key \(name) is signed in with." : "and \(action == .rewrite ? "count" : "counts") toward your \(plan) plan's usage."
                        expected = first + second + billing
                    }
                    check("\(provider.id) \(action) \(method) exact action-specific consent", actual == expected)
                }
            }
        }
        let previousVoiceLab = app.bool("voiceLab.enabled")
        defer { app.set("voiceLab.enabled", .bool(previousVoiceLab)) }
        app.set("voiceLab.enabled", .bool(true))
        var project = fixture
        project.media.source.durationSeconds = 100
        project.transcript?.durationSeconds = 100
        project.transcript?.words = (0..<80).map { (index: Int) -> TimedWord in
            let position: Double = Double(index)
            let start: Double = position + 1
            let end: Double = start + 0.4
            return TimedWord(id: "rewrite-\(index)", text: "word\(index)", start: start, end: end)
        }
        project.edits = ProjectEdits()
        let envelope = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000))
        func make(_ fake: RewriteFixtureConnector? = nil, group: String = "local", range: ClosedRange<Int> = 3...5, scope: RewriteScope? = nil,
                  words: [TimedWord]? = nil, clips: [ClipRange] = [], withoutEnvelope: Bool = false, prices: VoiceLabPriceCatalog? = nil, synthesisModel: String? = nil,
                  consent: @escaping @MainActor () async -> Bool = { true }, current: @escaping @MainActor () -> Bool = { true }) -> (EditorModel, RewriteSession) {
            var input = project
            if let words { input.transcript?.words = words }
            input.edits.clips = clips
            if case .clip(let id) = scope { input.edits.activeClipId = id }
            let editor = EditorModel(document: VoxClipDocument(project: input), app: app, preview: DemoPreviewEngine())
            editor.mediaResolved = true; editor.refresh()
            editor.editTimestampForTests = Date(timeIntervalSince1970: 1_798_588_800)
            editor.waveform = WaveformData(fine: envelope.levels)
            let connector = fake.map { RewriteConnector(connector: $0, model: "fixture-local", name: "Fixture", group: group, plan: "ChatGPT plan") }
            let session = RewriteSession(editor: editor, scope: scope ?? .selection(range), envelope: withoutEnvelope ? nil : envelope, connector: connector,
                prices: prices, synthesisModel: synthesisModel, consent: consent, connectorIsCurrent: current)
            editor.rewrite = session
            return (editor, session)
        }
        /// Shows `text` as a selection's reply, as `run` does with the AI's answer.
        func propose(_ session: RewriteSession, _ text: String) throws {
            try session.receivePassage(text)
            session.finishRun(seconds: 1)
        }
        for provider in app.providers.filter({ $0.group == "cli" }) {
            let previousOverride = app.connectorOverride
            let previousConsent = app.bool("llm.cloudConsent.\(provider.id)")
            defer { app.connectorOverride = previousOverride; app.set("llm.cloudConsent.\(provider.id)", .bool(previousConsent)) }
            let fake = RewriteFixtureConnector(id: ConnectorID(rawValue: provider.id)!)
            app.connectorOverride = { _ in fake }
            app.set("llm.cloudConsent.\(provider.id)", .bool(false))
            _ = await app.connectorStatus(provider)
            _ = await app.connectorStatus(provider)
            let ungranted = await fake.counts()
            check("\(provider.id) Find Clips opening and Retry detect before consent without requests", ungranted.discoveries == 2 && ungranted.sends == 0)
            app.set("llm.cloudConsent.\(provider.id)", .bool(true))
            let ready = await app.connectorStatus(provider)
            let grantedStatuses = await fake.statuses
            check("\(provider.id) granted Find Clips still detects readiness", ready == .ready && grantedStatuses == 3)

            let rewriteFake = RewriteFixtureConnector(id: ConnectorID(rawValue: provider.id)!)
            app.set("llm.cloudConsent.\(provider.id)", .bool(false))
            let (editor, session) = make(rewriteFake, group: "cli", consent: { app.bool("llm.cloudConsent.\(provider.id)") })
            defer { editor.close() }
            await session.detectConnector(); await session.detectConnector()
            let prepared = await rewriteFake.counts()
            check("\(provider.id) Rewrite opening and Retry detect without sending", prepared.discoveries == 2 && prepared.sends == 0)
            _ = await session.run()
            let denied = await rewriteFake.counts()
            // A first run that sends nothing closes Rewrite, as Stop does (V15); the user runs it again.
            check("\(provider.id) declined Rewrite sends nothing after detection and closes", denied.discoveries == 2 && denied.sends == 0 && !session.isOpen)
            app.set("llm.cloudConsent.\(provider.id)", .bool(true))
            let (grantedEditor, granted) = make(rewriteFake, group: "cli", consent: { app.bool("llm.cloudConsent.\(provider.id)") })
            defer { grantedEditor.close() }
            _ = await granted.run()
            let rewriteStatuses = await rewriteFake.statuses
            check("\(provider.id) granted Rewrite request follows explicit detection", rewriteStatuses == 3)
        }
        check("text Rewrite needs an editable project and a scope, and no Voice Lab",
              RewriteEntryPolicy.canRun(editable: true, scope: .clip("clip")) && RewriteEntryPolicy.canRun(editable: true, scope: .selection(0...1))
                && !RewriteEntryPolicy.canRun(editable: false, scope: .fullTake) && !RewriteEntryPolicy.canRun(editable: true, scope: nil))
        do {
            let (editor, _) = make()
            defer { editor.close() }
            let shown = EditorPane.order(explorerVisible: true, viewerVisible: true, timelineVisible: true)
            editor.focusedPane = .viewer; editor.movePaneFocus(backward: false, through: shown)
            check("F6 moves from viewer to Rewrite panel", editor.focusedPane == .panel)
            editor.movePaneFocus(backward: false, through: shown)
            check("F6 moves from Rewrite panel to timeline", editor.focusedPane == .timeline)
            editor.movePaneFocus(backward: true, through: shown)
            check("Shift-F6 moves from timeline to Rewrite panel", editor.focusedPane == .panel)
            editor.focusedPane = .transcript
            editor.movePaneFocus(backward: false, through: EditorPane.order(explorerVisible: true, viewerVisible: false, timelineVisible: true))
            check("F6 skips hidden right-column panes", editor.focusedPane == .timeline)
        }

        for correction in [false, true] {
            let (editor, session) = make()
            defer { editor.close() }
            let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
            let manual = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
            defer { manual.close() }
            manual.mediaResolved = true; manual.refresh(); manual.editTimestampForTests = editor.editTimestampForTests
            try propose(session, correction ? "Word3! word4 word5" : "word3 word5")
            check(correction ? "a text-only reply offers Apply 1 Change" : "a cut-only reply offers Apply 1 Change", session.applyTitle == "Apply 1 Change")
            undo.beginUndoGrouping(); let applied = session.applyFreeChanges(); undo.endUndoGrouping()
            if correction { manual.apply(.correct(id: "rewrite-3", text: "Word3!"), name: "Correct spelling") }
            else { manual.apply(.cutSelection(ids: ["rewrite-4"]), name: "Cut selection") }
            let actual = try ProjectJSON.encode(editor.project)
            let expected = try ProjectJSON.encode(manual.project)
            try actual.write(to: directory.appendingPathComponent(correction ? "rewrite-correction.voxclip" : "rewrite-cuts.voxclip"))
            try expected.write(to: directory.appendingPathComponent(correction ? "manual-correction.voxclip" : "manual-cuts.voxclip"))
            check("\(correction ? "correction" : "cut") saved bytes equal manual edit", applied && actual == expected)
            check("\(correction ? "correction" : "cut") is one undo step named for the scope, announced, and closes Rewrite",
                  undo.undoActionName == "Rewrite 3 words" && editor.announcements.last == "Applied 1 change" && !session.isOpen && editor.openRewrite == nil)
            undo.undo()
            check("\(correction ? "correction" : "cut") undoes exactly once without AI metadata", editor.project.edits == project.edits && !undo.canUndo && editor.project.voiceLab == project.voiceLab)
        }
        do {
            var words = project.transcript?.words ?? []
            words[10].text = "Hello world"; words[11].text = "SUNDAY"
            let fake = RewriteFixtureConnector()
            let (editor, session) = make(fake, range: 10...11, words: words)
            defer { editor.close() }
            let original = editor.project
            let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
            let manual = EditorModel(document: VoxClipDocument(project: original), app: app, preview: DemoPreviewEngine())
            defer { manual.close() }
            manual.mediaResolved = true; manual.refresh(); manual.editTimestampForTests = editor.editTimestampForTests
            try propose(session, "hello WORLD, Sunday!")
            check("multi-token whole-item correction offers local acceptance", session.applyTitle != nil)
            undo.beginUndoGrouping(); let applied = session.applyFreeChanges(); undo.endUndoGrouping()
            manual.apply(.correct(id: "rewrite-10", text: "hello WORLD,"), name: "Correct spelling")
            manual.apply(.correct(id: "rewrite-11", text: "Sunday!"), name: "Correct spelling")
            let actual = try ProjectJSON.encode(editor.project)
            let expected = try ProjectJSON.encode(manual.project)
            try actual.write(to: directory.appendingPathComponent("rewrite-multitoken-correction.voxclip"))
            try expected.write(to: directory.appendingPathComponent("manual-multitoken-correction.voxclip"))
            check("multi-token whole-item correction saves identical manual bytes", applied && actual == expected)
            check("whole-item correction preserves source timings and text", editor.words == words)
            undo.undo()
            let counts = await fake.counts()
            check("multi-token corrections undo once without AI calls or metadata", editor.project.edits == original.edits && !undo.canUndo && counts.sends == 0 && editor.project.voiceLab == original.voiceLab)
        }
        let prices = try VoiceLabPriceCatalog(data: Data(contentsOf: app.shared!.root.appendingPathComponent("catalog/voice-lab.json")))
        do {
            let (editor, session) = make(range: 10...30, prices: prices, synthesisModel: "eleven_multilingual_v2")
            defer { editor.close() }
            let words = session.source.enumerated().map { (pair: EnumeratedSequence<[TimedWord]>.Element) -> String in
                pair.offset == 0 || pair.offset == 20 ? "fresh" : pair.element.text
            }
            try propose(session, words.joined(separator: " "))
            check("voice changes never offer local acceptance", session.applyTitle == nil && !session.applyFreeChanges())
            if let review = session.review {
                check("one Core fit line per voice hunk", review.voiceHunks.count == 2 && review.voiceHunks.allSatisfy { $0.meter != nil })
                for hunk in review.voiceHunks {
                    let quoted: String = "“" + hunk.hunk.newTokens.joined(separator: " ") + "”"
                    check("fit line quotes only hunk newTokens", hunk.meter?.copy.hasPrefix(quoted) == true)
                    if let window = hunk.window {
                        let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: .full, window: window)
                        let rate = try VoiceLabLengthBudget.rate(transcript: session.transcript).charactersPerSecond
                        let expected = try VoiceLabFitMeter.measure(text: hunk.patchText!, window: window, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                            rate: rate, newWords: hunk.hunk.newTokens.joined(separator: " "), multipleHunks: true)
                        check("fit uses complete placed patch and lendable silence", expected == hunk.meter)
                    }
                }
                let summary = try VoiceLabDiffSummary.make(hunks: review.hunks, meters: review.voiceHunks.compactMap(\.meter), catalog: prices,
                    model: "eleven_multilingual_v2", patchTexts: review.voiceHunks.map(\.patchText))
                check("summary is Core complete-patch summary", summary == review.summary)
                check("complete placed patch pricing has a real catalogue amount", review.summary?.costEstimate?.usd != nil)
                if case .proposal(let set) = session.task.state {
                    check("each change reads what it removes and inserts (\(set.items.map(\.spoken)))",
                          zip(set.items.map(\.spoken), ["Change 1 of 2: removed word10; inserted fresh", "Change 2 of 2: removed word30; inserted fresh"]).allSatisfy { $0.hasPrefix($1) })
                } else { check("the reply shows a proposal", false) }
            } else { check("voice review exists", false) }
            try propose(session, Array(repeating: "fresh", count: 61).joined(separator: " "))
            check("patch budget uses whole transcript and exact re-record copy", session.review?.budget.copy == VoiceLabPatchBudget.disabledCopy)
        }
        do {
            let (editor, session) = make(range: 10...12, withoutEnvelope: true, prices: prices, synthesisModel: "eleven_multilingual_v2")
            defer { editor.close() }
            try session.receivePassage("Sunday word11 word12")
            check("missing windows never invent a meter or amount", session.review?.summary == nil && session.review?.voiceHunks.allSatisfy { $0.window == nil && $0.patchText == nil && $0.refusal != nil } == true)
            let sent = await session.run()
            check("no connector asks which AI in the panel (R0) and cannot send", session.task.state == .choosingAI && session.sendLine.isEmpty && !sent)
            let (unknownEditor, unknown) = make(range: 10...12, prices: prices, synthesisModel: "unknown-model")
            defer { unknownEditor.close() }
            try unknown.receivePassage("Sunday word11 word12")
            check("unknown synthesis model never invents a price", unknown.review?.summary != nil && unknown.review?.summary?.costEstimate?.usd == nil && unknown.review?.summary?.copy.contains("$") == false)
        }
        do {
            var words = project.transcript?.words ?? []
            words[11].kind = .event; words[11].text = "[laughter]"
            words[12].kind = .unlabeledSpeech; words[12].text = "[unlabeled speech]"
            let (editor, session) = make(range: 10...13, words: words)
            defer { editor.close() }
            try propose(session, "Sunday")
            for label in ["[laughter]", "[unlabeled speech]"] {
                let removed = if case .proposal(let set) = session.task.state { set.items.contains { $0.oldWords.contains(label) } } else { false }
                check("an absorbed \(label) is among the change's removed words", removed)
            }
        }
        for group in ["local", "apiKey", "cli"] {
            for granted in [false, true] {
                // The connector decides how the send presents its cost (C8): Ollama, and Codex signed in on a plan, start at
                // once; OpenAI asks first. Every group asks `consent`, the editor's route to the send authorization.
                let id: ConnectorID = group == "local" ? .ollama : group == "apiKey" ? .openai : .codex
                if group == "cli", let codex = app.providers.first(where: { $0.id == "codex" }) {
                    _ = await app.connectorStatus(codex, using: RewriteFixtureConnector(id: .codex))
                }
                let fake = RewriteFixtureConnector(id: id)
                let probe = RewriteTestState()
                let (editor, session) = make(fake, group: group, consent: {
                    probe.consentCalls += 1
                    let counts1 = await fake.counts()
                    probe.beforeDiscovery = counts1.discoveries == 0 && counts1.sends == 0
                    return granted
                })
                defer { editor.close() }
                let proposed = await session.run()
                let counts = await fake.counts()
                check("\(group) consent \(granted) gates send and releases lease", proposed == granted && counts.sends == (granted ? 1 : 0) && !editor.llmRuns.isBusy)
                check("\(group) consent precedes every discovery and the quote needs none", probe.consentCalls == 1 && probe.beforeDiscovery)
                check("proposals are inert project data", editor.project == project)
                check("\(group) a declined first sheet closes Rewrite silently", granted || (!session.isOpen && editor.announcements.isEmpty))
                let asks = group == "apiKey"
                check("\(group) button is the action, with an ellipsis only when the send asks first", session.proposalButton == (asks ? "Rewrite…" : "Rewrite"))
                if group == "cli" { check("CLI on a plan names the plan", session.sendLine.contains("ChatGPT plan")) }
            }
        }
        for boundary in ["panel", "editor", "leave"] {
            let fake = RewriteFixtureConnector()
            let held = HeldRewriteConsent()
            let (editor, session) = make(fake, group: "cli", consent: { await held.confirm() })
            defer { editor.close() }
            let task = Task { await session.run() }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !held.started && clock.now < deadline { await Task.yield() }
            switch boundary {
            case "panel": editor.closeRewrite(returnFocus: false)
            case "editor": editor.close()
            default: editor.isLeaving = true
            }
            while editor.llmRuns.isBusy && clock.now < deadline { await Task.yield() }
            let counts = await fake.counts()
            check("\(boundary) close releases lease without completing held consent", held.started && !held.completed && !editor.llmRuns.isBusy && counts.discoveries == 0 && counts.sends == 0)
            held.release()
            _ = await task.value
        }
        do {
            let fake = RewriteFixtureConnector(hold: true)
            let (editor, session) = make(fake)
            defer { editor.close() }
            let task = Task { await session.run() }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while await fake.sends == 0 && clock.now < deadline { await Task.yield() }
            check("Rewrite holds the same project lease as Find Clips", editor.llmRuns.isBusy && !editor.capabilities.ai)
            editor.findClips()
            check("Find Clips cannot start while Rewrite holds lease", !editor.finding && editor.findTask == nil)
            editor.closeRewrite(returnFocus: false)
            for _ in 0..<20 { await Task.yield() }
            check("close after dispatch retains lease until fake request stops", editor.llmRuns.isBusy)
            await fake.release()
            _ = await task.value
            check("stopped dispatched request releases lease without late changes", !editor.llmRuns.isBusy && session.changes.isEmpty && editor.project == project)
        }
        for change in ["project", "connector", "close", "leave"] {
            let fake = RewriteFixtureConnector()
            let probe = RewriteTestState()
            let (editor, session) = make(fake, group: "apiKey", consent: {
                guard let session = probe.session else { return false }
                switch change {
                case "project": session.editor.apply(.cutSelection(ids: ["rewrite-4"]), name: "Cut")
                case "connector": probe.connectorCurrent = false
                case "close": session.editor.closeRewrite(returnFocus: false)
                default: session.editor.isLeaving = true
                }
                return true
            }, current: { probe.connectorCurrent })
            probe.session = session
            defer { editor.close() }
            let sent = await session.run()
            let counts = await fake.counts()
            check("\(change) during consent never discovers or sends", !sent && counts.discoveries == 0 && counts.sends == 0 && !editor.llmRuns.isBusy)
            if change == "project" { check("an edit in the scope during consent shows R3", session.isOpen && session.task.state == .changed) }
        }
        do {
            let fake = RewriteFixtureConnector(failure: true)
            let (editor, session) = make(fake)
            defer { editor.close() }
            let sent = await session.run()
            let failed: Bool = { if case .error(.message(let text)) = session.task.state { !text.isEmpty } else { false } }()
            check("failed proposal shows its error in R1x and releases lease", !sent && failed && !editor.llmRuns.isBusy)
            if let lease = editor.llmRuns.acquire() {
                let blocked = await session.run()
                check("Find Clips first blocks Rewrite", !blocked && !session.isProposing)
                editor.llmRuns.release(lease)
            }
            editor.mediaResolved = false
            check("losing media closes and clears the session", editor.rewrite == nil && editor.rewriteScope == nil && !session.isOpen)
        }
        do {
            let previousConnector = app.string("llm.connector")
            let previousModel = app.string("llm.model.ollama")
            let previousConsent = app.bool("llm.cloudConsent.ollama")
            let previousOverride = app.connectorOverride
            let fake = RewriteFixtureConnector(hold: true)
            app.set("llm.connector", .string("ollama")); app.set("llm.model.ollama", .string("fixture-local"))
            app.connectorOverride = { _ in fake }
            defer {
                app.connectorOverride = previousOverride
                app.set("llm.connector", .string(previousConnector)); app.set("llm.model.ollama", .string(previousModel))
                app.set("llm.cloudConsent.ollama", .bool(previousConsent))
            }
            let (editor, session) = make(fake)
            defer { editor.close() }
            editor.findClips()
            // The lease is taken at once; `finding` (the sidebar row) follows only once the route says yes.
            check("real Find Clips entry acquires shared project lease first", editor.llmRuns.isBusy)
            let proposal = await session.run()
            check("Find Clips first refuses Rewrite without a second send", !proposal && !session.isProposing)
            for _ in 0..<5_000 { if await fake.sends > 0 { break }; await Task.yield() }
            let before = await fake.counts()
            check("Find Clips uses fake connector only", before.sends == 1)
            editor.findTask?.cancel(); await fake.release(); await editor.findTask?.value
            check("Find Clips cancellation releases lease and leaves project unchanged", !editor.finding && !editor.llmRuns.isBusy && editor.project == project)
            app.set("llm.cloudConsent.ollama", .bool(true))
            check("persisting connector consent does not close unchanged Rewrite", session.isOpen && session.current)
        }
        for change in ["selection", "close", "leave"] {
            let (editor, session) = make()
            session.close(); editor.rewrite = nil
            editor.selectedWordIDs = ["rewrite-3", "rewrite-4"]
            editor.runRewrite()
            switch change {
            case "selection": editor.selectedWordIDs = ["rewrite-9"]
            case "close": editor.closeRewrite(returnFocus: false)
            default: editor.isLeaving = true
            }
            await editor.rewriteOpenTask?.value
            check("async opening rejects stale \(change)", editor.rewrite == nil)
            editor.close()
        }
        results += await scopeChecks(app: app, project: project, envelope: envelope)
        check("a selection with no video audio says so", RewriteSession.refusal(RewriteSessionError.noSourceAudio) == "Find the original video before rewriting speech. Your edits are saved.")
        check("insertion fallback exact copy", RewriteSession.refusal(VoiceLabGeometryError.insertionUnsupported) == "Inserting words isn't available yet. Your edits are saved.")
        results.append(.equal("room tone fallback exact copy", expected: "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in. Clean audio is not available in this build. Re-record this sentence instead.", actual: RewriteSession.refusal(VoiceLabGeometryError.roomToneUnavailable)))
        check("no speech rate fallback exact copy", RewriteSession.refusal(VoiceLabLengthBudgetError.rateUnavailable) == "There isn't enough timed speech to estimate this change. Your edits are saved.")
        check("placement fallback exact copy", RewriteSession.refusal(VoiceLabGeometryError.reversedWords) == "This change can't be placed in this take. Your edits are saved.")
        check("take start refusal uses Core edge and exact copy", RewriteSession.refusal(VoiceLabGeometryError.seamFadeOutsideTake(isStart: true)) == "This change is too close to the start of the take to blend in. Re-record this sentence instead.")
        check("take end refusal uses Core edge and exact copy", RewriteSession.refusal(VoiceLabGeometryError.seamFadeOutsideTake(isStart: false)) == "This change is too close to the end of the take to blend in. Re-record this sentence instead.")
        results += await directorChecks(app: app, fixture: fixture)
        results += try await keyboardChecks(app: app, fixture: fixture)
        return results
    }
}

extension DebugRewrite {
    /// A clip's and Full take's Rewrite (impl-plan V13) through C1's plan, `PatchRewriteService` and C2's diff, with the
    /// fixture's canned reply that cuts the first word of the first line: the request, the proposal, Apply as one step
    /// named for the scope, and R3 with its way back.
    static func scopeChecks(app: AppModel, project: Project, envelope: AudioEnvelope) async -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        func open(_ scope: RewriteScope, fake: RewriteFixtureConnector) -> (EditorModel, RewriteSession, UndoManager) {
            var input = project
            input.edits.clips = [ClipRange(id: "scope-clip", startWordId: "rewrite-10", endWordId: "rewrite-30")]
            if case .clip(let id) = scope { input.edits.activeClipId = id }
            let editor = EditorModel(document: VoxClipDocument(project: input), app: app, preview: DemoPreviewEngine())
            editor.mediaResolved = true; editor.refresh()
            editor.waveform = WaveformData(fine: envelope.levels)
            let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
            let connector = RewriteConnector(connector: fake, model: "fixture-local", name: "Ollama", group: "local", plan: "")
            let session = RewriteSession(editor: editor, scope: scope, envelope: envelope, connector: connector, consent: { true })
            editor.rewrite = session
            return (editor, session, undo)
        }
        for (scope, name, cut) in [(RewriteScope.clip("scope-clip"), "Rewrite clip 1", "rewrite-10"), (.fullTake, "Rewrite full take", "rewrite-0")] {
            let fake = RewriteFixtureConnector()
            let (editor, session, undo) = open(scope, fake: fake)
            defer { editor.close() }
            let proposed = await session.run()
            let request = await fake.requests.first
            check("\(name) sends one patch_edits request asking Fix mistakes", proposed && request?.tag == "patch-rewrite"
                  && request?.instruction.hasSuffix("Instruction: Fix slips and repeats. Keep my words and my voice; change as little as possible.") == true)
            guard case .proposal(let set) = session.task.state else { check("\(name) shows a proposal", false); continue }
            check("\(name) proposes the reply's cut as one change (\(set.items.map(\.sourceWordIDs)))",
                  set.items.map(\.kind) == [.cut] && set.items.first?.sourceWordIDs == [cut] && session.task.headline.text == "1 change" && session.task.headline.sub == "1 cut")
            check("\(name) offers Apply 1 Change", session.applyTitle == "Apply 1 Change")
            undo.beginUndoGrouping(); let applied = session.applyFreeChanges(); undo.endUndoGrouping()
            check("\(name) applies as one undo step named for the scope", applied && undo.undoActionName == name && editor.cutWordIDs.contains(cut) && !session.isOpen)
        }
        do {
            let fake = RewriteFixtureConnector()
            let (editor, session, undo) = open(.clip("scope-clip"), fake: fake)
            defer { editor.close() }
            _ = await session.run()
            guard case .proposal(let set) = session.task.state else { return results + [.init(name: "the clip's run shows a proposal", passed: false)] }
            func step(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
            step { editor.apply(.cutSelection(ids: ["rewrite-60"]), name: "Cut selection") }
            check("an edit outside the clip leaves the proposal on the new project", session.task.state == .proposal(set) && session.project == editor.project && session.current)
            step { editor.apply(.cutSelection(ids: ["rewrite-20"]), name: "Cut selection") }
            check("an edit inside the clip shows R3 (\(session.task.headline.text))", session.isOpen && session.task.state == .changed && session.task.headline.text == "Clip 1 changed"
                  && session.task.footer.primary?.title == "Rewrite Again" && session.task.footer.link?.title == "Close" && session.applyTitle == nil)
            undo.undo()
            check("undoing back to the proposal's revision shows it again", session.task.state == .proposal(set) && session.current && session.applyTitle == "Apply 1 Change")
        }
        return results
    }
}

/// Keys for the Director scenes and tests: in memory, never the Keychain.
actor DirectorFixtureKeys: ProviderKeyStore {
    private(set) var saved: [String: String] = [:]
    init(_ keys: [String: String] = [:]) { saved = keys }
    func hasKey(for provider: String) -> Bool { !(saved[provider] ?? "").isEmpty }
    func save(_ value: String, for provider: String) { saved[provider] = value }
}

/// One Director scene: the Rewrite job in one state (impl-plan V12m), and the editor it lives in.
struct DirectorScene {
    let name: String
    let task: DirectorTask
    let editor: EditorModel?
}

extension DebugRewrite {
    /// The Rewrite job's states on the Director task, from real sessions over stub connectors: R0 with AIs and with
    /// none, R1 on a selection and on a clip, each R1x, the too-large R1x from real Full take and clip runs, and R3.
    /// Nothing is sent and no setting is written; the app's overrides are put back. Close each scene's editor when done.
    static func directorScenes(app: AppModel, fixture: Project) async -> [DirectorScene] {
        let previousOverride = app.connectorOverride, previousKeys = app.providerKeyStoreOverride
        defer { app.connectorOverride = previousOverride; app.providerKeyStoreOverride = previousKeys }
        let envelope = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 100_000))
        func connector(_ id: ConnectorID, name: String, group: String, model: String) -> RewriteConnector {
            RewriteConnector(connector: ConsentFixtureConnector(id: id), model: model, name: name, group: group, plan: id == .codex ? "ChatGPT plan" : "Claude plan")
        }
        func session(_ id: ConnectorID?, name: String = "", group: String = "local", model: String = "fixture-local") -> (EditorModel, RewriteSession) {
            let editor = DebugConnectorRequests.makeEditor(fixture: fixture, app: app)
            let session = RewriteSession(editor: editor, scope: .selection(3...9), envelope: envelope, connector: id.map { connector($0, name: name, group: group, model: model) })
            editor.rewrite = session
            return (editor, session)
        }
        /// A take of `count` words, 0.5 s apart, with one clip over `clip` open on its tab, and a session on `scope`.
        func scoped(_ scope: RewriteScope, words count: Int = 80, text: @escaping (Int) -> String = { "word\($0)" }, clip: ClosedRange<Int>? = 10...40,
                    on id: ConnectorID = .claudeCode, name: String = "Claude Code", group: String = "cli") -> (EditorModel, RewriteSession) {
            var project = fixture
            project.id = UUID().uuidString.lowercased()
            project.edits = ProjectEdits()
            project.transcript?.words = (0..<count).map { TimedWord(id: "scene-\($0)", text: text($0), start: Double($0) / 2 + 1, end: Double($0) / 2 + 1.4) }
            project.media.source.durationSeconds = Double(count) / 2 + 2
            project.transcript?.durationSeconds = Double(count) / 2 + 2
            if let clip {
                project.edits.clips = [ClipRange(id: "scene-clip", startWordId: "scene-\(clip.lowerBound)", endWordId: "scene-\(clip.upperBound)")]
                if case .clip = scope { project.edits.activeClipId = "scene-clip" }
            }
            let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
            editor.mediaResolved = true; editor.refresh()
            let session = RewriteSession(editor: editor, scope: scope, envelope: nil, connector: connector(id, name: name, group: group, model: "sonnet"))
            editor.rewrite = session
            return (editor, session)
        }
        var scenes: [DirectorScene] = []
        // R0: Claude Code signed in on a plan, Codex signed out, Ollama answering; no API key, so Anthropic offers its field.
        let readiness: [String: ConnectorStatus] = ["claude-code": .ready, "codex": .cliSignedOut, "ollama": .ready, "lmstudio": .notRunning(url: "http://127.0.0.1:1234"), "apple-foundation": .unavailable(reason: "Off")]
        app.connectorOverride = { id in ConsentFixtureConnector(id: ConnectorID(rawValue: id) ?? .ollama, readiness: readiness[id] ?? .cliMissing, authMethod: "claude.ai") }
        app.providerKeyStoreOverride = DirectorFixtureKeys()
        let (chooser, r0) = session(nil)
        await r0.showChooser()
        scenes.append(DirectorScene(name: "r0", task: r0.task, editor: chooser))
        app.connectorOverride = { id in ConsentFixtureConnector(id: ConnectorID(rawValue: id) ?? .ollama, readiness: .cliMissing) }
        let (none, r0none) = session(nil)
        await r0none.showChooser()
        scenes.append(DirectorScene(name: "r0-none", task: r0none.task, editor: none))
        // R1 on Claude Code with a plan: the send went, and it waits for the answer.
        if let claude = app.providers.first(where: { $0.id == "claude-code" }) {
            _ = await app.connectorStatus(claude, using: ConsentFixtureConnector(id: .claudeCode, authMethod: "claude.ai"))
        }
        let (running, r1) = session(.claudeCode, name: "Claude Code", group: "cli", model: "sonnet")
        r1.beginRun(); r1.sendRun()
        scenes.append(DirectorScene(name: "r1", task: r1.task, editor: running))
        // R1 on a clip: "Rewriting clip 1…", the clip's kept words and edited length, and its send line.
        let (clipRunning, r1clip) = scoped(.clip("scene-clip"))
        r1clip.beginRun(); r1clip.sendRun()
        scenes.append(DirectorScene(name: "r1-clip", task: r1clip.task, editor: clipRunning))
        // R1x: each error with its fix.
        let errors: [(String, ConnectorID, String, String, PanelError)] = [
            ("r1x-message", .claudeCode, "Claude Code", "cli", .message(LLMError.timeout.userMessage(label: "Claude Code", feature: .voiceRewrite) ?? "")),
            ("r1x-signed-out", .codex, "Codex", "cli", .signedOut(cli: "Codex", command: "codex login")),
            ("r1x-no-key", .anthropic, "Anthropic", "apiKey", .noKey(provider: "anthropic", name: "Anthropic")),
            ("r1x-not-running", .ollama, "Ollama", "local", .notRunning(server: "Ollama", url: "http://127.0.0.1:11434")),
            ("r1x-refused", .claudeCode, "Claude Code", "cli", .refused),
        ]
        for (name, id, label, group, error) in errors {
            let (editor, failed) = session(id, name: label, group: group, model: id == .anthropic ? "claude-opus-5-5" : "sonnet")
            failed.fail(error)
            scenes.append(DirectorScene(name: name, task: failed.task, editor: editor))
        }
        // R1x over Rewrite's limits, from real runs that C1's plan refuses before anything is sent: a Full take of 3,412
        // words offers Find Clips; a clip of 2,900 long words has only Close.
        let (longTake, tooMany) = scoped(.fullTake, words: 3_412, clip: nil)
        _ = await tooMany.run()
        scenes.append(DirectorScene(name: "r1x-too-many-words", task: tooMany.task, editor: longTake))
        let (longClip, tooMuch) = scoped(.clip("scene-clip"), words: 3_000, text: { "explanation\($0)" }, clip: 50...2_949)
        _ = await tooMuch.run()
        scenes.append(DirectorScene(name: "r1x-too-much-text", task: tooMuch.task, editor: longClip))
        // R3: an edit inside the clip while its proposal was open.
        let (changedEditor, r3) = scoped(.clip("scene-clip"))
        r3.showChanged()
        scenes.append(DirectorScene(name: "r3", task: r3.task, editor: changedEditor))
        return scenes + proposalScenes(app: app, fixture: fixture)
    }

    /// R2, one scene per footer case of design.md R2 with impl-plan item 25 (V15), each a real reply to Rewrite clip 1
    /// read through the passage diff and shown in the transcript: only cuts and fixes; phrases in your voice with Voice
    /// Lab off; f3's Get Price, with Keep All; Make Your Voice; Use Take 1; more than one phrase; over the voice budget;
    /// every change left out; and no changes. Voice Lab's settings are put back, and each scene's change list stops
    /// following them, so it shows its case when drawn.
    static func proposalScenes(app: AppModel, fixture: Project) -> [DirectorScene] {
        let keys = ["voiceLab.enabled", "voiceLab.betaNoticeAccepted", "voiceLab.providerConsent.elevenlabs"]
        let saved = keys.map { app.settings.values[$0] }
        defer { for (key, value) in zip(keys, saved) { app.settings.values[key] = value } }
        let prices = app.shared.flatMap { try? VoiceLabPriceCatalog(data: Data(contentsOf: $0.root.appendingPathComponent("catalog/voice-lab.json"))) }
        let envelope = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000))
        /// Clip 1 over words 10–45 of an 80-word take, one second apart, and the reply `edit` makes of its words.
        func scene(_ name: String, voiceLab: Bool = true, edit: ([String]) -> [String]) -> (EditorModel, RewriteSession) {
            app.settings.values["voiceLab.enabled"] = .bool(voiceLab)
            app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(voiceLab)
            app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(voiceLab)
            var project = fixture
            project.id = UUID().uuidString.lowercased()
            project.edits = ProjectEdits()
            project.transcript?.words = (0..<80).map { TimedWord(id: "r2-\($0)", text: "word\($0)", start: Double($0) + 1, end: Double($0) + 1.4) }
            project.media.source.durationSeconds = 100
            project.transcript?.durationSeconds = 100
            project.edits.clips = [ClipRange(id: "r2-clip", startWordId: "r2-10", endWordId: "r2-45")]
            project.edits.activeClipId = "r2-clip"
            let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
            editor.mediaResolved = true; editor.refresh()
            editor.waveform = WaveformData(fine: envelope.levels)
            let connector = RewriteConnector(connector: ConsentFixtureConnector(id: .claudeCode), model: "sonnet", name: "Claude Code", group: "cli", plan: "Claude plan")
            let session = RewriteSession(editor: editor, scope: .clip("r2-clip"), envelope: envelope, connector: connector,
                                         prices: prices, synthesisModel: "eleven_multilingual_v2")
            editor.rewrite = session
            try? session.receivePassage(edit(session.source.map(\.text)).joined(separator: " "))
            session.finishRun(seconds: 14)
            return (editor, session)
        }
        func replacing(_ words: [String], _ changes: [String: String?]) -> [String] {
            words.compactMap { word in changes.keys.contains(word) ? changes[word] ?? nil : word }
        }
        var made: [(String, EditorModel, RewriteSession)] = []
        func add(_ name: String, _ pair: (EditorModel, RewriteSession)) { made.append((name, pair.0, pair.1)) }
        // Only cuts and fixes: "No AI voice needed. Nothing is sent." and Apply 2 Changes.
        add("r2-free", scene("r2-free") { replacing($0, ["word12": nil, "word20": "Word20"]) })
        // A phrase in your voice with Voice Lab off: Turn On Voice Lab… and Apply 2 Free Changes.
        add("r2-voice-lab-off", scene("r2-voice-lab-off", voiceLab: false) { replacing($0, ["word12": nil, "word20": "Word20", "word30": "fresh"]) })
        // f3: two cuts and a phrase in your voice, "Nothing paid yet.", Keep All and Get Price.
        add("r2-make-takes", scene("r2-make-takes") { replacing($0, ["word12": nil, "word13": nil, "word25": nil, "word30": "fresh"]) })
        // No voice yet: Make Your Voice.
        let noVoice = scene("r2-make-voice") { replacing($0, ["word12": nil, "word30": "fresh"]) }
        try? DebugRewriteGeneration.install("no-voice", in: noVoice.1)
        noVoice.1.showProposal()
        add("r2-make-voice", noVoice)
        // A take passed: Use Take 1.
        let ready = scene("r2-use-take") { words in
            var changes: [String: String?] = ["word12": nil,
                "word30": "This comprehensive demonstration preserves reviewed pronunciation naturally."]
            for index in 31...37 { changes["word\(index)"] = .some(nil) }
            return replacing(words, changes)
        }
        try? DebugRewriteGeneration.install("ready", in: ready.1)
        if let plan = ready.1.takePlan {
            for index in plan.phrases.indices { _ = plan.chooseVideo(.source, phrase: index) }
        }
        ready.1.showProposal()
        add("r2-use-take", ready)
        // Two phrases in your voice (impl-plan item 25): the one-passage line and Apply 1 Free Change.
        add("r2-several-voices", scene("r2-several-voices") { replacing($0, ["word12": nil, "word20": "fresh", "word40": "new"]) })
        // Over the voice budget: the callout and Apply 1 Free Change.
        add("r2-over-budget", scene("r2-over-budget") { words in
            // Fifteen words in a row in your voice, over the 12 of an 80-word take (15 %).
            replacing(words, ["word12": nil]).map { (20...34).contains(Int($0.dropFirst(4)) ?? 0) ? "fresh" : $0 }
        })
        // Every change left out from the list: the note alone.
        let leftOut = scene("r2-nothing-included") { replacing($0, ["word12": nil, "word20": "Word20"]) }
        leftOut.1.review(1, .undo); leftOut.1.review(2, .undo)
        add("r2-nothing-included", leftOut)
        // No changes: "No changes needed", the Ask field and Ask for Something Else.
        add("r2-no-changes", scene("r2-no-changes") { $0 })
        // Ask again over a change edited in its popover: "Discard these 2 changes?" in the footer's place, Keep Working
        // (the keyboard's answer) and Discard Changes (84384e1d, inline, not an alert).
        let discard = scene("r2-discard") { replacing($0, ["word12": nil, "word20": "Word20"]) }
        if discard.0.editChange(2, text: "Fresh") { discard.1.task.contextAction?.perform() }
        add("r2-discard", discard)
        // The scenes keep what they show once the settings are put back.
        for (_, _, session) in made { session.proposalObservation += 1 }
        return made.map { DirectorScene(name: $0.0, task: $0.2.task, editor: $0.1) }
    }

    /// The scene runner's checks on one scene laid out in `host`: every action the task offers is drawn, and no button
    /// it draws is disabled (design.md §6.3.4: no disabled buttons).
    static func directorSceneChecks(_ scene: DirectorScene, host: NSView, width: Int) -> [DebugUISuite.Result] {
        let texts = DebugRightColumn.texts(in: host)
        let buttons = texts.filter { $0.key.hasPrefix("director.button.") }
        // A question stands in the footer's place with its two answers.
        let answers: [PanelAction?] = scene.task.confirm.map { [$0.confirm, $0.cancel] } ?? [scene.task.footer.link, scene.task.footer.primary]
        let actions: [PanelAction?] = [scene.task.close, scene.task.contextAction, scene.task.headline.stop] + answers
        var expected: [PanelAction] = actions.compactMap { $0 }
        for case .chooser(_, let saveKey?) in scene.task.cards { expected.append(saveKey) }
        let drawn = expected.allSatisfy { buttons["director.button.\($0.id)"] == $0.title }
        let disabled = buttons.filter { $0.value.hasPrefix(DirectorPanel.disabledPrefix) }.map(\.key).sorted()
        // R2: every change has its row, named "Change {i} of {c}: …" as the transcript's rotor names it (design.md §6.3.5).
        var rows: [DebugUISuite.Result] = []
        for case .changes(let set) in scene.task.cards {
            let named = set.items.allSatisfy { texts["director.change.\($0.ordinal)"] == $0.spoken && $0.spoken.hasPrefix("Change \($0.ordinal) of \(set.items.count): ") }
            rows.append(.init(name: "v2-rewrite-\(scene.name) at \(width) draws a row per change named for its ordinal", passed: named && !set.items.isEmpty))
        }
        return rows + [
            .init(name: "v2-rewrite-\(scene.name) at \(width) draws every action of its task (\(expected.map(\.title)))", passed: drawn),
            .init(name: "v2-rewrite-\(scene.name) at \(width) shows no disabled button (\(disabled))", passed: disabled.isEmpty && !buttons.isEmpty),
            .init(name: "v2-rewrite-\(scene.name) at \(width) shows its headline", passed: texts["director.headline"] == scene.task.headline.text),
            .init(name: "v2-rewrite-\(scene.name) at \(width) shows its question, if it asks one", passed: texts["director.question"] == scene.task.confirm?.question),
        ]
    }

    /// The Director scenes laid out offscreen at the panel body's 404 and the narrowest column's 300, with the checks
    /// above, and R1's and R1x's announcements.
    static func directorChecks(app: AppModel, fixture: Project) async -> [DebugUISuite.Result] {
        let scenes = await directorScenes(app: app, fixture: fixture)
        defer { scenes.forEach { $0.editor?.close() } }
        var results: [DebugUISuite.Result] = []
        for scene in scenes {
            for width in [404, 300] {
                let host = NSHostingView(rootView: DirectorPanel(task: scene.task).frame(width: CGFloat(width), height: 265).environment(app))
                host.frame = CGRect(x: 0, y: 0, width: width, height: 265)
                host.layoutSubtreeIfNeeded()
                results += directorSceneChecks(scene, host: host, width: width)
            }
        }
        let announced = Dictionary(scenes.compactMap { scene in scene.editor.map { (scene.name, $0.announcements) } }, uniquingKeysWith: { first, _ in first })
        results.append(.init(name: "R1 announces \"Rewriting these words\" once", passed: announced["r1"] == ["Rewriting these words"]))
        results.append(.init(name: "R1x announces its headline", passed: announced["r1x-refused"] == ["Couldn't rewrite these words."]))
        return results
    }

    /// The Rewrite job's keyboard in an offscreen window like the main window (V12m review, V13): ⇧⌘R in the transcript
    /// runs at once and leaves the keyboard there (design.md §10), where Esc stops R1; with the keyboard moved into R1
    /// (F6), Esc (and ⌘., the same action) stops it there; a reply that arrives while the user works in the transcript
    /// leaves the keyboard there. A held stub connector on this Mac answers; the settings and the override are put back.
    static func keyboardChecks(app: AppModel, fixture: Project) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let keys = ["llm.connector", "llm.model.ollama", "voiceLab.enabled"]
        let saved = keys.map { app.settings.values[$0] }, previousOverride = app.connectorOverride
        defer { for (key, value) in zip(keys, saved) { app.settings.values[key] = value }; app.connectorOverride = previousOverride }
        app.settings.values["llm.connector"] = .string("ollama")
        app.settings.values["llm.model.ollama"] = .string("fixture-local")
        app.settings.values["voiceLab.enabled"] = .bool(true)
        var fake = RewriteFixtureConnector(id: .ollama, hold: true)
        app.connectorOverride = { _ in fake }
        var project = fixture
        project.id = UUID().uuidString.lowercased()
        project.edits = ProjectEdits()
        project.transcript?.words = (0..<80).map { TimedWord(id: "keyboard-\($0)", text: "word\($0)", start: Double($0) + 1, end: Double($0) + 1.4) }
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        guard let editor = shell.editor else { return [.init(name: "the Rewrite keyboard checks open an editor", passed: false)] }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))

        let size = NSSize(width: 1280, height: 800)
        let window = MainWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = DebugShellWindowController(window: window, shell: shell)
        defer { window.close(); withExtendedLifetime(controller) {} }
        // The editor attached before this window: it is the editor's window, as the main window is (sheets, the transcript).
        editor.window = window
        window.appearance = NSAppearance(named: .darkAqua)
        EditorShellController.prepare(window)
        let host = NSHostingController(rootView: WorkspaceView(shell: shell).environment(app).sceneAccent())
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        shell.windowWidth = size.width
        window.orderBack(nil)
        // Key, as the editor's window is while the user types; SwiftUI focus in a background window differs.
        window.makeKey()

        /// The right column's hosting view.
        func right() -> NSView? {
            func find(_ view: NSView) -> NSView? {
                String(describing: type(of: view)).contains("RightColumnHost") ? view : view.subviews.lazy.compactMap(find).first
            }
            return window.contentView.flatMap(find)
        }
        func responder() -> String { window.firstResponder.map { String(describing: type(of: $0)) } ?? "none" }
        /// The task's panel itself has the keyboard: the right column holds it, but no text field does.
        func paneHasKeyboard() -> Bool { !(window.firstResponder is NSTextView) && (window.firstResponder as? NSView).map { right().map($0.isDescendant) ?? false } ?? false }
        func until(_ done: () -> Bool) async throws { for _ in 0..<80 where !done() { try await Task.sleep(for: .milliseconds(25)) } }
        func sends() async -> Int { await fake.counts().sends }
        /// Selects words 3–5 in the transcript and presses ⇧⌘R there, then waits for the held send.
        func open() async throws -> RewriteSession? {
            _ = focusTranscript(in: window)
            editor.selectedWordIDs = Set(editor.words[3...5].map(\.id))
            let before = await sends()
            guard let text = window.firstResponder as? TranscriptNSTextView,
                  let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: "R", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15) else { return nil }
            text.keyDown(with: key)
            await editor.rewriteOpenTask?.value
            for _ in 0..<80 { if await sends() > before { break }; try await Task.sleep(for: .milliseconds(25)) }
            return editor.openRewrite
        }
        /// Esc, as the key, to the window's first responder.
        func escapeKey() {
            let escape = String(UnicodeScalar(UInt8(27)))
            if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: escape, charactersIgnoringModifiers: escape, isARepeat: false, keyCode: 53) {
                window.sendEvent(key)
            }
        }
        try await until { right() != nil && focusTranscript(in: window) }

        guard let first = try await open() else { return results + [.init(name: "⇧⌘R opens Rewrite in the window", passed: false)] }
        check("⇧⌘R in the transcript runs at once and leaves the keyboard there (first responder \(responder()))",
              first.task.state == .running && window.firstResponder is TranscriptNSTextView)
        escapeKey()
        check("Esc in the transcript stops R1 and closes Rewrite", !first.isOpen && editor.openRewrite == nil)
        await fake.release()
        await first.actionTask?.value

        fake = RewriteFixtureConnector(id: .ollama, hold: true)
        guard let second = try await open() else { return results + [.init(name: "⇧⌘R opens Rewrite again", passed: false)] }
        editor.focusedPane = .panel
        editor.paneFocusRequest += 1
        try await until { paneHasKeyboard() }
        check("F6 moves the keyboard into R1 (first responder \(responder()))", second.task.state == .running && paneHasKeyboard())
        window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        check("Esc in R1 stops it and closes Rewrite", !second.isOpen && editor.openRewrite == nil)
        await fake.release()
        await second.actionTask?.value

        fake = RewriteFixtureConnector(id: .ollama, hold: true)
        guard let third = try await open() else { return results + [.init(name: "⇧⌘R opens Rewrite a third time", passed: false)] }
        await fake.release()
        await third.actionTask?.value
        // The passage panel's own work (detection) runs as it appears; give it the time it takes.
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(25)) }
        let proposed = if case .proposal = third.task.state { true } else { false }
        check("a reply that arrives while the user works in the transcript leaves the keyboard there (first responder \(responder()))",
              proposed && window.firstResponder is TranscriptNSTextView)
        editor.closeRewrite(returnFocus: false)

        // R2 with the keyboard in the panel (design.md §10, V15 review): Return edits the focused change in the transcript
        // and never runs the footer's primary; ⌘Return runs it. Full take's fixture reply cuts a word: Apply 1 Change.
        func transcript() -> TranscriptNSTextView? {
            func find(_ view: NSView) -> TranscriptNSTextView? { view as? TranscriptNSTextView ?? view.subviews.lazy.compactMap(find).first }
            return window.contentView.flatMap(find)
        }
        func returnKey(_ flags: NSEvent.ModifierFlags) {
            if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                window.sendEvent(key)
            }
        }
        fake = RewriteFixtureConnector(id: .ollama)
        _ = focusTranscript(in: window)
        editor.selectedWordIDs = []
        editor.runRewrite()
        await editor.rewriteOpenTask?.value
        guard let fourth = editor.openRewrite else { return results + [.init(name: "⇧⌘R opens Rewrite on Full take", passed: false)] }
        await fourth.actionTask?.value
        let before = editor.project
        let applies = fourth.task.footer.primary?.id == "apply"
        editor.focusedPane = .panel
        editor.paneFocusRequest += 1
        try await until { paneHasKeyboard() }
        returnKey([])
        try await until { transcript()?.changePopoverVisible == true }
        check("Return on R2's change list edits the focused change and applies nothing (first responder \(responder()))",
              applies && transcript()?.changePopoverVisible == true && editor.project == before && fourth.isOpen)
        transcript()?.hideChangePopover()
        editor.focusedPane = .panel
        editor.paneFocusRequest += 1
        try await until { paneHasKeyboard() }
        returnKey(.command)
        try await until { !fourth.isOpen }
        check("⌘Return in R2's panel runs its primary, Apply", applies && !fourth.isOpen && editor.project != before)
        editor.closeRewrite(returnFocus: false)
        return results
    }

    /// `-sceneAudit`: each Director scene in the panel body's 404 × 265 and at the 300 minimum, named v2-rewrite-*.
    static func directorCaptures(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        let scenes = await directorScenes(app: app, fixture: fixture)
        defer { scenes.forEach { $0.editor?.close() } }
        for scene in scenes {
            for width in [404, 300] {
                let name = "v2-rewrite-\(scene.name)" + (width == 404 ? "" : "-\(width)")
                try await DebugUISuite.snapshot(DirectorPanel(task: scene.task).environment(app), name: name,
                                                size: NSSize(width: width, height: 265), appearance: .darkAqua, directory: directory)
            }
        }
        return [.init(name: "captured \(scenes.count * 2) v2-rewrite scenes", passed: true)]
    }
}
#endif
