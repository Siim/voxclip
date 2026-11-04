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
    func play(_ url: URL) { played.append(url) }
    func stop() { stops += 1 }
}

private final class FetchLog: Sendable {
    private let value = Mutex<[String]>([])
    var ids: [String] { value.withLock { $0 } }
    func record(_ id: String) { value.withLock { $0.append(id) } }
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

    private static let library = MusicCandidate(id: "openverse-piano", source: .library, title: "Quiet piano", creator: "Artist", license: .by,
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
            folder: { folder })
        return Fixture(root: root, folder: folder, app: app, editor: editor, audition: audition, fetches: fetches)
    }

    @Test func withoutSuggestionsItListsTheMusicFolderAndNamesTheNextStep() throws {
        let fixture = try fixture(files: ["calm evening.m4a", "drums.mp3", "notes.txt"])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel
        panel.loadFolder()
        #expect(panel.rows(model: fixture.editor).map(\.title) == ["calm evening", "drums"])
        #expect(MusicSection.footer(phase: .idle, using: nil, hasRows: true) == "Next: \u{25B6} to listen, then Use.")
        #expect(MusicSection.footer(phase: .idle, using: nil, hasRows: false) == "Next: search, or add a file.")
        #expect(fixture.editor.capabilities.edit)
    }

    @Test func suggestionsShowTheBestThreeWithBadgesAndAPricedMake() async throws {
        let own = MusicCandidate(id: "file-x", source: .file, title: "calm evening", license: .own, fileExtension: "m4a")
        let fixture = try fixture(suggest: MusicSuggestionResult(candidates: [Self.library, Self.generated(), own],
                                                                 notes: [.library: "A note"]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel
        panel.query = "calm piano"
        panel.search(model: fixture.editor)
        await panel.settled()
        let rows = panel.rows(model: fixture.editor)
        #expect(rows.map(\.source) == [.library, .generated, .file])
        #expect(rows.map(MusicCandidateRow.badge) == ["CC BY", "Eleven", "Yours"])
        #expect(MusicCandidateRow.actionTitle(rows[0]) == "Use" && MusicCandidateRow.actionTitle(rows[1]) == "Make \u{00B7} $0.08")
        #expect(panel.auditionURL(rows[1], model: fixture.editor) == nil, "nothing to play before it is made")
        #expect(panel.notes == ["A note"] && panel.brief?.query == "calm piano")
    }

    @Test func playStopsTheEditorAndOtherAuditionsAndTogglesOff() async throws {
        let fixture = try fixture(suggest: MusicSuggestionResult(candidates: [Self.library]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel
        panel.suggest(MusicBrief(mood: "calm"), model: fixture.editor)
        await panel.settled()
        fixture.editor.isPlaying = true
        panel.toggleAudition(Self.library, model: fixture.editor)
        #expect(!fixture.editor.isPlaying && panel.playing == Self.library.id && fixture.audition.played == [Self.library.audioURL!])
        panel.toggleAudition(Self.library, model: fixture.editor)
        #expect(panel.playing == nil && fixture.audition.stops == 1)
    }

    @Test func useStoresTheTrackUnderTheOpenScopeWithItsCreditAndOneVolume() async throws {
        let fixture = try fixture(suggest: MusicSuggestionResult(candidates: [Self.library]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, panel = editor.musicPanel
        let steps = editor.undoSteps
        panel.suggest(MusicBrief(mood: "calm"), model: editor)
        await panel.settled()
        panel.use(Self.library, model: editor)
        await panel.settled()
        #expect(panel.phase == .idle)
        let entry = try #require(editor.currentMusic)
        #expect(entry.clipId == editor.renderedActiveClipID && entry.license == .by && entry.gainDb == -20 && entry.ducking)
        #expect(editor.project.schemaVersion == 4 && editor.undoSteps == steps + 1)
        #expect(FileManager.default.fileExists(atPath: MusicRenderInput.url(for: entry.asset, dataRoot: fixture.root).path))
        let rows = panel.rows(model: editor)
        #expect(rows.count == 1 && rows[0].id == MusicPanel.usingID(entry), "the used suggestion shows once, as Using")
        #expect(MusicSection.footer(phase: .idle, using: entry, hasRows: true).hasSuffix("Next: Export. The credit goes in the post text."))
        var draft = ShareCaptionDraft()
        draft.load(target: editor.renderedActiveClipID ?? "full", model: editor)
        #expect(draft.captionDraft.hasSuffix("\n\nMusic: \"Quiet piano\" by Artist is licensed under CC BY 3.0."))
        panel.setGain(-25.3, model: editor)
        #expect(editor.currentMusic?.gainDb == -25.5 && MusicSection.gainLabel(-25.5) == "\u{2212}25.5 dB")
        #expect(editor.timelineMusic(on: .edited).map { $0.range.lowerBound == 0 && abs($0.range.upperBound - editor.duration) < 1e-9 } == true)
        panel.remove(model: editor)
        #expect(editor.currentMusic == nil && editor.project.music.isEmpty && editor.timelineMusic(on: .edited) == nil)
        #expect(fixture.fetches.ids == [Self.library.id])
    }

    @Test func aFailedGenerationIsShownInlineAndNeverRetried() async throws {
        let fixture = try fixture(suggest: MusicSuggestionResult(candidates: [Self.generated()]), fail: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let panel = fixture.editor.musicPanel
        panel.suggest(MusicBrief(mood: "calm"), model: fixture.editor)
        await panel.settled()
        panel.use(Self.generated(), model: fixture.editor)
        await panel.settled()
        guard case .failed(let message) = panel.phase else { Issue.record("expected a failure, got \(panel.phase)"); return }
        #expect(!message.isEmpty && fixture.editor.project.music.isEmpty)
        #expect(MusicSection.footer(phase: panel.phase, using: nil, hasRows: true) == "Nothing was changed. Try another track, or try this one again.")
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
        canvas.frame = NSRect(x: 0, y: 0, width: 1056, height: 260)
        canvas.layoutSubtreeIfNeeded()
        #expect(canvas.music.state.music == nil && canvas.music.accessibilityLabel() == "Music: none")
        fixture.editor.musicPanel.use(Self.library, model: fixture.editor)
        await fixture.editor.musicPanel.settled()
        canvas.renderContent()
        #expect(canvas.music.state.music?.title == "Quiet piano")
        #expect(canvas.music.accessibilityLabel() == "Music: Quiet piano, \u{2212}20 dB")
        shell.choosePanelJob(.export, for: fixture.editor)
        canvas.headers[4].action?()
        #expect(shell.panelJob(for: fixture.editor) == .captions)
    }
}
#endif
