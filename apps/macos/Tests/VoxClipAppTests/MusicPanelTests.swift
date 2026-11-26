#if DEBUG
import AppKit
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

@MainActor private final class StubAudition: MusicAuditioning {
    var played: [URL] = []
    var stops = 0
    var completion: (@MainActor @Sendable (Bool) -> Void)?
    func play(_ url: URL, finished: @escaping @MainActor @Sendable (Bool) -> Void) { played.append(url); completion = finished }
    func stop() { stops += 1 }
}

private final class FetchLog: Sendable {
    private let value = Mutex<[String]>([])
    var ids: [String] { value.withLock { $0 } }
    func record(_ id: String) { value.withLock { $0.append(id) } }
}

private actor DelayedCatalog {
    private var pending: CheckedContinuation<MusicCatalogPage, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func search() async -> MusicCatalogPage {
        await withCheckedContinuation { continuation in
            pending = continuation
            waiting?.resume()
            waiting = nil
        }
    }

    func started() async {
        guard pending == nil else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func finish(_ page: MusicCatalogPage) { pending?.resume(returning: page); pending = nil }
}

/// The Music section (doc/spec/music.md §6) on a demo editor with its own data folder: no network, no keychain, no
/// window. Every source is a stub; the audio is synthetic.
@Suite("Music section", .serialized, .offlineFixtures)
@MainActor struct MusicPanelTests {
    private struct Fixture {
        let root: URL
        let folder: URL
        let app: AppModel
        let editor: EditorModel
        let audition: StubAudition
        let fetches: FetchLog
    }

    private static func wavBytes(seconds: Double = 2) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-music-app-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PCMFile(url: url, rate: 48_000, channels: 2, float: false)
        var state: UInt32 = 1
        let samples = (0..<Int(seconds * 96_000)).map { _ -> Int16 in state = state &* 1_664_525 &+ 1_013_904_223; return Int16(truncatingIfNeeded: state >> 20) }
        try file.append(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        try file.finish()
        return try Data(contentsOf: url)
    }

    nonisolated private static let library = MusicCandidate(id: "openverse-piano", source: .library, title: "Quiet piano", creator: "Artist", license: .by,
                                                attribution: "\"Quiet piano\" by Artist is licensed under CC BY 3.0.",
                                                sourceUrl: "https://www.jamendo.com/track/1", audioURL: URL(string: "https://example.com/piano.mp3"),
                                                fileExtension: "wav", durationSeconds: 120, reason: "calm, piano")
    private static func generated() -> MusicCandidate {
        MusicCandidate(id: "eleven-1", source: .generated, title: "Calm piano", license: .generated, fileExtension: "wav",
                       prompt: "Instrumental background music, calm piano mood", durationSeconds: 30,
                       estimate: CostEstimate(provider: "elevenlabs", operation: "musicCompose", units: 30, unit: "second", usd: Decimal(string: "0.075"), basis: "list-2026-11-04"))
    }

    private func fixture(suggest: MusicSuggestionResult = MusicSuggestionResult(), fail: Bool = false, files: [String] = []) throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-music-panel-" + UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("My Music", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files { try Self.wavBytes(seconds: 1).write(to: folder.appendingPathComponent(name)) }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        editor.mediaResolved = true
        editor.refresh()
        let audition = StubAudition(), fetches = FetchLog()
        let bytes = try Self.wavBytes()
        editor.musicPanel.audition = audition
        editor.musicPanel.services = MusicPanelServices(
            suggest: { _, _ in suggest },
            fetch: { candidate in
                fetches.record(candidate.id)
                if fail { throw VoxClipError.providerError("Eleven Music replied 500", provider: "elevenlabs", status: 500) }
                return bytes
            },
            folder: { folder },
            browse: { _, _, _ in .init(candidates: suggest.candidates.filter { $0.source == .library }) },
            price: { _, _ in .init(candidates: suggest.candidates.filter { $0.source == .generated }, notes: suggest.notes) })
        editor.musicPanel.syncScope(model: editor)
        return Fixture(root: root, folder: folder, app: app, editor: editor, audition: audition, fetches: fetches)
    }

    private func quote(_ fixture: Fixture) async {
        let panel = fixture.editor.musicPanel
        panel.prompt = Self.generated().prompt ?? ""
        panel.priceGeneration(model: fixture.editor)
        await panel.settled()
    }

    @Test func withoutSuggestionsItListsTheMusicFolderAndNamesTheNextStep() throws {
        let fixture = try fixture(files: ["calm evening.m4a", "drums.mp3", "notes.txt"])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel
        panel.loadFolder()
        #expect(panel.folderFiles.map(\.title) == ["calm evening", "drums"])
        #expect(MusicSection.footer(phase: .idle, using: nil, hasRows: true) == "Preview a track, then pick it for this clip.")
        #expect(MusicSection.footer(phase: .idle, using: nil, hasRows: false) == "Search the library, price a brief, or add a file.")
        #expect(fixture.editor.capabilities.edit)
    }

    @Test func sourcesHaveHonestBadgesAndPricingDoesNotMakeAudio() async throws {
        let fixture = try fixture(suggest: MusicSuggestionResult(candidates: [Self.library, Self.generated()]), files: ["calm evening.m4a"])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel
        panel.query = "calm piano"
        panel.search(model: fixture.editor)
        await panel.settled()
        #expect(panel.catalogRows(model: fixture.editor) == [Self.library])
        #expect(panel.generationChoice(model: fixture.editor) == nil)
        await quote(fixture)
        panel.loadFolder()
        let candidate = try #require(panel.generationChoice(model: fixture.editor))
        let own = try #require(panel.folderFiles.first)
        #expect([Self.library, candidate, own].map(MusicCandidateRow.badge) == ["CC BY", "Not made", "Yours"])
        #expect(MusicCandidateRow.actionTitle(Self.library) == "Pick" && MusicCandidateRow.actionTitle(candidate) == "Make & use \u{00B7} $0.08")
        #expect(MusicCandidateRow.badgeName(candidate) == "Eleven Music, not generated yet")
        #expect(panel.auditionURL(candidate, model: fixture.editor) == nil)
        #expect(fixture.fetches.ids.isEmpty && fixture.editor.currentMusic == nil)
    }

    @Test func plannerAndOfflineDirectionsAreDistinctEditableAndDoNotRequestAnything() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, panel = editor.musicPanel, requests = FetchLog()
        panel.services?.browse = { _, _, _ in requests.record("search"); throw VoxClipError.offline }
        panel.services?.price = { _, _ in requests.record("price"); return .init() }
        let picked = MusicBrief(mood: "Soft Keys", query: "felt piano", prompt: "Sparse piano without a beat", reason: "Room under the voice")
        let alternate = MusicBrief(mood: "soft keys", query: "analog organ", prompt: "Muted organ chords")
        panel.setDirections([picked, alternate], model: editor)
        #expect(panel.directions.starts(with: [picked, alternate]))
        #expect(Set(panel.directions.indices.map { panel.directionTitle($0).lowercased() }).count == panel.directions.count)
        #expect(Set(panel.directions.map(\.searchText)).count >= 3 && Set(panel.directions.map(\.compositionPrompt)).count >= 3)
        panel.query = "soft upright piano"
        panel.prompt = "Warm upright piano with long gaps"
        panel.selectDirection(1)
        #expect(panel.query == alternate.query && panel.prompt == alternate.prompt)
        panel.selectDirection(0)
        panel.sourceTab = .eleven
        panel.sourceTab = .files
        panel.sourceTab = .free
        panel.syncScope(model: editor)
        #expect(panel.query == "soft upright piano" && panel.prompt == "Warm upright piano with long gaps")
        #expect(requests.ids.isEmpty && fixture.fetches.ids.isEmpty && editor.currentMusic == nil)
        panel.search(model: editor)
        await panel.settled()
        #expect(panel.catalogNote?.hasPrefix("Search failed:") == true)
        #expect(panel.directions[0].query == "soft upright piano" && requests.ids == ["search"] && editor.currentMusic == nil)
    }

    @Test func pagingAppendsAllDistinctChoicesAndAPageFailureKeepsPriorResults() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, panel = editor.musicPanel
        var next = Self.library; next.id = "openverse-next"
        let other = next, calls = Mutex<[Int]>([])
        panel.services?.browse = { _, _, page in
            let attempt = calls.withLock { pages in pages.append(page); return pages.count }
            if page == 1 { return .init(candidates: [Self.library], nextPage: 2) }
            if attempt == 2 { throw VoxClipError.offline }
            return .init(candidates: [Self.library, other])
        }
        panel.search(model: editor); await panel.settled()
        #expect(panel.nextPage(model: editor) == 2 && panel.catalogRows(model: editor) == [Self.library])
        panel.loadMore(model: editor); await panel.settled()
        #expect(panel.catalogRows(model: editor) == [Self.library] && panel.catalogNote?.hasPrefix("Couldn’t load more tracks:") == true)
        panel.loadMore(model: editor); await panel.settled()
        #expect(panel.catalogRows(model: editor) == [Self.library, other] && panel.nextPage(model: editor) == nil && panel.catalogNote == nil)
        #expect(calls.withLock { $0 } == [1, 2, 2] && fixture.fetches.ids.isEmpty)
        panel.query = "new direction"
        #expect(panel.catalogRows(model: editor).isEmpty && panel.auditionURL(other, model: editor) == nil)
        panel.use(other, model: editor)
        #expect(fixture.fetches.ids.isEmpty && editor.currentMusic == nil)
    }

    @Test func delayedSearchCannotPublishResultsForADifferentClip() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, panel = editor.musicPanel, delayed = DelayedCatalog()
        let initial = editor.renderedActiveClipID
        let destination = initial == nil ? editor.project.edits.clips.first : nil
        panel.services?.browse = { _, _, _ in await delayed.search() }
        panel.search(model: editor)
        await delayed.started()
        editor.activate(destination)
        await delayed.finish(.init(candidates: [Self.library], nextPage: 2))
        await panel.settled()
        #expect(editor.renderedActiveClipID != initial)
        #expect(panel.phase == .idle && panel.catalogRows(model: editor).isEmpty && panel.nextPage(model: editor) == nil)
        #expect(fixture.fetches.ids.isEmpty && editor.currentMusic == nil)
    }

    @Test func playStopsTheEditorAndOtherAuditionsAndTogglesOff() async throws {
        let fixture = try fixture(suggest: MusicSuggestionResult(candidates: [Self.library]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel
        panel.search(model: fixture.editor)
        await panel.settled()
        fixture.editor.isPlaying = true
        panel.toggleAudition(Self.library, model: fixture.editor)
        #expect(!fixture.editor.isPlaying && panel.playing == Self.library.id && fixture.audition.played == [Self.library.audioURL!])
        let beforeStop = fixture.audition.stops
        panel.toggleAudition(Self.library, model: fixture.editor)
        #expect(panel.playing == nil && fixture.audition.stops == beforeStop + 1)
        panel.toggleAudition(Self.library, model: fixture.editor)
        fixture.audition.completion?(false)
        #expect(panel.playing == nil && panel.phase == .failed("Can’t preview “Quiet piano”. Try another track."))
        #expect(fixture.fetches.ids.isEmpty && fixture.editor.currentMusic == nil)
    }

    @Test func useStoresTheTrackUnderTheOpenScopeWithItsCreditAndOneVolume() async throws {
        let fixture = try fixture(suggest: MusicSuggestionResult(candidates: [Self.library]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, panel = editor.musicPanel
        let steps = editor.undoSteps
        panel.search(model: editor)
        await panel.settled()
        panel.use(Self.library, model: editor)
        await panel.settled()
        #expect(panel.phase == .idle)
        let entry = try #require(editor.currentMusic)
        #expect(entry.clipId == editor.renderedActiveClipID && entry.license == .by && entry.gainDb == -20 && entry.ducking)
        #expect(editor.project.schemaVersion == 4 && editor.undoSteps == steps + 1)
        #expect(FileManager.default.fileExists(atPath: MusicRenderInput.url(for: entry.asset, dataRoot: fixture.root).path))
        #expect(panel.currentRow(model: editor)?.id == MusicPanel.usingID(entry))
        #expect(MusicSection.footer(phase: .idle, using: entry, hasRows: true).hasSuffix("Next: Export. The credit goes in the post text."))
        var draft = ShareCaptionDraft()
        draft.load(target: editor.renderedActiveClipID ?? "full", model: editor)
        #expect(draft.captionDraft.hasSuffix("\n\nMusic: \"Quiet piano\" by Artist is licensed under CC BY 3.0."))
        panel.setGain(-25.3, model: editor)
        #expect(editor.currentMusic?.gainDb == -25.5 && MusicSection.gainLabel(-25.5) == "\u{2212}25.5 dB")
        let canvas = TimelineCanvasView(model: editor)
        defer { canvas.tearDown() }
        canvas.renderContent()
        #expect(canvas.content.items.first { $0.item.id == .music(entry.id) }?.audio?.gainDb == -25.5)
        #expect(editor.timelineMusic(on: .edited).map { $0.range.lowerBound == 0 && abs($0.range.upperBound - editor.duration) < 1e-9 } == true)
        panel.remove(model: editor)
        #expect(editor.currentMusic == nil && editor.project.music.isEmpty && editor.timelineMusic(on: .edited) == nil)
        #expect(FileManager.default.fileExists(atPath: MusicRenderInput.url(for: entry.asset, dataRoot: fixture.root).path))
        #expect(fixture.fetches.ids == [Self.library.id])
    }

    @Test func makeUsesTheSearchThatOwnsTheQuoteExactlyOnce() async throws {
        let candidate = Self.generated(), fixture = try fixture(suggest: .init(candidates: [candidate]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel, otherClient = FetchLog()
        await quote(fixture)
        panel.services?.fetch = { choice in otherClient.record(choice.id); throw CancellationError() }
        panel.use(candidate, model: fixture.editor)
        panel.use(candidate, model: fixture.editor)
        await panel.settled()
        #expect(fixture.editor.currentMusic?.source == .generated && panel.phase == .idle)
        panel.use(candidate, model: fixture.editor)
        await panel.settled()
        #expect(fixture.fetches.ids == [candidate.id] && otherClient.ids.isEmpty)
        #expect(panel.phase == .failed("Get a new price for this clip and brief."))
    }

    @Test func editingTheBriefInvalidatesAnOtherwiseValidQuote() async throws {
        let candidate = Self.generated(), fixture = try fixture(suggest: .init(candidates: [candidate]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, panel = editor.musicPanel
        await quote(fixture)
        #expect(panel.generationChoice(model: editor) == candidate)
        panel.prompt = "Different selected brief"
        #expect(panel.generationChoice(model: editor) == nil)
        panel.use(candidate, model: editor)
        #expect(fixture.fetches.ids.isEmpty && editor.currentMusic == nil)
    }

    @Test func generatedSegmentsSurviveUndoAndRedoWithoutRemovingTheAsset() async throws {
        let candidate = Self.generated(), fixture = try fixture(suggest: .init(candidates: [candidate]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, panel = editor.musicPanel
        await quote(fixture)
        panel.use(candidate, model: editor)
        await panel.settled()
        let original = try #require(editor.currentMusic)
        let plan = try #require(editor.itemEditPlan)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        undo.beginUndoGrouping()
        let split = editor.commitTimelineItemEdit(.split(items: [.music(original.id)], atSource: plan.sourceTime(plan.duration / 2)))
        undo.endUndoGrouping()
        #expect(split && undo.undoActionName == "Split music")
        let segments = try #require(editor.currentMusic?.segments)
        #expect(segments.count == 2)
        undo.undo()
        #expect(editor.currentMusic == original)
        undo.redo()
        #expect(editor.currentMusic?.segments == segments)
        undo.beginUndoGrouping(); panel.remove(model: editor); undo.endUndoGrouping()
        #expect(editor.currentMusic == nil)
        #expect(FileManager.default.fileExists(atPath: MusicRenderInput.url(for: original.asset, dataRoot: fixture.root).path))
        undo.undo()
        #expect(editor.currentMusic?.segments == segments)
    }

    @Test func replacingAndTurningOffMusicKeepMixAndUndoInSeparateSteps() async throws {
        let fixture = try fixture(suggest: .init(candidates: [Self.library]), files: ["Current.wav"])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, panel = editor.musicPanel
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        panel.loadFolder()
        let file = try #require(panel.folderFiles.first)
        undo.beginUndoGrouping(); panel.use(file, model: editor); await panel.settled(); undo.endUndoGrouping()
        var previous = try #require(editor.currentMusic)
        previous.gainDb = -27; previous.ducking = false; previous.fadeInSeconds = 0.25; previous.fadeOutSeconds = 2
        undo.beginUndoGrouping()
        editor.replace(try MusicProject.setting(previous, clipId: previous.clipId, in: editor.project), name: "Change mix")
        undo.endUndoGrouping()
        panel.search(model: editor); await panel.settled()
        #expect(editor.currentMusic == previous)
        undo.beginUndoGrouping(); panel.use(Self.library, model: editor); await panel.settled(); undo.endUndoGrouping()
        let picked = try #require(editor.currentMusic)
        #expect(picked.gainDb == previous.gainDb && picked.ducking == previous.ducking && picked.fadeInSeconds == previous.fadeInSeconds && picked.fadeOutSeconds == previous.fadeOutSeconds)
        undo.beginUndoGrouping(); panel.remove(model: editor); undo.endUndoGrouping()
        #expect(editor.currentMusic == nil)
        undo.undo(); #expect(editor.currentMusic == picked)
        undo.undo(); #expect(editor.currentMusic == previous)
    }

    @Test func searchPricesTheRenderedLengthAndChangingSpeedStalesTheQuote() async throws {
        let candidate = Self.generated(), fixture = try fixture(suggest: .init(candidates: [candidate]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, panel = editor.musicPanel, quoted = Mutex<Double>(0)
        #expect(editor.setSpeed(1.25))
        panel.services?.price = { _, seconds in quoted.withLock { $0 = seconds }; return .init(candidates: [candidate]) }
        await quote(fixture)
        #expect(abs(quoted.withLock { $0 } - editor.duration / 1.25) < 0.0001)
        #expect(editor.setSpeed(0.75))
        panel.use(candidate, model: editor); await panel.settled()
        #expect(fixture.fetches.ids.isEmpty && panel.phase == .failed("Get a new price for this clip and brief."))
    }

    @Test func alteredChoiceAndChangedClipCannotSpendAnOldEstimate() async throws {
        let candidate = Self.generated(), fixture = try fixture(suggest: .init(candidates: [candidate]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel, editor = fixture.editor
        await quote(fixture)
        var altered = candidate; altered.prompt = "Different request"
        panel.use(altered, model: editor)
        #expect(panel.phase == .failed("Get a new price for this clip and brief."))
        let original = editor.renderedActiveClipID
        editor.activate(original == nil ? editor.project.edits.clips.first : nil)
        #expect(editor.renderedActiveClipID != original)
        panel.use(candidate, model: editor)
        await panel.settled()
        #expect(panel.phase == .failed("Get a new price for this clip and brief."))
        #expect(fixture.fetches.ids.isEmpty && editor.currentMusic == nil)
    }

    @Test func aFailedGenerationIsShownInlineAndNeverRetried() async throws {
        let fixture = try fixture(suggest: MusicSuggestionResult(candidates: [Self.generated()]), fail: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel
        await quote(fixture)
        panel.use(Self.generated(), model: fixture.editor)
        await panel.settled()
        guard case .failed(let message) = panel.phase else { Issue.record("expected a failure, got \(panel.phase)"); return }
        #expect(!message.isEmpty && fixture.editor.project.music.isEmpty)
        #expect(MusicSection.footer(phase: panel.phase, using: nil, hasRows: true) == "Choose another track, or get a new price for the brief.")
        #expect(fixture.fetches.ids == ["eleven-1"])
        panel.dismissFailure()
        #expect(panel.phase == .idle)
    }

    @Test func m1LaneDrawsTheTrackAndTheHeaderOpensTheMusicSection() async throws {
        let fixture = try fixture(suggest: MusicSuggestionResult(candidates: [Self.library]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let shell = WorkspaceShell(app: fixture.app)
        let canvas = TimelineCanvasView(model: fixture.editor, shell: shell)
        defer { canvas.tearDown() }
        canvas.frame = NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height)
        canvas.layoutSubtreeIfNeeded()
        #expect(canvas.music.state.fragments.isEmpty && canvas.itemAXGroups[.music] == nil)
        fixture.editor.musicPanel.search(model: fixture.editor)
        await fixture.editor.musicPanel.settled()
        fixture.editor.musicPanel.use(Self.library, model: fixture.editor)
        await fixture.editor.musicPanel.settled()
        canvas.renderContent()
        #expect(canvas.music.state.fragments.first?.display.title == "Quiet piano")
        #expect(canvas.itemAXGroups[.music]?.accessibilityLabel() == "Music lane")
        let trackID = try #require(fixture.editor.currentMusic?.id)
        #expect(canvas.itemAXElements[.music(trackID)]?.accessibilityLabel()?.hasPrefix("Music, Quiet piano, ") == true)
        shell.choosePanelJob(.export, for: fixture.editor)
        canvas.header(.music).action?()
        #expect(shell.panelJob(for: fixture.editor) == .music)
    }
}
#endif
