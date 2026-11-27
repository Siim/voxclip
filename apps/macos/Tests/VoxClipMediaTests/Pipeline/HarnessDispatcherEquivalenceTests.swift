import Foundation
import Testing
import VoxClipCore
import VoxClipMedia
@testable import voxclip_cli

@Test func savedHarnessAndLiveDispatcherReturnTheSameJSON() async throws {
    let shared = SharedResources(root: try FixtureLoader.sharedRoot())
    let vector = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/agent-chat/tool-cases.json")))
    let fixture = shared.root.appendingPathComponent(try #require(vector[ai: "project"].aiString))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fixture.voxclip")
    let bytes = try Data(contentsOf: fixture)
    var project = try JSONProjectStore.decode(bytes)
    let clipSource = shared.root.appendingPathComponent("fixtures/media/counter-1080p.mp4")
    project.media.source.absolutePath = clipSource.path
    project.media.source.sizeBytes = try #require(try clipSource.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    project.media.source.contentKey = try JSONProjectStore.contentKey(for: clipSource)
    try await JSONProjectStore().save(project, to: path)
    let saved = try HarnessProject(path: path.path)
    var calls = try #require(vector[ai: "savedCalls"].aiObject)
    calls["read_frames"] = .object(["times": .array([.number(0.2)])])
    for (name, arguments) in calls.sorted(by: { $0.key < $1.key }) {
        let tool = try #require(HarnessTool(rawValue: name))
        let live = try await HarnessTools.call(tool, arguments: arguments, project: project, shared: shared,
                                               projectURL: path, decodeFrames: HarnessFrameDecoder.decode)
        let cli = try await saved.call(tool, arguments: arguments)
        #expect(try comparable(cli.fields) == comparable(live.fields))
        #expect(cli.images.map(\.jpeg) == live.images.map(\.jpeg))
        if tool == .proposeTimeline { #expect(FileManager.default.fileExists(atPath: path.path + ".proposal.json")) }
    }
}

private func comparable(_ fields: [String: JSONValue]) throws -> JSONValue {
    var fields = fields
    if var proposal = fields["proposal"]?.aiObject {
        _ = try #require(proposal.removeValue(forKey: "id")?.aiString.flatMap(UUID.init(uuidString:)))
        fields["proposal"] = .object(proposal)
    }
    return .object(fields)
}
