#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The incremental transcript renderer (impl-plan V8a), headless: a fold edit writes only
/// its own paragraphs, untouched paragraphs keep their styles, the per-paragraph range map
/// finds every span after an edit, and the edited text, spans, styles and rendering
/// attributes equal a fresh build. DebugTranscriptPerformance times the same paths at
/// 10,000 words in the profile build.
@Suite("Incremental transcript renderer", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are opened."), .offlineFixtures)
@MainActor struct TranscriptRendererTests {
    @Test func recordingSwitcherUsesPlayOrderAndRecordingBands() throws {
        let fixture = try SharedResources.locate().root.appendingPathComponent("fixtures/recordings/two-recordings.voxclip")
        let project = try JSONProjectStore.decode(Data(contentsOf: fixture))
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true),
                                app: AppModel(settingsStore: RegressionSettingsStore()), preview: DemoPreviewEngine())
        let (text, renderer, coordinator) = try pane(model)
        _ = coordinator
        #expect(model.transcriptRecordingScope == .playOrder)
        let first = try #require(text.map.span(id: "r2.w1"))
        let second = try #require(text.map.span(id: "w1"))
        #expect(first.range.location < second.range.location)
        #expect(renderer.marks(for: "clip-main").compactMap { $0.recording?.colourIndex } == [1, 0])
        #expect(text.map.span(id: "r2.w3") == nil)
        model.chooseRecordingShortcut(2)
        render(model, renderer)
        #expect(text.map.span(id: "w1") == nil)
        #expect(text.map.span(id: "r2.w1") != nil)
        model.chooseRecordingShortcut(0)
        render(model, renderer)
        let allFirst = try #require(text.map.span(id: "w1"))
        let allSecond = try #require(text.map.span(id: "r2.w1"))
        #expect(allFirst.range.location < allSecond.range.location)
    }

    @Test func recordingControlsAppearBesideTheirWords() throws {
        let model = try recordingShortcutModel()
        defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let matches = try #require(model.recordingTakeMatches)

        func controls() throws -> [(RecordingInlineControl, NSRange)] {
            let storage = try #require(text.textStorage)
            var result: [(RecordingInlineControl, NSRange)] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let attachment = value as? RecordingInlineAttachment { result.append((attachment.control, range)) }
            }
            return result
        }

        let markers = try controls().compactMap { control, range -> (RecordingClipLine, NSRange)? in
            guard case .marker(let line) = control else { return nil }
            return (line, range)
        }
        try #require(!markers.isEmpty)
        for (line, range) in markers {
            let beat = try #require(matches.beats.first { $0.id == line.id })
            let alternatives = Set(beat.spans.filter { $0.fromKey == line.take.key }.map(\.toKey))
            #expect(Set(line.alternatives.map(\.key)) == alternatives)
            let word = try #require(text.map.span(id: line.start))
            #expect(NSMaxRange(range) <= word.range.location)
        }
        let opening = try #require(markers.first?.0)
        model.showRecordingLineVersions(opening)
        render(model, renderer)
        let inClip = try controls()
        let versions = try #require(inClip.first { if case .versions = $0.0 { true } else { false } })
        let openingEnd = try #require(text.map.span(id: opening.end))
        let following = try #require(text.map.span(id: "w8"))
        #expect(NSMaxRange(openingEnd.range) <= versions.1.location && NSMaxRange(versions.1) <= following.range.location)
        let omitted = try #require(inClip.first { if case .omitted = $0.0 { true } else { false } })
        let beforeRestart = try #require(text.map.span(id: "w13"))
        let afterRestart = try #require(text.map.span(id: "w18"))
        #expect(text.map.span(id: "w14") == nil)
        #expect(NSMaxRange(beforeRestart.range) <= omitted.1.location && NSMaxRange(omitted.1) <= afterRestart.range.location)

        let alternate = try #require(model.recordingRegions.last)
        model.chooseRecordingTranscript(.recording(alternate.key), announceChange: false)
        render(model, renderer)
        let solo = try #require(try controls().first { item in
            if case .solo(let run) = item.0 { return run.startWordId == "r2.w18" }
            return false
        })
        let punchline = try #require(text.map.span(id: "r2.w18"))
        let previous = try #require(text.map.span(id: "r2.w17"))
        #expect(NSMaxRange(previous.range) <= solo.1.location && NSMaxRange(solo.1) <= punchline.range.location)
    }

    @Test func putBackRestoresConsecutiveLeadingRestartsInRecordingOrder() throws {
        let words = ["One", "more", "time.", "Let", "me", "start", "again.", "We", "can", "ship", "it."]
            .enumerated().map { index, word in
                let start = Double(index) * 0.2
                return TimedWord(id: "lead\(index)", text: word, start: start, end: start + 0.15)
            }
        let model = try recordingShortcutModel(primaryWords: words)
        defer { model.close() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let (text, _, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let firstKept = try #require(text.map.span(id: "lead7"))
        let storage = try #require(text.textStorage)
        var leadingRows: [String] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: firstKept.range.location)) { value, _, _ in
            if let attachment = value as? RecordingInlineAttachment, case .omitted(let line) = attachment.control {
                leadingRows.append(line.id)
            }
        }
        #expect(leadingRows == ["lead0", "lead3"])
        let original = model.project
        let undoSteps = model.undoSteps
        let first = try #require(model.recordingOmittedLines.first)
        undo.beginUndoGrouping(); model.putBackRecordingLine(first); undo.endUndoGrouping()
        #expect(model.activeClip?.playParts.map(\.startWordId) == ["lead0", "lead7"])
        let firstRestored = model.project
        let second = try #require(model.recordingOmittedLines.first)
        undo.beginUndoGrouping(); model.putBackRecordingLine(second); undo.endUndoGrouping()
        #expect(model.activeClip?.playParts.map(\.startWordId) == ["lead0"])
        #expect(model.activeClip?.playParts.last?.endWordId == "lead10")
        #expect(model.recordingOmittedLines.isEmpty)
        #expect(undo.undoActionName == "Add part" && model.undoSteps == undoSteps + 2)
        undo.undo(); #expect(model.project == firstRestored)
        undo.undo(); #expect(model.project == original)
    }

    @Test func recordingFoldKeysActInTheTranscriptAndNotInTextFields() throws {
        let model = try recordingShortcutModel(thirdVersion: true)
        defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let opening = try #require(model.recordingLineWithVersions(at: "w1"))
        let word = try #require(pane.text.map.span(id: "w1"))
        pane.text.setSelectedRange(NSRange(location: word.range.location, length: 0))
        try #require(pane.window.makeFirstResponder(pane.text))
        #expect(AppDelegate.recordingLine(for: model, responder: pane.window.firstResponder)?.id == opening.id)
        #expect(model.recordingVersionsAccessibility(opening) == "Line 1, 2 other versions, in 0010 and 0006")
        model.showRecordingLineVersions(opening)
        #expect(model.lastAnnouncement == "Line 1, 2 other versions, in 0010 and 0006")
        pane.update(rebuild: true)

        func key(_ characters: String, _ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: pane.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        let down = try key("\u{f701}", 125), up = try key("\u{f700}", 126)
        let space = try key(" ", 49), enter = try key("\r", 36), escape = try key("\u{1b}", 53)
        let original = model.project
        let first = try #require(opening.alternatives.first)
        let last = try #require(opening.alternatives.last)
        let field = NSTextField(string: "Search")
        pane.scroll.addSubview(field)
        try #require(pane.window.makeFirstResponder(field))
        let input = try #require(field.currentEditor() as? NSTextView)
        #expect(AppDelegate.recordingLine(for: model, responder: field) == nil)
        #expect(AppDelegate.recordingLine(for: model, responder: input) == nil)
        for event in [down, up, space, enter, escape] {
            if pane.window.firstResponder !== input { try #require(pane.window.makeFirstResponder(field)) }
            pane.window.firstResponder?.keyDown(with: event)
            #expect(model.recordingSelectedVersionKey == first.key && model.recordingOpenLineID == opening.id)
            #expect(model.recordingAuditionTask == nil && model.project == original)
        }

        try #require(pane.window.makeFirstResponder(pane.text))
        pane.text.keyDown(with: down)
        #expect(model.recordingSelectedVersionKey == last.key)
        pane.text.keyDown(with: up)
        #expect(model.recordingSelectedVersionKey == first.key)
        pane.text.keyDown(with: space)
        #expect(model.recordingAuditionTask != nil && model.project == original)
        pane.text.keyDown(with: escape)
        #expect(model.recordingOpenLineID == nil && model.recordingAuditionTask == nil)
        #expect(pane.text.selectedRange().location == pane.text.map.span(id: opening.start)?.range.location)
        model.showRecordingLineVersions(opening)
        pane.text.keyDown(with: enter)
        #expect(model.activeClip?.playParts.first?.startWordId == "r2.w1" && model.recordingOpenLineID == nil)
    }

    private func recordingShortcutModel(thirdVersion: Bool = false, primaryWords: [TimedWord]? = nil) throws -> EditorModel {
        _ = NSApplication.shared
        let fixture = try SharedResources.locate().root.appendingPathComponent("fixtures/recordings/reference-recordings.voxclip")
        var project = try JSONProjectStore.decode(Data(contentsOf: fixture))
        project.edits.clips = []
        project.edits.activeClipId = nil
        if let primaryWords { project.transcript?.words = primaryWords }
        if thirdVersion {
            var media = try #require(project.media.additionalSources.first)
            media.absolutePath = "/synthetic/DJI_0006.MOV"
            media.contentKey = String(repeating: "6", count: 64)
            var spoken = try #require(project.media.spokenSources?.first)
            spoken.sourceKey = media.contentKey
            spoken.wordIdPrefix = "r3."
            spoken.offsetSeconds += Int(media.durationSeconds.rounded(.up)) + 1
            spoken.transcript.words = Array(spoken.transcript.words.prefix(11))
            project.media.additionalSources.append(media)
            project.media.spokenSources?.append(spoken)
        }
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true),
                                app: AppModel(settingsStore: RegressionSettingsStore()), preview: DemoPreviewEngine())
        let primary = try #require(model.recordingRegions.first)
        model.startFromRecording(primary)
        try #require(model.transcriptRecordingScope == .playOrder)
        return model
    }

    /// `paragraphs` turns of ten words by six speakers in turn, r0–r59 by default, each its own
    /// paragraph. Every fifth word is cut, r23 and r41 are fillers, a 1.2 s pause follows r14,
    /// and a clip spans the fifth paragraph, as an AI suggestion not yet kept with `suggested`.
    private func editor(showCuts: Bool, paragraphs: Int = 6, suggested: Bool = false) throws -> EditorModel {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let count = paragraphs * 10
        project.transcript?.words = (0..<count).map { index in
            let start = Double(index) * 0.5 + (index > 14 ? 1 : 0)
            return TimedWord(id: "r\(index)", text: [23, 41].contains(index) ? "um" : index % 10 == 9 ? "end." : "word", start: start, end: start + 0.3, speaker: "s\(index / 10 % 6)")
        }
        project.transcript?.durationSeconds = Double(count) / 2 + 2
        project.media.source.durationSeconds = Double(count) / 2 + 2
        project.edits = ProjectEdits(cutWordIds: stride(from: 0, to: count, by: 5).map { "r\($0)" })
        project.edits.clips = [ClipRange(id: "fifth", startWordId: "r40", endWordId: "r49", title: "Fifth", origin: suggested ? .ai : .manual, selected: !suggested)]
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(settingsStore: RegressionSettingsStore()), preview: DemoPreviewEngine())
        model.showsCuts = showCuts
        return model
    }
    private func pane(_ model: EditorModel) throws -> (TranscriptNSTextView, TranscriptRenderer, TranscriptTextView.Coordinator) {
        _ = NSApplication.shared
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let scroll = TranscriptTextView.makeScrollView(model: model, coordinator: coordinator, width: 652, height: 488)
        let text = try #require(scroll.documentView as? TranscriptNSTextView)
        render(model, coordinator.renderer)
        layOut(text)
        return (text, coordinator.renderer, coordinator)
    }
    private func appearance(_ model: EditorModel) -> TranscriptAppearance {
        TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, scope: model.scopeBounds, activeClipID: model.activeClip?.id, playhead: model.sourceTime)
    }
    /// What the editor's updateNSView does after an edit.
    private func render(_ model: EditorModel, _ renderer: TranscriptRenderer) {
        renderer.rebuild(model: model)
        renderer.update(appearance(model))
    }
    private func layOut(_ text: TranscriptNSTextView) {
        guard let manager = text.textLayoutManager else { return }
        manager.ensureLayout(for: manager.documentRange)
    }
    private func color(_ renderer: TranscriptRenderer, _ id: String, _ key: NSAttributedString.Key = .foregroundColor) -> NSColor? { renderer.attributes[id]?[key] as? NSColor }
    /// The length of a paragraph's text without its line break.
    private func length(_ renderer: TranscriptRenderer, _ text: TranscriptNSTextView, paragraph: Int) -> Int {
        (paragraph + 1 < renderer.paragraphs.count ? renderer.paragraphs[paragraph + 1].offset - 1 : text.string.utf16.count) - renderer.paragraphs[paragraph].offset
    }

    /// Records the character edits the text storage processes, in order.
    private final class EditLog: @unchecked Sendable {
        var edits: [(range: NSRange, change: Int)] = []
        var token: NSObjectProtocol?
        init(_ storage: NSTextStorage) {
            token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] notification in
                guard let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
                self?.edits.append((storage.editedRange, storage.changeInLength))
            }
        }
        func stop() { token.map(NotificationCenter.default.removeObserver); token = nil }
    }

    /// The same model built from scratch has the same text, paragraphs, spans and styles.
    private func expectFreshBuild(_ model: EditorModel, _ text: TranscriptNSTextView, _ renderer: TranscriptRenderer) throws {
        let (fresh, freshRenderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(fresh.string == text.string)
        #expect(fresh.map.spans == text.map.spans)
        #expect(freshRenderer.paragraphs == renderer.paragraphs)
        #expect(Set(renderer.attributes.keys) == Set(text.map.spans.map(\.id)), "one style per span, none left from replaced spans")
        let tips = { (view: TranscriptNSTextView, span: TranscriptSpan) in view.textStorage?.attribute(.toolTip, at: span.range.location, effectiveRange: nil) as? String }
        for span in text.map.spans {
            #expect(color(renderer, span.id) === color(freshRenderer, span.id)
                    && renderer.attributes[span.id]?[.vcStrike] as? Bool == freshRenderer.attributes[span.id]?[.vcStrike] as? Bool, "\(span.id) styled as a fresh build")
            #expect(tips(text, span) == tips(fresh, span), "\(span.id) has a fresh build's tooltip")
        }
    }
    /// Every laid-out span's rendering attributes are its style's colours, so no paragraph
    /// shows a stale style after an edit.
    private func expectRenderingAttributes(_ text: TranscriptNSTextView, _ renderer: TranscriptRenderer, _ context: String) throws {
        let manager = try #require(text.textLayoutManager), content = try #require(manager.textContentManager)
        let start = content.documentRange.location
        var runs: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        manager.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
            runs.append((NSRange(location: content.offset(from: start, to: range.location), length: content.offset(from: range.location, to: range.endLocation)), attributes))
            return true
        }
        let stale = text.map.spans.filter { span in
            let run = runs.last { $0.range.location <= span.range.location && NSMaxRange($0.range) > span.range.location }
            return run?.attributes[.foregroundColor] as? NSColor !== color(renderer, span.id) || run?.attributes[.backgroundColor] as? NSColor !== color(renderer, span.id, .backgroundColor)
        }
        #expect(stale.isEmpty, "\(context): stale rendering attributes on \(stale.map(\.id))")
    }

    @Test func aFoldEditWritesOnlyItsParagraph() throws {
        let model = try editor(showCuts: false); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let before = text.string.components(separatedBy: "\n")
        #expect(before.count == 6 && before[2].hasPrefix(TranscriptFold.text) && text.map.span(id: "r20")?.ids == ["r20"])
        let log = EditLog(try #require(text.textStorage)); defer { log.stop() }
        model.apply(.toggle(id: "r21"), name: "Cut")
        render(model, renderer)
        let after = text.string.components(separatedBy: "\n")
        #expect(after[2].hasPrefix(TranscriptFold.text + "word") && text.map.span(id: "r21")?.ids == ["r20", "r21"], "the cut joins r20's fold")
        #expect(after.indices.filter { after[$0] != before[$0] } == [2])
        #expect(log.edits.map(\.range) == [NSRange(location: renderer.paragraphs[2].offset, length: length(renderer, text, paragraph: 2))], "one edit, exactly the third paragraph")
        try expectFreshBuild(model, text, renderer)
    }

    /// Another transcript open first, with no folds, leaves Foundation's shared attribute
    /// dictionaries holding its paragraph style. Every run still holds the one style for the
    /// text size, so the storage sets no style again over the edited paragraph and its line
    /// break as it processes a fold edit.
    @Test func aFoldEditBesideAnotherTranscriptWritesOnlyItsParagraph() throws {
        let other = try editor(showCuts: true, paragraphs: 3); defer { other.close() }
        let (otherText, _, otherCoordinator) = try pane(other)
        defer { withExtendedLifetime((otherText, otherCoordinator)) {} }
        let model = try editor(showCuts: false); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let storage = try #require(text.textStorage), style = TranscriptRenderer.paragraphStyle(textSize: model.textSize)
        let log = EditLog(storage); defer { log.stop() }
        model.apply(.toggle(id: "r21"), name: "Cut")
        render(model, renderer)
        #expect(log.edits.map(\.range) == [NSRange(location: renderer.paragraphs[2].offset, length: length(renderer, text, paragraph: 2))], "one edit, the third paragraph without its line break")
        var others: [NSRange] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if (value as? NSParagraphStyle) !== style { others.append(range) }
        }
        #expect(others.isEmpty, "runs holding another paragraph style: \(others)")
    }

    @Test func cutsInTwoParagraphsEditOnlyThoseTwo() throws {
        let model = try editor(showCuts: false); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let log = EditLog(try #require(text.textStorage)); defer { log.stop() }
        model.apply(.cutSelection(ids: ["r11", "r46"]), name: "Cut")
        render(model, renderer)
        // The later paragraph is written first, so the earlier paragraph's offset still holds.
        #expect(log.edits.count == 2, "two edits rather than one over the four paragraphs between")
        guard log.edits.count == 2 else { return }
        #expect(log.edits[1].range == NSRange(location: renderer.paragraphs[1].offset, length: length(renderer, text, paragraph: 1)))
        #expect(log.edits[0].range == NSRange(location: renderer.paragraphs[4].offset - log.edits[1].change, length: length(renderer, text, paragraph: 4)))
        #expect(renderer.paragraphReplacements == 6 + 2 && renderer.documentRebuilds == 1, "the first build and two paragraphs")
        try expectFreshBuild(model, text, renderer)
    }

    @Test func aBulkEditOverMoreThanTheSeparateEditsWritesOneEditOverItsParagraphs() throws {
        let model = try editor(showCuts: false, paragraphs: 16); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(renderer.paragraphs.count == 16)
        let storage = try #require(text.textStorage), limit = TranscriptRenderer.separateEdits
        // Up to the limit each changed paragraph is its own edit, as for a single cut.
        var log = EditLog(storage)
        model.apply(.cutSelection(ids: (0..<limit).map { "r\($0 * 20 + 2)" }), name: "Cut")
        render(model, renderer)
        log.stop()
        #expect(log.edits.count == limit)
        // One more, spread like Cut Fillers or Show Pauses over every second paragraph from the
        // second: one edit from the first to the last, since every TextKit edit costs time in
        // proportion to the whole document. That is still at most half the paragraphs.
        let ids = (0...limit).map { "r\($0 * 20 + 12)" }, last = 2 * limit + 1
        try #require(last < 15 && ids.count * 2 <= 16)
        let rebuilds = renderer.documentRebuilds
        for (restore, name) in [(false, "Cut"), (true, "Restore")] {
            layOut(text)
            let applied = renderer.attributeUpdates
            log = EditLog(storage)
            model.apply(restore ? .restoreSelection(ids: ids) : .cutSelection(ids: ids), name: name)
            render(model, renderer)
            log.stop()
            let end = renderer.paragraphs[last].offset + length(renderer, text, paragraph: last)
            #expect(log.edits.map(\.range) == [NSRange(location: renderer.paragraphs[1].offset, length: end - renderer.paragraphs[1].offset)], "\(name): one edit, from the second paragraph to the last changed one")
            #expect(renderer.documentRebuilds == rebuilds, "\(name): \(ids.count) of 16 paragraphs is not a whole-document write")
            layOut(text)
            // The update applies the changed words, and the validator the extent's spans; the
            // paragraphs before and after it keep their rendering attributes.
            let extent = (1...last).reduce(0) { $0 + text.map.spans(inParagraph: $1).count }
            #expect(renderer.attributeUpdates - applied <= extent + ids.count, "\(name): \(renderer.attributeUpdates - applied) applied, at most \(extent + ids.count)")
            try expectRenderingAttributes(text, renderer, name)
            try expectFreshBuild(model, text, renderer)
        }
    }

    @Test func keepAllTurnsTheOpenSuggestionsBarSolidAndUndoDashesItAgain() throws {
        let model = try editor(showCuts: false, suggested: true); defer { model.close() }
        model.activate(model.project.edits.clips[0])
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        try #require(text.textLayoutManager).textViewportLayoutController.layoutViewport()
        #expect(text.backdrop?.band?.suggested == true, "a suggestion's bar is dashed")
        let revision = renderer.storageRevision
        model.keepAll()
        render(model, renderer)
        // Keeping writes no text, so no viewport layout places the backdrop again.
        #expect(renderer.storageRevision == revision && renderer.clipMarks["fifth"]?.suggested == false)
        #expect(text.backdrop?.band?.suggested == false, "the kept clip's bar is solid")
        model.apply(.setClipSelected(id: "fifth", selected: false), name: "Undo Keep All")
        render(model, renderer)
        #expect(text.backdrop?.band?.suggested == true, "undoing Keep All dashes the bar again")
    }

    @Test func theViewportRelayPassesLayoutToTheTextViewAndThenPlacesTheBackdrop() throws {
        let model = try editor(showCuts: false); defer { model.close() }
        model.activate(model.project.edits.clips[0])
        let (text, _, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let controller = try #require(text.textLayoutManager).textViewportLayoutController
        let relay = try #require(controller.delegate as? TranscriptViewportRelay, "the relay is the viewport delegate")
        text.relayViewportLayout()
        #expect(controller.delegate === relay, "asking again keeps the one relay")
        // Calls the relay does not name reach the text view as they would without it.
        for name in ["textViewportLayoutControllerReceivedSetNeedsLayout:", "textViewportLayoutController:cacheRenderingSurface:forKey:", "doesNotExistForTheRelay:"] {
            let selector = NSSelectorFromString(name)
            #expect(relay.responds(to: selector) == text.responds(to: selector), "\(name)")
        }
        controller.layoutViewport()
        #expect(!controller.viewportBounds.isEmpty, "the text view supplies the viewport")
        #expect(text.backdrop?.band != nil, "a finished layout places the active clip's band")
    }

    @Test func validationDuringAStorageEditDefersItsWrites() throws {
        let model = try editor(showCuts: false); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let storage = try #require(text.textStorage)
        // A selection adjustment can ask the renderer to validate while replaceCharacters
        // is processing. Retain an unchanged fragment before editing TextKit storage.
        let manager = try #require(text.textLayoutManager)
        var fragments: [NSTextLayoutFragment] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            fragments.append(fragment)
            return false
        }
        try #require(fragments.count == 1)
        @MainActor final class Validations {
            let text: TranscriptNSTextView
            let renderer: TranscriptRenderer
            let fragments: [NSTextLayoutFragment]
            var count = 0
            var eagerWrites = 0
            init(text: TranscriptNSTextView, renderer: TranscriptRenderer, fragments: [NSTextLayoutFragment]) {
                self.text = text; self.renderer = renderer; self.fragments = fragments
            }
            func validate() {
                guard let storage = text.textStorage, storage.editedMask.contains(.editedCharacters) else { return }
                let before = renderer.attributeUpdates
                for fragment in fragments {
                    count += 1
                    renderer.validate(fragment)
                }
                eagerWrites += renderer.attributeUpdates - before
            }
        }
        let validations = Validations(text: text, renderer: renderer, fragments: fragments)
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in
            MainActor.assumeIsolated { validations.validate() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        model.apply(.toggle(id: "r21"), name: "Cut")
        render(model, renderer)
        #expect(validations.count > 0, "The validator ran inside the storage write")
        #expect(validations.eagerWrites == 0, "Colour writes wait for storage processing to finish")
        layOut(text)
        try expectRenderingAttributes(text, renderer, "validation inside an edit")
        try expectFreshBuild(model, text, renderer)
    }

    @Test func untouchedParagraphsKeepTheirStyles() throws {
        let model = try editor(showCuts: false); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let applied = renderer.attributeUpdates, styles = renderer.rebuildStyles
        model.apply(.toggle(id: "r21"), name: "Cut")
        render(model, renderer)
        layOut(text)
        let spans = text.map.spans(inParagraph: 2).count
        #expect(renderer.attributeUpdates - applied <= spans + 1, "the third paragraph's spans and the cut, not \(text.map.count) spans (\(renderer.attributeUpdates - applied))")
        #expect(renderer.rebuildStyles - styles == spans, "only the replaced paragraph's spans are styled again")
        try expectRenderingAttributes(text, renderer, "after a fold edit")
    }

    @Test func renderingAttributesFollowEveryEdit() throws {
        let model = try editor(showCuts: false); defer { model.close() }
        model.activate(model.project.edits.clips[0])
        model.showsSurroundingContext = true
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(color(renderer, "r12") === DesignValues.nsColor("word.outside") && color(renderer, "r42") === DesignValues.nsColor("word.text"))
        try expectRenderingAttributes(text, renderer, "first build")
        // A fold edit before the clip moves every later paragraph, the clip's included.
        model.apply(.toggle(id: "r11"), name: "Cut")
        render(model, renderer); layOut(text)
        try expectRenderingAttributes(text, renderer, "a fold edit in the second paragraph")
        var project = model.project
        project.edits.corrections["r33"] = "corrected"
        model.document.replaceProject(project); model.refresh()
        render(model, renderer); layOut(text)
        try expectRenderingAttributes(text, renderer, "a correction")
        model.apply(.toggle(id: "r0"), name: "Restore")
        render(model, renderer); layOut(text)
        try expectRenderingAttributes(text, renderer, "a restore in the first paragraph")
        model.activate(nil)
        renderer.update(appearance(model)); layOut(text)
        try expectRenderingAttributes(text, renderer, "Full Take")
        #expect(color(renderer, "r12") === DesignValues.nsColor("word.text"))
        model.showsCuts = true
        render(model, renderer); layOut(text)
        try expectRenderingAttributes(text, renderer, "Show cuts on")
        try expectFreshBuild(model, text, renderer)
    }

    @Test func showCutsAndTheTextSizeRewriteTheDocumentAndKeepUntouchedStyles() throws {
        let model = try editor(showCuts: true); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let rebuilds = renderer.documentRebuilds, styles = renderer.rebuildStyles, revision = renderer.storageRevision
        model.showsCuts = false
        render(model, renderer)
        #expect(renderer.documentRebuilds == rebuilds + 1, "every paragraph folds a cut, so the document is written once")
        #expect(renderer.rebuildStyles - styles == text.map.count)
        try expectFreshBuild(model, text, renderer)
        model.textSize = 20
        render(model, renderer)
        // The text starts with r0's fold, so the size is read at a word.
        let word = try #require(text.map.span(id: "r1"))
        #expect(renderer.documentRebuilds == rebuilds + 2 && (text.textStorage?.attribute(.font, at: word.range.location, effectiveRange: nil) as? NSFont)?.pointSize == 20)
        #expect(renderer.rebuildStyles - styles == text.map.count, "a new size keeps every style")
        render(model, renderer)
        #expect(renderer.storageRevision == revision + 2, "a rebuild with nothing changed writes nothing")
        try expectFreshBuild(model, text, renderer)
    }

    @Test func aTabSwitchWritesTheParagraphsWhoseInClipStateChangedAndFillersHaveNoHint() throws {
        let model = try editor(showCuts: false); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(text.map.span(id: "r10")?.kind == .fold && text.map.span(id: "r45")?.kind == .fold)
        // Outside the open clip the words read as said: no folds (notes.md §5). Five of the six
        // paragraphs hold a cut outside the clip, so the switch writes the document once.
        let rebuilds = renderer.documentRebuilds
        model.activate(model.project.edits.clips[0])
        model.showsSurroundingContext = true
        render(model, renderer)
        #expect(renderer.documentRebuilds == rebuilds + 1)
        #expect(text.map.span(id: "r10")?.kind == .text && text.map.span(id: "r10")?.ids == [] && text.map.span(id: "r45")?.kind == .fold)
        #expect(!text.string.components(separatedBy: "\n")[1].contains(TranscriptFold.glyph) && text.string.components(separatedBy: "\n")[4].contains(TranscriptFold.glyph))
        #expect(color(renderer, "r10") === DesignValues.nsColor("word.outside") && renderer.attributes["r10"]?[.vcStrike] as? Bool == false, "a cut word outside the clip is unstruck")
        // Back to Full Take every paragraph folds its cuts again.
        model.activate(nil)
        render(model, renderer)
        #expect(text.map.span(id: "r10")?.kind == .fold)
        try expectFreshBuild(model, text, renderer)
        // The filler underline and its hint are gone (impl-plan item 11); fillers stay in the rotor.
        func tip(_ id: String) -> String? { text.map.span(id: id).flatMap { text.textStorage?.attribute(.toolTip, at: $0.range.location, effectiveRange: nil) as? String } }
        #expect(tip("r23") == nil && tip("r41") == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func clipContextIsHiddenByDefaultAndOneToggleUpdatesBothSurfaces(_ suggested: Bool, _ showCuts: Bool) throws {
        let model = try editor(showCuts: showCuts, suggested: suggested)
        defer { model.close() }
        model.activate(model.project.edits.clips[0])
        model.selectedWordIDs = ["r42", "r43"]
        model.sourceTime = model.words[42].start
        let undo = UndoManager()
        model.undoManager = undo
        let original = model.project, steps = model.undoSteps, revision = model.projectRevision
        let wasEdited = model.document.isDocumentEdited
        let duration = model.duration, sourceDuration = model.sourceDuration
        let mapping = (0...20).map { model.timelineSourceTime(duration * Double($0) / 20, on: .edited) }
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(!model.showsSurroundingContext && model.focusesClip)
        model.selectedWordIDs = ["r42", "r43"]
        #expect(renderer.paragraphs.map(\.firstWord) == [40])
        #expect(text.map.span(id: "r39") == nil && text.map.span(id: "r50") == nil)
        #expect(renderer.caretOffset(atTime: model.words[42].start) == text.map.span(id: "r42")?.range.location)
        let focused = text.string
        let focusedSpans = text.map.spans
        let scope = try #require(model.scopeSourceRange)
        canvas.renderContent()
        #expect(canvas.content.overviewRange == scope && canvas.content.clips.map(\.id) == ["fifth"])
        #expect(canvas.content.displayRange == (showCuts ? scope : 0...duration))
        #expect(!canvas.audio.state.showsSurroundingContext && !canvas.video.state.showsSurroundingContext)
        #expect(abs(canvas.overview.time(atX: canvas.overview.x(scope.lowerBound)) - scope.lowerBound) < 1e-9)
        let toggle = SurroundingContextToggle(model: model)
        #expect(toggle.state == .off && !toggle.isHidden)
        #expect(toggle.accessibilityLabel() == "Show surrounding context")
        toggle.performClick(nil)
        TranscriptTextView.render(model, coordinator: coordinator)
        canvas.renderContent()
        #expect(model.showsSurroundingContext && toggle.state == .on)
        #expect(renderer.paragraphs.count == 6 && text.map.span(id: "r39") != nil && text.map.span(id: "r50") != nil)
        #expect(color(renderer, "r39") === DesignValues.nsColor("word.outside"))
        #expect(canvas.content.overviewRange == 0...sourceDuration)
        #expect(canvas.audio.state.showsSurroundingContext && canvas.video.state.showsSurroundingContext)
        #expect(model.showsCuts == showCuts)
        layOut(text)
        try expectRenderingAttributes(text, renderer, "context on")
        toggle.performClick(nil)
        TranscriptTextView.render(model, coordinator: coordinator)
        canvas.renderContent()
        #expect(text.string == focused && text.map.spans == focusedSpans)
        #expect(canvas.content.overviewRange == scope && !canvas.content.showsSurroundingContext)
        #expect(Set(renderer.attributes.keys) == Set(text.map.spans.map(\.id)))
        #expect(model.selectedWordIDs == ["r42", "r43"])
        TranscriptTextView.select(model: model, in: text)
        let selectedRange = try #require(text.selectedRanges.first?.rangeValue)
        #expect(text.map.selected([selectedRange]).map(\.id) == ["r42", "r43"])
        layOut(text)
        try expectRenderingAttributes(text, renderer, "context off again")
        try expectFreshBuild(model, text, renderer)
        model.toggleShowsCuts()
        TranscriptTextView.render(model, coordinator: coordinator)
        canvas.renderContent()
        #expect(!model.showsSurroundingContext && model.showsCuts != showCuts)
        #expect(text.map.span(id: "r39") == nil && canvas.content.overviewRange == scope)
        #expect(model.project == original && model.projectRevision == revision)
        #expect(model.undoSteps == steps && !undo.canUndo && !undo.canRedo)
        #expect(model.document.isDocumentEdited == wasEdited)
        #expect(model.duration == duration && model.sourceDuration == sourceDuration)
        #expect((0...20).map { model.timelineSourceTime(duration * Double($0) / 20, on: .edited) } == mapping)
    }

    @Test func focusedSameParagraphBoundariesAndSuggestionSwitchesKeepSourceMappings() throws {
        let model = try editor(showCuts: false)
        defer { model.close() }
        var project = model.project
        project.edits.clips = [ClipRange(id: "middle", startWordId: "r42", endWordId: "r47"),
                              ClipRange(id: "suggestion", startWordId: "r12", endWordId: "r16", origin: .ai, selected: false)]
        project.edits.corrections["r43"] = "corrected"
        model.document.replaceProject(project); model.refresh()
        model.activate(model.project.edits.clips[0])
        let sourceWords = model.words
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(renderer.paragraphs.map(\.firstWord) == [42])
        #expect(renderer.paragraphs.map(\.start) == [sourceWords[42].start])
        #expect(text.string.contains("corrected") && text.map.span(id: "r45")?.kind == .fold)
        #expect(text.map.span(id: "r41") == nil && text.map.span(id: "r48") == nil)
        #expect((42...47).allSatisfy { text.map.span(id: "r\($0)") != nil })
        model.showsSurroundingContext = true
        TranscriptTextView.render(model, coordinator: coordinator)
        canvas.renderContent()
        #expect(text.map.span(id: "r41") != nil)
        model.activate(model.project.edits.clips[1])
        #expect(!model.showsSurroundingContext && model.isSuggestion("suggestion"))
        TranscriptTextView.render(model, coordinator: coordinator)
        canvas.renderContent()
        #expect(renderer.paragraphs.map(\.firstWord) == [12])
        #expect(text.map.span(id: "r11") == nil && text.map.span(id: "r17") == nil)
        #expect(text.map.span(id: "r15")?.kind == .fold)
        #expect(canvas.content.clips.map(\.id) == ["suggestion"] && canvas.content.overviewRange == model.scopeSourceRange)
        model.showsSurroundingContext = true
        model.activate(model.project.edits.clips[0])
        TranscriptTextView.render(model, coordinator: coordinator)
        canvas.renderContent()
        #expect(!model.showsSurroundingContext && renderer.paragraphs.map(\.firstWord) == [42])
        #expect(text.string.contains("corrected") && text.map.span(id: "r12") == nil)
        model.activate(nil)
        TranscriptTextView.render(model, coordinator: coordinator)
        canvas.renderContent()
        #expect(!model.focusesClip && renderer.paragraphs.count == 6)
        #expect(canvas.content.overviewRange == 0...model.sourceDuration)
        #expect(canvas.content.clips.map(\.id) == model.sortedClips.map(\.id))
        #expect(model.words == sourceWords && model.project.edits.corrections["r43"] == "corrected")
        try expectFreshBuild(model, text, renderer)
    }

    @Test func theRangeMapFindsEverySpanAcrossParagraphsAndAfterAReplacement() {
        // "abc ⎵wxyz " · "⋯ 2 cut " · "‖ 1.0s end ", the second paragraph's fold standing for f1 and f2.
        var map = TranscriptRangeMap(paragraphs: [
            (0, [TranscriptSpan(id: "a", range: NSRange(location: 0, length: 3), pause: false),
                 TranscriptSpan(id: "ai:s", range: NSRange(location: 4, length: 1), pause: false, kind: .ai),
                 TranscriptSpan(id: "w", range: NSRange(location: 5, length: 4), pause: false, ids: ["w", "x"])]),
            (11, [TranscriptSpan(id: "f1", range: NSRange(location: 0, length: 7), pause: false, ids: ["f1", "f2"])]),
            (20, [TranscriptSpan(id: "pause-after-f2", range: NSRange(location: 0, length: 6), pause: true),
                  TranscriptSpan(id: "e", range: NSRange(location: 7, length: 3), pause: false)])
        ])
        #expect(map.count == 6 && map.paragraphCount == 3)
        #expect(map.spans.map(\.range.location) == [0, 4, 5, 11, 20, 27])
        #expect(map.span(id: "x")?.id == "w" && map.span(id: "f2")?.range == NSRange(location: 11, length: 7) && map.span(id: "e")?.range.location == 27)
        expectFlatLookups(map, length: 31)
        // The fold opens into three words: the paragraph grows by 4 and the last one moves.
        map.replace(paragraph: 1, with: [TranscriptSpan(id: "f0", range: NSRange(location: 0, length: 2), pause: false),
                                         TranscriptSpan(id: "f1", range: NSRange(location: 3, length: 4), pause: false),
                                         TranscriptSpan(id: "f2", range: NSRange(location: 8, length: 3), pause: false)], lengthChange: 4)
        #expect(map.count == 8 && map.span(id: "f2")?.range == NSRange(location: 19, length: 3) && map.span(id: "f2")?.ids == [])
        #expect(map.span(id: "e")?.range == NSRange(location: 31, length: 3) && map.span(id: "pause-after-f2")?.range.location == 24)
        #expect(map[7].id == "e" && map[3].id == "f0" && map.spans(inParagraph: 2).map(\.range.location) == [24, 31])
        expectFlatLookups(map, length: 35)
        map.replace(paragraph: 0, with: [TranscriptSpan(id: "a", range: NSRange(location: 0, length: 3), pause: false)], lengthChange: -6)
        #expect(map.span(id: "x") == nil && map.span(id: "ai:s") == nil && map.span(id: "e")?.range.location == 25)
        expectFlatLookups(map, length: 29)
    }

    /// The map's character lookups agree with a scan of its spans in one flat array, the
    /// renderer's map before paragraphs, at every offset and for ranges up to 12 long.
    private func expectFlatLookups(_ map: TranscriptRangeMap, length: Int) {
        let spans = map.spans
        func lower(_ offset: Int) -> Int { spans.firstIndex { NSMaxRange($0.range) > offset } ?? spans.count }
        for offset in -1...(length + 1) {
            let position = lower(offset)
            let at = spans[position...].first(where: \.selectable) ?? spans[..<position].last(where: \.selectable)
            #expect(map.span(at: offset) == at, "span(at: \(offset))")
            for size in 0...12 {
                let range = NSRange(location: max(0, offset), length: size)
                let start = lower(range.location)
                var upper = start
                while upper < spans.count && (spans[upper].range.location < NSMaxRange(range) || range.length == 0 && upper == start) { upper += 1 }
                #expect(map.intersecting(range) == Array(spans[start..<upper]), "intersecting \(range)")
            }
        }
        for span in spans { #expect(map.span(id: span.id) == span && span.ids.allSatisfy { map.span(id: $0) == span }) }
    }
}
#endif
