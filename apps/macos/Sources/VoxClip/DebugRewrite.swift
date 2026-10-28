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
    let failure: Bool
    let hold: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(id: ConnectorID = .ollama, failure: Bool = false, hold: Bool = false) { self.id = id; self.failure = failure; self.hold = hold }
    func status() -> ConnectorStatus { discoveries += 1; statuses += 1; return .ready }
    func models(refresh: Bool) -> [LLMModel] {
        discoveries += 1
        return [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128_000, source: .curated)]
    }
    func contextTokens(model: String) -> Int? { discoveries += 1; return 128_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        sends += 1
        if hold { await withCheckedContinuation { continuation = $0 } }
        if failure { throw LLMError.invalidOutput(reason: "Fixture proposal failed.") }
        return RawCompletion(text: "{\"rewrite\":\"A clearer passage\"}", model: model, stop: .complete)
    }
    func counts() -> (discoveries: Int, sends: Int) { (discoveries, sends) }
    func release() { continuation?.resume(); continuation = nil }
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
        func make(_ fake: RewriteFixtureConnector? = nil, group: String = "local", range: ClosedRange<Int> = 3...5,
                  words: [TimedWord]? = nil, withoutEnvelope: Bool = false, prices: VoiceLabPriceCatalog? = nil, synthesisModel: String? = nil,
                  consent: @escaping @MainActor () async -> Bool = { false }, current: @escaping @MainActor () -> Bool = { true }) -> (EditorModel, RewriteSession) {
            var input = project
            if let words { input.transcript?.words = words }
            let editor = EditorModel(document: VoxClipDocument(project: input), app: app, preview: DemoPreviewEngine())
            editor.mediaResolved = true; editor.refresh()
            editor.editTimestampForTests = Date(timeIntervalSince1970: 1_798_588_800)
            editor.waveform = WaveformData(fine: envelope.levels)
            let connector = fake.map { RewriteConnector(connector: $0, model: "fixture-local", name: "Fixture", group: group, plan: "ChatGPT plan") }
            let session = RewriteSession(editor: editor, range: range, envelope: withoutEnvelope ? nil : envelope, connector: connector,
                prices: prices, synthesisModel: synthesisModel, consent: consent, connectorIsCurrent: current)
            editor.rewrite = session; editor.rewriteRange = range
            return (editor, session)
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
            check("\(provider.id) Find Clips opening and Retry perform zero pre-consent probes", ungranted.discoveries == 0)
            app.set("llm.cloudConsent.\(provider.id)", .bool(true))
            let ready = await app.connectorStatus(provider)
            let grantedStatuses = await fake.statuses
            check("\(provider.id) granted Find Clips probes once", ready == .ready && grantedStatuses == 1)

            let rewriteFake = RewriteFixtureConnector(id: ConnectorID(rawValue: provider.id)!)
            app.set("llm.cloudConsent.\(provider.id)", .bool(false))
            let (editor, session) = make(rewriteFake, group: "cli", consent: { app.connectorProbeAllowed(provider) })
            defer { editor.close() }
            await session.prepare(); await session.prepare()
            let prepared = await rewriteFake.counts()
            check("\(provider.id) Rewrite opening and estimate Retry perform zero probes", prepared.discoveries == 0)
            if let quote = session.quote {
                session.markEstimateShown(quote.id)
                _ = await session.propose(quote, affirmative: true)
            }
            let denied = await rewriteFake.counts()
            check("\(provider.id) ungranted Rewrite never probes or sends", denied.discoveries == 0 && denied.sends == 0)
            app.set("llm.cloudConsent.\(provider.id)", .bool(true))
            await session.prepare()
            if let quote = session.quote {
                session.markEstimateShown(quote.id)
                _ = await session.propose(quote, affirmative: true)
            }
            let rewriteStatuses = await rewriteFake.statuses
            check("\(provider.id) granted Rewrite probes once", rewriteStatuses == 1)
        }
        for entry in [RewriteEntry.selection, .context, .menu, .shortcut, .insertWords] {
            check("release hides Rewrite entry \(entry)", RewriteEntryPolicy.resolve(entry, enabled: true, editable: true, selection: true, internalBuild: false) == .unavailable)
            let off = RewriteEntryPolicy.resolve(entry, enabled: false, editable: true, selection: true)
            check("Voice Lab off only offers one-time menu flow \(entry)", off == (entry == .menu ? .turnOnVoiceLab : .unavailable))
        }
        check("Insert Words unavailable even in DEBUG", RewriteEntryPolicy.resolve(.insertWords, enabled: true, editable: true, selection: true) == .unavailable)
        do {
            let (editor, _) = make()
            defer { editor.close() }
            let previousViewer = app.shell.viewerVisible
            defer { app.shell.viewerVisible = previousViewer }
            app.shell.viewerVisible = true
            editor.focusedPane = .viewer; editor.movePaneFocus(backward: false)
            check("F6 moves from viewer to Rewrite panel", editor.focusedPane == .panel)
            editor.movePaneFocus(backward: false)
            check("F6 moves from Rewrite panel to timeline", editor.focusedPane == .timeline)
            editor.movePaneFocus(backward: true)
            check("Shift-F6 moves from timeline to Rewrite panel", editor.focusedPane == .panel)
            app.shell.viewerVisible = false
            editor.focusedPane = .transcript; editor.movePaneFocus(backward: false)
            check("F6 skips hidden right-column panes", editor.focusedPane == .timeline)
        }

        for correction in [false, true] {
            let (editor, session) = make()
            defer { editor.close() }
            let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
            let manual = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
            defer { manual.close() }
            manual.mediaResolved = true; manual.refresh(); manual.editTimestampForTests = editor.editTimestampForTests
            session.edit(correction ? "Word3! word4 word5" : "word3 word5")
            check(correction ? "text-only diff offers Apply Correction" : "cut-only diff offers Apply Cuts", session.localAction == (correction ? "Apply Correction" : "Apply Cuts"))
            undo.beginUndoGrouping(); let applied = session.applyLocalChanges(); undo.endUndoGrouping()
            if correction { manual.apply(.correct(id: "rewrite-3", text: "Word3!"), name: "Correct spelling") }
            else { manual.apply(.cutSelection(ids: ["rewrite-4"]), name: "Cut selection") }
            let actual = try ProjectJSON.encode(editor.project)
            let expected = try ProjectJSON.encode(manual.project)
            try actual.write(to: directory.appendingPathComponent(correction ? "rewrite-correction.voxclip" : "rewrite-cuts.voxclip"))
            try expected.write(to: directory.appendingPathComponent(correction ? "manual-correction.voxclip" : "manual-cuts.voxclip"))
            check("\(correction ? "correction" : "cut") saved bytes equal manual edit", applied && actual == expected)
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
            session.edit("hello WORLD, Sunday!")
            check("multi-token whole-item correction offers local acceptance", session.localAction == "Apply Correction")
            undo.beginUndoGrouping(); let applied = session.applyLocalChanges(); undo.endUndoGrouping()
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
            session.edit(words.joined(separator: " "))
            check("voice changes never offer local acceptance", session.localAction == nil && !session.applyLocalChanges())
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
                let summary = try VoiceLabDiffSummary.make(diff: review.diff, meters: review.voiceHunks.compactMap(\.meter), catalog: prices,
                    model: "eleven_multilingual_v2", patchTexts: review.voiceHunks.map(\.patchText))
                check("summary is Core complete-patch summary", summary == review.summary)
                check("complete placed patch pricing has a real catalogue amount", review.summary?.costEstimate?.usd != nil)
                check("diff is read-only with spoken changes", !review.runs.isEmpty && review.accessibleDescription.contains("removed") && review.accessibleDescription.contains("insert"))
            } else { check("voice review exists", false) }
            session.edit(Array(repeating: "fresh", count: 61).joined(separator: " "))
            check("patch budget uses whole transcript and exact re-record copy", session.review?.budget.copy == VoiceLabPatchBudget.disabledCopy)
        }
        do {
            let (editor, session) = make(range: 10...12, withoutEnvelope: true, prices: prices, synthesisModel: "eleven_multilingual_v2")
            defer { editor.close() }
            session.edit("Sunday word11 word12")
            check("missing windows never invent a meter or amount", session.review?.summary == nil && session.review?.voiceHunks.allSatisfy { $0.window == nil && $0.patchText == nil && $0.refusal != nil } == true)
            check("no connector uses approved settings fallback and disables proposal", session.sendLine == "Choose a connector in Settings → AI." && !session.canPropose)
            let (unknownEditor, unknown) = make(range: 10...12, prices: prices, synthesisModel: "unknown-model")
            defer { unknownEditor.close() }
            unknown.edit("Sunday word11 word12")
            check("unknown synthesis model never invents a price", unknown.review?.summary != nil && unknown.review?.summary?.costEstimate?.usd == nil && unknown.review?.summary?.copy.contains("$") == false)
        }
        do {
            var words = project.transcript?.words ?? []
            words[11].kind = .event; words[11].text = "[laughter]"
            words[12].kind = .unlabeledSpeech; words[12].text = "[unlabeled speech]"
            let (editor, session) = make(range: 10...13, words: words)
            defer { editor.close() }
            session.edit("Sunday")
            for label in ["[laughter]", "[unlabeled speech]"] {
                check("absorbed \(label) struck in read-only diff", session.review?.runs.contains { $0.text == label && $0.kind == .removed } == true)
                check("absorbed \(label) has spoken removal", session.review?.accessibleDescription.contains(label + " removed") == true)
            }
            let (bridgeEditor, bridge) = make(range: 10...18)
            defer { bridgeEditor.close() }
            bridge.edit("Sunday word11 word12 five word14 word15 word16 word17 word18")
            check("unchanged bridge words appear in read-only diff", bridge.review?.runs.contains { $0.kind == .bridge && $0.sourceID == "rewrite-11" } == true)
        }
        for group in ["local", "apiKey", "cli"] {
            for granted in [false, true] {
                let fake = RewriteFixtureConnector()
                let probe = RewriteTestState()
                let (editor, session) = make(fake, group: group, consent: {
                    probe.consentCalls += 1
                    let counts1 = await fake.counts()
                    probe.beforeDiscovery = counts1.discoveries == 0 && counts1.sends == 0
                    return granted
                })
                defer { editor.close() }
                await session.prepare()
                let counts2 = await fake.counts()
                check("\(group) preparing quote never discovers or sends", counts2.discoveries == 0 && counts2.sends == 0)
                guard let quote = session.quote else { check("\(group) prepares quote", false); continue }
                let hidden = await session.propose(quote, affirmative: true)
                let counts3 = await fake.counts()
                check("\(group) cannot send undisplayed estimate", !hidden && counts3.sends == 0)
                session.markEstimateShown(quote.id)
                let declined = await session.propose(quote, affirmative: false)
                let counts4 = await fake.counts()
                check("\(group) cannot send unapproved estimate", !declined && counts4.sends == 0)
                let approved = await session.propose(quote, affirmative: true)
                let expected = group == "local" || granted
                let counts5 = await fake.counts()
                check("\(group) consent \(granted) gates send and releases lease", approved == expected && counts5.sends == (expected ? 1 : 0) && !editor.llmRuns.isBusy)
                check("\(group) consent precedes every discovery", group == "local" ? probe.consentCalls == 0 : probe.consentCalls == 1 && probe.beforeDiscovery)
                check("proposals are inert project data", editor.project == project)
                if group == "local" { check("local exact no-charge title", session.proposalButton == "Rewrite · No charge") }
                if group == "cli" { check("CLI has no header amount and names plan", session.proposalButton == "Rewrite" && session.sendLine.contains("ChatGPT plan")) }
            }
        }
        for boundary in ["panel", "editor", "leave"] {
            let fake = RewriteFixtureConnector()
            let held = HeldRewriteConsent()
            let (editor, session) = make(fake, group: "cli", consent: { await held.confirm() })
            defer { editor.close() }
            await session.prepare()
            if let quote = session.quote {
                session.markEstimateShown(quote.id)
                let task = Task { await session.propose(quote, affirmative: true) }
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
            } else { check("held consent quote exists", false) }
        }
        do {
            let fake = RewriteFixtureConnector(hold: true)
            let (editor, session) = make(fake)
            defer { editor.close() }
            await session.prepare()
            if let quote = session.quote {
                session.markEstimateShown(quote.id)
                let task = Task { await session.propose(quote, affirmative: true) }
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(5))
                while await fake.sends == 0 && clock.now < deadline { await Task.yield() }
                editor.closeRewrite(returnFocus: false)
                for _ in 0..<20 { await Task.yield() }
                check("close after dispatch retains lease until fake request stops", editor.llmRuns.isBusy)
                await fake.release()
                _ = await task.value
                check("stopped dispatched request releases lease without late edits", !editor.llmRuns.isBusy && session.newWords == session.source.map(\.text).joined(separator: " "))
            } else { check("dispatched close quote exists", false) }
        }
        for change in ["instruction", "project", "connector", "close", "leave"] {
            let fake = RewriteFixtureConnector()
            let probe = RewriteTestState()
            let (editor, session) = make(fake, group: "apiKey", consent: {
                guard let session = probe.session else { return false }
                switch change {
                case "instruction": session.setInstruction("Changed during consent")
                case "project": session.editor.apply(.cutSelection(ids: ["rewrite-4"]), name: "Cut")
                case "connector": probe.connectorCurrent = false
                case "close": session.editor.closeRewrite(returnFocus: false)
                default: session.editor.isLeaving = true
                }
                return true
            }, current: { probe.connectorCurrent })
            probe.session = session
            defer { editor.close() }
            await session.prepare()
            if let quote = session.quote {
                session.markEstimateShown(quote.id)
                let sent = await session.propose(quote, affirmative: true)
                let counts6 = await fake.counts()
                check("\(change) during consent never discovers or sends", !sent && counts6.discoveries == 0 && counts6.sends == 0 && !editor.llmRuns.isBusy)
            } else { check("consent race prepares quote", false) }
        }
        do {
            let fake = RewriteFixtureConnector()
            let (editor, session) = make(fake)
            defer { editor.close() }
            await session.prepare()
            let previous = session.quote?.id
            session.edit("A new draft")
            check("New words edit immediately invalidates the displayed estimate", session.quote == nil && !session.canPropose)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while session.quote == nil && clock.now < deadline { await Task.yield() }
            check("New words edit offers a fresh estimate and leaves lease free", session.quote != nil && session.quote?.id != previous && !editor.llmRuns.isBusy)
            if let fresh = session.quote {
                let unshown = await session.propose(fresh, affirmative: true)
                session.markEstimateShown(fresh.id)
                let denied = await session.propose(fresh, affirmative: false)
                let counts = await fake.counts()
                check("new estimate requires display and affirmative approval before send", !unshown && !denied && session.canPropose && counts.sends == 0)
            }
        }
        do {
            let fake = RewriteFixtureConnector(hold: true)
            let (editor, session) = make(fake)
            defer { editor.close() }
            await session.prepare()
            if let quote = session.quote {
                session.markEstimateShown(quote.id)
                session.setInstruction("new instruction")
                let stale = await session.propose(quote, affirmative: true)
                let counts7 = await fake.counts()
                check("changed instruction invalidates displayed quote without discovery", !stale && counts7.discoveries == 0)
                await session.prepare()
                if let fresh = session.quote {
                    session.markEstimateShown(fresh.id)
                    let task = Task { await session.propose(fresh, affirmative: true) }
                    for _ in 0..<500 { if await fake.sends > 0 { break }; await Task.yield() }
                    check("Rewrite holds the same project lease as Find Clips", editor.llmRuns.isBusy && !editor.capabilities.ai)
                    editor.findClips()
                    check("Find Clips cannot start while Rewrite holds lease", !editor.finding)
                    session.edit("Typing wins")
                    await fake.release()
                    _ = await task.value
                    check("late proposal cannot overwrite typing and cancellation releases lease", session.newWords == "Typing wins" && !editor.llmRuns.isBusy)
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .seconds(5))
                    while session.quote == nil && clock.now < deadline { await Task.yield() }
                    check("typing during pending proposal re-offers an unshown estimate", session.quote != nil && session.quote?.id != fresh.id && !session.canPropose && !editor.llmRuns.isBusy)
                    if let replacement = session.quote {
                        session.markEstimateShown(replacement.id)
                        check("showing the replacement estimate enables Rewrite", session.canPropose)
                    }
                }
            }
        }
        do {
            let fake = RewriteFixtureConnector(failure: true)
            let (editor, session) = make(fake)
            defer { editor.close() }
            await session.prepare()
            if let quote = session.quote {
                session.markEstimateShown(quote.id)
                let sent = await session.propose(quote, affirmative: true)
                check("failed proposal retains inline error and releases lease", !sent && !session.problem.isEmpty && !editor.llmRuns.isBusy)
            }
            if let lease = editor.llmRuns.acquire() {
                check("Find Clips first blocks Rewrite", !session.canPropose)
                editor.llmRuns.release(lease)
            }
            editor.mediaResolved = false
            check("losing media closes and clears passage", editor.rewrite == nil && editor.rewriteRange == nil && !session.isOpen)
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
            await session.prepare()
            if let quote = session.quote {
                session.markEstimateShown(quote.id)
                editor.findClips()
                check("real Find Clips entry acquires shared project lease first", editor.finding && editor.llmRuns.isBusy)
                let proposal = await session.propose(quote, affirmative: true)
                check("Find Clips first refuses approved Rewrite without a second send", !proposal && !session.isProposing)
                for _ in 0..<5_000 { if await fake.sends > 0 { break }; await Task.yield() }
                let before = await fake.counts()
                check("Find Clips uses fake connector only", before.sends == 1)
                editor.findTask?.cancel(); await fake.release(); await editor.findTask?.value
                check("Find Clips cancellation releases lease and leaves project unchanged", !editor.finding && !editor.llmRuns.isBusy && editor.project == project)
            } else { check("Find Clips interlock quote exists", false) }
            app.set("llm.cloudConsent.ollama", .bool(true))
            check("persisting connector consent does not close unchanged Rewrite", session.isOpen && session.current)
        }
        for change in ["selection", "caret", "close", "leave"] {
            let (editor, session) = make()
            session.close(); editor.rewrite = nil
            editor.selectedWordIDs = ["rewrite-3", "rewrite-4"]
            editor.beginRewrite()
            switch change {
            case "selection": editor.selectedWordIDs = ["rewrite-9"]
            case "caret": editor.sourceTime = 9
            case "close": editor.closeRewrite(returnFocus: false)
            default: editor.isLeaving = true
            }
            await editor.rewriteOpenTask?.value
            check("async opening rejects stale \(change)", editor.rewrite == nil)
            editor.close()
        }
        check("insertion fallback exact copy", RewriteSession.refusal(VoiceLabGeometryError.insertionUnsupported) == "Inserting words isn't available yet. Your edits are saved.")
        check("room tone fallback exact copy", RewriteSession.refusal(VoiceLabGeometryError.roomToneUnavailable) == "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in.")
        check("no speech rate fallback exact copy", RewriteSession.refusal(VoiceLabLengthBudgetError.rateUnavailable) == "There isn't enough timed speech to estimate this change. Your edits are saved.")
        check("placement fallback exact copy", RewriteSession.refusal(VoiceLabGeometryError.reversedWords) == "This change can't be placed in this take. Your edits are saved.")
        check("take start refusal uses Core edge and exact copy", RewriteSession.refusal(VoiceLabGeometryError.seamFadeOutsideTake(isStart: true)) == "This change is too close to the start of the take to blend in. Re-record this sentence instead.")
        check("take end refusal uses Core edge and exact copy", RewriteSession.refusal(VoiceLabGeometryError.seamFadeOutsideTake(isStart: false)) == "This change is too close to the end of the take to blend in. Re-record this sentence instead.")
        return results
    }
}
#endif
