import Foundation
import Testing
import VoxClipCore
import VoxClipMedia
@testable import voxclip_cli

/// `voxclip-cli transcribe` builds its project with `CLIWorkflow.imported`; a project id must be a lowercase UUID, or the
/// save that ends every transcribe fails with "Invalid project text".
@Test("CLI-imported projects have a lowercase id and save", .timeLimit(.minutes(1)))
func cliImportedProjectSaves() async throws {
    let source = try FixtureLoader.sharedRoot().appendingPathComponent("fixtures/media/bars-1080p.mp4")
    let project = try CLIWorkflow.imported(source, probe: try await AVMediaProbe().probe(source), transcript: nil)
    #expect(project.id == project.id.lowercased())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-cli-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("bars.voxclip")
    try await JSONProjectStore().save(project, to: destination)
    #expect(try await JSONProjectStore().load(from: destination).id == project.id)
}
