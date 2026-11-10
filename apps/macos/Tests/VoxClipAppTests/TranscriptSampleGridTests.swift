#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The transcript shows AI coverage on the source sample grid, as the Core decides it (voice-lab §10.1). The fit stores a
/// replace range's edges as sample ÷ rate, so a touching word boundary off the grid sits under a sample outside the stored
/// edge. Such a word is still covered: its underline, its spoken "AI modified", the AI passage menu, and no AI dot or
/// disclosure on the clip and paragraph that touch the range from outside. A word that really crosses an edge stays
/// uncovered.
@Suite("Transcript AI coverage on the source sample grid", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are opened."), .offlineFixtures)
@MainActor struct TranscriptSampleGridTests {
    static let rate = 48_000
    static let startSample = 124_799, endSample = 148_800

    /// Where a word meets the stored range: w4 starts before the stored start, or w5 ends after the stored end.
    enum Touch: String, CaseIterable, CustomTestStringConvertible {
        case startOneULP, startHalfSample, endOneULP, endCrossesByTwoAndAHalfSamples
        var testDescription: String { rawValue }
        var covered: Bool { self != .endCrossesByTwoAndAHalfSamples }
    }

    /// The passage fixture at 48 kHz with its replace range over w4 and w5 stored on the grid, as the fit stores it.
    private func editor(_ touch: Touch, app: AppModel = AppModel(settingsStore: RegressionSettingsStore())) throws -> EditorModel {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let rate = Double(Self.rate)
        let lower: Double = Double(Self.startSample) / rate, upper: Double = Double(Self.endSample) / rate
        project.media.source.audio?.sampleRate = Self.rate
        project.edits.activeClipId = nil
        let index = try #require(project.voiceLab.segments.firstIndex { $0.id == "vl-passage" })
        project.voiceLab.segments[index].replace.start = lower
        project.voiceLab.segments[index].replace.end = upper
        var words = try #require(project.transcript?.words)
        let w4 = try #require(words.firstIndex { $0.id == "w4" }), w5 = try #require(words.firstIndex { $0.id == "w5" })
        switch touch {
        case .startOneULP: words[w4].start = lower.nextDown
        case .startHalfSample: words[w4].start = (Double(Self.startSample) - 0.5) / rate
        case .endOneULP: words[w5].end = upper.nextUp
        case .endCrossesByTwoAndAHalfSamples: words[w5].end = upper + 2.5 / rate
        }
        project.transcript?.words = words
        // The off-grid boundary really is off the grid, and on the stored edge's sample unless it crosses.
        let grid = VoiceLabSampleGrid(rate: rate)
        switch touch {
        case .startOneULP, .startHalfSample:
            #expect(words[w4].start < lower && grid.sample(words[w4].start) == Double(Self.startSample))
        case .endOneULP:
            #expect(words[w5].end > upper && grid.sample(words[w5].end) == Double(Self.endSample))
        case .endCrossesByTwoAndAHalfSamples:
            #expect(grid.sample(words[w5].end) == Double(Self.endSample + 3))
        }
        return EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
    }

    private func pane(_ model: EditorModel) throws -> (TranscriptNSTextView, TranscriptRenderer, TranscriptScrollView) {
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let scroll = TranscriptTextView.makeScrollView(model: model, coordinator: coordinator, width: 652, height: 488)
        let text = try #require(scroll.documentView as? TranscriptNSTextView)
        coordinator.renderer.rebuild(model: model)
        coordinator.renderer.update(TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, scope: model.scopeBounds,
                                                         activeClipID: model.activeClip?.id, playhead: model.sourceTime))
        return (text, coordinator.renderer, scroll)
    }

    @Test(arguments: Touch.allCases) func aWordTouchingAStoredEdgeOffTheGridShowsAsTheAIsWords(touch: Touch) throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        let model = try editor(touch, app: app); defer { model.close() }
        model.refresh()
        let (text, renderer, _) = try pane(model)
        let covered = renderer.aiWordIDs
        // The touching word is the AI's, not the recording's; a word that really crosses stays the recording's.
        #expect(covered.contains("w4") && (covered.contains("w5") == touch.covered), "AI words: \(covered.sorted())")
        #expect(!covered.contains("w3") && !covered.contains("w6"))
        // The replacement's span reads as AI modified, and its menu offers the AI passage's actions.
        let span = try #require(text.map.spans.first { $0.id == "w4" })
        #expect(text.spoken(span).hasSuffix("AI modified"), "\(text.spoken(span))")
        model.selectedWordIDs = touch == .endOneULP ? ["w5"] : ["w4"]
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let titles = text.menu(for: event)?.items.map(\.title) ?? []
        #expect(titles.contains("Delete AI passage"), "the menu for \(model.selectedWordIDs): \(titles)")
        // The AI words rotor lands on it, against the synth piece's own samples.
        func piece(_ kind: VoiceLabOutputPieceKind, _ start: Int64, _ end: Int64) -> VoiceLabOutputPiece {
            VoiceLabOutputPiece(kind: kind, sourceStartSample: start, sourceEndSample: end, outputStartSample: start, outputEndSample: end,
                                segmentId: nil, assetId: nil, audio: nil)
        }
        let total = Int64(Self.rate * 7), lower = Int64(Self.startSample), upper = Int64(Self.endSample)
        model.voiceLabPlan = VoiceLabOutputPlan(sampleRate: Double(Self.rate), totalSourceSamples: total,
            pieces: [piece(.source, 0, lower), piece(.synth, lower, upper), piece(.source, upper, total)], captions: [], scope: .full)
        let rotor = NSAccessibilityCustomRotor(label: "AI words", itemSearchDelegate: text)
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        var landed: [NSRange] = []
        while landed.count < 4, let item = text.rotor(rotor, resultFor: parameters) {
            landed.append(item.targetRange)
            parameters.currentItem = item
        }
        #expect(landed == [span.range], "the AI words rotor lands on \(landed), not \(span.range)")
    }

    /// A clip and a paragraph that start at a boundary touching the stored end from inside it, by under a sample, share
    /// no source sample with the range: no AI disclosure and no AI dot, as the output planner leaves the range out of the clip.
    @Test(arguments: [false, true]) func aClipTouchingTheStoredEndFromInsideCarriesNoAISpeech(halfSample: Bool) async throws {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let rate = Double(Self.rate)
        let lower: Double = Double(Self.startSample) / rate, upper: Double = Double(Self.endSample) / rate
        project.media.source.audio?.sampleRate = Self.rate
        project.edits.activeClipId = nil
        let index = try #require(project.voiceLab.segments.firstIndex { $0.id == "vl-passage" })
        project.voiceLab.segments[index].replace.start = lower
        project.voiceLab.segments[index].replace.end = upper
        var words = try #require(project.transcript?.words)
        let w5 = try #require(words.firstIndex { $0.id == "w5" })
        // w5 and w6 touch just before the stored end; w6 starts a new speaker's paragraph and the clip "after".
        let boundary = halfSample ? (Double(Self.endSample) - 0.5) / rate : upper.nextDown
        #expect(boundary < upper && VoiceLabSampleGrid(rate: rate).sample(boundary) == Double(Self.endSample))
        words[w5].end = boundary; words[w5 + 1].start = boundary
        for position in words.indices { words[position].speaker = position <= w5 ? "a" : "b" }
        project.transcript?.words = words
        project.edits.clips.append(ClipRange(id: "after", startWordId: "w6", endWordId: "w8", title: "After the passage"))
        project.edits.clips.append(ClipRange(id: "over", startWordId: "w5", endWordId: "w8", title: "Over the passage"))
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        defer { editor.close() }
        #expect(!editor.containsAISpeech(clipID: "after"), "the clip after the passage shares no sample with it")
        #expect(editor.containsAISpeech(clipID: "over") && editor.containsAISpeech())
        let entries = shell.outlineEntries
        #expect(entries.count == 2)
        #expect(entries.map(\.aiVoice) == [true, false], "the paragraph after the passage has no AI dot")
    }
}
#endif
