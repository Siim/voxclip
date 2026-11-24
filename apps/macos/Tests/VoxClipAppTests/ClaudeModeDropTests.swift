#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClip
import VoxClipCore
import VoxClipMedia

@Suite(.offlineFixtures)
@MainActor struct ClaudeModeDropTests {
    private struct ChoiceRow: Decodable {
        let mode: String
        let apple: ClaudeTranscriptionChoice.Apple
        let confirmation: TranscriptEngine
        let firstPass: Bool
        let label: String
    }

    @Test func clipStyleUsesTheSharedTranscriptionChoices() throws {
        let shared = try SharedResources.locate()
        let file = shared.root.appendingPathComponent("fixtures/transcription/claude-mode-choice.json")
        let rows = try JSONDecoder().decode([ChoiceRow].self, from: Data(contentsOf: file))
        for row in rows {
            let choice = ClaudeTranscriptionChoice(mode: row.mode, apple: row.apple)
            #expect(choice.confirmation == row.confirmation && choice.firstPass == row.firstPass && choice.label == row.label)
        }
    }

    @Test(.timeLimit(.minutes(2))) func fixtureDropStreamsConfirmedClipsUnderTwoMinutes() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-c14-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: locations)
        app.providerKeyStoreOverride = DropKeys()
        app.voiceRecoveryForTests = { }
        let shared = try SharedResources.locate()
        let media = shared.root.appendingPathComponent("fixtures/media/fillers-chirp.mp4")
        let fixture = shared.root.appendingPathComponent("fixtures/media/fillers-chirp.transcript.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var transcript = try decoder.decode(Transcript.self, from: Data(contentsOf: fixture))
        for index in transcript.words.indices {
            transcript.words[index].text = index % 20 == 19 ? "today." : "word"
        }
        transcript.words[0].text = "Siim"
        let answer = try DebugRewriteSmoke.claudeModeFindReply(words: transcript.words)
        let connector = DropConnector(reply: answer.replacingOccurrences(of: "Moment", with: "Seem moment"))
        app.connectorOverride = { _ in connector }
        app.connectorConsentOverride = { _, _, _ in true }
        #expect(app.set(ClipsMode.key, .string("claude")))
        #expect(app.set(ClipsMode.capKey, .number(0)))
        #expect(app.set("transcription.language", .string("fr")))
        #expect(app.set("llm.connector", .string("claude-code")))
        #expect(app.set("llm.cloudConsent.claude-code", .bool(true)))
        #expect(app.set("update.autoCheck", .bool(false)))
        await app.start()
        let provider = try #require(app.providers.first { $0.id == "claude-code" })
        _ = await app.connectorStatus(provider, using: connector)

        let drop = ClaudeModeClock()
        let document = try await importedDocument(media, app: app, clock: drop)
        let editor = EditorModel(document: document, app: app, preview: DemoPreviewEngine())
        defer { editor.close(); document.close() }
        editor.preset = .quotes
        editor.transcription.readinessOverride = { _ in .ready }
        var engines: [TranscriptEngine] = []
        editor.transcription.runOverrideUsesAudio = true
        editor.transcription.runOverride = { plan in
            engines.append(plan.engine)
            var result = transcript
            result.engine.id = plan.engine
            if plan.engine == .appleSpeech {
                try await Task.sleep(for: .milliseconds(50))
                result.words[0].text = "Seem"
            } else {
                try await Task.sleep(for: .milliseconds(500))
                #expect(editor.project.transcript == nil && editor.project.ai.results.isEmpty)
                for index in result.words.indices { result.words[index].id = "confirm-\(index + 1)" }
            }
            return result
        }
        var plannedCount = 0
        var gate: TestContinuation<Void>?
        editor.musicPanel.services = MusicPanelServices(suggest: { _, _ in MusicSuggestionResult(candidates: []) }, fetch: { _ in Data() }, folder: { nil })
        editor.makeIt.services = MakeItServices(plan: { request, _, _, progress in
            guard case .clips(let spans) = request.mode else { return ClipAutopilotSeries(plans: []) }
            plannedCount = spans.count
            #expect(request.transcript.words[0].text == "Siim")
            #expect(!request.moments.contains { $0.title.contains("Seem") })
            let plans = spans.map { span in
                ClipAutopilotPlan(startWord: span.lowerBound, endWord: span.upperBound, title: "Confirmed clip", hook: "",
                                  captions: MakeItPostableTestsPlan.captions, postText: "Post.", score: 8, verdict: .post)
            }
            for index in plans.indices { progress(.planning(clip: index, of: plans.count)) }
            try await Task.sleep(for: .milliseconds(120))
            if let first = plans.first { progress(.ready(clip: 0, of: plans.count, first)) }
            await withTestDeadline { gate = $0 }
            for index in plans.indices.dropFirst() { progress(.ready(clip: index, of: plans.count, plans[index])) }
            return ClipAutopilotSeries(plans: plans)
        }, voice: { _, _ in MakeItRewriteOutcome(result: .voiced(segments: []), spent: 0) }, voiceAvailable: { _ in false })

        await editor.start()
        await editor.workTask?.value
        await editor.findTask?.value
        await editor.claudeMode.afterFind?.value
        for _ in 0..<100 where editor.claudeModeReady.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.claudeModeReady.count == 1 && plannedCount > 1)
        editor.reviewClaudeMode()
        let reviewing = try #require(editor.claudeModeReady.first?.clipID)
        gate?.resume(); gate = nil
        await editor.claudeMode.task?.value
        let clock = try #require(editor.claudeMode.clock)
        let first = try #require(clock.firstReady)
        print("c14 fixture drop: \(clock.json())")
        #expect(clock === drop && first < 120)
        #expect([ClaudeModeStage.ingest, .probe, .audio, .draft].allSatisfy { stage in clock.timings.contains { $0.stage == stage } })
        let confirm = try #require(clock.timings.first { $0.stage == .confirm })
        let find = try #require(clock.timings.first { $0.stage == .find })
        #expect(find.start < confirm.end)
        #expect(engines == [.appleSpeech, .whispercpp])
        #expect(!editor.project.ai.results.flatMap(\.clips).contains { $0.title.contains("Seem") })
        #expect(editor.project.ai.results.flatMap(\.clips).contains { $0.startWordId == "confirm-1" && $0.title.hasPrefix("Siim") })
        #expect(editor.claudeModeReady.count == plannedCount)
        #expect(editor.makeIt.shown?.clipID == reviewing)
        #expect(editor.project.edits.activeClipId == reviewing)
    }
}

private struct DropKeys: ProviderKeyStore {
    func hasKey(for provider: String) async -> Bool { false }
    func save(_ value: String, for provider: String) async throws { }
}

private actor DropConnector: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func knownCLIAuthMethod() async -> String? { "claude.ai" }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        try await Task.sleep(for: .milliseconds(650))
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}
#endif
