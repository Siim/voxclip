import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct ContextDemoPersistenceTests {
    private func project(_ path: String = "fixtures/projects/interview-take.voxclip") throws -> Project {
        try JSONProjectStore.decode(FixtureLoader.data(path))
    }

    private func timeline() -> RenderTimeline {
        .legacy(EditPlan(sampleRate: 48_000, totalSamples: 336_000,
                         kept: [MediaInterval(startSample: 0, endSample: 336_000)]))
    }

    @Test(arguments: ["fixtures/projects/interview-take.voxclip", "fixtures/voice-lab/passage-project.voxclip", "fixtures/voice-lab/passage-render-v3.voxclip"])
    func legacyProjectWireOmitsFeaturesWithoutImplicitUpgrade(path: String) throws {
        let original = try project(path)
        let encoded = try JSONProjectStore.encode(original)
        let reopened = try JSONProjectStore.decode(encoded)
        let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(raw["contextDemo"] == nil && raw["motionCues"] == nil)
        #expect(reopened.schemaVersion == original.schemaVersion)
        #expect(reopened.transcript == original.transcript && reopened.voiceLab == original.voiceLab)
        #expect(reopened.contextDemo == nil && reopened.motionCues.isEmpty)
    }

    @Test func explicitAttachUpgradesToV4AndPreservesNarrationWordsAndExtensions() throws {
        var original = try project()
        original.extensions = ["org.example.test": .object(["keep": .bool(true)])]
        let document = try ContextDemoDocument(project: original, planId: "demo-plan", timeline: timeline())
        let changed = try ContextDemoProject.setting(document, in: original, timeline: timeline())
        #expect(original.schemaVersion == 1 && original.contextDemo == nil)
        #expect(changed.schemaVersion == 4 && changed.contextDemo == document)
        #expect(changed.transcript == original.transcript && changed.edits == original.edits && changed.extensions == original.extensions)
        #expect(changed.voiceLab == (try VoiceLabProject.upgradeToV3(original)).voiceLab)
        let reopened = try JSONProjectStore.decode(JSONProjectStore.encode(changed))
        #expect(reopened.schemaVersion == 4 && reopened.contextDemo == document)
        #expect(reopened.transcript == original.transcript)
    }

    @Test func featureUnderLegacyVersionAndUnknownFutureVersionFailHonestly() throws {
        let original = try project()
        let document = try ContextDemoDocument(project: original, planId: "demo-plan", timeline: timeline())
        var old = original
        old.contextDemo = document
        #expect(throws: ContextDemoError.unsupportedVersion) { try ProjectJSON.encoder().encode(old) }
        let changed = try ContextDemoProject.setting(document, in: original, timeline: timeline())
        var raw = try #require(JSONSerialization.jsonObject(with: ProjectJSON.encode(changed)) as? [String: Any])
        raw["schemaVersion"] = 3
        #expect(throws: (any Error).self) { try ProjectJSON.decode(JSONSerialization.data(withJSONObject: raw)) }
        raw["schemaVersion"] = 5
        #expect(throws: (any Error).self) { try JSONProjectStore.decode(JSONSerialization.data(withJSONObject: raw)) }
    }

    @Test func realAssetMetadataAndTrimSurviveProjectSaveReopenWithoutWordTimingChanges() throws {
        let original = try project()
        let target = ContextDemoTarget(kind: .desktopApp, displayName: "Example app", locator: "org.example.App")
        let asset = ContextDemoAsset(id: "demo-asset", requestId: "capture", target: target,
            relativePath: try ContextDemoAsset.relativePath(projectId: original.id, assetId: "demo-asset"),
            sha256: String(repeating: "b", count: 64), durationSeconds: 2, pixelWidth: 1280, pixelHeight: 720,
            byteSize: 4096, createdAt: original.createdAt)
        let placement = ContextDemoPlacement(id: "overlay", assetId: asset.id, source: TimeRange(start: 0.25, end: 1.75), editedStartSeconds: 1)
        let document = try ContextDemoDocument(project: original, planId: "plan", timeline: timeline())
            .placing(asset: asset, placement: placement, expectedRevision: 0)
        let attached = try ContextDemoProject.setting(document, in: original, timeline: timeline())
        let reopened = try JSONProjectStore.decode(JSONProjectStore.encode(attached))
        #expect(reopened.contextDemo?.assets == [asset])
        #expect(reopened.contextDemo?.placements == [placement])
        #expect(reopened.contextDemo?.sourceContentKey == original.media.source.contentKey)
        #expect(reopened.transcript == original.transcript && reopened.edits == original.edits)
        #expect(reopened.contextDemo?.isCurrent(project: reopened, timeline: timeline()) == true)
    }

    @Test func sourceRelinkWithChangedIdentityCannotReusePlanButCanRemoveIt() throws {
        let original = try project()
        let document = try ContextDemoDocument(project: original, planId: "demo-plan", timeline: timeline())
        var attached = try ContextDemoProject.setting(document, in: original, timeline: timeline())
        attached.media.source.contentKey = String(repeating: "f", count: 64)
        #expect(!document.isCurrent(project: attached, timeline: timeline()))
        #expect(throws: ContextDemoError.staleNarration) {
            try ContextDemoPlanner.prepare(document: document, project: attached, timeline: timeline())
        }
        let cleared = try ContextDemoProject.setting(nil, in: attached, timeline: timeline())
        #expect(cleared.contextDemo == nil && cleared.schemaVersion == 4)
    }

    @Test func voiceLabUpgradeDoesNotDowngradeV4OrDiscardFeatures() throws {
        let original = try project("fixtures/voice-lab/passage-render-v3.voxclip")
        let upgraded = try ContextDemoProject.upgradeToV4(original)
        #expect(upgraded.schemaVersion == 4 && upgraded.voiceLab == original.voiceLab)
        #expect(try VoiceLabProject.upgradeToV3(upgraded) == upgraded)
        var future = upgraded
        future.schemaVersion = 5
        #expect(throws: (any Error).self) { try VoiceLabProject.upgradeToV3(future) }
    }

    @Test func legacyV2SegmentNeedsReviewInsteadOfDestructivePromotion() throws {
        let original = try project("fixtures/voice-lab/passage-project.voxclip")
        #expect(throws: VoiceLabProjectError.legacySegmentsNeedReview) { try ContextDemoProject.upgradeToV4(original) }
        #expect(original.schemaVersion == 2 && !original.voiceLab.segments.isEmpty)
    }
}
