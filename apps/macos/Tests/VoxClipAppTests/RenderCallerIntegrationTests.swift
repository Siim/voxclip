#if DEBUG
import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip
@testable import VoxClipMedia

@Suite("Render caller integration", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR"), .offlineFixtures)
@MainActor struct RenderCallerIntegrationTests {
    @Test func bRollOverACutUsesConsecutiveSourceFramesAndEndsWhenTheRecordingDoes() async throws {
        let shared = try SharedResources.locate()
        let camera = shared.root.appendingPathComponent("fixtures/media/joins-tone.mov")
        let companion = shared.root.appendingPathComponent("fixtures/media/counter-1080p.mp4")
        let plan = EditPlan(sampleRate: 48_000, totalSamples: 576_000,
                            kept: [.init(startSample: 0, endSample: 48_000), .init(startSample: 96_000, endSample: 192_000)])
        var render = RenderRequest(sourceURL: camera, plan: plan,
                                   output: .init(size: .init(width: 320, height: 180), fps: 30, videoBitrate: 100_000))
        let entry = ClipFootage(id: "footage", clipID: "scope", kind: .bRoll, start: 0.5, end: 3.5,
                                footage: .init(sourceKey: "counter", start: 3), fadeInSeconds: 0.25, fadeOutSeconds: 0.25)
        render.footage = [.init(entry: entry, url: companion)]
        let graph = try await CompositionBuilder().build(render)
        let other = try #require(graph.composition.tracks(withMediaType: .video).first { $0.trackID != graph.videoTrack.trackID })
        let media = try #require(other.segments.first { !$0.isEmpty })
        let mapping = media.timeMapping
        #expect(mapping.source.start.seconds == 3)
        #expect(mapping.target.start.seconds == 0.5)
        #expect(mapping.target.duration.seconds == 1)
        #expect(mapping.source.duration == mapping.target.duration)
        let generator = AVAssetImageGenerator(asset: graph.composition)
        generator.videoComposition = graph.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let referencePlan = EditPlan(sampleRate: 48_000, totalSamples: 192_000, kept: [.init(startSample: 144_000, endSample: 192_000)])
        let reference = try await CompositionBuilder().build(RenderRequest(sourceURL: companion, plan: referencePlan, output: render.output))
        let expected = AVAssetImageGenerator(asset: reference.composition)
        expected.videoComposition = reference.videoComposition
        expected.requestedTimeToleranceBefore = .zero; expected.requestedTimeToleranceAfter = .zero
        var thumbnails: [Data] = []
        for frame in [29, 30] as [Int64] {
            let actual = try await generator.image(at: CMTime(value: frame, timescale: 30)).image
            let consecutive = try await expected.image(at: CMTime(value: frame - 15, timescale: 30)).image
            let actualBytes = try #require(actual.dataProvider?.data as Data?)
            let expectedBytes = try #require(consecutive.dataProvider?.data as Data?)
            #expect(actualBytes == expectedBytes)
            thumbnails.append(actualBytes)
        }
        #expect(thumbnails[0] != thumbnails[1])
    }

    @Test func previewAndExportPCMMatchForSlippedFadedSplitMusic() async throws {
        let shared = try SharedResources.locate()
        let source = shared.root.appendingPathComponent("fixtures/media/joins-tone.mov")
        let rate: Int32 = 48_000
        let frames: Int64 = 96_000
        let plan = EditPlan(sampleRate: Double(rate), totalSamples: 576_000,
                            kept: [.init(startSample: 0, endSample: frames)])
        var render = RenderRequest(sourceURL: source, plan: plan,
                                   output: .init(size: .init(width: 320, height: 180), fps: 30, videoBitrate: 100_000))
        var entry = ProjectMusic(id: "music", clipId: nil, asset: .init(file: "bed.mov", sha256: "", durationSeconds: 12),
                                 source: .file, title: "Bed", license: .own, gainDb: -20, ducking: false, startOffsetSeconds: 0)
        entry.segments = [
            .init(id: "left", anchorSeconds: 0, lengthSeconds: 0.75, songFromSeconds: 2, loop: false, fadeInSeconds: 0.25, fadeOutSeconds: 0),
            .init(id: "right", anchorSeconds: 0.75, lengthSeconds: 0.75, songFromSeconds: 2.75, loop: false, fadeInSeconds: 0, fadeOutSeconds: 0.25)
        ]
        render.music = .init(entry: entry, assetURL: source)
        let preview = PreviewPlayerController()
        defer { preview.close() }
        try await preview.load(render)
        let item = try #require(preview.player.currentItem as? LeasedPlayerItem)
        var previewHash = SHA256()
        let range = CMTimeRange(start: .zero, duration: CMTime(value: frames, timescale: rate))
        try await AVExporter.readMix(graph: item.renderGraph, timeRange: range, sampleLimit: frames) { samples in
            previewHash.update(data: Data(UnsafeRawBufferPointer(samples)))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = AVExporter(cleanupRegistry: root.appendingPathComponent("Scratch"))
        let wav = try await exporter.stageEditedAudio(render, to: root.appendingPathComponent("sound.wav"), includeMusic: true)
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        try file.read(into: buffer)
        let pcm = buffer.audioBufferList.pointee.mBuffers
        let bytes = try #require(pcm.mData)
        let exportHash = SHA256.hash(data: Data(bytes: bytes, count: Int(pcm.mDataByteSize)))
        #expect(previewHash.finalize() == exportHash)
    }

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
