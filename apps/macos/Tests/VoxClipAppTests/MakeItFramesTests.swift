#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// A Vision stand-in that reports what `look` says for each frame's time.
private final class TimedVision: FrameObserving {
    let look: @Sendable (Double) -> FrameObservation
    init(_ look: @escaping @Sendable (Double) -> FrameObservation) { self.look = look }
    func observe(_ image: CGImage, time: Double) throws -> FrameObservation { look(time) }
}

/// A decoder stand-in: a small grey frame at each time asked for; `failing` reads nothing (a source without video).
private final class GreyDecoder: FrameDecoding {
    let failing: Bool
    init(failing: Bool = false) { self.failing = failing }
    func reader(source: URL, maximumEdge: Int, tolerance: Double) -> any FrameReading { GreyReader(failing: failing) }
}

private struct GreyReader: FrameReading {
    let failing: Bool
    func image(at time: Double) async throws -> (image: CGImage, time: Double) {
        if failing { throw VoxClipError.decodeFailed("no video track") }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VoxClipError.decodeFailed("context") }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        guard let image = context.makeImage() else { throw VoxClipError.decodeFailed("image") }
        return (image, time)
    }
}

final class Lines: Sendable {
    private let value = Mutex<[String]>([])
    var all: [String] { value.withLock { $0 } }
    func add(_ line: String) { value.withLock { $0.append(line) } }
}

/// What the stub planner was given for each clip.
final class SentFrames: Sendable {
    private let value = Mutex<[ClipAutopilotFrames?]>([])
    func withLock<T>(_ body: (inout [ClipAutopilotFrames?]) -> T) -> T { value.withLock { body(&$0) } }
}

/// "Claude sees the picture" in Make it postable (ADR-R48, design.md §6.7.1) on a demo editor: the analyzer is a stub (no
/// Vision, no decode), the planner a stub that asks for each clip's frames as the live one does, and nothing is sent.
@Suite("Make it postable sees the picture", .serialized, .offlineFixtures)
@MainActor struct MakeItFramesTests {
    struct Fixture {
        let root: URL
        let editor: EditorModel
        let undo: UndoManager
        let sent: SentFrames
    }

    /// Words: 0 So · 1 um, · 2 today · (pause) · 3 we · 4 ship · 5 uh · 6 the · 7 clipper. · 8 Thanks. The plan tightens
    /// the clip to "we … clipper." (3…7), whose first word starts at 2.6 s after a pause.
    static func plan(blur: Bool = true, cover: String = "C1") -> ClipAutopilotPlan {
        ClipAutopilotPlan(startWord: 3, endWord: 7, title: "Ship day", hook: "",
            captions: .init(styleId: "vox-bold", font: .init(family: "Roboto", weight: 900), textCase: .upper, wordsPerCaption: 3),
            postText: "We ship.", score: 7, verdict: .post,
            frames: .init(blur: [.init(id: "B1", blur: blur, reason: "It shows calendar entries with names")],
                          cover: .init(id: cover, reason: "Eyes open, face centred")))
    }

    /// A face left of centre, eyes shut in the first frame (around 2.6 s) and open elsewhere; a phone screen at the
    /// sentence frame (2.95 s).
    static let look: @Sendable (Double) -> FrameObservation = { time in
        let shut = time > 2.5 && time < 2.75
        let face = FrameFace(rect: .init(x: 0.3, y: 0.2, width: 0.2, height: 0.36), captureQuality: 0.6,
                             leftEyeAspect: shut ? 0.1 : 0.3, rightEyeAspect: shut ? 0.1 : 0.3, yaw: 0, pitch: 0)
        let phone = FrameScreen(rect: .init(x: 0.62, y: 0.3, width: 0.12, height: 0.4), textBoxes: 6, textCoverage: 0.3, framed: true)
        return FrameObservation(time: time, faceCount: 1, face: face, screens: abs(time - 2.95) < 0.3 ? [phone] : [])
    }

