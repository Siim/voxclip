import Foundation
import Testing
@testable import VoxClipCore

@Suite struct RenderCallerInputsTests {
    private let root = URL(fileURLWithPath: "/tmp/voxclip-render-caller-data", isDirectory: true)

    private func project() throws -> Project {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        project.schemaVersion = 4
        project.voiceLab = ProjectVoiceLab(assets: [], cleanAudio: .init(mode: .off), voices: [], videoAssets: [])
        project.edits = ProjectEdits(cutWordIds: ["w2"], clips: [ClipRange(id: "scope", startWordId: "w4", endWordId: "w5")])
        project.captions.styleId = "off"
        return project
    }

    private func request(_ project: Project, clipID: String? = nil, preview: Bool = false) throws -> RenderRequest {
        guard case .legacy(let plan) = try RenderCallerInputs.timeline(project: project, clipID: clipID) else {
            throw ContextDemoError.invalidNarration
        }
        return RenderRequest(sourceURL: URL(fileURLWithPath: project.media.source.absolutePath), plan: plan,
            output: OutputSpec(size: PixelSize(width: 1920, height: 1080), fps: 30, videoBitrate: 4_000_000), forPreview: preview)
    }

    private func demo(_ project: Project, start: Double, duration: Double = 0.3) throws -> Project {
        let asset = ContextDemoAsset(id: "capture", requestId: "request", target: .init(kind: .desktopApp,
            displayName: "Demo", locator: "org.voxclip.demo"),
            relativePath: try ContextDemoAsset.relativePath(projectId: project.id, assetId: "capture"),
            sha256: String(repeating: "a", count: 64), durationSeconds: 2, pixelWidth: 640, pixelHeight: 360,
            byteSize: 100, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let document = try ContextDemoDocument(project: project, planId: "plan", timeline: RenderCallerInputs.timeline(project: project))
            .placing(asset: asset, placement: .init(id: "placement", assetId: asset.id,
                source: .init(start: 0.2, end: 0.2 + duration), editedStartSeconds: start), expectedRevision: 0)
        return try ContextDemoProject.setting(document, in: project, timeline: RenderCallerInputs.timeline(project: project))
    }

    @Test func fullNarrationBindingIsClippedAndZeroRebasedWithoutChangingWords() throws {
        let initial = try project()
        let full = try RenderCallerInputs.timeline(project: initial)
        let clipped = try RenderCallerInputs.timeline(project: initial, clipID: "scope")
        let start = full.mapTime(clipped.sourceTime(0))
        let project = try demo(initial, start: start - 0.1)
        let clip = try RenderCallerInputs.prepare(request(project, clipID: "scope"), project: project,
            clipID: "scope", dataRoot: root)
        let input = try #require(clip.contextDemo)
        let placement = try #require(input.placements.first)
        #expect(abs(input.scope.start - start) < 1e-9)
        #expect(abs(placement.output.start) < 1e-9 && abs(placement.output.end - 0.2) < 1e-9)
        #expect(abs(placement.source.start - 0.3) < 1e-9 && abs(placement.source.end - 0.5) < 1e-9)
        #expect(input.narration == project.contextDemo?.narration && input.preservesNarration && input.captureAudioGain == 0)
        #expect(clip.contextDemoRoot == root.standardizedFileURL.resolvingSymlinksInPath())
        #expect(clip.sourceContentKey == project.media.source.contentKey && project.transcript == initial.transcript)
        try input.verifyRenderedTimeline(clip.timeline)
        let fullRequest = try RenderCallerInputs.prepare(request(project), project: project, clipID: nil, dataRoot: root)
        let fullInput = try #require(fullRequest.contextDemo)
        let fullPlacement = try #require(fullInput.placements.first)
        #expect(fullInput.scope.start == 0 && abs(fullPlacement.source.start - 0.2) < 1e-9)
    }

    @Test func projectSourceAndFullTimelineMustAllRemainCurrent() throws {
        let original = try demo(project(), start: 0.5)
        var sourceChanged = original
        sourceChanged.media.source.contentKey = String(repeating: "b", count: 64)
        var idChanged = original
        idChanged.id = UUID().uuidString.lowercased()
        var cutChanged = original
        cutChanged.edits.cutWordIds.append("w1")
        for changed in [sourceChanged, idChanged, cutChanged] {
            #expect(throws: (any Error).self) {
                try RenderCallerInputs.prepare(request(changed), project: changed, clipID: nil, dataRoot: root)
            }
        }
        #expect(throws: ContextDemoError.staleNarration) {
            try RenderCallerInputs.prepare(request(original), project: original, clipID: "scope", dataRoot: root)
        }
        #expect(throws: VoiceLabProjectError.invalidScope) {
            try RenderCallerInputs.prepare(request(original), project: original, clipID: "missing", dataRoot: root)
        }
    }

    @Test func cancellationAndNonFileRootsFailBeforePreparation() throws {
        let project = try demo(project(), start: 0.5)
        #expect(throws: CancellationError.self) {
            try RenderCallerInputs.prepare(request(project), project: project, clipID: nil, dataRoot: root, isCancelled: { true })
        }
        #expect(throws: ContextDemoError.unsafePath) {
            try RenderCallerInputs.prepare(request(project), project: project, clipID: nil,
                dataRoot: #require(URL(string: "https://example.test/data")))
        }
    }

    @Test func onlyActiveClipMotionIsPassedAndReduceMotionNeverChangesExport() throws {
        var project = try project()
        project.edits.clips.append(ClipRange(id: "other", startWordId: "w1", endWordId: "w3"))
        project.motionCues = [MotionCue(id: "active", clipID: "scope", sourceStart: 2.5, sourceEnd: 3.2),
                             MotionCue(id: "other", clipID: "other", sourceStart: 0.3, sourceEnd: 1)]
        let preview = try RenderCallerInputs.prepare(request(project, clipID: "scope", preview: true), project: project,
            clipID: "scope", dataRoot: root, reduceMotion: true)
        #expect(preview.motionClipID == "scope" && preview.motionCues.map(\.id) == ["active"] && preview.reduceMotion)
        let exported = try RenderCallerInputs.prepare(request(project, clipID: "scope"), project: project,
            clipID: "scope", dataRoot: root, reduceMotion: true)
        #expect(!exported.reduceMotion && exported.motionCues == preview.motionCues)
        let full = try RenderCallerInputs.prepare(request(project), project: project, clipID: nil, dataRoot: root)
        #expect(full.motionClipID == nil && full.motionCues.isEmpty)
    }

    @Test(arguments: [1, 2, 3])
    func legacyRequestsDoNotUpgradeProjectShape(version: Int) throws {
        var project = try project()
        project.schemaVersion = version
        if version == 1 { project.voiceLab = ProjectVoiceLab() }
        if version == 2 { project.voiceLab = ProjectVoiceLab(assets: []) }
        let rendered = try RenderCallerInputs.prepare(request(project), project: project, clipID: nil, dataRoot: root)
        #expect(rendered.contextDemo == nil && rendered.contextDemoRoot == nil && rendered.motionCues.isEmpty)
        #expect(project.schemaVersion == version)
    }
}
