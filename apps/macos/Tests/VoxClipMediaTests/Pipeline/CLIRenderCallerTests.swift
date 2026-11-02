import Foundation
import Testing
import VoxClipCore
@testable import voxclip_cli

@Suite struct CLIRenderCallerTests {
    private func project() throws -> Project {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        project.schemaVersion = 4
        project.voiceLab = ProjectVoiceLab(assets: [], cleanAudio: .init(mode: .off), voices: [], videoAssets: [])
        project.edits = ProjectEdits(clips: [ClipRange(id: "scope", startWordId: "w4", endWordId: "w5", origin: .ai)], activeClipId: "scope")
        project.motionCues = [MotionCue(id: "motion", clipID: "scope", sourceStart: 2.5, sourceEnd: 3.2)]
        let full = try RenderCallerInputs.timeline(project: project)
        let scoped = try RenderCallerInputs.timeline(project: project, clipID: "scope")
        let start = full.mapTime(scoped.sourceTime(0))
        let asset = ContextDemoAsset(id: "capture", requestId: "request", target: .init(kind: .desktopApp,
            displayName: "Demo", locator: "org.voxclip.demo"),
            relativePath: try ContextDemoAsset.relativePath(projectId: project.id, assetId: "capture"),
            sha256: String(repeating: "a", count: 64), durationSeconds: 1, pixelWidth: 640, pixelHeight: 360,
            byteSize: 100, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        project.contextDemo = try ContextDemoDocument(project: project, planId: "plan", timeline: full)
            .placing(asset: asset, placement: .init(id: "placement", assetId: "capture",
                source: .init(start: 0.2, end: 0.5), editedStartSeconds: start), expectedRevision: 0)
        return project
    }

    private func request(_ project: Project) throws -> RenderRequest {
        guard case .legacy(let plan) = try RenderCallerInputs.timeline(project: project, clipID: project.edits.activeClipId) else {
            throw ContextDemoError.invalidNarration
        }
        return try CLIWorkflow.renderRequest(project: project, source: URL(fileURLWithPath: project.media.source.absolutePath),
            plan: plan, style: nil, output: .init(size: .init(width: 640, height: 360), fps: 30, videoBitrate: 1_000_000),
            voiceLab: nil, dataRoot: URL(fileURLWithPath: "/tmp/voxclip-cli-render-data"))
    }

    @Test func cliSuggestedClipGetsScopedDemoSourceBindingAndAuthoredMotion() throws {
        let project = try project()
        let request = try request(project)
        #expect(request.contextDemo?.placements.first?.output.start == 0)
        #expect(abs((request.contextDemo?.placements.first?.output.end ?? 0) - 0.3) < 1e-9)
        #expect((request.contextDemo?.scope.start ?? 0) > 0)
        #expect(request.contextDemoRoot == URL(fileURLWithPath: "/tmp/voxclip-cli-render-data").resolvingSymlinksInPath())
        #expect(request.sourceContentKey == project.media.source.contentKey)
        #expect(request.motionClipID == "scope" && request.motionCues == project.motionCues)
        #expect(!request.forPreview && !request.reduceMotion)
        try #require(request.contextDemo).verifyRenderedTimeline(request.timeline)
    }

    @Test func cliFullEditDoesNotBorrowActiveClipMotionOrRebaseFullDemo() throws {
        var project = try project(); project.edits.activeClipId = nil
        let request = try request(project)
        #expect(request.contextDemo?.scope.start == 0 && request.contextDemo?.placements.count == 1)
        #expect(request.motionClipID == nil && request.motionCues.isEmpty)
    }

    @Test func staleNarrationOrSourceNeverSilentlyDropsDemoInCli() throws {
        let initial = try project()
        var sourceChanged = initial; sourceChanged.media.source.contentKey = String(repeating: "b", count: 64)
        var cutsChanged = initial; cutsChanged.edits.cutWordIds.append("w1")
        for changed in [sourceChanged, cutsChanged] {
            #expect(throws: (any Error).self) { try request(changed) }
        }
    }
}
