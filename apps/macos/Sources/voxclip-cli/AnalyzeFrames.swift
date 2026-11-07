import ArgumentParser
import Foundation
import VoxClipCore
import VoxClipMedia

/// `voxclip-cli analyze-frames --open <project> --clip <id> --json` (ADR-R48): the on-device frame analysis of one
/// clip, the decisions made from it and the timings, without changing the project. Nothing is sent anywhere.
struct AnalyzeFrames: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "analyze-frames",
        abstract: "Measure a clip's frames on this Mac (faces, eyes, screens) without modifying the project.")
    @Option(name: .customLong("open"), help: "Project file, or a media file with --transcript and --words.") var input: String
    @Option(help: "Saved clip ID (with a project).") var clip: String?
    @Option(help: "Transcript JSON (fixture words) when --open is a media file.") var transcript: String?
    @Option(help: "With --transcript: the clip as first:last word indices.") var words: String?
    @Flag(name: .customLong("video-pass"),
          help: "First run the whole video's sentence-frame pass, as Claude mode does beside Find Clips, and time it, the clip's frames from it and its opening scan.")
    var videoPass = false
    @Flag(name: .customLong("no-cache"), help: "Analyze every frame again and leave the cache untouched.") var noCache = false
    @Option(name: .customLong("sheet-out"), help: "Folder to write the frame sheet's JPEGs to.") var sheetOut: String?
    @Flag(help: "Print JSON.") var json = false

    mutating func validate() throws {
        if transcript == nil {
            guard clip != nil, words == nil else { throw ValidationError("A project needs --clip; --words goes with --transcript.") }
        } else {
            guard clip == nil, let words, words.split(separator: ":").compactMap({ Int($0) }).count == 2 else {
                throw ValidationError("A media file needs --transcript and --words first:last.")
            }
        }
    }

    mutating func run() async throws {
        let input = input, clipID = clip, transcriptPath = transcript, wordRange = words, noCache = noCache, sheetOut = sheetOut, videoPass = videoPass
        try await CLIExecution.run(command: "analyze-frames", json: json) {
            let inputURL = URL(fileURLWithPath: input)
            let project: Project, source: URL, range: ClipRange
            if let transcriptPath {
                let words: Transcript
                do { words = try ProjectJSON.decoder().decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: transcriptPath))) }
                catch { throw VoxClipError.projectUnreadable("The transcript could not be read") }
                let bounds = (wordRange ?? "").split(separator: ":").compactMap { Int($0) }
                guard bounds.count == 2, bounds[0] >= 0, bounds[0] <= bounds[1], bounds[1] < words.words.count else {
                    throw ValidationError("--words must name two word indices of the transcript, first:last.")
                }
                let probe = try await AVMediaProbe().probe(inputURL)
                project = try CLIWorkflow.imported(inputURL, probe: probe, transcript: words)
                source = inputURL
                range = ClipRange(id: "words", startWordId: words.words[bounds[0]].id, endWordId: words.words[bounds[1]].id)
            } else {
                let store = JSONProjectStore()
                project = try await store.load(from: inputURL)
                guard let found = project.edits.clips.first(where: { $0.id == clipID }) else { throw ValidationError("The requested clip does not exist.") }
                range = found
                source = try await store.resolveSource(for: project, projectURL: inputURL)
            }
            guard let transcript = project.transcript else { throw VoxClipError.noSpeech }
            guard let frameClip = FrameClip(transcript: transcript, clip: range, cutWordIds: Set(project.edits.cutWordIds)) else {
                throw ValidationError("The requested clip has no kept words.")
            }
            let contentKey = project.media.source.contentKey
            let cache = noCache ? nil : FrameAnalysisCache(locations: DataLocations())
            let analyzer = FrameAnalyzer(cache: cache)
            var extra: [String: JSONValue] = [:]
            if videoPass {
                extra["videoPass"] = await FrameAnalyzerCLI.timedPass(analyzer: analyzer, source: source, contentKey: contentKey,
                                                                      words: transcript.words, clip: frameClip)
            }
            let result = try await analyzer.analyze(source: source, contentKey: contentKey, clip: frameClip)
            if let sheetOut { try FrameAnalyzerCLI.write(result.sheet, to: URL(fileURLWithPath: sheetOut)) }
            return try FrameAnalyzerCLI.report(analysis: result.analysis, clip: frameClip, project: project, sheet: result.sheet, extra: extra)
        }
    }
}

