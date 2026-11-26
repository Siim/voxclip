#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClip
import VoxClipCore
import VoxClipMedia

@Suite(.serialized, .offlineFixtures)
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

    @Test(.timeLimit(.minutes(3)), arguments: [0, 1]) func fixtureDropToPost(_ cap: Int) async throws {
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
        #expect(app.set(ClipsMode.capKey, .number(Double(cap))))
        #expect(app.set("export.folder", .string(directory.appendingPathComponent("Exports").path)))
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
        var copiedPost = ""
        var moves = ["Drop video"]
        editor.pasteboardOverride = { copiedPost = $0 }
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
        var paidRequests = 0
        var approvedRequests = 0
        let voicePrice = Decimal(string: "0.10")!
        var gate: TestContinuation<Void>?
        editor.makeIt.style = MakeItStyle(rewording: .tighten, generatedMusic: false, music: false, shapes: [.landscape])
        editor.musicPanel.services = MusicPanelServices(suggest: { _, _ in MusicSuggestionResult(candidates: []) }, fetch: { _ in Data() }, folder: { nil })
        editor.makeIt.services = MakeItServices(plan: { request, _, _, progress in
            guard case .clips(let spans) = request.mode else { return ClipAutopilotSeries(plans: []) }
            plannedCount = spans.count
            #expect(request.transcript.words[0].text == "Siim")
            #expect(!request.moments.contains { $0.title.contains("Seem") })
            let plans = spans.enumerated().map { index, span in
                let first = span.lowerBound
                let last = min(first + 2, span.upperBound)
                let rewrite = ClipAutopilotPlan.Rewrite(startWord: first, endWord: last,
                    text: "\(request.transcript.words[first].text) new \(request.transcript.words[last].text)", reason: "Tighten the middle word.")
                return ClipAutopilotPlan(startWord: span.lowerBound, endWord: span.upperBound, title: "Confirmed clip", hook: "",
                                  rewrites: index == 0 && last - first == 2 ? [rewrite] : [],
                                  captions: MakeItPostableTestsPlan.captions, postText: "Post.", score: 8, verdict: .post)
            }
            for index in plans.indices { progress(.planning(clip: index, of: plans.count)) }
            try await Task.sleep(for: .milliseconds(120))
            if let first = plans.first { progress(.ready(clip: 0, of: plans.count, first)) }
            await withTestDeadline { gate = $0 }
            for index in plans.indices.dropFirst() { progress(.ready(clip: index, of: plans.count, plans[index])) }
            return ClipAutopilotSeries(plans: plans)
        }, voice: { request, _ in
            paidRequests += 1
            guard let budget = request.budget, budget >= voicePrice else {
                Issue.record("The voice stand-in was invoked without sufficient approval")
                return MakeItRewriteOutcome(result: .overCap(nextUSD: voicePrice), spent: 0)
            }
            approvedRequests += 1
            return MakeItRewriteOutcome(result: .voiced(segments: []), spent: voicePrice)
        }, voiceAvailable: { _ in true }, revoiceWholeClip: { _, _ in
            Issue.record("This fixture does not approve a fal.ai lip-sync request")
            return .failed("No lip sync approved.", spent: 0)
        })

        await editor.start()
        await editor.workTask?.value
        await editor.findTask?.value
        await editor.claudeMode.afterFind?.value
        for _ in 0..<100 where editor.claudeModeReady.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.claudeModeReady.count == 1 && plannedCount > 1)
        moves.append("Review clips")
        editor.reviewClaudeMode()
        let reviewing = try #require(editor.claudeModeReady.first?.clipID)
        gate?.resume(); gate = nil
        await editor.claudeMode.task?.value
        let clock = try #require(editor.claudeMode.clock)
        let first = try #require(clock.firstReady)
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

        try #require(editor.canClaudeExportAll)
        moves.append("Export all")
        editor.claudeExportAll()
        let export = try #require(editor.exportTask)
        await export.value
        #expect(!copiedPost.isEmpty)
        #expect(editor.exportFileFailures.isEmpty)
        #expect(editor.exports.count == plannedCount)
        #expect(approvedRequests == (cap == 0 ? 0 : 1) && paidRequests == approvedRequests)
        #expect(editor.claudeMode.budget?.spent == voicePrice * Decimal(approvedRequests))
        let verdicts = try editor.claudeModeReady.map { run in
            let row = try #require(editor.exportJob.checks[run.clipID]?.first)
            let report = try #require(row.report)
            #expect(report.results.map(\.check) == ExportCheckKind.allCases)
            #expect(report[.sync]?.status != .skipped)
            #expect(try String(contentsOf: row.url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8).contains("Post."))
            return report.passed ? "pass" : "review"
        }
        print("drop-to-post \(clock.json()) · moves=\(moves.count) · paid=\(paidRequests)/\(approvedRequests) · checks=\(verdicts.joined(separator: ","))")
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
