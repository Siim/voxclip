import CoreGraphics
import Foundation
import ImageIO
import VoxClipCore
import VoxClipMedia

/// What the viewer shows over the paused player while a look is previewed, Compare is held or a slider is dragged (looks
/// spec 2026-11-28, sections 3.4 and 7.8): the export's frame with other colour, and its badge.
struct ClipLookViewerPreview {
    /// The clip it shows; another clip's viewer never shows it.
    let clipID: String
    let image: CGImage
    /// "Preview · Golden Hour", "As filmed", or nil for a drag.
    let badge: String?
}

/// Fix › Auto's measurement of one clip (spec sections 5.9 and 10).
enum ClipLookAuto: Equatable {
    case measuring, failed, measured(ClipColorFix)
}

/// Where the tiles' picture comes from (spec section 7.7).
enum ClipLookTileSource: Equatable {
    /// The clip's own paused frame.
    case frame
    /// The synthetic test card, with the line that says why, when one applies.
    case sample(String?)
}

/// A tile cache key (spec section 7.6): the clip, the still, its framing and Fix, the tile's pixels and the source.
struct ClipLookTileKey: Hashable {
    let clipID: String
    let stillTime: Double?
    let framing: String
    let fix: [Int]
    let pixels: Int
    let looks: Int

    init(clipID: String, stillTime: Double?, controls: ProjectClipControls, pixels: Int, library: ClipLookLibrary) {
        self.clipID = clipID
        self.stillTime = stillTime
        let reframe = controls.reframe.map { "\($0.mode),\($0.zoom),\($0.centerX ?? -1),\($0.centerY ?? -1)" } ?? "-"
        framing = "\(controls.shape?.rawValue ?? "-")|\(controls.flipHorizontal)|\(controls.rotationDegrees)|\(reframe)"
        let fix = controls.colorGrade?.fix ?? .neutral
        self.fix = [fix.exposure, fix.temperature, fix.tint]
        self.pixels = pixels
        var hasher = Hasher()
        for look in library.looks { hasher.combine(look.id); hasher.combine(look.label) }
        looks = hasher.finalize()
    }
}

/// The tiles of the open clip and the last two (spec section 7.6), in memory only.
struct ClipLookTileCache {
    static let clips = 3
    private var entries: [(key: ClipLookTileKey, tiles: [String: CGImage])] = []

    func tiles(_ key: ClipLookTileKey) -> [String: CGImage]? { entries.first { $0.key == key }?.tiles }

    mutating func store(_ tiles: [String: CGImage], for key: ClipLookTileKey) {
        entries.removeAll { $0.key.clipID == key.clipID }
        entries.insert((key, tiles), at: 0)
        if entries.count > Self.clips { entries.removeLast(entries.count - Self.clips) }
    }

    var clipIDs: [String] { entries.map(\.key.clipID) }
}

/// The Picture panel's view state and previews (looks spec 2026-11-28): none of it is an undo step or a project change.
/// The chosen category is remembered per editor; Claude's picks and Auto's measurements live for the session.
@MainActor @Observable final class ClipLookState {
    /// The chosen category chip.
    var category = ClipLookPanel.suggested
    /// Claude's look per clip, from Make it postable (spec section 9.6), held for the session.
    var picks: [String: ClipLookPick] = [:]
    /// Fix › Auto per clip.
    var auto: [String: ClipLookAuto] = [:]
    /// Compare is held: the viewer shows As filmed.
    private(set) var comparing = false
    /// The look a hover or keyboard focus previews.
    private(set) var hovered: String?
    /// What the viewer shows over the player, while it shows something.
    private(set) var preview: ClipLookViewerPreview?
    /// The open clip's tiles by look ID, and their picture.
    private(set) var tiles: [String: CGImage] = [:]
    private(set) var tileSource = ClipLookTileSource.sample(nil)
    /// Bumped to move keyboard focus to Amount (a click on the applied tile).
    var amountFocusRequest = 0
    /// The look the panel scrolls to once it shows (the Clip section's link).
    var scrollTarget: String?

    /// The paused frame's source; nil asks the editor's player. Tests stand it in.
    @ObservationIgnored var stills: (@MainActor (EditorModel) async throws -> ClipStillFrame?)?
    @ObservationIgnored var still: (key: String, frame: ClipStillFrame)?
    @ObservationIgnored var tileCache = ClipLookTileCache()
    @ObservationIgnored var tileKey: ClipLookTileKey?
    @ObservationIgnored var previewTask: Task<Void, Never>?
    @ObservationIgnored var tileTask: Task<Void, Never>?
    @ObservationIgnored var autoTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var generation = 0
    @ObservationIgnored fileprivate var resumesAfterCompare = false
    #if DEBUG
    /// How many times the tiles were drawn, for tests that check the cache.
    @ObservationIgnored var tileRenders = 0
    #endif

