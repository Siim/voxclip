#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
import CoreImage
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// A Claude Code fake on a plan that answers Ask Claude with `reply`.
private actor AskFixtureConnector: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    private(set) var requests: [LLMRequest] = []
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func knownCLIAuthMethod() async -> String? { "claude.ai" }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        requests.append(request)
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}

/// ✦ Ask Claude in the editor (design.md §6.8): the selection bar, a timeline range and the clip row open one inline
/// field; chips only fill it; the answer applies as one undo step; each row undoes alone and Undo all takes every row out.
/// Stub connectors only, settings in memory, nothing shown on screen.
@Suite("Ask Claude", .serialized, .offlineFixtures)
@MainActor struct AskClaudeAppTests {
    private static func op(_ kind: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["kind": kind, "startWord": -1, "endWord": -1, "start": -1, "end": -1, "text": "", "target": "", "x": 0, "y": 0,
                                    "width": 0, "height": 0, "tracking": "", "position": "", "rate": 0, "scale": 0, "sound": "", "language": "",
                                    "choice": "", "reason": "\(kind) because it was asked"]
        for (key, field) in fields { value[key] = field }
        return value
    }
    private static func reply(_ ops: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["summary": "Done as asked.", "ops": ops]), as: UTF8.self)
    }

    private func open(reply: String = "{\"summary\":\"\",\"ops\":[]}") async throws -> (WorkspaceShell, EditorModel, AskFixtureConnector, UndoManager) {
        _ = NSApplication.shared
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.loadCatalogue()
        let fake = AskFixtureConnector(reply: reply)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("claude-code"))
        app.connectorConsentOverride = { _, action, _ in #expect(action == .askClaude); return true }
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        // A saved project's own id; effects promote it to v4, whose asset folders are named by it.
        project.id = "0d6f3a52-8a59-4c0e-9d1b-2f8e7c4a6b31"
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        return (shell, editor, fake, undo)
    }

    private func select(_ editor: EditorModel, _ range: ClosedRange<Int>) {
        editor.selectedWordIDs = Set(editor.words[range].map(\.id))
    }

    @Test func theSelectionBarOpensOneInlineFieldAndChipsOnlyFillIt() async throws {
        let (shell, editor, fake, _) = try await open()
        defer { editor.close() }
        select(editor, 2...5)
        #expect(editor.canAskClaude && editor.askClaudeWordSelection == AskClaudeSelection(scope: .words(2...5), clipID: nil))
        editor.openAskClaudeOnSelection()
        #expect(editor.askClaude.selection != nil && editor.askClaude.label.hasPrefix("\u{201C}"))
        #expect(PanelJob.available(in: editor).contains(.askClaude) && shell.panelJob(for: editor) == .askClaude)
        #expect(editor.askClaudeCostLine == "Free on your Claude plan")
        // Chips fill the field; nothing is sent until Return.
        editor.askClaude.text = AskClaudeState.chips[0].text
        #expect(editor.askClaude.text == "Bleep these words")
        #expect(await fake.requests.isEmpty)
        // An empty field sends nothing either.
        editor.askClaude.text = "   "
        editor.sendAskClaude()
        await editor.askClaude.task?.value
        #expect(await fake.requests.isEmpty)
        editor.closeAskClaude()
        #expect(!editor.askClaude.isOpen && !PanelJob.available(in: editor).contains(.askClaude))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."))
    func theAnswerAppliesAsOneUndoStepAndEachRowUndoesAlone() async throws {
        let ops = [Self.op("bleep", ["startWord": 3, "endWord": 4]), Self.op("title", ["text": "Day 1", "position": "top"]),
                   Self.op("sound", ["sound": "pop"]), Self.op("rewrite", ["startWord": 2, "endWord": 5, "text": "this is new"]),
                   Self.op("speed", ["rate": 1.5])]
        let (shell, editor, fake, undo) = try await open(reply: try Self.reply(ops))
        defer { editor.close() }
        select(editor, 2...5)
        editor.openAskClaudeOnSelection()
        editor.askClaude.text = "bleep the swear, add a title and a pop"
        let before = editor.project
        undo.beginUndoGrouping()
        editor.sendAskClaude()
        await editor.askClaude.task?.value
        undo.endUndoGrouping()
        let requests = await fake.requests
        #expect(requests.count == 1 && requests.first?.feature == .askClaude && requests.first?.effort == .xhigh)
        #expect(requests.first?.instruction.contains("Instruction: bleep the swear, add a title and a pop") == true)
        let run = try #require(editor.askClaude.run, "\(editor.askClaude.error ?? "no error")")
        #expect(editor.askClaude.error == nil && !editor.llmRuns.isBusy)
        #expect(run.rows.count == 5 && run.rows[0...2].allSatisfy { $0.status == .applied })
        #expect(priced(run.rows[3]).hasPrefix("Voice it \u{00B7} "), "\(run.rows[3].status)")
        // A speed on Full Take words that no clip holds: a clip plays at one speed, so the row says why and changes nothing.
        #expect(EditorModel.stretchClip(run.rows[4].operation, in: editor.project) == nil)
        #expect(run.rows[4].status == .later(EditorModel.laterReason(run.rows[4].operation)) && run.rows[4].title == "Speed up 1.5\u{00D7}")
        #expect(editor.project.clipEffects.map(\.kind) == [.bleep, .title, .sound])
        #expect(run.appliedCount == 3 && shell.panelJob(for: editor) == .askClaude)
        // Paid rows wait for their click: nothing else was sent.
        #expect(await fake.requests.count == 1)

        // One undo step for the whole answer.
        undo.undo()
        #expect(editor.project.clipEffects.isEmpty && editor.project.edits == before.edits)
        undo.redo()
        #expect(editor.project.clipEffects.count == 3)

        // Undo one row: the others stay.
        undo.beginUndoGrouping()
        editor.undoAskClaudeRow(run.rows[1].id)
        undo.endUndoGrouping()
        #expect(editor.project.clipEffects.map(\.kind) == [.bleep, .sound] && run.rows[1].status == .undone)
        // Undo all: the rest, in one step.
        undo.beginUndoGrouping()
        editor.undoAllAskClaude()
        undo.endUndoGrouping()
        #expect(editor.project.clipEffects.isEmpty && run.appliedCount == 0)
        undo.undo()
        #expect(editor.project.clipEffects.map(\.kind) == [.bleep, .sound])
    }

    private func priced(_ row: AskClaudeRow) -> String { if case .paid(let price) = row.status { price } else { "" } }

    /// "Play this clip at 1.25×" on a clip: the stretch covers the whole clip (within 0.25 s at each end), so it applies
    /// as the clip's speed in the answer's one undo step, and its Undo takes the speed back.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."))
    func aStretchOverTheWholeClipSetsTheClipsSpeed() async throws {
        let (shell, editor, _, undo) = try await open(reply: try Self.reply([Self.op("speed", ["rate": 1.25])]))
        defer { editor.close() }
        let clip = try #require(editor.project.edits.clips.first)
        shell.choose(.clip(clip.id), byClick: false)
        editor.openAskClaude(clip: clip.id)
        editor.askClaude.text = "play this clip a bit faster"
        undo.beginUndoGrouping(); editor.sendAskClaude(); await editor.askClaude.task?.value; undo.endUndoGrouping()
        let run = try #require(editor.askClaude.run, "\(editor.askClaude.error ?? "no error")")
        let row = try #require(run.rows.first)
        guard case .stretch(_, let start, let end, _) = row.operation.action else { Issue.record("no stretch: \(row.operation.action)"); return }
        let span = try #require(ClipControlsProject.sourceSpan(of: clip.id, in: editor.project))
        #expect(abs(start - span.lowerBound) <= 0.25 && abs(end - span.upperBound) <= 0.25)
        #expect(row.status == .applied && ClipControlsProject.controls(for: clip.id, in: editor.project)?.speed == 1.25)
        #expect(undo.undoActionName == "Ask Claude")
        undo.beginUndoGrouping(); editor.undoAskClaudeRow(row.id); undo.endUndoGrouping()
        #expect(editor.project.clipControls.isEmpty && run.rows[0].status == .undone)
        // The pure step: a stretch just inside the tolerance applies; one past it stays pending.
        let inside = ClipAutopilotOperation(id: "s1", decision: .stretch, action: .stretch(clipID: clip.id, start: span.lowerBound + 0.2,
                                            end: span.upperBound - 0.2, rate: 1.25), reason: "")
        let partial = ClipAutopilotOperation(id: "s2", decision: .stretch, action: .stretch(clipID: clip.id, start: span.lowerBound + 0.3,
                                             end: span.upperBound, rate: 1.25), reason: "")
        let applied = try ClipAutopilotMapping.apply([inside], to: editor.project)
        #expect(applied.pending.isEmpty && ClipControlsProject.controls(for: clip.id, in: applied.project)?.speed == 1.25)
        let kept = try ClipAutopilotMapping.apply([partial], to: editor.project)
        #expect(kept.pending.map(\.id) == ["s2"] && kept.project == editor.project)
    }

    /// "Slow this bit down" on words inside a clip: a clip plays at one speed, so nothing changes and the row offers one
    /// inline action, "Apply 0.5× to the whole clip", which applies it as one undo step; Undo all takes it back.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."))
    func aStretchOverPartOfAClipOffersItsSpeedForTheWholeClip() async throws {
        let (shell, editor, _, undo) = try await open(reply: try Self.reply([Self.op("speed", ["rate": 0.5])]))
        defer { editor.close() }
        let clip = try #require(editor.project.edits.clips.first { $0.selected })
        shell.choose(.clip(clip.id), byClick: false)
        let first = try #require(editor.index(clip.startWordId))
        select(editor, (first + 2)...(first + 4))
        editor.openAskClaudeOnSelection()
        #expect(editor.askClaude.selection?.clipID == clip.id)
        editor.askClaude.text = "slow this bit down"
        undo.beginUndoGrouping(); editor.sendAskClaude(); await editor.askClaude.task?.value; undo.endUndoGrouping()
        let run = try #require(editor.askClaude.run, "\(editor.askClaude.error ?? "no error")")
        let row = try #require(run.rows.first)
        #expect(row.status == .wholeClip(clipID: clip.id) && row.title == "Slow-mo 0.5\u{00D7}", "\(row.status)")
        #expect(EditorModel.wholeClipTitle(row.operation) == "Apply 0.5\u{00D7} to the whole clip")
        #expect(editor.project.clipControls.isEmpty, "nothing changes until that click")
        undo.beginUndoGrouping(); editor.applyAskClaudeStretchToClip(row.id); undo.endUndoGrouping()
        #expect(ClipControlsProject.controls(for: clip.id, in: editor.project)?.speed == 0.5 && run.rows[0].status == .applied)
        #expect(run.rows[0].detail.hasPrefix("Whole clip \u{00B7} "), "\(run.rows[0].detail)")
        #expect(undo.undoActionName == "Change speed")
        undo.beginUndoGrouping(); editor.undoAllAskClaude(); undo.endUndoGrouping()
        #expect(editor.project.clipControls.isEmpty && run.rows[0].status == .undone)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."))
    func adjustNudgesTheRangeEditsTextAndMovesTheBoxAsUndoSteps() async throws {
        let ops = [Self.op("title", ["text": "Day 1", "position": "top"]), Self.op("blur", ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, "tracking": "none"])]
        let (_, editor, _, undo) = try await open(reply: try Self.reply(ops))
        defer { editor.close() }
        select(editor, 2...8)
        editor.openAskClaudeOnSelection()
        editor.askClaude.text = "title and blur"
        undo.beginUndoGrouping(); editor.sendAskClaude(); await editor.askClaude.task?.value; undo.endUndoGrouping()
        let run = try #require(editor.askClaude.run)
        let title = run.rows[0].id, blur = run.rows[1].id
        let start = try #require(editor.askClaudeEffect(title)?.start)
        undo.beginUndoGrouping(); editor.adjustAskClaudeEffect(title) { $0.start += 0.1 }; undo.endUndoGrouping()
        #expect(abs((editor.askClaudeEffect(title)?.start ?? 0) - (start + 0.1)) < 1e-9)
        undo.beginUndoGrouping(); editor.adjustAskClaudeEffect(title) { $0.text = "Day 2"; $0.position = .bottom }; undo.endUndoGrouping()
        #expect(editor.askClaudeEffect(title)?.text == "Day 2" && editor.askClaudeEffect(title)?.position == .bottom)
        editor.askClaude.adjusting = blur
        #expect(editor.askClaudeAdjustingRect?.id == blur)
        undo.beginUndoGrouping(); editor.adjustAskClaudeEffect(blur) { $0.rect?.x = 0.95 }; undo.endUndoGrouping()
        #expect(editor.askClaudeEffect(blur)?.rect == ClipEffect.Rect(x: 0.8, y: 0.1, width: 0.2, height: 0.2), "kept inside the frame")
        undo.undo()
        #expect(editor.askClaudeEffect(blur)?.rect?.x == 0.1)
        // The box on the viewer maps through the export crop.
        let frame = try #require(AskClaudeRectOverlay.frame(ClipEffect.Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), project: editor.project, stage: CGSize(width: 320, height: 180)))
        #expect(abs(frame.midX - 160) < 0.5 && abs(frame.midY - 90) < 0.5)
        // The FX lane lists them with their names.
        #expect(editor.timelineEffects(on: .source).compactMap(\.label).sorted() == ["Blur", "Title"])
    }

    @Test func aTimelineRangeAndAClipRowOpenTheFieldToo() async throws {
        let (shell, editor, _, _) = try await open()
        defer { editor.close() }
        let words = editor.words
        editor.askClaude.timeRange = words[1].start...words[6].end
        editor.openAskClaudeOnTimeRange()
        guard case .time(let range)? = editor.askClaude.selection?.scope else { Issue.record("No time range"); return }
        #expect(range.lowerBound == words[1].start && editor.askClaude.label.contains("\u{2013}"))
        let clip = try #require(editor.project.edits.clips.first)
        shell.choose(.clip(clip.id), byClick: false)
        editor.openAskClaude(clip: clip.id)
        #expect(editor.askClaude.selection == AskClaudeSelection(scope: .clip(clip.id), clipID: clip.id))
        #expect(editor.askClaude.label == "Clip \(editor.clipNumber(clip.id) ?? 0)")
    }

    @Test func aReadOnlyOrAIlessEditorOffersNoAskClaude() async throws {
        let (_, editor, _, _) = try await open()
        defer { editor.close() }
        editor.app.set("llm.connector", .string(""))
        select(editor, 2...5)
        #expect(!editor.canAskClaude)
        editor.openAskClaudeOnSelection()
        #expect(editor.askClaude.selection == nil)
    }

    /// Adjust on a flipped or turned clip (design.md §6.8, §6.9): the viewer's box maps through the clip's flip and quarter
    /// turns, so it sits where the render draws the blur, and a drag maps back to the rect as filmed, which is what is
    /// stored. Dragging the box by a distance moves the drawn box by exactly that distance.
    @Test(arguments: [(true, 0), (true, 90), (false, 270)])
    func theAdjustBoxFollowsAFlippedOrTurnedClipBothWays(flip: Bool, degrees: Int) throws {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.export.aspect = .landscape
        project = try ClipControlsProject.setting(ProjectClipControls(clipId: "clip-main", flipHorizontal: flip, rotationDegrees: degrees), in: project)
        #expect(project.edits.activeClipId == "clip-main")
        let stage = CGSize(width: 320, height: 180)
        let filmed = ClipEffect.Rect(x: 0.3, y: 0.35, width: 0.1, height: 0.1)
        let controls = try #require(ClipControlsProject.controls(for: "clip-main", in: project))
        let shown = controls.mapRect(filmed)
        let scale = AskClaudeRectOverlay.pictureScale(project: project, stage: stage)
        let frame = try #require(AskClaudeRectOverlay.frame(filmed, project: project, stage: stage))
        // Where the render draws it: the flipped and turned rect through the centred crop.
        #expect(abs(frame.midX - (stage.width / 2 + (shown.midX - 0.5) * scale.width)) < 1e-6)
        #expect(abs(frame.midY - (stage.height / 2 + (shown.midY - 0.5) * scale.height)) < 1e-6)
        if flip, degrees == 0 { #expect(abs(frame.midX - (160 + 0.15 * 320)) < 1e-6, "mirrored to the right of the centre") }
        // A drag on the stage moves the drawn box by the drag and stores the rect as filmed.
        let drag = CGSize(width: 12, height: -8)
        let moved = AskClaudeRectOverlay.dragged(filmed, by: drag, project: project, stage: stage)
        let after = try #require(AskClaudeRectOverlay.frame(moved, project: project, stage: stage))
        #expect(abs(after.midX - (frame.midX + drag.width)) < 1e-6 && abs(after.midY - (frame.midY + drag.height)) < 1e-6, "\(after) vs \(frame)")
        #expect(abs(moved.width - filmed.width) < 1e-9 && abs(moved.height - filmed.height) < 1e-9)
        // Unflipped, the same drag would have moved the stored rect the other way (or across) on the source.
        let naive = ClipEffect.Rect(x: filmed.x + drag.width / scale.width, y: filmed.y + drag.height / scale.height, width: filmed.width, height: filmed.height)
        #expect(abs(naive.x - moved.x) > 1e-3 || abs(naive.y - moved.y) > 1e-3)
    }

    /// The box Adjust draws on the viewer sits on the blur the render draws (the compositor's own steps: orient, crop,
    /// `EffectFrames.picture`), on a flipped clip and a flipped and turned one.
    @Test(arguments: [(true, 0), (true, 90)])
    func theAdjustBoxSitsOnTheRenderedBlur(flip: Bool, degrees: Int) throws {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.export.aspect = .landscape
        let controls = ProjectClipControls(clipId: "clip-main", flipHorizontal: flip, rotationDegrees: degrees)
        project = try ClipControlsProject.setting(controls, in: project)
        let video = try #require(project.media.source.video)
        let output = CGSize(width: 640, height: 360)
        // A fine checkerboard the size of the source as filmed, so the blur changes every pixel it covers.
        let source = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputColor0": CIColor(red: 0.9, green: 0.8, blue: 0.2),
            "inputColor1": CIColor(red: 0.1, green: 0.2, blue: 0.5), "inputWidth": 12, "inputCenter": CIVector(x: 0, y: 0), "inputSharpness": 1])!
            .outputImage!.cropped(to: CGRect(x: 0, y: 0, width: video.width, height: video.height))
        let oriented = ClipPicture.orient(source, controls: controls)
        let crop = FrameCompositor.centerCrop(source: oriented.extent, output: output)
        let plain = CompositionFrameGeometry.fill(oriented, crop: crop, output: output)
        let filmed = ClipEffect.Rect(x: 0.45, y: 0.3, width: 0.1, height: 0.1)
        let blur = ClipEffect(id: "fx-blur-1", clipId: "clip-main", kind: .blur, start: 0, end: 4, rect: filmed,
                              tracking: ClipEffect.Tracking.none, track: [])
        let frames = EffectFrames(input: ClipEffectsRenderInput(effects: [blur], soundURLs: [:]))
        let blurred = frames.picture(plain, source: oriented.extent, crop: crop, output: output, time: 1, controls: controls)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let width = Int(output.width), height = Int(output.height)
        func pixels(_ image: CIImage) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &rgba, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: output), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return rgba
        }
        let before = pixels(plain), after = pixels(blurred)
        // The changed pixels' bounds, top-left origin like the viewer's stage.
        var changed = CGRect.null
        for row in 0..<height { for column in 0..<width {
            let index = (row * width + column) * 4
            if (0..<3).contains(where: { abs(Int(before[index + $0]) - Int(after[index + $0])) > 8 }) {
                changed = changed.union(CGRect(x: column, y: row, width: 1, height: 1))
            }
        } }
        let box = try #require(AskClaudeRectOverlay.frame(filmed, project: project, stage: output))
        #expect(!changed.isNull)
        #expect(abs(changed.minX - box.minX) <= 2 && abs(changed.maxX - box.maxX) <= 2 && abs(changed.minY - box.minY) <= 2
                && abs(changed.maxY - box.maxY) <= 2, "blur \(changed) vs box \(box)")
        // The picture with the viewer's box on it, for the review.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let graphics = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        graphics.draw(try #require(context.createCGImage(blurred, from: CGRect(origin: .zero, size: output), format: .RGBA8, colorSpace: space)),
                      in: CGRect(origin: .zero, size: output))
        graphics.setStrokeColor(CGColor(srgbRed: 1, green: 0.82, blue: 0.04, alpha: 1)); graphics.setLineWidth(2); graphics.setLineDash(phase: 0, lengths: [6, 3])
        graphics.stroke(CGRect(x: box.minX, y: output.height - box.maxY, width: box.width, height: box.height).insetBy(dx: 1, dy: 1))
        try ReviewCaptures.write(try #require(graphics.makeImage()), name: degrees == 0 ? "adjust-box-flipped" : "adjust-box-flipped-turned-\(degrees)")
    }
}
#endif