    func fixture(plan: ClipAutopilotPlan = Self.plan(), ai: MakeItFrameAI? = MakeItFrameAI(name: "Claude", images: true, billing: .plan("Claude")),
                 failing: Bool = false, lines: Lines = Lines(), transcript: ((inout [TimedWord]) -> Void)? = nil) throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-make-it-frames-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: locations)
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        if let transcript, var words = project.transcript?.words { transcript(&words); project.transcript?.words = words }
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let sent = SentFrames()
        let fixture = Fixture(root: root, editor: editor, undo: undo, sent: sent)
        let analyzer = FrameAnalyzer(vision: TimedVision(Self.look), decoder: GreyDecoder(failing: failing), cache: FrameAnalysisCache(locations: locations))
        let words = project.transcript?.words ?? []
        let source = URL(fileURLWithPath: project.media.source.absolutePath), key = project.media.source.contentKey
        editor.makeIt.services = MakeItServices(
            plan: { request, _, frames, _ in
                // As the live planner does: each clip asks for its frames just before its send.
                if case .clip(let span) = request.mode { let shown = await frames?(0, span); sent.withLock { $0.append(shown) } }
                return ClipAutopilotSeries(plans: [plan])
            },
            voice: { _, _ in MakeItRewriteOutcome(result: .voiced(segments: [])) },
            voiceAvailable: { _ in false },
            framePass: { _ in VideoFramePass(analyzer: analyzer, source: source, contentKey: key, words: words) { lines.add($0) } },
            frameAI: { _ in ai })
        return fixture
    }

    func run(_ fixture: Fixture) async throws -> MakeItRun {
        fixture.editor.makeItPostable("clip-main")
        let run = try #require(fixture.editor.makeIt.run(for: "clip-main"))
        await run.task?.value
        return run
    }

    func step(_ undo: UndoManager, _ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }

    func close(_ fixture: Fixture) { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }

    @Test func theFourRowsApplyInTheMockupsOrderAndTheSendLineSaysWhatWent() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        let run = try await run(fixture)
        #expect(run.phase == .ready)
        let sent = try #require(fixture.sent.withLock { $0.first } ?? nil)
        #expect(sent.images.count == 1 && sent.summary.contains("eyes open") && sent.blur.map(\.id) == ["B1"] && sent.cover.map(\.id) == ["C1"])
        #expect(run.rows.prefix(4).map(\.id) == ["frames-opening", "frames-face", "frames-blur-B1", "frames-cover"])
        let opening = try #require(run.rows.first)
        #expect(opening.text == "Opens on a clear look at you")
        #expect(opening.detail == "Your eyes were shut on the first frame, so the clip starts in the pause 0.5 s earlier")
        #expect(opening.frames.map(\.tag) == ["eyes shut", nil] && opening.frames.last?.picked == true)
        let clip = try #require(editor.project.edits.clips.first { $0.id == "clip-main" })
        #expect(clip.leadInSeconds == 0.6 && clip.startWordId == "w4")
        let controls = try #require(ClipControlsProject.controls(for: "clip-main", in: editor.project))
        #expect(controls.reframe == .face(x: 0.4, y: 0.5), "the median face centre; a 16:9 source's 9:16 crop keeps its full height")
        #expect(controls.coverSeconds == 2.95)
        let blur = try #require(editor.project.clipEffects.first { $0.kind == .blur })
        #expect(blur.clipId == "clip-main" && blur.rect == .init(x: 0.62, y: 0.3, width: 0.12, height: 0.4) && blur.tracking == ClipEffect.Tracking.none)
        #expect(run.rows[2].text.hasPrefix("Blurred the phone screen at ") && run.rows[2].detail == "It shows calendar entries with names")
        #expect(run.rows[3].detail == "Eyes open, face centred · saved next to the export as a cover image" && run.rows[3].frames.count == 1)
        let line = try #require(editor.makeItSendLine(run))
        #expect(line.lead + line.emphasis + line.tail
                == "Claude read the clip's words and 1 small frame (one per sentence, 320 px) on your Claude plan. Faces were measured on this Mac.")
        #expect(editor.makeItFrameStrip(run).count == 1)
        #expect(fixture.undo.undoActionName == "Make it postable", "the picture rows are in the run's one step")
    }

    @Test(arguments: ["frames-opening", "frames-face", "frames-blur-B1", "frames-cover"])
    func eachRowUndoesOnItsOwnByteExactlyAndTheProjectSavesIt(_ rowID: String) async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        let run = try await run(fixture)
        // Saved and reloaded, every picture decision is in the project.
        let saved = try ProjectJSON.encode(editor.project)
        let reloaded = try ProjectJSON.decode(saved)
        #expect(try ProjectJSON.encode(reloaded) == saved && reloaded.edits.clips.first?.leadInSeconds == 0.6)
        #expect(reloaded.clipControls.first?.reframe != nil && reloaded.clipControls.first?.coverSeconds != nil && reloaded.clipEffects.contains { $0.kind == .blur })
        let before = editor.project
        var expected = before
        switch rowID {
        case "frames-opening": expected.edits.clips[0].leadInSeconds = nil
        case "frames-face": expected.clipControls[0].reframe = nil
        case "frames-blur-B1": expected.clipEffects.removeAll { $0.kind == .blur }
        default: expected.clipControls[0].coverSeconds = nil
        }
        step(fixture.undo) { editor.makeItUndo(rowID, in: run) }
        expected.modifiedAt = editor.project.modifiedAt
        #expect(try ProjectJSON.encode(editor.project) == ProjectJSON.encode(expected), "only that decision goes back")
        #expect(run.rows.first { $0.id == rowID }?.undone == true)
        fixture.undo.undo()
        #expect(try ProjectJSON.encode(editor.project) == ProjectJSON.encode(before), "the row's Undo is one step of its own")
    }

    @Test func theOpeningNeverReachesTheWordBefore() async throws {
        // "today" now ends at 2.3 s, inside the opening scan: its frames are clear looks too, but the start stays after it.
        let fixture = try fixture { words in words[2].end = 2.3 }
        defer { close(fixture) }
        let editor = fixture.editor
        let run = try await run(fixture)
        let opening = try #require(run.rows.first { $0.id == "frames-opening" })
        #expect(opening.detail.hasSuffix("starts in the pause 0.1 s earlier"))
        let timeline = try RenderCallerInputs.timeline(project: editor.project, clipID: "clip-main")
        let words = try #require(editor.project.transcript?.words)
        #expect(timeline.sourceTime(0) > words[2].end, "no sound of “today”")
        #expect(abs(timeline.sourceTime(0) - clipLeadInFloor(words, startIndex: 3)) < 1e-3)
    }

    @Test func aTextOnlyAIGetsTheSummaryNothingIsBlurredAndTheRowOffersBlur() async throws {
        let fixture = try fixture(ai: MakeItFrameAI(name: "Ollama", images: false, billing: .free))
        defer { close(fixture) }
        let editor = fixture.editor
        let run = try await run(fixture)
        let sent = try #require(fixture.sent.withLock { $0.first } ?? nil)
        #expect(sent.images.isEmpty && sent.summary.contains("screen with 6 text boxes"))
        #expect(!editor.project.clipEffects.contains { $0.kind == .blur }, "it could not see the screen")
        let row = try #require(run.rows.first { $0.id == "frames-blur-B1" })
        #expect(row.text.hasPrefix("Phone screen at ") && row.text.hasSuffix(" left sharp") && row.actionTitle == "Blur" && !row.undoable)
        let line = try #require(editor.makeItSendLine(run))
        #expect(line.lead + line.emphasis + line.tail == "Ollama read the clip's words and a text summary of 1 frame. Faces were measured on this Mac.")
        let steps = editor.undoSteps
        step(fixture.undo) { editor.makeItChange(.screen("B1"), run: run) }
        #expect(editor.project.clipEffects.contains { $0.kind == .blur } && fixture.undo.undoActionName == "Blur screen")
        #expect(run.rows.first { $0.id == "frames-blur-B1" }?.text.hasPrefix("Blurred the phone screen") == true)
        fixture.undo.undo()
        #expect(!editor.project.clipEffects.contains { $0.kind == .blur } && editor.undoSteps >= steps)
    }

    @Test func theCoverChangeOffersTheCandidatesAndAPickIsOneStep() async throws {
        let fixture = try fixture(plan: Self.plan(cover: "C9"))
        defer { close(fixture) }
        let editor = fixture.editor
        let run = try await run(fixture)
        let row = try #require(run.rows.first { $0.id == EditorModel.makeItCoverID })
        #expect(row.detail.hasPrefix("Eyes open, the clearest look measured on this Mac"), "an unknown id fell back to the local best")
        editor.makeItChange(.cover, run: run)
        #expect(run.openChoice == EditorModel.makeItCoverID)
        step(fixture.undo) { editor.makeItChooseCover(2.95, run: run) }
        #expect(ClipControlsProject.controls(for: "clip-main", in: editor.project)?.coverSeconds == 2.95)
    }

    @Test func anUnreadableVideoGoesOnAsTextOnlyAndLogsOneLine() async throws {
        let lines = Lines()
        let fixture = try fixture(failing: true, lines: lines)
        defer { close(fixture) }
        let run = try await run(fixture)
        #expect(run.phase == .ready)
        #expect(fixture.sent.withLock { $0 }.count == 1 && fixture.sent.withLock { $0.first } == .some(nil), "the plan went without frames")
        #expect(!run.rows.contains { $0.id.hasPrefix("frames-") } && fixture.editor.makeItSendLine(run) == nil)
        #expect(lines.all.count == 1 && lines.all.first?.hasPrefix("frames: ") == true)
    }

    @Test func imagesOnAKeyArePricedFirstAndTheCapHoldsAcrossThreePlansAtOnce() async throws {
        let fixture = try fixture(ai: MakeItFrameAI(name: "Claude", images: true, billing: .key(.anthropic, model: "claude-opus-5-5")))
        defer { close(fixture) }
        let editor = fixture.editor
        // One sheet frame (320 × 180, 77 tokens at $4 per million) costs $0.000308: the cap holds two, not three.
        let budget = MakeItBudget(cap: Decimal(string: "0.0007")!)
        let ids = ["clip-a", "clip-b", "clip-c"]
        var project = editor.project
        for id in ids { project.edits.clips.append(ClipRange(id: id, startWordId: "w4", endWordId: "w8")) }
        step(fixture.undo) { editor.replace(project, name: "Clips") }
        for id in ids { editor.makeIt.insert(MakeItRun(clipID: id, cap: budget.cap, budget: budget)) }
        async let first = editor.makeItFrames(clipIDs: ids, index: 0, span: 3...7)
        async let second = editor.makeItFrames(clipIDs: ids, index: 1, span: 3...7)
        async let third = editor.makeItFrames(clipIDs: ids, index: 2, span: 3...7)
        let sent = await [first, second, third].compactMap { $0 }
        #expect(sent.count == 3)
        #expect(sent.filter(\.sendsImages).count == 2 && sent.filter { !$0.sendsImages }.count == 1)
        #expect(budget.spent == Decimal(string: "0.000616") && budget.spent <= budget.cap)
        let priced = ids.compactMap { editor.makeIt.run(for: $0)?.frames?.usd }
        #expect(priced == [Decimal(string: "0.000308")!, Decimal(string: "0.000308")!])
        let textOnly = try #require(ids.compactMap { editor.makeIt.run(for: $0) }.first { $0.frames?.sent.sendsImages == false })
        #expect(editor.makeItSendLine(textOnly)?.emphasis == "a text summary of 1 frame")
    }

    @Test func thePassStartsWithTheTranscriptAndFindClipsIsNotKeptWaiting() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        let transcript = try #require(editor.project.transcript)
        step(fixture.undo) { editor.replaceTranscript(transcript) }
        let pass = try #require(editor.makeIt.framePass, "started as the transcript arrives")
        // Nothing waits for it: the call returned before the pass ran, and a clip's frames come from it afterwards.
        #expect(await pass.seconds == nil)
        #expect(await pass.finish())
        #expect(await pass.analyzed == 2 && pass.frameCount == 2, "one frame per sentence of the whole video")
        #expect(editor.startFramePass() === pass, "the same video and transcript keep their pass")
    }
}
#endif