    fileprivate func show(_ next: ClipLookViewerPreview?) { preview = next }
    fileprivate func setTiles(_ next: [String: CGImage], source: ClipLookTileSource) { tiles = next; tileSource = source }
    fileprivate func setHovered(_ id: String?) { hovered = id }
    fileprivate func setComparing(_ on: Bool) { comparing = on }

    func reset() {
        previewTask?.cancel(); tileTask?.cancel(); autoTask?.cancel()
        preview = nil; hovered = nil; comparing = false; still = nil
    }

    /// `shared/looks/test-card.png`, the picture tiles show while the clip's frame is missing (spec section 7.7).
    static let testCard: CGImage? = {
        guard let shared = try? SharedResources.locate(),
              let source = CGImageSourceCreateWithURL(shared.root.appendingPathComponent("looks/test-card.png") as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()
}

/// The result of a tile's click (spec section 3.2).
enum ClipLookChoice: Equatable {
    case changed, focusAmount, unchanged
}

/// The Picture panel's commands (looks spec 2026-11-28, sections 3 and 5): each is one undo step named for what it changed,
/// announced, and refused (returning false) when it would change nothing, the clip has no picture, or the editor can't
/// edit. With no `clipID` they act on the open clip.
extension EditorModel {
    /// The open clip's look panel; nil on Full Take, without a picture, or without the looks file.
    var lookPanel: ClipLookPanel? {
        guard project.media.source.video != nil, let library = ClipLookLibrary.app, let controls = currentClipControls else { return nil }
        return ClipLookPanel(library: library, controls: controls, pick: looks.picks[controls.clipId])
    }

    private func lookPanel(for clipID: String?) -> ClipLookPanel? {
        guard project.media.source.video != nil, let library = ClipLookLibrary.app, let id = clipID ?? renderedActiveClipID,
              let controls = ClipControlsProject.controls(for: id, in: project) else { return nil }
        return ClipLookPanel(library: library, controls: controls, pick: looks.picks[id])
    }

    /// The reason every look control is disabled, as the editor's line says it (spec section 10); nil while they act.
    var lookEditReason: String? {
        if project.media.source.video == nil { return "This recording has no picture to color." }
        if mediaRelinkCandidate != nil { return "Confirm the video to change the look." }
        if !mediaUsable { return "Locate the video to change the look." }
        return capabilities.edit ? nil : "This version can't be changed."
    }

    /// A tile's click: the look at 100% (or Claude's amount for Claude's pick), keeping the Fix. The applied, unedited tile
    /// moves focus to Amount instead; an edited one gets the look's values again and keeps Amount.
    @discardableResult func chooseLook(_ id: String, clipID: String? = nil) -> ClipLookChoice {
        guard let panel = lookPanel(for: clipID), let look = panel.library.look(id) else { return .unchanged }
        var amount = 100
        switch panel.state(of: look) {
        case .applied where look.id != ClipLookPanel.original:
            looks.amountFocusRequest += 1
            return .focusAmount
        case .edited: amount = panel.amount
        default: if let pick = panel.pick, pick.look.id.rawValue == look.id { amount = pick.look.amount }
        }
        let name = look.id == ClipLookPanel.original || amount == 100 ? look.label : "\(look.label) at \(amount)%"
        return updateLook(clipID, name: "Change look", announcing: "Look \(name)") { $0.applyLook(look, amount: amount) } ? .changed : .unchanged
    }

    /// Amount, 0…100%: how much of the look shows over the Fix. Refused while there is no look to blend.
    @discardableResult func setLookAmount(_ amount: Int, clipID: String? = nil) -> Bool {
        guard let panel = lookPanel(for: clipID), panel.amountReason == nil else { return false }
        let point = min(100, max(0, amount))
        return updateLook(clipID, name: "Change look amount", announcing: "Amount \(point) percent") { controls in
            var grade = controls.colorGrade ?? ClipColorGrade()
            grade.amount = point
            controls.colorGrade = grade
        }
    }

    /// One Fine-tune slider, as an absolute value. Vibrance and Saturation are refused on a black-and-white base.
    @discardableResult func setLookSlider(_ slider: ClipLookSlider, value: Int, clipID: String? = nil) -> Bool {
        guard let panel = lookPanel(for: clipID), panel.reason(slider) == nil else { return false }
        let point = min(slider.range.upperBound, max(slider.range.lowerBound, value))
        return updateLook(clipID, name: slider.undoName, announcing: "\(slider.label) \(slider.spoken(point))") { slider.set(point, in: &$0) }
    }

    /// A group back to the look's values; the Fix back to 0.
    @discardableResult func resetLookGroup(_ group: ClipLookGroup, clipID: String? = nil) -> Bool {
        guard let panel = lookPanel(for: clipID), panel.resetReason(group) == nil else { return false }
        return updateLook(clipID, name: group.resetName, announcing: "\(group.title) reset") { controls in
            for slider in group.sliders { slider.set(panel.tick(slider), in: &controls) }
        }
    }

    /// Back to {look}: every non-Fix value back to the look's; Amount and the Fix stay.
    @discardableResult func backToLook(clipID: String? = nil) -> Bool {
        guard let panel = lookPanel(for: clipID), let origin = panel.origin, panel.backToReason == nil else { return false }
        return updateLook(clipID, name: "Back to \(origin.label)", announcing: "Back to \(origin.label)") {
            $0.applyLook(origin, amount: panel.amount)
        }
    }

    /// The toning row's Remove: the look's curve and split tone.
    @discardableResult func removeLookToning(clipID: String? = nil) -> Bool {
        updateLook(clipID, name: "Remove toning", announcing: "Toning removed") { controls in
            controls.colorGrade?.curve = nil
            controls.colorGrade?.splitTone = nil
        }
    }

    /// Clear all color: As filmed, with no adjustments and no grade, the Fix included.
    @discardableResult func clearColor(clipID: String? = nil) -> Bool {
        guard lookPanel(for: clipID)?.clearReason == nil else { return false }
        return updateLook(clipID, name: "Clear color", announcing: "Color cleared") { controls in
            controls.look = .original
            controls.colorAdjustments = nil
            controls.colorGrade = nil
        }
    }

    /// Why Fix › Auto can't act (spec section 10); nil when it can.
    func autoReason(_ panel: ClipLookPanel) -> String? {
        switch looks.auto[panel.controls.clipId] {
        case nil, .measuring?: return "Measuring the picture\u{2026}"
        case .failed?: return "VoxClip couldn't read this video's frames"
        case .measured(let fix)?:
            if fix == .neutral { return "The light and color already look even" }
            return fix == panel.fix ? "Fix matches the measurement" : nil
        }
    }

    /// Fix › Auto: Exposure, Temperature and Tint from the clip's measured frames, as one step.
    @discardableResult func fixLightAndColor(clipID: String? = nil) -> Bool {
        guard let panel = lookPanel(for: clipID), autoReason(panel) == nil, case .measured(let fix)? = looks.auto[panel.controls.clipId] else { return false }
        let spoken = [(ClipLookSlider.exposure, fix.exposure), (.temperature, fix.temperature), (.tint, fix.tint)].filter { $0.1 != 0 }
            .map { "\($0.0.rawValue) \($0.0.spoken($0.1))" }.joined(separator: ", ")
        return updateLook(clipID, name: "Fix light and color", announcing: "Fix light and color: \(spoken)") { controls in
            var grade = controls.colorGrade ?? ClipColorGrade()
            grade.fix = fix
            controls.colorGrade = grade
        }
    }

    /// Measures the clip's light for Auto once per session (spec section 5.9), from the frames the frame pass already
    /// analyses: free, on this Mac, never on the main thread.
    func measureLookFix(clipID: String? = nil) {
        guard let id = clipID ?? renderedActiveClipID, looks.auto[id] == nil || looks.auto[id] == .failed,
              let measure = ClipLookLibrary.app?.measure else { return }
        looks.auto[id] = .measuring
        looks.autoTask = Task { [weak self] in
            guard let self else { return }
            let clips = lookFrameClips(id)
            guard !clips.isEmpty, let pass = startFramePass(), let found = await pass.frames(for: clips) else {
                if looks.auto[id] == .measuring { looks.auto[id] = .failed }
                return
            }
            let frames = found.sheet.frames
            let fix = await Task.detached { FrameLightSampling.fix(frames, measure: measure) }.value
            looks.auto[id] = fix.map(ClipLookAuto.measured) ?? .failed
        }
    }

    private func lookFrameClips(_ clipID: String) -> [FrameClip] {
        guard let transcript = ProjectClock.build(project).transcript,
              let parts = project.edits.clips.first(where: { $0.id == clipID })?.playPartIndices(in: transcript.words) else { return [] }
        let cuts = Set(project.edits.cutWordIds)
        return parts.compactMap { FrameClip(words: transcript.words, first: $0.lowerBound, last: $0.upperBound, cutWordIds: cuts) }
    }

    /// The Claude line's Use it: Claude's look at its amount with its Fix, as one step.
    @discardableResult func useClaudesLook(clipID: String? = nil) -> Bool {
        guard let panel = lookPanel(for: clipID), let pick = panel.pick, let look = panel.library.look(pick.look.id.rawValue) else { return false }
        return updateLook(clipID, name: "Use Claude's look", announcing: "Look \(EditorModel.makeItLookName(look, amount: pick.look.amount))") {
            $0.applyLook(look, amount: pick.look.amount, fix: pick.fix)
        }
    }

    /// One colour change on a clip with a picture. A grade the change creates or keeps carries the look it came from as its
    /// `preset`, so the Look row reads "{look}, edited" rather than Custom; a neutral grade or adjustment is removed.
    @discardableResult private func updateLook(_ clipID: String?, name: String, announcing message: String,
                                               _ change: (inout ProjectClipControls) -> Void) -> Bool {
        guard project.media.source.video != nil, let library = ClipLookLibrary.app else { return false }
        let origin = (clipID ?? renderedActiveClipID).flatMap { ClipControlsProject.controls(for: $0, in: project) }
            .flatMap { library.match($0)?.look }
        let changed = updateClipControls(clipID, name: name, announcing: message) { controls in
            change(&controls)
            if var grade = controls.colorGrade {
                if grade.preset == nil, let origin, origin.id != ClipLookPanel.original, !ClipLookPanel.lookPartNeutral(controls) {
                    grade.preset = origin.id
                }
                controls.colorGrade = grade.isNeutral ? nil : grade
            }
        }
        if changed { looks.show(nil) }
        return changed
    }

    // MARK: Previews (spec sections 3.4 and 7.8)

    /// Hover and keyboard previews, Compare and drags work while the video can be read; never during playback for hover.
    var lookPreviewsAvailable: Bool { project.media.source.video != nil && mediaResolved && !mediaUnreadable }

    /// The paused frame, captured once per project revision and player time.
    func lookStill() async throws -> ClipStillFrame? {
        if let stills = looks.stills { return try await stills(self) }
        guard let native = nativePreview else { return nil }
        let key = "\(projectRevision):\(renderedActiveClipID ?? ""):\(native.player.currentTime().seconds)"
        if let still = looks.still, still.key == key { return still.frame }
        guard let frame = try await native.stillFrame() else { return nil }
        looks.still = (key, frame)
        return frame
    }

    /// A tile's look on the viewer at 100% with the clip's Fix, badged "Preview · {look}"; nil ends the preview. Nothing
    /// happens during playback.
    func previewLook(_ id: String?) {
        guard let id else {
            looks.setHovered(nil)
            if !looks.comparing { endLookPreview() }
            return
        }
        guard !isPlaying, lookPreviewsAvailable, let panel = lookPanel, let look = panel.library.look(id) else { return }
        looks.setHovered(id)
        var controls = panel.controls
        controls.applyLook(look, amount: 100)
        showLookStill(controls, badge: "Preview \u{00B7} \(look.label)")
    }

    /// A drag's values on the paused viewer; nil ends it (the release commits and reloads, as today).
    func previewLookDraft(_ controls: ProjectClipControls?) {
        guard let controls else { endLookPreview(); return }
        guard !isPlaying, lookPreviewsAvailable else { return }
        showLookStill(controls, badge: nil)
    }

    /// Hold Compare (the button, the backslash key or View › Compare with As Filmed): As filmed on the viewer, playback
    /// paused while held and resumed on release.
    func setLookCompare(_ on: Bool) {
        guard on != looks.comparing else { return }
        if on {
            guard lookPreviewsAvailable, let panel = lookPanel, panel.compareReason == nil else { return }
            if isPlaying { preview.pause(); isPlaying = false; looks.resumesAfterCompare = true }
            looks.setComparing(true)
            announce("Showing as filmed")
            showLookStill(nil, badge: "As filmed")
        } else {
            looks.setComparing(false)
            endLookPreview()
            if let panel = lookPanel { announce("Showing \(panel.lookName)") }
            if looks.resumesAfterCompare { looks.resumesAfterCompare = false; preview.play(); isPlaying = preview.isPlaying }
        }
    }

    func endLookPreview() {
        looks.generation += 1
        looks.previewTask?.cancel()
        looks.show(nil)
    }

    /// `colour` nil is As filmed.
    private func showLookStill(_ colour: ProjectClipControls?, badge: String?) {
        looks.generation += 1
        let generation = looks.generation
        looks.previewTask?.cancel()
        guard let clipID = renderedActiveClipID else { return }
        looks.previewTask = Task { [weak self] in
            guard let self, let still = try? await lookStill(), !Task.isCancelled,
                  let image = try? await still.still(colorOf: colour), generation == looks.generation else { return }
            looks.show(ClipLookViewerPreview(clipID: clipID, image: image, badge: badge))
        }
    }

    // MARK: Tiles (spec section 7)

    /// The open clip's tiles at `pixels` (2× the tile's points, at most 144): each look at 100% with the clip's Fix on the
    /// paused frame before the grade, or on the test card while there is none. Cached per clip, still, framing and Fix, so
    /// choosing a look draws nothing again. `first` render before the rest.
    func refreshLookTiles(pixels: Int, first: [String] = []) {
        guard let panel = lookPanel else { return }
        let size = min(144, max(16, pixels))
        looks.tileTask?.cancel()
        looks.tileTask = Task { [weak self] in
            guard let self else { return }
            guard lookPreviewsAvailable else {
                await drawLookTiles(panel, still: nil, source: .sample("Previews need the source video. Looks still apply when it's back."),
                                    pixels: size, first: first)
                return
            }
            var still: ClipStillFrame?
            do { still = try await lookStill() } catch {
                await drawLookTiles(panel, still: nil, source: .sample("Showing looks on a sample picture: this frame couldn't be read."),
                                    pixels: size, first: first)
                return
            }
            if still == nil, looks.stills == nil, nativePreview != nil {
                // The player has no item yet: the test card until it has one (spec section 7.7).
                await drawLookTiles(panel, still: nil, source: .sample(nil), pixels: size, first: first)
                for _ in 0..<20 where still == nil && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    still = try? await lookStill()
                }
            }
            await drawLookTiles(panel, still: still, source: still == nil ? .sample(nil) : .frame, pixels: size, first: first)
        }
    }

    /// Draws the tiles of `panel`'s clip from `still` (the test card when nil), unless the cache has them; `first` first.
    private func drawLookTiles(_ panel: ClipLookPanel, still: ClipStillFrame?, source: ClipLookTileSource, pixels size: Int, first: [String]) async {
        guard !Task.isCancelled, let controls = currentClipControls, controls.clipId == panel.controls.clipId else { return }
        let key = ClipLookTileKey(clipID: controls.clipId, stillTime: still?.renderedTime.seconds, controls: controls, pixels: size,
                                  library: panel.library)
        if let cached = looks.tileCache.tiles(key) {
            looks.tileKey = key
            looks.setTiles(cached, source: source)
            return
        }
        let order = first + panel.library.visible.map(\.id).filter { !first.contains($0) }
        let looksByID = order.compactMap { id in panel.library.look(id).map { (id, $0) } }
        let center = Self.tileCenter(controls)
        let card = ClipLookState.testCard
        var drawn: [String: CGImage] = [:]
        let split = first.isEmpty ? looksByID.count : min(looksByID.count, first.count)
        for batch in [Array(looksByID.prefix(split)), Array(looksByID.dropFirst(split))] where !batch.isEmpty {
            let jobs = batch.map { id, look -> (String, ProjectClipControls) in
                var tile = controls
                tile.applyLook(look, amount: 100)
                return (id, tile)
            }
            let images = await Task.detached(priority: .userInitiated) { () -> [(String, CGImage)] in
                jobs.compactMap { id, tile in
                    if Task.isCancelled { return nil }
                    let image = if let still { try? still.tile(controls: tile, center: center, pixels: size) }
                                else { card.flatMap { try? ClipStillFrame.tile(of: $0, controls: tile, center: nil, pixels: size) } }
                    return image.map { (id, $0) }
                }
            }.value
            guard !Task.isCancelled else { return }
            for (id, image) in images { drawn[id] = image }
            looks.setTiles(drawn, source: source)
        }
        #if DEBUG
        looks.tileRenders += 1
        #endif
        looks.tileKey = key
        looks.tileCache.store(drawn, for: key)
    }

    /// The tile square's centre in the output frame, from the top left: the stored face anchor, else the middle.
    static func tileCenter(_ controls: ProjectClipControls) -> (x: Double, y: Double)? {
        guard let reframe = controls.reframe, reframe.mode == ReframeSettings.faceMode, let x = reframe.centerX, let y = reframe.centerY else { return nil }
        let anchor = controls.mapAnchor(x: x, y: y)
        return (anchor.x, anchor.y)
    }
}
