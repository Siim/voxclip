#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import VoxClipMedia

actor ConsentFixtureConnector: LLMConnector {
    nonisolated let id: ConnectorID
    let readiness: ConnectorStatus
    let authMethod: String?
    private(set) var statuses = 0
    private(set) var sends = 0
    init(id: ConnectorID, readiness: ConnectorStatus = .ready, authMethod: String? = "api_key") {
        self.id = id; self.readiness = readiness; self.authMethod = authMethod
    }
    func status() -> ConnectorStatus { statuses += 1; return readiness }
    func knownCLIAuthMethod() async -> String? { authMethod }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        sends += 1
        let text = request.feature == .test ? "{\"ok\":true,\"echo\":\"voxclip\"}" : request.feature == .voiceRewrite ? "{\"rewrite\":\"A clearer passage\"}" : "{\"clips\":[]}"
        return RawCompletion(text: text, model: model, stop: .complete)
    }
}

@MainActor private final class ConsentObservation {
    var copies: [String] = []
    var detectedBeforeSheet = true
    var zeroRequestsBeforeSheet = true
}

@MainActor enum DebugConnectorRequests {
    static func run(fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        for id in ["anthropic", "claude-code", "codex"] {
            let methods: [String?] = id == "anthropic" ? ["api_key"] : ["api_key", id == "codex" ? "chatgpt" : "claude.ai", nil, "unrecognized"]
            for method in methods {
            for action in [ConnectorConsentAction.findClips, .rewrite, .test] {
                for choice in ["cancel", "continue", "granted"] {
                    let app = AppModel(settingsStore: RegressionSettingsStore())
                    await app.start()
                    guard let provider = app.providers.first(where: { $0.id == id }) else { throw CocoaError(.coderInvalidValue) }
                    let fake = ConsentFixtureConnector(id: ConnectorID(rawValue: id)!, authMethod: method)
                    app.connectorOverride = { _ in fake }
                    app.set("llm.connector", .string(id))
                    app.set("llm.model.\(id)", .string("fixture-local"))
                    app.set("voiceLab.enabled", .bool(true))
                    app.set("llm.cloudConsent.\(id)", .bool(choice == "granted"))
                    let observation = ConsentObservation()
                    app.connectorConsentOverride = { _, _, copy in
                        observation.copies.append(copy)
                        let sends = await fake.sends, statuses = await fake.statuses
                        observation.zeroRequestsBeforeSheet = sends == 0
                        observation.detectedBeforeSheet = statuses > 0
                        return choice == "continue"
                    }
                    let editor = makeEditor(fixture: fixture, app: app)
                    defer { editor.close(); app.connectorConsentOverride = nil; app.connectorOverride = nil }
                    switch action {
                    case .findClips:
                        editor.findClips()
                        await wait { !editor.finding }
                    case .rewrite:
                        editor.beginRewrite()
                        await wait { editor.rewrite != nil }
                        if let session = editor.rewrite {
                            await session.detectConnector(); await session.prepare()
                            if let quote = session.quote { session.markEstimateShown(quote.id); _ = await session.propose(quote, affirmative: true) }
                        }
                    case .test:
                        _ = await testProvider(provider, app: app)
                    }
                    let sends = await fake.sends
                    let known = method != nil && method != "unrecognized"
                    let expected = choice == "cancel" || !known ? 0 : 1
                    let prefix = "\(id) \(action) \(method ?? "unknown") \(choice)"
                    check("\(prefix) detects before sheet and sends only after consent", observation.detectedBeforeSheet && observation.zeroRequestsBeforeSheet && sends == expected && observation.copies.count == (choice == "granted" || !known ? 0 : 1))
                    check("\(prefix) leaves no run or lease held", !editor.finding && !editor.llmRuns.isBusy && app.testingProviders.isEmpty)
                    if !known {
                        check("\(prefix) unknown method never defaults to plan wording", provider.consentCopy(action: action, wordCount: 3, authMethod: method).isEmpty && observation.copies.isEmpty && app.detectedConnectorStatus[id] == .cliSignedOut)
                    } else if choice != "granted" {
                        let copy = observation.copies.first ?? ""
                        let billing = provider.group != "cli" || (method == "api_key" ? copy.contains("billed to the API key") && !copy.contains("plan's usage") : copy.contains("plan's usage") && !copy.contains("billed to the API key"))
                        check("\(prefix) fresh process uses detected billing sentence on first use", billing && !copy.isEmpty)
                        if action == .test {
                            let vendor = id == "claude-code" ? "Anthropic" : "OpenAI"
                            let name = id == "claude-code" ? "Claude Code" : "Codex"
                            let plan = id == "claude-code" ? "Claude" : "ChatGPT"
                            let ending = method == "api_key" ? "billed to the API key \(name) is signed in with." : "counts toward your \(plan) plan's usage."
                            let expectedCopy = provider.group == "cli" ? "VoxClip will run your installed \(name) with your own sign-in. A short test request is sent to \(vendor) and \(ending)" : "Test sends a short test request to \(provider.label) using your API key. Nothing from your projects is sent."
                            check("\(prefix) uses exact Test consent copy", copy == expectedCopy)
                        }
                        if choice == "continue" {
                            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                                try DebugRound4.bitmap(Text(copy).font(.system(size: 13)).padding(16), name: "r6-consent-copy-only-\(id)-\(action)-\(method ?? "unknown")-\(appearance)", width: 440, height: 150, scheme: scheme, directory: directory)
                            }
                        }
                    }
                }
            }
            }
        }
        return results
    }
    static func makeEditor(fixture: Project, app: AppModel) -> EditorModel {
        var project = fixture
        project.id = UUID().uuidString.lowercased()
        project.edits = ProjectEdits()
        project.transcript?.words = (0..<80).map { index in
            let position: Double = Double(index)
            let start: Double = position + 1
            let end: Double = start + 0.4
            return TimedWord(id: "consent-\(index)", text: "word\(index)", start: start, end: end)
        }
        let editor = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        editor.mediaResolved = true; editor.refresh()
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))
        editor.selectedWordIDs = Set(editor.words[3...5].map(\.id))
        return editor
    }
    static func wait(_ done: () -> Bool) async {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !done() && clock.now < deadline { await Task.yield() }
    }
}
#endif
