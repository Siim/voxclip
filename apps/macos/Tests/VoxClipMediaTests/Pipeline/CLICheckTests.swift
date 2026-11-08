import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import voxclip_cli

/// A connector stand-in that answers at once: Find Clips with one clip over every line, and a plan with nothing to cut.
private actor OneClipStub: LLMConnector {
    nonisolated let id = ConnectorID.ollama
    let lines: ClosedRange<Int>
    init(lines: ClosedRange<Int>) { self.lines = lines }
    func status() -> ConnectorStatus { .ready }
    func supportsImages() -> Bool { false }
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
        var reply: [String: Any] = [:]
        let numbers: [String: Int] = ["startWord": start, "endWord": end, "captionWeight": 900, "wordsPerCaption": 3, "speed": 1, "musicPick": 0, "score": 8]
        let texts: [String: String] = ["title": "Ship day", "hook": "", "lengthReason": "", "captionStyle": "vox-bold", "captionReason": "punchy",
                                       "captionFont": "Roboto", "captionCase": "upper", "look": "original", "lookReason": "", "speedReason": "",
                                       "postText": "We ship.", "verdict": "post", "scoreReason": "Clear.", "tone": "none", "toneSummary": ""]
        for (key, value) in numbers { reply[key] = value }
        for (key, value) in texts { reply[key] = value }
        for key in ["corrections", "cuts", "pauseCuts", "rewrites", "zooms", "music", "questions"] { reply[key] = [Any]() }
        reply["frames"] = ["blur": [Any](), "cover": ["id": "", "reason": ""]]
        return RawCompletion(text: String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self), model: model, stop: .complete)
    }
}

/// `voxclip-cli check` and the autopilot's per-clip check (ADR-R49).
extension HeavyMediaTests {
    /// The checker fixture project saved in `directory` and its clip exported there with `extra` export options.
    private func exportedClip(_ directory: URL, name: String, extra: [String] = []) async throws -> (project: URL, export: URL) {
        let source = try await NativeMediaFixtures.shared.file("speech-bursts.mov")
        let projectURL = directory.appendingPathComponent("check.voxclip")
        if !FileManager.default.fileExists(atPath: projectURL.path) {
            try await JSONProjectStore().save(try await checkerProject(source: source), to: projectURL)
        }
        let output = directory.appendingPathComponent(name)
        _ = try await CLIWorkflow.export(try Export.parse(["--open", projectURL.path, "--export", output.path, "--clip", "clip-1", "--aspect", "9:16",
                                                           "--style", "off", "--quiet"] + extra), input: projectURL.path)
        return (projectURL, output)
    }

    @Test(.timeLimit(.minutes(2)))
    func theCheckCommandsExitStatusAndJSON() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let social = try await exportedClip(directory, name: "social.mp4")
        let quiet = try await exportedClip(directory, name: "quiet.mp4", extra: ["--loudness", "off"])

        // All ok or skipped: exit 0. The test's data folder has no model, so the words are skipped, never sent anywhere.
        let passing = try runCLI(["check", "--project", social.project.path, "--clip", "1", social.export.path, "--json"], directory: directory, timeout: 60)
        #expect(passing.status == 0, "\(passing.stderr)")
        let json = try passing.json
        #expect(json["ok"] as? Bool == true && json["command"] as? String == "check" && json["clipId"] as? String == "clip-1")
        let check = try #require(json["check"] as? [String: Any])
        #expect(check["passed"] as? Bool == true && check["engine"] is NSNull)
        #expect((check["words"] as? [String: Any])?["status"] as? String == "skipped")
        #expect((check["words"] as? [String: Any])?["reason"] as? String == "No local transcription model")
        let sync = try #require(check["sync"] as? [String: Any])
        #expect(sync["status"] as? String == "ok" && abs((sync["startOffset"] as? Double) ?? 1) <= 1 / 30.0)
        let loudness = try #require(check["loudness"] as? [String: Any])
        #expect(loudness["status"] as? String == "ok" && abs(((loudness["integratedLufs"] as? Double) ?? 0) + 14) <= 1, "\(loudness)")
        #expect((check["captions"] as? [String: Any])?["status"] as? String == "skipped")
        #expect(check["check"] == nil && (check["seconds"] as? Double ?? -1) >= 0)

