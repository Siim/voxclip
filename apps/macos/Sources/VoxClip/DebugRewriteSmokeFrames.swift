#if DEBUG
import CoreGraphics
import Foundation
import VoxClipCore
import VoxClipMedia

// S-make-frames and S-make-frames-text (doc/release.md): "Claude sees the picture" in ✦ Make it postable (ADR-R48 part 2,
// design.md §6.7.1). The frame analyzer is a stand-in (no Vision, no decode): a face left of centre whose eyes are shut on
// the clip's first frame and a phone screen in every sentence frame. The planner stub answers with the reply's frame
// choices. F1–F4 check the four rows, their single undo steps, the send line and the text-only path.

extension DebugRewriteSmoke {
    static var framesScenarios: [Definition] { [
        Definition(id: "S-make-frames", title: "✦ Make it postable sees the picture: opening, face-follow, blur and cover rows", requiresCompletion: false,
            fixture: Fixture(rewrites: [])) { harness in
            try await harness.makeItFrames(images: true)
        },
        Definition(id: "S-make-frames-text", title: "✦ Make it postable on a text-only AI: a summary of the frames, the screen left sharp with Blur",
            requiresCompletion: false, fixture: Fixture(rewrites: [])) { harness in
            try await harness.makeItFrames(images: false)
        },
    ] }
}

/// The smoke's frame stand-ins: a grey 640×360 picture at each time asked for, and `look` for what is in it.
private final class SmokeFrameVision: FrameObserving {
    let look: @Sendable (Double) -> FrameObservation
    init(_ look: @escaping @Sendable (Double) -> FrameObservation) { self.look = look }
    func observe(_ image: CGImage, time: Double) throws -> FrameObservation { look(time) }
}

private final class SmokeGreyDecoder: FrameDecoding {
    func reader(source: URL, maximumEdge: Int, tolerance: Double) -> any FrameReading { SmokeGreyReader() }
}

private struct SmokeGreyReader: FrameReading {
    func image(at time: Double) async throws -> (image: CGImage, time: Double) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VoxClipError.decodeFailed("context") }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        guard let image = context.makeImage() else { throw VoxClipError.decodeFailed("image") }
        return (image, time)
    }
}

