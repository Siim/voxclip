#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The status bar (impl-plan V11a): the AI's name with its billing only after this session's detection (item 14), the
/// running task from the Director task and Find Clips with its elapsed time, the tab's edit summary, the Frame that
/// opens View › Frame's choices, the export state, VoiceOver's group with values, f1's measurements and the narrow
/// drop order. Stub connectors only, settings in memory, nothing shown.
@Suite("Status bar", .serialized)
@MainActor struct StatusBarTests {
    init() { _ = NSApplication.shared }
    private func fiveQuestions() throws -> Project {
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugSidebar.fiveQuestions(from: base)
        project.export.aspect = .landscape
        return project
    }
    /// An app with `connector` chosen and fixture connectors for detection; nothing leaves the Mac.
    private func app(_ connector: String?, _ fakes: [String: ConsentFixtureConnector] = [:]) -> AppModel {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.connectorOverride = { id in fakes[id] ?? ConsentFixtureConnector(id: ConnectorID(rawValue: id) ?? .ollama, readiness: .cliMissing, authMethod: nil) }
        if let connector { app.set("llm.connector", .string(connector)) }
        return app
    }
    /// A shell with the five questions open on Full Take, its media treated as found, and a bar `width` wide.
    private func open(_ app: AppModel, width: CGFloat = 1280) async throws -> (WorkspaceShell, EditorModel, UndoManager, StatusBarView) {
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try fiveQuestions(), demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let bar = StatusBarView(shell: shell)
        bar.shellGroup("Status")
        lay(bar, width: width)
        return (shell, editor, undo, bar)
    }
    private func lay(_ bar: StatusBarView, width: CGFloat) {
        bar.render()
        bar.frame = NSRect(x: 0, y: 0, width: width, height: ShellMetrics.statusBar)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
    }
    private func detect(_ app: AppModel) async {
        if let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) { _ = await app.connectorStatus(provider) }
    }

    // MARK: The AI and its billing (item 14)

    @Test func theBillingPhraseWaitsForThisSessionsDetection() async throws {
        let app = app("claude-code", ["claude-code": ConsentFixtureConnector(id: .claudeCode, readiness: .ready, authMethod: "claude.ai")])
        let (_, editor, _, bar) = try await open(app)
        defer { bar.tearDown(); editor.close() }
        // Before detection: the name and a ring, no billing phrase anywhere, also not for VoiceOver.
        let before = try #require(bar.content[.harness])
        #expect(before.text == "Claude Code · Sonnet (latest)" && before.lead == .dot(token: "text.tertiary", filled: false))
        #expect(bar.content[.billing] == nil && !bar.shown.contains(.billing))
        #expect(bar.itemView(.harness)?.accessibilityValue() as? String == "Claude Code (installed CLI), Sonnet (latest)")
        // A send's or the picker's detection in this session brings the C8 phrase and the dot.
        await detect(app)
        lay(bar, width: 1280)
        let after = try #require(bar.content[.harness])
        #expect(after.lead == .dot(token: "status.success", filled: true))
        #expect(bar.content[.billing]?.text == "No extra cost on your plan" && bar.content[.billing]?.dim == true)
        #expect(Array(bar.shown.prefix(2)) == [.harness, .billing])
        #expect(bar.itemView(.harness)?.accessibilityValue() as? String == "Claude Code (installed CLI), Sonnet (latest), no extra cost on your plan")
    }

    @Test(arguments: [
        ("claude-code", ConnectorID.claudeCode, ConnectorStatus.ready, "api_key" as String?, "Billed to your key", "status.warning"),
        ("codex", .codex, .cliSignedOut, nil, "Not signed in", "text.tertiary"),
        ("ollama", .ollama, .ready, nil, "No extra cost", "status.success"),
        ("anthropic", .anthropic, .ready, nil, "Billed to your key", "status.warning"),
    ])
    func theBillingSaysWhoPays(_ id: String, _ connector: ConnectorID, _ readiness: ConnectorStatus, _ method: String?, _ phrase: String, _ dot: String) async throws {
        let app = app(id, [id: ConsentFixtureConnector(id: connector, readiness: readiness, authMethod: method)])
        let (_, editor, _, bar) = try await open(app)
        defer { bar.tearDown(); editor.close() }
        #expect(bar.content[.billing] == nil)
        await detect(app)
        bar.render()
        #expect(bar.content[.billing]?.text == phrase)
        if case .dot(let token, true) = bar.content[.harness]?.lead { #expect(token == dot) } else { Issue.record("no filled dot after detection") }
    }

    @Test func withNoAIChosenTheBarShowsNoAI() async throws {
        let (_, editor, _, bar) = try await open(app(nil))
        defer { bar.tearDown(); editor.close() }
        #expect(bar.content[.harness] == nil && bar.content[.billing] == nil && bar.shown == [.summary, .frame, .export])
    }

    // MARK: The running task

    @Test func theRunningTaskReadsFindClipsAndTheDirectorTask() async throws {
        let app = app("ollama", ["ollama": ConsentFixtureConnector(id: .ollama, readiness: .ready, authMethod: nil)])
        app.set("voiceLab.enabled", .bool(true))
        app.set("voiceLab.betaNoticeAccepted", .bool(true))
        app.connectorConsentOverride = { _, _, _ in true }
        let (_, editor, _, bar) = try await open(app)
        defer { bar.tearDown(); editor.close() }
        #expect(bar.content[.task] == nil)
        // Find Clips (Hook's or the popover's): "Finding clips… 0:12", the time in SF Mono, a spinner.
        editor.finding = true
        let since = try #require(editor.findingSince)
        bar.now = { since.addingTimeInterval(12.2) }
        bar.render()
        let finding = try #require(bar.content[.task])
        #expect(finding.text == "Finding clips… 0:12" && finding.lead == .spinner && bar.content.taskSince == since)
        #expect(finding.parts.last == StatusText(string: "0:12", mono: true) && finding.spoken == "Finding clips, 12 seconds")
        bar.now = { since.addingTimeInterval(73) }
        bar.tick()
        #expect(bar.content[.task]?.text == "Finding clips… 1:13")
        editor.finding = false
        #expect(editor.findingSince == nil)
        bar.render()
        #expect(bar.content[.task] == nil && bar.content.taskSince == nil)
        // A Rewrite run: the task's own headline and start (V12m), not a copy of them.
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))
        editor.selectedWordIDs = Set(editor.words[3...5].map(\.id))
        editor.beginRewrite()
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.openRewrite)
        await session.actionTask?.value
        let started = Date(timeIntervalSince1970: 1_000)
        session.task.show(.running, headline: PanelHeadline(text: "Rewriting these words…", runningSince: started))
        bar.now = { started.addingTimeInterval(5) }
        bar.render()
        #expect(bar.content[.task]?.text == "Rewriting these words… 0:05" && bar.content[.task]?.spoken == "Rewriting these words, 5 seconds" && bar.content.taskSince == started)
        session.task.show(.ready, headline: PanelHeadline(text: session.task.words.title))
        bar.render()
        #expect(bar.content[.task] == nil)
        // Transcription shows its own progress line.
        editor.progress = "Transcribing on this Mac · 42%"
        bar.render()
        #expect(bar.content[.task]?.text == "Transcribing on this Mac · 42%" && bar.content.taskSince == nil)
        editor.progress = nil
        editor.closeRewrite(returnFocus: false)
    }

    // MARK: The summary

    @Test func theSummaryNamesTheTabWithItsDurationCutsAndChanges() async throws {
        let app = app("ollama", ["ollama": ConsentFixtureConnector(id: .ollama, readiness: .ready, authMethod: nil)])
        app.set("voiceLab.enabled", .bool(true))
        app.set("voiceLab.betaNoticeAccepted", .bool(true))
        app.connectorConsentOverride = { _, _, _ in true }
        let (shell, editor, _, bar) = try await open(app)
        defer { bar.tearDown(); editor.close() }
        #expect(bar.content[.summary]?.text == "Full Take · 2:10 · 8 cuts")
        // A proposal waiting on this tab adds its changes (V12m's change set).
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))
        editor.selectedWordIDs = Set(editor.words[3...5].map(\.id))
        editor.beginRewrite()
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.openRewrite)
        await session.actionTask?.value
        let items = (1...5).map { ProposalItem(ordinal: $0, kind: .cut, sourceWordIDs: [editor.words[$0].id], newWords: []) }
        session.task.show(.proposal(ChangeSet(items: items)), headline: PanelHeadline(text: "5 changes"))
        bar.render()
        #expect(bar.content[.summary]?.text == "Full Take · 2:10 · 8 cuts · 5 changes to review")
        #expect(bar.content[.summary]?.spoken == "Full Take, 2 minutes 10 seconds, 8 cuts, 5 changes to review")
        // Undo on a pending hunk excludes it; excluded items no longer await review (plan item 7).
        var pending = items
        for index in 1..<pending.count { pending[index].included = false }
        session.task.show(.proposal(ChangeSet(items: pending)), headline: PanelHeadline(text: "1 change"))
        bar.render()
        #expect(bar.content[.summary]?.text == "Full Take · 2:10 · 8 cuts · 1 change to review")
        pending[0].included = false
        session.task.show(.proposal(ChangeSet(items: pending)), headline: PanelHeadline(text: "No changes needed"))
        bar.render()
        #expect(bar.content[.summary]?.text == "Full Take · 2:10 · 8 cuts")
        // A proposal belongs to its own tab, even while the session remains open.
        session.task.show(.proposal(ChangeSet(items: items)), headline: PanelHeadline(text: "5 changes"))
        shell.selection = .clip(editor.keptClips[1].id)
        bar.render()
        #expect(bar.content[.summary]?.text == "Clip 2 · 0:20 · 2 cuts")
        shell.selection = .fullTake
        editor.closeRewrite(returnFocus: false)
        bar.render()
        #expect(bar.content[.summary]?.text == "Full Take · 2:10 · 8 cuts")
        let kept = editor.keptClips
        shell.selection = .clip(kept[1].id)
        bar.render()
        let clip = try #require(bar.content[.summary])
        #expect(clip.text == "Clip 2 · 0:20 · 2 cuts" && clip.parts.filter(\.mono).map(\.string) == ["0:20"] && !clip.dim)
        #expect(clip.spoken == "Clip 2, 20 seconds, 2 cuts" && clip.help == editor.summaryDetail)
        #expect(bar.itemView(.summary)?.accessibilityHelp() == editor.summaryDetail)
        shell.selection = .clip(kept[3].id)
        bar.render()
        #expect(bar.content[.summary]?.text == "Clip 4 · 0:11 · No cuts yet")
    }

    // MARK: Frame and export

    @Test func theFrameOpensViewFramesChoicesAndSetsTheAspect() async throws {
        let (_, editor, undo, bar) = try await open(app(nil))
        defer { bar.tearDown(); editor.close() }
        let button = bar.frameButton
        #expect(bar.content[.frame]?.text == "16:9 · 1080p30" && bar.content[.frame]?.dim == true)
        #expect(button.isEnabled && button.accessibilityRole() == .popUpButton && button.accessibilityLabel() == "Frame")
        #expect(button.accessibilityValue() as? String == "16:9, 1080p30")
        let menu = button.makeMenu()
        #expect(menu.items.map(\.title) == ["9:16", "1:1", "16:9", "Original"] && menu.items.map(\.title) == AppDelegate.frameAspects.map(\.frameName))
        #expect(menu.items.map(\.tag) == [52, 53, 54, 55])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["16:9"])
        // A choice is View › Frame's: setAspect's one undo step.
        let steps = editor.undoSteps
        undo.beginUndoGrouping(); button.chooseAspect(menu.items[0]); undo.endUndoGrouping()
        #expect(editor.project.export.aspect == .portrait && editor.undoSteps == steps + 1 && undo.undoActionName == "Change aspect")
        bar.render()
        #expect(bar.content[.frame]?.text == "9:16 · 1080p30" && button.makeMenu().items.filter { $0.state == .on }.map(\.title) == ["9:16"])
        undo.beginUndoGrouping(); button.chooseAspect(menu.items[3]); undo.endUndoGrouping()
        bar.render()
        #expect(bar.content[.frame]?.text == "Original · 1080p30")
        // Where the Frame cannot change it only reads.
        editor.mediaResolved = false
        bar.render()
        #expect(!button.isEnabled && button.accessibilityRole() == .staticText && bar.content[.frame]?.text == "Original · 1080p30")
        let unavailableSteps = editor.undoSteps
        button.chooseAspect(menu.items[0])
        #expect(editor.project.export.aspect == .source && editor.undoSteps == unavailableSteps)
    }

    @Test func theExportStateFollowsTheRunAndItsFailures() async throws {
        let (shell, editor, _, bar) = try await open(app(nil))
        defer { bar.tearDown(); editor.close() }
        #expect(bar.content[.export] == StatusItem(kind: .export, lead: .symbol("square.and.arrow.up"), parts: [StatusText(string: "Not exported")], dim: true, spoken: "Not exported"))
        editor.exporting = true
        editor.exportProgress = ExportProgress(phase: .encoding, fraction: 0.42)
        bar.render()
        #expect(bar.content[.export]?.text == "Exporting 42%" && bar.content[.export]?.dim == false)
        editor.exportClipIDs = editor.keptClips.prefix(3).map(\.id)
        editor.exportIndex = 2
        bar.render()
        #expect(bar.content[.export]?.text == "Exporting 2 of 3 · 42%" && bar.content[.export]?.spoken == "Exporting 2 of 3, 42%")
        editor.exporting = false
        let clip = editor.keptClips[0].id
        shell.selection = .clip(clip)
        editor.failedExports[ExportLedger.key(.clip(clip), aspect: editor.project.export.aspect)] = FileManager.default.temporaryDirectory
        bar.render()
        #expect(bar.content[.export]?.text == "Export failed" && bar.content[.export]?.lead == .symbol("exclamationmark.triangle") && bar.content[.export]?.dim == false)
    }

    // MARK: VoiceOver, measurements, narrow widths

    @Test func theItemsReadAsTheStatusGroupWithValues() async throws {
        let app = app("claude-code", ["claude-code": ConsentFixtureConnector(id: .claudeCode, readiness: .ready, authMethod: "claude.ai")])
        let (shell, editor, _, bar) = try await open(app)
        defer { bar.tearDown(); editor.close() }
        await detect(app)
        shell.selection = .clip(editor.keptClips[1].id)
        editor.finding = true
        let since = try #require(editor.findingSince)
        bar.now = { since.addingTimeInterval(12) }
        lay(bar, width: 1280)
        #expect(bar.isAccessibilityElement() && bar.accessibilityRole() == .group && bar.accessibilityLabel() == "Status")
        let children = try #require(bar.accessibilityChildren() as? [NSView])
        #expect(children.map { $0.accessibilityLabel() ?? "" } == ["AI", "In progress", "Edit summary", "Frame", "Export"])
        #expect(children.map { $0.accessibilityValue() as? String ?? "" } == [
            "Claude Code (installed CLI), Sonnet (latest), no extra cost on your plan", "Finding clips, 12 seconds",
            "Clip 2, 20 seconds, 2 cuts", "16:9, 1080p30", "Not exported",
        ])
        #expect(children.map { $0.accessibilityRole() } == [.staticText, .staticText, .staticText, .popUpButton, .staticText])
        let summary = try #require(children.first { $0.accessibilityLabel() == "Edit summary" })
        #expect(summary.accessibilityHelp() == editor.summaryDetail)
        editor.finding = false
    }

    @Test func f1sItemsSitWhereTheMockupDrawsThem() async throws {
        let app = app("claude-code", ["claude-code": ConsentFixtureConnector(id: .claudeCode, readiness: .ready, authMethod: "claude.ai")])
        let (_, editor, _, bar) = try await open(app)
        defer { bar.tearDown(); editor.close() }
        await detect(app)
        lay(bar, width: 1280)
        #expect(bar.shown == [.harness, .billing, .summary, .frame, .export])
        let harness = try #require(bar.view(.harness)), billing = try #require(bar.view(.billing))
        let summary = try #require(bar.view(.summary)), frame = try #require(bar.view(.frame)), export = try #require(bar.view(.export))
        // notes.md `.sbar` / `.si`: 8 pt in, items 7 pt in from their sides, 2 between them, 6 between a lead and its text.
        #expect(harness.frame.minX == 8 && harness.frame.height == 24 && bar.frame.height == 24)
        let textX = StatusBarMetrics.textX(try #require(bar.content[.harness]))
        #expect(harness.frame.minX + textX == 27, "the AI's name starts at \(harness.frame.minX + textX)")
        #expect(billing.frame.minX == harness.frame.maxX + 2)
        #expect(export.frame.maxX == 1272 && frame.frame.maxX == export.frame.minX - 2 && summary.frame.maxX == frame.frame.minX - 2)
        // The fill and the hairline (the mockup's #141517 under a #28292D line).
        bar.appearance = NSAppearance(named: .darkAqua)
        let bitmap = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
        bar.cacheDisplay(in: bar.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / bar.bounds.height
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? { bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) }
        func token(_ path: String) -> NSColor? {
            var color: NSColor?
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { color = DesignValues.nsColor(path).usingColorSpace(.sRGB) }
            return color
        }
        func near(_ a: NSColor?, _ b: NSColor?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.redComponent - b.redComponent) < 0.03 && abs(a.greenComponent - b.greenComponent) < 0.03 && abs(a.blueComponent - b.blueComponent) < 0.03
        }
        let gap = (billing.frame.maxX + summary.frame.minX) / 2
        #expect(near(pixel(gap, 12), token("bg.statusBar")))
        #expect(near(pixel(gap, 0.5), token("line.default")))
    }

    @Test func aNarrowBarDropsTheBillingFirstAndTruncatesTheSummaryLast() async throws {
        let app = app("claude-code", ["claude-code": ConsentFixtureConnector(id: .claudeCode, readiness: .ready, authMethod: "claude.ai")])
        let (_, editor, _, bar) = try await open(app)
        defer { bar.tearDown(); editor.close() }
        await detect(app)
        editor.finding = true
        let since = try #require(editor.findingSince)
        bar.now = { since.addingTimeInterval(12) }
        lay(bar, width: 1280)
        let all: [StatusItem.Kind] = [.harness, .billing, .task, .summary, .frame, .export]
        #expect(bar.shown == all)
        func width(_ kinds: [StatusItem.Kind]) -> CGFloat {
            let leading = kinds.filter(StatusItem.Kind.leading.contains), trailing = kinds.filter(StatusItem.Kind.trailing.contains)
            func run(_ run: [StatusItem.Kind]) -> CGFloat { run.reduce(0) { $0 + StatusBarMetrics.naturalWidth(bar.content[$1]!) } + CGFloat(max(0, run.count - 1)) * 2 }
            return 16 + run(leading) + run(trailing) + (leading.isEmpty || trailing.isEmpty ? 0 : 16)
        }
        // Each step one point too narrow for what is shown drops the next item in order.
        var expected = all
        for dropped in [StatusItem.Kind.billing, .frame, .export, .harness, .task] {
            lay(bar, width: width(expected) - 1)
            expected.removeAll { $0 == dropped }
            #expect(bar.shown == expected, "after dropping \(dropped)")
            let shown = bar.shown.compactMap { bar.view($0) }
            #expect(zip(shown, shown.dropFirst()).allSatisfy { $0.frame.maxX <= $1.frame.minX }, "items overlap after dropping \(dropped)")
        }
        // The summary stays, truncated to what is left.
        lay(bar, width: 120)
        #expect(bar.shown == [.summary])
        let summary = try #require(bar.view(.summary))
        #expect(summary.frame.minX >= 8 && summary.frame.maxX == 112 && summary.frame.width < StatusBarMetrics.naturalWidth(bar.content[.summary]!))
        editor.finding = false
    }

    @Test func homeShowsNothing() async throws {
        let (shell, editor, _, bar) = try await open(app("claude-code"))
        defer { bar.tearDown(); editor.close() }
        shell.selection = .home
        lay(bar, width: 1280)
        #expect(bar.content == StatusBarContent() && bar.shown.isEmpty && (bar.accessibilityChildren() ?? []).isEmpty)
    }
}
#endif
