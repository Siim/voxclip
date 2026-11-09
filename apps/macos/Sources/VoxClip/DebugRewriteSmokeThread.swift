#if DEBUG
import AppKit
import Foundation
import VoxClipCore

// Talk back to Claude in the Rewrite smoke (design.md §6.3 "Talk back to Claude", ADR-R50): the thread under the focused
// change, driven as a user drives it, with the scripted AI answering the thread's requests too. Nothing is paid or sent
// anywhere; only the kept version goes on to the voice steps.
//
// - S-thread: Rewrite gives version 1; the user sends their sentence ("It reads like I was happy about the scammer. I was
//   happy about the sale.") and gets version 2 in place; ‹ back to version 1, › forward to version 2; "✓ That's it, keep it"
//   keeps it; then Use, with the stubbed voice. It also writes rewrite-smoke-S-thread-thread.png, the transcript with the
//   thread, offscreen.
// - S-thread-more: a steady bubble gives version 2; "3 more versions" gives versions 3–5 and shows 3; Undo (⌘⌫ in the
//   thread's input) returns the recorded words, and the Rewrite ends with Done, nothing changed.
// - S-thread-own: "✎ My own words" fills the input with version 1; the user types their sentence over it and presses ↵,
//   which puts it in place as version 2, "your words", with no request; "✓ That's it, keep it" keeps it; then Use, the
//   stubbed voice reading the user's words.

