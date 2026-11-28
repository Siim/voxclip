#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// A Vision stand-in: no face, nothing on screen.
private final class LookVision: FrameObserving {
    func observe(_ image: CGImage, time: Double) throws -> FrameObservation { FrameObservation(time: time, faceCount: 0, face: nil, screens: []) }
}

/// A decoder stand-in: a flat frame of one sRGB colour at every time; `failing` reads nothing.
private final class LookDecoder: FrameDecoding {
    let color: [Double]
    let failing: Bool
    init(color: [Double], failing: Bool = false) { self.color = color; self.failing = failing }
    func reader(source: URL, maximumEdge: Int, tolerance: Double) -> any FrameReading { LookReader(color: color, failing: failing) }
}

private struct LookReader: FrameReading {
    let color: [Double]
    let failing: Bool
    func image(at time: Double) async throws -> (image: CGImage, time: Double) {
        if failing { throw VoxClipError.decodeFailed("no video track") }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VoxClipError.decodeFailed("context") }
        context.setFillColor(CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        guard let image = context.makeImage() else { throw VoxClipError.decodeFailed("image") }
        return (image, time)
    }
}

/// Set when an observed value changes.
private final class LookHeard: @unchecked Sendable { var value = false }

/// A player stand-in that counts what reloads it: hover and Compare must never.
@MainActor final class LookCountingPreview: PreviewEngine {
    let events: AsyncStream<PreviewEvent>
    private let continuation: AsyncStream<PreviewEvent>.Continuation
    private(set) var isPlaying = false
    private(set) var editedTime = 0.0
    private(set) var loads = 0
    private(set) var updates = 0
    init() { (events, continuation) = AsyncStream.makeStream() }
    func load(_ request: RenderRequest) async throws { loads += 1 }
    func update(_ request: RenderRequest) async throws { updates += 1 }
    func seek(to editedTime: Double, exact: Bool) async throws { self.editedTime = editedTime }
    func play() { isPlaying = true; continuation.yield(.playing(true)) }
    func pause() { isPlaying = false; continuation.yield(.playing(false)) }
    func close() { continuation.finish() }
}

/// The Picture panel's looks (looks spec 2026-11-28, sections 3, 7 and 10) on a demo editor with its own data folder: the
/// commands, their undo names and announcements, the disabled reasons, Suggested, Auto, Claude's line, the previews and
/// tiles drawn by the export's own compositor, and offscreen captures of the panel. No window, no network, no keychain.
@Suite("Picture looks", .serialized, .offlineFixtures)
@MainActor struct ClipLookControlsTests {
    struct Fixture {
        let root: URL
        let editor: EditorModel
        let undo: UndoManager
        let player: LookCountingPreview
    }

