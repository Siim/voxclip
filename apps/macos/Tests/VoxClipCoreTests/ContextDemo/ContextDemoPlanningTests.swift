import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct ContextDemoPlanningTests {
    private let projectID = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11"
    private let sourceKey = String(repeating: "a", count: 64)

    private func timeline(_ intervals: [(Int64, Int64)] = [(0, 96_000), (192_000, 336_000)]) -> RenderTimeline {
        .legacy(EditPlan(sampleRate: 48_000, totalSamples: 336_000,
                         kept: intervals.map { MediaInterval(startSample: $0.0, endSample: $0.1) }))
    }

    private func target() -> ContextDemoTarget {
        ContextDemoTarget(kind: .desktopApp, displayName: "Example app", locator: "org.example.App")
    }

    private func asset(id: String = "demo-1", duration: Double = 6, path: String? = nil,
                       width: Int = 1280, size: Int64 = 1024) throws -> ContextDemoAsset {
        ContextDemoAsset(id: id, requestId: "capture-1", target: target(),
            relativePath: try path ?? ContextDemoAsset.relativePath(projectId: projectID, assetId: id),
            sha256: String(repeating: "b", count: 64), durationSeconds: duration,
            pixelWidth: width, pixelHeight: 720, byteSize: size, createdAt: Date(timeIntervalSince1970: 1_793_577_600))
    }

    private func document(placements: [ContextDemoPlacement]? = nil, assets: [ContextDemoAsset]? = nil,
                          revision: Int = 0) throws -> ContextDemoDocument {
        ContextDemoDocument(projectId: projectID, planId: "plan-1", revision: revision,
            narration: try ContextDemoNarrationSnapshot(timeline: timeline()), assets: try assets ?? [asset()],
            placements: placements ?? [ContextDemoPlacement(id: "placement-1", assetId: "demo-1",
                source: TimeRange(start: 0.5, end: 3.5), editedStartSeconds: 1)], sourceContentKey: sourceKey)
    }

    @Test func cutMappingPreservesNarrationAndCaptureTrim() throws {
        let document = try document()
        let input = try ContextDemoPlanner.prepare(document: document, projectId: projectID, timeline: timeline())
        let placement = try #require(input.placements.first)
        #expect(input.preservesNarration && input.captureAudioGain == 0)
        #expect(input.scope == TimeRange(start: 0, end: 5))
        #expect(placement.source == TimeRange(start: 0.5, end: 3.5))
        #expect(placement.output == TimeRange(start: 1, end: 4))
        #expect(placement.narrationMappings.map(\.source) == [TimeRange(start: 1, end: 2), TimeRange(start: 4, end: 6)])
        #expect(placement.narrationMappings.map(\.output) == [TimeRange(start: 1, end: 2), TimeRange(start: 2, end: 4)])
        try input.verifyRenderedTimeline(timeline())
        #expect(document.revision == 0)
    }

    @Test func clippedScopeRebasesOutputAndAdvancesCaptureTrim() throws {
        let document = try document()
        let input = try ContextDemoPlanner.prepare(document: document, projectId: projectID, timeline: timeline(),
            scope: TimeRange(start: 1.5, end: 3.5))
        let placement = try #require(input.placements.first)
        #expect(placement.source == TimeRange(start: 1, end: 3))
        #expect(placement.output == TimeRange(start: 0, end: 2))
        #expect(placement.narrationMappings.map(\.source) == [TimeRange(start: 1.5, end: 2), TimeRange(start: 4, end: 5.5)])
        try input.verifyRenderedTimeline(timeline([(72_000, 96_000), (192_000, 264_000)]))
        #expect(throws: ContextDemoError.staleNarration) {
            try input.verifyRenderedTimeline(timeline([(0, 96_000)]))
        }
    }

    @Test func voiceLabSyntheticMappingRetainsSourceScaleWithoutReplacingNarration() throws {
        let synthetic = VoiceLabOutputPiece(kind: .synth, sourceStartSample: 48_000, sourceEndSample: 144_000,
            outputStartSample: 0, outputEndSample: 48_000, segmentId: "synth", assetId: "speech", audio: nil)
        let voice = RenderTimeline.voiceLab(VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: 336_000,
            pieces: [synthetic], captions: [], scope: .full))
        let placement = ContextDemoPlacement(id: "placement", assetId: "demo-1", source: TimeRange(start: 0, end: 1), editedStartSeconds: 0)
        let document = ContextDemoDocument(projectId: projectID, planId: "plan-1",
            narration: try ContextDemoNarrationSnapshot(timeline: voice), assets: try [asset()],
            placements: [placement], sourceContentKey: sourceKey)
        let input = try ContextDemoPlanner.prepare(document: document, projectId: projectID, timeline: voice)
        #expect(input.narration.pieces.first?.synthetic == true)
        #expect(input.placements.first?.narrationMappings.first?.source == TimeRange(start: 1, end: 3))
        #expect(input.captureAudioGain == 0 && input.preservesNarration)
        try input.verifyRenderedTimeline(voice)
    }

    @Test func sameDurationDifferentSourceCutsAreStale() throws {
        let document = try document()
        let changed = timeline([(0, 48_000), (144_000, 336_000)])
        #expect(changed.duration == timeline().duration)
        #expect(!document.isCurrent(projectId: projectID, timeline: changed))
        #expect(throws: ContextDemoError.staleNarration) {
            try ContextDemoPlanner.prepare(document: document, projectId: projectID, timeline: changed)
        }
    }

    @Test func adjacentHalfOpenPlacementsAreValidButOverlapIsNot() throws {
        let first = ContextDemoPlacement(id: "first", assetId: "demo-1", source: TimeRange(start: 0, end: 1), editedStartSeconds: 0)
        let touching = ContextDemoPlacement(id: "second", assetId: "demo-1", source: TimeRange(start: 1, end: 2), editedStartSeconds: 1)
        try document(placements: [first, touching]).validate()
        let overlap = ContextDemoPlacement(id: "second", assetId: "demo-1", source: touching.source, editedStartSeconds: 0.5)
        #expect(throws: ContextDemoError.overlappingPlacements) { try document(placements: [first, overlap]).validate() }
        #expect(throws: ContextDemoError.overlappingPlacements) { try document(placements: [touching, first]).validate() }
    }

    @Test func mutationIsImmutableOrderedAndRevisionChecked() throws {
        let original = try document(placements: [])
        let later = ContextDemoPlacement(id: "later", assetId: "demo-1", source: TimeRange(start: 0, end: 1), editedStartSeconds: 3)
        let first = ContextDemoPlacement(id: "first", assetId: "demo-1", source: TimeRange(start: 0, end: 1), editedStartSeconds: 0)
        let second = try original.replacingPlacement(later, expectedRevision: 0)
            .replacingPlacement(first, expectedRevision: 1)
        #expect(original.placements.isEmpty && original.revision == 0)
        #expect(second.placements.map(\.id) == ["first", "later"] && second.revision == 2)
        #expect(throws: ContextDemoError.staleRevision) { try second.removingPlacement(id: "first", expectedRevision: 1) }
        #expect(try second.removingPlacement(id: "first", expectedRevision: 2).placements.map(\.id) == ["later"])
    }

    @Test func trimReplaceAndRemovePreserveUnchangedPlacementIdentity() throws {
        let original = try document()
        let trim = ContextDemoPlacement(id: "placement-1", assetId: "demo-1", source: TimeRange(start: 1, end: 2), editedStartSeconds: 2)
        let trimmed = try original.replacingPlacement(trim, expectedRevision: 0)
        let replaced = try trimmed.replacingAsset(id: "demo-1", with: asset(duration: 2), expectedRevision: 1)
        #expect(replaced.placements == [trim] && replaced.revision == 2)
        #expect(throws: ContextDemoError.invalidPlacement) {
            try replaced.replacingAsset(id: "demo-1", with: asset(duration: 1), expectedRevision: 2)
        }
        #expect(try replaced.removingPlacement(id: "placement-1", expectedRevision: 2).placements.isEmpty)
        #expect(original.placements.first?.source == TimeRange(start: 0.5, end: 3.5))
    }

    @Test func assetAndPlacementCanCommitAtomicallyInOneRevision() throws {
        let original = try document(placements: [], assets: [])
        let placement = ContextDemoPlacement(id: "new", assetId: "demo-1", source: TimeRange(start: 0, end: 1), editedStartSeconds: 0)
        let placed = try original.placing(asset: asset(), placement: placement, expectedRevision: 0)
        #expect(placed.revision == 1 && placed.assets.count == 1 && placed.placements == [placement])
        #expect(original.assets.isEmpty && original.placements.isEmpty)
    }

    @Test func cancellationAndRevisionMismatchDoNotReturnPreparedAssets() throws {
        let document = try document()
        #expect(throws: ContextDemoError.cancelled) {
            try ContextDemoPlanner.prepare(document: document, projectId: projectID, timeline: timeline(), isCancelled: { true })
        }
        #expect(throws: ContextDemoError.staleRevision) {
            try ContextDemoPlanner.prepare(document: document, projectId: projectID, timeline: timeline(), expectedRevision: 1)
        }
    }

    @Test func unknownAssetsDuplicatesAndNonSampleAlignedTrimFail() throws {
        let missing = ContextDemoPlacement(id: "missing", assetId: "absent", source: TimeRange(start: 0, end: 1), editedStartSeconds: 0)
        #expect(throws: ContextDemoError.missingAsset) { try document(placements: [missing]).validate() }
        #expect(throws: ContextDemoError.duplicateIdentity) { try document(assets: [asset(), asset()]).validate() }
        let offGrid = ContextDemoPlacement(id: "off-grid", assetId: "demo-1", source: TimeRange(start: 0, end: 1),
                                           editedStartSeconds: 1 / 96_000)
        #expect(throws: ContextDemoError.invalidPlacement) { try document(placements: [offGrid]).validate() }
        let subSample = ContextDemoPlacement(id: "sub-sample", assetId: "demo-1", source: TimeRange(start: 0, end: 1e-12),
                                             editedStartSeconds: 0)
        #expect(throws: ContextDemoError.invalidPlacement) { try document(placements: [subSample]).validate() }
    }

    @Test func localAssetContractRefusesTraversalWrongContainerOddPixelsAndOversize() throws {
        #expect(throws: ContextDemoError.unsafePath) { try document(assets: [asset(path: "../private.mp4")]).validate() }
        #expect(throws: ContextDemoError.unsafePath) { try document(assets: [asset(path: "context-demo/\(projectID)/demo-1.mov")]).validate() }
        #expect(throws: ContextDemoError.invalidAsset) { try document(assets: [asset(width: 1279)]).validate() }
        #expect(throws: ContextDemoError.invalidAsset) { try document(assets: [asset(size: 67_108_865)]).validate() }
        #expect(throws: ContextDemoError.unsafePath) { try ContextDemoAsset.relativePath(projectId: projectID, assetId: "con") }
    }

    @Test func requestRequiresBoundWindowIdentityAndSafeTarget() throws {
        let valid = ContextDemoCaptureRequest(id: "request", planId: "plan", revision: 0, target: target(), durationSeconds: 5,
            window: ContextDemoWindowBinding(windowID: 1, processID: 2, bundleID: "org.example.App"))
        try valid.validate()
        let wrongWindow = ContextDemoCaptureRequest(id: "request", planId: "plan", revision: 0, target: target(), durationSeconds: 5,
            window: ContextDemoWindowBinding(windowID: 1, processID: 2, bundleID: "org.other.App"))
        #expect(throws: ContextDemoError.invalidRequest) { try wrongWindow.validate() }
        let unsafe = ContextDemoTarget(kind: .webPage, displayName: "Page", locator: "https://user:password@example.invalid")
        #expect(throws: ContextDemoError.invalidTarget) {
            try ContextDemoCaptureRequest(id: "request", planId: "plan", revision: 0, target: unsafe, durationSeconds: 5).validate()
        }
    }

    @Test(arguments: ["file:///tmp/../private", "file://remote.invalid/project", "file:///tmp/project%00name"])
    func projectTargetRefusesRemoteTraversalAndEncodedControl(locator: String) throws {
        let target = ContextDemoTarget(kind: .codeProject, displayName: "Project", locator: locator)
        #expect(throws: ContextDemoError.invalidTarget) {
            try ContextDemoCaptureRequest(id: "request", planId: "plan", revision: 0, target: target, durationSeconds: 1).validate()
        }
    }

    @Test func emptyScopeDropsUnusedAssetsAndBoundaryTouchDoesNotLoop() throws {
        let input = try ContextDemoPlanner.prepare(document: document(), projectId: projectID, timeline: timeline(),
            scope: TimeRange(start: 4, end: 5))
        #expect(input.placements.isEmpty && input.assets.isEmpty)
    }

    @Test func sidecarCodecIsDeterministicAndRejectsUnknownFutureSemantics() throws {
        let original = try document()
        let encoded = try ContextDemoCodec.encode(original)
        #expect(try ContextDemoCodec.decode(encoded) == original)
        #expect(try ContextDemoCodec.encode(original) == encoded)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["version"] = 2
        #expect(throws: ContextDemoError.unsupportedVersion) {
            try ContextDemoCodec.decode(JSONSerialization.data(withJSONObject: json))
        }
        json["version"] = 1
        var assets = try #require(json["assets"] as? [[String: Any]])
        assets[0]["codec"] = "unsupported-codec"
        json["assets"] = assets
        #expect(throws: ContextDemoError.unsupportedVersion) {
            try ContextDemoCodec.decode(JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func revisionOverflowIsRejectedWithoutMutation() throws {
        let original = try document(revision: Int(Int32.max))
        try original.validate()
        #expect(throws: ContextDemoError.staleRevision) {
            try original.removingPlacement(id: "placement-1", expectedRevision: Int(Int32.max))
        }
        #expect(throws: ContextDemoError.invalidRequest) { try document(revision: Int(Int32.max) + 1).validate() }
    }
}