extension DebugRewriteSmoke {
    /// The user's sentence about Clip 1 (2026-11-09).
    nonisolated static let threadMessage = "It reads like I was happy about the scammer. I was happy about the sale."
    /// The scripted versions: none shares a word with the recorded "record a short clip in one take", so each stays one
    /// phrase to voice.
    nonisolated static let threadVersion2 = "film quick footage straight through."
    nonisolated static let threadMoreVersion2 = "film quick footage nonstop."
    nonisolated static let threadAlternatives = ["film quick footage without stopping.", "shoot quick footage straight through.", "film fast footage without breaks."]
    /// The user's own words for S-thread-own: no word of the recorded ones either.
    nonisolated static let threadOwnWords = "shoot fast footage straight through."
    nonisolated static func threadReply(_ text: String, note: String, steps: [String] = []) -> String {
        (try? JSONSerialization.data(withJSONObject: ["text": text, "note": note, "nextSteps": steps], options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    nonisolated static func threadVersionsReply(_ texts: [String], note: String) -> String {
        (try? JSONSerialization.data(withJSONObject: ["alternatives": texts, "note": note, "nextSteps": [String]()], options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static var threadScenarios: [Definition] { [
        Definition(id: "S-thread", title: "talk back to Claude: a reply becomes version 2, ‹ and › switch versions, \u{201C}That's it, keep it\u{201D} keeps it, Use",
                   voiced: 1,
                   fixture: Fixture(rewrites: [.passage(replace([twoChanges[0]]))],
                                    followups: [threadReply(threadVersion2, note: "The sale comes first now, and the rest follows it.", steps: ["Say it in four words"])],
                                    voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.start()
            try await ThreadSmoke(harness).talk()
            try await harness.finish()
        },
        Definition(id: "S-thread-more", title: "talk back to Claude: \u{201C}3 more versions\u{201D} gives versions 3\u{2013}5, Undo returns the recorded words",
                   mayEndUnchanged: true,
                   fixture: Fixture(rewrites: [.passage(replace([twoChanges[0]]))],
                                    followups: [threadReply(threadMoreVersion2, note: "Closer to how you said it."),
                                                threadVersionsReply(threadAlternatives, note: "Three more ways to say it.")],
                                    voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.start()
            try await ThreadSmoke(harness).moreAndUndo()
            try await harness.finish()
        },
        Definition(id: "S-thread-own", title: "talk back to Claude: \u{201C}My own words\u{201D} puts the user's sentence in place with no request, keep it, Use",
                   voiced: 1,
                   fixture: Fixture(rewrites: [.passage(replace([twoChanges[0]]))], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.start()
            let smoke = ThreadSmoke(harness)
            try await smoke.ownWords()
            try await harness.finish()
            smoke.appliedOwnWords()
        },
    ] }
}

/// Drives one thread scenario on the harness's editor; each step is the harness's own observation (I1–I10) plus the
/// thread's checks T1–T9.
@MainActor struct ThreadSmoke {
    typealias Check = DebugRewriteSmoke.Check
    let harness: DebugRewriteSmoke.Harness
    init(_ harness: DebugRewriteSmoke.Harness) { self.harness = harness }

    private func step(_ name: String, _ perform: () async -> Void, checks: () async -> [Check]) async throws {
        try await harness.act(name, perform)
        let extra = await checks()
        guard let last = harness.steps.popLast() else { return }
        var step = DebugRewriteSmoke.Step(index: last.index, action: last.action, snapshot: last.snapshot, checks: last.checks + extra, capture: last.capture)
        step.seconds = last.seconds; step.waits = last.waits
        harness.steps.append(step)
    }
    private var syntheses: Int { RewriteSmokeHTTP.script.withLock { $0.syntheses } }
    private func followups() async -> [LLMRequest] { await harness.connector?.followupRequests ?? [] }
    private func voiceOrdinal(_ editor: EditorModel) throws -> Int {
        if let proposal = editor.proposal {
            for change in proposal.changes where change.kind == .voice { return change.ordinal }
        }
        throw DebugRewriteSmoke.Failure.setup("the Rewrite proposed no voice change")
    }
    /// The thread's input as the user types into it: the text, then a key.
    private func type(_ text: String, key: UInt16, flags: NSEvent.ModifierFlags = [], editor: EditorModel) {
        let input = RewriteThreadInputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        input.model = editor
        input.string = text
        editor.rewriteThread.text = text
        let characters = key == 36 ? "\r" : ""
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key) {
            input.keyDown(with: event)
        }
    }
    /// Words in `text` in this order.
    private static func inOrder(_ parts: [String], in text: String) -> Bool {
        var cursor = text.startIndex
        for part in parts {
            guard let found = text.range(of: part, range: cursor..<text.endIndex) else { return false }
            cursor = found.upperBound
        }
        return true
    }

    /// S-thread.
    func talk() async throws {
        guard let editor = harness.editor else { throw DebugRewriteSmoke.Failure.setup("no editor") }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let first = editor.changeText(ordinal), recorded = editor.recordedText(ordinal)
        let shown = editor.rewriteThreadDisplay, before = syntheses
        try await step("type the user's sentence in change \(ordinal)'s thread, press Return", {
            _ = editor.openRewriteThreadInput()
            type(DebugRewriteSmoke.threadMessage, key: 36, editor: editor)
            await editor.rewriteThread.task?.value
        }) {
            let sent: [LLMRequest] = await followups()
            let display: RewriteThreadDisplay? = editor.rewriteThreadDisplay
            // Typed one at a time: one array literal of these took the type checker over 250 ms.
            let opened: Bool = shown?.ordinal == ordinal && shown?.versionLine == "1 of 1" && shown?.turns.isEmpty == true && shown?.steady.count == 3
            let openedLine: String = shown.map { "\($0.versionLine), \($0.turns.count) turns" } ?? "none"
            let carried: Bool = sent.count == 1 && sent[0].tag == "rewrite-followup"
                && Self.inOrder([recorded, first, DebugRewriteSmoke.threadMessage], in: sent[0].instruction)
            let inText: String = editor.changeText(ordinal)
            let turns: [String] = display?.turns.map(\.text) ?? []
            let placed: Bool = inText == DebugRewriteSmoke.threadVersion2 && display?.versionLine == "2 of 2"
                && turns.last == "The sale comes first now, and the rest follows it." && display?.steps == ["Say it in four words"]
            var noTakes = true
            if let plan = harness.session?.takePlan {
                for phrase in plan.phrases where !phrase.takes.isEmpty { noTakes = false }
            }
            let unpaid: Bool = syntheses == before && noTakes
            var checks: [Check] = []
            checks.append(Check(invariant: "T1", passed: opened, detail: "the thread opened under change \(ordinal) with the bubbles and the input: \(openedLine)"))
            checks.append(Check(invariant: "T2", passed: carried, detail: "\(sent.count) thread request(s) carrying the recorded words, version 1 and the message in order"))
            checks.append(Check(invariant: "T3", passed: placed, detail: "in the text: \(inText); \(display?.versionLine ?? "no thread"); \(turns)"))
            checks.append(Check(invariant: "T4", passed: unpaid, detail: "nothing voiced or paid in the thread (\(syntheses - before) syntheses)"))
            checks.append(capture(editor, ordinal: ordinal))
            return checks
        }
        try await step("click [\u{2039}] in the thread", { editor.switchRewriteThreadVersion(by: -1) }) {
            let sent = await followups()
            return [Check(invariant: "T5", passed: editor.changeText(ordinal) == first && editor.rewriteThreadDisplay?.versionLine == "1 of 2" && sent.count == 1,
                          detail: "version 1 back in the text (\(editor.changeText(ordinal))), nothing sent")]
        }
        try await step("click [\u{203A}] in the thread", { editor.switchRewriteThreadVersion(by: 1) }) {
            let sent = await followups()
            return [Check(invariant: "T5", passed: editor.changeText(ordinal) == DebugRewriteSmoke.threadVersion2
                            && editor.rewriteThreadDisplay?.versionLine == "2 of 2" && sent.count == 1,
                          detail: "version 2 in the text again (\(editor.changeText(ordinal))), nothing sent")]
        }
        let keep = editor.rewriteThreadDisplay?.keep ?? ""
        try await step("click [\(keep)]", { editor.pressRewriteThreadBubble(keep) }) {
            [Check(invariant: "T6", passed: editor.proposal?[ordinal]?.state == .kept && editor.proposal?.threads[ordinal] == nil
                     && editor.changeText(ordinal) == DebugRewriteSmoke.threadVersion2 && syntheses == before,
                   detail: "change \(ordinal) kept with version 2 as Keep keeps it; its thread is gone; nothing voiced yet")]
        }
    }

    /// S-thread-more.
    func moreAndUndo() async throws {
        guard let editor = harness.editor else { throw DebugRewriteSmoke.Failure.setup("no editor") }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let first = editor.changeText(ordinal), recorded = editor.recordedText(ordinal), before = syntheses
        try await step("click [Closer to my words] in change \(ordinal)'s thread", {
            editor.pressRewriteThreadBubble("Closer to my words")
            await editor.rewriteThread.task?.value
        }) {
            [Check(invariant: "T3", passed: editor.changeText(ordinal) == DebugRewriteSmoke.threadMoreVersion2 && editor.rewriteThreadDisplay?.versionLine == "2 of 2",
                   detail: "in the text: \(editor.changeText(ordinal)); \(editor.rewriteThreadDisplay?.versionLine ?? "no thread")")]
        }
        try await step("click [3 more versions]", {
            editor.pressRewriteThreadBubble("3 more versions")
            await editor.rewriteThread.task?.value
        }) {
            let sent = await followups()
            let last = sent.last
            return [
                Check(invariant: "T7", passed: sent.count == 2 && last?.tag == "rewrite-followup-versions"
                        && Self.inOrder([recorded, first, DebugRewriteSmoke.threadMoreVersion2, "Closer to my words", "3 more versions"], in: last?.instruction ?? ""),
                      detail: "the second request asks for alternatives with every version and message so far"),
                Check(invariant: "T8", passed: editor.rewriteThreadDisplay?.versionLine == "3 of 5" && editor.changeText(ordinal) == DebugRewriteSmoke.threadAlternatives[0],
                      detail: "versions 3\u{2013}5 added, the first in the text: \(editor.rewriteThreadDisplay?.versionLine ?? "no thread"), \(editor.changeText(ordinal))"),
                Check(invariant: "T4", passed: syntheses == before, detail: "nothing voiced or paid in the thread"),
            ]
        }
        try await step("press \u{2318}\u{232B} in the thread's input (Undo)", { type("", key: 51, flags: .command, editor: editor) }) {
            let runs = (editor.proposalDisplay?.before.values.flatMap { $0 } ?? []) + (editor.proposalDisplay?.after.values.flatMap { $0 } ?? [])
            return [Check(invariant: "T9", passed: editor.proposal?[ordinal]?.state == .excluded && editor.proposal?.threads[ordinal] == nil
                            && !runs.contains { $0.mark.ordinal == ordinal },
                          detail: "change \(ordinal) undone: the recorded words show (\(recorded)), its thread is gone")]
        }
    }

    /// S-thread-own.
    func ownWords() async throws {
        guard let editor = harness.editor else { throw DebugRewriteSmoke.Failure.setup("no editor") }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let first = editor.changeText(ordinal), before = syntheses
        let bubble = RewriteThreadDisplay.ownWordsBubble
        try await step("click [\(bubble)] in change \(ordinal)'s thread", { editor.pressRewriteThreadBubble(bubble) }) {
            let display: RewriteThreadDisplay? = editor.rewriteThreadDisplay
            let filled: Bool = editor.rewriteThread.text == first && display?.ownWords == true
            let costLine: String = display?.inputCostLine ?? "no thread"
            return [Check(invariant: "T11", passed: filled && costLine == RewriteThreadDisplay.ownWordsCostLine,
                          detail: "the input holds version 1 (\(editor.rewriteThread.text)) for your own words; beside it: \(costLine)")]
        }
        try await step("type \u{201C}\(DebugRewriteSmoke.threadOwnWords)\u{201D} over it, press Return", {
            type(DebugRewriteSmoke.threadOwnWords, key: 36, editor: editor)
        }) {
            let sent: [LLMRequest] = await followups()
            let display: RewriteThreadDisplay? = editor.rewriteThreadDisplay
            let inText: String = editor.changeText(ordinal)
            let yours: Bool = display?.yoursLine != nil && display?.ownWords == false
                && display?.turns.last == RewriteThread.Turn(speaker: .yours, text: DebugRewriteSmoke.threadOwnWords)
            let placed: Bool = inText == DebugRewriteSmoke.threadOwnWords && display?.versionLine == "2 of 2" && yours
            let eligible: Bool = harness.session?.reviewedVoiceOrdinals.contains(ordinal) == true && harness.session?.hasEditedChanges == false
            var checks: [Check] = []
            checks.append(Check(invariant: "T12", passed: placed, detail: "in the text: \(inText); \(display?.versionLine ?? "no thread") \(display?.yoursLine ?? "")"))
            checks.append(Check(invariant: "T13", passed: sent.isEmpty && syntheses == before, detail: "\(sent.count) thread request(s), \(syntheses - before) syntheses: nothing sent"))
            checks.append(Check(invariant: "T14", passed: eligible, detail: "your words are the Rewrite's words for change \(ordinal), voiced at Keep"))
            return checks
        }
        let keep = editor.rewriteThreadDisplay?.keep ?? ""
        try await step("click [\(keep)]", { editor.pressRewriteThreadBubble(keep) }) {
            [Check(invariant: "T6", passed: editor.proposal?[ordinal]?.state == .kept && editor.proposal?.threads[ordinal] == nil
                     && editor.changeText(ordinal) == DebugRewriteSmoke.threadOwnWords && syntheses == before,
                   detail: "change \(ordinal) kept with your words; its thread is gone; nothing voiced yet")]
        }
    }

    /// After Use: the applied voice reads the user's own words.
    func appliedOwnWords() {
        let segments = harness.editor?.project.voiceLab.segments ?? []
        let spoken: [String] = segments.compactMap { $0.text?.new }
        let read: Bool = spoken.contains { $0.contains("shoot fast footage straight through") }
        let check = Check(invariant: "T15", passed: read, detail: "the applied voice reads: \(spoken)")
        guard let last = harness.steps.popLast() else { return }
        var step = DebugRewriteSmoke.Step(index: last.index, action: last.action, snapshot: last.snapshot, checks: last.checks + [check], capture: last.capture)
        step.seconds = last.seconds; step.waits = last.waits
        harness.steps.append(step)
    }

    /// The transcript with the thread as the editor draws it, offscreen, once (rewrite-smoke-S-thread-thread.png): the thread
    /// under the change's paragraph at the text column, the paragraph after it below the thread.
    private func capture(_ editor: EditorModel, ordinal: Int) -> Check {
        guard harness.scenario == "S-thread" else { return Check(invariant: "T10", passed: true, detail: "captured in the realistic pass") }
        do {
            let pane = try TranscriptPane(model: editor, size: NSSize(width: 720, height: 460))
            defer { pane.close() }
            if let range = pane.renderer.changeRange(ordinal) { pane.scroll(toCharacter: range.location) }
            pane.text.layoutThreadNow()
            pane.layout()
            pane.text.layoutThreadNow()
            guard let thread = pane.text.threadAuditView, let anchor = pane.renderer.threadAnchor, let line = pane.text.lineBox(atCharacter: anchor) else {
                return Check(invariant: "T10", passed: false, detail: "no thread drawn in the transcript")
            }
            let next = pane.text.lineBox(atCharacter: anchor + 2)
            _ = try pane.bitmap("rewrite-smoke-S-thread-thread", directory: harness.directory)
            let placed = thread.frame.minY >= line.maxY && abs(thread.frame.minX - pane.text.textContainerOrigin.x) < 0.5 && (next.map { $0.minY >= thread.frame.maxY } ?? true)
            return Check(invariant: "T10", passed: placed, detail: "thread \(thread.frame) under line \(line.maxY), next line \(next?.minY ?? -1); rewrite-smoke-S-thread-thread.png")
        } catch { return Check(invariant: "T10", passed: false, detail: "capture failed: \(error)") }
    }
}
#endif
