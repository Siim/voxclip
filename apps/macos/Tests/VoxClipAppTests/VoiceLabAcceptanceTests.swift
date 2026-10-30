#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private struct AcceptanceTestKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { Issue.record("Acceptance tests must not request keys"); return nil }
}

@MainActor private final class AcceptanceBarrier {
    private var arrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            release = continuation; arrived = true; arrival?.resume(); arrival = nil
        }
    }
    func wait() async {
        if arrived { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func resume() { release?.resume(); release = nil }
}

@Suite("Headless Voice Lab acceptance", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
@MainActor struct VoiceLabAcceptanceTests {
    @Test func wordAccessibilityCoversSourceAndAcceptedSpeechWithoutAWindow() throws {
        let results = try DebugTranscriptPixels.wordAccessibility(app: AppModel())
        #expect(results.count == 8)
        for result in results { #expect(result.passed, Comment(rawValue: result.name)) }
    }
    @Test func interiorClipBoundariesSurviveReplacementUndoAndRedo() throws {
        var project = try fixture()
        var start = try #require(project.edits.clips.first), end = start
        start.id = "inside-start"; start.startWordId = "w5"
        end.id = "inside-end"; end.endWordId = "w4"
        project.edits.clips = [start, end]
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        let text = TranscriptNSTextView(usingTextLayoutManager: true), renderer = TranscriptRenderer()
        text.model = model; renderer.text = text
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        func assertMarkers(ai: Bool) throws {
            renderer.rebuild(model: model)
            let leading = try #require(text.map.span(id: "clip-start:inside-start"))
            let trailing = try #require(text.map.span(id: "clip-end:inside-end"))
            let word = try #require(text.map.span(id: "w4"))
            #expect(text.map.spans.filter { $0.id == leading.id || $0.id == trailing.id }.count == 2)
            if ai {
                #expect(NSMaxRange(leading.range) <= word.range.location)
                #expect(trailing.range.location >= NSMaxRange(word.range))
                #expect(text.map.span(id: "w5")?.range == word.range)
            }
        }
        try assertMarkers(ai: true)
        undo.beginUndoGrouping()
        try model.applyVoiceLab(.setEnabled(segmentID: project.voiceLab.segments[0].id, enabled: false))
        undo.endUndoGrouping()
        try assertMarkers(ai: false)
        undo.undo(); try assertMarkers(ai: true)
        undo.redo(); try assertMarkers(ai: false)
    }
    private func fixture() throws -> Project {
        let shared = try SharedResources.locate()
        return try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
    }
    @Test(arguments: [false, true])
    func snapshotUndoPreservesTimestampsAndPriorDirtyCount(alreadyDirty: Bool) throws {
        let original = try fixture()
        let document = VoxClipDocument(project: original, demo: true)
        let model = EditorModel(document: document, app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false; model.undoManager = undo
        document.updateChangeCount(.changeCleared)
        if alreadyDirty { document.updateChangeCount(.changeDone) }
        let editedAt = original.modifiedAt.addingTimeInterval(10)
        model.editTimestampForTests = editedAt
        undo.beginUndoGrouping()
        try model.applyVoiceLab(.setEnabled(segmentID: original.voiceLab.segments[0].id, enabled: false))
        undo.endUndoGrouping()
        let edited = model.project
        #expect(edited.modifiedAt == editedAt && document.isDocumentEdited)
        model.editTimestampForTests = editedAt.addingTimeInterval(10)
        undo.undo()
        #expect(model.project == original && document.isDocumentEdited == alreadyDirty)
        model.editTimestampForTests = editedAt.addingTimeInterval(20)
        undo.redo()
        #expect(model.project == edited && document.isDocumentEdited)
        undo.undo()
        #expect(model.project == original && document.isDocumentEdited == alreadyDirty)
        undo.removeAllActions()
    }
    @Test func exportDisclosureSurvivesMissingAssetsForFullAndClipScopes() throws {
        var project = try fixture()
        project.voiceLab.assets = []
        var outside = try #require(project.edits.clips.first)
        outside.id = "outside"; outside.startWordId = "w1"; outside.endWordId = "w2"
        project.edits.clips.append(outside)
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        let expected = "This video contains AI-modified speech. It will show AI MODIFIED."
        #expect(model.exportDisclosure([.fullEdit]) == expected)
        #expect(model.exportDisclosure([.clip("clip-main")]) == expected)
        #expect(model.exportDisclosure([.clip("outside")]) == nil)
        for scope: VoiceLabOutputScope in [.full, .clip("clip-main")] {
            #expect(throws: (any Error).self) {
                try VoiceLabRenderPreflight.prepare(project: project, scope: scope,
                    paidRoot: model.app.locations.root.appendingPathComponent("VoiceLab"), labelPosition: .topRight)
            }
        }
        #expect(model.exportDisclosure([.fullEdit, .clip("clip-main")]) == expected)
        var disabled = project; disabled.voiceLab.segments[0].enabled = false
        model.replace(disabled, name: "Disable missing replacement")
        #expect(model.exportDisclosure([.fullEdit, .clip("clip-main")]) == nil)
    }
    @Test(arguments: [false, true])
    func readyAcceptancePublishesOnceAndStalePublicationNeverMutates(cancel: Bool) async throws {
        var original = try fixture()
        let stored = original.voiceLab.segments[0], recipe = try #require(original.voiceLab.segments[0].candidates[0].recipe)
        let shared = try SharedResources.locate()
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        let assets = try #require(original.voiceLab.assets)
        original.voiceLab.segments = []; original.voiceLab.assets = []; original.voiceLab.voices = []
        let document = VoxClipDocument(project: original, demo: true)
        let model = EditorModel(document: document, app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false; model.undoManager = undo; model.editTimestampForTests = original.modifiedAt
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = VoiceLabTakeRun(client: ElevenLabsVoiceLab(keys: AcceptanceTestKeys(), region: .default),
            store: VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])), speaker: .unavailable,
            storage: .init(projectId: original.id, paidRoot: root, scratchRoot: root.appendingPathComponent("scratch")),
            dispatchIfCurrent: { _ in Issue.record("Acceptance must not dispatch a provider request") }, inputsAreCurrent: { true })
        let session = RewriteGenerationSession(run: run)
        #expect(session.acceptTitle == "Use Take 1")
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 2400, trimEndFrame: 19200, windowStart: 2.5, windowEnd: 3.2, windowStartSample: 2500, windowEndSample: 3200,
            outputFrames: 16800, words: try #require(recipe.words))
        let window = VoiceLabWindow(firstWordId: "w4", lastWordId: "w5", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 2.5, end: 3.2,
            startSample: 2500, endSample: 3200, leftSeam: .init(kind: .gap, time: 2.5, sample: 2500, fadeSamples: 20),
            rightSeam: .init(kind: .gap, time: 3.2, sample: 3200, fadeSamples: 20))
        let input = VoiceLabTakeInput(text: "new words", modelID: "fixture-model", recordID: record.id, language: "en", seed: 7,
            contentKey: original.media.source.contentKey, source: [], sourceSampleRate: 1000, items: try #require(original.transcript?.words),
            window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "test", basis: "unknown")
        let quote = VoiceLabQuote(id: UUID(), operation: .textToSpeech, requestID: UUID(), estimate: estimate, region: .default,
            endpoint: recipe.provenance.endpoint, languageMode: .explicit("en"), fingerprint: "test")
        let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: quote.endpoint, modelID: input.modelID,
            voiceID: record.voiceId, requestID: quote.requestID, providerRequestID: nil, spendWarning: nil)
        let audio = VoiceLabTakeAudio(sampleRate: 24000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0,
            roomTone: recipe.roomTone, fit: .exact(plan))
        let row = VoiceLabTakeRow(id: quote.requestID, index: 0, seed: 7, receipt: receipt, audio: audio,
            qa: VoiceLabTakeQAResult(values: stored.qa, failures: []), score: 1, quote: .init(index: 0, seed: 7, synthesis: quote, qa: quote))
        var unity = recipe.audio; unity.stretch = 1
        let publication = VoiceLabPublishedTake(assets: assets, audio: unity, outDuration: 3.2 - 2.5,
            words: try #require(recipe.words), chunks: recipe.chunks)
        let barrier = AcceptanceBarrier()
        var publications = 0
        session.publishForTests = { _, _, _ in publications += 1; await barrier.pause(); return (publication, record) }
        #expect(await session.accept(into: model) == false)
        #expect(publications == 0 && model.project == original)
        session.review(VoiceLabTakeRunResult(rows: [row], end: .completed), input: input)
        #expect(session.acceptTitle == "Use Take 1")
        undo.beginUndoGrouping()
        let acceptance = Task { await session.accept(into: model, at: Date(timeIntervalSince1970: 1_800_000_000)) }
        await barrier.wait()
        #expect(await session.accept(into: model) == false)
        #expect(!session.select(row.id) && publications == 1)
        if cancel { session.invalidate() }
        barrier.resume()
        #expect(await acceptance.value == !cancel)
        undo.endUndoGrouping()
        if cancel { #expect(model.project == original && !document.isDocumentEdited && model.undoSteps == 0) }
        else {
            let accepted = model.project
            #expect(accepted.voiceLab.segments.count == 1 && accepted.voiceLab.assets == assets)
            #expect(document.isDocumentEdited && model.undoSteps == 1)
            undo.undo(); #expect(model.project == original && !document.isDocumentEdited)
            undo.redo(); #expect(model.project == accepted && document.isDocumentEdited)
        }
        undo.removeAllActions(); session.invalidate()
    }
    @Test func acceptAndEachSegmentActionAreOneNativeUndoStep() throws {
        var accepted = try fixture()
        accepted.voiceLab.voices?[0].status = .active
        let segment = accepted.voiceLab.segments[0]
        var original = accepted
        original.voiceLab.segments = []; original.voiceLab.assets = []
        let document = VoxClipDocument(project: original, demo: true)
        let model = EditorModel(document: document, app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false; model.undoManager = undo
        model.editTimestampForTests = original.modifiedAt
        let voice = try #require(accepted.voiceLab.voices?.first)
        let assets = try #require(accepted.voiceLab.assets)
        let commands: [VoiceLabEditCommand] = [.accept(segment, assets: assets, voice: voice),
            .setEnabled(segmentID: segment.id, enabled: false), .setEnabled(segmentID: segment.id, enabled: true),
            .chooseCandidate(segmentID: segment.id, index: 1), .delete(segmentID: segment.id)]
        for command in commands {
            let before = model.project, previousSteps = model.undoSteps
            undo.beginUndoGrouping()
            try model.applyVoiceLab(command)
            undo.endUndoGrouping()
            let after = model.project
            #expect(after != before && model.undoSteps == previousSteps + 1)
            #expect(undo.undoActionName == command.actionName)
            #expect(document.isDocumentEdited)
            if case .delete = command { #expect(after.voiceLab.assets == before.voiceLab.assets) }
            #expect(after.transcript == before.transcript && after.edits == before.edits)
            undo.undo()
            #expect(model.project == before)
            if case .accept = command { #expect(!document.isDocumentEdited && model.project.voiceLab.assets == []) }
            undo.redo()
            #expect(model.project == after && document.isDocumentEdited)
            #expect(model.project.voiceLab.assets == after.voiceLab.assets)
        }
        #expect(model.project.voiceLab.segments.isEmpty && model.project.voiceLab.assets == assets)
        undo.removeAllActions()
    }
    @Test func disclosureIsScopeSpecificAndOffRestoresTheSource() throws {
        let project = try fixture()
        let document = VoxClipDocument(project: project, demo: true)
        let model = EditorModel(document: document, app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        #expect(model.containsAISpeech())
        #expect(model.exportAccessibleName("Export", targets: [.fullEdit]) == "Export, contains AI-modified speech")
        let control = EditorExportControl(title: "Export Video…", accessibleName: model.exportAccessibleName("Export Video…", targets: [.fullEdit])) {}
        #expect(control.accessibleName == "Export Video…, contains AI-modified speech")
        for row in ["Source audio for Clean audio", "Consent statement audio", "Training samples", "Patch text and context text", "Lip-sync window video and audio", "Speaker embeddings never leave this Mac"] {
            #expect(privacyCopy.contains(row))
        }
        #expect(!model.containsAISpeech(clipID: "missing"))
        try model.applyVoiceLab(.setEnabled(segmentID: project.voiceLab.segments[0].id, enabled: false))
        #expect(!model.containsAISpeech())
        #expect(model.exportAccessibleName("Export", targets: [.fullEdit]) == "Export")
    }
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func acceptedWordsPaintAndSpeakWithoutAWindow(appearance: NSAppearance.Name) throws {
        let project = try fixture()
        let document = VoxClipDocument(project: project, demo: true)
        let model = EditorModel(document: document, app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        text.textContainer?.containerSize = NSSize(width: 640, height: 10_000)
        text.textContainer?.widthTracksTextView = true
        text.model = model; text.textLayoutManager?.delegate = coordinator
        coordinator.text = text; coordinator.renderer.text = text
        let renderer = coordinator.renderer
        text.textLayoutManager?.renderingAttributesValidator = { [weak renderer] _, fragment in
            MainActor.assumeIsolated { renderer?.validate(fragment) }
        }
        let chosenAppearance = try #require(NSAppearance(named: appearance))
        text.appearance = chosenAppearance
        var drawingError: (any Error)?
        chosenAppearance.performAsCurrentDrawingAppearance {
          do {
            renderer.rebuild(model: model)
            renderer.update(TranscriptAppearance(cutWords: ["w4"]))
            let span = try #require(text.map.span(id: "w4"))
            #expect((text.string as NSString).substring(with: span.range) == "new words")
            #expect(text.map.spans.filter { $0.kind == .ai }.count == 1)
            #expect(renderer.attributes[span.id]?[.vcUnderline] as? Int == 3)
            #expect(renderer.attributes[span.id]?[.vcStrike] as? Bool == false)
            model.sourceTime = try #require(model.words.first { $0.id == "w5" }).start
            #expect(text.spoken(span) == "new words, playing, AI modified")
            let manager = try #require(text.textLayoutManager)
            manager.ensureLayout(for: manager.documentRange)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 300,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            let context = graphics.cgContext
            context.setFillColor(DesignValues.nsColor("bg.window").cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 300))
            context.translateBy(x: 8, y: 292); context.scaleBy(x: 1, y: -1)
            var underline: (lower: CGFloat, upper: CGFloat, row: CGFloat)?
            manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
                fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
                if let content = manager.textContentManager, let element = fragment.textElement?.elementRange {
                    let offset = content.offset(from: content.documentRange.location, to: element.location)
                    for line in fragment.textLineFragments {
                        let intersection = NSIntersectionRange(span.range, NSRange(location: offset + line.characterRange.location, length: line.characterRange.length))
                        guard intersection.length > 0 else { continue }
                        let start = line.locationForCharacter(at: intersection.location - offset)
                        let end = line.locationForCharacter(at: NSMaxRange(intersection) - offset)
                        let font = DesignValues.transcriptFont(size: model.textSize)
                        underline = (8 + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + min(start.x, end.x),
                            8 + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + max(start.x, end.x),
                            8 + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y - font.underlinePosition + 1)
                    }
                }
                return true
            }
            let accent = try #require(NSColor(DesignValues.accentText).usingColorSpace(.deviceRGB))
            var colored = 0
            for row in 0..<300 {
                for column in 0..<640 {
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                    if abs(pixel.redComponent - accent.redComponent) < 0.04 && abs(pixel.greenComponent - accent.greenComponent) < 0.04 && abs(pixel.blueComponent - accent.blueComponent) < 0.04 {
                        colored += 1
                    }
                }
            }
            #expect(colored > 20)
            let geometry = try #require(underline)
            let background = try #require(DesignValues.nsColor("bg.window").usingColorSpace(.deviceRGB))
            var dashedRows = 0
            for row in Int(floor(geometry.row - 1))...Int(ceil(geometry.row + 1)) {
                var matches = 0, transitions = 0, previous = false
                for column in Int(ceil(geometry.lower))..<Int(floor(geometry.upper)) {
                    let pixel = try #require(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB))
                    let distance = abs(pixel.redComponent - background.redComponent) + abs(pixel.greenComponent - background.greenComponent) + abs(pixel.blueComponent - background.blueComponent)
                    let marked = distance > 0.3
                    if marked { matches += 1 }
                    if marked != previous { transitions += 1 }; previous = marked
                }
                let fraction = Double(matches) / Double(geometry.upper - geometry.lower)
                if (0.4...0.8).contains(fraction) && transitions >= 8 { dashedRows += 1 }
            }
            #expect((1...2).contains(dashedRows), "One-pixel dashed underline at \(geometry), measured \(dashedRows) rows")
            if let directory = ProcessInfo.processInfo.environment["VOXCLIP_TEST_ARTIFACTS"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("accepted-\(appearance.rawValue).png"))
            }
            try model.applyVoiceLab(.setEnabled(segmentID: project.voiceLab.segments[0].id, enabled: false))
            renderer.rebuild(model: model)
            #expect(text.map.spans.allSatisfy { $0.kind != .ai })
            #expect(!text.spoken(try #require(text.map.span(id: "w4"))).contains("AI modified"))
          } catch { drawingError = error }
        }
        if let drawingError { throw drawingError }
    }
}
#endif
