#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// A Claude Code fake on a plan (no send confirmation) that answers the caption pick with `reply`.
private actor PickFixtureConnector: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    private(set) var requests: [LLMRequest] = []
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func knownCLIAuthMethod() async -> String? { "claude.ai" }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        requests.append(request)
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}

/// The clip style card and Claude's caption pick (design.md §6.6): shown once above the clip list, collapsed to the
/// status bar's "Style: …" item that reopens it, the Auto pick from a stub reply, and a fixed style no pick replaces.
/// Stub connectors only, settings in memory, nothing shown on screen.
@Suite("Clip style", .serialized, .offlineFixtures)
@MainActor struct ClipStyleTests {
    private func open(app: AppModel = AppModel(settingsStore: RegressionSettingsStore())) async throws -> (WorkspaceShell, EditorModel) {
        _ = NSApplication.shared
        app.loadCatalogue()
        // "I'll pick" (design §6.6): the clip style card shows once, as before Claude mode; card A has been answered.
        #expect(app.set(ClipsMode.key, .string(ClipsMode.pick.rawValue)))
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        project.captions.styleId = "box-highlight"
        project.clipStyle = nil
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        #expect(!editor.project.edits.clips.isEmpty)
        return (shell, editor)
    }

    @Test func theCardShowsOnceCollapsesToTheStatusBarAndReopensInline() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        #expect(editor.showsClipStyleCard && editor.project.clipStyle == nil)
        #expect(editor.cardClipStyle?.preset == .auto && editor.statusClipStyle == nil)
        #expect(StatusBarContent.make(app: editor.app, editor: editor, now: Date())[.clipStyle] == nil)

        editor.chooseClipPreset(.auto)
        #expect(!editor.showsClipStyleCard)
        let style = try #require(editor.project.clipStyle)
        #expect(style.preset == .auto && style.captions == .auto && style.maxLengthSec == 60 && style.shapes == [.landscape, .portrait])
        #expect(editor.statusClipStyle?.text == "Style: Auto · ≤60 s · 16:9+9:16")
        #expect(StatusBarContent.make(app: editor.app, editor: editor, now: Date())[.clipStyle]?.text == "Style: Auto · ≤60 s · 16:9+9:16")
        #expect(editor.savedClipStyle == style.settingsDefault)
        #expect(editor.project.captions.styleId == "box-highlight", "Auto leaves the caption style to Claude")

        // The status bar item reopens the card in place; Done collapses it again without another choice.
        let bar = StatusBarView(shell: shell)
        defer { bar.tearDown() }
        bar.render()
        let item = try #require(bar.itemView(.clipStyle))
        #expect(item.onPress != nil)
        item.onPress?()
        #expect(editor.showsClipStyleCard)
        editor.collapseClipStyleCard()
        #expect(!editor.showsClipStyleCard && editor.project.clipStyle == style)

