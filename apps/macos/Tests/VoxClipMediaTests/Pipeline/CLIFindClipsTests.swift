import Foundation
import Testing
import VoxClipCore
@testable import voxclip_cli

@Suite("Find-clips CLI output parity")
struct CLIFindClipsTests {
    @Test(arguments: [false, true])
    func resultMatchesSharedExpectedOutput(emptyClips: Bool) throws {
        let fixture = try loadFixture()
        let resultCase = try #require(fixture["result"] as? [String: Any])
        var expected = try #require(resultCase["expected"] as? [String: Any])
        if emptyClips { expected["clips"] = [] as [String] }
        var payload = expected
        for key in ["ok", "command", "version"] { payload.removeValue(forKey: key) }
        let resultData = try JSONSerialization.data(withJSONObject: payload)
        let result = try ProjectJSON.decoder().decode(ProjectAIResult.self, from: resultData)
        let output = try CLIWorkflow.success("find-clips", value: result)
        var actual = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        let version = actual.removeValue(forKey: "version") as? String
        #expect(version?.isEmpty == false)
        #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
    }

    @Test(.timeLimit(.minutes(1)))
    func dryRunMatchesSharedExpectedShapeWithoutChangingProject() throws {
        let fixture = try loadFixture()
        let dryRun = try #require(fixture["dryRun"] as? [String: Any])
        let shared = try FixtureLoader.sharedRoot(environment: [:])
        let project = shared.appendingPathComponent("fixtures/\(try #require(dryRun["project"] as? String))")
        let original = try Data(contentsOf: project)
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = try #require(dryRun["arguments"] as? [String])
        let arguments = ["find-clips", "--open", project.path, "--dry-run", "--json"] + options
        let result = try runCLI(arguments, directory: directory)
        #expect(result.status == 0)
        let output = try result.json
        #expect(Set(output.keys) == Set(try #require(dryRun["keys"] as? [String])))
        let expected = try #require(dryRun["expected"] as? [String: Any])
        for (key, value) in expected {
            #expect(NSDictionary(dictionary: [key: try #require(output[key])]).isEqual(to: [key: value]))
        }
        #expect((output["version"] as? String)?.isEmpty == false)
        let prompts = try #require(output["prompts"] as? [[String: Any]])
        #expect(prompts.count == dryRun["promptCount"] as? Int)
        let promptKeys = Set(try #require(dryRun["promptKeys"] as? [String]))
        for prompt in prompts {
            #expect(Set(prompt.keys) == promptKeys)
            for key in promptKeys { #expect((prompt[key] as? String)?.isEmpty == false) }
        }
        #expect(try Data(contentsOf: project) == original)
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio])
    func localDryRunUsesFallbackWithoutQueryingConnector(_ connector: ConnectorID) throws {
        let shared = try FixtureLoader.sharedRoot(environment: [:])
        let source = shared.appendingPathComponent("fixtures/projects/interview-take.voxclip")
        var project = try ProjectJSON.decode(Data(contentsOf: source))
        var transcript = try #require(project.transcript)
        transcript.words = (0..<1_500).map { (index: Int) -> TimedWord in
            let position: Double = Double(index)
            let start: Double = position / 2
            let end: Double = start + 0.4
            return TimedWord(id: "local-\(index)", text: "word.", start: start, end: end)
        }
        transcript.durationSeconds = 750
        project.transcript = transcript
        project.media.source.durationSeconds = transcript.durationSeconds
        project.edits = ProjectEdits()
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("local.voxclip")
        let original = try ProjectJSON.encode(project)
        try original.write(to: input)
        let promptData = try Data(contentsOf: shared.appendingPathComponent("prompts/clip-finder.json"))
        let prompt = try ClipPromptDocument(data: promptData)
        let preset = try #require(prompt.presets.first { $0.id == .best })
        let builder = ClipRequestBuilder(prompt: prompt)
        let words = builder.clipWords(transcript)
        let windows = try builder.windows(words: words, preset: preset, contextTokens: 4_096, localServer: true)
        #expect(windows.count > 1)
        #expect(try builder.windows(words: words, preset: preset, contextTokens: 128_000, localServer: true).count == 1)
        let result = try runCLI(["find-clips", "--open", input.path, "--dry-run", "--json", "--preset", "best",
                                 "--connector", connector.rawValue, "--model", "unknown-local"], directory: directory)
        #expect(result.status == 0)
        let prompts = try #require(result.json["prompts"] as? [[String: String]])
        #expect(prompts.count == windows.count)
        for (index, pair) in zip(windows, prompts).enumerated() {
            let (window, rendered) = pair
            let request = builder.request(words: words, window: window, preset: preset, windowIndex: index,
                                          windowCount: windows.count, timeout: .seconds(120), language: transcript.language)
            #expect(rendered == ["system": request.system, "cachedBlock": request.cachedBlock ?? "", "instruction": request.instruction])
        }
        #expect(try Data(contentsOf: input) == original)
    }

    private func loadFixture() throws -> [String: Any] {
        let shared = try FixtureLoader.sharedRoot(environment: [:])
        let data = try Data(contentsOf: shared.appendingPathComponent("fixtures/cli/find-clips.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
