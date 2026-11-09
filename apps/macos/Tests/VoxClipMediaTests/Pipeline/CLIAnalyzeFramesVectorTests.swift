import Foundation
import Testing
import VoxClipCore
@testable import voxclip_cli

/// Replays shared/fixtures/clip-frames/analyze-frames-cli-cases.json (ADR-R48, Windows package W5): `FrameAnalyzerCLI.report` on
/// each fabricated analysis prints exactly the bytes the file holds, through `CLIExecution.printed` (what `printJSON` writes),
/// and each number is the text the file names. The Windows CLI's `AnalyzeFramesVectorTests` replays the same file, so the
/// two `analyze-frames --json` outputs agree byte for byte.
@Suite("Analyze-frames CLI vectors")
struct CLIAnalyzeFramesVectorTests {
    static let path = "fixtures/clip-frames/analyze-frames-cli-cases.json"

    private struct WordCase: Decodable { var id: String; var text: String; var kind: String; var start: Double; var end: Double }
    private struct ClipCase: Decodable { var first: Int; var last: Int; var cut: [String] }
    private struct VideoCase: Decodable { var width: Int; var height: Int; var rotationDegrees: Int }
    private struct SheetCase: Decodable { var index: Int; var sentence: Int; var width: Int; var height: Int; var bytes: Int }
    private struct ReportCase: Decodable {
        var id: String
        var words: [WordCase]
        var clip: ClipCase
        var video: VideoCase?
        var analysis: FrameAnalysis
        var sheet: [SheetCase]
        var videoPass: JSONValue
        var json: String
    }
    private struct NumberCase: Decodable { var value: Double; var text: String }
    private struct Vectors: Decodable {
        var schema: String
        var version: String
        var caseCount: Int
        var reports: [ReportCase]
        var numbers: [NumberCase]
    }

    private static func vectors() throws -> Vectors { try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data(path)) }

    @Test func theVectorsHaveTheirKeysAndCounts() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: FixtureLoader.data(Self.path)) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "description", "version", "caseCount", "counts", "reports", "numbers"])
        let vectors = try Self.vectors()
        #expect(vectors.schema == "voxclip-analyze-frames-cli-cases/1")
        #expect(vectors.caseCount == vectors.reports.count + vectors.numbers.count)
    }

    @Test func theReportPrintsTheSharedBytes() throws {
        let vectors = try Self.vectors()
        for report in vectors.reports {
            let words = report.words.map { TimedWord(id: $0.id, text: $0.text, start: $0.start, end: $0.end) }
            let clip = try #require(FrameClip(words: words, first: report.clip.first, last: report.clip.last, cutWordIds: Set(report.clip.cut)))
            let video = report.video.map { MediaVideo(width: $0.width, height: $0.height, frameRate: 30, rotationDegrees: $0.rotationDegrees) }
            let project = Project(id: UUID().uuidString.lowercased(), createdAt: Date(), modifiedAt: Date(), savedBy: ProjectWriter(version: "9.8.7"),
                media: ProjectMedia(source: MediaReference(absolutePath: "/fixture.mp4", sizeBytes: 1, durationSeconds: 10,
                                                           contentKey: report.analysis.contentKey, video: video)),
                transcript: nil, edits: ProjectEdits(clips: []))
            let sheet = FrameSheet(frames: report.sheet.map {
                FrameSheetFrame(index: $0.index, observation: report.analysis.sentences[$0.sentence], jpeg: Data(count: $0.bytes),
                                width: $0.width, height: $0.height)
            })
            var baseline = report.analysis.pitchBaseline
            var extra: [String: JSONValue] = [:]
            if case .object(let pass) = report.videoPass {
                extra["videoPass"] = report.videoPass
                if case .number(let value)? = pass["pitchBaseline"] { baseline = value } else { baseline = nil }
            }
            let value = try FrameAnalyzerCLI.report(analysis: report.analysis, clip: clip, project: project, sheet: sheet,
                                                    pitchBaseline: baseline, extra: extra)
            guard case .object(var fields) = value else { Issue.record("\(report.id): not an object"); continue }
            fields["version"] = .string(vectors.version)
            let printed = String(decoding: try CLIExecution.printed(.object(fields)), as: UTF8.self)
            #expect(printed == report.json, "\(report.id):\n\(printed)")
        }
    }

    @Test func numbersAreWrittenAsTheFileSays() throws {
        for number in try Self.vectors().numbers {
            let printed = String(decoding: try CLIExecution.printed(.number(number.value)), as: UTF8.self)
            #expect(printed == number.text + "\n", "\(number.value)")
        }
    }
}
