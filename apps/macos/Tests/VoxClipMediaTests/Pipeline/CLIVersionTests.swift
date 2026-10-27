import Foundation
import Testing
import VoxClipCore

struct CLIVersionTests {
    private func releaseVersion() throws -> String {
        let root = try FixtureLoader.sharedRoot().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("apps/macos/Sources/VoxClip/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(plist["CFBundleShortVersionString"] as? String)
    }

    @Test(.timeLimit(.minutes(1)))
    func binaryVersionFlagAndVersionCommandMatchPlist() throws {
        let expected = try releaseVersion()
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let flag = try runCLI(["--version"], directory: directory)
        #expect(flag.status == 0)
        #expect(String(decoding: flag.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        let command = try runCLI(["version"], directory: directory)
        #expect(command.status == 0)
        #expect(String(decoding: command.stdout, as: UTF8.self).hasPrefix("VoxClip \(expected) (macos-"))
    }

    @Test(.timeLimit(.minutes(1)))
    func successAndFailureJSONMatchPlist() throws {
        let expected = try releaseVersion()
        let shared = try FixtureLoader.sharedRoot()
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = shared.appendingPathComponent("fixtures/projects/interview-take.voxclip")
        let cases: [([String], Int32)] = [
            (["version", "--json"], 0),
            (["plan", "--open", project.path, "--json"], 0),
            (["find-clips", "--open", project.path, "--preset", "hooks", "--connector", "codex", "--dry-run", "--json"], 0),
            (["probe", directory.appendingPathComponent("missing.mov").path, "--json"], 3),
            (["probe", "--json"], 2)
        ]
        for (arguments, status) in cases {
            let result = try runCLI(arguments, directory: directory)
            #expect(result.status == status, "\(arguments): \(result.stderr)")
            let output = try result.json
            #expect(output["version"] as? String == expected, "\(arguments)")
            #expect(output["ok"] as? Bool == (status == 0))
        }
    }

}
