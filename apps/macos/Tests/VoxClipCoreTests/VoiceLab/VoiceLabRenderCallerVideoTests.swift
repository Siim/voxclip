import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabRenderCallerVideoTests {
    private func video(output: Int64 = 800) -> VoiceLabVideoRecipe {
        VoiceLabVideoRecipe(mode: .zoomCover, sourceStartSample: 2_500, sourceEndSample: 3_200,
            outputSamples: output, retimeFactor: 700 / Double(output), zoom: 1.12, faceX: 0.5, faceY: 0.5,
            assetId: nil, provider: nil, model: nil, requestId: nil, windowStartSample: nil, windowEndSample: nil, syncMode: nil)
    }

    @Test(arguments: [560, 800, 875])
    func onlyBoundedSourceVideoRetimeIsSupported(output: Int) {
        #expect(VoiceLabRenderInput.supportsVideoMode(.source) && VoiceLabRenderInput.supportsVideoMode(.zoomCover))
        #expect(!VoiceLabRenderInput.supportsVideoMode(.retimed) && !VoiceLabRenderInput.supportsVideoMode(.lipsync))
        #expect(VoiceLabRenderInput.supportsVideoRecipe(video(output: Int64(output))))
    }

    @Test func invalidZoomCoverPoliciesCannotEnterNativeRequest() {
        var changed = video(); changed.zoom = 1.13
        var factor = video(); factor.retimeFactor = 800 / 700
        let outside = video(output: 876)
        var external = video(); external.assetId = "external"
        var face = video(); face.faceX = .nan
        var legacy = video(); legacy.mode = .retimed
        var lipsync = video(); lipsync.mode = .lipsync
        for invalid in [changed, factor, outside, external, face, legacy, lipsync] {
            #expect(!VoiceLabRenderInput.supportsVideoRecipe(invalid))
        }
    }

    @Test func preparedZoomCoverBindsRealRecipeAndPreservesUnityAudio() throws {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        var segment = project.voiceLab.segments[0]
        var recipe = try #require(segment.candidates[0].recipe)
        recipe.audio.stretch = 1
        recipe.outDuration = 0.8
        recipe.audio.trimEnd = recipe.audio.trimStart + 0.8
        recipe.chunks[0].assembledEndFrame = Int64(EditingPrimitives.jsRound(recipe.audio.trimEnd * 24_000))
        var words = try #require(recipe.words)
        words[1].end = 0.6
        recipe.words = words
        recipe.video = video()
        segment.candidates = [segment.candidates[0]]
        segment.candidates[0].recipe = recipe
        segment.audio = recipe.audio; segment.outDuration = recipe.outDuration; segment.words = recipe.words
        project.voiceLab.segments = [segment]
        project.voiceLab.assets?[0].durationSeconds = 1.5
        let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        let input = try VoiceLabRenderInput(project: project, scope: .full, labelPosition: .topRight,
            paidRoot: URL(fileURLWithPath: "/tmp/unused-paid-root"), prepared: prepared)
        #expect(input.prepared.outputPlan.outputSamples == 7_100)
        #expect(input.prepared.selectedSegmentRecipes.first?.recipe.video == video())
        #expect(input.prepared.selectedSegmentRecipes.first?.recipe.audio.stretch == 1)
        var stale = project; stale.media.source.contentKey = String(repeating: "b", count: 64)
        #expect(throws: VoiceLabProjectError.staleRenderContract) {
            try VoiceLabRenderInput(project: stale, scope: .full, labelPosition: .topRight,
                paidRoot: URL(fileURLWithPath: "/tmp/unused-paid-root"), prepared: prepared)
        }
        project.schemaVersion = 4
        let full = try RenderCallerInputs.timeline(project: project)
        let asset = ContextDemoAsset(id: "capture", requestId: "request", target: .init(kind: .desktopApp,
            displayName: "Demo", locator: "org.voxclip.demo"),
            relativePath: try ContextDemoAsset.relativePath(projectId: project.id, assetId: "capture"),
            sha256: String(repeating: "a", count: 64), durationSeconds: 1, pixelWidth: 640, pixelHeight: 360,
            byteSize: 100, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        project.contextDemo = try ContextDemoDocument(project: project, planId: "plan", timeline: full)
            .placing(asset: asset, placement: .init(id: "placement", assetId: "capture",
                source: .init(start: 0, end: 0.4), editedStartSeconds: 2.6), expectedRevision: 0)
        let selected = try VoiceLabRenderContract.prepare(project, scope: .clip("clip-main"), labelPosition: .topRight)
        let voice = try VoiceLabRenderInput(project: project, scope: .clip("clip-main"), labelPosition: .topRight,
            paidRoot: URL(fileURLWithPath: "/tmp/unused-paid-root"), prepared: selected)
        let transcript = try #require(project.transcript)
        let state = EditState(transcript: transcript,
            pauses: try detectPauses(transcript.words, thresholdSeconds: project.edits.pauseThresholdSeconds),
            pauseThresholdSeconds: project.edits.pauseThresholdSeconds, pauseKeepSeconds: project.edits.pauseKeepSeconds,
            clips: project.edits.clips)
        let plan = try EditPlan.build(transcript: transcript, editState: state, activeClip: project.edits.clips.first,
            duration: 7, sampleRate: 1_000)
        let request = try RenderCallerInputs.prepare(RenderRequest(sourceURL: URL(fileURLWithPath: project.media.source.absolutePath),
            plan: plan, output: .init(size: .init(width: 640, height: 360), fps: 30, videoBitrate: 1_000_000), voiceLab: voice),
            project: project, clipID: "clip-main", dataRoot: URL(fileURLWithPath: "/tmp/unused-data-root"))
        let demo = try #require(request.contextDemo)
        let mapping = try #require(demo.placements.first?.narrationMappings.first)
        #expect(demo.scope.start > 0 && request.timeline.outputSamples == selected.outputPlan.outputSamples)
        #expect(abs((mapping.source.end - mapping.source.start) / (mapping.output.end - mapping.output.start) - 0.875) < 1e-9)
        try demo.verifyRenderedTimeline(request.timeline)
    }
}
