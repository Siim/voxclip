#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Settings for an editor in a temporary data folder: nothing loads or saves.
private actor TimelineTestSettings: SettingsStore {
    func load() async throws -> SettingsDocument { SettingsDocument(values: ["update.autoCheck": .bool(false)]) }
    func save(_ settings: SettingsDocument) async throws {}
    func flush() async throws {}
}

/// The v2 timeline's app side (impl-plan V7a): the viewport, the lanes following the model
/// without redrawing on a playhead tick, Show cuts as a view setting and the model-owned
/// waveform. No window is shown; each test has its own data folder.
@Suite("v2 timeline", .serialized, .offlineFixtures)
@MainActor struct TimelineCanvasTests {
    @Test func soundFadePreviewsAndCommitsOnce() throws {
        var fixture = try project()
        fixture.clipEffects = [.init(id: "sound", clipId: fixture.edits.activeClipId, kind: .sound,
            start: 11, end: 13, sound: .init(source: .bundled, id: "pop", durationSeconds: 2, title: "Pop", license: "cc0"), gainDb: -20)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let fragment = try #require(canvas.itemFragments.first { $0.display.item.id == .effect("sound") })
        let grip = try #require(fragment.fadeGrip(.start))
        let start = NSPoint(x: grip.midX, y: grip.midY)
        let end = NSPoint(x: start.x + 0.8 * canvas.viewport.ptPerSecond, y: start.y)
        canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas))
        #expect(model.timelineItemRefusal == nil)
        #expect(canvas.itemOverlay.preview?.readout == "Fade in 0.8 s")
        #expect(!undo.canUndo)
        canvas.keyDown(with: try timelineKey(53))
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas))
        #expect(model.project == fixture && !undo.canUndo && canvas.itemOverlay.preview == nil)
        canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas))
        undo.beginUndoGrouping()
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas))
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Fade sound" && model.undoSteps == 1)
        #expect(model.project.clipEffects.first?.fadeInSeconds == 0.8)
    }

    private enum MusicDrag: CaseIterable { case fade, volume, keyframe, dip, gripSlip, modifierSlip, loop }

    private func projectWithMusic(segmented: Bool = true) throws -> Project {
        var fixture = try project()
        let asset = MusicAsset(file: "\(fixture.id)/music-night.wav", sha256: String(repeating: "a", count: 64), durationSeconds: 46)
        let segment = MusicSegment(id: "music", anchorSeconds: 11, lengthSeconds: 4, songFromSeconds: 42,
                                   loop: true, fadeInSeconds: 0, fadeOutSeconds: 0)
        fixture.music = [.init(id: "music", clipId: fixture.edits.activeClipId, asset: asset, source: .file, title: "Night Drive",
                               license: .own, gainDb: -30, fadeInSeconds: 0, fadeOutSeconds: 0, startOffsetSeconds: 42,
                               segments: segmented ? [segment] : nil)]
        return fixture
    }

    @Test(arguments: MusicDrag.allCases) private func musicDragPreviewsCancelsAndCommitsOnce(_ gesture: MusicDrag) throws {
        var fixture = try projectWithMusic(segmented: gesture != .volume)
        if gesture == .keyframe { fixture.music[0].segments?[0].gainPoints = [.init(t: 1, db: 0)] }
        let app = try app(), model = editor(app, project: fixture)
        let shell = WorkspaceShell(app: app)
        shell.layout.trackHeight = .large
        let (canvas, window) = windowed(model, shell: shell)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        model.timelineSnapping = false
        let id = TimelineItemID.music("music")
        let item = try #require(canvas.content.items.first { $0.item.id == id })
        canvas.selectAndRevealItem(item)
        let fragment = try #require(canvas.itemFragments.first { $0.display.item.id == id })
        let rect = fragment.rect
        let scale = canvas.viewport.ptPerSecond
        let line = fragment.volumeY(-30)
        var flags: NSEvent.ModifierFlags = []
        let start: NSPoint, end: NSPoint, name: String, readout: String
        switch gesture {
        case .fade:
            let grip = try #require(fragment.fadeGrip(.start))
            start = .init(x: grip.midX, y: grip.midY); end = .init(x: start.x + 0.8 * scale, y: start.y)
            name = "Fade music"; readout = "Fade in 0.8 s"
        case .volume:
            start = .init(x: rect.midX, y: line); end = .init(x: start.x, y: line - 12.5 / fragment.dbPerPoint)
            name = "Change volume"; readout = "−17.5 dB"
        case .keyframe:
            start = try #require(fragment.volumePoints.first?.center)
            end = .init(x: start.x + 0.5 * scale, y: line - 10 / fragment.dbPerPoint)
            name = "Move volume keyframe"; readout = "−20.0 dB"
        case .dip:
            start = .init(x: rect.midX, y: line); end = .init(x: start.x, y: line + 8 / fragment.dbPerPoint)
            name = "Dip volume"
            readout = "\(timelineItemTime(fragment.range.start + 1))–\(timelineItemTime(fragment.range.start + 3)) · −8.0 dB"
        case .gripSlip, .modifierSlip:
            if gesture == .gripSlip {
                let grip = try #require(fragment.slipGrip)
                start = .init(x: grip.midX, y: grip.midY)
            } else {
                flags = [.option, .command]
                start = .init(x: rect.midX, y: rect.midY)
            }
            end = .init(x: start.x + 2.5 * scale, y: start.y)
            name = "Slip music"; readout = "Slip +0:02.5 · song 0:42.0 → 0:44.5"
        case .loop:
            start = .init(x: rect.maxX - 1, y: rect.midY); end = .init(x: start.x + 4 * scale, y: start.y)
            name = "Trim music"; readout = "∞ 1 loop · 8.0 s"
        }
        func selectDipRange(cancel: Bool = false) throws {
            let lower = NSPoint(x: rect.minX + scale, y: rect.maxY - 1)
            let upper = NSPoint(x: rect.minX + 3 * scale, y: lower.y)
            canvas.mouseDown(with: try mouse(.leftMouseDown, lower, in: canvas))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, upper, in: canvas))
            #expect(canvas.itemOverlay.preview != nil)
            if cancel { canvas.keyDown(with: try timelineKey(53)) }
            canvas.mouseUp(with: try mouse(.leftMouseUp, upper, in: canvas))
            #expect(!undo.canUndo && canvas.itemOverlay.audioSelection.isEmpty == cancel)
        }
        func begin() throws {
            if gesture == .dip { try selectDipRange() }
            canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas, flags: flags))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas, flags: flags))
            #expect(canvas.itemOverlay.preview?.readout == readout)
            #expect(model.project == fixture && !undo.canUndo)
        }
        if gesture == .dip { try selectDipRange(cancel: true) }
        try begin()
        canvas.keyDown(with: try timelineKey(53))
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas, flags: flags))
        #expect(model.project == fixture && !undo.canUndo && canvas.itemOverlay.preview == nil)
        try begin()
        undo.beginUndoGrouping()
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas, flags: flags))
        undo.endUndoGrouping()
        #expect(model.timelineItemRefusal == nil)
        #expect(undo.undoActionName == name && model.undoSteps == 1)
        if gesture == .volume {
            // Track level only: the bed stays one continuous bed that follows the clip.
            #expect(model.currentMusic?.gainDb == -17.5 && model.currentMusic?.segments == nil)
        } else {
            let segment = try #require(model.currentMusic?.segments?.first)
            switch gesture {
            case .fade: #expect(segment.fadeInSeconds == 0.8)
            case .volume: break
            case .keyframe: #expect(segment.gainPoints == [.init(t: 1.5, db: 10)])
            case .dip: #expect(segment.gainPoints?.map(\.db) == [0, -8, -8, 0])
            case .gripSlip, .modifierSlip: #expect(segment.songFromSeconds == 44.5 && segment.anchorSeconds == 11)
            case .loop:
                #expect(abs(segment.lengthSeconds - 8) < 0.001)
                #expect(canvas.content.musicGraphics.loops["music"]?.count == 1)
            }
        }
        undo.undo()
        #expect(model.project.music == fixture.music)
    }

    @Test func optionClickAddsAKeyframeAtThePointerAndOnTheLine() throws {
        var fixture = try projectWithMusic()
        fixture.music[0].segments?[0].gainPoints = [.init(t: 0, db: 0), .init(t: 3, db: 9)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let fragment = try #require(canvas.itemFragments.first { $0.display.item.id == .music("music") })
        let time = fragment.range.start + 2
        let point = NSPoint(x: canvas.headerWidth + canvas.viewport.x(time), y: fragment.volumeY(-24))
        canvas.mouseDown(with: try mouse(.leftMouseDown, point, in: canvas, flags: .option))
        canvas.keyDown(with: try timelineKey(53))
        canvas.mouseUp(with: try mouse(.leftMouseUp, point, in: canvas, flags: .option))
        #expect(!undo.canUndo && model.project == fixture)
        canvas.mouseDown(with: try mouse(.leftMouseDown, point, in: canvas, flags: .option))
        undo.beginUndoGrouping()
        canvas.mouseUp(with: try mouse(.leftMouseUp, point, in: canvas, flags: .option))
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Add volume keyframe")
        #expect(model.currentMusic?.segments?.first?.gainPoints?[1] == .init(t: 2, db: 6))
        let newFragment = try #require(canvas.itemFragments.first { $0.display.item.id == .music("music") })
        let keyframe = try #require(newFragment.volumePoints.first { $0.gain.t == 2 })
        #expect(hypot(keyframe.center.x - point.x, keyframe.center.y - point.y) < 0.01)
    }

    @Test func audioVoiceOverAndKeyboardUseTheSameUndoableActions() throws {
        let model = editor(try app(), project: try projectWithMusic())
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let id = TimelineItemID.music("music")
        model.sourceTime = 12
        model.playhead = model.timelineTime(source: 12, on: .edited)
        model.selectTimelineItems([id]); canvas.apply()
        func perform(_ title: String) throws {
            let action = try #require(canvas.itemAXElements[id]?.accessibilityCustomActions()?.first { $0.name == title }?.handler)
            undo.beginUndoGrouping(); defer { undo.endUndoGrouping() }
            #expect(action())
        }
        for edge in ["in", "out"] {
            try perform("Fade \(edge) longer")
            #expect(undo.undoActionName == "Fade music" && model.lastAnnouncement == "Fade \(edge) 0.1 seconds.")
            try perform("Fade \(edge) shorter")
            #expect(model.lastAnnouncement == "Fade \(edge) 0.0 seconds.")
        }
        try perform("Volume up 1 dB")
        #expect(undo.undoActionName == "Change volume" && model.lastAnnouncement == "Volume −29.0 dB.")
        try perform("Volume down 1 dB")
        #expect(model.lastAnnouncement == "Volume −30.0 dB.")
        try perform("Add volume keyframe")
        #expect(undo.undoActionName == "Add volume keyframe")
        #expect(model.lastAnnouncement == "Volume keyframe added at the playhead.")
        undo.undo()
        for (code, character, flags, undoName): (UInt16, String, NSEvent.ModifierFlags, String) in [
            (24, "=", .control, "Change volume"), (27, "-", .control, "Change volume"), (40, "k", .option, "Add volume keyframe")
        ] {
            let event = try timelineKey(code, character, flags: flags)
            undo.beginUndoGrouping()
            #expect(canvas.interaction.keyDown(event))
            undo.endUndoGrouping()
            #expect(undo.undoActionName == undoName)
        }
    }

    @Test func musicContourDrawsStagedDipsAndMarksTheCrossfade() throws {
        var fixture = try projectWithMusic()
        fixture.music[0].gainDb = -20
        fixture.music[0].segments?.append(.init(id: "tail", anchorSeconds: 13, lengthSeconds: 3, songFromSeconds: 39,
                                               loop: false, fadeInSeconds: 0, fadeOutSeconds: 0))
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let piece = try #require(canvas.itemFragments.first { $0.display.item.id == .music("music") })
        let speech = piece.range.start + 2
        let activity = (0..<800).map { abs((Double($0) + 0.5) * MusicMix.frameSeconds - speech) < 0.3 }
        let contour = TimelineDuckingContour(gains: MusicMix.duckingGainsDb(activity: activity), timing: .init(speed: 1))
        model.stagedTimelineDucking = (model.projectRevision, contour)
        canvas.renderContent()
        let staged = try #require(canvas.music.state.music.contour)
        #expect(!canvas.music.state.music.usesFallback)
        #expect(abs(piece.duckingY(atX: piece.audioX(at: speech), contour: staged) - piece.volumeY(-32)) < 0.001)
        #expect(piece.duckingY(atX: piece.audioX(at: speech - 1), contour: staged) == piece.volumeY(-20))
        let band = try #require(canvas.music.state.music.fades["tail"])
        #expect(abs(band.end - band.start - 2) < 0.001)
    }

    @Test func audioFieldsExplainUnavailableEditsAndZeroDuckingTurnsItOff() throws {
        var fixture = try projectWithMusic()
        fixture.music[0].segments?[0].lengthSeconds = 6
        fixture.clipEffects = [.init(id: "hidden", clipId: fixture.edits.activeClipId, kind: .sound,
            start: 31, end: 31.8, sound: .init(source: .bundled, id: "pop", durationSeconds: 0.8, title: "Pop", license: "cc0"))]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let id = TimelineItemID.music("music")
        let music = try #require(canvas.content.items.first { $0.item.id == id })
        let hidden = try #require(canvas.content.items.first { $0.item.id == .effect("hidden") })
        #expect(model.timelineFieldDisabledReason(hidden) == "Hidden · outside this clip")
        #expect(model.timelineFieldDisabledReason(music) == nil && music.audio?.duckDb == -12)
        #expect(model.timelineEditReason(.setLoop(item: id, false))?.hasSuffix("Turn on Loop to extend it.") == true)
        #expect(!undo.canUndo)
        for (input, expected) in [(-30.0, -24.0), (0, 0)] {
            undo.beginUndoGrouping()
            #expect(model.commitTimelineItemEdit(.setDuck(track: "music", db: input)))
            undo.endUndoGrouping()
            canvas.renderContent()
            #expect(canvas.content.items.first { $0.item.id == id }?.audio?.duckDb == expected)
            #expect(model.currentMusic?.ducking == (expected != 0))
        }
        undo.undo()
        #expect(model.currentMusic?.duckDb == -24 && model.currentMusic?.ducking == true)
        undo.undo()
        #expect(model.currentMusic == fixture.music.first)
    }

    @Test func aRecordingSeamAndTitleFollowPlayOrder() throws {
        let root = try SharedResources.locate().root
        var fixture = try JSONProjectStore.decode(Data(contentsOf: root.appendingPathComponent("fixtures/recordings/two-recordings.voxclip")))
        let clock = ProjectClock.build(fixture)
        let word = try #require(clock.words.first { $0.id == "r2.w1" })
        fixture.clipEffects = [.init(id: "recording-title", clipId: "clip-main", kind: .title,
            start: word.start, end: word.end, text: "Second recording", position: .top)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        try #require(model.plan != nil, "\(model.previewError ?? "No preview error")")
        let before = try #require(canvas.content.items.first { $0.item.id == .effect("recording-title") }?.ranges.first)
        let story = try #require(model.storyTimeline)
        #expect(story.parts.count == 2)
        #expect(story.parts.allSatisfy { $0.edited != nil })
        #expect(canvas.content.partMarkers.map { $0.recording?.label } == ["0010", "0007"])
        #expect(canvas.content.partMarkers.last?.seamLabel?.hasPrefix("→ 0007 ") == true)
        #expect(canvas.content.recordingGaps.count == 1)
        model.moveStoryPart("first", to: 1)
        canvas.renderContent()
        let after = try #require(canvas.content.items.first { $0.item.id == .effect("recording-title") }?.ranges.first)
        #expect(canvas.content.partMarkers.last?.seamLabel?.hasPrefix("→ 0010 ") == true)
        #expect(after.start > before.start && model.project.clipEffects == fixture.clipEffects)
    }

    @Test func aTitleDragWritesOneNamedUndoOnRelease() throws {
        let app = try app()
        var fixture = try project()
        fixture.clipEffects = [ClipEffect(id: "title", clipId: fixture.edits.activeClipId, kind: .title,
                                          start: 12, end: 13, text: "Faster edits", position: .top)]
        let model = editor(app, project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.timelineSnapping = false
        let fragment = try #require(canvas.itemFragments.first { $0.display.item.id == .effect("title") })
        let point = NSPoint(x: fragment.rect.midX, y: fragment.rect.midY)
        let end = NSPoint(x: point.x + canvas.viewport.ptPerSecond, y: point.y)
        canvas.mouseDown(with: try mouse(.leftMouseDown, point, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas))
        #expect(!undo.canUndo && model.project.clipEffects.first?.start == 12)
        undo.beginUndoGrouping()
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas))
        undo.endUndoGrouping()
        #expect(model.timelineItemRefusal == nil)
        #expect(undo.undoActionName == "Move title" && model.undoSteps == 1)
        #expect(model.project.clipEffects.first?.start == 13)
        undo.undo()
        #expect(model.project.clipEffects.first?.start == 12)
    }

    @Test func itemHitRegionsAndMarqueeFollowTheLanes() throws {
        var fixture = try project()
        let clip = try #require(fixture.edits.activeClipId)
        fixture.clipEffects = [ClipEffect(id: "title", clipId: clip, kind: .title, start: 12, end: 13, text: "Faster edits", position: .top),
                               ClipEffect(id: "sound", clipId: clip, kind: .bleep, start: 16, end: 16.8, wordIds: ["t16"])]
        fixture.media.footage = [.init(id: "picture", clipID: clip, kind: .bRoll, start: 12, end: 13,
                                       footage: .init(sourceKey: "picture-source", start: 0))]
        fixture.motionCues = [.init(id: "zoom", clipID: clip, sourceStart: 12, sourceEnd: 13)]
        let asset = MusicAsset(file: "demo.wav", sha256: String(repeating: "a", count: 64), durationSeconds: 60)
        fixture.music = [.init(id: "music", clipId: clip, asset: asset, source: .file, title: "Night Drive", license: .own)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        #expect(canvas.headers.map(\.trackID) == ["CC", "T1", "B1", "FX", "V1", "A1", "S1", "M1"])
        for (id, lane, label): (TimelineItemID, TimelineItemLane, String) in [
            (.effect("title"), .titles, "Title, Faster edits"), (.footage("picture"), .pictures, "B-roll"),
            (.motion("zoom"), .effects, "Zoom, Pan & Zoom"), (.effect("sound"), .sounds, "Bleep"), (.music("music"), .music, "Music, Night Drive")
        ] {
            let piece = try #require(canvas.itemFragments.first { $0.display.item.id == id })
            #expect(canvas.itemAXElements[id]?.accessibilityLabel()?.hasPrefix(label + ", ") == true)
            let body = NSPoint(x: piece.rect.midX, y: piece.rect.midY)
            #expect(canvas.item(at: body)?.display.item.lane == lane)
            #expect(canvas.item(at: body)?.edge(at: body) == nil)
            let start = NSPoint(x: piece.rect.minX + 1, y: piece.rect.midY)
            #expect(canvas.item(at: start)?.edge(at: start) == .start)
            let end = NSPoint(x: piece.rect.maxX - 1, y: piece.rect.midY)
            #expect(canvas.item(at: end)?.edge(at: end) == .end)
        }
        let start = NSPoint(x: canvas.headerWidth + 1, y: canvas.effects.frame.midY + canvas.trackClip.frame.minY)
        let end = NSPoint(x: canvas.headerWidth + canvas.viewport.x(4), y: canvas.motion.frame.midY + canvas.trackClip.frame.minY)
        canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas))
        #expect(canvas.itemOverlay.preview?.marquee == true)
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas))
        #expect(model.timelineItemSelection == [.effect("title"), .footage("picture"), .motion("zoom")])
    }

    @Test func itemDragThresholdEscapeAndWordGuideLeaveUndoUntouched() throws {
        var fixture = try project()
        fixture.clipEffects = [.init(id: "title", clipId: fixture.edits.activeClipId, kind: .title, start: 11, end: 12, text: "Faster edits", position: .top)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); model.undoManager = undo
        let original = model.project
        let fragment = try #require(canvas.itemFragments.first { $0.display.item.id == .effect("title") })
        let start = NSPoint(x: fragment.rect.midX, y: fragment.rect.midY)
        let small = NSPoint(x: start.x + 2.99, y: start.y)
        canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, small, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, small, in: canvas))
        #expect(model.project == original && !undo.canUndo)
        let word = model.timelineTime(source: 12, on: model.timelineAxis)
        let end = NSPoint(x: start.x + canvas.viewport.ptPerSecond + 2, y: start.y)
        canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas))
        let preview = try #require(canvas.itemOverlay.preview)
        #expect(preview.readout == "+0:01.0 · on “word”")
        #expect(abs((preview.guide ?? 0) - (canvas.headerWidth + canvas.viewport.x(word))) < 0.01)
        let endGrip = NSPoint(x: fragment.rect.maxX - 2, y: start.y)
        canvas.keyDown(with: try timelineKey(53))
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas))
        #expect(model.project == original && !undo.canUndo && model.undoSteps == 0 && canvas.itemOverlay.preview == nil)
        canvas.mouseDown(with: try mouse(.leftMouseDown, endGrip, in: canvas))
        let trim = NSPoint(x: endGrip.x + 0.4 * canvas.viewport.ptPerSecond, y: endGrip.y)
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, trim, in: canvas, flags: .option))
        #expect(canvas.itemOverlay.preview?.readout == "Out +0:00.4 · 1.4 s")
        #expect(canvas.itemOverlay.preview?.guide == nil)
        canvas.keyDown(with: try timelineKey(53))
    }

    @Test func aDragAcrossTheClipEdgePreviewsTheReducerRefusal() throws {
        var fixture = try project()
        fixture.clipEffects = [.init(id: "title", clipId: fixture.edits.activeClipId, kind: .title,
                                     start: 12, end: 15, text: "Faster edits", position: .top)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        model.timelineSnapping = false
        let undo = UndoManager(); model.undoManager = undo
        let original = model.project
        let fragment = try #require(canvas.itemFragments.first { $0.display.item.id == .effect("title") })
        let start = NSPoint(x: fragment.rect.midX, y: fragment.rect.midY)
        let end = NSPoint(x: canvas.headerWidth + canvas.viewport.x(model.duration - 1), y: start.y)
        canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas))
        let preview = try #require(canvas.itemOverlay.preview)
        #expect(preview.readout == "Place it inside one part.")
        #expect(preview.rectangles == [fragment.rect])
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas))
        #expect(model.timelineItemRefusal == preview.readout && model.project == original && !undo.canUndo)
    }

    @Test func aTitleCornerFadesWithoutMovingTheItem() throws {
        var fixture = try project()
        fixture.clipEffects = [.init(id: "title", clipId: fixture.edits.activeClipId, kind: .title,
                                     start: 11, end: 13, text: "Faster edits", position: .top)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        model.selectTimelineItems([.effect("title")]); canvas.apply()
        let fragment = try #require(canvas.itemFragments.first { $0.display.item.id == .effect("title") })
        let start = NSPoint(x: fragment.rect.minX + 10, y: fragment.rect.minY + 4)
        let end = NSPoint(x: start.x + canvas.viewport.ptPerSecond * 0.4, y: start.y)
        canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas))
        #expect(canvas.itemOverlay.preview?.readout == "Fade in 0.4 s" && !undo.canUndo)
        canvas.keyDown(with: try timelineKey(53))
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas))
        #expect(model.project == fixture && !undo.canUndo)
        canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas))
        undo.beginUndoGrouping()
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas))
        undo.endUndoGrouping()
        #expect(model.project.clipEffects.first?.start == 11 && model.project.clipEffects.first?.fadeInSeconds == 0.4)
        #expect(undo.undoActionName == "Fade title" && model.undoSteps == 1)
        let actions = Set(canvas.itemAXElements[.effect("title")]?.accessibilityCustomActions()?.map(\.name) ?? [])
        #expect(actions.isSuperset(of: ["Fade in longer", "Fade in shorter", "Fade out longer", "Fade out shorter"]))
    }

    @Test func optionCommandDragSlipsBRollWithoutMovingItsAnchor() throws {
        var fixture = try project()
        var recording = fixture.media.source
        recording.contentKey = "picture-source"
        recording.recordingHash = nil
        fixture.media.additionalSources = [recording]
        fixture.media.footage = [.init(id: "picture", clipID: try #require(fixture.edits.activeClipId), kind: .bRoll,
                                       start: 11, end: 13, footage: .init(sourceKey: recording.footageKey, start: 2))]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let fragment = try #require(canvas.itemFragments.first { $0.display.item.id == .footage("picture") })
        let start = NSPoint(x: fragment.rect.midX, y: fragment.rect.midY)
        let end = NSPoint(x: start.x + canvas.viewport.ptPerSecond, y: start.y)
        let flags: NSEvent.ModifierFlags = [.option, .command]
        canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas, flags: flags))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas, flags: flags))
        #expect(canvas.itemOverlay.preview?.readout == "Slip +0:01.0 · recording 0:02.0 → 0:03.0")
        #expect(canvas.itemOverlay.preview?.rectangles == [fragment.rect] && model.project == fixture && !undo.canUndo)
        undo.beginUndoGrouping()
        canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas, flags: flags))
        undo.endUndoGrouping()
        #expect(model.project.media.footage.map(\.start) == [11] && model.project.media.footage.first?.footage.start == 3)
        #expect(undo.undoActionName == "Slip B-roll" && model.undoSteps == 1)
    }

    @Test func voiceOverCanMoveAnItemByWordAndExposesItsActions() throws {
        var fixture = try project()
        fixture.clipEffects = [.init(id: "title", clipId: fixture.edits.activeClipId, kind: .title, start: 11, end: 12, text: "Faster edits", position: .top)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        model.selectTimelineItems([.effect("title")]); canvas.apply()
        let title = try #require(canvas.itemAXElements[.effect("title")])
        let label = try #require(title.accessibilityLabel())
        #expect(label == "Title, Faster edits, 0:01.1 to 0:02.1, selected")
        #expect(canvas.itemAXEdges[.effect("title")]?.compactMap { $0.accessibilityLabel() } == ["Title start", "Title end"])
        #expect(title.accessibilityValue() is NSNumber)
        let actions = Set(title.accessibilityCustomActions()?.map(\.name) ?? [])
        #expect(actions.isSuperset(of: ["Move later a frame", "Trim start to playhead", "Split at playhead", "Duplicate", "Delete", "Open editor"]))
        #expect(title.accessibilityPerformIncrement())
        #expect(model.timelineItemRefusal == nil)
        #expect(model.project.clipEffects.first?.start == 12)
        #expect(title.accessibilityPerformDecrement())
        #expect(model.project.clipEffects.first?.start == 11)
    }

    @Test func aHiddenTitleCanRestoreItsWordsFromTheTimeline() throws {
        var fixture = try project()
        fixture.clipEffects = [.init(id: "title", clipId: fixture.edits.activeClipId, kind: .title,
                                     start: 14, end: 15.8, text: "Faster edits", position: .top)]
        fixture.edits.cutWordIds.append("t24")
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let element = try #require(canvas.itemAXElements[.effect("title")])
        #expect(element.accessibilityLabel() == "Title, Faster edits, Hidden · its words are cut")
        let restore = try #require(element.accessibilityCustomActions()?.first { $0.name == "Restore Words" }?.handler)
        undo.beginUndoGrouping()
        #expect(restore())
        undo.endUndoGrouping()
        #expect(model.cutWordIDs == ["t24"] && model.project.clipEffects == fixture.clipEffects)
        #expect(canvas.itemFragments.first(where: { $0.display.item.id == .effect("title") })?.display.item.hidden == false)
        #expect(undo.undoActionName == "Restore words" && model.undoSteps == 1)
    }

    @Test func timelineNAndTheToolbarActionToggleTheSameStateAndFitRestoresTheViewport() throws {
        let model = editor(try app(), project: try project())
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let fitted = canvas.viewport
        canvas.zoom(by: 2)
        #expect(canvas.viewport.ptPerSecond > fitted.ptPerSecond)
        canvas.keyDown(with: try timelineKey(6, "Z", shift: true))
        #expect(canvas.viewport == fitted)
        let previous = model.timelineSnapping
        canvas.keyDown(with: try timelineKey(45, "n"))
        #expect(model.timelineSnapping != previous)
        model.toggleTimelineSnapping()
        #expect(model.timelineSnapping == previous)
        #expect(model.timelineSnapHint == (previous ? "Snapping on (N)" : "Snapping off (N)"))
    }

    @Test func fitShowsBothSourceClipEdgesEvenWithCutsAndContext() throws {
        var fixture = try project()
        fixture.edits.cutWordIds = (13...26).map { "t\($0)" }
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        model.showsCuts = true
        model.showsSurroundingContext = true
        canvas.renderContent()
        let scope = try #require(model.scopeSourceRange)
        canvas.zoom(by: 4)
        canvas.keyDown(with: try timelineKey(6, "Z", shift: true))
        #expect(canvas.viewport.axis == .source)
        #expect(canvas.viewport.visible.contains(scope.lowerBound) && canvas.viewport.visible.contains(scope.upperBound))
        #expect(!canvas.viewport.visible.contains(model.sourceDuration) && model.undoSteps == 0)
    }

    @Test func doubleClickOpensTheExistingEffectEditor() throws {
        var fixture = try project()
        fixture.clipEffects = [.init(id: "title", clipId: fixture.edits.activeClipId, kind: .title, start: 11, end: 12, text: "Faster edits", position: .top)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let fragment = try #require(canvas.itemFragments.first { $0.display.item.id == .effect("title") })
        let point = NSPoint(x: fragment.rect.midX, y: fragment.rect.midY)
        canvas.mouseDown(with: try mouse(.leftMouseDown, point, in: canvas))
        #expect(!model.timelineEffectsOpen)
        canvas.mouseDown(with: try mouse(.leftMouseDown, point, in: canvas, clicks: 2))
        #expect(model.timelineEffectsOpen && model.timelineEffectID == "title")
        #expect(model.undoSteps == 0)
    }

    @Test func aV1PartBandReordersAndItsEdgeTrimsByWord() throws {
        var fixture = try project()
        fixture.edits.clips = [.init(id: "clip-1", startWordId: "t10", endWordId: "t29", parts: [
            .init(id: "first", startWordId: "t10", endWordId: "t13"),
            .init(id: "second", startWordId: "t25", endWordId: "t29")
        ], kind: .story)]
        let model = editor(try app(), project: fixture)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close(); model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        func part(_ id: String) throws -> TimelineItemFragment {
            try #require(canvas.itemFragments.first { $0.display.item.id == .part(id) })
        }
        func drag(_ start: NSPoint, _ end: NSPoint) throws {
            canvas.mouseDown(with: try mouse(.leftMouseDown, start, in: canvas))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, end, in: canvas))
            undo.beginUndoGrouping()
            canvas.mouseUp(with: try mouse(.leftMouseUp, end, in: canvas))
            undo.endUndoGrouping()
        }
        let first = try part("first").rect, second = try part("second").rect
        try drag(.init(x: first.midX, y: first.midY), .init(x: second.midX, y: second.midY))
        #expect(model.activeClip?.parts?.map(\.id) == ["second", "first"])
        #expect(undo.undoActionName == "Move part")
        undo.undo(); canvas.renderContent()
        let edge = try part("second").rect
        let start = NSPoint(x: edge.maxX - 1, y: edge.midY)
        try drag(start, .init(x: start.x - canvas.viewport.ptPerSecond, y: start.y))
        #expect(model.activeClip?.parts?.last?.endWordId == "t28")
        #expect(undo.undoActionName == "Trim part 2")
    }

    private func app() throws -> AppModel {
        let parent = ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("voxclip-timeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        return AppModel(settingsStore: TimelineTestSettings(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
    }

    /// A 60-second take of one-second words with Clip 1 on words 10–29, words 14 and 15 cut.
    private func project() throws -> Project {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.media.source.durationSeconds = 60
        project.transcript?.durationSeconds = 60
        project.transcript?.words = (0..<60).map { index in
            let start = Double(index)
            return TimedWord(id: "t\(index)", text: index % 10 == 9 ? "word." : "word", start: start, end: start + 0.8)
        }
        let clip = ClipRange(id: "clip-1", startWordId: "t10", endWordId: "t29")
        project.edits = ProjectEdits(cutWordIds: ["t14", "t15"], clips: [clip], activeClipId: clip.id)
        return project
    }

    private func editor(_ app: AppModel, project: Project, demo: Bool = true) -> EditorModel {
        EditorModel(document: VoxClipDocument(project: project, demo: demo), app: app, preview: DemoPreviewEngine())
    }

    /// The lanes as the panel sizes them, in a dark window that is never shown.
    private func windowed(_ model: EditorModel, shell: WorkspaceShell? = nil) -> (canvas: TimelineCanvasView, window: NSWindow) {
        let canvas = TimelineCanvasView(model: model, shell: shell)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1056, height: TimelineMetrics.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = canvas
        return (canvas, window)
    }

    /// A left-button event at `point` in the canvas (top-left origin).
    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in canvas: NSView, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                                        windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    /// A horizontal trackpad swipe of `points`.
    private func swipe(_ points: Int32) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: points, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }

    /// The canvas read back in sRGB, and `token` at `alpha` over `ground` read back the same way.
    @MainActor private struct Pixels {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
        let appearance: NSAppearance.Name
        init(_ view: NSView, backingScale: CGFloat? = nil) throws {
            appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .darkAqua
            if let backingScale {
                view.layoutSubtreeIfNeeded()
                let cached = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(view.bounds.width * backingScale), pixelsHigh: Int(view.bounds.height * backingScale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                cached.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: cached)
                let image = try #require(cached.cgImage)
                let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            } else { bitmap = try DebugTimeline.sRGBBitmap(of: view) }
            scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        }
        func at(_ x: CGFloat, _ y: CGFloat) -> [Double] { DebugTimeline.pixel(bitmap, x: Int(x * scale), y: Int(y * scale)) }
        // Expected colours go through the same drawing and read-back, so colour management treats both alike.
        func shows(_ x: CGFloat, _ y: CGFloat, _ token: String, alpha: CGFloat = 1, over ground: String? = nil) throws -> Bool {
            let actual = at(x, y), expected = try DebugTimeline.swatch(token, alpha: alpha, over: ground, appearance: appearance)
            return actual.count == 3 && zip(actual, expected).allSatisfy { abs($0 - $1) < 3.0 / 255 }
        }
        /// Whether a 1 pt line centred on `x` shows `token` at `y`, over what `ground`, the same
        /// view without the line, shows there. At 2x the line fills a whole pixel column. At 1x,
        /// as on the hosted runner, a line off the pixel grid covers two columns in part: each
        /// holds the token over the ground, the larger part at least half, one column's worth in all.
        func showsLine(_ x: CGFloat, _ y: CGFloat, _ token: String, ground: Pixels) throws -> Bool {
            let ink = try DebugTimeline.swatch(token, appearance: appearance)
            let row = Int(y * scale)
            let left: CGFloat = (x - 0.5) * scale, right: CGFloat = (x + 0.5) * scale
            var total: Double = 0, most: Double = 0
            for column in Int(left.rounded(.down))..<Int(right.rounded(.up)) {
                let actual = DebugTimeline.pixel(bitmap, x: column, y: row), paper = DebugTimeline.pixel(ground.bitmap, x: column, y: row)
                guard actual.count == 3, paper.count == 3, ink.count == 3 else { return false }
                let direction: [Double] = zip(ink, paper).map { $0 - $1 }
                let difference: [Double] = zip(actual, paper).map { $0 - $1 }
                let magnitude: Double = direction.reduce(0) { $0 + $1 * $1 }
                guard magnitude > 0.001 else { return false }
                let coverage: Double = zip(difference, direction).reduce(0) { $0 + $1.0 * $1.1 } / magnitude
                // A colour off the way from the ground to the token is something else.
                guard zip(difference, direction).allSatisfy({ abs($0 - $1 * coverage) < 0.06 }) else { return false }
                total += coverage
                most = max(most, coverage)
            }
            return most >= (scale >= 2 ? 0.95 : 0.45) && abs(total - Double(scale)) < 0.35
        }
    }

    // MARK: Viewport

    @Test func fittingKeepsASecondOfLaneEachSideAsInF1() {
        // f1: a 43.2 s clip in a 944 pt lane shows -1.0 s to 44.2 s over 936 pt.
        let viewport = TimelineViewport.fitting(0...43.2, width: 944, axis: .edited)
        #expect(abs(viewport.ptPerSecond - 936 / 45.2) < 1e-9)
        #expect(viewport.origin == -1)
        #expect(abs(viewport.x(44.2) - 936) < 1e-9)
        #expect(abs(viewport.time(atX: viewport.x(12.3)) - 12.3) < 1e-9)
        // Source keeps the zoom; only the axis and its start change (notes.md §6).
        let source = viewport.switched(to: .source, start: 221)
        #expect(source.ptPerSecond == viewport.ptPerSecond && source.origin == 220 && source.axis == .source)
    }

    @Test func playheadPagesAndPansStayInTheContent() {
        let viewport = TimelineViewport(axis: .edited, ptPerSecond: 10, origin: -1, width: 508)
        #expect(viewport.showing(20) == viewport)
        #expect(viewport.showing(55).origin == 54)
        #expect(viewport.showing(-5).origin == -6)
        #expect(viewport.panned(by: 100, within: 0...100).origin == 9)
        #expect(viewport.panned(by: 10_000, within: 0...100).origin == 51)
        #expect(viewport.panned(by: -10_000, within: 0...100).origin == -1)
    }

    // MARK: The canvas

    @Test func aPlayheadTickMovesOnlyThePlayheadLayers() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        canvas.frame = NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height)
        canvas.layoutSubtreeIfNeeded()
        canvas.renderContent()
        model.waveform = DebugTimeline.speech(words: model.words, duration: 60)
        canvas.renderContent()
        let lanes: [TimelineLane] = [canvas.overview, canvas.ruler, canvas.bed, canvas.video, canvas.audio, canvas.captions, canvas.motion]
        // Lanes draw through their layers (the 60-minute budget measures this way).
        lanes.forEach { $0.layer?.displayIfNeeded() }
        let draws = lanes.map(\.draws)
        #expect(draws.allSatisfy { $0 >= 1 })
        let invalidations = lanes.map(\.invalidations)
        let moves = canvas.overlay.playheadMoves
        for frame in 1...30 {
            model.playhead = Double(frame) * 0.5
            model.sourceTime = model.timelineSourceTime(model.playhead, on: .edited)
            canvas.followPlayhead()
        }
        #expect(lanes.map(\.invalidations) == invalidations)
        lanes.forEach { $0.layer?.displayIfNeeded() }
        #expect(lanes.map(\.draws) == draws)
        #expect(canvas.overlay.playheadMoves == moves + 30)
        // The playhead layer lives in the lanes' clip, right of the headers.
        let x = Double(canvas.overlay.playhead.transform.m41)
        #expect(abs(x - canvas.viewport.x(15)) < 1e-6)
        #expect(canvas.overlay.laneClip.masksToBounds && canvas.overlay.laneClip.frame.minX == TimelineMetrics.header)
        // Clip 1's overview label steps 5 pt past a playhead that would sit on it, as a layer move.
        let block = canvas.overview.x(try #require(model.timelineOverviewClips.first).source.lowerBound)
        #expect(canvas.overview.labels(playheadX: block + 20).first?.x == block + 4)
        #expect(canvas.overview.labels(playheadX: block + 6).first?.x == block + 11)
        // The selection is content: it redraws the ruler.
        model.selectedWordIDs = ["t20", "t21"]
        canvas.renderContent()
        #expect(canvas.ruler.invalidations > invalidations[1])
        #expect(canvas.content.selection == model.timelineSelection(on: .edited))
    }

    @Test func thePlayheadOffScreenPagesTheViewport() throws {
        let app = try app()
        let model = editor(app, project: try project())
        model.showsSurroundingContext = true
        defer { model.close() }
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        canvas.frame = NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height)
        canvas.layoutSubtreeIfNeeded()
        model.showsCuts = true
        canvas.renderContent()
        let before = canvas.viewport
        #expect(!before.visible.contains(45))
        let invalidations = canvas.ruler.invalidations
        model.sourceTime = 45
        model.playhead = model.timelineTime(source: 45, on: .edited)
        canvas.followPlayhead()
        #expect(canvas.viewport.origin == 44 && canvas.viewport.ptPerSecond == before.ptPerSecond)
        #expect(canvas.ruler.invalidations > invalidations)
    }

    @Test func activatingAStoryClipSeeksToItsFirstPlayedPart() async throws {
        let app = try app()
        var story = try project()
        story.edits.activeClipId = nil
        story.edits.clips = [ClipRange(id: "clip-1", startWordId: "t10", endWordId: "t29", parts: [
            ClipPart(id: "later", startWordId: "t25", endWordId: "t29"),
            ClipPart(id: "earlier", startWordId: "t10", endWordId: "t12"),
        ])]
        let model = editor(app, project: story)
        defer { model.close() }
        model.activate(try #require(story.edits.clips.first))
        for _ in 0..<100 where model.sourceTime != 24.9 { await Task.yield() }
        #expect(model.sourceTime == 24.9)
        #expect(model.playhead == 0)
    }

    @Test func storyTimelineLabelsBackwardJoinsAndOpensCutsInsideEachPart() throws {
        let app = try app()
        var story = try project()
        story.edits.clips = [ClipRange(id: "clip-1", startWordId: "t10", endWordId: "t29", parts: [
            ClipPart(id: "later", startWordId: "t25", endWordId: "t29"),
            ClipPart(id: "earlier", startWordId: "t10", endWordId: "t18")
        ], kind: .story)]
        let model = editor(app, project: story)
        defer { model.close() }
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        canvas.frame = NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height)
        canvas.layoutSubtreeIfNeeded()
        canvas.renderContent()
        #expect(canvas.content.partMarkers.map(\.label) == ["1 · 0:25", "2 · 0:10"])
        #expect(canvas.content.partMarkers.compactMap(\.seamLabel) == ["↶ 0:10"])
        #expect(canvas.content.clips.map(\.source.lowerBound) == [25, 10])
        let join = try #require(canvas.content.partMarkers.last?.range.lowerBound)
        #expect(model.timelineSeamGap(near: join, within: 0.01) == nil)
        model.showsCuts = true
        canvas.renderContent()
        let markers = canvas.content.partMarkers
        #expect(markers.count == 2)
        #expect(markers[0].range.upperBound == markers[1].range.lowerBound)
        #expect(abs(model.timelineSourceTime(markers[1].range.lowerBound + 0.1, on: .source) - 10) < 1e-6)
        #expect(canvas.content.removed.count == 1)
        let cut = try #require(canvas.content.removed.first)
        #expect(cut.lowerBound > markers[1].range.lowerBound && cut.upperBound < markers[1].range.upperBound)
    }

    @Test func showCutsOpensTakeTimeAtTheEditedZoomFromTheClip() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        canvas.frame = NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height)
        canvas.layoutSubtreeIfNeeded()
        canvas.renderContent()
        let edited = canvas.viewport
        #expect(edited.axis == .edited && edited.origin == -1)
        #expect(canvas.content.inOut == 0...model.duration)
        model.showsCuts = true
        canvas.renderContent()
        let scope = try #require(model.scopeSourceRange)
        #expect(canvas.viewport.axis == .source && canvas.viewport.ptPerSecond == edited.ptPerSecond && canvas.viewport.origin == scope.lowerBound - 1)
        #expect(canvas.content.inOut == scope)
        // Full Take has no In/Out and fits again.
        model.activate(nil)
        canvas.renderContent()
        #expect(canvas.content.inOut == nil && canvas.content.scope == nil)
        #expect(canvas.accessibilityChildren()?.compactMap { $0 as? TimelineSliderElement }.count == 1)
    }

    @Test func showCutsIsAViewSettingOffByDefault() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let undo = UndoManager()
        model.undoManager = undo
        #expect(!model.showsCuts && model.timelineAxis == .edited)
        let steps = model.undoSteps, edited = model.document.isDocumentEdited
        model.showsCuts = true
        #expect(model.timelineAxis == .source)
        #expect(model.undoSteps == steps && !undo.canUndo)
        #expect(model.document.isDocumentEdited == edited)
        // The playhead slider's value names the axis it shows (design §5.2).
        #expect(model.timelineAccessibilityValue.contains(" source, "))
        model.showsCuts = false
        #expect(model.timelineAccessibilityValue.contains(" after cuts, "))
    }

    @Test func editedTrimsMapAcrossAClosedCut() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let clip = try #require(model.activeClip)
        // Words 14 and 15 are cut: Edited time after the seam lands on word 16.
        let inside = model.timelineTime(source: 16.4, on: .edited)
        #expect(abs(model.timelineSourceTime(inside, on: .edited) - 16.4) < 0.001)
        #expect(model.timelineTrimIndex(clip, start: false, time: inside + 0.1, on: .edited) == 16)
        #expect(model.timelineTime(source: 16.4, on: .source) == 16.4)
        #expect(model.timelineTrimIndex(clip, start: true, time: -5, on: .edited) == 10)
        #expect(model.timelineTrimIndex(clip, start: false, time: 9_999, on: .edited) == 29)
        // On Source a drag can widen the clip.
        #expect(model.timelineTrimIndex(clip, start: true, time: 3.1, on: .source) == 3)
    }

    /// While nothing has moved it, Edited stays fitted to the clip through cuts and
    /// restores, so Out never leaves the lane and no empty ruler trails it; an edge dropped
    /// on the timeline keeps the zoom it was dropped at; a pan that moves the view ends the fit.
    @Test func aFittedEditedViewFitsAgainWhenTheClipsLengthChanges() throws {
        let app = try app()
        let model = editor(app, project: try project())
        model.showsSurroundingContext = true
        defer { model.close() }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let lane = Double(canvas.bounds.width - TimelineMetrics.header)
        func fit() -> TimelineViewport { TimelineViewport.fitting(0...model.duration, width: lane, axis: .edited) }
        #expect(canvas.viewport == fit())
        // A swipe the fitted view has no room for moves nothing and keeps the fit.
        let push = try swipe(-40)
        #expect(push.scrollingDeltaX != 0)
        canvas.scrollWheel(with: push)
        #expect(canvas.viewport == fit())
        // Restore Cuts lengthens the clip by its two cut words: Out stays on the lane.
        let cut = model.duration
        model.apply(.restoreCuts, name: "Restore cuts")
        canvas.renderContent()
        #expect(model.duration > cut + 1.5)
        #expect(canvas.viewport == fit())
        #expect(canvas.viewport.x(try #require(canvas.content.inOut).upperBound) <= lane - Double(TimelineMetrics.trailing) + 1e-9)
        // A cut shortens it: the clip still ends at the lane's end.
        model.selectedWordIDs = ["t20", "t21", "t22"]
        model.cutSelection()
        canvas.renderContent()
        #expect(canvas.viewport == fit())
        // Out dragged 3 s in on the ruler lands under the pointer at the zoom it was dropped at.
        let zoom = canvas.viewport
        let outX = TimelineMetrics.header + CGFloat(zoom.x(model.duration)), y = TimelineMetrics.ruler.y + 11
        let drop = outX - CGFloat(3 * zoom.ptPerSecond)
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: outX, y: y), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: drop, y: y), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: drop, y: y), in: canvas))
        // The model's observation takes the same change again.
        canvas.renderContent()
        #expect(model.activeClip?.endWordId == "t26")
        #expect(canvas.viewport == zoom)
        #expect(abs(TimelineMetrics.header + CGFloat(canvas.viewport.x(model.duration)) - drop) < CGFloat(zoom.ptPerSecond) / 2)
        // The next change fits again.
        model.selectedWordIDs = ["t12"]
        model.cutSelection()
        canvas.renderContent()
        #expect(canvas.viewport == fit())
        // A pan that moves the view (Source has the take to move through) ends the fit:
        // back on Edited a cut keeps that zoom.
        model.showsCuts = true
        canvas.renderContent()
        let source = canvas.viewport
        canvas.scrollWheel(with: try swipe(-200))
        #expect(canvas.viewport.origin != source.origin)
        model.showsCuts = false
        canvas.renderContent()
        let kept = canvas.viewport
        #expect(kept.axis == .edited && kept.ptPerSecond == source.ptPerSecond)
        model.selectedWordIDs = ["t11"]
        model.cutSelection()
        canvas.renderContent()
        #expect(canvas.viewport == kept)
    }

    /// notes.md §6: the headers are chrome over anything left of the lanes. A scrub dragged
    /// over them and a selection that starts before the view leave the playhead and the
    /// wash on the lanes alone, and letting go pages to the playhead.
    @Test func thePlayheadAndTheWashStayOffTheTrackHeaders() throws {
        let app = try app()
        let model = editor(app, project: try project())
        model.showsSurroundingContext = true
        defer { model.close() }
        model.showsCuts = true
        model.sourceTime = 20.4
        model.playhead = model.timelineTime(source: 20.4, on: .edited)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.followPlayhead()
        let y = TimelineMetrics.audio.y + 10
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: TimelineMetrics.header + 300, y: y), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 40, y: y), in: canvas))
        let early = canvas.viewport.time(atX: Double(40 - TimelineMetrics.header))
        #expect(early > 0 && early < canvas.viewport.origin)
        // The seek lands (the preview answers later); the view holds under the pointer.
        model.sourceTime = early
        model.playhead = model.timelineTime(source: early, on: .edited)
        canvas.followPlayhead()
        #expect(!canvas.viewport.visible.contains(early))
        // Words 5–12, from before the view, selected.
        model.selectedWordIDs = Set((5...12).map { "t\($0)" })
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        let pixels = try Pixels(canvas)
        #expect(try pixels.shows(40, y, "bg.window"))
        #expect(try pixels.shows(80, y, "bg.window"))
        // V1's bare lane under the wash (A1 draws the take's audio there).
        #expect(try pixels.shows(TimelineMetrics.header + canvas.viewport.x(11), TimelineMetrics.tracks[TimelineItemLane.video.index].y + 18, "tint.wash", over: "timeline.videoPiece"))
        let zoom = canvas.viewport.ptPerSecond
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 40, y: y), in: canvas))
        #expect(canvas.viewport.visible.contains(early) && canvas.viewport.ptPerSecond == zoom)
        #expect(abs(Double(canvas.overlay.playhead.transform.m41) - canvas.viewport.x(early)) < 1e-6)
    }

    /// The default Edited view closes a cut to a seam: a double-click within reach of it
    /// restores everything cut there as one step, as one on the cut does in Source view.
    @Test func aDoubleClickOnAClosedCutsSeamRestoresIt() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        #expect(canvas.toolTip?.contains("Double-click a cut to restore it") == true && canvas.toolTip?.contains("Cut selection") == true)
        // Words 14 and 15 close to one seam, where the piece after them starts.
        let pieces = model.timelinePieces.pieces
        let after = try #require(pieces.indices.dropFirst().first { pieces[$0].source.lowerBound - pieces[$0 - 1].source.upperBound > 1 })
        let seam = TimelineMetrics.header + CGFloat(canvas.viewport.x(pieces[after].edited.lowerBound))
        let y = TimelineMetrics.audio.y + 10
        let steps = model.undoSteps
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: seam + TimelineMetrics.reach + 3, y: y), in: canvas, clicks: 2))
        #expect(model.cutWordIDs == ["t14", "t15"] && model.undoSteps == steps)
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: seam - 3, y: y), in: canvas, clicks: 2))
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: seam - 3, y: y), in: canvas))
        #expect(model.cutWordIDs.isEmpty && model.undoSteps == steps + 1)
        // Source view restores the cut word under the pointer.
        model.selectedWordIDs = ["t14", "t15"]
        model.cutSelection()
        model.restoreCut(at: 14.4, on: .source, tolerance: 0.1)
        #expect(model.cutWordIDs == ["t15"])
    }

    /// The panel lays out in a window that is never shown: the toolbar's readout resolves
    /// its token colours and the lanes are hosted under it.
    @Test func thePanelLaysOutWithItsToolbarAndLanes() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        model.playhead = 14 + 23.0 / 30
        let host = ShellHost.controller(TimelinePanel(model: model, shell: WorkspaceShell(app: app)), app: app)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1056, height: 216), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1056, height: 216))
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        let canvas = try #require(DebugShell.firstView(TimelineCanvasView.self, in: host.view))
        #expect(abs(canvas.frame.height - (216 - TimelineMetrics.toolbar - TimelineMetrics.editBar)) < 1 && abs(canvas.frame.width - 1056) < 1)
        _ = host.view.fittingSize
        canvas.tearDown()
    }

    /// notes.md §6's pixels, drawn in a window that is never shown: the playhead's line and
    /// head in the tint, the In bracket in clip.label, the ruler on chrome inside In/Out and
    /// darker outside, the track lanes, the open clip's 42% overview block, no red.
    @Test(arguments: [TimelineAxis.edited, .source]) func theLanesDrawNotesSixPixels(_ axis: TimelineAxis) throws {
        let app = try app()
        let model = editor(app, project: try project())
        model.showsSurroundingContext = true
        defer { model.close() }
        model.showsCuts = axis == .source
        // The playhead inside the clip before the canvas follows it, so neither axis pages.
        let source = 20.4
        model.sourceTime = source
        model.playhead = model.timelineTime(source: source, on: .edited)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.followPlayhead()
        #expect(abs(canvas.viewport.origin - (axis == .edited ? -1 : 8.9)) < 1e-9)
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let pixels = try Pixels(canvas)
        let cached = pixels.bitmap
        // The lanes without the playhead, under its line.
        canvas.overlay.playhead.isHidden = true
        let ground = try Pixels(canvas)
        canvas.overlay.playhead.isHidden = false
        let viewport = canvas.viewport
        let play = TimelineMetrics.header + CGFloat(viewport.x(model.timelinePlayhead(on: axis)))
        #expect(try pixels.showsLine(play, TimelineMetrics.audio.y + 10, "tint.default", ground: ground))
        #expect(try pixels.shows(play, TimelineMetrics.ruler.y + 14, "tint.default"))
        let inOut = try #require(model.timelineInOut(on: axis))
        let inX = TimelineMetrics.header + CGFloat(viewport.x(inOut.lowerBound))
        #expect(try pixels.shows(inX + 0.75, TimelineMetrics.ruler.y + 12, "clip.label"))
        #expect(try pixels.shows(inX + 3, TimelineMetrics.ruler.y + 13, "bg.window"))
        #expect(try pixels.shows(inX - 6, TimelineMetrics.ruler.y + 13, "timeline.rulerOut"))
        #expect(try pixels.shows(TimelineMetrics.header + 4, TimelineMetrics.tracks[TimelineItemLane.video.index].y + 18, axis == .source ? "timeline.videoPiece" : "timeline.lane", alpha: axis == .source ? 0.32 : 1, over: axis == .source ? "timeline.lane" : nil))
        let block = canvas.overview.x(try #require(model.timelineOverviewClips.first).source.lowerBound + 0.3)
        #expect(try pixels.shows(block, TimelineMetrics.overview.y + 12, "clip.label", alpha: 0.42, over: "timeline.lane"))
        // The header column and its hairline stay beside every lane.
        #expect(try pixels.shows(TimelineMetrics.header - 0.5, TimelineMetrics.overview.y + 6, "line.default"))
        var red = false
        for row in stride(from: 0, to: cached.pixelsHigh, by: 2) {
            for column in stride(from: 0, to: cached.pixelsWide, by: 2) {
                guard let color = cached.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.55 && color.greenComponent < 0.3 && color.blueComponent < 0.3 { red = true }
            }
        }
        #expect(!red)
    }

    /// A pending proposed change is a 3 pt `change.add` bar in the ruler on either axis, under the selection's bar
    /// (notes.md §6), and goes once it is kept or left out (impl-plan V14, V15).
    @Test(arguments: [TimelineAxis.edited, .source]) func pendingChangesAreRulerBars(_ axis: TimelineAxis) throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = axis == .source
        // The playhead inside the clip before the canvas follows it, so neither axis pages.
        model.sourceTime = 20.4
        model.playhead = model.timelineTime(source: 20.4, on: .edited)
        model.proposal = TranscriptProposal(clipID: "clip-1", title: "Rewrite clip 1", changes: [
            TranscriptChange(ordinal: 1, parts: [.init(kind: .cut, sourceWordIDs: ["t20", "t21"])])
        ])
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.followPlayhead()
        let change = try #require(canvas.content.changes.first)
        #expect(canvas.content.changes.count == 1 && canvas.ruler.state.changes == canvas.content.changes)
        #expect(abs(change.lowerBound - model.timelineTime(source: 20, on: axis)) < 1e-6 && abs(change.upperBound - model.timelineTime(source: 21.8, on: axis)) < 1e-6)
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let x = TimelineMetrics.header + CGFloat(canvas.viewport.x((change.lowerBound + change.upperBound) / 2))
        #expect(try Pixels(canvas).shows(x, TimelineMetrics.ruler.y + 20.5, "change.add"))
        // The selection's bar draws over it.
        model.selectedWordIDs = ["t20", "t21"]
        canvas.renderContent()
        window.displayIfNeeded()
        #expect(try Pixels(canvas).shows(x, TimelineMetrics.ruler.y + 20.5, "tint.default"))
        model.selectedWordIDs = []
        model.excludeChange(1)
        canvas.renderContent()
        #expect(canvas.content.changes.isEmpty && canvas.ruler.state.changes.isEmpty)
    }

    // MARK: A1

    /// The default project with words 14, 15, 20 and 24 cut, a speech envelope (each word
    /// voiced, silence between words) and the playhead in word 17, which both axes' fitted
    /// views show, so neither pages.
    private func audioModel(_ app: AppModel) throws -> EditorModel {
        var project = try project()
        project.edits.cutWordIds = ["t14", "t15", "t20", "t24"]
        let model = editor(app, project: project)
        model.waveform = DebugTimeline.speech(words: model.words, duration: 60)
        model.sourceTime = 17.4
        model.playhead = model.timelineTime(source: 17.4, on: .edited)
        return model
    }

    /// The take-time cut ranges of the scope's plan inside `span`, adjacent ones merged.
    private func cutRanges(_ model: EditorModel, within span: ClosedRange<Double>) throws -> [Range<Double>] {
        let plan = try #require(model.plan)
        var ranges: [Range<Double>] = []
        for cut in plan.cuts {
            let lower = max(span.lowerBound, Double(cut.startSample) / plan.sampleRate), upper = min(span.upperBound, Double(cut.endSample) / plan.sampleRate)
            guard upper > lower else { continue }
            if let last = ranges.last, abs(last.upperBound - lower) < 1e-9 { ranges[ranges.count - 1] = last.lowerBound..<upper } else { ranges.append(lower..<upper) }
        }
        return ranges.filter { $0.upperBound - $0.lowerBound > 0.02 }
    }

    /// notes.md §6, Edited: pieces butt on `timeline.audioPiece`, each cut in the clip is one
    /// `timeline.seam`, words draw the waveform's core and the silence between them draws
    /// nothing, not even a centre line.
    @Test func editedA1DrawsASeamPerCutAndNothingInSilence() throws {
        let app = try app()
        let model = try audioModel(app)
        defer { model.close() }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        let plan = try #require(model.plan)
        let first = try #require(plan.kept.first), last = try #require(plan.kept.last)
        let interior = plan.cuts.filter { $0.startSample > first.startSample && $0.endSample < last.endSample }
        #expect(interior.count == 3)
        #expect(canvas.audio.drawn.seams.count == interior.count)
        #expect(model.timelinePieces.seams.count == interior.count)
        let pixels = try Pixels(canvas)
        let viewport = canvas.viewport, top = TimelineMetrics.audio.y, mid = top + TimelineMetrics.audio.height / 2
        func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(viewport.x(time)) }
        for seam in canvas.audio.drawn.seams { #expect(try pixels.shows(seam - 0.5, mid, "timeline.seam")) }
        // Word 22 is spoken: its loudest column shows the core in timeline.wave and the peak
        // around it at 62%. The 0.2 s after it is silence inside the same piece.
        let waveform = try #require(model.waveform)
        let half = TimelineMetrics.audio.height / 2 - TimelineAudioLane.pieceInset - TimelineAudioLane.waveInset
        let columns = stride(from: x(model.timelineTime(source: 22.05, on: .edited)).rounded(.down), to: x(model.timelineTime(source: 22.75, on: .edited)), by: 1).map { column in
            (column: column, value: waveform.column(from: viewport.time(atX: Double(column - TimelineMetrics.header)) + 22 - model.timelineTime(source: 22, on: .edited),
                                                    to: viewport.time(atX: Double(column + 1 - TimelineMetrics.header)) + 22 - model.timelineTime(source: 22, on: .edited)))
        }
        let loudest = try #require(columns.max { $0.value.core < $1.value.core })
        let core = CGFloat(loudest.value.core) * half, peak = CGFloat(loudest.value.peak) * half
        #expect(core >= 3 && peak - core >= 2)
        let voiced = loudest.column + 0.5
        #expect(try pixels.shows(voiced, mid, "timeline.wave"))
        #expect(try pixels.shows(voiced, mid - core + 1, "timeline.wave"))
        #expect(try pixels.shows(voiced, mid - (core + peak) / 2, "timeline.wave", alpha: TimelineAudioLane.peakOpacity, over: "timeline.audioPiece"))
        let silent = x(model.timelineTime(source: 22.9, on: .edited)).rounded(.down) + 0.5
        #expect(try pixels.shows(silent, mid, "timeline.audioPiece"))
        #expect(try pixels.shows(silent, top + 2.25, "timeline.audioPiece"))
        // The waveform keeps 2.5 pt of the piece clear above and below it.
        #expect(try pixels.shows(voiced, top + 2.25, "timeline.audioPiece"))
    }

    /// notes.md §6, Source: the same zoom on take time; each cut range in the clip is empty
    /// lane with a dashed `timeline.cutOutline`, kept pieces stand where they are and media
    /// outside In/Out shows at 32%.
    @Test func focusedSourceHidesOutsideAudioAndVideoAndContextRestoresThem() throws {
        let app = try app(), model = try audioModel(app)
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        let scope = try #require(model.scopeSourceRange)
        let original = model.project
        for showsContext in [false, true, false] {
            model.showsSurroundingContext = showsContext
            canvas.renderContent()
            canvas.layoutSubtreeIfNeeded()
            canvas.audio.layer?.displayIfNeeded()
            canvas.video.layer?.displayIfNeeded()
            #expect((canvas.audio.drawn.dimmed > 0) == showsContext)
            #expect((canvas.video.dimmed > 0) == showsContext)
            #expect(canvas.content.overviewRange == (showsContext ? 0...model.sourceDuration : scope))
            if !showsContext {
                #expect(canvas.content.displayRange == scope)
                canvas.zoom(by: 4)
                canvas.scroll(to: 0)
                #expect(abs(canvas.viewport.origin - (scope.lowerBound - 1)) < 1e-9)
                canvas.scroll(to: 1)
                // The viewport includes the existing trailing label room beyond the usable lane.
                let usableEnd = canvas.viewport.visible.upperBound - Double(TimelineMetrics.trailing) / canvas.viewport.ptPerSecond
                #expect(usableEnd <= scope.upperBound + TimelineViewport.margin + 1e-9)
            }
        }
        #expect(model.project == original && model.undoSteps == 0 && !model.document.isDocumentEdited)
    }

    @Test func sourceA1GapsCoverExactlyTheCutRanges() throws {
        let app = try app()
        let model = try audioModel(app)
        model.showsSurroundingContext = true
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        let scope = try #require(model.scopeSourceRange)
        let expected = try cutRanges(model, within: scope)
        #expect(expected.count == 3 && expected.allSatisfy { canvas.viewport.visible.contains($0.upperBound) })
        #expect(canvas.audio.drawn.gaps == expected)
        #expect(canvas.audio.drawn.seams.isEmpty)
        let pixels = try Pixels(canvas)
        let viewport = canvas.viewport, top = TimelineMetrics.audio.y, mid = top + TimelineMetrics.audio.height / 2
        func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(viewport.x(time)) }
        // The silence between the cut words 14 and 15 is empty lane; the words show ghosted.
        #expect(try pixels.shows(x(14.9), mid, "timeline.lane"))
        #expect(try pixels.shows(x(14.9), top + 2.25, "timeline.lane"))
        let ghosted = stride(from: x(14.05).rounded(.down) + 0.5, to: x(14.75), by: 1).filter { (try? pixels.shows($0, mid, "timeline.lane")) == false }
        #expect(ghosted.count > 5)
        let gap = try #require(expected.first)
        let dashes = stride(from: x(gap.lowerBound) + 1, to: x(gap.upperBound) - 2, by: 0.5).filter { (try? pixels.shows($0, top + 1.5, "timeline.cutOutline")) == true }
        #expect(dashes.count > 4)
        // A kept piece in take time, and the take before In at 32%.
        #expect(try pixels.shows(x(12.4), top + 2.25, "timeline.audioPiece"))
        #expect(try pixels.shows(x(scope.lowerBound) - 4, top + 2.25, "timeline.audioPiece", alpha: TimelineAudioLane.outsideOpacity, over: "timeline.lane"))
    }

    /// A Voice Lab patch on Edited (notes.md §6): an `ai.tint` 10% fill with no outline and no
    /// seam of its own; with the playhead in it the src TC reads "AI voice".
    @Test func anAIPatchIsABlueFillWithoutSeams() throws {
        let app = try app()
        let model = try audioModel(app)
        defer { model.close() }
        func piece(_ kind: VoiceLabOutputPieceKind, _ source: (Int64, Int64), _ output: (Int64, Int64)) -> VoiceLabOutputPiece {
            VoiceLabOutputPiece(kind: kind, sourceStartSample: source.0, sourceEndSample: source.1, outputStartSample: output.0, outputEndSample: output.1,
                                segmentId: nil, assetId: nil, audio: nil)
        }
        // Words 10–29 with 16–18 s spoken by your AI voice in 2.5 s, and 24–25 s cut.
        model.voiceLabPlan = VoiceLabOutputPlan(sampleRate: 100, totalSourceSamples: 6_000,
            pieces: [piece(.source, (1_000, 1_600), (0, 600)), piece(.synth, (1_600, 1_800), (600, 850)), piece(.source, (1_800, 2_400), (850, 1_450)),
                     piece(.source, (2_500, 3_000), (1_450, 1_950))], captions: [], scope: .clip("clip-1"))
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        #expect(canvas.audio.drawn.seams.count == 1)
        let pixels = try Pixels(canvas)
        let viewport = canvas.viewport, top = TimelineMetrics.audio.y
        func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(viewport.x(time)) }
        #expect(try pixels.shows(x(7.2), top + 2.25, "ai.tint", alpha: 0.10, over: "timeline.lane"))
        #expect(try pixels.shows(x(7.2), top + 1.5, "ai.tint", alpha: 0.10, over: "timeline.lane"))
        #expect(try pixels.shows(x(3), top + 2.25, "timeline.audioPiece"))
        model.playhead = 7.2
        #expect(model.playheadInAIVoice)
        model.playhead = 5.9
        #expect(!model.playheadInAIVoice)
        model.playhead = 8.5
        #expect(!model.playheadInAIVoice)
    }

    /// notes.md §6 on Source while In is dragged: A1 dims from the edge the ruler shows, so
    /// the bracket and the dimming agree. Words the drag drops show at 32%; words it adds
    /// show as kept media.
    @Test(arguments: [12.1, 9.1]) func sourceA1DimsFromTheDraggedIn(_ target: Double) throws {
        let app = try app()
        let model = try audioModel(app)
        model.showsSurroundingContext = true
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        // Include enough context to sample both sides even when moving In a word earlier.
        canvas.pan(by: -2 * canvas.viewport.ptPerSecond)
        let scope = try #require(model.scopeSourceRange)
        let viewport = canvas.viewport, top = TimelineMetrics.audio.y, y = TimelineMetrics.ruler.y + 11
        func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(viewport.x(time)) }
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: x(scope.lowerBound), y: y), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: x(target), y: y), in: canvas))
        let targetWord = Int(target.rounded(.down))
        let dragged = Double(targetWord) - 0.1
        #expect(canvas.audio.state.inOut == dragged...scope.upperBound)
        #expect(canvas.audio.state.clip == scope)
        canvas.audio.layer?.displayIfNeeded()
        let pixels = try Pixels(canvas)
        // Word 11 (or word 9) lies between the old In and the dragged one.
        let between = x(dragged > 10 ? 11.4 : 9.4)
        if dragged > 10 {
            #expect(try pixels.shows(between, top + 2.25, "timeline.audioPiece", alpha: TimelineAudioLane.outsideOpacity, over: "timeline.lane"))
        } else {
            #expect(try pixels.shows(between, top + 2.25, "timeline.audioPiece"))
        }
        #expect(x(dragged) - 4 > canvas.headerWidth)
        #expect(try pixels.shows(x(dragged) - 4, top + 2.25, "timeline.audioPiece", alpha: TimelineAudioLane.outsideOpacity, over: "timeline.lane"))
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: x(target), y: y), in: canvas))
        #expect(model.activeClip?.startWordId == "t\(targetWord)")
        #expect(canvas.audio.state.inOut == model.scopeSourceRange && canvas.audio.state.clip == model.scopeSourceRange)
    }

    /// A lane of `pieces` on Edited at 20 pt/s from a second before 0, over a steady voice.
    private func lane(_ pieces: [TimelinePiece]) -> (lane: TimelineAudioLane, window: NSWindow) {
        let lane = TimelineAudioLane()
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1056, height: 44), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = lane
        lane.frame = NSRect(x: 0, y: 0, width: 1056, height: 44)
        lane.state = TimelineAudioLane.State(viewport: TimelineViewport(axis: .edited, ptPerSecond: 20, origin: -1, width: 944),
                                             pieces: TimelinePieces(pieces), waveform: WaveformData(fine: [Float](repeating: 0.05, count: 1_000)), takeLength: 10)
        lane.layer?.displayIfNeeded()
        return (lane, window)
    }

    /// The lane point a cut falls inside is one column, drawn once: the pieces either side
    /// of it do not each paint it.
    @Test func aPointTwoPiecesShareIsOneColumn() throws {
        // The cut is at x 60.4 in the lane: columns 20–60 are the first piece's, 60–100 the second's.
        let (lane, window) = lane([TimelinePiece(source: 0..<2.02, edited: 0..<2.02), TimelinePiece(source: 3..<5, edited: 2.02..<4.02)])
        defer { window.close() }
        #expect(lane.drawn.seams.count == 1)
        #expect(lane.drawn.columns == 81)
        #expect(lane.drawn.boxes == 2)
    }

    /// A fitted hour with 1,500 cuts has pieces under a point: they share one box rather
    /// than each having none, so A1 keeps its `timeline.audioPiece` ground.
    @Test func piecesUnderAPointShareOneBox() throws {
        // A hundred 0.6 pt pieces, each after a 10 ms cut.
        let pieces: [TimelinePiece] = (0..<100).map { (index: Int) -> TimelinePiece in
            let source: Double = Double(index) * 0.04, edited: Double = Double(index) * 0.03
            return TimelinePiece(source: source..<(source + 0.03), edited: edited..<(edited + 0.03))
        }
        let (lane, window) = lane(pieces)
        defer { window.close() }
        #expect(lane.drawn.boxes == 1)
        #expect(lane.drawn.columns == 60)
        // Between the seams (each the point left of a cut), above the waveform.
        let pixels = try Pixels(lane)
        let seams = lane.drawn.seams.map { $0 - 1..<$0 }
        let clear = stride(from: TimelineMetrics.header + 22, to: TimelineMetrics.header + 78, by: 1).filter { point in
            !seams.contains { $0.overlaps(point..<point + 1) }
        }
        #expect(clear.count > 5)
        for point in clear { #expect(try pixels.shows(point + 0.5, 5.5, "timeline.audioPiece")) }
    }

    /// Until the waveform arrives (or with no media to read) A1 draws one capsule per kept
    /// word (design §5.4.10); when it arrives A1 draws it, and only A1 redraws.
    @Test func a1RedrawsWhenTheWaveformArrives() throws {
        let app = try app()
        var project = try project()
        project.edits.cutWordIds = ["t12"]
        let model = editor(app, project: project)
        defer { model.close() }
        model.sourceTime = 17.4
        model.playhead = model.timelineTime(source: 17.4, on: .edited)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        #expect(canvas.audio.drawn.columns == 0 && canvas.audio.drawn.capsules == 19)
        let pixels = try Pixels(canvas)
        let mid = TimelineMetrics.audio.y + TimelineMetrics.audio.height / 2
        func x(_ source: Double) -> CGFloat { TimelineMetrics.header + CGFloat(canvas.viewport.x(model.timelineTime(source: source, on: .edited))) }
        #expect(try pixels.shows(x(21.4), mid, "timeline.wave"))
        #expect(try pixels.shows(x(21.4), mid - 5, "timeline.audioPiece"))
        #expect(try pixels.shows(x(21.9), mid, "timeline.audioPiece"))
        let ruler = canvas.ruler.invalidations, audio = canvas.audio.invalidations
        model.waveform = DebugTimeline.speech(words: model.words, duration: 60)
        canvas.renderContent()
        #expect(canvas.audio.invalidations == audio + 1 && canvas.ruler.invalidations == ruler)
        canvas.audio.layer?.displayIfNeeded()
        #expect(canvas.audio.drawn.columns > 100)
        // The same load again changes nothing.
        canvas.renderContent()
        #expect(canvas.audio.invalidations == audio + 1)
    }

    // MARK: The waveform pyramid

    /// notes.md §6: nothing is drawn in silence, down to one silent 10 ms frame at a zoom
    /// where a point is 10 ms; the column beside it draws.
    @Test func aSilentTenMillisecondRunDrawsNothing() throws {
        var fine = [Float](repeating: 0.08, count: 1_000)
        fine[300] = 0
        let waveform = WaveformData(fine: fine)
        #expect(waveform.column(from: 3.0, to: 3.01) == (0, 0))
        #expect(waveform.column(from: 2.99, to: 3.0).core > 0)
        #expect(waveform.column(from: 3.01, to: 3.02).peak > 0)
        // Quiet room tone 30 dB under the voice is silence too.
        fine[400] = 0.08 * 0.03
        #expect(WaveformData(fine: fine).column(from: 4.0, to: 4.01) == (0, 0))
        // Drawn: at 100 pt/s the silent frame is one blank column of the piece.
        let lane = TimelineAudioLane()
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1056, height: 44), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = lane
        defer { window.close() }
        lane.frame = NSRect(x: 0, y: 0, width: 1056, height: 44)
        lane.state = TimelineAudioLane.State(viewport: TimelineViewport(axis: .edited, ptPerSecond: 100, origin: 2.5, width: 944),
                                             pieces: TimelinePieces([TimelinePiece(source: 0..<10, edited: 0..<10)]), waveform: waveform, takeLength: 10)
        lane.layer?.displayIfNeeded()
        let pixels = try Pixels(lane)
        let silent = TimelineMetrics.header + 50.5
        #expect(try pixels.shows(silent, 22, "timeline.audioPiece"))
        #expect(try pixels.shows(silent - 1, 22, "timeline.wave"))
        #expect(try pixels.shows(silent + 1, 22, "timeline.wave"))
    }

    /// notes.md §6: typical peaks reach 55–70% of the half-height, and the core sits inside
    /// them. Measured on a minute of speech from a whole take's zoom to 10 ms a point, f1's
    /// 20.7 pt/s among them.
    @Test func typicalPeaksReachFiftyFiveToSeventyPercent() throws {
        let words = (0..<60).map { TimedWord(id: "t\($0)", text: "word", start: Double($0), end: Double($0) + 0.8) }
        let waveform = DebugTimeline.speech(words: words, duration: 60)
        for ptPerSecond in [936 / 45.2, 3, 8, 40, 100] {
            let step = 1 / ptPerSecond
            let columns = stride(from: 0.0, to: 60, by: step).map { waveform.column(from: $0, to: $0 + step) }.filter { $0.peak > 0 }
            let peaks = columns.map(\.peak).sorted()
            let median = peaks[peaks.count / 2]
            #expect(median >= 0.55 && median <= 0.70, "median peak \(median) at \(ptPerSecond) pt/s")
            #expect(columns.allSatisfy { $0.core <= $0.peak })
        }
        // A column a piece ends inside keeps the whole column's scale, so the columns at a
        // seam are no taller than their neighbours.
        let alternating = WaveformData(fine: (0..<400).map { $0 % 4 == 0 ? 0.1 : 0.02 })
        let whole = alternating.column(from: 1.0, to: 1.048), edge = alternating.column(from: 1.034, to: 1.048, span: 0.048)
        #expect(whole.peak > 0.5 && edge.peak <= whole.peak + 1e-6)
        #expect(alternating.column(from: 1.034, to: 1.048).peak > whole.peak)
        // A level of a 60-minute envelope folds four frames of the one below it.
        let hour = WaveformData(fine: [Float](repeating: 0.1, count: 360_000))
        #expect(hour.levels.map(\.max.count) == [360_000, 90_000, 22_500, 5_625])
        #expect(hour.byteCount < 4 << 20)
    }

    /// The column at each lane point of `seconds` at `ptPerSecond`, and whether it is a
    /// pause: every 10 ms frame within 100 ms of it under −45 dBFS.
    private func columns(_ waveform: WaveformData, seconds: Double, ptPerSecond: Double) -> [(peak: Float, pause: Bool)] {
        let step = 1 / ptPerSecond, quiet = Float(pow(10, -45.0 / 20))
        return stride(from: 0.0, to: seconds, by: step).map { start in
            let lower = max(0, Int((start - 0.1) * 100)), upper = min(waveform.fine.count, Int(((start + step + 0.1) * 100).rounded(.up)))
            return (waveform.column(from: start, to: start + step, span: step).peak, lower < upper && waveform.fine[lower..<upper].allSatisfy { $0 < quiet })
        }
    }

    /// notes.md §6 on `waveform` at the timeline's zooms: no pause draws (not even a centre
    /// line), fewer than 10% of the voiced columns reach the top, and their median peak is
    /// within `typical` of the half-height.
    private func expectSpeech(_ waveform: WaveformData, seconds: Double, typical: ClosedRange<Float>, _ name: String) {
        let half = Float(TimelineMetrics.audio.height / 2 - TimelineAudioLane.pieceInset - TimelineAudioLane.waveInset)
        for ptPerSecond in [3, 8, 936 / 45.2, 40, 100] {
            let all = columns(waveform, seconds: seconds, ptPerSecond: ptPerSecond)
            let pauses = all.filter(\.pause), voiced = all.filter { !$0.pause && $0.peak * half >= 0.5 }.map(\.peak).sorted()
            let drawn = pauses.filter { $0.peak * half >= 0.5 }.count
            #expect(drawn == 0, "\(name): \(drawn) of \(pauses.count) pause columns draw at \(ptPerSecond) pt/s")
            guard !voiced.isEmpty else { Issue.record("\(name): nothing voiced at \(ptPerSecond) pt/s"); continue }
            let top = voiced.filter { $0 >= 0.99 }.count, median = voiced[voiced.count / 2]
            #expect(top * 10 < voiced.count, "\(name): \(top) of \(voiced.count) voiced columns reach the top at \(ptPerSecond) pt/s")
            #expect(typical.contains(median), "\(name): median peak \(median) at \(ptPerSecond) pt/s")
        }
    }

    /// Real speech, decoded as the cache decodes a take: four LibriSpeech readings whose
    /// pauses hold room tone between −60 and −45 dBFS. Six seconds each, so a median holds a
    /// few dozen columns at a whole take's zoom: 50–75% here, 55–70% on the minute above.
    @Test func realSpeechDrawsNothingInItsPausesAndRarelyReachesTheTop() async throws {
        let shared = try SharedResources.locate()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-waveform-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let loader = WaveformCache()
        for name in ["1089-134686-0000", "1089-134686-0002", "1188-133604-0000", "1188-133604-0001"] {
            let source = shared.root.appendingPathComponent("fixtures/voice-lab/speaker/\(name).wav")
            let waveform = try #require(await loader.load(.init(contentKey: "fixture-\(name)", source: source, cache: cache)))
            #expect(waveform.fine.count == 600)
            expectSpeech(waveform, seconds: 6, typical: 0.5...0.75, name)
        }
    }

    /// A phone or laptop take: two minutes of speech with pauses most of the time (57%)
    /// holding −50 dBFS room tone, ±3 dB. The room is not voice: it draws nothing, and it
    /// does not set the scale.
    @Test func roomToneIsSilenceAndDoesNotSetTheScale() {
        let words = (0..<60).map { TimedWord(id: "t\($0)", text: "word", start: Double($0) * 2, end: Double($0) * 2 + 0.86) }
        var fine = DebugTimeline.speech(words: words, duration: 120).fine
        var seed: UInt32 = 7
        for index in fine.indices where fine[index] == 0 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            // Typed steps: as one expression hosted CI's Xcode 26 gave up type-checking it.
            let spread: Double = 6 * Double(seed >> 8) / Double(1 << 24)
            let level: Double = -50 + spread - 3
            fine[index] = Float(pow(10, level / 20))
        }
        #expect(fine.filter { $0 < 0.005 }.count * 100 / fine.count >= 55)
        expectSpeech(WaveformData(fine: fine), seconds: 120, typical: 0.55...0.70, "room tone")
    }

    /// impl-plan §3.1's 60-minute gate times Source as it draws: with
    /// Show cuts on and a clip open, its frames draw the removed ranges and the take outside
    /// In/Out, and its full redraw is timed with Edited's.
    @Test func thePerformanceGateTimesSourceWithItsCutsAndInOut() async throws {
        let app = try app()
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let directory = app.locations.root.appendingPathComponent("performance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let results = try await DebugTimeline.performance(app: app, fixture: fixture, directory: directory)
        let source = try #require(results.first { $0.name.contains("Source frames draw the removed ranges and the take outside In/Out") })
        #expect(source.passed, "\(source.name)")
        #expect(results.contains { $0.name.contains("full redraw on Edited and Source") })
        for result in results { #expect(result.passed, "\(result.name)") }
    }

    // MARK: The waveform

    /// impl-plan §3.1: the model loads the waveform when the media is there, so a hidden
    /// timeline (or none) never starves the audiogram stand-in or Rewrite.
    @Test func theWaveformLoadsWithNoTimeline() async throws {
        let app = try app()
        var project = try project()
        let key = String(repeating: "c", count: 64)
        project.media.source.contentKey = key
        project.media.source.absolutePath = app.locations.root.appendingPathComponent("absent.mov").path
        let entry = app.locations.cache.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let samples: [Float] = [0.1, 0.4, 0.2, 0.6, 0.3]
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: entry.appendingPathComponent("envelope-10ms.f32"))
        var metadata = CacheEntry(contentKey: key, createdAt: Date(), lastAccessAt: Date(), bytes: Int64(data.count))
        metadata.envelope = CacheEnvelope(sampleRate: 48_000, count: samples.count)
        try ProjectJSON.encoder().encode(metadata).write(to: entry.appendingPathComponent("meta.json"))
        let model = editor(app, project: project, demo: false)
        defer { model.close() }
        #expect(model.waveform == nil && model.waveformTask == nil)
        model.mediaResolved = true
        let task = try #require(model.waveformTask)
        await task.value
        #expect(model.waveform?.fine == samples)
        // The same media does not load again; missing media drops the request.
        model.refresh()
        #expect(model.waveformTask == task)
        model.mediaResolved = false
        #expect(model.waveformKey == nil)
    }
    // MARK: Timeline II (V9)
    @Test func trackHeightsAndHeadersFollowTheWindowWithoutEditing() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        let shell = WorkspaceShell(app: app)
        let canvas = TimelineCanvasView(model: model, shell: shell)
        defer { canvas.tearDown() }
        let steps = model.undoSteps
        #expect(TrackHeight.small.heights == [20, 20, 20, 20, 28, 32, 20, 20])
        #expect(TrackHeight.medium.heights == [24, 24, 24, 24, 36, 44, 24, 24])
        #expect(TrackHeight.large.heights == [28, 28, 28, 28, 52, 64, 40, 40])
        for height in TrackHeight.allCases {
            shell.layout.trackHeight = height
            canvas.layoutSubtreeIfNeeded(); canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
            #expect(canvas.trackLanes.map { $0.frame.height } == height.heights)
        }
        #expect(canvas.header(.video).button.isHidden)
        #expect(canvas.header(.captions).button.accessibilityLabel() == "CC Captions, shown")
        canvas.header(.voice).action?()
        #expect(model.previewMuted)
        #expect(model.undoSteps == steps)
        shell.layout.windowWidth = 960
        canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
        #expect(canvas.headerWidth == 64 && canvas.audio.headerWidth == 64)
        #expect(canvas.verticalMaximum > 0)
        #expect(!canvas.verticalScroller.isHidden)
        #expect(!model.document.isDocumentEdited)
        shell.layout.workHeight = 700
        let normalHeight = shell.layout.timelineHeight
        shell.layout.timelineMaximized = true
        #expect(shell.layout.timelineHeight == 700 - Double(ShellMetrics.topMinimum) - 1)
        shell.layout.timelineMaximized = false
        #expect(shell.layout.timelineHeight == normalHeight)
        shell.layout.timelineMaximized = true
        shell.layout.rememberTimelineHeight(220)
        #expect(!shell.layout.timelineMaximized && shell.layout.timelineHeight == 220)
        shell.layout.trackHeight = .medium
        canvas.setFrameSize(NSSize(width: 960, height: 155)) // 183 pt panel, including toolbar
        canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
        canvas.verticalScroller.changed?(0)
        #expect(canvas.captions.frame.maxY <= canvas.trackClip.bounds.height && canvas.audio.frame.minY >= canvas.trackClip.bounds.height)
        canvas.verticalScroller.changed?(1)
        #expect(canvas.music.frame.minY >= 0 && canvas.music.frame.maxY <= canvas.trackClip.bounds.height)
    }

    @Test(arguments: [CGFloat(1), 2], [NSAppearance.Name.aqua, .darkAqua]) func captionLaneFitsWholeWordsAndLeavesAOnePointSeam(backingScale: CGFloat, appearance: NSAppearance.Name) throws {
        let lane = CaptionLane(frame: NSRect(x: 0, y: 0, width: 500, height: 24))
        lane.state = .init(viewport: .init(axis: .edited, ptPerSecond: 30, origin: 0, width: 388), cues: [
            TimelineCue(range: 0..<2, text: "And one cool feature"),
            TimelineCue(range: 2..<4, text: "we added today"),
            TimelineCue(range: 4..<4.7, text: "So")
        ])
        lane.appearance = NSAppearance(named: appearance)
        let pixels = try Pixels(lane, backingScale: backingScale)
        #expect(lane.blocks.count == 3)
        #expect(lane.blocks[1].minX - lane.blocks[0].maxX == 1)
        #expect(lane.textBlocks.allSatisfy { $0 >= 24 })
        #expect(lane.textBlocks.count == 2 && lane.ellipses == 2)
        #expect(try pixels.shows(171.5, 12, "timeline.lane"))
        #expect(try pixels.shows(lane.blocks[0].midX, 3 + 1 / pixels.scale, "timeline.cue"))
        for height in [20.0, 28] {
            lane.setFrameSize(NSSize(width: 500, height: height))
            _ = try Pixels(lane)
            #expect(lane.blocks.allSatisfy { $0.height == 20 })
        }
        let empty = CaptionLane(frame: lane.frame)
        _ = try Pixels(empty)
        #expect(empty.blocks.isEmpty)
    }

    @Test(arguments: [CGFloat(1), 2], [NSAppearance.Name.aqua, .darkAqua]) func sourceCaptionSpansDarkenOnlyTheCutInsideThem(backingScale: CGFloat, appearance: NSAppearance.Name) throws {
        let lane = CaptionLane(frame: NSRect(x: 0, y: 0, width: 500, height: 24))
        lane.state = .init(viewport: .init(axis: .source, ptPerSecond: 30, origin: 10, width: 388), cues: [TimelineCue(range: 10..<15, text: "And one cool", cuts: [12..<13])])
        lane.appearance = NSAppearance(named: appearance)
        let pixels = try Pixels(lane, backingScale: backingScale)
        #expect(lane.blocks.count == 1)
        #expect(try pixels.shows(160, 4, "timeline.cue"))
        #expect(try pixels.shows(185, 4, "timeline.lane", alpha: 0.42, over: "timeline.cue"))
        lane.state.inOut = 11...14
        let dimmed = try Pixels(lane, backingScale: backingScale)
        #expect(try dimmed.shows(127, 4, "timeline.cue", alpha: 0.32, over: "timeline.lane"))
    }

    @Test func videoNameThresholdSeamsAndSourceDimming() throws {
        let lane = VideoLane(frame: NSRect(x: 0, y: 0, width: 500, height: 36))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 500, height: 36), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = lane
        defer { window.close() }
        lane.mediaName = "…0075_D"
        lane.state = .init(viewport: .init(axis: .edited, ptPerSecond: 30, origin: 0, width: 388), pieces: TimelinePieces([
            TimelinePiece(source: 10..<13, edited: 0..<3), TimelinePiece(source: 14..<15, edited: 3..<4)
        ]), takeLength: 30)
        _ = try Pixels(lane)
        #expect(lane.names == 1)
        #expect(lane.seams == [202])
        lane.state.viewport = .init(axis: .source, ptPerSecond: 20, origin: 8, width: 388)
        lane.state.inOut = 10...15; lane.state.clip = 10...15
        let pixels = try Pixels(lane)
        #expect(lane.dimmed == 2 && lane.seams.isEmpty)
        let expected = try DebugTimeline.swatch("timeline.videoPiece", alpha: 0.32, over: "timeline.lane")
        #expect(try pixels.shows(122, 20, "timeline.videoPiece", alpha: 0.32, over: "timeline.lane"), "actual \(pixels.at(122, 20)), expected \(expected)")
        #expect(try pixels.shows(222, 20, "timeline.lane")) // cut 13–14
    }

    @Test func zoomAndScrollStayBoundedAndNeverDirtyTheDocument() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let width = canvas.bounds.width, original = canvas.viewport
        let steps = model.undoSteps
        canvas.zoom(by: 4, anchor: 200)
        #expect(abs(original.time(atX: 200) - canvas.viewport.time(atX: 200)) < 1e-9)
        #expect(!canvas.horizontalScroller.isHidden)
        canvas.scroll(to: 1)
        #expect(canvas.viewport.origin > original.origin)
        #expect(canvas.bounds.width == width && canvas.audio.bounds.width == width)
        canvas.setZoom(0)
        #expect(abs(canvas.viewport.ptPerSecond - canvas.zoomMinimum) < 1e-9)
        #expect(model.undoSteps == steps && !model.document.isDocumentEdited)
    }

    @Test func zoomKeysActOnTheKeyVersionsTimelineWithoutAChange() throws {
        _ = NSApplication.shared
        let app = try app(), version = VoxClipDocument(project: try project(), demo: true)
        version.versionForTesting = true
        let controller = VersionWindowController(version: version, app: app)
        defer { version.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        let editor = try #require(controller.shell.editor)
        editor.focusedPane = .timeline
        let delegate = AppDelegate()
        delegate.commandWindowForTesting = controller.window
        defer { delegate.commandWindowForTesting = nil }
        let action = NSSelectorFromString("performEditorCommand:")
        for (tag, key, expected) in [(18, "=", 1), (19, "-", 0), (18, "+", 1)] {
            let item = NSMenuItem(title: "Zoom", action: action, keyEquivalent: key)
            item.tag = tag; item.keyEquivalentModifierMask = .command
            #expect(delegate.validateMenuItem(item))
            if tag == 19 { #expect(item.title == "Zoom Timeline Out") }
            _ = delegate.perform(action, with: item)
            #expect(editor.timelineZoomStep == expected)
        }
        let menu = NSMenu(title: "View")
        delegate.addZoomCommands(to: menu)
        #expect(Set(menu.items.filter { !$0.isHidden }.map(\.tag)).count == menu.items.filter { !$0.isHidden }.count)
        #expect(menu.items.filter { $0.tag == 18 }.count == 2)
        #expect(Set(menu.items.map(\.keyEquivalent)).count == menu.items.count)
        for item in menu.items { #expect(delegate.validateMenuItem(item)) }
        #expect(menu.items.filter { !$0.isHidden && $0.title == "Zoom Timeline In" }.count == 1)
        #expect(menu.items.filter { !$0.isHidden && $0.title == "Zoom Timeline Out" }.count == 1)
        editor.focusedPane = .transcript
        let textSize = editor.textSize
        for (tag, expected) in [(18, textSize + 1), (19, textSize), (18, textSize + 1)] {
            let item = try #require(menu.items.first { $0.tag == tag })
            #expect(delegate.validateMenuItem(item))
            #expect(item.title == (tag == 19 ? "Smaller Text" : "Bigger Text"))
            _ = delegate.perform(action, with: item)
            #expect(editor.textSize == expected && editor.timelineZoomStep == 1)
        }
        editor.zoom(3)
        let actual = try #require(menu.items.first { $0.tag == 20 })
        #expect(delegate.validateMenuItem(actual))
        _ = delegate.perform(action, with: actual)
        #expect(editor.textSize == DesignValues.transcriptTextSize, "Actual Size targets Versions too")
        #expect(menu.items.filter { $0.tag == 18 && !$0.isHidden }.map(\.keyEquivalent) == ["="])
        #expect(menu.items.filter { $0.tag == 18 && $0.isHidden }.map(\.keyEquivalent) == ["+"])
        #expect(!version.isDocumentEdited && !version.hasUnautosavedChanges)
    }

    @Test func onlyLiveCanvasReceivesZoomCommands() async throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        model.timelineZoomStep = 3
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let fit = TimelineViewport.fitting(0...max(1, model.duration), width: canvas.viewport.width, axis: .edited)
        #expect(abs(canvas.viewport.ptPerSecond - fit.ptPerSecond) < 0.001, "A rebuilt canvas does not replay earlier zoom keys")
        let before = canvas.viewport.ptPerSecond
        model.timelineZoomStep += 1
        for _ in 0..<20 { await Task.yield() }
        #expect(abs(canvas.viewport.ptPerSecond - before * 1.4) < 0.001, "A live canvas applies each new step once")
        #expect(canvas.toolTip?.contains("Drag an In or Out bracket") == true)
    }

    @Test func captionPagesStayEmptyUntilLoadedAndFollowCutsBeforeTheNextLayout() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        #expect(model.timelineCaptionCues(on: .edited).isEmpty)
        model.captionPages = DebugTimeline.captionPages(model)
        let before = model.timelineCaptionCues(on: .edited)
        #expect(!before.isEmpty)
        let count = before.reduce(0) { $0 + $1.text.split(separator: " ").count }
        model.selectedWordIDs = ["t11"]
        model.cutSelection()
        let after = model.timelineCaptionCues(on: .edited)
        #expect(after.reduce(0) { $0 + $1.text.split(separator: " ").count } == count - 1)
        let source = model.timelineCaptionCues(on: .source, removed: model.timelineRemovedRanges(model.timelinePieces))
        #expect(source.map(\.text) == after.map(\.text))
        #expect(source.contains { !$0.cuts.isEmpty })
        model.activate(nil)
        #expect(model.captionPages.isEmpty && model.timelineCaptionCues(on: .edited).isEmpty)
        model.captionPages = DebugTimeline.captionPages(model)
        model.setCaptionsEnabled(false)
        #expect(model.timelineCaptionCues(on: .edited).isEmpty)
    }

    @Test func toolbarControlsFitAndDropInTheSpecifiedOrder() throws {
        let app = try app()
        let root = app.locations.root
        defer { #expect(!FileManager.default.fileExists(atPath: root.path), "Toolbar captures are removed with their test data") }
        defer { try? FileManager.default.removeItem(at: root) }
        let model = editor(app, project: try project())
        defer { model.close() }
        let shell = WorkspaceShell(app: app)
        model.selectedWordIDs = ["t20", "t21", "t22", "t23"]
        for width in [1056.0, 960, 840, 800, 700] {
            let size = NSSize(width: width, height: 28)
            let host = ShellHost.controller(TimelineToolbar(model: model, shell: shell), app: app)
            host.view.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentViewController = host
            defer { window.close() }
            host.view.layoutSubtreeIfNeeded()
            let rects = DebugRightColumn.markers(in: host.view)
            for (name, rect) in rects {
                #expect(rect.minX >= -0.5 && rect.maxX <= width + 0.5, "\(name) at \(width): \(rect)")
            }
            for name in ["timeline.zoom.out", "timeline.zoom.in", "timeline.maximize", "timeline.hide"] { #expect(rects[name] != nil) }
            #expect((rects["timeline.trackHeight"] != nil) == (width >= 840))
            #expect((rects["timeline.zoom.slider"] != nil) == (width >= 800))
            #expect((rects["timeline.snapping"] != nil) == (width >= 720))
            if width == 1056 { #expect(rects["timeline.sourceReadout"] != nil && rects["timeline.selectionLength"] != nil) }
            if width == 1056 || width == 700 {
                let bitmap = try DebugTimeline.sRGBBitmap(of: host.view)
                let file = app.locations.root.appendingPathComponent("toolbar-\(Int(width)).png")
                try FileManager.default.createDirectory(at: app.locations.root, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: file)
                print("V9 toolbar capture: \(file.path)")
            }
        }
    }

    @Test func fittedHourKeepsV1VisibleAcrossSubpointPieces() throws {
        let lane = VideoLane(frame: NSRect(x: 0, y: 0, width: 1056, height: 36))
        let pieces = (0..<1500).map { index in
            let source = Double(index) * 2.4
            let edited = Double(index) * 1.6
            return TimelinePiece(source: source..<(source + 1.6), edited: edited..<(edited + 1.6))
        }
        lane.everyFrame = DebugTimeline.filmstripFrame()
        lane.state = .init(viewport: .fitting(0...2400, width: 944, axis: .edited), pieces: TimelinePieces(pieces), takeLength: 3600)
        _ = try Pixels(lane)
        #expect(lane.tiles > 10)
        #expect(lane.names == 0, "Coalescing subpoint pieces must not invent a wide piece's name strip")
    }

    // MARK: Timeline III

    private func timelineKey(_ code: UInt16, _ characters: String = "", shift: Bool = false, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? flags.union(.shift) : flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    @Test(arguments: [TimelineAxis.edited, .source]) func timelineDragAndTranscriptSpanSelectTheSameOriginalIDs(_ axis: TimelineAxis) throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = axis == .source
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let y = TimelineMetrics.audio.y + 12
        func point(_ source: Double) -> NSPoint { NSPoint(x: canvas.headerWidth + canvas.viewport.x(model.timelineTime(source: source, on: axis)), y: y) }
        canvas.mouseDown(with: try mouse(.leftMouseDown, point(12), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, point(17.8), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, point(17.8), in: canvas))
        let timelineIDs = model.selectedWordIDs
        #expect(timelineIDs == Set((12...17).map { "t\($0)" }))
        #expect(canvas.ruler.state.selection == model.timelineSelection(on: axis))
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let scroll = TranscriptTextView.makeScrollView(model: model, coordinator: coordinator)
        let text = try #require(scroll.documentView as? TranscriptNSTextView)
        coordinator.updating = true
        coordinator.renderer.rebuild(model: model)
        coordinator.updating = false
        let first = try #require(text.map.span(id: "t12")), last = try #require(text.map.span(id: "t17"))
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let ranges = text.map.selectionRanges(in: span)
        model.selectedWordIDs = []
        text.selectedRanges = ranges.map { NSValue(range: $0) }
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: text))
        #expect(model.selectedWordIDs == timelineIDs, "The hidden cut's IDs are shared through transcript folds")
        // Drive a different real transcript selection, then inspect the drawn ruler
        // and wash against fixture times, independently of timelineSelection().
        let nextFirst = try #require(text.map.span(id: "t20")), nextLast = try #require(text.map.span(id: "t23"))
        text.selectedRanges = [NSValue(range: NSRange(location: nextFirst.range.location, length: NSMaxRange(nextLast.range) - nextFirst.range.location))]
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: text))
        #expect(model.selectedWordIDs == Set((20...23).map { "t\($0)" }))
        canvas.renderContent()
        let expected: ClosedRange<Double> = axis == .source ? 20...23.8 : 8.1...11.9
        let selected = try #require(canvas.content.selection)
        #expect(abs(selected.lowerBound - expected.lowerBound) < 0.000001 && abs(selected.upperBound - expected.upperBound) < 0.000001)
        #expect(canvas.ruler.state.selection == selected)
        canvas.auditViewport(.init(axis: axis, ptPerSecond: 20, origin: axis == .source ? 18 : 6, width: canvas.viewport.width))
        let lower = canvas.viewport.x(expected.lowerBound), upper = canvas.viewport.x(expected.upperBound)
        #expect(!canvas.overlay.wash.isHidden && abs(canvas.overlay.wash.frame.minX - lower) < 0.001 && abs(canvas.overlay.wash.frame.width - (upper - lower)) < 0.001)
        canvas.ruler.layer?.displayIfNeeded()
        let pixels = try Pixels(canvas.ruler)
        let tint = try DebugTimeline.swatch("tint.default")
        #expect(try pixels.shows(canvas.headerWidth + (lower + upper) / 2, 20, "tint.default"), "The transcript span draws the 3 pt ruler bar: \(pixels.at(canvas.headerWidth + (lower + upper) / 2, 20)); expected \(tint)")
        #expect(try !pixels.shows(canvas.headerWidth + lower - 2, 20, "tint.default"), "The bar starts at the selected word")
        #expect(try !pixels.shows(canvas.headerWidth + upper + 2, 20, "tint.default"), "The bar stops after the selected word")
        #expect(model.undoSteps == 0 && !model.document.isDocumentEdited)
        withExtendedLifetime((coordinator, scroll)) {}
    }

    @Test func waveformDragSelectsBackwardsAndOptionBypassesTheMagnet() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let y = TimelineMetrics.audio.y + 12
        func p(_ source: Double) -> NSPoint { NSPoint(x: canvas.headerWidth + canvas.viewport.x(source), y: y) }
        for flags: NSEvent.ModifierFlags in [[], [.option]] {
            canvas.mouseDown(with: try mouse(.leftMouseDown, p(17.05), in: canvas, flags: flags))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, p(12.85), in: canvas, flags: flags))
            if flags.isEmpty { #expect(model.selectedWordIDs == Set((13...16).map { "t\($0)" }) && model.timelineRange == nil) }
            else {
                // ⌥ keeps the exact range, on the frame grid; the words wholly inside it stay selected.
                #expect(model.selectedWordIDs == Set((13...16).map { "t\($0)" }))
                let preview = try #require(canvas.interaction.selection)
                #expect(abs(preview.lowerBound - 12.85) < 0.017 && abs(preview.upperBound - 17.05) < 0.017, "Within half a frame: \(preview)")
                #expect(model.timelineRange != nil)
            }
            canvas.mouseUp(with: try mouse(.leftMouseUp, p(12.85), in: canvas, flags: flags))
        }
        model.timelineSnapping = false
        canvas.mouseDown(with: try mouse(.leftMouseDown, p(12), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, p(17.05), in: canvas))
        #expect(model.selectedWordIDs == Set((12...16).map { "t\($0)" }) && model.timelineRange != nil)
    }

    @Test func cuttingAPauseOrSpanningItNeverSubstitutesANearbyWord() throws {
        var project = try project()
        project.transcript?.words.removeAll { $0.id == "t20" || $0.id == "t21" }
        let app = try app(), model = editor(app, project: project), undo = UndoManager()
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        undo.groupsByEvent = false; model.undoManager = undo
        let pause = try #require(model.pause(at: 20.5))
        for snap in [false, true] {
            _ = model.selectTimeline(from: 21.5, to: 20.5, on: .source, snap: snap)
            #expect(model.selectedWordIDs.isEmpty && model.selectedPauseIDs == [pause.id])
        }
        undo.beginUndoGrouping(); model.cutSelection(); undo.endUndoGrouping()
        #expect(model.cutPauseIDs.contains(pause.id) && model.cutWordIDs == ["t14", "t15"] && !model.timelineCanCut)
        undo.undo()
        _ = model.selectTimeline(from: 19.1, to: 22.6, on: .source, snap: false)
        #expect(model.selectedWordIDs == ["t19", "t22"] && model.selectedPauseIDs.contains(pause.id))
        undo.beginUndoGrouping(); model.cutSelection(); undo.endUndoGrouping()
        #expect(model.cutPauseIDs.contains(pause.id) && model.cutWordIDs == ["t14", "t15", "t19", "t22"])
        undo.undo(); #expect(model.cutPauseIDs.isEmpty && model.cutWordIDs == ["t14", "t15"])
    }

    @Test func optionTrimShowsTheExactSourceEdgeBeforeRelease() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        func p(_ time: Double) -> NSPoint { NSPoint(x: canvas.headerWidth + canvas.viewport.x(time), y: TimelineMetrics.ruler.y + 10) }
        let old = try #require(model.scopeSourceRange), drop = p(25.36)
        canvas.mouseDown(with: try mouse(.leftMouseDown, p(old.upperBound), in: canvas, flags: [.option]))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, drop, in: canvas, flags: [.option]))
        let preview = try #require(canvas.ruler.state.inOut)
        #expect(abs(preview.upperBound - 25.9) < 0.00001 && model.scopeSourceRange == old)
        canvas.mouseUp(with: try mouse(.leftMouseUp, drop, in: canvas, flags: [.option]))
        #expect(model.scopeSourceRange == preview && model.activeClip?.endWordId == "t25")
    }

    @Test func editActionsFitInAShallowOrExpandedTimeline() throws {
        let app = try app(), model = editor(app, project: try project()), shell = WorkspaceShell(app: app)
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        for size in [NSSize(width: 700, height: 100), NSSize(width: 700, height: 210)] {
            let host = ShellHost.controller(TimelinePanel(model: model, shell: shell), app: app)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = host
            defer { window.close() }
            host.view.frame = CGRect(origin: .zero, size: size); host.view.layoutSubtreeIfNeeded()
            let rects = DebugRightColumn.markers(in: host.view)
            let action = try #require(rects[size.height < 175 ? "timeline.editMenu" : "timeline.cutSelection"])
            #expect(action.width > 5 && action.minX >= 0 && action.maxX <= size.width)
            #expect(try #require(rects["timeline.hide"]).maxX <= size.width + 0.5)
        }
    }

    @Test func savedTitleIsEditableAfterReopenWithoutTheOriginatingRun() throws {
        let app = try app(), first = editor(app, project: try project())
        defer { first.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        first.sourceTime = 18.5
        try first.addTimelineTitle("First title")
        let model = editor(app, project: try JSONProjectStore.decode(JSONProjectStore.encode(first.project)))
        defer { model.close() }
        let title = try #require(model.timelineEditableEffects.first), undo = UndoManager()
        undo.groupsByEvent = false; model.undoManager = undo
        #expect(title.start == 18.5 && title.end == 20.5 && model.askClaude.run == nil)
        model.adjustAskClaudeEffect(fromTimeline: title.id)
        #expect(model.timelineEffectID == title.id && model.timelineEffectsOpen)
        undo.beginUndoGrouping(); model.adjustProjectEffect(title) { $0.text = "Edited title"; $0.position = .bottom }; undo.endUndoGrouping()
        let saved = try JSONProjectStore.decode(JSONProjectStore.encode(model.project))
        #expect(saved.clipEffects.first?.text == "Edited title" && saved.clipEffects.first?.position == .bottom)
        let edited = model.project
        model.adjustProjectEffect(title) { $0.text = "Stale" }
        #expect(model.project == edited)
        undo.undo(); #expect(model.project.clipEffects.first == title)
        undo.beginUndoGrouping(); model.apply(.removeClip(id: "clip-1"), name: "Remove clip"); undo.endUndoGrouping()
        #expect(model.timelineEditableEffects.isEmpty && model.project.clipEffects.isEmpty)
        _ = try JSONProjectStore.encode(model.project)
        undo.undo(); #expect(model.project.clipEffects.first == title)
    }

    @Test(arguments: [TimelineAxis.edited, .source], [true, false]) func trimPointerTransactionIsExactlyOneUndo(_ axis: TimelineAxis, _ start: Bool) throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = axis == .source
        let undo = UndoManager(), clip = try #require(model.activeClip)
        undo.groupsByEvent = false; model.undoManager = undo
        undo.removeAllActions()
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let old = try #require(canvas.content.inOut)
        func p(_ time: Double) -> NSPoint { NSPoint(x: canvas.headerWidth + canvas.viewport.x(time), y: TimelineMetrics.ruler.y + 11) }
        let begin = p(start ? old.lowerBound : old.upperBound)
        canvas.mouseDown(with: try mouse(.leftMouseDown, begin, in: canvas))
        for index in (start ? [11, 12, 13] : [28, 27, 26]) {
            let source = start ? model.words[index].start : model.words[index].end
            let point = p(model.timelineTime(source: source, on: axis))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, point, in: canvas))
            #expect(model.activeClip == clip && model.undoSteps == 0 && !undo.canUndo)
        }
        let source = start ? model.words[13].start : model.words[26].end
        undo.beginUndoGrouping()
        canvas.mouseUp(with: try mouse(.leftMouseUp, p(model.timelineTime(source: source, on: axis)), in: canvas))
        undo.endUndoGrouping()
        #expect(model.activeClip.map { start ? $0.startWordId : $0.endWordId } == (start ? "t13" : "t26"))
        #expect(model.undoSteps == 1 && undo.undoActionName == "Trim clip")
        undo.undo()
        #expect(model.activeClip == clip && !undo.canUndo && undo.canRedo)
        undo.redo()
        #expect(model.activeClip.map { start ? $0.startWordId : $0.endWordId } == (start ? "t13" : "t26"))
    }

    @Test(arguments: [TimelineAxis.edited, .source], [true, false]) func escapeCancelsTheMouseTrim(_ axis: TimelineAxis, _ start: Bool) throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        model.showsCuts = axis == .source
        let clip = try #require(model.activeClip), undo = UndoManager()
        undo.groupsByEvent = false; model.undoManager = undo; undo.removeAllActions()
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let range = try #require(canvas.content.inOut)
        func point(_ time: Double) -> NSPoint { NSPoint(x: canvas.headerWidth + canvas.viewport.x(time), y: TimelineMetrics.ruler.y + 11) }
        let press = point(start ? range.lowerBound : range.upperBound)
        let drop = point(model.timelineTime(source: start ? model.words[13].start : model.words[26].end, on: axis))
        canvas.mouseDown(with: try mouse(.leftMouseDown, press, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, drop, in: canvas))
        #expect(canvas.interaction.active)
        let cancelled = canvas.interaction.key(53, shift: false)
        #expect(cancelled)
        guard cancelled else { return }
        #expect(!canvas.interaction.active && canvas.interaction.inOut(range) == range)
        canvas.mouseUp(with: try mouse(.leftMouseUp, drop, in: canvas))
        #expect(model.activeClip == clip && model.undoSteps == 0 && !undo.canUndo)
    }

    @Test(arguments: [TimelineAxis.edited, .source]) func canvasAccessibilityMatchesBothAuditScenes(_ axis: TimelineAxis) throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        model.showsCuts = axis == .source
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let results = DebugTimeline.canvasAccessibilityChecks(canvas, clipNumber: 1, name: "headless")
        #expect(results.count == 2)
        for result in results { #expect(result.passed, "\(result.name)") }
    }

    @Test(arguments: [TimelineAxis.edited, .source], [true, false]) func clickingAnEdgeWithoutDraggingAddsNoUndo(_ axis: TimelineAxis, _ start: Bool) throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        model.showsCuts = axis == .source
        let clip = try #require(model.activeClip), undo = UndoManager()
        model.undoManager = undo
        defer { undo.removeAllActions() }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        // At close zoom a few pixels can mean the same word and hide this bug.
        canvas.auditViewport(.init(axis: axis, ptPerSecond: 5, origin: axis == .source ? 9 : -1, width: canvas.viewport.width))
        let edges = try #require(canvas.content.inOut)
        let edge = start ? edges.lowerBound : edges.upperBound
        let press = NSPoint(x: canvas.headerWidth + canvas.viewport.x(edge) + (start ? 4 : -4), y: TimelineMetrics.ruler.y + 11)
        for jitter in [0.0, 2.0] {
            let release = NSPoint(x: press.x + (start ? jitter : -jitter), y: press.y)
            canvas.mouseDown(with: try mouse(.leftMouseDown, press, in: canvas))
            canvas.mouseUp(with: try mouse(.leftMouseUp, release, in: canvas))
            #expect(model.activeClip == clip, "\(axis) \(start) jitter \(jitter): \(String(describing: model.activeClip?.startWordId))…\(String(describing: model.activeClip?.endWordId))")
            #expect(model.undoSteps == 0)
            #expect(!undo.canUndo)
            #expect(!model.document.isDocumentEdited)
        }
    }

    @Test func voiceOverAdjustsEachEdgeBothWaysAndHasSelectionAndZoom() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let children = try #require(canvas.accessibilityChildren())
        func slider(_ id: String) throws -> TimelineSliderElement {
            try #require(children.compactMap { $0 as? TimelineSliderElement }.first { $0.accessibilityIdentifier() == "voxclip.timeline.\(id)" })
        }
        let undo = UndoManager(), clip = try #require(model.activeClip)
        undo.groupsByEvent = false; model.undoManager = undo
        for (id, start) in [("in", true), ("out", false)] {
            let edge = try slider(id)
            undo.removeAllActions()
            let index = try #require(model.index(start ? clip.startWordId : clip.endWordId))
            undo.beginUndoGrouping()
            #expect(edge.accessibilityPerformIncrement())
            undo.endUndoGrouping()
            #expect(model.activeClip.map { start ? $0.startWordId : $0.endWordId } == model.words[index + 1].id)
            #expect(undo.undoActionName == "Trim clip")
            undo.beginUndoGrouping()
            #expect(edge.accessibilityPerformDecrement())
            undo.endUndoGrouping()
            #expect(model.activeClip == clip)
        }
        model.selectedWordIDs = ["t12", "t13"]
        let summary = try #require(children.compactMap { $0 as? TimelineSelectionElement }.first)
        #expect((summary.accessibilityValue() as? String)?.hasPrefix("2 words,") == true)
        #expect(!children.compactMap { $0 as? TimelineSliderElement }.contains { $0.accessibilityLabel() == "Timeline zoom" }, "Zoom is exposed once by the toolbar")
        #expect(canvas.accessibilityRole() == .group && canvas.accessibilityLabel() == "Timeline")
    }

    @Test func keyboardOnlyCanSelectTrimPlayAndStopInsideTheActiveTab() async throws {
        var project = try project()
        project.transcript?.words[19] = TimedWord(id: "t19", text: "word?", start: 19, end: 19.8)
        let app = try app(), model = editor(app, project: project)
        defer { model.close() }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        model.selectedWordIDs = ["t12"]
        canvas.keyDown(with: try timelineKey(124))
        #expect(model.selectedWordIDs == ["t13"])
        // The F6-focused SwiftUI panel forwards to this same path.
        #expect(canvas.interaction.key(124, shift: true))
        #expect(model.selectedWordIDs == Set((13...19).map { "t\($0)" }))
        canvas.keyDown(with: try timelineKey(123, shift: true))
        #expect(model.selectedWordIDs == Set((10...13).map { "t\($0)" }), "Reverse selection keeps its anchor")
        canvas.keyDown(with: try timelineKey(124))
        #expect(model.selectedWordIDs == ["t16"], "Edited caret skips the two folded words")
        // On the timeline I sets the exact range's In at the playhead; the clip keeps its edges (issue #41).
        for _ in 0..<100 { await Task.yield() }
        canvas.keyDown(with: try timelineKey(34, "i"))
        #expect(model.activeClip?.startWordId == "t10" && model.timelineRange?.start == model.words[16].start)
        canvas.keyDown(with: try timelineKey(37, "l"))
        #expect(model.isPlaying)
        canvas.keyDown(with: try timelineKey(40, "k"))
        #expect(!model.isPlaying)
        canvas.keyDown(with: try timelineKey(115))
        for _ in 0..<100 { await Task.yield() }
        #expect(model.sourceTime == model.words[10].start)
        canvas.keyDown(with: try timelineKey(119))
        for _ in 0..<100 { await Task.yield() }
        #expect(model.sourceTime == model.words[29].end)
        model.selectedWordIDs = ["t29"]
        canvas.keyDown(with: try timelineKey(124))
        #expect(model.selectedWordIDs == ["t29"], "Navigation never leaves the active clip tab")
    }

    @Test func scrollerOwnsItsHitRegionAndScopeChangesCancelAnEdgeDrag() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent(); canvas.zoom(by: 4)
        let frame = canvas.horizontalScroller.frame
        let hit = canvas.hitTest(canvas.convert(NSPoint(x: frame.midX, y: frame.midY), to: canvas.superview))
        #expect(hit === canvas.horizontalScroller)
        let old = try #require(canvas.content.inOut)
        let point = NSPoint(x: canvas.headerWidth + canvas.viewport.x(old.lowerBound), y: TimelineMetrics.ruler.y + 11)
        canvas.mouseDown(with: try mouse(.leftMouseDown, point, in: canvas))
        let drop = NSPoint(x: point.x + 60, y: point.y)
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, drop, in: canvas))
        model.activate(nil)
        canvas.mouseUp(with: try mouse(.leftMouseUp, drop, in: canvas))
        #expect(model.project.edits.clips.first?.startWordId == "t10" && model.undoSteps == 0)
    }

    @Test func selectionAtAnEditedSeamStopsBeforeTheClosedCut() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        let after = try #require(model.timelinePieces.pieces.first { $0.source.lowerBound >= 15.8 })
        let seam = after.edited.lowerBound
        _ = model.selectTimeline(from: model.timelineTime(source: 12, on: .edited), to: seam, on: .edited, snap: true)
        #expect(model.selectedWordIDs == ["t12", "t13"])
        #expect(model.timelineSourceTime(seam, on: .edited) >= 15.8)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let range = try #require(canvas.content.selection)
        let x = canvas.headerWidth + canvas.viewport.x((range.lowerBound + range.upperBound) / 2)
        let pixels = try Pixels(canvas)
        #expect(try pixels.shows(x, TimelineMetrics.ruler.y + 20, "tint.default"))
        #expect(try pixels.shows(x, TimelineMetrics.ruler.y + 21, "tint.default"))
        #expect(try pixels.shows(x, TimelineMetrics.tracks[TimelineItemLane.video.index].y + 18, "tint.wash", over: "timeline.videoPiece"))
        #expect(abs((canvas.overlay.wash.backgroundColor?.alpha ?? 0) - 0.07) < 0.001)
    }

    @Test func timelineInteractionScenesExerciseTheRealPointerPath() throws {
        let app = try app()
        let directory = app.locations.root.appendingPathComponent("interaction-scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("V10 scenes: \(directory.path)")
        let results = try DebugTimeline.interactionScenes(app: app, fixture: try project(), directory: directory)
        #expect(results.count == 9)
        for result in results { #expect(result.passed, "\(result.name)") }
        for name in ["v2-timeline-selection-edited", "v2-timeline-selection-source", "v2-timeline-trim-preview"] {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).png").path))
        }
    }

    @Test func motionHasAnEmptyHintAtEachHeightAndAnAccessibleHeader() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        let shell = WorkspaceShell(app: app)
        shell.layout.windowWidth = 1280
        let (canvas, window) = windowed(model, shell: shell)
        defer { canvas.tearDown(); window.close() }
        #expect(canvas.headers.count == 8)
        #expect(canvas.header(.titles).accessibilityLabel() == "T1 Titles & effects" && canvas.header(.titles).button.isHidden)
        #expect(canvas.header(.music).accessibilityLabel() == "M1 Music")
        #expect(canvas.header(.music).button.accessibilityLabel() == "Choose background music" && canvas.header(.music).action != nil)
        shell.layout.rightVisible = false
        canvas.header(.music).action?()
        #expect(shell.viewerShown && shell.panelJob(for: model) == .music)
        #expect(model.project.music.isEmpty) // Opening the browser never attaches or generates a track.
        #expect(canvas.header(.effects).accessibilityLabel() == "FX Zoom, looks & speed")
        #expect(canvas.header(.effects).button.accessibilityLabel() == "Edit clip motion cues")
        #expect(!canvas.header(.effects).button.isHidden && canvas.header(.effects).action != nil)
        let expected: [CGFloat] = [20, 24, 28]
        for (index, height) in TrackHeight.allCases.enumerated() {
            shell.layout.trackHeight = height
            canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded(); canvas.renderContent()
            canvas.verticalScroller.changed?(1)
            #expect(canvas.motion.frame.height == expected[index])
            let bitmap = try DebugTimeline.sRGBBitmap(of: canvas.motion)
            let scale = Double(bitmap.pixelsWide) / canvas.motion.bounds.width
            let ground = try DebugTimeline.swatch("timeline.lane")
            var ink = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in Int((canvas.headerWidth + 10) * scale)..<Int((canvas.headerWidth + 180) * scale) {
                    let pixel = DebugTimeline.pixel(bitmap, x: x, y: y)
                    if zip(pixel.prefix(3), ground.prefix(3)).contains(where: { abs($0 - $1) > 0.035 }) { ink += 1 }
                }
            }
            #expect(ink > 50, "FX hint must be drawn, not just exposed as a string")
        }
        #expect(model.undoSteps == 0 && !model.document.isDocumentEdited)
    }

    @Test func motionHeightAndHintScenesPassWithoutShowingWindows() throws {
        let app = try app()
        let directory = app.locations.root.appendingPathComponent("motion-scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("V9b scenes: \(directory.path)")
        let results = try DebugTimeline.motionScenes(app: app, fixture: try project(), directory: directory)
        #expect(results.count == 11)
        for result in results { #expect(result.passed, "\(result.name)") }
        for name in ["s", "m", "l", "short-scrolled"] {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("v2-timeline-motion-\(name).png").path))
        }
    }

}
#endif
