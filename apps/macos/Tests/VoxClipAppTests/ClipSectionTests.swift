#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// The Clip section and its editor commands (design.md §6.8) on a demo editor with its own data folder: no window, no
/// network, no keychain.
@Suite("Clip section", .serialized, .offlineFixtures)
@MainActor struct ClipSectionTests {
    private struct Fixture {
        let root: URL
        let editor: EditorModel
        let undo: UndoManager
    }

    /// With `undo`, a manager that groups only where `step` opens a group (as the run loop opens one per click).
    private func fixture(undo withUndo: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-clip-section-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false
        if withUndo { editor.undoManager = undo }
        return Fixture(root: root, editor: editor, undo: undo)
    }

    /// Each command, once, as its own undo group (as the run loop groups one per click).
    private func step(_ fixture: Fixture, _ change: () -> Bool) -> Bool {
        fixture.undo.beginUndoGrouping()
        defer { fixture.undo.endUndoGrouping() }
        return change()
    }

    @Test func eachControlIsOneUndoStepOnTheOpenClip() throws {
        let fixture = try fixture(undo: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        #expect(editor.renderedActiveClipID == "clip-main" && editor.currentClipControls?.isDefault == true)
        #expect(editor.project.schemaVersion == 3 && editor.clipSpeedBadge == nil)
        let steps = editor.undoSteps
        #expect(step(fixture) { editor.setSpeed(1.25) })
        #expect(editor.project.schemaVersion == 4 && editor.clipSpeedBadge == "1.25\u{00D7}")
        #expect(step(fixture) { editor.setLook(.muted) })
        #expect(step(fixture) { editor.setShape(.portraitFourFive) })
        #expect(step(fixture) { editor.setGain(-3.3) })
        #expect(step(fixture) { editor.setFade(in: 0.46) })
        #expect(step(fixture) { editor.setFade(out: 1) })
        #expect(step(fixture) { editor.setMute(true) })
        #expect(step(fixture) { editor.setFlip(true) })
        #expect(step(fixture) { editor.setRotation(90) })
        #expect(editor.undoSteps == steps + 9)
        let controls = try #require(editor.currentClipControls)
        #expect(controls == ProjectClipControls(clipId: "clip-main", speed: 1.25, shape: .portraitFourFive, look: .muted, gainDb: -3.5,
                                                fadeInSeconds: 0.5, fadeOutSeconds: 1, muteSource: true, flipHorizontal: true, rotationDegrees: 90))
        #expect(ClipSection.summary(controls) == "1.25\u{00D7} \u{00B7} 4:5 \u{00B7} Muted \u{00B7} Source muted \u{00B7} Fades \u{00B7} Flipped \u{00B7} 90\u{00B0}")
        // The same value again is no step at all.
        #expect(!editor.setSpeed(1.25) && !editor.setLook(.muted) && editor.undoSteps == steps + 9)
        #expect(editor.lastAnnouncement == "Rotated 90 degrees")
        // Undo walks back one control at a time, to no stored controls at all.
        fixture.undo.undo()
        #expect(editor.currentClipControls?.rotationDegrees == 0 && editor.currentClipControls?.flipHorizontal == true)
        fixture.undo.undo()
        #expect(editor.currentClipControls?.flipHorizontal == false)
        for _ in 0..<7 { fixture.undo.undo() }
        #expect(editor.project.clipControls.isEmpty && editor.currentClipControls?.isDefault == true)
        fixture.undo.redo()
        #expect(editor.currentClipControls?.speed == 1.25 && editor.project.clipControls.count == 1)
    }

    @Test func thePlannersLookAndSpeedApplyAsOneStepEach() throws {
        let fixture = try fixture(undo: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let steps = editor.undoSteps
        #expect(step(fixture) { editor.apply(look: ClipAutopilotPlan.Look(id: .warm, reason: "Golden hour")) })
        #expect(step(fixture) { editor.apply(speed: ClipAutopilotPlan.Speed(rate: 1.1, reason: "Slow delivery")) })
        #expect(editor.undoSteps == steps + 2 && editor.currentClipControls?.look == .warm && editor.clipSpeedBadge == "1.1\u{00D7}")
        // A named clip works from any tab; a clip that is not in the project does nothing.
        #expect(!editor.setSpeed(2, clipID: "clip-missing") && editor.undoSteps == steps + 2)
        #expect(step(fixture) { editor.resetClipControls() })
        #expect(editor.project.clipControls.isEmpty && editor.clipSpeedBadge == nil)
    }

    @Test func fullTakeHasNoClipControlsAndRotateNeedsAPicture() throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        var full = editor.project
        full.edits.activeClipId = nil
        editor.replace(full, name: "Full Take")
        #expect(editor.renderedActiveClipID == nil && editor.currentClipControls == nil)
        let steps = editor.undoSteps
        #expect(!editor.setSpeed(1.5) && !editor.setLook(.bw) && editor.undoSteps == steps && editor.clipSpeedBadge == nil)
        var clip = editor.project
        clip.edits.activeClipId = "clip-main"
        clip.media.source.video = nil
        editor.replace(clip, name: "No picture")
        #expect(!editor.canRotateClip && !editor.setRotation(90) && editor.setFlip(true))
    }

    @Test func removingTheClipDropsItsControls() throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        #expect(editor.setSpeed(1.5))
        editor.apply(.removeClip(id: "clip-main"), name: "Remove clip")
        #expect(editor.project.clipControls.isEmpty)
        #expect(try ProjectJSON.decode(ProjectJSON.encode(editor.project)).clipControls.isEmpty)
    }

    /// Preview and export read the controls from the same request: the clip's speed, look and frame.
    @Test func theRenderRequestCarriesTheClipsControlsAndFrame() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let plain = try await editor.renderRequest(target: .clip("clip-main"))
        let projectFrame = ExportFingerprint.output(editor.project).size
        #expect(plain.clipControls == nil && plain.output.size == projectFrame)
        let before = try ExportFingerprint.value(editor.project, target: .clip("clip-main"))
        #expect(editor.setSpeed(1.25) && editor.setLook(.bw) && editor.setShape(.portraitFourFive))
        let request = try await editor.renderRequest(target: .clip("clip-main"))
        #expect(request.clipControls?.speed == 1.25 && request.clipControls?.look == .bw)
        #expect(request.output.size == PixelSize(width: 1080, height: 1350) && editor.outputSpec().size == request.output.size)
        #expect(abs(request.renderedDuration - request.timeline.duration / 1.25) < 1e-4)
        #expect(ViewerSection.ratio(editor.project) == 0.8)
        // The export is stale once a control changes, and the full take is unaffected.
        #expect(try ExportFingerprint.value(editor.project, target: .clip("clip-main")) != before)
        let full = try await editor.renderRequest(target: .fullEdit)
        #expect(full.clipControls == nil && full.output.size == projectFrame)
        #expect(editor.resetClipControls())
        #expect(try ExportFingerprint.value(editor.project, target: .clip("clip-main")) == before)
    }

    @Test func theSectionShowsForAClipAndTheHeaderBadgeFollowsTheSpeed() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        #expect(editor.setSpeed(0.75))
        let host = NSHostingView(rootView: ClipSection(model: editor, expanded: true, more: true).frame(width: 300))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 520)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 200, "\(host.fittingSize)")
        #expect(editor.clipSpeedBadge == "0.75\u{00D7}")
        #expect(ClipSection.summary(ProjectClipControls(clipId: "a")) == nil)
        #expect(ClipSection.summary(ProjectClipControls(clipId: "a", gainDb: 3)) == "3 dB")
    }

    /// Offscreen PNGs of the folded and open section, dark and light, only when VOXCLIP_CLIP_CONTROLS_CAPTURES names a folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_CLIP_CONTROLS_CAPTURES"] != nil))
    func capturesTheSection() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOXCLIP_CLIP_CONTROLS_CAPTURES"]), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        try await Self.capture(ClipSection(model: editor), name: "clip-folded-default", folder: folder, height: 48)
        #expect(editor.setSpeed(1.25) && editor.setLook(.muted))
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            try await Self.capture(ClipSection(model: editor), name: "clip-folded-\(name)", folder: folder, height: 48, appearance: appearance)
            try await Self.capture(ClipSection(model: editor, expanded: true), name: "clip-open-\(name)", folder: folder, height: 340, appearance: appearance)
            try await Self.capture(ClipSection(model: editor, expanded: true, more: true), name: "clip-more-\(name)", folder: folder, height: 520,
                                   appearance: appearance)
        }
        #expect(editor.setMute(true))
        try await Self.capture(ClipSection(model: editor, expanded: true), name: "clip-muted-dark", folder: folder, height: 340)
    }

    private static func capture(_ section: ClipSection, name: String, folder: URL, height: CGFloat,
                                appearance: NSAppearance.Name = .darkAqua) async throws {
        let view = section.frame(width: 276).padding(.horizontal, 12).frame(width: 300, height: height, alignment: .top)
            .background(DesignValues.color("bg.window"))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: height)
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
}
#endif
