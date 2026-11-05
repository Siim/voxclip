import CryptoKit
import Foundation
import Testing
@testable import VoxClipCore

/// shared/fixtures/ask-claude/ask-claude-cases.json: the Ask Claude request and the op-by-op validation of stub replies
/// (ai.md §18).
@Suite(.offlineFixtures) struct AskClaudeTests {
    private static func fixture() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/ask-claude/ask-claude-cases.json")) }
    private static func shared() throws -> SharedResources { try SharedResources.locate() }
    private static func prompt() throws -> AskClaudePrompt { try AskClaudePrompt.load(shared: shared()) }
    private static func project() throws -> Project {
        try ProjectJSON.decode(JSONEncoder().encode(fixture()[ai: "project"]))
    }
    private static func detections(_ value: JSONValue) -> [AskClaudeDetection] {
        value.aiArray.map { item in
            AskClaudeDetection(label: item[ai: "label"].aiString ?? "", kind: item[ai: "kind"].aiString == "face" ? .face : .text,
                               start: item[ai: "start"].aiDouble ?? 0, end: item[ai: "end"].aiDouble ?? 0,
                               rect: .init(x: item[ai: "x"].aiDouble ?? 0, y: item[ai: "y"].aiDouble ?? 0, width: item[ai: "width"].aiDouble ?? 0,
                                           height: item[ai: "height"].aiDouble ?? 0), text: item[ai: "text"].aiString)
        }
    }
    private static func selection(_ item: JSONValue) -> AskClaudeSelection {
        let words = item[ai: "selection"][ai: "words"].aiArray.compactMap(\.aiInt)
        return AskClaudeSelection(scope: .words(words[0]...words[1]), clipID: item[ai: "clipID"].aiString)
    }
    private static func close(_ a: Double?, _ b: Double?) -> Bool { guard let a, let b else { return a == nil && b == nil }; return abs(a - b) < 1e-6 }

