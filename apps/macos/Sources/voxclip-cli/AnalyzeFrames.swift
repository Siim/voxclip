import ArgumentParser
import Foundation
import VoxClipCore
import VoxClipMedia

/// `voxclip-cli analyze-frames --open <project> --clip <id> --json` (ADR-R48): the on-device frame analysis of one
/// clip, the decisions made from it and the timings, without changing the project. Nothing is sent anywhere.
struct AnalyzeFrames: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "analyze-frames",
        abstract: "Measure a clip's frames on this Mac (faces, eyes, screens) without modifying the project.")
    @Option(name: .customLong("open"), help: "Project file.") var input: String
    @Option(help: "Saved clip ID.") var clip: String
    @Flag(name: .customLong("no-cache"), help: "Analyze every frame again and leave the cache untouched.") var noCache = false
    @Option(name: .customLong("sheet-out"), help: "Folder to write the frame sheet's JPEGs to.") var sheetOut: String?
    @Flag(help: "Print JSON.") var json = false

    mutating func run() async throws {
        let input = input, clipID = clip, noCache = noCache, sheetOut = sheetOut
        try await CLIExecution.run(command: "analyze-frames", json: json) {
            let projectURL = URL(fileURLWithPath: input)
            let store = JSONProjectStore()
            let project = try await store.load(from: projectURL)
            guard let transcript = project.transcript else { throw VoxClipError.noSpeech }
            guard let range = project.edits.clips.first(where: { $0.id == clipID }) else { throw ValidationError("The requested clip does not exist.") }
            guard let frameClip = FrameClip(transcript: transcript, clip: range, cutWordIds: Set(project.edits.cutWordIds)) else {
                throw ValidationError("The requested clip has no kept words.")
            }
            let source = try await store.resolveSource(for: project, projectURL: projectURL)
            let contentKey = project.media.source.contentKey
            let cache = noCache ? nil : FrameAnalysisCache(locations: DataLocations())
            let analyzer = FrameAnalyzer(cache: cache)
            let result = try await analyzer.analyze(source: source, contentKey: contentKey, clip: frameClip)
            if let sheetOut { try FrameAnalyzerCLI.write(result.sheet, to: URL(fileURLWithPath: sheetOut)) }
            return try FrameAnalyzerCLI.report(analysis: result.analysis, clip: frameClip, project: project, sheet: result.sheet)
        }
    }
}

enum FrameAnalyzerCLI {
    static func report(analysis: FrameAnalysis, clip: FrameClip, project: Project, sheet: FrameSheet) throws -> JSONValue {
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
        return CLIWorkflow.success("analyze-frames", fields: [
            "clipStart": .number(clip.start), "clipEnd": .number(clip.end),
            "analysis": try value(analysis), "decisions": .object(decisions), "sheet": .object(sheetFields),
        ])
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
