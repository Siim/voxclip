#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

@Suite("Explorer", .serialized)
@MainActor struct ExplorerTests {
    private func open() async throws -> (WorkspaceShell, EditorModel) {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        await shell.attachForTesting(VoxClipDocument(project: try DebugExplorer.fiveQuestions(from: base), demo: true), selection: .fullTake)
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
        #expect(checks.count == 4)
        #expect(checks.allSatisfy { $0.passed })
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

    @Test func rowRewriteUsesTheExistingEntryPolicyAndNeedsKeptWords() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
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

    @Test func rewriteFromARowPinsAndUsesThatClipsKeptWords() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        editor.app.settings.values["llm.connector"] = .string("ollama")
        editor.app.connectorOverride = { _ in ConsentFixtureConnector(id: .ollama) }
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))
        shell.rewriteExplorerClip("five-1")
        await editor.rewriteOpenTask?.value
        let clip = try #require(editor.keptClips.first { $0.id == "five-1" })
        let lower = try #require(editor.index(clip.startWordId)), upper = try #require(editor.index(clip.endWordId))
        let kept = Set(editor.words[lower...upper].filter { !editor.cutWordIDs.contains($0.id) }.map(\.id))
        #expect(editor.selectedWordIDs == kept && shell.tabs.active == .clip("five-1") && shell.tabs.preview == nil)
        #expect(editor.openRewrite?.scope == .clip("five-1"))
        #expect(!editor.document.isDocumentEdited)
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
            let overlaps = project.voiceLab.segments.contains { $0.enabled && $0.replace.start < end && $0.replace.end > start }
            #expect(entry.aiVoice == overlaps)
            if entry.aiVoice { #expect(entry.accessibilityLabel.contains("AI voice")) }
        }
    }

    @Test func disclosuresAreSharedViewPreferencesAndLeaveTheDocumentClean() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        let other = WorkspaceShell(app: shell.app)
        for section in ExplorerSection.allCases {
            #expect(shell.explorerExpanded(section))
            shell.setExplorerExpanded(section, false)
            #expect(!other.explorerExpanded(section) && shell.app.settings.values[section.key] == .bool(false))
            shell.setExplorerExpanded(section, true)
            #expect(other.explorerExpanded(section))
        }
        #expect(editor.undoSteps == 0 && !editor.document.isDocumentEdited)
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
            #expect(DebugRightColumn.texts(in: header)["explorer.header.\(section.rawValue)"] == section.accessibilityLabel(count: 4))
        }
    }
}
#endif
