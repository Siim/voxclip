#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

private actor SignInConnector: LLMConnector {
    func contextTokens(model: String) -> Int? { nil }
    nonisolated let id = ConnectorID.codex
    private var readiness: ConnectorStatus = .cliSignedOut
    private(set) var sends = 0
    private(set) var checks = 0
    func set(_ status: ConnectorStatus) { readiness = status }
    func status() -> ConnectorStatus { checks += 1; return readiness }
    func knownCLIAuthMethod() -> String? { readiness == .ready ? "chatgpt" : nil }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func send(_ request: LLMRequest, model: String) throws -> RawCompletion { sends += 1; throw CancellationError() }
}

@Suite("V11b services", .serialized, .offlineFixtures)
@MainActor struct V11bServicesTests {
    init() { _ = NSApplication.shared }
    @Test func spendUsesOnlyTheLocalMonthAndRetainsUnknownPrices() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = VoiceLabSpendLedger(url: folder.appendingPathComponent("spend.json"), timeZone: try #require(TimeZone(secondsFromGMT: 7200)))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-31T23:30:00Z"))
        var data = VoiceLabSpendDocument(months: ["2026-10": ["elevenlabs": .init(usd: 99)], "2026-11": ["elevenlabs": .init(usd: Decimal(string: "0.40")!, unknownCount: 2)]])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.encoded().write(to: ledger.url)
        let spend = MonthlySpend(); await spend.refresh(ledger: ledger, now: now)
        #expect(spend.month == "2026-11" && spend.text == "ElevenLabs · $0.40 + 2 unpriced this month")
        data.months["2026-12"] = ["elevenlabs": .init()]; try data.encoded().write(to: ledger.url)
        await spend.refresh(ledger: ledger, now: try #require(ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")))
        #expect(spend.text == "ElevenLabs · $0.00 this month")
    }
    @Test func spendIsVoiceLabOnlyInTheStatusBarAndHarnessPicker() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let ledger = VoiceLabSpendLedger(locations: app.locations)
        let now = Date()
        await app.monthlySpend.refresh(ledger: ledger, now: now)
        app.settings.values["voiceLab.enabled"] = .bool(false)
        #expect(StatusBarContent.make(app: app, editor: nil, now: now)[.spend] == nil)
        #expect(!HarnessPicker(app: app).makeMenu().items.contains { $0.title.contains("this month") })
        app.settings.values["voiceLab.enabled"] = .bool(true)
        let line = app.monthlySpendLine
        #expect(StatusBarContent.make(app: app, editor: nil, now: now)[.spend]?.text == line)
        #expect(HarnessPicker(app: app).makeMenu().items.contains { $0.title == line })
    }
    @Test func signInRunsTheCatalogueCommandAndKeepsInstructionsAndResultsInline() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore()); app.loadCatalogue()
        let provider = try #require(app.providers.first { $0.id == "codex" })
        app.set("llm.connector", .string(provider.id))
        let connector = SignInConnector()
        _ = await app.connectorStatus(provider, using: connector)
        let picker = HarnessPicker(app: app), menu = picker.makeMenu()
        #expect(menu.items.contains { $0.title == "Sign In…" && $0.action != nil })
        #expect(menu.items.compactMap { ($0.view as? NSTextField)?.stringValue }.contains { $0.contains(provider.cli?.signInHint ?? "missing") })
        var launched: URL?
        await app.harnessSignIn.signIn(provider) { launched = $0 }
        let file = try #require(launched)
        defer { try? FileManager.default.removeItem(at: file) }
        let script = try String(contentsOf: file, encoding: .utf8)
        #expect(script.contains("'codex' login") && !script.contains(" exec "))
        #expect(app.harnessSignIn.message(for: provider) == "Finish signing in in Terminal, then return here.")
        await connector.set(.ready); await app.harnessSignIn.check(provider, using: connector)
        picker.refresh(menu)
        #expect(app.harnessSignIn.message(for: provider) == "Codex is signed in.")
        #expect(menu.items.compactMap { ($0.view as? NSTextField)?.stringValue }.contains { $0.contains("Codex is signed in.") })
        #expect(await connector.sends == 0)
        // User-selected paths remain one executable argument, including shell metacharacters.
        let path = "/fixture/a'b $(do-not-run)/codex"
        #expect(HarnessSignIn.command(provider: provider, path: path) == "'/fixture/a'\\''b $(do-not-run)/codex' login")
    }
    @Test func activationChecksSignInOnceAndAnnouncesOnlyChanges() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore()); app.loadCatalogue()
        let provider = try #require(app.providers.first { $0.id == "codex" })
        app.set("llm.connector", .string(provider.id))
        let connector = SignInConnector()
        var spoken: [String] = [], file: URL?
        app.harnessSignIn.announce = { spoken.append($0) }
        await app.harnessSignIn.signIn(provider) { file = $0 }
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        #expect(app.harnessSignIn.pendingCheck)
        await connector.set(.ready)
        await app.harnessSignIn.checkPending(using: connector)
        #expect(await connector.checks == 1)
        #expect(spoken == ["Codex is signed in."] && !app.harnessSignIn.pendingCheck)
        let menu = HarnessPicker(app: app).makeMenu()
        #expect(!menu.items.contains { $0.title == "Sign In…" || $0.title == "Sign in to Codex" })
        #expect(app.harnessSignIn.message(for: provider) == "Codex is signed in.")
        await app.harnessSignIn.checkPending(using: connector)
        #expect(await connector.checks == 1)
        #expect(spoken.count == 1 && app.harnessSignIn.providerID == nil && app.harnessSignIn.result == nil)
        await app.harnessSignIn.check(provider, using: connector)
        await app.harnessSignIn.check(provider, using: connector)
        #expect(spoken.count == 2, "the repeated ready status has no second announcement")
        #expect(await connector.sends == 0)
    }
    @Test func homeSignInRowAppearsOnlyForSignedOutOrAnInlineResult() {
        #expect(HomeView.showsHarnessSignIn(readiness: .cliSignedOut, result: nil))
        #expect(HomeView.showsHarnessSignIn(readiness: .ready, result: "Signed in"))
        #expect(!HomeView.showsHarnessSignIn(readiness: .ready, result: nil))
        #expect(!HomeView.showsHarnessSignIn(readiness: nil, result: nil))
    }
    @Test func failedSignInStaysInlineAndCheckingDoesNotSend() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore()); app.loadCatalogue()
        let provider = try #require(app.providers.first { $0.id == "claude-code" })
        app.set("llm.connector", .string(provider.id))
        #expect(HarnessSignIn.command(provider: provider, path: "") == "'claude'")
        var file: URL?
        await app.harnessSignIn.signIn(provider) { file = $0; throw CocoaError(.fileNoSuchFile) }
        #expect(app.harnessSignIn.message(for: provider)?.hasPrefix("Couldn't open Terminal.") == true)
        #expect(file.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        let connector = SignInConnector(); await app.harnessSignIn.check(provider, using: connector)
        #expect(app.harnessSignIn.message(for: provider)?.hasPrefix("Still not signed in.") == true)
        let menu = HarnessPicker(app: app).makeMenu()
        #expect(menu.items.compactMap { ($0.view as? NSTextField)?.stringValue }.contains { $0.contains("Still not signed in.") })
        #expect(await connector.sends == 0)
    }
    @Test func aDetectionThatFinishesWithSignedOutAddsTheInlineRowToTheOpenMenu() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore()); app.loadCatalogue()
        let provider = try #require(app.providers.first { $0.id == "codex" })
        app.set("llm.connector", .string(provider.id))
        let picker = HarnessPicker(app: app), menu = picker.makeMenu()
        #expect(!menu.items.contains { $0.title == "Sign In…" })
        _ = await app.connectorStatus(provider, using: SignInConnector())
        picker.refresh(menu)
        #expect(menu.items.filter { $0.title == "Sign In…" }.count == 1)
        picker.refresh(menu)
        #expect(menu.items.filter { $0.title == "Sign In…" }.count == 1)
    }
    @Test func timelineExportsUsesTheSameRowsAndActionsAsExplorer() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore()), shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        let shared = try SharedResources.locate()
        let fixture = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let editor = EditorModel(document: VoxClipDocument(project: try DebugExplorer.fiveQuestions(from: fixture), demo: true), app: app)
        defer { editor.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        app.exportLedger = ExportLedger(file: folder.appendingPathComponent("exports.json"))
        try app.exportLedger.record(ExportRecord(projectID: editor.project.id, targetID: "five-1", exportedAt: Date(), planFingerprint: "", styleId: "off", aspect: .portrait, outputPath: "", failed: true))
        let host = NSHostingView(rootView: TimelineExportsList(model: editor))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 200); host.layoutSubtreeIfNeeded()
        let texts = DebugRightColumn.texts(in: host)
        #expect(texts["timeline.exports"] == "Exports, 1 item")
        #expect(texts["explorer.export"] == editor.exportsList.rows.first?.accessibilityLabel)
        #expect(texts["explorer.exportWarning"] == "Export failed")
        let toolbar = NSHostingView(rootView: TimelineToolbar(model: editor, shell: shell, exportsSelected: .constant(true)))
        toolbar.frame = NSRect(x: 0, y: 0, width: 800, height: 28); toolbar.layoutSubtreeIfNeeded()
    }
}
#endif
