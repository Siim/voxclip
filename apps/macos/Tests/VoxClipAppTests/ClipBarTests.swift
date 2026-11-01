#if DEBUG
import AppKit
import Foundation
import Observation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// The sheets a routed send showed.
@MainActor private final class SheetReasons { var reasons: [ConnectorSendPrompt.Reason] = [] }
/// Whether an observation heard a change.
private final class Heard: @unchecked Sendable { var value = false }

/// A Find Clips connector that keeps what it was asked. It answers with no clips; nothing leaves the Mac. A CLI with
/// no sign-in method reads as signed out until `signIn` gives it one.
private actor HookFixtureConnector: LLMConnector {
    nonisolated let id: ConnectorID
    private(set) var authMethod: String?
    private(set) var requests: [LLMRequest] = []
    private(set) var statuses = 0
    init(id: ConnectorID, authMethod: String?) { self.id = id; self.authMethod = authMethod }
    func signIn(_ method: String?) { authMethod = method }
    func status() -> ConnectorStatus { statuses += 1; return .ready }
    func knownCLIAuthMethod() async -> String? { authMethod }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        requests.append(request)
        return RawCompletion(text: "{\"clips\":[]}", model: model, stop: .complete)
    }
}

/// The clip bar (impl-plan V3b): Tighten as one undo step on the tab's clip, Hook as one click through the send route,
/// the harness picker that writes `llm.connector` and detects only when its menu opens, the suggestion's Keep and
/// Dismiss, VoiceOver's names, and the narrow widths. Stub connectors only, settings in memory, nothing shown.
@Suite("Clip bar", .serialized)
@MainActor struct ClipBarTests {
    /// `performClick` sends its action through `NSApp`, so every test needs the application, also when it runs alone.
    init() { _ = NSApplication.shared }
    /// The interview take with one clip, w1…w7, open: two fillers (w2 "um,", w6 "uh") and the pause after w3 inside it,
    /// the pause after w8 outside it, nothing cut.
    private func tightenProject() throws -> Project {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.edits.cutWordIds = []
        project.edits.cutPauseIds = []
        project.edits.clips = [ClipRange(id: "tight-1", startWordId: "w1", endWordId: "w7", title: "One", origin: .manual, selected: true)]
        project.edits.activeClipId = nil
        return project
    }
    private func fiveQuestions() throws -> Project {
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        return try DebugExplorer.fiveQuestions(from: base)
    }
    /// A shell with `project` open on Full Take, its media treated as found, one undo group per action, and a bar.
    private func open(_ project: Project, app: AppModel = AppModel(settingsStore: RegressionSettingsStore())) async throws -> (WorkspaceShell, EditorModel, UndoManager, ClipBarView) {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let bar = ClipBarView(model: editor, shell: shell)
        bar.frame = NSRect(x: 0, y: 0, width: ShellRegion.clipBar.reference.width, height: ShellMetrics.clipBar)
        bar.render()
        bar.layoutSubtreeIfNeeded()
        return (shell, editor, undo, bar)
    }
    private func lay(_ bar: ClipBarView, width: CGFloat) {
        bar.render()
        bar.frame.size.width = width
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
    }
    private func shows(_ view: NSView) -> Bool { !view.isHidden }

    // MARK: Tighten