        // An export made with loudness off, checked as social: the loudness warns and the exit status is 8.
        let warning = try runCLI(["check", "--project", social.project.path, "--clip", "clip-1", quiet.export.path, "--json"], directory: directory, timeout: 60)
        #expect(warning.status == Check.warningExitCode, "\(warning.stderr)")
        let warnedJSON = try warning.json
        let warned = try #require(warnedJSON["check"] as? [String: Any])
        let level = try #require(warned["loudness"] as? [String: Any])
        #expect(warned["passed"] as? Bool == false && level["status"] as? String == "warning")
        let items = try #require(level["items"] as? [[String: Any]])
        #expect(items.count == 1 && items.first?["kind"] as? String == "integratedLoudness" && ((items.first?["value"] as? Double) ?? 0) < -15)
        // Told it ran with loudness off, the same file passes: loudness is skipped with the reason.
        let told = try runCLI(["check", "--project", social.project.path, "--clip", "1", quiet.export.path, "--loudness", "off", "--json"], directory: directory, timeout: 60)
        let toldCheck = try told.json["check"] as? [String: Any]
        #expect(told.status == 0 && (toldCheck?["loudness"] as? [String: Any])?["reason"] as? String == "Loudness is off for this export")
        // Without --json, one line per check on stdout, and the same exit status.
        let human = try runCLI(["check", "--project", social.project.path, "--clip", "1", quiet.export.path], directory: directory, timeout: 60)
        let text = String(decoding: human.stdout, as: UTF8.self)
        #expect(human.status == Check.warningExitCode && text.contains("loudness: warning") && text.contains("words: skipped") && text.hasSuffix("warnings\n"), "\(text)")
        // A clip the project doesn't have is a usage error.
        let unknown = try runCLI(["check", "--project", social.project.path, "--clip", "7", social.export.path, "--json"], directory: directory, timeout: 60)
        let refused = try unknown.json["error"] as? [String: Any]
        #expect(unknown.status == 2 && refused?["code"] as? String == "usageError")
    }

    @Test(.timeLimit(.minutes(3)))
    func theAutopilotChecksEachExportedClipUnlessToldNotTo() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await NativeMediaFixtures.shared.file("speech-bursts.mov")
        var project = try await checkerProject(source: source)
        project.edits = ProjectEdits()
        let words = project.transcript?.words ?? []
        let shared = try SharedResources.locate()
        let catalog = try LLMCatalog(shared: shared)
        func run(checking: Bool) async throws -> (clip: JSONValue, timings: JSONValue) {
            let clock = ClaudeModeClock()
            let stub = OneClipStub(lines: ClipRequestBuilder.lineRange(of: 0...(words.count - 1), words: words))
            let checks = checking ? ClipChecks(transcript: project.transcript, clock: clock) : nil
            let made = try await CLIWorkflow.autopilot(project: project, connector: stub, lanes: [], model: "fixture", preset: .quotes, count: 1,
                                                       shared: shared, catalog: catalog, clock: clock, report: AutopilotReport(quiet: true),
                                                       checks: checks) { project, clip, rank in
                try await CLIWorkflow.exportClip(project, clip: clip, rank: rank, outDir: directory, aspect: "9:16", quiet: true, clock: clock, checks: checks)
            }
            return (try #require(made.clips.first), clock.json())
        }
        let checked = try await run(checking: true)
        let check = checked.clip[ai: "check"]
        #expect(check[ai: "sync"][ai: "status"] == .string("ok") && check[ai: "loudness"][ai: "status"] == .string("ok"), "\(check)")
        #expect(check[ai: "words"][ai: "status"] == .string("skipped"))
        // The clip's captions (vox-bold, the plan's pick) are measured against the 9:16 bands; vox-bold's default sits in
        // the bottom one (ExportCheckPlacementTests), and `passed` says so.
        let captions = check[ai: "captions"][ai: "status"].aiString
        #expect(captions == "ok" || captions == "warning", "\(check[ai: "captions"])")
        #expect(check[ai: "passed"] == .bool(captions == "ok"), "\(check)")
        // `--timings` gains the check, after the clip's export, and it never delays the first clip.
        let stages = checked.timings[ai: "stages"].aiArray
        let checkStage = try #require(stages.first { $0[ai: "stage"] == .string("check") })
        let exportStage = try #require(stages.first { $0[ai: "stage"] == .string("export") })
        #expect(checkStage[ai: "clip"] == .number(1) && (checkStage[ai: "start"].aiDouble ?? 0) >= (exportStage[ai: "end"].aiDouble ?? 1))
        #expect((checked.timings[ai: "firstClipSeconds"].aiDouble ?? 1e9) <= (checkStage[ai: "start"].aiDouble ?? 0))
        #expect(ClaudeModeClock.logLineMentions(checked: true))

        let unchecked = try await run(checking: false)
        #expect(unchecked.clip[ai: "check"] == .null)
        #expect(!unchecked.timings[ai: "stages"].aiArray.contains { $0[ai: "stage"] == .string("check") })
    }

    @Test func theCheckOptionsValidate() throws {
        #expect(throws: (any Error).self) { try Check.parse(["--project", "/tmp/p.voxclip", "--clip", "1", "/tmp/x.mp4", "--aspect", "4:3"]) }
        #expect(throws: (any Error).self) { try Check.parse(["--project", "/tmp/p.voxclip", "--clip", "1", "/tmp/x.mp4", "--loudness", "loud"]) }
        #expect(throws: (any Error).self) { try Check.parse(["--project", "/tmp/p.voxclip", "/tmp/x.mp4"]) }
        let options = try Check.parse(["--project", "/tmp/p.voxclip", "--clip", "2", "/tmp/x.mp4", "--json"])
        #expect(options.clip == "2" && options.export == "/tmp/x.mp4" && options.aspect == nil && options.json)
        #expect(try Autopilot.parse(["--open", "/tmp/x.mov", "--connector", "claude-code", "--no-check"]).noCheck)
        #expect(try !Autopilot.parse(["--open", "/tmp/x.mov", "--connector", "claude-code"]).noCheck)
    }
}

private extension ClaudeModeClock {
    /// The app log's numbers-only line names the check stage like any other (`check1=`).
    static func logLineMentions(checked: Bool) -> Bool {
        let clock = ClaudeModeClock()
        clock.record(.check, clip: 1, since: 0)
        return clock.logLine().contains("check1=") == checked
    }
}