    private func fixture(color: [Double] = [0.54, 0.5, 0.475], failingFrames: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-looks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: locations)
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let player = LookCountingPreview()
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: player)
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let analyzer = FrameAnalyzer(vision: LookVision(), decoder: LookDecoder(color: color, failing: failingFrames),
                                     cache: FrameAnalysisCache(locations: locations))
        let words = project.transcript?.words ?? []
        let source = URL(fileURLWithPath: project.media.source.absolutePath), key = project.media.source.contentKey
        editor.makeIt.services = MakeItServices(
            plan: { _, _, _, _ in ClipAutopilotSeries(plans: []) },
            voice: { _, _ in MakeItRewriteOutcome(result: .voiced(segments: [])) },
            voiceAvailable: { _ in false },
            framePass: { _ in VideoFramePass(analyzer: analyzer, source: source, contentKey: key, words: words) { _ in } },
            frameAI: { _ in nil })
        return Fixture(root: root, editor: editor, undo: undo, player: player)
    }

    private func close(_ fixture: Fixture) { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }

    /// One command as its own undo group, as the run loop groups one per click.
    @discardableResult private func step<T>(_ fixture: Fixture, _ change: () -> T) -> T {
        fixture.undo.beginUndoGrouping()
        defer { fixture.undo.endUndoGrouping() }
        return change()
    }

    private var library: ClipLookLibrary { get throws { try #require(ClipLookLibrary.app) } }
    private func panel(_ editor: EditorModel) throws -> ClipLookPanel { try #require(editor.lookPanel) }

    // MARK: The reference task (spec section 3.0)

    /// Warm Print, then 70%, +20 vibrance and −15 highlights: four undo steps with the spec's names, the Look row reads
    /// "Warm Print, edited · 70%", and the clip stores exactly spec section 8.1's entry, promoted to v8.
    @Test func theReferenceTaskIsFourNamedStepsAndStoresTheSpecsEntry() throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        #expect(try panel(editor).lookValue == "As filmed")
        let steps = editor.undoSteps
        #expect(step(fixture) { editor.chooseLook("warmPrint") } == .changed)
        #expect(fixture.undo.undoActionName == "Change look" && editor.lastAnnouncement == "Look Warm Print")
        #expect(try panel(editor).lookValue == "Warm Print")
        #expect(step(fixture) { editor.setLookAmount(70) })
        #expect(fixture.undo.undoActionName == "Change look amount" && editor.lastAnnouncement == "Amount 70 percent")
        #expect(try panel(editor).lookValue == "Warm Print \u{00B7} 70%")
        #expect(step(fixture) { editor.setLookSlider(.vibrance, value: 20) })
        #expect(fixture.undo.undoActionName == "Change vibrance" && editor.lastAnnouncement == "Vibrance plus 20")
        #expect(step(fixture) { editor.setLookSlider(.highlights, value: -15) })
        #expect(fixture.undo.undoActionName == "Change highlights" && editor.lastAnnouncement == "Highlights minus 15")
        #expect(editor.undoSteps == steps + 4)
        let panel = try panel(editor)
        #expect(panel.lookValue == "Warm Print, edited \u{00B7} 70%")
        #expect(ClipSection.summary(panel.controls) == "Warm Print, edited 70%")
        #expect(panel.controls.look == .original)
        #expect(panel.controls.colorAdjustments == ClipColorAdjustments(saturation: -10, warmth: 26))
        let warmPrint = try #require(try library.look("warmPrint"))
        #expect(panel.controls.colorGrade == ClipColorGrade(preset: "warmPrint", amount: 70, highlights: -15, vibrance: 20, fade: 20, grain: 20,
                                                            curve: warmPrint.grade.curve, splitTone: warmPrint.grade.splitTone))
        #expect(warmPrint.grade.curve?.master == [0, 245, 500, 760, 965])
        #expect(editor.project.schemaVersion == ProjectMigrations.colorGradeVersion)
        // Highlights' tick is Warm Print's −12; the Fix has none.
        #expect(panel.tick(.highlights) == -12 && panel.tick(.exposure) == 0)
        // The same value again is no step.
        #expect(!editor.setLookSlider(.vibrance, value: 20) && !editor.setLookAmount(70) && editor.undoSteps == steps + 4)
        // Undo walks back one control at a time.
        fixture.undo.undo()
        #expect(editor.currentClipControls?.colorGrade?.highlights == -12)
        fixture.undo.undo(); fixture.undo.undo()
        #expect(try self.panel(editor).lookValue == "Warm Print")
        fixture.undo.undo()
        #expect(editor.project.clipControls.isEmpty)
    }

    /// A click on the applied tile moves focus to Amount and changes nothing; on the edited tile it puts the look's values
    /// back and keeps Amount and the Fix; As filmed keeps the Fix, and again is no step.
    @Test func tileClicksFollowTheAppliedEditedAndAsFilmedRules() throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        #expect(step(fixture) { editor.chooseLook("goldenHour") } == .changed)
        let focus = editor.looks.amountFocusRequest
        let steps = editor.undoSteps
        #expect(editor.chooseLook("goldenHour") == .focusAmount && editor.looks.amountFocusRequest == focus + 1 && editor.undoSteps == steps)
        #expect(step(fixture) { editor.setLookSlider(.exposure, value: 20) })
        #expect(try panel(editor).state(of: try #require(try library.look("goldenHour"))) == .applied, "the Fix doesn't edit a look")
        #expect(step(fixture) { editor.setLookAmount(60) })
        #expect(step(fixture) { editor.setLookSlider(.vignette, value: 50) })
        let golden = try #require(try library.look("goldenHour"))
        #expect(try panel(editor).state(of: golden) == .edited && (try panel(editor).lookName) == "Golden Hour, edited")
        #expect(step(fixture) { editor.chooseLook("goldenHour") } == .changed)
        var controls = try #require(editor.currentClipControls)
        #expect(controls.colorGrade?.vignette == 20 && controls.colorGrade?.amount == 60 && controls.colorGrade?.exposure == 20)
        #expect(step(fixture) { editor.chooseLook("original") } == .changed)
        controls = try #require(editor.currentClipControls)
        #expect(controls.look == .original && controls.colorAdjustments == nil)
        #expect(controls.colorGrade == ClipColorGrade(exposure: 20), "As filmed keeps the Fix, with no preset and the full amount")
        #expect(try panel(editor).lookValue == "As filmed")
        let after = editor.undoSteps
        #expect(editor.chooseLook("original") == .unchanged && editor.undoSteps == after)
    }

    /// Resets, Back to, Remove toning and Clear all color: their undo names, what each keeps, and their disabled reasons.
    @Test func resetsBackToToningAndClearEachUndoByName() throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        step(fixture) { editor.chooseLook("warmPrint") }
        #expect(try panel(editor).backToReason == "Matches Warm Print" && (try panel(editor).backToLabel) == "Back to Warm Print")
        #expect(ClipLookGroup.allCases.allSatisfy { (try? panel(editor).resetReason($0)) == "Nothing to reset" })
        step(fixture) { editor.setLookAmount(70) }
        step(fixture) { editor.setLookSlider(.exposure, value: 20) }
        step(fixture) { editor.setLookSlider(.vibrance, value: 30) }
        step(fixture) { editor.setLookSlider(.highlights, value: -40) }
        step(fixture) { editor.setLookSlider(.grain, value: 0) }
        #expect(try panel(editor).resetReason(.light) == nil && (try panel(editor).resetReason(.fix)) == nil)
        #expect(step(fixture) { editor.resetLookGroup(.light) })
        #expect(fixture.undo.undoActionName == "Reset light" && editor.lastAnnouncement == "Light reset")
        #expect(editor.currentClipControls?.colorGrade?.highlights == -12 && editor.currentClipControls?.colorGrade?.vibrance == 30)
        #expect(step(fixture) { editor.resetLookGroup(.fix) })
        #expect(fixture.undo.undoActionName == "Reset fix" && editor.currentClipControls?.colorGrade?.fix == .neutral)
        #expect(!editor.resetLookGroup(.fix), "Nothing to reset")
        #expect(step(fixture) { editor.setLookSlider(.temperature, value: -12) })
        #expect(step(fixture) { editor.backToLook() })
        #expect(fixture.undo.undoActionName == "Back to Warm Print")
        var controls = try #require(editor.currentClipControls)
        #expect(controls.colorGrade?.vibrance == 0 && controls.colorGrade?.grain == 20, "every look value back")
        #expect(controls.colorGrade?.amount == 70 && controls.colorGrade?.temperature == -12, "Amount and the Fix stay")
        #expect(try panel(editor).hasToning && (try panel(editor).toningText) == "Toning from Warm Print \u{00B7} curve and split tone")
        #expect(step(fixture) { editor.removeLookToning() })
        #expect(fixture.undo.undoActionName == "Remove toning")
        controls = try #require(editor.currentClipControls)
        let edited = try panel(editor).lookName
        #expect(controls.colorGrade?.curve == nil && controls.colorGrade?.splitTone == nil && edited == "Warm Print, edited")
        #expect(step(fixture) { editor.clearColor() })
        #expect(fixture.undo.undoActionName == "Clear color" && editor.project.clipControls.isEmpty, "the Fix goes too")
        #expect(try panel(editor).clearReason == "Nothing to clear" && !editor.clearColor())
        fixture.undo.undo()
        #expect(editor.currentClipControls?.colorGrade?.temperature == -12)
    }

    /// Spec section 10's reasons: As filmed has nothing to blend or compare, B&W mutes Vibrance and Saturation, and a missing
    /// or unconfirmed video disables every control with the editor's line.
    @Test func disabledControlsSayWhy() throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        var panel = try panel(editor)
        #expect(panel.amountReason == "As filmed has no look to blend" && !editor.setLookAmount(50))
        #expect(panel.compareReason == "Nothing to compare: the clip is as filmed")
        #expect(panel.clearReason == "Nothing to clear" && panel.backToLabel == nil)
        step(fixture) { editor.setLookSlider(.exposure, value: 10) }
        panel = try self.panel(editor)
        #expect(panel.compareReason == nil && panel.amountReason != nil, "a Fix alone compares but has nothing to blend")
        step(fixture) { editor.chooseLook("softBW") }
        panel = try self.panel(editor)
        #expect(panel.reason(.vibrance) == "No effect on black and white" && panel.reason(.saturation) == "No effect on black and white")
        #expect(panel.reason(.warmth) == nil && panel.reason(.temperature) == nil)
        #expect(!editor.setLookSlider(.vibrance, value: 20) && step(fixture) { editor.setLookSlider(.warmth, value: 20) })
        #expect(editor.lookEditReason == nil)
        editor.mediaResolved = false
        #expect(editor.lookEditReason == "Locate the video to change the look." && !editor.chooseLook("warm").changedSomething)
        editor.mediaResolved = true
        var project = editor.project
        project.media.source.video = nil
        editor.document.replaceProject(project)
        editor.refresh()
        #expect(editor.lookPanel == nil && editor.lookEditReason == "This recording has no picture to color.")
    }

    /// Suggested (spec section 3.2): As filmed, Claude's pick and alternatives (✦), the current look, then the starters,
    /// duplicates dropped, at most 8; All is the file's 24, and a category its own.
    @Test func suggestedPutsClaudesLooksAndTheCurrentLookFirst() throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        var panel = try panel(editor)
        #expect(panel.suggestedLooks.map(\.id) == ["original", "naturalBoost", "softSkin", "warm", "goldenHour", "warmPrint", "softBW", "cleanPop"])
        #expect(panel.looks(in: ClipLookPanel.all).count == 24)
        #expect(panel.looks(in: "film").map(\.label) == ["Vintage Fade", "Cool Film", "Warm Print", "Matte Film", "Throwback"])
        #expect(panel.categories.map(\.label) == ["Suggested", "All", "Natural", "Bright", "Warm", "Film", "Cinematic", "B&W"])
        step(fixture) { editor.chooseLook("moody") }
        editor.looks.picks["clip-main"] = ClipLookPick(look: .init(id: "tealAmber", amount: 70, alternatives: ["matteFilm", "sepia"],
                                                                   reason: "Cool evening light"), fix: nil)
        panel = try self.panel(editor)
        #expect(panel.suggestedLooks.map(\.id) == ["original", "tealAmber", "matteFilm", "sepia", "moody", "naturalBoost", "softSkin", "warm"])
        let teal = try #require(try library.look("tealAmber")), matte = try #require(try library.look("matteFilm"))
        let moody = try #require(try library.look("moody"))
        #expect(panel.isClaudes(teal) && panel.isClaudes(matte) && !panel.isClaudes(moody))
        #expect(panel.tileLabel(teal) == "Teal & Amber, Cinematic look" && panel.tileValue(teal) == "Claude's pick")
        #expect(panel.tileValue(try #require(try library.look("moody"))) == "Selected")
        // A click on Claude's pick starts at Claude's amount.
        #expect(step(fixture) { editor.chooseLook("tealAmber") } == .changed)
        #expect(editor.currentClipControls?.colorGrade?.amount == 70 && editor.lastAnnouncement == "Look Teal & Amber at 70%")
        #expect(try self.panel(editor).tileValue(teal) == "Selected, amount 70 percent, Claude's pick")
    }

    /// The Claude line (spec section 9.6): "Claude chose …" while the clip shows Claude's look; after a hand change "Claude's
    /// pick: … · Use it", which puts it back with its Fix as one step, "Use Claude's look".
    @Test func claudesPickStaysFindableAndUseItIsOneStep() throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        let look = ClipAutopilotPlan.Look(id: "warmPrint", amount: 70, fix: true, reason: "Warm lamp light suits a travel memory.")
        let fix = ClipColorFix(temperature: -12)
        #expect(step(fixture) { editor.apply(look: look, fix: fix) })
        editor.looks.picks["clip-main"] = ClipLookPick(look: look, fix: fix)
        var line = try #require(try panel(editor).claudeLine)
        #expect(line.text == "Claude chose Warm Print \u{00B7} 70% \u{00B7} Warm lamp light suits a travel memory. Fix: temperature \u{2212}12." && !line.useIt)
        #expect(step(fixture) { editor.chooseLook("goldenHour") } == .changed)
        line = try #require(try panel(editor).claudeLine)
        #expect(line.text == "Claude's pick: Warm Print \u{00B7} 70%" && line.useIt)
        #expect(step(fixture) { editor.useClaudesLook() })
        #expect(fixture.undo.undoActionName == "Use Claude's look" && editor.lastAnnouncement == "Look Warm Print at 70%")
        #expect(editor.currentClipControls?.colorGrade?.temperature == -12 && editor.currentClipControls?.colorGrade?.amount == 70)
        #expect(try panel(editor).claudeLine?.useIt == false)
    }

    /// Fix › Auto (spec sections 5.9 and 10): measuring, then the measured Fix as one step "Fix light and color", announced;
    /// then "Fix matches the measurement". Frames that can't be read say so.
    @Test func autoMeasuresTheClipsFramesAndSetsTheFixAsOneStep() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        #expect(editor.autoReason(try panel(editor)) == "Measuring the picture\u{2026}")
        editor.measureLookFix()
        #expect(editor.looks.auto["clip-main"] == .measuring)
        await editor.looks.autoTask?.value
        guard case .measured(let fix)? = editor.looks.auto["clip-main"] else { Issue.record("no measurement"); return }
        #expect((-30 ... -12).contains(fix.temperature), "\(fix)")
        #expect(editor.autoReason(try panel(editor)) == nil)
        #expect(step(fixture) { editor.fixLightAndColor() })
        #expect(fixture.undo.undoActionName == "Fix light and color" && editor.currentClipControls?.colorGrade?.fix == fix)
        #expect(editor.lastAnnouncement?.hasPrefix("Fix light and color: ") == true && editor.lastAnnouncement?.contains("temperature minus") == true)
        #expect(editor.autoReason(try panel(editor)) == "Fix matches the measurement" && !editor.fixLightAndColor())

        let failing = try self.fixture(failingFrames: true)
        defer { close(failing) }
        failing.editor.measureLookFix()
        await failing.editor.looks.autoTask?.value
        #expect(failing.editor.autoReason(try panel(failing.editor)) == "VoxClip couldn't read this video's frames")

        let even = try self.fixture(color: [0.42, 0.42, 0.42])
        defer { close(even) }
        even.editor.measureLookFix()
        await even.editor.looks.autoTask?.value
        #expect(even.editor.autoReason(try panel(even.editor)) == "The light and color already look even")
    }

    /// Slider text and typing (spec section 3.5): Exposure in EV, others signed; "+20", "−15" and EV are typed.
    @Test func sliderValuesReadAndTypeAsTheSpecSays() {
        #expect(ClipLookSlider.exposure.text(20) == "+0.40 EV" && ClipLookSlider.exposure.text(-50) == "\u{2212}1.00 EV" && ClipLookSlider.exposure.text(0) == "0.00 EV")
        #expect(ClipLookSlider.vibrance.text(20) == "+20" && ClipLookSlider.highlights.text(-15) == "\u{2212}15" && ClipLookSlider.fade.text(0) == "0")
        #expect(ClipLookSlider.vibrance.parse("+20") == 20 && ClipLookSlider.highlights.parse("\u{2212}15") == -15 && ClipLookSlider.highlights.parse("-15") == -15)
        #expect(ClipLookSlider.exposure.parse("+0.4") == 20 && ClipLookSlider.exposure.parse("0.40 EV") == 20)
        #expect(ClipLookSlider.fade.parse("-20") == 0 && ClipLookSlider.vibrance.parse("400") == 100 && ClipLookSlider.vibrance.parse("warm") == nil)
        #expect(ClipLookSlider.exposure.spoken(20) == "plus 0.4" && ClipLookSlider.vibrance.spoken(-5) == "minus 5")
        #expect(ClipLookSlider.allCases.map(\.undoName) == ["Change exposure", "Change temperature", "Change tint", "Change brightness", "Change contrast",
                                                          "Change highlights", "Change shadows", "Change vibrance", "Change saturation", "Change warmth",
                                                          "Change fade", "Change vignette", "Change grain"])
        #expect(ClipLookGroup.fix.accessibilityLabel == "Fix, stays when you change look")
        #expect(ClipLookTileGrid.columns(width: 296) == 4 && ClipLookTileGrid.columns(width: 376) == 6 && ClipLookTileGrid.columns(width: 532) == 8)
    }

    // MARK: Previews and tiles (spec sections 7 and 11.3)

    /// A render of the fixture's clip over a small synthetic video, for stills.
    private func still(_ editor: EditorModel, seconds: Double = 1) async throws -> ClipStillFrame {
        let shared = try SharedResources.locate()
        let source = shared.root.appendingPathComponent("fixtures/media/fillers-chirp.mp4")
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [MediaInterval(startSample: 0, endSample: 96000)])
        var request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 360, height: 640), fps: 30, videoBitrate: 4_000_000))
        request.clipControls = editor.currentClipControls.flatMap { $0.isDefault ? nil : $0 }
        return try await Self.capture(request, seconds: seconds)
    }

    private nonisolated static func capture(_ request: RenderRequest, seconds: Double) async throws -> ClipStillFrame {
        try await ClipStillFrame.capture(try await CompositionBuilder().build(request), renderedSeconds: seconds)
    }

    private func bytes(_ image: CGImage?) -> Data? { image?.dataProvider?.data as Data? }

    /// Hover shows the look at 100% with the clip's Fix, Compare As filmed, a drag its values: each the export's own frame
    /// (`ClipStillFrame.still(colorOf:)`), with nothing reloaded; during playback hover does nothing, and Compare pauses
    /// and resumes.
    @Test(.timeLimit(.minutes(3))) func previewsAreTheExportsFrameAndReloadNothing() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        step(fixture) { editor.setLookSlider(.exposure, value: 15) }
        step(fixture) { editor.chooseLook("warmPrint") }
        let still = try await still(editor)
        editor.looks.stills = { _ in still }
        // The edits' own preview update (150 ms after each) lands first; only what follows counts.
        try await Task.sleep(for: .milliseconds(400))
        let loads = fixture.player.loads, updates = fixture.player.updates
        editor.previewLook("goldenHour")
        await editor.looks.previewTask?.value
        var shown = try #require(editor.looks.preview)
        var expected = try #require(editor.currentClipControls)
        expected.applyLook(try #require(try library.look("goldenHour")), amount: 100)
        #expect(shown.badge == "Preview \u{00B7} Golden Hour" && expected.colorGrade?.exposure == 15)
        #expect(bytes(shown.image) == bytes(try await still.still(colorOf: expected)))
        editor.previewLook(nil)
        #expect(editor.looks.preview == nil && editor.looks.hovered == nil)

        editor.setLookCompare(true)
        await editor.looks.previewTask?.value
        shown = try #require(editor.looks.preview)
        #expect(shown.badge == "As filmed" && editor.lastAnnouncement == "Showing as filmed")
        #expect(bytes(shown.image) == bytes(try await still.still(colorOf: nil)))
        editor.setLookCompare(false)
        #expect(editor.looks.preview == nil && editor.lastAnnouncement == "Showing Warm Print")

        var dragged = try #require(editor.currentClipControls)
        dragged.colorGrade?.amount = 40
        editor.previewLookDraft(dragged)
        await editor.looks.previewTask?.value
        #expect(bytes(editor.looks.preview?.image) == bytes(try await still.still(colorOf: dragged)))
        editor.previewLookDraft(nil)
        #expect(fixture.player.loads == loads && fixture.player.updates == updates, "hover, Compare and drags reload nothing")

        // Playing: hover does nothing; a Compare hold pauses and its release resumes.
        editor.transport(" ")
        #expect(editor.isPlaying)
        editor.previewLook("bw")
        #expect(editor.looks.hovered == nil && editor.looks.preview == nil)
        editor.setLookCompare(true)
        #expect(!editor.isPlaying && editor.looks.comparing)
        editor.setLookCompare(false)
        #expect(editor.isPlaying)
        editor.transport(" ")
    }

    /// The pointer moving from tile to tile keeps the last preview until the next one shows (spec section 3.4): leaving a
    /// tile only stops its own pending preview, whichever of the two events comes first; leaving the grid ends it.
    @Test(.timeLimit(.minutes(3))) func movingBetweenTilesKeepsThePreviewUntilTheNextShows() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        step(fixture) { editor.chooseLook("warmPrint") }
        let still = try await still(editor)
        editor.looks.stills = { _ in still }
        let golden = "Preview \u{00B7} \(try #require(try library.look("goldenHour")).label)"
        let bw = "Preview \u{00B7} \(try #require(try library.look("bw")).label)"
        editor.hoverLookTile("goldenHour", inside: true)
        await editor.looks.hoverTask?.value
        await editor.looks.previewTask?.value
        #expect(editor.looks.preview?.badge == golden && editor.looks.hovered == "goldenHour")
        // Out of one tile into the gap: the preview stays.
        editor.hoverLookTile("goldenHour", inside: false)
        #expect(editor.looks.preview?.badge == golden && editor.looks.hovered == "goldenHour")
        // Into the next tile, its entry before the last tile's exit: the late exit cancels nothing.
        editor.hoverLookTile("bw", inside: true)
        editor.hoverLookTile("goldenHour", inside: false)
        #expect(editor.looks.preview?.badge == golden, "the viewer never shows the unpreviewed clip between tiles")
        await editor.looks.hoverTask?.value
        await editor.looks.previewTask?.value
        #expect(editor.looks.preview?.badge == bw && editor.looks.hovered == "bw")
        // Passing over a tile without resting previews nothing.
        editor.hoverLookTile("softBW", inside: true)
        editor.hoverLookTile("softBW", inside: false)
        await editor.looks.hoverTask?.value
        #expect(editor.looks.preview?.badge == bw)
        editor.leaveLookTiles()
        #expect(editor.looks.preview == nil && editor.looks.hovered == nil && editor.looks.pointerTile == nil)
    }

    /// Keyboard focus lands on the tile under the pointer, else the applied or edited look, else the first (spec section 3.9).
    @Test func keyboardFocusLandsOnThePointersTileThenTheAppliedOne() throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        step(fixture) { editor.chooseLook("warmPrint") }
        var shown = try panel(editor).looks(in: ClipLookPanel.all)
        let warmPrint = try #require(shown.firstIndex { $0.id == "warmPrint" })
        #expect(warmPrint > 0)
        #expect(ClipLookTileGrid.entryIndex(shown, panel: try panel(editor), pointer: nil) == warmPrint)
        step(fixture) { editor.setLookSlider(.vibrance, value: 20) }
        #expect(ClipLookTileGrid.entryIndex(shown, panel: try panel(editor), pointer: nil) == warmPrint, "the edited look")
        let bw = try #require(shown.firstIndex { $0.id == "bw" })
        #expect(ClipLookTileGrid.entryIndex(shown, panel: try panel(editor), pointer: "bw") == bw)
        shown.removeAll { $0.id == "warmPrint" }
        #expect(ClipLookTileGrid.entryIndex(shown, panel: try panel(editor), pointer: nil) == 0)
    }

    /// The tiles' redraw key reads the playhead only while paused, so playback's 30 Hz playhead never re-evaluates the grid
    /// (spec section 7.1); paused, a seek redraws them.
    @Test func theTilesFollowThePausedPlayheadOnly() throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        func changes(_ change: () -> Void) -> Bool {
            let changed = LookHeard()
            withObservationTracking { _ = ClipLookTileGrid.stillKey(editor, clipID: "a", pixels: 96) } onChange: { changed.value = true }
            change()
            return changed.value
        }
        editor.isPlaying = true
        #expect(!changes { editor.playhead += 1.0 / 30 }, "playback's playhead")
        editor.isPlaying = false
        let paused = ClipLookTileGrid.stillKey(editor, clipID: "a", pixels: 96)
        #expect(changes { editor.playhead += 1 }, "a paused seek")
        #expect(ClipLookTileGrid.stillKey(editor, clipID: "a", pixels: 96) != paused)
    }

    /// Tiles are each look at 100% with the clip's Fix on the paused frame before the grade, the export's tile exactly;
    /// choosing a look draws nothing again, a Fix does. Without a frame they use the test card.
    @Test(.timeLimit(.minutes(3))) func tilesAreTheExportsTilesAndAreCachedPerFix() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        step(fixture) { editor.setLookSlider(.temperature, value: -20) }
        let still = try await still(editor)
        editor.looks.stills = { _ in still }
        editor.refreshLookTiles(pixels: 96, first: ["warmPrint"])
        await editor.looks.tileTask?.value
        #expect(editor.looks.tileSource == .frame && editor.looks.tiles.count == 24 && editor.looks.tileRenders == 1)
        var warmPrint = try #require(editor.currentClipControls)
        warmPrint.applyLook(try #require(try library.look("warmPrint")), amount: 100)
        #expect(bytes(editor.looks.tiles["warmPrint"]) == bytes(try still.tile(controls: warmPrint, center: nil, pixels: 96)))
        step(fixture) { editor.chooseLook("moody") }
        editor.refreshLookTiles(pixels: 96)
        await editor.looks.tileTask?.value
        #expect(editor.looks.tileRenders == 1, "choosing a look draws no tile again")
        step(fixture) { editor.setLookSlider(.exposure, value: 30) }
        editor.refreshLookTiles(pixels: 96)
        await editor.looks.tileTask?.value
        #expect(editor.looks.tileRenders == 2, "a new Fix draws them again")

        // No frame: the test card, and why.
        editor.looks.stills = { _ in throw VoxClipError.decodeFailed("unreadable") }
        step(fixture) { editor.setLookSlider(.tint, value: 10) }
        editor.refreshLookTiles(pixels: 96)
        await editor.looks.tileTask?.value
        #expect(editor.looks.tileSource == .sample("Showing looks on a sample picture: this frame couldn't be read."))
        let card = try #require(ClipLookState.testCard)
        var bw = try #require(editor.currentClipControls)
        bw.applyLook(try #require(try library.look("bw")), amount: 100)
        #expect(bytes(editor.looks.tiles["bw"]) == bytes(try ClipStillFrame.tile(of: card, controls: bw, center: nil, pixels: 96)))
        editor.mediaUnreadable = true
        editor.refreshLookTiles(pixels: 96)
        await editor.looks.tileTask?.value
        #expect(editor.looks.tileSource == .sample("Previews need the source video. Looks still apply when it's back."))
        #expect(!editor.lookPreviewsAvailable)
    }

    /// The tile cache holds the open clip and the last two (spec section 7.6).
    @Test func theTileCacheKeepsThreeClips() throws {
        let library = try library
        var cache = ClipLookTileCache()
        let image = try #require(ClipLookState.testCard)
        for id in ["a", "b", "c", "d"] {
            cache.store(["original": image], for: ClipLookTileKey(clipID: id, stillTime: 1, controls: ProjectClipControls(clipId: id), pixels: 96, library: library))
        }
        #expect(cache.clipIDs == ["d", "c", "b"])
        let key = ClipLookTileKey(clipID: "c", stillTime: 1, controls: ProjectClipControls(clipId: "c"), pixels: 96, library: library)
        #expect(cache.tiles(key) != nil)
        var fixed = ProjectClipControls(clipId: "c"); fixed.colorGrade = ClipColorGrade(exposure: 5)
        #expect(cache.tiles(ClipLookTileKey(clipID: "c", stillTime: 1, controls: fixed, pixels: 96, library: library)) == nil)
        var looked = ProjectClipControls(clipId: "c"); looked.look = .bw
        #expect(cache.tiles(ClipLookTileKey(clipID: "c", stillTime: 1, controls: looked, pixels: 96, library: library)) != nil, "a look is not in the key")
    }
}

extension ClipLookChoice {
    var changedSomething: Bool { self == .changed }
}
#endif