    @Test func tightenIsOneUndoStepScopedToTheClip() async throws {
        let (shell, editor, undo, bar) = try await open(try tightenProject())
        defer { bar.tearDown(); editor.close() }
        shell.selection = .clip("tight-1")
        bar.render()
        #expect(bar.variant == .scope("tight-1") && shows(bar.tighten))
        #expect(bar.tighten.accessibilityLabel() == "Tighten Clip 1")
        let before = editor.project, steps = editor.undoSteps
        undo.beginUndoGrouping(); bar.runTighten(); undo.endUndoGrouping()
        // One step named for the clip; only the clip's fillers and the pause inside it are cut.
        #expect(editor.undoSteps == steps + 1 && undo.undoActionName == "Tighten clip 1")
        #expect(Set(editor.project.edits.cutWordIds) == ["w2", "w6"])
        #expect(editor.project.edits.cutPauseIds == ["pause-after-w3"])
        #expect(editor.project.edits.clips == before.edits.clips && editor.project.edits.activeClipId == "tight-1")
        #expect(editor.lastAnnouncement == "Clip 1 tightened: 3 cuts")
        // "3 cuts · Undo" stands in Tighten's place, which has nothing left to do.
        bar.render()
        #expect(shows(bar.toast) && !shows(bar.tighten) && bar.toast.cuts == 3 && bar.toast.label.stringValue == "3 cuts ·")
        #expect(bar.toast.undo.accessibilityLabel() == "Undo Tighten clip 1")
        // Its Undo is a 24 pt target (impl-plan §3.7) that fills the toast's height.
        lay(bar, width: 652)
        bar.toast.layoutSubtreeIfNeeded()
        #expect(bar.toast.frame.height == 24 && bar.toast.undo.frame.height == 24 && bar.toast.undo.frame.minY == 0)
        bar.undoTighten()
        #expect(editor.project.edits.cutWordIds.isEmpty && editor.project.edits.cutPauseIds.isEmpty && editor.project.edits.activeClipId == "tight-1")
        bar.render()
        #expect(!shows(bar.toast) && shows(bar.tighten))
        // A bar behind a tab switch tightens nothing.
        #expect(editor.tighten(scope: nil) == nil && editor.project.edits.cutWordIds.isEmpty)
        // Full Take tightens the whole take as its own step, and the toast goes with the next edit.
        shell.selection = .fullTake
        bar.render()
        undo.beginUndoGrouping(); bar.runTighten(); undo.endUndoGrouping()
        #expect(undo.undoActionName == "Tighten full take" && editor.project.edits.cutPauseIds == ["pause-after-w3", "pause-after-w8"])
        bar.render()
        #expect(shows(bar.toast) && bar.toast.cuts == 4)
        undo.beginUndoGrouping(); editor.apply(.restoreCuts, name: "Restore cuts"); undo.endUndoGrouping()
        bar.render()
        #expect(!shows(bar.toast) && bar.tightened == nil)
    }

    // MARK: Hook