enum FrameAnalyzerCLI {
    /// The whole video's pass as Claude mode runs it (ADR-R48 part 2), then the clip's frames from it and its opening scan,
    /// each timed in wall seconds.
    static func timedPass(analyzer: FrameAnalyzer, source: URL, contentKey: String, words: [TimedWord], clip: FrameClip) async -> JSONValue {
        func since(_ start: ContinuousClock.Instant) -> JSONValue {
            let parts = start.duration(to: .now).components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            return .number((seconds * 1000).rounded() / 1000)
        }
        let pass = VideoFramePass(analyzer: analyzer, source: source, contentKey: contentKey, words: words) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        let begin = ContinuousClock.now
        let read = await pass.finish()
        let passSeconds = since(begin)
        let clipBegin = ContinuousClock.now
        let frames = await pass.frames(for: clip)
        let clipSeconds = since(clipBegin)
        let openingBegin = ContinuousClock.now
        let opening = await pass.opening(for: clip)
        let openingSeconds = since(openingBegin)
        return .object(["read": .bool(read), "frames": .number(Double(pass.frameCount)), "analyzed": .number(Double(await pass.analyzed)),
                        "cached": .number(Double(await pass.cached)), "seconds": passSeconds,
                        "clipFrames": .number(Double(frames?.sentences.count ?? 0)), "clipSeconds": clipSeconds,
                        "openingFrames": .number(Double(opening?.count ?? 0)), "openingSeconds": openingSeconds])
    }

    static func report(analysis: FrameAnalysis, clip: FrameClip, project: Project, sheet: FrameSheet,
                       extra: [String: JSONValue] = [:]) throws -> JSONValue {
        let encoder = ProjectJSON.encoder()
        func value(_ item: some Encodable) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: encoder.encode(item)) }
        let aspect = sourceAspect(project.media.source.video)
        let samples = analysis.sentences.map { (time: $0.time, face: $0.face?.rect) }
        let scan = analysis.opening + analysis.sentences
        let openingChoice = OpeningFrame.choose(clip, scan: analysis.opening)
        var decisions: [String: JSONValue] = [
            "opening": try openingChoice.map(value) ?? .null,
            "cover": try CoverFrame.pick(scan).map(value) ?? .null,
            "blurSpans": try value(FrameBlurSpans.merge(analysis.sentences, maxGap: ClipFrameCandidates.blurMaxGap, pad: ClipFrameCandidates.blurPad)),
            // What the plan request names (ai.md §19.6): screens B1… and covers C1…C3.
            "blurCandidates": try value(ClipFrameCandidates.blur(analysis.sentences, clipStart: clip.start, clipEnd: clip.end)),
            "coverCandidates": try value(ClipFrameCandidates.cover(sheet.frames)),
        ]
        decisions["crop9x16"] = try FaceFollowCrop.plan(samples, sourceAspect: aspect, targetAspect: 9.0 / 16.0).map(value) ?? .null
        decisions["crop1x1"] = try FaceFollowCrop.plan(samples, sourceAspect: aspect, targetAspect: 1).map(value) ?? .null
        let sheetFields: [String: JSONValue] = [
            "frames": .number(Double(sheet.frames.count)),
            "imageBytes": .number(Double(sheet.imageBytes)),
            "estimatedImageTokens": .number(Double(sheet.estimatedImageTokens)),
            "estimatedSummaryTokens": .number(Double(sheet.estimatedSummaryTokens)),
            "summary": .string(sheet.summary),
        ]
        let fields: [String: JSONValue] = [
            "clipStart": .number(clip.start), "clipEnd": .number(clip.end),
            "analysis": try value(analysis), "decisions": .object(decisions), "sheet": .object(sheetFields),
        ]
        return CLIWorkflow.success("analyze-frames", fields: fields.merging(extra) { first, _ in first })
    }

    /// The source picture's display width over height, after its rotation; 16:9 when the project has no video facts.
    static func sourceAspect(_ video: MediaVideo?) -> Double {
        guard let video, video.width > 0, video.height > 0 else { return 16.0 / 9.0 }
        let width = Double(video.width), height = Double(video.height)
        return video.rotationDegrees % 180 == 0 ? width / height : height / width
    }

    static func write(_ sheet: FrameSheet, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for frame in sheet.frames {
            let name = String(format: "frame-%02d.jpg", frame.index)
            try frame.image.data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

}
