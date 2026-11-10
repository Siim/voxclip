#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

@Suite("Explorer", .serialized, .offlineFixtures)
@MainActor struct ExplorerTests {
    private func open(demo: Bool = true) async throws -> (WorkspaceShell, EditorModel) {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        await shell.attachForTesting(VoxClipDocument(project: try DebugExplorer.fiveQuestions(from: base), demo: demo), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let undo = try #require(editor.document.undoManager)
        undo.groupsByEvent = false
        editor.undoManager = undo
        return (shell, editor)
    }

    @Test func headlessDebugChecksUseTheProductionOutlineAndMetrics() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let checks = DebugExplorer.explorerChecks(shell: shell)
        #expect(checks.count == 6)
        #expect(checks.allSatisfy { $0.passed })
    }

    @Test(arguments: ["selected", "focused", "hovered", "idle", "suggested", "suggestedIdle"], [176.0, 196.0, 200.0, 224.0])
    func clipRowActionsReplaceDurationOnSelectedHoveredOrFocusedRows(_ state: String, width: Double) async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let suggested = state.hasPrefix("suggested")
        var clip = try #require(suggested ? editor.suggestedClips.first : editor.keptClips.first)
        clip.title = "A long clip title that must truncate before the trailing row actions"
        if state == "selected" || state == "suggested" { shell.choose(.clip(clip.id)) }
        let row = NSHostingView(rootView: ClipRow(shell: shell, editor: editor, clip: clip, suggested: suggested,
                                                selectedFocused: state == "focused", hovering: state == "hovered").frame(width: width))
        row.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        row.layoutSubtreeIfNeeded()
        let markers = DebugRightColumn.markers(in: row)
        let showsActions = state != "idle" && state != "suggestedIdle"
        #expect((markers["explorer.clipActions"] != nil) == showsActions)
        #expect((markers["explorer.clipDuration"] != nil) == !showsActions)
        #expect(row.fittingSize.height == 28)
        if let actions = markers["explorer.clipActions"] {
            #expect(actions.minX >= 0 && actions.maxX <= width)
            let title = try #require(markers["explorer.clipTitle"])
            #expect(title.width > 0 && title.maxX <= actions.minX)
            #expect(markers["explorer.clipMakeIt"]?.size == CGSize(width: 22, height: 20))
            #expect(markers["explorer.clipMore"]?.size == CGSize(width: 22, height: 20))
        }
    }

    /// The user never saw the row actions: the selected suggestion always shows ✦ and ⋯, and so does a hovered or
    /// focused one; an idle, unselected suggestion keeps its duration.
    @Test func suggestedRowsShowActionsWhileSelectedHoveredOrFocused() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let clip = try #require(editor.suggestedClips.first)
        #expect(!ClipRow(shell: shell, editor: editor, clip: clip, suggested: true).showsActions)
        #expect(ClipRow(shell: shell, editor: editor, clip: clip, suggested: true, hovering: true).showsActions)
        #expect(ClipRow(shell: shell, editor: editor, clip: clip, suggested: true, focused: true).showsActions)
        shell.choose(.clip(clip.id))
        #expect(ClipRow(shell: shell, editor: editor, clip: clip, suggested: true).showsActions)
        #expect(shell.canRewriteExplorerClip(clip.id))
        let host = NSHostingView(rootView: ClipRow(shell: shell, editor: editor, clip: clip, suggested: true).frame(width: 196))
        host.frame = NSRect(x: 0, y: 0, width: 196, height: 28)
        host.layoutSubtreeIfNeeded()
        let markers = DebugRightColumn.markers(in: host)
        #expect(markers["explorer.clipMakeIt"]?.size == CGSize(width: 22, height: 20))
        #expect(markers["explorer.clipMore"]?.size == CGSize(width: 22, height: 20))
        #expect(host.fittingSize.height == 28)
    }

    /// The user: suggested clips "should also have the same option for the rewrite". Rewrite on a suggestion keeps it
    /// first, as one undo step with no prompt, then opens Rewrite on that clip exactly as on a kept clip.
    @Test func rewriteFromASuggestedRowKeepsItThenOpensRewriteOnTheClip() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        editor.app.settings.values["voiceLab.enabled"] = .bool(false)
        editor.app.settings.values["llm.connector"] = .string("ollama")
        editor.app.connectorOverride = { _ in ConsentFixtureConnector(id: .ollama) }
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))
        #expect(editor.isSuggestion("five-5"))
        let undo = try #require(editor.undoManager)
        let steps = editor.undoSteps
        undo.beginUndoGrouping(); shell.rewriteExplorerClip("five-5"); undo.endUndoGrouping()
        await editor.rewriteOpenTask?.value
        #expect(!editor.isSuggestion("five-5") && editor.keptClips.contains { $0.id == "five-5" })
        #expect(editor.undoSteps == steps + 1 && undo.undoActionName == "Keep clip")
        #expect(!editor.sendConfirmation.isPresented)
        let session = try #require(editor.openRewrite)
        #expect(session.rewriteScope == .clip("five-5") && session.scope == .clip("five-5"))
        #expect(editor.project.edits.activeClipId == "five-5" && shell.tabs.active == .clip("five-5") && shell.tabs.preview == nil)
        editor.closeRewrite(returnFocus: false)
        undo.undo()
        #expect(editor.isSuggestion("five-5"))
    }

    /// Export on a suggestion keeps it the same way, then opens the Export job on that clip.
    @Test func exportFromASuggestedRowKeepsItThenOpensExportOnTheClip() async throws {
        let (shell, editor) = try await open(demo: false)
        defer { editor.close() }
        #expect(shell.canExportExplorerClip("five-5"))
        let undo = try #require(editor.undoManager)
        let steps = editor.undoSteps
        undo.beginUndoGrouping(); shell.exportExplorerClip("five-5"); undo.endUndoGrouping()
        #expect(!editor.isSuggestion("five-5") && editor.undoSteps == steps + 1 && undo.undoActionName == "Keep clip")
        #expect(editor.exportJob.isOpen && editor.exportJob.requestedIDs == ["five-5"] && editor.exportJob.scope == .thisClip)
        // A kept row exports without another undo step.
        let kept = editor.undoSteps
        shell.exportExplorerClip("five-1")
        #expect(editor.undoSteps == kept && editor.exportJob.requestedIDs == ["five-1"])
    }

    /// ⋯'s Captions shows the Captions job on that clip; Find More Clips opens Find Clips with no AI chosen and is off
    /// while a search runs. Neither is an undo step.
    @Test func moreMenuCaptionsAndFindMoreClipsAct() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let steps = editor.undoSteps
        shell.captionExplorerClip("five-5")
        #expect(shell.selection == .clip("five-5") && shell.panelJob(for: editor) == .captions)
        #expect(editor.isSuggestion("five-5"))
        editor.app.settings.values["llm.connector"] = .string("")
        #expect(shell.canFindMoreClips)
        shell.findMoreClips()
        #expect(editor.showFindClips && editor.findClipsAnchor == .sidebar)
        editor.finding = true
        #expect(!shell.canFindMoreClips)
        editor.finding = false
        #expect(editor.undoSteps == steps && !editor.document.isDocumentEdited)
    }

    @Test func unavailableRewriteLeavesMoreVisibleWithoutAddingAnAction() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let clip = try #require(editor.keptClips.first)
        shell.choose(.clip(clip.id))
        editor.isLeaving = true
        let host = NSHostingView(rootView: ClipRow(shell: shell, editor: editor, clip: clip, suggested: false).frame(width: 196))
        host.frame = NSRect(x: 0, y: 0, width: 196, height: 28)
        host.layoutSubtreeIfNeeded()
        let markers = DebugRightColumn.markers(in: host)
        #expect(markers["explorer.clipMakeIt"] == nil && markers["explorer.clipDuration"] == nil)
        #expect(markers["explorer.clipMore"]?.size == CGSize(width: 22, height: 20))
    }

    @Test func clipRowActionsShareRewriteMenuAndAccessibilityWithoutKeyboardStops() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/ExplorerView.swift"), encoding: .utf8)
        let row = try #require(source.components(separatedBy: "@MainActor struct ClipRow: View").last?.components(separatedBy: "@MainActor private struct ExplorerClipMenu").first)
        #expect(row.contains(".onHover"))
        #expect(row.contains("shell.canRewriteExplorerClip(clip.id)"))
        #expect(row.contains("shell.rewriteExplorerClip(clip.id)"))
        // ✦ is Make it postable (design.md §6.7); Rewrite stays in ⋯, the context menu and the accessibility actions.
        #expect(row.contains("MakeItRowButton(model: editor, clipID: clip.id) { editor.makeItPostable(clip.id) }"))
        #expect(row.components(separatedBy: "ExplorerClipMenu(shell:").count == 3)
        #expect(row.contains(".focusable(false)"))
        let actions = try #require(row.components(separatedBy: ".accessibilityActions {").last)
        #expect(actions.contains("Button(\"Rewrite Clip \\(number)\")"))
        #expect(actions.contains("Button(\"Export Clip\") { shell.exportExplorerClip(clip.id) }"))
        for name in ["Captions", "Find More Clips", "Keep", "Dismiss"] { #expect(actions.contains("Button(\"\(name)\")")) }
        // ⋯ and the context menu: the shared actions for every row, then Keep and Dismiss for a suggestion.
        let menu = try #require(source.components(separatedBy: "@MainActor private struct ExplorerClipMenu").last?.components(separatedBy: "private var clipText").first)
        let shared = try #require(menu.components(separatedBy: "if suggested {").first)
        for name in ["Rewrite Clip \\(", "Captions", "Find More Clips", "Export Clip…"] { #expect(shared.contains("Button(\"\(name)")) }
        #expect(menu.contains("Button(\"Keep Clip\")") && menu.contains("Button(\"Dismiss\")"))
        #expect(row.contains(".accessibilityElement(children: shell.renaming == clip.id ? .contain : .combine)"))
    }

    @Test func outlineUsesTakeParagraphsAndFiltersWithoutReflowing() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let paragraphs = TranscriptParagraphs.split(words: editor.words)
        #expect(shell.outlineEntries.map(\.words) == paragraphs)
        #expect(shell.outlineEntries.map(\.id) == Array(paragraphs.indices))
        let first = try #require(shell.outlineEntries.first)
        #expect(first.time == TranscriptGutter.timecode(editor.words[first.words.lowerBound].start))
        #expect(first.title == editor.words[first.words.prefix(6)].map { editor.text($0) }.joined(separator: " "))
        let take = shell.outlineEntries
        shell.choose(.clip("five-2"))
        let scope = try #require(editor.scopeBounds)
        let expected = take.filter { $0.words.overlaps(scope.lowerBound..<(scope.upperBound + 1)) }
        #expect(!expected.isEmpty && shell.outlineEntries == expected)
        editor.showsCuts.toggle()
        #expect(shell.outlineEntries == expected)
        shell.choose(.fullTake)
        #expect(shell.outlineEntries == take)
        shell.choose(.home)
        #expect(shell.outlineEntries.isEmpty)
    }

    @Test func outlineClickRequestsScrollWithoutChangingScopeSelectionOrDocument() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        shell.choose(.clip("five-2"))
        let entry = try #require(shell.outlineEntries.last)
        let scope = editor.project.edits.activeClipId
        editor.selectedWordIDs = [editor.words[entry.words.lowerBound].id]
        let selected = editor.selectedWordIDs, steps = editor.undoSteps, revision = editor.scopeScrollRevision
        shell.choose(.outline(entry.id), byClick: false)
        #expect(shell.selection == .outline(entry.id) && shell.tabs.active == .clip("five-2"))
        #expect(editor.project.edits.activeClipId == scope && editor.selectedWordIDs == selected)
        #expect(editor.scopeScrollRevision == revision + 1 && editor.outlineScrollWordID == editor.words[entry.words.lowerBound].id)
        shell.choose(.outline(entry.id), byClick: false)
        #expect(editor.scopeScrollRevision == revision + 2)
        #expect(editor.undoSteps == steps && !editor.document.isDocumentEdited && !editor.document.hasUnautosavedChanges)
        shell.selectTab(.fullTake)
        #expect(editor.outlineScrollWordID == nil && shell.selection == .fullTake)
    }

    @Test func outlineScrollUsesTheTranscriptScrollAPI() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let coordinator = TranscriptTextView.Coordinator(model: editor)
        let scroll = TranscriptTextView.makeScrollView(model: editor, coordinator: coordinator, width: 652, height: 120)
        let text = try #require(scroll.documentView as? TranscriptNSTextView)
        TranscriptTextView.render(editor, coordinator: coordinator)
        let entry = try #require(shell.outlineEntries.last)
        shell.choose(.outline(entry.id))
        TranscriptTextView.scrollIfRequested(editor, coordinator: coordinator, in: text)
        #expect(coordinator.scopeScrollRevision == editor.scopeScrollRevision)
        #expect(scroll.contentView.bounds.minY > 0)
        let target = try #require(text.map.span(id: editor.words[entry.words.lowerBound].id))
        let line = try #require(text.lineBox(atCharacter: target.range.location))
        #expect(text.visibleRect.intersects(line))
    }

    @Test func singleClickPreviewsKeptClipsAndDoubleClickPins() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let steps = editor.undoSteps
        shell.choose(.clip("five-1"), byClick: true)
        #expect(shell.tabs.preview == .clip("five-1") && shell.tabs.open == [.fullTake, .clip("five-1")])
        shell.syncTabs()
        #expect(shell.tabs.preview == .clip("five-1"))
        shell.choose(.clip("five-2"), byClick: true)
        #expect(shell.tabs.preview == .clip("five-2") && !shell.tabs.open.contains(.clip("five-1")))
        shell.pinExplorerRows([.clip("five-2")])
        #expect(shell.tabs.preview == nil && shell.tabs.open == [.clip("five-2"), .fullTake])
        shell.choose(.clip("five-3"), byClick: true)
        #expect(shell.tabs.open == [.clip("five-2"), .fullTake, .clip("five-3")])
        shell.choose(.clip("five-2"), byClick: true)
        #expect(shell.tabs.preview == .clip("five-3") && shell.tabs.active == .clip("five-2"))
        #expect(editor.undoSteps == steps && !editor.document.isDocumentEdited && !editor.document.hasUnautosavedChanges)
    }

    @Test func rewriteOnAPreviewPinsBeforeTheNextExplorerChoice() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        editor.app.settings.values["llm.connector"] = .string("ollama")
        editor.app.connectorOverride = { _ in ConsentFixtureConnector(id: .ollama) }
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))
        shell.choose(.clip("five-1"))
        let clip = try #require(editor.activeClip)
        let lower = try #require(editor.index(clip.startWordId))
        editor.selectedWordIDs = Set(editor.words[lower...(lower + 2)].map(\.id))
        editor.runRewrite()
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.openRewrite)
        #expect(session.rewriteScope == .selection(lower...(lower + 2)))
        #expect(shell.tabs.preview == nil && shell.tabs.clipTabs.contains(.clip("five-1")))
        shell.choose(.clip("five-2"))
        #expect(session.isOpen && editor.openRewrite === session && session.current)
        #expect(shell.tabs.clipTabs.contains(.clip("five-1")) && shell.tabs.preview == .clip("five-2"))
        shell.selectTab(.clip("five-1"))
        #expect(editor.rewrite === session)
    }

    @Test func previewReplacementAlsoGuardsAnExistingSession() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        shell.choose(.clip("five-1"))
        // Exercise the replacement guard independently of the eager open notification.
        editor.onRewriteSessionOpen = nil
        let lower = try #require(editor.activeClip.flatMap { editor.index($0.startWordId) })
        let session = RewriteSession(editor: editor, scope: .selection(lower...(lower + 2)), envelope: nil, connector: nil)
        editor.openRewrite = session
        #expect(shell.tabs.preview == .clip("five-1"))
        shell.choose(.clip("five-1"))
        #expect(shell.tabs.open == [.clip("five-1"), .fullTake] && shell.tabs.preview == nil)
        shell.choose(.clip("five-2"))
        #expect(shell.tabs.clipTabs.contains(.clip("five-1")) && session.isOpen && editor.openRewrite === session)
        #expect(shell.tabs.preview == .clip("five-2"))
    }

    @Test func dirtyPreviewPinsImmediatelyAndSurvivesTheNextChoice() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        shell.choose(.clip("five-1"))
        shell.tabs.dirty.insert(.clip("five-1"))
        #expect(shell.tabs.preview == nil && shell.tabs.clipTabs.contains(.clip("five-1")))
        shell.choose(.clip("five-2"))
        #expect(shell.tabs.open.contains(.clip("five-1")) && shell.dirtyTabs.contains(.clip("five-1")))
        #expect(shell.tabs.preview == .clip("five-2"))
    }

    @Test func suggestionsShareThePreviewSlotAndKeepStillConvertsThem() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        shell.choose(.clip("five-1"))
        shell.choose(.clip("five-5"))
        #expect(shell.tabs.preview == .suggestion("five-5") && !shell.tabs.open.contains(.clip("five-1")))
        let undo = try #require(editor.undoManager)
        undo.beginUndoGrouping(); editor.keep("five-5"); undo.endUndoGrouping()
        #expect(editor.suggestedClips.isEmpty && shell.tabs.open.contains(.clip("five-5")))
        #expect(shell.tabs.preview == nil)
        undo.undo()
        #expect(editor.suggestedClips.map(\.id) == ["five-5"])
    }

    /// V13's entry rule: AI editing and a clip that keeps a word; text Rewrite needs no Voice Lab.
    @Test func rowRewriteNeedsAIEditingAndKeptWordsButNoVoiceLab() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        editor.app.settings.values["voiceLab.enabled"] = .bool(false)
        #expect(shell.canRewriteExplorerClip("five-1"))
        #expect(!shell.canRewriteExplorerClip("missing-clip"))
        editor.isLeaving = true
        #expect(!shell.canRewriteExplorerClip("five-1"))
        editor.isLeaving = false
        var project = editor.project
        let clip = try #require(editor.keptClips.first { $0.id == "five-1" })
        let lower = try #require(editor.index(clip.startWordId)), upper = try #require(editor.index(clip.endWordId))
        project.edits.cutWordIds = Array(Set(project.edits.cutWordIds).union(editor.words[lower...upper].map(\.id)))
        editor.document.replaceProject(project); editor.refresh()
        #expect(!shell.canRewriteExplorerClip("five-1"))
    }

    /// "Rewrite Clip {n}" runs V13's Rewrite on the clip itself with the clip bar's field text, from a selection
    /// elsewhere and with Voice Lab off, and pins the clip's tab.
    @Test func rewriteFromARowPinsAndRunsOnTheClip() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        editor.app.settings.values["voiceLab.enabled"] = .bool(false)
        editor.app.settings.values["llm.connector"] = .string("ollama")
        editor.app.connectorOverride = { _ in ConsentFixtureConnector(id: .ollama) }
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))
        editor.rewriteInstruction = "Make it shorter"
        editor.selectedWordIDs = Set(editor.words.prefix(3).map(\.id))
        shell.rewriteExplorerClip("five-2")
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.openRewrite)
        #expect(session.rewriteScope == .clip("five-2") && session.scope == .clip("five-2") && session.instruction == "Make it shorter")
        #expect(editor.selectedWordIDs.isEmpty && editor.rewriteScopeNow == .clip("five-2") && editor.rewriteMenuTitle == "Rewrite Clip 2")
        #expect(shell.tabs.active == .clip("five-2") && shell.tabs.preview == nil)
        #expect(!editor.document.isDocumentEdited)
        // The row's Rewrite on the open clip again sends the same session again in place.
        shell.rewriteExplorerClip("five-2")
        #expect(editor.openRewrite === session)
        editor.closeRewrite(returnFocus: false)
    }

    @Test func pendingHunkSeamMarksOnlyItsParagraphAndSpeaksItsMeaning() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let entry = try #require(shell.outlineEntries.last)
        shell.outlineHasPendingHunk = { $0 == entry.words }
        #expect(shell.outlineEntries.filter(\.pendingHunk).map(\.id) == [entry.id])
        #expect(shell.outlineEntries.last?.accessibilityLabel.contains("pending change") == true)
        shell.outlineHasPendingHunk = nil
        #expect(shell.outlineEntries.allSatisfy { !$0.pendingHunk })
    }

    /// The Outline's green dots follow the transcript's proposal on the open tab (V14): a paragraph with a change that
    /// waits, until it is kept or undone; ⌘Z of a Keep brings the dot back. An insertion marks the word it follows.
    @Test func outlineDotsFollowTheProposalsPendingChanges() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let entries = shell.outlineEntries
        try #require(entries.count >= 3)
        #expect(entries.allSatisfy { !$0.pendingHunk })
        let first = try #require(editor.words[entries[0].words].first { !editor.cutWordIDs.contains($0.id) && $0.kind == .word })
        let last = try #require(editor.words[entries[2].words].last { !editor.cutWordIDs.contains($0.id) && $0.kind == .word })
        editor.proposal = TranscriptProposal(clipID: nil, title: "Rewrite full take", changes: [
            TranscriptChange(ordinal: 1, parts: [.init(kind: .cut, sourceWordIDs: [first.id])]),
            TranscriptChange(ordinal: 2, parts: [.init(kind: .voice, sourceWordIDs: [], newTokens: ["really"])], anchor: .after(last.id)),
        ])
        func dots() -> [Int] { shell.outlineEntries.filter(\.pendingHunk).map(\.id) }
        #expect(dots() == [entries[0].id, entries[2].id])
        #expect(editor.excludeChange(2))
        #expect(dots() == [entries[0].id], "an undone change needs no review")
        let undo = try #require(editor.undoManager)
        undo.beginUndoGrouping(); #expect(editor.keepChange(1)); undo.endUndoGrouping()
        #expect(dots().isEmpty, "a kept change needs no review")
        undo.undo()
        #expect(dots() == [entries[0].id], "⌘Z of the Keep brings its change back")
        // A proposal on another tab marks nothing on this one.
        editor.proposal?.clipID = "five-1"
        #expect(dots().isEmpty)
        editor.proposal = nil
    }

    @Test func outlineKeepsBareRowKeysWhileTheKeepAlternateStillActsOnTheTab() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        let item = NSMenuItem(title: "Keep Suggestion", action: nil, keyEquivalent: "\r")
        item.tag = 40; item.keyEquivalentModifierMask = []
        #expect(!AppDelegate.clipRowKeyEnabled(item, event: event, pane: .sidebar, renaming: false, responder: nil, row: .outline(0)))
        item.keyEquivalentModifierMask = [.command, .shift]
        #expect(AppDelegate.clipRowKeyEnabled(item, event: event, pane: .sidebar, renaming: false, responder: nil, row: .outline(0)))
        #expect(!AppDelegate.clipRowKeyEnabled(item, event: event, pane: .sidebar, renaming: true, responder: nil, row: .outline(0)))
    }

    @Test func aiVoiceDotsFollowEnabledSpeechOverlappingEachParagraph() async throws {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.edits.activeClipId = nil
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        defer { editor.close() }
        #expect(shell.outlineEntries.contains { $0.aiVoice })
        for entry in shell.outlineEntries {
            let start = editor.words[entry.words.lowerBound].start, end = editor.words[entry.words.upperBound - 1].end
            let overlaps = project.voiceLab.segments.contains { $0.enabled && editor.sourceGrid.overlaps(start, end, start: $0.replace.start, end: $0.replace.end) }
            #expect(entry.aiVoice == overlaps)
            if entry.aiVoice { #expect(entry.accessibilityLabel.contains("AI voice")) }
        }
    }

    @Test func disclosuresAreSharedViewPreferencesAndLeaveTheDocumentClean() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let other = WorkspaceShell(app: shell.app)
        for section in ExplorerSection.allCases {
            #expect(shell.explorerExpanded(section) == (section != .voices && section != .exports))
            shell.setExplorerExpanded(section, false)
            #expect(!other.explorerExpanded(section) && shell.app.settings.values[section.key] == .bool(false))
            shell.setExplorerExpanded(section, true)
            #expect(other.explorerExpanded(section))
        }
        #expect(editor.undoSteps == 0 && !editor.document.isDocumentEdited)
    }

    @Test func projectHeadingKeepsItsNameAndOutlineShowsTheOpenScope() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        func header(_ section: ExplorerSection, count: Int) -> [String: String] {
            let host = NSHostingView(rootView: ExplorerHeader(shell: shell, section: section, count: count).frame(width: 224))
            host.frame = NSRect(x: 0, y: 0, width: 224, height: 28)
            host.layoutSubtreeIfNeeded()
            return DebugRightColumn.texts(in: host)
        }
        let take = header(.take, count: 1)
        #expect(take["explorer.header.take"] == "\(shell.projectTitle), 1 item")
        #expect(take["explorer.header.title.take"] == shell.projectTitle.uppercased())
        #expect(take["explorer.header.trailing.take"] == nil)
        #expect(header(.outline, count: shell.outlineEntries.count)["explorer.header.trailing.outline"] == "Full Take")
        shell.choose(.clip("five-2"))
        #expect(header(.outline, count: shell.outlineEntries.count)["explorer.header.trailing.outline"] == "Clip 2")
    }

    @Test func findingAndFocusExpandTheSectionThatOwnsTheRow() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        shell.setExplorerExpanded(.suggested, false)
        editor.finding = true
        #expect(shell.explorerExpanded(.suggested))
        editor.finding = false
        shell.setExplorerExpanded(.suggested, false)
        editor.focusedSuggestion = "five-5"
        #expect(shell.explorerExpanded(.suggested))
        shell.setExplorerExpanded(.clips, false)
        shell.choose(.clip("five-2"))
        #expect(shell.selection == .clip("five-2") && shell.explorerExpanded(.clips))
        shell.selectTab(.fullTake)
        shell.setExplorerExpanded(.clips, false)
        shell.selectTab(.clip("five-2"))
        #expect(shell.selection == .clip("five-2") && shell.explorerExpanded(.clips))
        shell.setExplorerExpanded(.suggested, false)
        shell.choose(.clip("five-5"))
        #expect(shell.explorerExpanded(.suggested))
        #expect(!editor.document.isDocumentEdited)
    }

    @Test(arguments: [false, true])
    func findClipsAndHookExpandSuggestedEvenWhenNoClipsArrive(hook: Bool) async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let fake = ConsentFixtureConnector(id: try #require(ConnectorID(rawValue: "claude-code")), authMethod: "claude.ai")
        editor.app.connectorOverride = { _ in fake }
        editor.app.set("llm.connector", .string("claude-code"))
        editor.app.set("llm.cloudConsent.claude-code", .bool(true))
        shell.setExplorerExpanded(.suggested, false)
        let bar = ClipBarView(model: editor, shell: shell)
        defer { bar.tearDown() }
        if hook { bar.hook.performClick(nil) } else { editor.findClips() }
        await editor.findTask?.value
        #expect(await fake.sends == 1)
        #expect(editor.focusedSuggestion == nil && shell.explorerExpanded(.suggested))
        #expect(editor.lastFindRequest?.preset == (hook ? .hooks : editor.preset))
    }

    @Test func exportWarningsMoveFromClipsToTheExportsSection() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-explorer-exports-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        editor.app.exportLedger = ExportLedger(file: folder.appendingPathComponent("exports.json"))
        let clip = try #require(editor.keptClips.first)
        func warning() -> String? {
            let host = NSHostingView(rootView: ClipRow(shell: shell, editor: editor, clip: clip, suggested: false).frame(width: 224))
            host.frame = NSRect(x: 0, y: 0, width: 224, height: 28)
            host.layoutSubtreeIfNeeded()
            return DebugRightColumn.texts(in: host)["explorer.exportWarning"]
        }
        #expect(editor.exportRowStatus(clip.id) == .none && warning() == nil)
        let fingerprint = try ExportFingerprint.value(editor.project, target: .clip(clip.id), labelPosition: editor.app.voiceLabLabelPosition)
        func record(_ fingerprint: String, failed: Bool = false) throws {
            try editor.app.exportLedger.record(ExportRecord(projectID: editor.project.id, targetID: clip.id, exportedAt: Date(),
                planFingerprint: fingerprint, styleId: editor.project.captions.styleId, aspect: editor.project.export.aspect,
                outputPath: folder.appendingPathComponent("clip.mp4").path, failed: failed))
        }
        func exportWarning() throws -> String? {
            let row = try #require(editor.exportsList.rows.first)
            let host = NSHostingView(rootView: ExplorerExportRow(editor: editor, row: row).frame(width: 224))
            host.frame = NSRect(x: 0, y: 0, width: 224, height: 28)
            host.layoutSubtreeIfNeeded()
            let marker = DebugRightColumn.markers(in: host)["explorer.export"]
            #expect(marker?.height == ExplorerMetrics.libraryRowHeight)
            return DebugRightColumn.texts(in: host)["explorer.exportWarning"]
        }
        try record(fingerprint)
        #expect(editor.exportRowStatus(clip.id) == .exported && warning() == nil)
        #expect(try exportWarning() == nil)
        try record("older-export")
        #expect(editor.exportRowStatus(clip.id) == .changed && warning() == nil)
        #expect(try exportWarning() == "Edited since export")
        try record("older-export", failed: true)
        #expect(editor.exportRowStatus(clip.id) == .failed && warning() == nil)
        #expect(try exportWarning() == "Export failed")
    }

    @Test func clipTwelveKeepsItsNumberOnOneLine() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        var project = editor.project
        let template = try #require(editor.keptClips.last)
        for index in 5...12 {
            var clip = template
            clip.id = "two-digit-\(index)"
            project.edits.clips.append(clip)
        }
        editor.document.replaceProject(project); editor.refresh()
        let clip = try #require(editor.keptClips.first { editor.clipNumber($0.id) == 12 })
        let row = NSHostingView(rootView: ClipRow(shell: shell, editor: editor, clip: clip, suggested: false).frame(width: 224))
        row.frame = NSRect(x: 0, y: 0, width: 224, height: 28); row.layoutSubtreeIfNeeded()
        let number = try #require(DebugRightColumn.markers(in: row)["explorer.clipNumber"])
        let natural = NSHostingView(rootView: Text("12").font(DesignValues.mono(10)).fixedSize()).fittingSize
        #expect(DebugRightColumn.texts(in: row)["explorer.clipNumber"] == "12")
        #expect(number.width >= natural.width && number.height <= natural.height)
        #expect(row.fittingSize.height == 28)
    }

    @Test func rowsUseV2GeometryAndHeadersSpeakCounts() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let clip = try #require(editor.keptClips.first)
        let full = NSHostingView(rootView: FullTakeRow(editor: editor).frame(width: 200).environment(shell.app))
        let row = NSHostingView(rootView: ClipRow(shell: shell, editor: editor, clip: clip, suggested: false).frame(width: 200).environment(shell.app))
        let entry = try #require(shell.outlineEntries.first)
        let outline = NSHostingView(rootView: ExplorerOutlineRow(entry: entry).frame(width: 200))
        #expect(full.fittingSize.height == 28 && row.fittingSize.height == 28 && outline.fittingSize.height == 24)
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        row.layoutSubtreeIfNeeded()
        #expect(DebugRightColumn.markers(in: row)["explorer.thumbnail"]?.size == CGSize(width: 36, height: 20))
        #expect(ExplorerSection.clips.accessibilityLabel(count: 4) == "Clips, 4 items")
        #expect(ExplorerSection.take.accessibilityLabel(count: 1) == "Take, 1 item")
        for section in ExplorerSection.allCases {
            let header = NSHostingView(rootView: ExplorerHeader(shell: shell, section: section, count: 4).frame(width: 200))
            #expect(header.fittingSize.height >= EditorAccessibilityPolicy.minimumTarget)
            header.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
            header.layoutSubtreeIfNeeded()
            #expect(DebugRightColumn.texts(in: header)["explorer.header.\(section.rawValue)"] == section.accessibilityLabel(count: 4, title: section == .take ? shell.projectTitle : nil))
        }
    }
}
#endif
