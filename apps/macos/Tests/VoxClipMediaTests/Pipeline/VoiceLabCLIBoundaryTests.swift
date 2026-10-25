import Foundation
import Testing
import VoxClipCore

@Test(.timeLimit(.minutes(1)))
func cliVoiceLabPlanRejectsActiveAndPreservesDisabledSource() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let shared = try FixtureLoader.sharedRoot(environment: [:])
    var project = try JSONProjectStore.decode(Data(contentsOf: shared.appendingPathComponent("fixtures/voice-lab/passage-project.voxclip")))
    let path = directory.appendingPathComponent("take.voxclip")
    try JSONProjectStore.encode(project).write(to: path)
    let blocked = try runCLI(["plan", "--open", path.path, "--json"], directory: directory)
    #expect(blocked.status == 5)
    let error = try #require(blocked.json["error"] as? [String: Any])
    #expect(error["code"] as? String == "exportFailed")
    #expect((error["message"] as? String)?.contains("generated voice segments") == true)
    project = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: project)
    try JSONProjectStore.encode(project).write(to: path)
    let source = try runCLI(["plan", "--open", path.path, "--json"], directory: directory)
    #expect(source.status == 0)
    #expect(try source.json["outputSamples"] as? Int == 7000)
}