        // A preset with a fixed caption style applies it; a row change makes it "My style".
        editor.reopenClipStyleCard()
        editor.chooseClipPreset(.punchy)
        #expect(editor.project.clipStyle?.preset == .punchy && editor.project.captions.styleId == "punch-in" && !editor.showsClipStyleCard)
        editor.updateClipStyle { $0.maxLengthSec = 30 }
        #expect(editor.project.clipStyle?.preset == .mine && editor.project.clipStyle?.maxLengthSec == 30)
        #expect(editor.statusClipStyle?.text == "Style: My style · ≤30 s · 9:16")
    }

    @Test func aNewProjectStartsFromTheSavedDefault() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let (_, first) = try await open(app: app)
        first.chooseClipPreset(.calm)
        first.close()
        let (_, second) = try await open(app: app)
        defer { second.close() }
        #expect(second.showsClipStyleCard && second.cardClipStyle?.preset == .calm && second.project.clipStyle == nil)
        #expect(second.cardClipStyle?.captions == .style("minimal"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."))
    func autoPicksAStylePerClipFromAStubReply() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let reply = #"{"picks":[{"clip":"C1","style":"punch-in","reason":"Punchy hook."},{"clip":"C2","style":"minimal","reason":"Quiet story."}]}"#
        let fake = PickFixtureConnector(reply: reply)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("claude-code"))
        app.connectorConsentOverride = { _, action, _ in #expect(action == .pickCaptions); return true }
        let (shell, editor) = try await open(app: app)
        defer { editor.close() }
        editor.chooseClipPreset(.auto)
        let clips = editor.keptClips + editor.suggestedClips
        try #require(clips.count >= 2)
        #expect(editor.canPickCaptionStyles && editor.unpickedClipCount == editor.project.edits.clips.count)
        editor.pickCaptionStyles()
        await editor.clipStyleState.task?.value
        let requests = await fake.requests
        #expect(requests.count == 1 && requests.first?.feature == .captionPick && requests.first?.effort == .xhigh)
        let picks = try #require(editor.project.clipStyle?.captionPicks)
        #expect(picks[clips[0].id] == ClipCaptionPick(styleId: "punch-in", reason: "Punchy hook."))
        #expect(picks[clips[1].id] == ClipCaptionPick(styleId: "minimal", reason: "Quiet story."))
        #expect(editor.clipStyleState.error == nil && !editor.clipStyleState.picking && !editor.llmRuns.isBusy)

        // The active clip uses its pick, shown with the reason in the Captions panel.
        shell.selection = .clip(clips[1].id)
        editor.applyCaptionPick()
        #expect(editor.activeCaptionPick?.styleId == "minimal" && editor.project.captions.styleId == "minimal")
    }

    @Test func aStyleTheUserChoseIsNeverOverridden() async throws {
        let (shell, editor) = try await open()
        defer { editor.close() }
        editor.chooseClipPreset(.auto)
        let clip = try #require((editor.keptClips + editor.suggestedClips).first)
        shell.selection = .clip(clip.id)
        #expect(editor.activeClip?.id == clip.id)
        // A gallery tile is a choice: it fixes the clip style's captions.
        editor.setStyle("marker")
        #expect(editor.project.clipStyle?.captions == .style("marker") && editor.project.clipStyle?.preset == .mine)
        #expect(!editor.canPickCaptionStyles)
        // Even a pick recorded for the clip changes nothing while a style is fixed.
        var next = editor.project
        next.clipStyle = next.clipStyle?.recording([clip.id: ClipCaptionPick(styleId: "glow", reason: "Later.")])
        #expect(next.clipStyle?.captionPicks[clip.id] == nil)
        next.clipStyle?.captionPicks[clip.id] = ClipCaptionPick(styleId: "glow", reason: "Injected.")
        editor.replace(next, name: "Inject")
        editor.applyCaptionPick()
        #expect(editor.activeCaptionPick == nil && editor.project.captions.styleId == "marker")
        // Back to Auto in the card, the pick applies again.
        editor.setClipCaptions(.auto)
        editor.applyCaptionPick()
        #expect(editor.project.captions.styleId == "glow")
    }

    /// Offscreen pictures of the card, the pick row and the status bar for review (the gallery, whose tiles render
    /// in a window, comes from `-layoutAudit <dir> -spacingCaptures`), only when VOXCLIP_CLIP_STYLE_CAPTURES names a folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_CLIP_STYLE_CAPTURES"] != nil))
    func capturesTheCardThePickRowAndTheStatusBar() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOXCLIP_CLIP_STYLE_CAPTURES"]), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (shell, editor) = try await open()
        defer { editor.close() }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            let card = ClipStyleCard(editor: editor).frame(width: 224 - 24).padding(12).background(DesignValues.color("bg.window"))
            try await Self.capture(card, size: CGSize(width: 224, height: 360), appearance: appearance, to: folder.appendingPathComponent("card-\(name).png"))
        }
        editor.chooseClipPreset(.auto)
        var next = editor.project
        if let clip = editor.activeClip ?? editor.keptClips.first ?? editor.suggestedClips.first {
            next.clipStyle = next.clipStyle?.recording([clip.id: ClipCaptionPick(styleId: "punch-in", reason: "Fast, direct advice; bold caps punch each word.")])
            next.edits.activeClipId = clip.id
        }
        editor.replace(next, name: "Capture")
        editor.applyCaptionPick()
        let row = VStack(alignment: .leading) { ClipStyleCaptionRow(model: editor) }.frame(width: 372).padding(16).background(DesignValues.color("bg.window"))
        try await Self.capture(row, size: CGSize(width: 404, height: 120), appearance: .darkAqua, to: folder.appendingPathComponent("captions-pick-row.png"))
        let bar = StatusBarView(shell: shell)
        defer { bar.tearDown() }
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.frame = NSRect(x: 0, y: 0, width: 1280, height: ShellMetrics.statusBar)
        bar.render(); bar.layoutSubtreeIfNeeded()
        try Self.write(bar, to: folder.appendingPathComponent("status-bar.png"))
    }

    /// Lays `view` out offscreen, settling until `ready` (every gallery tile drawn) or `settle` layout passes.
    private static func capture(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL, settle: Int = 40,
                                ready: (NSView) -> Bool = { _ in false }) async throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<settle {
            host.layoutSubtreeIfNeeded()
            if ready(host) { break }
            await Task.yield()
        }
        host.layoutSubtreeIfNeeded()
        try write(host, to: url)
    }

    private static func write(_ view: NSView, to url: URL) throws {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
#endif
