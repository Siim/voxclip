import CoreGraphics
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import voxclip_cli

/// A connector stand-in that answers at once: Find Clips with one clip over every line, and the plan with Claude's picks
/// among the frames (blur `B1`, cover `C1`), each with its reason. `images` is what it says it takes.
private actor PictureStub: LLMConnector {
    nonisolated let id = ConnectorID.ollama
    let images: Bool
    /// Find Clips' lines that hold the whole transcript.
    let lines: ClosedRange<Int>
    private(set) var planImages = 0
    init(images: Bool, lines: ClosedRange<Int>) { self.images = images; self.lines = lines }
    func status() -> ConnectorStatus { .ready }
    func supportsImages() -> Bool { images }
    func models(refresh: Bool) -> [LLMModel] { [.init(id: "fixture", name: "Fixture", contextTokens: 200_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 200_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        if request.feature == .clipFinder {
            let clips: [[String: Any]] = [["title": "Ship day", "reason": "A clear line.", "score": 8, "start_line": lines.lowerBound, "end_line": lines.upperBound]]
            return RawCompletion(text: String(decoding: try JSONSerialization.data(withJSONObject: ["clips": clips]), as: UTF8.self), model: model, stop: .complete)
        }
        guard let span = request.instruction.firstMatch(of: #/Plan the clip from word (\d+) to word (\d+)/#), let start = Int(span.1), let end = Int(span.2) else {
            throw LLMError.invalidOutput(reason: "not a Claude mode clip plan")
        }
        planImages += request.images.count
        var reply: [String: Any] = [:]
        let numbers: [String: Int] = ["startWord": start, "endWord": end, "captionWeight": 900, "wordsPerCaption": 3, "speed": 1, "musicPick": 0, "score": 8]
        let texts: [String: String] = ["title": "Ship day", "hook": "", "lengthReason": "", "captionStyle": "vox-bold", "captionReason": "punchy",
                                       "captionFont": "Roboto", "captionCase": "upper", "look": "original", "lookReason": "", "speedReason": "",
                                       "postText": "We ship.", "verdict": "post", "scoreReason": "Clear.", "tone": "none", "toneSummary": ""]
        for (key, value) in numbers { reply[key] = value }
        for (key, value) in texts { reply[key] = value }
        for key in ["corrections", "cuts", "pauseCuts", "rewrites", "zooms", "music", "questions"] { reply[key] = [Any]() }
        reply["frames"] = ["blur": [["id": "B1", "blur": true, "reason": "It shows calendar entries with names"]],
                           "cover": ["id": "C1", "reason": "Eyes open, face centred"]]
        return RawCompletion(text: String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self), model: model, stop: .complete)
    }
}

/// Vision on a schedule: a face left of centre, eyes shut on the clip's first frame (0.8 s) and open elsewhere, and a
/// phone screen with text in every frame; `face` false reports no face at all.
private struct ScheduledVision: FrameObserving {
    var face = true
    func observe(_ image: CGImage, time: Double) throws -> FrameObservation {
        let shut = abs(time - 0.8) < 0.06
        let found = FrameFace(rect: .init(x: 0.3, y: 0.2, width: 0.2, height: 0.36), captureQuality: 0.6,
                              leftEyeAspect: shut ? 0.1 : 0.3, rightEyeAspect: shut ? 0.1 : 0.3, yaw: 0, pitch: 0)
        let phone = FrameScreen(rect: .init(x: 0.62, y: 0.3, width: 0.12, height: 0.4), textBoxes: 6, textCoverage: 0.3, framed: true)
        return FrameObservation(time: time, faceCount: face ? 1 : 0, face: face ? found : nil, screens: [phone])
    }
}

/// Grey frames at any time asked for: the analyzer's decode, without the file.
private struct GreyFrames: FrameDecoding {
    func reader(source: URL, maximumEdge: Int, tolerance: Double) -> any FrameReading { GreyFrameReader() }
}

private struct GreyFrameReader: FrameReading {
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

/// "We ship the clipper today, and it shows you." over 0.8–4.6 s of speech-bursts.mov (6 s, 16:9), after 0.8 s of silence.
private func pictureProject(source: URL) async throws -> Project {
    let texts = ["We", "ship", "the", "clipper", "today,", "and", "it", "shows", "you."]
    let words = texts.enumerated().map { index, text in
        TimedWord(id: "w\(index)", text: text, start: 0.8 + Double(index) * 0.42, end: 1.1 + Double(index) * 0.42)
    }
    let transcript = Transcript(words: words, durationSeconds: 6, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
                                rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let probe = try await AVMediaProbe().probe(source)
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    return Project(id: UUID().uuidString.lowercased(), createdAt: Date(), modifiedAt: Date(), savedBy: ProjectWriter(version: "9.8.7"),
        media: ProjectMedia(source: MediaReference(absolutePath: source.path,
            sizeBytes: try #require((attributes[.size] as? NSNumber)?.int64Value), durationSeconds: probe.durationSeconds,
            contentKey: try JSONProjectStore.contentKey(for: source), video: probe.video, audio: probe.audio)),
        transcript: transcript, edits: ProjectEdits())
}

/// The headless autopilot applies what Claude decided from the picture (ADR-R48, ai.md §19.6): the opening, the
/// face-follow crop, the confirmed blur and the cover, as Make it postable's rows do, and its JSON's `picture` keeps why.
extension HeavyMediaTests {
    struct PictureRun {
        let clip: JSONValue
        let project: Project
        let outputs: [URL]
        let planImages: Int
    }

    /// The CLI's own pipeline on the stub connector and analyzer; with `export`, each clip is exported at 9:16 into
    /// `directory` through the export command's path.
    private func pictureRun(images: Bool, face: Bool = true, aspect: AspectRatio = .portrait, export: Bool, directory: URL) async throws -> PictureRun {
        let source = try await NativeMediaFixtures.shared.file("speech-bursts.mov")
        let project = try await pictureProject(source: source)
        let shared = try SharedResources.locate()
        let catalog = try LLMCatalog(shared: shared)
        let clock = ClaudeModeClock()
        let words = project.transcript?.words ?? []
        let stub = PictureStub(images: images, lines: ClipRequestBuilder.lineRange(of: 0...(words.count - 1), words: words))
        let pass = VideoFramePass(analyzer: FrameAnalyzer(vision: ScheduledVision(face: face), decoder: GreyFrames(), cache: nil),
                                  source: source, contentKey: project.media.source.contentKey, words: project.transcript?.words ?? [])
        let made = try await CLIWorkflow.autopilot(project: project, connector: stub, lanes: [], model: "fixture", preset: .quotes, count: 1,
                                                   shared: shared, catalog: catalog, clock: clock, report: AutopilotReport(quiet: true),
                                                   frames: pass, images: images, shapes: [aspect]) { project, clip, rank in
            guard export else { return [] }
            return try await CLIWorkflow.exportClip(project, clip: clip, rank: rank, outDir: directory, aspect: aspect.rawValue, quiet: true, clock: clock)
        }
        // Saved and reloaded, as `--out-dir` writes it.
        let saved = directory.appendingPathComponent("autopilot.voxclip")
        try await JSONProjectStore().save(made.project, to: saved)
        let reloaded = try await JSONProjectStore().load(from: saved)
        let clip = try #require(made.clips.first)
        return PictureRun(clip: clip, project: reloaded, outputs: clip[ai: "outputs"].aiArray.compactMap(\.aiString).map(URL.init(fileURLWithPath:)),
                          planImages: await stub.planImages)
    }

    @Test(.timeLimit(.minutes(3)))
    func theAutopilotAppliesThePictureDecisionsAndItsJSONKeepsWhy() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try await pictureRun(images: true, export: true, directory: directory)
        let clipID = try #require(run.clip[ai: "clipId"].aiString)
        #expect(run.planImages > 0, "the plan carried the frames as images")
        // The opening: eyes shut at 0.8 s, so the clip starts in the pause, 0.6 s before its first word (0.48 s earlier
        // than its usual 0.12 s lead).
        let range = try #require(run.project.edits.clips.first { $0.id == clipID })
        #expect(range.leadInSeconds == 0.6)
        // The crop: the measured face's centre for 9:16.
        let controls = try #require(ClipControlsProject.controls(for: clipID, in: run.project))
        #expect(controls.reframe == .face(x: 0.4, y: 0.5))
        // The blur Claude confirmed, over the screen's span and box.
        let blur = try #require(run.project.clipEffects.first { $0.kind == .blur })
        #expect(blur.id == ClipPicture.blurEffectID(clipID: clipID, candidate: "B1") && blur.rect == .init(x: 0.62, y: 0.3, width: 0.12, height: 0.4))
        // The cover: Claude's pick, written beside the export and embedded.
        let coverTime = try #require(controls.coverSeconds)
        let picture = run.clip[ai: "picture"]
        #expect(picture[ai: "opening"][ai: "reason"] == .string("Your eyes were shut on the first frame"))
        #expect(abs((picture[ai: "opening"][ai: "shift"].aiDouble ?? 0) + 0.48) < 1e-9)
        #expect(picture[ai: "crop"][ai: "aspect"] == .string("9:16") && picture[ai: "crop"][ai: "faceFound"] == .bool(true))
        #expect(picture[ai: "crop"][ai: "center"][ai: "x"] == .number(0.4) && picture[ai: "crop"][ai: "center"][ai: "y"] == .number(0.5))
        let blurs = picture[ai: "blur"].aiArray
        #expect(blurs.count == 1 && blurs.first?[ai: "id"] == .string("B1") && blurs.first?[ai: "blurred"] == .bool(true))
        #expect(blurs.first?[ai: "reason"] == .string("It shows calendar entries with names"))
        #expect(blurs.first?[ai: "start"].aiDouble == blur.start && blurs.first?[ai: "end"].aiDouble == blur.end)
        #expect(picture[ai: "cover"][ai: "id"] == .string("C1") && picture[ai: "cover"][ai: "time"].aiDouble == coverTime)
        #expect(picture[ai: "cover"][ai: "reason"] == .string("Eyes open, face centred") && picture[ai: "cover"][ai: "fallback"] == .bool(false))
        // The frames summary stays as it was.
        #expect(run.clip[ai: "frames"][ai: "images"] == .bool(true) && run.clip[ai: "frames"][ai: "cover"].aiDouble == coverTime)
        // The export: the JPEG beside it and the same JPEG as the MP4's art.
        let video = try #require(run.outputs.first)
        let jpeg = try Data(contentsOf: video.deletingLastPathComponent().appendingPathComponent(video.deletingPathExtension().lastPathComponent + "-cover.jpg"))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        let art = try await coverArt(video)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            #expect(art == jpeg)
        } else {
            // As far as the macOS 26 probe allows (`CoverArtWriteVariantsTests`, doc/publishing.md).
            withKnownIssue("macOS 26 doesn't embed the covr art", isIntermittent: true) { #expect(art == jpeg) }
        }
    }

    /// A connector without images gets the text summary: nothing is blurred (it could not see the screen) and the JSON says
    /// the screen was left sharp; the opening, the crop and the cover are local measurements and still apply.
    @Test(.timeLimit(.minutes(2)))
    func aConnectorWithoutImagesBlursNothing() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try await pictureRun(images: false, export: false, directory: directory)
        let clipID = try #require(run.clip[ai: "clipId"].aiString)
        #expect(run.planImages == 0 && run.clip[ai: "frames"][ai: "images"] == .bool(false))
        #expect(!run.project.clipEffects.contains { $0.kind == .blur })
        let blurs = run.clip[ai: "picture"][ai: "blur"].aiArray
        #expect(blurs.count == 1 && blurs.first?[ai: "blurred"] == .bool(false))
        #expect(run.project.edits.clips.first { $0.id == clipID }?.leadInSeconds == 0.6)
        #expect(ClipControlsProject.controls(for: clipID, in: run.project)?.coverSeconds != nil)
    }

    /// No face measured: the crop stays centred and the JSON says so; 16:9 has no crop to decide.
    @Test(.timeLimit(.minutes(2)))
    func withoutAFaceTheCropStaysCentred() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try await pictureRun(images: true, face: false, export: false, directory: directory)
        let clipID = try #require(run.clip[ai: "clipId"].aiString)
        #expect(ClipControlsProject.controls(for: clipID, in: run.project)?.reframe == nil)
        #expect(run.clip[ai: "picture"][ai: "crop"][ai: "faceFound"] == .bool(false) && run.clip[ai: "picture"][ai: "crop"][ai: "center"] == .null)
        let wide = try await pictureRun(images: true, aspect: .landscape, export: false, directory: directory)
        let wideID = try #require(wide.clip[ai: "clipId"].aiString)
        #expect(wide.clip[ai: "picture"][ai: "crop"] == .null && ClipControlsProject.controls(for: wideID, in: wide.project)?.reframe == nil)
    }
}
