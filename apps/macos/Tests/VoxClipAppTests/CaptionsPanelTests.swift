#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The Captions job (impl-plan V5, ux/v2 notes.md §7, f1): the STYLE row and its switch, a
/// 3-column gallery of 40 pt tiles that all show "and one cool", every style in the library's
/// order with no group headers, two rows at 1280 × 800 and the rest scrolling, then 24 pt
/// property rows and Fine tune behind a disclosure. Nothing is shown and settings are never
/// saved, so nothing is written.
@Suite("Captions job", .serialized)
@MainActor struct CaptionsPanelTests {
    private typealias Metrics = CaptionsPanelMetrics
    /// The "Five questions" fixture, 16:9.
    private func project() throws -> Project {
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        project.export.aspect = .landscape
        project.captions.styleId = "box-highlight"
        return project
    }
    private func openShell() async throws -> (WorkspaceShell, EditorModel) {
        _ = NSApplication.shared
        let app = AppModel()
        app.loadCatalogue()
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try project(), demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        #expect(app.styles.count == 19)
        return (shell, editor)
    }
    /// `content` laid out offscreen at `size`, settled until every tile and the property rows are placed.
    private func host(_ content: some View, size: CGSize) async -> NSView {
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            let markers = DebugRightColumn.markers(in: host)
            if markers.keys.filter({ $0.hasPrefix("caption.image.") }).count == 19, markers["captions.property.fineTune"] != nil { break }
            await Task.yield()
        }
        host.layoutSubtreeIfNeeded()
        return host
    }
    /// The system's Always preference must not let a native scrollbar cross the column edge.
    @Test(arguments: [CGSize(width: 404, height: 522), CGSize(width: 324, height: 322)])
    func legacyCaptionScrollersStayInsideTheColumn(size: CGSize) async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let view = await host(PanelHost(model: editor, shell: shell, width: size.width, height: size.height, fineTune: true), size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let scrolls = DebugRightColumn.scrollViews(in: view)
        #expect(scrolls.count == 2)
        for scroll in scrolls {
            scroll.scrollerStyle = .legacy
            scroll.autohidesScrollers = false
            scroll.tile()
        }
        view.layoutSubtreeIfNeeded()
        #expect(DebugColumnBounds.scrollerOverflow(in: view).isEmpty,
                Comment(rawValue: DebugColumnBounds.scrollerOverflow(in: view).joined(separator: "; ")))
    }

    private func gallery(_ markers: [String: CGRect]) throws -> CGRect {
        try #require(markers.first { $0.key.hasPrefix("caption.gallery.") }?.value)
    }
    private func near(_ a: CGRect?, _ b: CGRect, _ tolerance: CGFloat = 0.5) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: Geometry

    /// notes.md §1 and §7 at 1280 × 800: a 265 pt body is the 30 pt STYLE row, two rows of
    /// tiles (128) and the property rows (107). Shorter bodies keep the first row and two
    /// property rows; Fine tune takes the gallery down to one row.
    @Test func theBodyIsSharedAsF1SharesIt() {
        #expect(Metrics.top == 30)
        #expect(Metrics.twoRows == 128)
        #expect(Metrics.properties == 107)
        #expect(Metrics.top + Metrics.twoRows + Metrics.properties == 265)
        #expect(abs(Metrics.tileWidth(panelWidth: 404) - 118.667) < 0.001)
        #expect(Metrics.tileWidth(panelWidth: 300) == 84)
        #expect(abs(Metrics.tileWidth(panelWidth: 560) - 170.667) < 0.001)
        #expect(Metrics.galleryWidth(panelWidth: 404) == 378)
        #expect(abs(Metrics.tileWidth(galleryWidth: Metrics.galleryWidth(panelWidth: 404)) - 118.667) < 0.001)
        // A 17 pt legacy scroller takes its width from the tiles (the scroll view gives them 361).
        #expect(Metrics.tileWidth(galleryWidth: 361) == 113)
        func split(_ body: CGFloat, _ properties: CGFloat = Metrics.properties, fineTune: Bool = false) -> [CGFloat] {
            let split = Metrics.split(available: body - Metrics.top, properties: properties, fineTune: fineTune)
            return [split.gallery, split.properties]
        }
        #expect(split(265) == [128, 107], "1280 × 800")
        #expect(split(342) == [205, 107], "1440 × 900: the gallery takes the rest")
        #expect(split(165) == [82, 53], "1280 × 700: the first row and two property rows")
        #expect(split(160) == [77, 53], "960 × 600")
        #expect(split(265, 240, fineTune: true) == [64, 171], "Fine tune open: one row of tiles")
        #expect(split(70) == [40, 0], "shorter than one row: the gallery takes it all")
    }

    /// f1's right column at 1280 × 800 (404 × 522): the body starts at 257 under the viewer and
    /// its header; STYLE 20 under it; three 118.67 × 40 tiles from 16 to 388, 8 apart, their
    /// names 4 under them; the second row 6 under the first's names; then the hairline and the
    /// four 24 pt rows.
    @Test func theCaptionsBodyMatchesF1() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let view = await host(PanelHost(model: editor, shell: shell, width: 404, height: 522), size: CGSize(width: 404, height: 522))
        let markers = DebugRightColumn.markers(in: view)
        let body: CGFloat = 227 + 30
        #expect(near(markers["panel.body"], CGRect(x: 0, y: body, width: 404, height: 265)))
        #expect(near(markers["captions.style"], CGRect(x: 16, y: body + 10, width: 372, height: 20)))
        let heading = try #require(markers["header.captions.heading"]), toggle = try #require(markers["header.captions.switch"])
        #expect(abs(heading.midY - (body + 20)) <= 0.5 && abs(toggle.midY - (body + 20)) <= 0.5 && abs(toggle.maxX - 388) <= 0.5)
        // The gallery's frame inside the padding; its scroll view reaches 3 past it for the rings.
        #expect(near(try gallery(markers), CGRect(x: 16, y: body + 30, width: 372, height: 128)))
        let order = CaptionsSection.galleryOrder(editor.app.styles).map(\.id)
        let width = Metrics.tileWidth(panelWidth: 404)
        for (index, id) in order.prefix(6).enumerated() {
            let x = 16 + CGFloat(index % 3) * (width + 8), y = body + 36 + CGFloat(index / 3) * (58 + 6)
            // An offscreen host lays its views on whole points, so a 118.67 column is 118 or 119.
            #expect(near(markers["caption.image.\(id)"], CGRect(x: x, y: y, width: width, height: 40), 1), Comment(rawValue: "\(id) \(String(describing: markers["caption.image.\(id)"]))"))
            #expect(near(markers["caption.name.\(id)"], CGRect(x: x, y: y + 44, width: width, height: 14), 1), Comment(rawValue: id))
        }
        #expect(near(markers["captions.properties"], CGRect(x: 0, y: body + 158, width: 404, height: 107)))
        for (index, row) in ["words", "case", "position", "fineTune"].enumerated() {
            #expect(near(markers["captions.property.\(row)"], CGRect(x: 16, y: body + 158 + 5 + CGFloat(index) * 24, width: 372, height: 24)), Comment(rawValue: row))
        }
    }

    /// The 960 × 600 window minimum leaves the column 324 × 322 and the body 160 (V4's
    /// `bodyMinimum`): the STYLE row, the first row of tiles whole, and Words per caption.
    @Test func theShortestBodyKeepsTheStyleRowAndTheFirstRow() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let view = await host(PanelHost(model: editor, shell: shell, width: 324, height: 322), size: CGSize(width: 324, height: 322))
        let markers = DebugRightColumn.markers(in: view)
        let body: CGFloat = 132 + 30
        #expect(near(markers["panel.body"], CGRect(x: 0, y: body, width: 324, height: 160)))
        let viewport = try gallery(markers)
        #expect(abs(viewport.minY - (body + 30)) <= 0.5 && abs(viewport.height - 77) <= 0.5, Comment(rawValue: "\(viewport)"))
        for id in CaptionsSection.galleryOrder(editor.app.styles).prefix(3).map(\.id) {
            #expect(markers["caption.image.\(id)"].map { viewport.contains($0) } == true, Comment(rawValue: id))
            #expect(markers["caption.name.\(id)"].map { viewport.contains($0) } == true, Comment(rawValue: id))
        }
        let properties = try #require(markers["captions.properties"])
        #expect(abs(properties.minY - viewport.maxY) <= 0.5 && abs(properties.maxY - 322) <= 0.5)
        #expect(markers["captions.property.words"].map { properties.insetBy(dx: -0.5, dy: -0.5).contains($0) } == true)
    }

    /// A caption error sits under the STYLE row, above the gallery, which still scrolls under it.
    @Test func aCaptionErrorStaysAboveTheGallery() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        editor.captionError = "Captions couldn't be drawn. Your media and edits are safe. Choose another style or try again."
        let view = await host(PanelHost(model: editor, shell: shell, width: 404, height: 522), size: CGSize(width: 404, height: 522))
        let markers = DebugRightColumn.markers(in: view)
        let error = try #require(markers["caption.error"]), viewport = try gallery(markers)
        #expect(error.minY >= 257 + 30 - 0.5 && abs(error.maxY - viewport.minY) <= 0.5, Comment(rawValue: "\(error) \(viewport)"))
        #expect(viewport.height >= Metrics.oneRow - 0.5)
    }

    // MARK: Tiles

    /// Every style is a tile, in the library's order (captions §15.1), named under it, with no
    /// group headers; only the selected one has the ring, 1 pt outside its tile.
    @Test func everyStyleIsANamedTileInTheLibrarysOrderWithNoHeaders() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let view = await host(PanelHost(model: editor, shell: shell, width: 404, height: 4096), size: CGSize(width: 404, height: 4096))
        let markers = DebugRightColumn.markers(in: view), texts = DebugRightColumn.texts(in: view)
        let order = CaptionsSection.galleryOrder(editor.app.styles)
        #expect(order.map(\.order) == order.map(\.order).sorted())
        #expect(order.first?.id == "vox-bold" && order.last?.id == "vhs")
        let tiles = markers.filter { $0.key.hasPrefix("caption.image.") }
        #expect(tiles.count == 19)
        let placed = tiles.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }.map { String($0.key.dropFirst("caption.image.".count)) }
        #expect(placed == order.map(\.id))
        for style in order { #expect(texts["caption.name.\(style.id)"] == style.name) }
        #expect(!markers.keys.contains { $0.hasPrefix("caption.group.") })
        let rings = markers.filter { $0.key.hasPrefix("caption.ring.") }
        #expect(rings.keys.sorted() == ["caption.ring.box-highlight"])
        let tile = try #require(markers["caption.image.box-highlight"])
        #expect(near(rings.values.first, tile.insetBy(dx: -1, dy: -1)))
    }

    /// notes.md §7: every tile draws "and one cool" (so only the style changes) in its key word,
    /// "cool", on the one-line surface that draws plates. Only the selected style takes the
    /// project's overrides, and nothing else moves a tile: not the playhead, not the scope.
    @Test func everyTileShowsTheSamePhrase() async throws {
        let (_, editor) = try await openShell()
        defer { editor.close() }
        let width = Metrics.tileWidth(panelWidth: 404)
        var project = editor.project
        project.captions.overrides = ["accent": .string("#4BE38A")]
        editor.replace(project, name: "Fine tune captions")
        let inputs = editor.app.styles.map { editor.captionTileInput($0, width: width) }
        for input in inputs {
            #expect(input.text.words.map(\.text) == ["and", "one", "cool"])
            #expect(input.text.keyIndex == 2 && input.language == "en" && input.previewBackground == nil)
            #expect(input.fit == CardFit.galleryTile(width: width) && input.fit.width == 236 && input.fit.height == 80)
            #expect(input.fit.surface.lineLimit == 1 && input.fit.surface.drawsPlates)
            #expect(input.overrides == (input.style.id == "box-highlight" ? project.captions.overrides : [:]), Comment(rawValue: input.style.id))
        }
        // A style that reveals by character is drawn at its last word's end, so it shows whole.
        #expect(inputs.first { $0.style.id == "typewriter" }?.text.drawsAtLastWord == true)
        editor.playhead = 12.5
        let clip = try #require(editor.keptClips.first)
        #expect(editor.setScope(clip.id))
        #expect(editor.app.styles.map { editor.captionTileInput($0, width: width) } == inputs)
    }

    /// Every style's tile, drawn by the caption card renderer in the narrowest, the 1280 and the
    /// widest column, inks its phrase legibly and keeps clear of the tile's edges.
    @Test func everyTileDrawsItsPhraseInsideTheTile() async throws {
        let (_, editor) = try await openShell()
        defer { editor.close() }
        for column: CGFloat in [300, 404, 560] {
            for style in editor.app.styles {
                let input = editor.captionTileInput(style, width: Metrics.tileWidth(panelWidth: column))
                let image = try #require(await editor.app.captions.card(input), Comment(rawValue: style.id))
                #expect(image.width == input.fit.width && image.height == 80)
                let bitmap = try #require(DebugCaptionsSection.tileBitmap(image, width: input.fit.width / 2, height: 40))
                let glyph = DebugCaptionsSection.glyphPixelHeight(bitmap)
                #expect(glyph >= DebugCaptionsSection.minimumTileGlyph(width: Metrics.tileWidth(panelWidth: column)), Comment(rawValue: "\(style.id) at \(column): \(glyph)"))
                #expect(!DebugCaptionsSection.edgeHasGlyph(bitmap), Comment(rawValue: "\(style.id) at \(column)"))
            }
        }
    }

    // MARK: Controls

    /// The switch reads its state ("On", "Off") and stays one control when captions turn off.
    @Test func theSwitchReadsItsState() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let size = CGSize(width: 404, height: 522)
        let on = DebugRightColumn.texts(in: await host(PanelHost(model: editor, shell: shell, width: 404, height: 522), size: size))
        #expect(on["header.captions.switch"] == "On" && on["header.captions.heading"] == "STYLE")
        editor.setCaptionsEnabled(false)
        let offView = await host(PanelHost(model: editor, shell: shell, width: 404, height: 522), size: size)
        #expect(DebugRightColumn.texts(in: offView)["header.captions.switch"] == "Off")
        #expect(!DebugRightColumn.markers(in: offView).keys.contains { $0.hasPrefix("caption.ring.") })
    }

    /// The property rows show the current values: the style's own words on screen as
    /// "Up to {n}", its case, and the position.
    @Test func thePropertyRowsShowTheCurrentValues() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        #expect(CaptionsSection.wordsLabel(1) == "1 word" && CaptionsSection.wordsLabel(5) == "Up to 5" && CaptionsSection.wordsLabel(16) == "Line")
        let size = CGSize(width: 404, height: 522)
        let before = DebugRightColumn.texts(in: await host(PanelHost(model: editor, shell: shell, width: 404, height: 522), size: size))
        #expect(before["captions.value.Words per caption"] == "Up to 4")
        #expect(before["captions.value.Case"] == "ALL CAPS")
        #expect(before["captions.value.Position"] == "Bottom")
        var project = editor.project
        project.captions.overrides = ["layout": .object(["maxWords": .number(3), "maxLines": .number(1)]), "text": .object(["transform": .string("none")])]
        editor.replace(project, name: "Fine tune captions")
        let after = DebugRightColumn.texts(in: await host(PanelHost(model: editor, shell: shell, width: 404, height: 522), size: size))
        #expect(after["captions.value.Words per caption"] == "Up to 3")
        #expect(after["captions.value.Case"] == "As said")
        #expect(after["captions.property.fineTune"] == "Fine tune")
    }

    // MARK: Keyboard

    /// Arrow keys in the gallery move as in a three-column radio group: left and right through
    /// the order, up and down by a row, nothing past an edge, the first style from none.
    @Test func arrowKeysStepThroughTheGrid() {
        func move(_ index: Int?, _ key: KeyEquivalent) -> Int? { CaptionGalleryNavigation.target(from: index, count: 19, key: key) }
        #expect(move(0, .rightArrow) == 1)
        #expect(move(4, .leftArrow) == 3)
        #expect(move(2, .downArrow) == 5)
        #expect(move(5, .upArrow) == 2)
        #expect(move(0, .leftArrow) == nil && move(1, .upArrow) == nil)
        #expect(move(18, .rightArrow) == nil && move(16, .downArrow) == nil)
        #expect(move(15, .downArrow) == 18)
        #expect(move(nil, .downArrow) == 0 && move(nil, .leftArrow) == 0)
        #expect(move(3, .return) == nil)
        #expect(CaptionGalleryNavigation.target(from: nil, count: 0, key: .rightArrow) == nil)
    }

    /// With the gallery focused in a window, the arrow keys choose the neighbouring style, each
    /// as one undo step, and the selected tile shows the keyboard focus ring.
    @Test func arrowKeysInTheFocusedGalleryChooseTheNeighbour() async throws {
        let (_, editor) = try await openShell()
        defer { editor.close() }
        let undo = UndoManager(); undo.groupsByEvent = false
        editor.undoManager = undo
        let order = CaptionsSection.galleryOrder(editor.app.styles).map(\.id)
        let start = try #require(order.firstIndex(of: "box-highlight"))
        let (window, view) = galleryWindow(editor)
        defer { window.close() }
        let identifier = try await galleryIdentifier(view)
        NotificationCenter.default.post(name: CaptionGalleryAudit.notification, object: identifier, userInfo: ["focus": true])
        #expect(await settle(view) { snapshot(identifier)?.focused == true })
        // One undo group per key, as the run loop makes one per event.
        undo.beginUndoGrouping()
        press(.rightArrow, in: window)
        #expect(await settle(view) { editor.project.captions.styleId == order[start + 1] }, Comment(rawValue: editor.project.captions.styleId))
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        press(.downArrow, in: window)
        #expect(await settle(view) { editor.project.captions.styleId == order[start + 4] }, Comment(rawValue: editor.project.captions.styleId))
        undo.endUndoGrouping()
        #expect(await settle(view) { DebugRightColumn.markers(in: view)["caption.focus.\(order[start + 4])"] != nil })
        undo.undo()
        #expect(editor.project.captions.styleId == order[start + 1])
        undo.undo()
        #expect(editor.project.captions.styleId == "box-highlight")
    }

    /// Fine tune scrolls on its own under the gallery, so the reveal rules hold with it open:
    /// a new style reveals its tile, and opening or closing Fine tune reveals the selected one.
    @Test func theRevealRulesHoldWithFineTuneOpen() {
        for result in DebugCaptionsSection.revealPolicyChecks() { #expect(result.passed, Comment(rawValue: result.name)) }
    }

    /// At 1280 × 800 opening Fine tune leaves the gallery one row (64). The selected tile, in
    /// the second row, is revealed in it, and so is each style the arrow keys then choose, a row
    /// down and across a row's end, so the tile that previews the edits never leaves the view.
    @Test func withFineTuneOpenTheSelectedTileStaysInView() async throws {
        let (_, editor) = try await openShell()
        defer { editor.close() }
        let order = CaptionsSection.galleryOrder(editor.app.styles).map(\.id)
        let start = try #require(order.firstIndex(of: "box-highlight"))
        #expect(start / Metrics.columns == 1 && start % Metrics.columns == 2, "the last tile of the second row")
        let (window, view) = galleryWindow(editor)
        defer { window.close() }
        let identifier = try await galleryIdentifier(view)
        /// The selected tile, ring included, lies inside the gallery's viewport: in the reveal's
        /// own geometry and in the window's laid-out views.
        func shown(_ style: String) -> Bool {
            guard let state = snapshot(identifier), let paint = state.paint, state.consumed, !state.pending,
                  state.selectedStyle == style, state.paintStyle == style, state.visible.height > 0 else { return false }
            let markers = DebugRightColumn.markers(in: view)
            guard let gallery = markers["caption.gallery.\(identifier)"], let target = markers["caption.target.\(style)"] else { return false }
            return state.visible.insetBy(dx: -0.5, dy: -0.5).contains(paint)
                && gallery.insetBy(dx: -Metrics.ringReserve - 0.5, dy: -0.5).contains(target.insetBy(dx: -Metrics.ringReserve, dy: 0))
        }
        func describe() -> Comment { Comment(rawValue: "\(editor.project.captions.styleId): \(String(describing: snapshot(identifier)))") }
        #expect(await settle(view) { shown("box-highlight") }, describe())
        NotificationCenter.default.post(name: CaptionGalleryAudit.notification, object: identifier, userInfo: ["fineTune": true])
        #expect(await settle(view) {
            guard let state = snapshot(identifier) else { return false }
            return state.fineTune && abs(state.size.height - Metrics.oneRow) <= 0.5 && shown("box-highlight")
        }, describe())
        NotificationCenter.default.post(name: CaptionGalleryAudit.notification, object: identifier, userInfo: ["focus": true])
        #expect(await settle(view) { snapshot(identifier)?.focused == true })
        press(.downArrow, in: window)
        #expect(await settle(view) { shown(order[start + Metrics.columns]) }, describe())
        press(.rightArrow, in: window)
        #expect(await settle(view) { shown(order[start + Metrics.columns + 1]) }, describe())
        #expect(snapshot(identifier)?.fineTune == true)
    }

    /// The Captions body at 1280 × 800 (404 × 265) in a borderless window that is never shown.
    private func galleryWindow(_ editor: EditorModel) -> (NSWindow, NSView) {
        let view = NSHostingView(rootView: CaptionsSection(model: editor, width: 404).frame(width: 404, height: 265))
        view.frame = CGRect(x: 0, y: 0, width: 404, height: 265)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        _ = window.makeFirstResponder(view)
        return (window, view)
    }
    /// Sends an arrow key's key-down to `window`, as the keyboard does.
    private func press(_ key: KeyEquivalent, in window: NSWindow) {
        let (code, character): (UInt16, Int) = switch key {
        case .leftArrow: (123, NSLeftArrowFunctionKey)
        case .rightArrow: (124, NSRightArrowFunctionKey)
        case .downArrow: (125, NSDownArrowFunctionKey)
        default: (126, NSUpArrowFunctionKey)
        }
        let characters = String(Character(UnicodeScalar(character)!))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: code)
        if let event { window.sendEvent(event) }
    }
    private func galleryIdentifier(_ view: NSView) async throws -> String {
        var key: String?
        _ = await settle(view) {
            key = DebugRightColumn.markers(in: view).keys.first { $0.hasPrefix("caption.gallery.") }
            return key != nil
        }
        return String(try #require(key).dropFirst("caption.gallery.".count))
    }
    private func snapshot(_ identifier: String) -> CaptionGalleryAudit.Snapshot? {
        NotificationCenter.default.post(name: CaptionGalleryAudit.notification, object: identifier, userInfo: ["snapshot": true])
        return CaptionGalleryAudit.snapshots[identifier]
    }
    /// Lays `view` out until `done` holds, giving SwiftUI up to 200 turns to apply a change.
    private func settle(_ view: NSView, until done: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            view.layoutSubtreeIfNeeded()
            if done() { return true }
            await Task.yield()
        }
        return done()
    }
}
#endif