    /// Hook sends Find Clips with the Hooks preset at once on a plan, and asks first on an API key (VS); the popover's
    /// own preset and instructions stay. Needs the shared catalogue and an isolated data folder, as the routing tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."),
          arguments: [("claude-code", "claude.ai"), ("claude-code", "api_key"), ("anthropic", nil)] as [(String, String?)])
    func hookStartsAtOnceOnAPlanAndAsksOnAKey(connector: String, authMethod: String?) async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let fake = HookFixtureConnector(id: try #require(ConnectorID(rawValue: connector)), authMethod: authMethod)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string(connector))
        app.set("llm.cloudConsent.\(connector)", .bool(true))
        let sheets = SheetReasons()
        app.connectorConsentOverride = { _, action, sheet in
            #expect(action == .findClips)
            sheets.reasons.append(sheet.reason)
            return false
        }
        let shared = try SharedResources.locate()
        let editor = DebugConnectorRequests.makeEditor(fixture: try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")), app: app)
        defer { editor.close() }
        editor.preset = .quotes
        editor.instruction = "only the jokes"
        let shell = WorkspaceShell(app: app)
        let bar = ClipBarView(model: editor, shell: shell)
        defer { bar.tearDown() }
        #expect(bar.variant == .scope(nil) && shows(bar.hook) && !shows(bar.finding))
        bar.hook.performClick(nil)
        await editor.findTask?.value
        let requests = await fake.requests
        if authMethod == "claude.ai" {
            // A plan costs nothing extra: no sheet, one send with the Hooks preset.
            let hooks = try presetInstruction("hooks")
            #expect(sheets.reasons.isEmpty && requests.count == 1)
            #expect(requests.allSatisfy { ($0.system + $0.instruction).contains(hooks) && !$0.instruction.contains("only the jokes") })
        } else {
            // An API key, the CLI's or Anthropic's: the cost sheet asks, and declining it sends nothing.
            #expect(sheets.reasons == [.cost] && requests.isEmpty)
        }
        #expect(editor.preset == .quotes && editor.instruction == "only the jokes" && !editor.showFindClips)
        #expect(!editor.finding && !editor.llmRuns.isBusy)
    }
    /// A Hook that fails (Claude Code signed out) shows the Explorer's error with Retry, and Retry sends Hooks again, not
    /// the popover's style and instructions.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."))
    func retryAfterAFailedHookSendsHooksAgain() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let fake = HookFixtureConnector(id: .claudeCode, authMethod: nil)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("claude-code"))
        app.set("llm.cloudConsent.claude-code", .bool(true))
        let sheets = SheetReasons()
        app.connectorConsentOverride = { _, _, sheet in sheets.reasons.append(sheet.reason); return false }
        let shared = try SharedResources.locate()
        let editor = DebugConnectorRequests.makeEditor(fixture: try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")), app: app)
        defer { editor.close() }
        editor.preset = .quotes
        editor.instruction = "only the jokes"
        let bar = ClipBarView(model: editor, shell: WorkspaceShell(app: app))
        defer { bar.tearDown() }
        bar.hook.performClick(nil)
        await editor.findTask?.value
        // Signed out: the route fails before anything is sent, and the Explorer shows the error with Retry.
        #expect(await fake.requests.isEmpty && editor.clipError?.isEmpty == false && editor.clipError != EditorModel.noClipsMatched)
        // Signed in on a plan, Retry sends the Hooks preset once, with no sheet.
        await fake.signIn("claude.ai")
        editor.retryFindClips()
        await editor.findTask?.value
        let requests = await fake.requests
        let hooks = try presetInstruction("hooks"), quotes = try presetInstruction("quotes")
        #expect(sheets.reasons.isEmpty && requests.count == 1)
        #expect(requests.allSatisfy { ($0.system + $0.instruction).contains(hooks) && !($0.system + $0.instruction).contains(quotes) && !$0.instruction.contains("only the jokes") })
        #expect(editor.preset == .quotes && editor.instruction == "only the jokes")
        // A Find Clips run from the popover is what the next Retry repeats.
        editor.findClips()
        await editor.findTask?.value
        #expect(editor.lastFindRequest?.preset == .quotes && editor.lastFindRequest?.instruction == "only the jokes")
    }
    private func presetInstruction(_ id: String) throws -> String {
        let shared = try SharedResources.locate()
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("prompts/clip-finder.json"))) as? [String: Any]
        let presets = try #require(document?["presets"] as? [[String: Any]])
        return try #require(presets.first { $0["id"] as? String == id }?["instruction"] as? String)
    }

    /// With no AI chosen, Hook opens the Find Clips popover at the clip bar on Hooks; ⇧⌘K, the menu and ⋯ anchor there too.
    @Test func hookWithNoAIOpensFindClipsAtTheClipBar() async throws {
        let (_, editor, _, bar) = try await open(try fiveQuestions())
        defer { bar.tearDown(); editor.close() }
        editor.app.set("llm.connector", .string(""))
        bar.render()
        #expect(shows(bar.hook) && bar.picker.status.name == "Choose AI" && bar.picker.accessibilityLabel() == "Choose AI")
        bar.hook.performClick(nil)
        #expect(editor.showFindClips && editor.findClipsAnchor == .clipBar && editor.preset == .hooks && editor.findTask == nil)
    }

    // MARK: The harness picker

    @Test func thePickerWritesTheConnectorThatSettingsShows() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.set("llm.connector", .string("claude-code"))
        let picker = HarnessPicker(app: app)
        let menu = picker.makeMenu()
        let titles = menu.items.map(HarnessPicker.name(of:))
        // design.md §3.2: the header, the three groups in order, then Model and AI Settings….
        #expect(titles.first == HarnessPicker.header)
        let headers = menu.items.filter(\.isSectionHeader).map(\.title)
        #expect(headers == ["Installed apps · your own sign-in", "On this Mac", "Your API key"])
        #expect(titles.suffix(2) == ["Model", "AI Settings…"])
        #expect(menu.items.first { $0.representedObject as? String == "claude-code" }?.state == .on)
        #expect(titles.contains("Claude Code (installed CLI)") && titles.contains("Apple on-device") && titles.contains("Anthropic"))
        // Settings → AI binds the same key: choosing Ollama here is what its picker shows, and it hears the change.
        let binding = app.stringBinding("llm.connector")
        let heard = Heard()
        withObservationTracking { _ = app.string("llm.connector") } onChange: { heard.value = true }
        let ollama = try #require(menu.items.first { $0.representedObject as? String == "ollama" })
        picker.choose(ollama)
        #expect(app.string("llm.connector") == "ollama" && binding.wrappedValue == "ollama" && heard.value)
        #expect(picker.status.name == "Ollama")
        // The Model submenu writes the chosen AI's model.
        app.set("llm.connector", .string("anthropic"))
        let models = try #require(picker.makeMenu().items.first { $0.identifier == HarnessPicker.modelItem }?.submenu)
        let sonnet = try #require(models.items.first { ($0.representedObject as? [String])?.last == "claude-sonnet-5-5" })
        picker.chooseModel(sonnet)
        #expect(app.string("llm.model.anthropic") == "claude-sonnet-5-5")
    }

    @Test func detectionRunsOnlyWhenTheMenuOpens() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let fakes: [String: ConsentFixtureConnector] = [
            "claude-code": ConsentFixtureConnector(id: .claudeCode, readiness: .ready, authMethod: "claude.ai"),
            "codex": ConsentFixtureConnector(id: .codex, readiness: .cliSignedOut, authMethod: nil),
            "ollama": ConsentFixtureConnector(id: .ollama, readiness: .ready, authMethod: nil),
            "lmstudio": ConsentFixtureConnector(id: .lmstudio, readiness: .notRunning(url: "http://127.0.0.1:1234"), authMethod: nil),
            "apple-foundation": ConsentFixtureConnector(id: .appleFoundation, readiness: .ready, authMethod: nil),
            "anthropic": ConsentFixtureConnector(id: .anthropic, readiness: .ready, authMethod: nil),
            "openai": ConsentFixtureConnector(id: .openai, readiness: .needsKey, authMethod: nil),
        ]
        app.connectorOverride = { id in fakes[id] ?? ConsentFixtureConnector(id: ConnectorID(rawValue: id) ?? .ollama, readiness: .needsKey, authMethod: nil) }
        app.set("llm.connector", .string("claude-code"))
        app.set("llm.model.ollama", .string("llama4:16b"))
        let (_, editor, _, bar) = try await open(try fiveQuestions(), app: app)
        defer { bar.tearDown(); editor.close() }
        // Drawing the bar and building the menu detect nothing; the picker claims no state yet.
        let menu = bar.picker.makeMenu()
        lay(bar, width: 652)
        for fake in fakes.values { #expect(await fake.statuses == 0) }
        #expect(app.harnessStatus.readiness == .unknown && app.harnessStatus.billing == nil && !app.harnessStatus.detected)
        #expect(bar.picker.accessibilityLabel() == "AI: Claude Code (installed CLI), Sonnet (latest)")
        // Opening the menu detects each AI once, and its rows read their billing.
        bar.picker.menuWillOpen(menu)
        #expect(bar.picker.billing(for: "codex") == "Checking…")
        await bar.picker.startDetection().value
        for (id, fake) in fakes { #expect(await fake.statuses == 1, "\(id)") }
        func trailing(_ id: String) -> String? {
            menu.items.first { $0.representedObject as? String == id }?.attributedTitle?.string.components(separatedBy: "\t").dropFirst().first
        }
        #expect(trailing("claude-code") == "Sonnet (latest) · no extra cost")
        #expect(trailing("codex") == "Not signed in")
        #expect(trailing("ollama") == "llama4:16b · free")
        #expect(trailing("lmstudio") == "Not running")
        #expect(trailing("apple-foundation") == "free · English")
        #expect(trailing("anthropic") == "asks before each send")
        #expect(trailing("openai") == "Add Key…")
        bar.picker.menuDidClose(menu)
        // This session's detection is the status bar's: the dot, the state and the billing.
        bar.render()
        let status = app.harnessStatus
        #expect(status.readiness == .ready && status.dotToken == "status.success" && status.billing == "Sonnet (latest) · no extra cost")
        #expect(bar.picker.accessibilityLabel() == "AI: Claude Code (installed CLI), Sonnet (latest), ready")
        app.set("llm.connector", .string("anthropic"))
        #expect(app.harnessStatus.readiness == .asksFirst && app.harnessStatus.dotToken == "status.warning" && app.harnessStatus.accessibilityLabel.hasSuffix(", asks before each send"))
        app.set("llm.connector", .string("codex"))
        #expect(app.harnessStatus.readiness == .unavailable("not signed in") && app.harnessStatus.dotToken == "text.tertiary" && app.harnessStatus.accessibilityLabel.hasSuffix(", not signed in"))
    }

    // MARK: VoiceOver and the suggestion

    @Test func theBarIsAGroupNamedForItsScope() async throws {
        let (shell, editor, _, bar) = try await open(try fiveQuestions())
        defer { bar.tearDown(); editor.close() }
        #expect(bar.isAccessibilityElement() && bar.accessibilityRole() == .group && bar.accessibilityLabel() == "Full Take tools")
        shell.selection = .clip("five-1")
        bar.render()
        #expect(bar.accessibilityLabel() == "Clip 1 tools")
        #expect(bar.picker.accessibilityRole() == .menuButton && bar.hook.accessibilityLabel() == "Hook: find hook clips in this take")
        // No editable scope: the bar is empty and no group (design.md §3.1).
        editor.mediaResolved = false
        lay(bar, width: 652)
        #expect(bar.variant == .hidden && !bar.isAccessibilityElement())
        let all: [NSView] = [bar.rewrite, bar.tighten, bar.hook, bar.ask, bar.picker, bar.keep]
        #expect(all.allSatisfy { $0.isHidden })
    }

    @Test func aSuggestionsTabKeepsOrDismissesIt() async throws {
        let (shell, editor, undo, bar) = try await open(try fiveQuestions())
        defer { bar.tearDown(); editor.close() }
        shell.selection = .clip("five-5")
        lay(bar, width: 652)
        #expect(bar.variant == .suggestion("five-5") && bar.accessibilityLabel() == "Suggested clip 5 tools")
        #expect(shows(bar.suggestionLabel) && shows(bar.keep) && shows(bar.dismiss))
        let verbs: [NSView] = [bar.rewrite, bar.tighten, bar.hook, bar.ask, bar.picker]
        #expect(verbs.allSatisfy { $0.isHidden })
        #expect(bar.keep.accessibilityLabel() == "Keep suggested clip 5" && bar.dismiss.accessibilityLabel() == "Dismiss suggested clip 5" && bar.keep.hint == "⇧⌘↩")
        // f5: the label at the bar's start, Keep 6 past it, Dismiss beside it, both drawn 22 high in 24 pt targets (impl-plan §3.7).
        #expect(bar.suggestionLabel.frame.minX == ClipBarMetrics.leading && bar.keep.frame.minX == bar.suggestionLabel.frame.maxX + ClipBarMetrics.gap + ClipBarMetrics.keepMargin)
        #expect(bar.dismiss.frame.minX == bar.keep.frame.maxX + ClipBarMetrics.gap)
        #expect(bar.keep.frame.height == 24 && bar.dismiss.frame.height == 24 && abs(bar.keep.frame.midY - 16.5) <= 0.5)
        #expect(bar.keep.chip.height == 22 && bar.keep.chip.midY == bar.keep.bounds.midY && bar.dismiss.chip.height == 22)
        let steps = editor.undoSteps
        undo.beginUndoGrouping(); bar.keep.performClick(nil); undo.endUndoGrouping()
        #expect(editor.undoSteps == steps + 1 && editor.keptClips.contains { $0.id == "five-5" })
        bar.render()
        // Keep moves the scope on to the next row in the same step: the last row's is Full Take.
        #expect(bar.variant == .scope(nil) && shows(bar.picker) && !shows(bar.keep))
        undo.undo()
        shell.selection = .clip("five-5")
        bar.render()
        #expect(bar.variant == .suggestion("five-5"))
        undo.beginUndoGrouping(); bar.dismiss.performClick(nil); undo.endUndoGrouping()
        #expect(!editor.project.edits.clips.contains { $0.id == "five-5" })
    }

    // MARK: Keys

    private func menuItem(_ tag: Int, _ key: Int, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: NSSelectorFromString("performEditorCommand:"), keyEquivalent: String(UnicodeScalar(UInt16(key))!))
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }
    private func keyDown(_ key: Int, _ modifiers: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
        let character = String(UnicodeScalar(UInt16(key))!)
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                                             characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    }

    /// Keep's ⇧⌘↩ on a suggestion's tab (Clip › Keep Suggestion's hidden alternate) answers from the transcript and the
    /// bar, not only from the Explorer; the bare Return and Delete of Keep, Dismiss, Rename and Remove still need the
    /// Explorer's list.
    @Test func keepsShiftCommandReturnWorksFromTheTranscript() async throws {
        let (shell, editor, _, bar) = try await open(try fiveQuestions())
        defer { bar.tearDown(); editor.close() }
        shell.selection = .clip("five-5")
        bar.render()
        #expect(bar.variant == .suggestion("five-5"))
        let transcript = TranscriptNSTextView(usingTextLayoutManager: true)
        transcript.model = editor
        let list = NSTableView()
        let keep = menuItem(40, NSCarriageReturnCharacter, []), alternate = menuItem(40, NSCarriageReturnCharacter, [.command, .shift])
        let dismiss = menuItem(41, NSDeleteCharacter, [])
        let plainReturn = try keyDown(NSCarriageReturnCharacter, [], code: 36), shiftCommandReturn = try keyDown(NSCarriageReturnCharacter, [.command, .shift], code: 36)
        let delete = try keyDown(NSDeleteCharacter, [], code: 51)
        editor.focusedPane = .transcript
        #expect(AppDelegate.clipRowKeyEnabled(alternate, event: shiftCommandReturn, pane: editor.focusedPane, renaming: false, responder: transcript))
        #expect(AppDelegate.clipRowKeyEnabled(alternate, event: shiftCommandReturn, pane: .tabs, renaming: false, responder: bar.keep))
        #expect(!AppDelegate.clipRowKeyEnabled(keep, event: plainReturn, pane: editor.focusedPane, renaming: false, responder: transcript))
        #expect(!AppDelegate.clipRowKeyEnabled(dismiss, event: delete, pane: editor.focusedPane, renaming: false, responder: transcript))
        // The Explorer's list keeps its bare keys; a rename in progress keeps every key, the alternate's too.
        #expect(AppDelegate.clipRowKeyEnabled(keep, event: plainReturn, pane: .sidebar, renaming: false, responder: list))
        #expect(AppDelegate.clipRowKeyEnabled(dismiss, event: delete, pane: .sidebar, renaming: false, responder: list))
        #expect(!AppDelegate.clipRowKeyEnabled(alternate, event: shiftCommandReturn, pane: .sidebar, renaming: true, responder: list))
        // Chosen from the menu, not by a key, they need no focus.
        #expect(AppDelegate.clipRowKeyEnabled(keep, event: nil, pane: .transcript, renaming: false, responder: transcript))
    }

    /// Return and Delete typed in the Ask field stay the field's, also when the Explorer was the last pane to take focus:
    /// the field puts focus in the tab and clip-bar pane, and Rename Clip… and Remove Clip refuse their bare keys while
    /// text is typed.
    @Test func theAskFieldKeepsItsReturnAndDelete() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.set("llm.connector", .string("apple-foundation"))
        app.set("voiceLab.enabled", .bool(true))
        app.set("voiceLab.betaNoticeAccepted", .bool(true))
        let (shell, editor, _, bar) = try await open(try fiveQuestions(), app: app)
        defer { bar.tearDown(); editor.close() }
        shell.selection = .clip("five-1")
        let clip = try #require(editor.activeClip), first = try #require(editor.index(clip.startWordId))
        editor.selectedWordIDs = Set(editor.words[(first + 1)...(first + 3)].map(\.id))
        lay(bar, width: 652)
        #expect(shows(bar.ask) && !editor.isSuggestion("five-1"))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 652, height: ShellMetrics.clipBar), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(bar)
        // The Explorer's row was clicked last; then a click in the field.
        editor.focusedPane = .sidebar
        #expect(window.makeFirstResponder(bar.ask))
        let responder = window.firstResponder
        #expect(responder is NSText && bar.ask.currentEditor() != nil)
        #expect(editor.focusedPane == .tabs)
        let rename = menuItem(43, NSCarriageReturnCharacter, []), remove = menuItem(44, NSDeleteCharacter, [])
        let plainReturn = try keyDown(NSCarriageReturnCharacter, [], code: 36), delete = try keyDown(NSDeleteCharacter, [], code: 51)
        for pane in [EditorPane.sidebar, editor.focusedPane] {
            #expect(!AppDelegate.clipRowKeyEnabled(rename, event: plainReturn, pane: pane, renaming: false, responder: responder), "\(pane)")
            #expect(!AppDelegate.clipRowKeyEnabled(remove, event: delete, pane: pane, renaming: false, responder: responder), "\(pane)")
        }
        // The field's own delegate takes its Return (Rewrite) instead.
        #expect(bar.control(bar.ask, textView: try #require(responder as? NSTextView), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await editor.rewriteOpenTask?.value
        editor.closeRewrite(returnFocus: false)
        #expect(editor.project.edits.clips.contains { $0.id == "five-1" })
    }

    // MARK: Rewrite and Ask

    /// Rewrite and Return in the Ask field run V13's Rewrite on the scope now with the field's text: the tab's clip with
    /// no selection, the selection when there is one, Full Take on its tab. Text Rewrite needs no Voice Lab.
    @Test func rewriteRunsTheScopeNowWithTheFieldAsItsInstruction() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let fake = ConsentFixtureConnector(id: .ollama, readiness: .ready, authMethod: nil)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("ollama"))
        app.set("voiceLab.enabled", .bool(false))
        let (shell, editor, _, bar) = try await open(try fiveQuestions(), app: app)
        defer { bar.tearDown(); editor.closeRewrite(returnFocus: false); editor.close() }
        // Clip 1, nothing selected: Rewrite and the Ask field act on the clip, with the picker inside the field.
        shell.selection = .clip("five-1")
        editor.selectedWordIDs = []
        lay(bar, width: 652)
        #expect(shows(bar.rewrite) && shows(bar.ask) && !shows(bar.askButton) && bar.rewrite.label == "Rewrite")
        #expect(bar.rewrite.accessibilityLabel() == "Rewrite clip 1" && bar.ask.placeholder == "Ask about Clip 1…" && bar.ask.accessibilityLabel() == "Ask about Clip 1")
        #expect(abs(bar.picker.frame.maxX - (bar.ask.frame.maxX - ClipBarMetrics.askTrailing)) <= 0.5)
        bar.ask.stringValue = "Make it punchier"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.ask))
        #expect(editor.rewriteInstruction == "Make it punchier")
        bar.rewrite.performClick(nil)
        await editor.rewriteOpenTask?.value
        let clipSession = try #require(editor.rewrite)
        #expect(clipSession.rewriteScope == .clip("five-1") && clipSession.instruction == "Make it punchier")
        bar.render()
        #expect(bar.rewrite.isOn || shows(bar.rewriting))
        // The run holds the project's AI lease; once the stub answers, Rewrite can run again.
        await clipSession.actionTask?.value
        bar.render()
        #expect(bar.rewrite.isOn && shows(bar.rewrite))
        // A selection: the verb and the field name it, and Return in the field replaces the clip's session with one on it.
        let words = try #require(editor.activeClip.flatMap { editor.index($0.startWordId) })
        editor.selectedWordIDs = Set(editor.words[(words + 2)...(words + 4)].map(\.id))
        bar.render()
        #expect(bar.rewrite.accessibilityLabel() == "Rewrite selection" && bar.ask.placeholder == "Ask about these words…")
        bar.ask.stringValue = "Shorter"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.ask))
        let editorView = NSTextView()
        #expect(bar.control(bar.ask, textView: editorView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await editor.rewriteOpenTask?.value
        let selectionSession = try #require(editor.rewrite)
        #expect(selectionSession !== clipSession && !clipSession.isOpen)
        #expect(selectionSession.rewriteScope == .selection((words + 2)...(words + 4)) && selectionSession.instruction == "Shorter")
        await selectionSession.actionTask?.value
        // Full Take on its tab, nothing selected.
        editor.closeRewrite(returnFocus: false)
        editor.selectedWordIDs = []
        shell.selection = .fullTake
        lay(bar, width: 652)
        #expect(shows(bar.rewrite) && bar.rewrite.accessibilityLabel() == "Rewrite full take" && bar.ask.placeholder == "Ask about Full Take…")
        // An API-key AI asks before each send: "Rewrite…", as Edit › Rewrite's title.
        app.set("llm.connector", .string("anthropic"))
        bar.render()
        #expect(bar.rewrite.label == "Rewrite…" && editor.rewriteMenuTitle == "Rewrite Full Take…")
        // Without AI editing (missing media) the bar holds nothing.
        editor.mediaResolved = false
        lay(bar, width: 652)
        #expect(!shows(bar.rewrite) && !shows(bar.ask))
        // The instruction's limit is 1,000 bytes of UTF-8, cut at a character.
        #expect(ClipBarView.limited(String(repeating: "é", count: 600)).utf8.count == 1_000)
    }

    // MARK: Widths

    /// notes.md §1 at 1280 (652 wide) and impl-plan §3.5's collapses: icons under 600, "Ask…" under 440, and a picker
    /// that keeps its dot and first word.
    @Test func theBarCollapsesAt600And440() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.set("llm.connector", .string("apple-foundation"))
        app.set("voiceLab.enabled", .bool(true))
        app.set("voiceLab.betaNoticeAccepted", .bool(true))
        let (_, editor, _, bar) = try await open(try fiveQuestions(), app: app)
        defer { bar.tearDown(); editor.close() }
        editor.selectedWordIDs = Set(editor.words[20...24].map(\.id))
        editor.app.set("voiceLab.enabled", .bool(true))
        // 652: Rewrite at the bar's start (12 in), then Tighten or Hook, the field to 10 from the end, the picker 3 inside it.
        lay(bar, width: 652)
        #expect(bar.rewrite.frame.minX == 12 && bar.rewrite.frame.height == 24 && abs(bar.rewrite.frame.midY - 16.5) <= 0.5 && !bar.rewrite.iconOnly)
        #expect(bar.hook.frame.minX == bar.rewrite.frame.maxX + 2 || bar.tighten.frame.minX == bar.rewrite.frame.maxX + 2)
        #expect(bar.ask.frame.minX == bar.hook.frame.maxX + 2 + 6 && bar.ask.frame.maxX == 642 && bar.ask.frame.height == 24)
        #expect(abs(bar.picker.frame.maxX - 639) <= 0.5 && !bar.picker.compact)
        for (width, icons, button) in [(600.0, false, false), (599.0, true, false), (440.0, true, false), (439.0, true, true), (300.0, true, true)] {
            lay(bar, width: width)
            let label = "at \(Int(width))"
            #expect([bar.rewrite, bar.hook].allSatisfy { $0.iconOnly == icons }, "\(label)")
            if icons { #expect(bar.rewrite.frame.width == 24 && bar.hook.toolTip != nil && bar.rewrite.toolTip != nil, "\(label)") }
            #expect(shows(bar.askButton) == button && shows(bar.ask) == !button, "\(label)")
            // The picker never truncates below its dot and first word, and stays inside the bar.
            #expect(bar.picker.frame.width >= bar.picker.compactWidth && bar.picker.frame.maxX <= width - ClipBarMetrics.trailing, "\(label)")
            let controls = [bar.rewrite, bar.tighten, bar.hook, bar.askButton, bar.ask].filter(shows)
            for (left, right) in zip(controls, controls.dropFirst()) {
                #expect(left.frame.maxX <= right.frame.minX, "\(label): \(left.identifier?.rawValue ?? "") overlaps \(right.identifier?.rawValue ?? "")")
            }
            // The picker sits inside the field's end, or after the last control.
            #expect(bar.picker.frame.minX >= (button ? bar.askButton.frame.maxX : bar.ask.frame.minX), "\(label)")
        }
        lay(bar, width: 220)
        #expect(bar.picker.compact && bar.picker.shownName == "Apple" && bar.picker.frame.minX >= bar.askButton.frame.maxX)
    }

    /// Tab from the active tab goes on into the clip bar; F6 still stops at the tab (V3a).
    @Test func tabFromTheActiveTabReachesTheClipBar() async throws {
        let (shell, editor, _, bar) = try await open(try fiveQuestions())
        defer { bar.tearDown(); editor.close() }
        let work = EditorWorkController(model: editor, shell: shell)
        defer { work.tearDown() }
        work.tabBar.render()
        #expect(work.tabBar.activeItem?.nextKeyView === work.clipBar && work.clipBar.nextKeyView === work.clipBar.rewrite)
        #expect(work.clipBar.identifier?.rawValue == "voxclip.shell.clipBar")
    }
}
#endif
