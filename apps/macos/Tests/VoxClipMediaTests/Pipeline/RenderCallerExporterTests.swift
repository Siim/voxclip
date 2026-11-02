import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite(.offlineFixtures) struct RenderCallerExporterTests {
    private func request(demo: Bool = false) throws -> RenderRequest {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        project.schemaVersion = 4
        project.voiceLab = ProjectVoiceLab(assets: [], cleanAudio: .init(mode: .off), voices: [], videoAssets: [])
        project.edits = ProjectEdits()
        let timeline = try RenderCallerInputs.timeline(project: project)
        guard case .legacy(let plan) = timeline else { throw ContextDemoError.invalidNarration }
        if demo {
            let asset = ContextDemoAsset(id: "capture", requestId: "request", target: .init(kind: .desktopApp,
                displayName: "Demo", locator: "org.voxclip.demo"),
                relativePath: try ContextDemoAsset.relativePath(projectId: project.id, assetId: "capture"),
                sha256: String(repeating: "a", count: 64), durationSeconds: 1, pixelWidth: 640, pixelHeight: 360,
                byteSize: 100, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            let document = try ContextDemoDocument(project: project, planId: "plan", timeline: timeline)
                .placing(asset: asset, placement: .init(id: "placement", assetId: "capture",
                    source: .init(start: 0, end: 0.5), editedStartSeconds: 0.5), expectedRevision: 0)
            project.contextDemo = document
        }
        return try RenderCallerInputs.prepare(RenderRequest(sourceURL: URL(fileURLWithPath: project.media.source.absolutePath), plan: plan,
            output: .init(size: .init(width: 640, height: 360), fps: 30, videoBitrate: 1_000_000)),
            project: project, clipID: nil, dataRoot: URL(fileURLWithPath: "/tmp/voxclip-render-exporter-data"))
    }

    @Test func sourceOnlyRouteRefusesDemoEvenWithCaptionsOff() throws {
        #expect(AVExporter.canUseSourceOnlyVideo(try request()))
        #expect(!AVExporter.canUseSourceOnlyVideo(try request(demo: true)))
    }

    @Test func activeClipMotionCannotUseSourceOnlyRouteAndFullTakeIsIdentity() throws {
        var request = try request()
        request.motionCues = [MotionCue(id: "motion", clipID: "scope", sourceStart: 0, sourceEnd: 1)]
        request.motionClipID = "scope"
        #expect(!AVExporter.canUseSourceOnlyVideo(request))
        request.motionClipID = nil
        #expect(AVExporter.canUseSourceOnlyVideo(request))
        request.motionClipID = "other"
        #expect(AVExporter.canUseSourceOnlyVideo(request))
    }

    @Test func missingDemoRootFailsBeforeOutputOrScratchPreparation() async throws {
        var render = try request(demo: true); render.contextDemoRoot = nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("video.mp4")
        let job = ExportJob(render: render, outputURL: destination)
        let exporter = AVExporter()
        await #expect(throws: ContextDemoCompositionError.unsafePath) {
            try await exporter.preflightCombinedExport(job, editedAudioURL: directory.appendingPathComponent("audio.wav"))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func exportCannotReplaceCanonicalDemoRecording() async throws {
        let render = try request(demo: true)
        let root = try #require(render.contextDemoRoot)
        let asset = try #require(render.contextDemo?.assets.first)
        let destination = root.appendingPathComponent(asset.relativePath)
        let exporter = AVExporter()
        await #expect(throws: (any Error).self) {
            try await exporter.preflightCombinedExport(ExportJob(render: render, outputURL: destination),
                editedAudioURL: root.appendingPathComponent("audio.wav"))
        }
    }
}