    @Test("The fixture is current for the prompt file")
    func fixtureIsCurrent() throws {
        let sha = SHA256.hash(data: try FixtureLoader.data("prompts/ask-claude.json")).map { String(format: "%02x", $0) }.joined()
        #expect(try Self.fixture()[ai: "promptSha256"].aiString == sha)
        #expect(try Self.fixture()[ai: "format"].aiString == "voxclip-ask-claude/1")
        #expect(try Self.prompt().kinds.count == 20)
        // Stickers are exactly the bundled emoji images, so every sticker renders from the app's own files.
        let folder = try Self.shared().root.appendingPathComponent("fonts/noto-emoji/png128")
        let bundled = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("emoji_u") }.map { name in
            String(String.UnicodeScalarView(name.dropFirst(7).dropLast(4).split(separator: "_").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }))
        }
        #expect(try Self.prompt().stickers == Set(bundled) && bundled.count == 50)
    }

    @Test("The request carries the instruction, the indexed words, context, the clip, detections and the toolbox, at extra high effort")
    func requestMatchesTheIndependentRender() throws {
        let prompt = try Self.prompt(), project = try Self.project()
        for item in try Self.fixture()[ai: "requests"].aiArray {
            let scope = try AskClaudeScope.resolve(Self.selection(item), in: project)
            let request = prompt.request(item[ai: "instruction"].aiString ?? "", scope: scope, project: project,
                                         detections: Self.detections(item[ai: "detections"]), aspect: item[ai: "aspect"].aiString ?? "",
                                         timeout: .seconds(60), language: "en")
            #expect(request.instruction == item[ai: "expectedInstruction"].aiString, "\(item[ai: "id"].aiString ?? "")")
            #expect(request.feature == .askClaude && request.effort == .xhigh && request.schemaName == "ask_claude_ops")
            #expect(request.system.contains("Never ask a question"))
        }
    }

    @Test("Stub replies validate op by op: clamped, defaulted, pre-picked when ambiguous, dropped when they cannot act")
    func repliesValidateOpByOp() throws {
        let prompt = try Self.prompt(), project = try Self.project()
        let words = try #require(project.transcript?.words)
        for item in try Self.fixture()[ai: "replies"].aiArray {
            let id = item[ai: "id"].aiString ?? ""
            let scope = try AskClaudeScope.resolve(Self.selection(item), in: project)
            let answer = AskClaudeValidator(prompt: prompt, scope: scope, project: project, detections: Self.detections(item[ai: "detections"]))
                .answer(item[ai: "reply"])
            let expected = item[ai: "expect"].aiArray
            #expect(answer.operations.count == expected.count, "\(id)")
            #expect(answer.repairs.count == item[ai: "repairs"].aiInt, "\(id): \(answer.repairs)")
            #expect(!answer.summary.isEmpty)
            for (operation, want) in zip(answer.operations, expected) {
                let label = "\(id) \(operation.id)"
                #expect(operation.decision.rawValue == want[ai: "decision"].aiString, "\(label)")
                #expect(!operation.reason.isEmpty, "\(label)")
                #expect(answer.choices[operation.id] == want[ai: "choice"].aiString, "\(label) choice")
                switch operation.action {
                case .effect(let effect):
                    #expect(effect.kind.rawValue == want[ai: "kind"].aiString, "\(label)")
                    #expect(Self.close(effect.start, want[ai: "start"].aiDouble) && Self.close(effect.end, want[ai: "end"].aiDouble), "\(label) range")
                    #expect(effect.clipId == "clip-main", "\(label)")
                    if let ids = want[ai: "wordIds"].aiArray.nonEmpty { #expect(effect.wordIds == ids.compactMap(\.aiString), "\(label)") }
                    if let rect = want[ai: "rect"].aiArray.nonEmpty?.compactMap(\.aiDouble) {
                        #expect(effect.rect == ClipEffect.Rect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), "\(label) rect")
                    }
                    if let tracking = want[ai: "tracking"].aiString { #expect(effect.tracking?.rawValue == tracking, "\(label)") }
                    if let text = want[ai: "text"].aiString { #expect(effect.text == text, "\(label)") }
                    if let position = want[ai: "position"].aiString { #expect(effect.position?.rawValue == position, "\(label)") }
                    if let scale = want[ai: "scale"].aiDouble { #expect(effect.scale == scale, "\(label)") }
                    if let sound = want[ai: "sound"].aiString { #expect(effect.sound?.id == sound, "\(label)") }
                    #expect(throws: Never.self) { try ClipEffects.validate(effect, projectId: project.id) }
                case .stretch(let clip, let start, let end, let rate):
                    #expect(want[ai: "kind"].aiString == "stretch" && clip == "clip-main" && rate == want[ai: "rate"].aiDouble, "\(label)")
                    #expect(Self.close(start, want[ai: "start"].aiDouble) && Self.close(end, want[ai: "end"].aiDouble), "\(label)")
                case .motion(let cue):
                    #expect(want[ai: "kind"].aiString == "zoom" && cue.clipID == "clip-main", "\(label)")
                    #expect(Self.close(cue.sourceStart, want[ai: "start"].aiDouble) && Self.close(cue.sourceEnd, want[ai: "end"].aiDouble), "\(label)")
                    #expect(cue.keyframes.map(\.scale) == [want[ai: "scale"].aiDouble ?? 0, want[ai: "scale"].aiDouble ?? 0], "\(label)")
                case .edit(.correct(let word, let text)):
                    #expect(want[ai: "kind"].aiString == "correction" && [word] == want[ai: "wordIds"].aiArray.compactMap(\.aiString) && text == want[ai: "text"].aiString, "\(label)")
                case .edit(.cutSelection(let ids)):
                    #expect(want[ai: "kind"].aiString == "jumpCut" && ids == want[ai: "wordIds"].aiArray.compactMap(\.aiString), "\(label)")
                case .rewrite(.selection(let range), let text):
                    let span = want[ai: "wordRange"].aiArray.compactMap(\.aiInt)
                    #expect(range == span[0]...span[1] && text == want[ai: "text"].aiString, "\(label)")
                    #expect(answer.paid.contains(operation) && want[ai: "paid"] == .bool(true), "\(label)")
                case .translateCaptions(_, let start, let end, let language, let text):
                    let span = want[ai: "wordRange"].aiArray.compactMap(\.aiInt)
                    #expect([start, end] == span && language == want[ai: "language"].aiString && text == want[ai: "text"].aiString, "\(label)")
                default: Issue.record("Unexpected action in \(label): \(operation.action)")
                }
            }
            _ = words
        }
    }

    @Test("Applying an answer adds every free change in one project step, keeps paid and unrendered ones pending, and each comes off alone")
    func applyIsOneGroupAndEachRowUndoesAlone() throws {
        let prompt = try Self.prompt(), project = try Self.project()
        let item = try #require(Self.fixture()[ai: "replies"].aiArray.first { $0[ai: "id"].aiString == "timing-sound-and-words" })
        let scope = try AskClaudeScope.resolve(Self.selection(item), in: project)
        let answer = AskClaudeValidator(prompt: prompt, scope: scope, project: project, detections: []).answer(item[ai: "reply"])
        let applied = try ClipAutopilotMapping.apply(answer.operations, to: project)
        #expect(applied.project.schemaVersion == 4)
        #expect(applied.project.clipEffects.map(\.kind) == [.freeze, .sound])
        #expect(applied.project.motionCues.count == 1)
        #expect(applied.project.edits.corrections == ["w19": "darn"] && applied.project.edits.cutWordIds == ["w18"])
        #expect(applied.pending.map(\.decision) == [.stretch, .rewrite, .translate])
        #expect(try ProjectJSON.decode(ProjectJSON.encode(applied.project)) == applied.project)
        // One row off: the same answer without that operation leaves the others in place.
        let withoutFreeze = answer.operations.filter { $0.decision != .freeze }
        let partial = try ClipAutopilotMapping.apply(withoutFreeze, to: project)
        #expect(partial.project.clipEffects.map(\.kind) == [.sound] && partial.project.motionCues.count == 1)
        // A free answer has no paid rows; the mockup's answer is all free.
        let mockup = try #require(Self.fixture()[ai: "replies"].aiArray.first)
        let free = AskClaudeValidator(prompt: prompt, scope: try AskClaudeScope.resolve(Self.selection(mockup), in: project), project: project,
                                      detections: Self.detections(mockup[ai: "detections"])).answer(mockup[ai: "reply"])
        #expect(free.paid.isEmpty)
        let censored = try ClipAutopilotMapping.apply(free.operations, to: project).project
        let segments = project.transcript!.words.map { EditSegment(id: $0.id, kind: .word, text: $0.text, start: $0.start, end: $0.end, cut: false) }
        let masked = ClipEffects.maskingBleeps(segments, effects: censored.clipEffects).map(\.text)
        #expect(masked[10...14].allSatisfy { $0.unicodeScalars.allSatisfy { $0 == "\u{00D7}" || $0 == "," } } && masked[9] == "is")
    }

    @Test("A time-range selection resolves its words; a zoom on the full video finds its clip; ducking needs music")
    func scopesAndFallbacks() throws {
        let prompt = try Self.prompt(), project = try Self.project()
        let words = try #require(project.transcript?.words)
        let range = try AskClaudeScope.resolve(AskClaudeSelection(scope: .time(words[3].start + 0.01...words[5].end - 0.01), clipID: nil), in: project)
        #expect(range.words == 3...5 && range.isTime && range.clipID == nil)
        let full = AskClaudeScope(words: 0...4, start: words[0].start, end: words[4].end, clipID: nil, isClip: false, isTime: false)
        let reply: JSONValue = .object(["summary": .string("Zoomed."), "ops": .array([
            .object(["kind": .string("zoom"), "reason": .string("Punch in.")]), .object(["kind": .string("duck"), "reason": .string("Duck.")])])])
        let answer = AskClaudeValidator(prompt: prompt, scope: full, project: project, detections: []).answer(reply)
        guard case .motion(let cue)? = answer.operations.first?.action else { Issue.record("No zoom"); return }
        #expect(cue.clipID == "clip-main" && answer.operations.count == 1 && answer.repairs.count == 1)
        let clip = try AskClaudeScope.resolve(AskClaudeSelection(scope: .clip("clip-main"), clipID: "clip-main"), in: project)
        #expect(clip.words == 0...(words.count - 1) && clip.isClip)
        #expect(throws: (any Error).self) { try AskClaudeScope.resolve(AskClaudeSelection(scope: .clip("nope"), clipID: nil), in: project) }
    }

    @Test("The service sends one request through the runner and returns the checked answer; an empty instruction sends nothing")
    func serviceWithStubConnector() async throws {
        let shared = try Self.shared(), catalog = try LLMCatalog(shared: shared), project = try Self.project()
        let mockup = try #require(Self.fixture()[ai: "replies"].aiArray.first)
        let reply = String(decoding: try JSONEncoder().encode(mockup[ai: "reply"]), as: UTF8.self)
        let connector = AskConnector(reply: reply)
        let service = AskClaudeService(runner: LLMRunner(keys: AskKeys(), catalog: catalog, log: AskLog()), prompt: try Self.prompt(), catalog: catalog)
        let result = try await service.ask("blur the invoice on screen and bleep the amount", selection: Self.selection(mockup), project: project,
                                           detections: Self.detections(mockup[ai: "detections"]), aspect: "9:16", connector: connector, model: "m")
        #expect(result.answer.operations.map(\.decision) == [.blur, .bleep] && result.promptVersion == 1)
        let sent = await connector.sent
        #expect(sent.count == 1 && sent.first?.feature == .askClaude && sent.first?.effort == .xhigh)
        let silent = AskConnector(reply: reply)
        await #expect(throws: (any Error).self) {
            _ = try await service.ask("   ", selection: Self.selection(mockup), project: project, detections: [], aspect: "9:16", connector: silent, model: "m")
        }
        #expect(await silent.sent.isEmpty)
    }
}

private extension Array { var nonEmpty: Self? { isEmpty ? nil : self } }

private struct AskKeys: KeyProvider { func key(for provider: String) async throws -> String? { nil } }
private actor AskLog: Redacting {
    func register(secret: String) {}
    func redact(_ message: String) -> String { message }
    func write(_ entry: LogEntry) {}
}
private actor AskConnector: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    var sent: [LLMRequest] = []
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { 200_000 }
    func send(_ request: LLMRequest, model: String) throws -> RawCompletion {
        sent.append(request)
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}
