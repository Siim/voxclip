import Foundation
import Testing
import VoxClipCore

/// The CLI's launch check on shared/data/share-text.json, as the App's (doc/publishing.md §2.1): a missing or unreadable
/// file stops every command but help and version with exit 3 and `sharedResourcesMissing`.
@Test(.timeLimit(.minutes(1)))
func cliRequiresReadableShareTextRules() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = FileManager.default
    // A copy of the parts of shared/ the launch check reads, inside this run's own directory (beside VOXCLIP_DATA_DIR).
    let shared = directory.appendingPathComponent("shared", isDirectory: true)
    let source = try FixtureLoader.sharedRoot(environment: [:])
    try manager.createDirectory(at: shared, withIntermediateDirectories: true)
    for part in ["caption-styles", "data"] { try manager.copyItem(at: source.appendingPathComponent(part), to: shared.appendingPathComponent(part)) }
    let rules = shared.appendingPathComponent("data/share-text.json")
    let media = directory.appendingPathComponent("absent.mov").path
    // The intact copy passes the check, so probing a missing file fails on the file instead.
    let intact = try runCLI(["probe", media, "--json"], directory: directory, sharedRoot: shared)
    #expect(intact.status == 3)
    #expect((try intact.json["error"] as? [String: Any])?["code"] as? String == "mediaMissing")
    for broken in [nil, Data("{".utf8)] {
        try? manager.removeItem(at: rules)
        if let broken { try broken.write(to: rules) }
        let failed = try runCLI(["probe", media, "--json"], directory: directory, sharedRoot: shared)
        #expect(failed.status == 3)
        #expect((try failed.json["error"] as? [String: Any])?["code"] as? String == "sharedResourcesMissing")
        for informational in [["--help"], ["--version"], ["version"]] {
            #expect(try runCLI(informational, directory: directory, sharedRoot: shared).status == 0, "\(informational)")
        }
    }
}
