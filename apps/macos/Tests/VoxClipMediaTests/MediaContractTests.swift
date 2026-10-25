import Foundation
import Testing
import VoxClipCore
import VoxClipMedia

@Test func mediaFixtureLoaderUsesRepositorySharedDirectory() throws {
    let root = try FixtureLoader.sharedRoot(environment: [:])
    #expect(root.lastPathComponent == "shared")
}

@Test func unfinishedMediaProbeFailsWithoutOpeningInput() async {
    let probe: any MediaProbe = AVMediaProbe()
    await #expect(throws: VoxClipError.mediaMissing("no-video.mov")) {
        _ = try await probe.probe(URL(fileURLWithPath: "/tmp/no-video.mov"))
    }
}

@Test @MainActor func emptyPreviewStartsStoppedAndClosesSafely() {
    let preview: any PreviewEngine = PreviewPlayerController()
    #expect(!preview.isPlaying)
    preview.play()
    #expect(!preview.isPlaying)
    preview.pause()
    preview.close()
    #expect(preview.editedTime == 0)
}