extension DebugRewriteSmoke.Harness {
    func makeItFrames(images: Bool) async throws {
        let editor = try makeItPrepare { range, _ in
            var plan = DebugRewriteSmoke.makeItPlan(span: range, cut: nil, rewrite: nil, zoom: nil, music: false, score: 8, title: "Edit video like a doc")
            plan.frames = .init(blur: [.init(id: "B1", blur: true, reason: "It shows a chat with names")],
                                cover: .init(id: "C1", reason: "Eyes open, face centred"))
            return plan
        }
        let words = editor.project.transcript?.words ?? []
        guard let start = DebugRewriteSmoke.wordIndex("first", in: words), let end = DebugRewriteSmoke.wordIndex("drag", in: words, from: start) else {
            throw DebugRewriteSmoke.Failure.setup("the script lost its second to fourth sentences")
        }
        let opening = words[start].start
        let look: @Sendable (Double) -> FrameObservation = { time in
            let shut = abs(time - opening) < 0.08
            let face = FrameFace(rect: .init(x: 0.3, y: 0.2, width: 0.2, height: 0.36), captureQuality: 0.6,
                                 leftEyeAspect: shut ? 0.1 : 0.3, rightEyeAspect: shut ? 0.1 : 0.3, yaw: 0, pitch: 0)
            let phone = FrameScreen(rect: .init(x: 0.62, y: 0.3, width: 0.12, height: 0.4), textBoxes: 6, textCoverage: 0.3, framed: true)
            return FrameObservation(time: time, faceCount: 1, face: face, screens: time > opening + 0.7 ? [phone] : [])
        }
        let analyzer = FrameAnalyzer(vision: SmokeFrameVision(look), decoder: SmokeGreyDecoder(), cache: nil)
        let source = URL(fileURLWithPath: editor.project.media.source.absolutePath), key = editor.project.media.source.contentKey
        editor.makeIt.services?.framePass = { _ in VideoFramePass(analyzer: analyzer, source: source, contentKey: key, words: words) }
        let ai = images ? MakeItFrameAI(name: "Claude", images: true, billing: .plan("Claude")) : MakeItFrameAI(name: "Ollama", images: false, billing: .free)
        editor.makeIt.services?.frameAI = { _ in ai }
        editor.apply(.addClip(ClipRange(id: "smoke-clip", startWordId: words[start].id, endWordId: words[end].id, title: "Smoke clip",
                                        origin: .manual, selected: true)), name: "Make clip")
        _ = editor.setScope("smoke-clip")
        let steps = editor.undoSteps
        try await act("click [\(editor.makeItTitle(clipID: "smoke-clip"))]", clicked: "makeIt") {
            editor.makeItPostable("smoke-clip")
            await editor.makeIt.run(for: "smoke-clip")?.task?.value
        }
        ended = true
        guard let run = editor.makeIt.run(for: "smoke-clip") else { throw DebugRewriteSmoke.Failure.setup("no run") }
        let clip = editor.project.edits.clips.first { $0.id == "smoke-clip" }
        let controls = ClipControlsProject.controls(for: "smoke-clip", in: editor.project)
        let blurred = editor.project.clipEffects.contains { $0.clipId == "smoke-clip" && $0.kind == .blur }
        // The picture rows come first, after the tone row when the run wrote the clip in a tone (design.md §6.7.1).
        let pictureRows = run.rows.drop { $0.change == .tone }.prefix(4)
        let ids = pictureRows.map(\.id)
        let line = editor.makeItSendLine(run).map { $0.lead + $0.emphasis + $0.tail } ?? "no send line"
        let screen = run.rows.first { $0.id == "frames-blur-B1" }
        var checks: [DebugRewriteSmoke.Check] = []
        if images {
            checks.append(DebugRewriteSmoke.Check(invariant: "F1",
                passed: ids == ["frames-opening", "frames-face", "frames-blur-B1", "frames-cover"] && (clip?.leadInSeconds ?? 0) > 0
                    && controls?.reframe?.mode == ReframeSettings.faceMode && controls?.coverSeconds != nil && blurred,
                detail: pictureRows.map(\.text).joined(separator: " · ")))
            checks.append(DebugRewriteSmoke.Check(invariant: "F3",
                passed: line.hasPrefix("Claude read the clip's words and ") && line.contains("small frame") && line.contains("on your Claude plan")
                    && !editor.makeItFrameStrip(run).isEmpty,
                detail: line))
            // F2: one undo step for the run; each row's Undo is a step of its own and takes back only its decision.
            let afterRun = editor.undoSteps
            for id in ["frames-opening", "frames-face", "frames-blur-B1", EditorModel.makeItCoverID] { editor.makeItUndo(id, in: run) }
            let undone = editor.project.edits.clips.first { $0.id == "smoke-clip" }?.leadInSeconds == nil
                && ClipControlsProject.controls(for: "smoke-clip", in: editor.project)?.reframe == nil
                && ClipControlsProject.controls(for: "smoke-clip", in: editor.project)?.coverSeconds == nil
                && !editor.project.clipEffects.contains { $0.clipId == "smoke-clip" && $0.kind == .blur }
            checks.append(DebugRewriteSmoke.Check(invariant: "F2", passed: afterRun == steps + 1 && editor.undoSteps == afterRun + 4 && undone,
                detail: "\(afterRun - steps) step(s) for the run, \(editor.undoSteps - afterRun) for four row Undos; all four taken back: \(undone)"))
        } else {
            checks.append(DebugRewriteSmoke.Check(invariant: "F4",
                passed: !blurred && screen?.text.hasSuffix(" left sharp") == true && screen?.actionTitle == "Blur"
                    && line == "Ollama read the clip's words and a text summary of \(run.frames?.sent.frames.count ?? 0) frames. Faces were measured on this Mac."
                    && (run.frames?.sent.images.isEmpty ?? false),
                detail: (screen.map { "\($0.text) [\($0.actionTitle ?? "")]" } ?? "no screen row") + " · " + line))
        }
        makeItAppend(checks)
        completed = checks.allSatisfy(\.passed)
    }
}
#endif
