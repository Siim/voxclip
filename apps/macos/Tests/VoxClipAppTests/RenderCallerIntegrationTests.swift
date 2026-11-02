#if DEBUG
import AppKit
import Foundation
import Testing
import VoxClipCore
@testable import VoxClip

@Suite("Render caller integration", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR"))
@MainActor struct RenderCallerIntegrationTests {
    private func project(origin: ClipOrigin = .manual) throws -> Project {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.id = UUID().uuidString.lowercased()
        project = try ContextDemoProject.upgradeToV4(project)
        project.captions.styleId = "off"
        project.edits = ProjectEdits(clips: [ClipRange(id: "scope", startWordId: "w4", endWordId: "w5", origin: origin)])
        project.motionCues = [MotionCue(id: "motion", clipID: "scope", sourceStart: 2.5, sourceEnd: 3.2,
            keyframes: [MotionKeyframe(progress: 0), MotionKeyframe(progress: 1, scale: 1.12)])]
        return project
    }

    private func asset(_ project: Project, hash: String = String(repeating: "a", count: 64)) throws -> ContextDemoAsset {
        ContextDemoAsset(id: "capture", requestId: "request", target: .init(kind: .desktopApp,
            displayName: "Demo", locator: "org.voxclip.demo"),
            relativePath: try ContextDemoAsset.relativePath(projectId: project.id, assetId: "capture"),
            sha256: hash, durationSeconds: 2, pixelWidth: 640, pixelHeight: 360,
            byteSize: 100, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func placingDemo(_ project: Project) throws -> Project {
        let timeline = try RenderCallerInputs.timeline(project: project)
        let scoped = try RenderCallerInputs.timeline(project: project, clipID: "scope")
        let start = timeline.mapTime(scoped.sourceTime(0))
        let document = try ContextDemoDocument(project: project, planId: "plan", timeline: timeline)
            .placing(asset: asset(project), placement: .init(id: "placement", assetId: "capture",
                source: .init(start: 0.2, end: 0.5), editedStartSeconds: start), expectedRevision: 0)
        return try ContextDemoProject.setting(document, in: project, timeline: timeline)
    }

    private func editor(_ project: Project) async throws -> EditorModel {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        await shell.attachForTesting(VoxClipDocument(project: project), selection: .clip("scope"),
            preview: DemoPreviewEngine(), exporter: RegressionExporter())
        let model = try #require(shell.editor)
        model.mediaResolved = true; model.mediaUnreadable = false; model.refresh()
        return model
    }

    @Test(arguments: [ClipOrigin.manual, .ai])
    func previewClipAndSuggestedExportsUseSameValidatedDemo(origin: ClipOrigin) async throws {
        let project = try placingDemo(project(origin: origin))
        let model = try await editor(project)
        defer { model.close() }
        var snapshot = model.renderSnapshot(); snapshot.reduceMotion = true
        let preview = try await model.renderRequest(snapshot: snapshot)
        let clip = try await model.renderRequest(target: .clip("scope"), snapshot: snapshot)
        let full = try await model.renderRequest(target: .fullEdit, snapshot: snapshot)
        #expect(preview.contextDemo == clip.contextDemo && preview.contextDemo?.placements.count == 1)
        #expect(preview.contextDemo?.placements.first?.output.start == 0)
        #expect(preview.reduceMotion && !clip.reduceMotion && !full.reduceMotion)
        #expect(preview.motionCues.map(\.id) == ["motion"] && clip.motionCues == preview.motionCues)
        #expect(full.motionCues.isEmpty && full.motionClipID == nil)
        #expect(full.contextDemo?.scope.start == 0 && full.contextDemo?.placements.count == 1)
        #expect(clip.sourceContentKey == project.media.source.contentKey)
        #expect(clip.contextDemoRoot == model.app.locations.root.standardizedFileURL.resolvingSymlinksInPath())
        #expect(model.project.transcript == project.transcript && model.project.media == project.media)
    }

    @Test func exportFingerprintChangesForDemoAddMoveReplaceRemoveAndClipMotion() throws {
        let initial = try project()
        let placed = try placingDemo(initial)
        let original = try ExportFingerprint.value(initial, target: .clip("scope"))
        let added = try ExportFingerprint.value(placed, target: .clip("scope"))
        #expect(original != added)
        let document = try #require(placed.contextDemo)
        var moved = placed
        moved.contextDemo = try document.replacingPlacement(.init(id: "placement", assetId: "capture",
            source: .init(start: 0.2, end: 0.5), editedStartSeconds: document.placements[0].editedStartSeconds + 0.1),
            expectedRevision: document.revision)
        #expect(try ExportFingerprint.value(moved, target: .clip("scope")) != added)
        var replaced = placed
        replaced.contextDemo = try document.replacingAsset(id: "capture", with: asset(placed, hash: String(repeating: "b", count: 64)),
            expectedRevision: document.revision)
        #expect(try ExportFingerprint.value(replaced, target: .clip("scope")) != added)
        var removed = placed; removed.contextDemo = nil
        #expect(try ExportFingerprint.value(removed, target: .clip("scope")) == original)
        var changedMotion = placed; changedMotion.motionCues = []
        #expect(try ExportFingerprint.value(changedMotion, target: .clip("scope")) != added)
        #expect(try ExportFingerprint.value(changedMotion, target: .fullEdit) == ExportFingerprint.value(placed, target: .fullEdit))
    }

    @Test func demoAndMotionOnlyChangesInvalidateExportCachesAndChangedState() async throws {
        let project = try project()
        let model = try await editor(project)
        defer { model.close() }
        let original = try ExportFingerprint.value(model.project, target: .clip("scope"))
        try model.app.exportLedger.record(ExportRecord(projectID: model.project.id, targetID: "scope", exportedAt: Date(),
            planFingerprint: original, styleId: "off", aspect: model.project.export.aspect, outputPath: "/tmp/unused-export.mp4"))
        #expect(model.exportRowStatus("scope") == .exported)
        let revision = model.projectRevision
        let cached = model.exportsFingerprintCache.value(project: model.project, target: .clip("scope"),
            revision: revision, labelPosition: model.app.voiceLabLabelPosition)
        model.document.replaceProject(try placingDemo(model.project)); model.refresh()
        #expect(model.projectRevision == revision + 1 && model.exportRowStatus("scope") == .changed)
        #expect(model.exportsFingerprintCache.value(project: model.project, target: .clip("scope"),
            revision: model.projectRevision, labelPosition: model.app.voiceLabLabelPosition) != cached)
        var motionOnly = model.project; motionOnly.motionCues = []
        model.document.replaceProject(motionOnly); model.refresh()
        #expect(model.projectRevision == revision + 2)
    }

    @Test func staleSourceBindingCannotReachPreviewRequest() async throws {
        let project = try placingDemo(project())
        let model = try await editor(project)
        defer { model.close() }
        var snapshot = model.renderSnapshot()
        var changed = snapshot.project; changed.media.source.contentKey = String(repeating: "b", count: 64)
        snapshot = EditorRenderSnapshot(project: changed, state: snapshot.state, plan: snapshot.plan)
        await #expect(throws: (any Error).self) { try await model.renderRequest(snapshot: snapshot) }
    }
}
#endif
