import Foundation
import Testing
@testable import VoxClipCore

private struct AIIntegrationKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { nil }
}

private actor AIIntegrationConnector: LLMConnector, LLMTokenCounting {
    nonisolated let id: ConnectorID
    let context: Int
    var failures: [Int: LLMError]
    let replies: [JSONValue]
    let countFactor: Double
    let delay: Bool
    let answeringModels: [String]
    var requests: [LLMRequest] = []
    var tokenCounts = 0

    init(id: ConnectorID = .openai, context: Int = 128000, failures: [Int: LLMError] = [:], replies: [JSONValue] = [], countFactor: Double = 1, delay: Bool = false, answeringModels: [String] = []) {
        self.id = id
        self.context = context
        self.failures = failures
        self.replies = replies
        self.countFactor = countFactor
        self.delay = delay
        self.answeringModels = answeringModels
    }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { context }
    func tokenCount(for prompt: String) -> Int { tokenCounts += 1; return Int(ceil(Double(AIText.estimate(prompt)) * countFactor)) }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        let index = requests.count
        requests.append(request)
        if delay { try await Task.sleep(for: .seconds(30)) }
        if let failure = failures.removeValue(forKey: index) { throw failure }
        return RawCompletion(object: replies.indices.contains(index) ? replies[index] : .object(["clips": .array([])]), model: answeringModels.indices.contains(index) ? answeringModels[index] : "answered", stop: .complete)
    }
}

private func aiIntegrationSetup() throws -> (ClipFinder, ClipRequestBuilder) {
    let shared = try SharedResources(root: FixtureLoader.sharedRoot())
    let catalog = try LLMCatalog(shared: shared)
    let runner = LLMRunner(keys: AIIntegrationKeys(), catalog: catalog, log: RedactingLogger(homeDirectory: "/fixture"))
    return (ClipFinder(runner: runner, shared: shared), ClipRequestBuilder(prompt: try AIClipTestData.prompt()))
}

private func aiIntegrationRequest(count: Int = 100, preset: ClipPresetID = .best) throws -> ClipFinderRequest {
    let words = (0..<count).map { index in
        let start = Double(index) * 0.3
        return TimedWord(id: "w\(index)", text: "w\(index)" + (index % 15 == 14 ? "." : ""), start: start, end: start + 0.25)
    }
    let transcript = Transcript(words: words, language: "en", durationSeconds: words.last?.end ?? 0, engine: EngineRef(id: .whispercpp, engineVersion: "fixture"), rawKey: "fixture", createdAt: Date(timeIntervalSince1970: 0))
    return ClipFinderRequest(transcript: transcript, preset: try AIClipTestData.preset(preset), snap: false)
}

/// A reply naming lines `start...end` (prompt version 2). The fixture's lines hold 15 words each: line n is words
/// 15(n − 1) to 15n − 1.
private func aiIntegrationReply(start: Int, end: Int, title: String = "clip") -> JSONValue {
    .object(["clips": .array([.object(["title": .string(title), "reason": .string("reason"), "score": .number(8), "start_line": .number(Double(start)), "end_line": .number(Double(end))])])])
}

@Test("Clip finder fills empty titles and hashes the full corrected input")
func aiFinderTitleAndProvenance() async throws {
    let (finder, builder) = try aiIntegrationSetup()
    var request = try aiIntegrationRequest()
    request.corrections["w0"] = "Corrected"
    let before = request.transcript
    let connector = AIIntegrationConnector(replies: [aiIntegrationReply(start: 1, end: 4, title: "  ")])
    let started = Date()
    let result = try await finder.find(request, connector: connector, model: "chosen")
    let clips = result.clips
    #expect(clips.count == 1)
    #expect(clips.first?.title.hasPrefix("Corrected w1") == true)
    #expect((clips.first?.title.utf16.count ?? 0) <= 120)
    #expect(request.transcript == before)
    let words = builder.clipWords(request.transcript, corrections: request.corrections)
    let formatted = try formatTranscript(words)
    let block = builder.sentenceBlock(words: words, lines: formatted.lines)
    #expect(block.hasPrefix("<transcript>\n1 0:00 Corrected w1 ") && block.contains("\n2 0:04 w15 ") && !block.contains("[0-14]"))
    #expect(result.inputSha256 == AIHash.sha256(block))
    #expect(result.model == "answered" && result.provider == "openai")
    #expect(result.preset == .best && result.instructions == nil && result.language == "en")
    #expect(result.createdAt >= started && result.createdAt <= Date())
    #expect(result.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#, options: .regularExpression) != nil)
    #expect(clips.first?.startWordId == "w0" && clips.first?.endWordId == "w59")
    #expect(clips.first?.score == 8 && clips.first?.reason == "reason")
}

@Test("Topics continuation includes every earlier valid candidate")
func aiFinderTopicsAcrossWindows() async throws {
    let (finder, _) = try aiIntegrationSetup()
    let request = try aiIntegrationRequest(count: 20000, preset: .topics)
    let connector = AIIntegrationConnector(replies: [aiIntegrationReply(start: 1, end: 5), aiIntegrationReply(start: 7, end: 12)])
    _ = try await finder.find(request, connector: connector, model: "chosen")
    let requests = await connector.requests
    #expect(requests.count > 1)
    #expect(!requests[0].instruction.contains("Topics up to line"))
    #expect(requests[1].instruction.hasSuffix("Topics up to line 5 are already covered. Start at line 6 or later."))
    if requests.count > 2 { #expect(requests[2].instruction.hasSuffix("Topics up to line 12 are already covered. Start at line 13 or later.")) }
    #expect(await finder.lastRun?.windowCount == requests.count)
}

@Test("Without a fallback the last window supplies the answering model")
func aiFinderLastWindowModel() async throws {
    let (finder, _) = try aiIntegrationSetup()
    let connector = AIIntegrationConnector(answeringModels: ["first-answer"])
    let result = try await finder.find(aiIntegrationRequest(count: 20000), connector: connector, model: "chosen")
    #expect(await connector.requests.count > 1)
    #expect(result.model == "answered")
    #expect(await finder.lastUsedFallback == false)
}

@Test("Invalid answering model ids remain saveable", arguments: ["", String(repeating: "x", count: 200)])
func aiFinderInvalidAnsweringModel(_ answeringModel: String) async throws {
    let (finder, _) = try aiIntegrationSetup()
    var request = try aiIntegrationRequest()
    request.transcript.rawKey = String(repeating: "a", count: 64)
    let connector = AIIntegrationConnector(replies: [aiIntegrationReply(start: 1, end: 4)], answeringModels: [answeringModel])
    let result = try await finder.find(request, connector: connector, model: "chosen")
    #expect(result.model == "chosen")
    let clip = try #require(result.clips.first)
    var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/projects/interview-take.voxclip"))
    project.transcript = request.transcript
    project.ai.results = [result]
    project.edits.clips = [ClipRange(id: "ai-clip", startWordId: clip.startWordId, endWordId: clip.endWordId,
                                   origin: .ai, aiResultId: result.id, aiClipIndex: 0)]
    let decoded = try JSONProjectStore.decode(JSONProjectStore.encode(project))
    #expect(decoded.ai.results.first?.model == "chosen")
    #expect(decoded.edits.clips.first?.aiResultId == result.id)
}

@Test("Failed later windows discard all earlier clip suggestions")
func aiFinderAtomicFailure() async throws {
    let (finder, _) = try aiIntegrationSetup()
    let request = try aiIntegrationRequest(count: 20000)
    let connector = AIIntegrationConnector(failures: [1: .timeout], replies: [aiIntegrationReply(start: 1, end: 5)])
    await #expect(throws: LLMError.timeout) { try await finder.find(request, connector: connector, model: "chosen") }
    #expect(await connector.requests.count == 2)
    #expect(await finder.lastRun == nil)
    #expect(request.transcript.words.count == 20000)
}

@Test("Apple actual token counts carry every dropped line forward")
func aiFinderActualTokenWindows() async throws {
    let (finder, _) = try aiIntegrationSetup()
    let request = try aiIntegrationRequest(count: 4000)
    let estimated = try await finder.prepare(request, connector: AIIntegrationConnector(id: .appleFoundation, context: 8192), model: "system")
    let connector = AIIntegrationConnector(id: .appleFoundation, context: 8192, countFactor: 1.8)
    let counted = try await finder.prepare(request, connector: connector, model: "system")
    #expect(counted.count > estimated.count)
    let builder = ClipRequestBuilder(prompt: try AIClipTestData.prompt())
    let words = builder.clipWords(request.transcript)
    for line in try formatTranscript(words).lines {
        // The line as the request numbers it (ai.md §11.3, prompt version 2).
        let sentence = String(builder.sentenceBlock(words: words, lines: [line]).dropFirst("<transcript>\n".count).dropLast("\n</transcript>".count))
        #expect(counted.contains { $0.cachedBlock?.contains("\n" + sentence + "\n") == true || $0.cachedBlock?.hasSuffix("\n" + sentence + "\n</transcript>") == true })
    }
    for canonical in counted {
        let actualCost = await connector.tokenCount(for: canonical.system) + connector.tokenCount(for: aiUserContent(canonical))
        #expect(actualCost + AIText.estimate(try canonical.schema.aiCompact()) + 1500 <= 8192)
    }
    #expect(await connector.requests.isEmpty)
}

@Test("Apple context errors shrink the affected window only once")
func aiFinderContextShrink() async throws {
    let (finder, _) = try aiIntegrationSetup()
    let request = try aiIntegrationRequest(count: 2000)
    let connector = AIIntegrationConnector(id: .appleFoundation, context: 8192, failures: [0: .contextTooLong])
    _ = try await finder.find(request, connector: connector, model: "system")
    let requests = await connector.requests
    #expect(requests.count >= 3)
    #expect((requests[1].cachedBlock?.utf8.count ?? 0) < (requests[0].cachedBlock?.utf8.count ?? 0))
    #expect(requests[1].cachedBlock?.hasPrefix("<transcript>\n1 0:00 w0 ") == true)
    let repeatFailure = AIIntegrationConnector(id: .appleFoundation, context: 8192, failures: [0: .contextTooLong, 1: .contextTooLong])
    await #expect(throws: LLMError.contextTooLong) { try await finder.find(request, connector: repeatFailure, model: "system") }
    #expect(await repeatFailure.requests.count == 2)
    #expect(await finder.lastRun == nil)
}

@Test("Cancellation aborts a run silently and releases its project gate")
func aiFinderCancellation() async throws {
    let (finder, _) = try aiIntegrationSetup()
    let request = try aiIntegrationRequest()
    let connector = AIIntegrationConnector(delay: true)
    let task = Task { try await finder.find(request, connector: connector, model: "chosen") }
    for _ in 0..<100 where await connector.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await connector.requests.count == 1)
    await #expect(throws: LLMError.unavailable(reason: "Clip finder is already running.")) { try await finder.find(request, connector: connector, model: "chosen") }
    task.cancel()
    await #expect(throws: LLMError.cancelled) { try await task.value }
    #expect(await finder.lastRun == nil)
    let retried = try await finder.find(request, connector: AIIntegrationConnector(), model: "chosen")
    #expect(retried.clips.isEmpty)
}

@Test("Clip finder stores normalized instructions and a new result identity", arguments: ["\u{FEFF} \t\n", "\u{FEFF}  notes  \u{00A0}", String(repeating: "a", count: 501)])
func aiFinderStoredInstructions(_ instruction: String) async throws {
    let (finder, builder) = try aiIntegrationSetup()
    var request = try aiIntegrationRequest()
    request.instruction = instruction
    let connector = AIIntegrationConnector()
    let first = try await finder.find(request, connector: connector, model: "chosen")
    let second = try await finder.find(request, connector: connector, model: "chosen")
    let expected = builder.instructions(instruction)
    #expect(first.instructions == (expected.isEmpty ? nil : expected))
    #expect((first.instructions?.utf16.count ?? 0) <= 500)
    #expect(first.id != second.id)
}

@Test("Clip finder preserves clip order and the answering fallback model")
func aiFinderResultOrderAndFallback() async throws {
    let (finder, _) = try aiIntegrationSetup()
    #expect(await finder.lastUsedFallback == nil)
    let request = try aiIntegrationRequest(count: 20000)
    let reply: JSONValue = .object(["clips": .array([
        aiIntegrationReply(start: 1, end: 4, title: "first")[ai: "clips"].aiArray[0],
        aiIntegrationReply(start: 5, end: 8, title: "second")[ai: "clips"].aiArray[0]
    ])])
    let connector = AIIntegrationConnector(failures: [0: .overloaded], replies: [.null, reply], answeringModels: ["", "fallback-answer", "last-answer"])
    let result = try await finder.find(request, connector: connector, model: "chosen")
    #expect(await connector.requests.count > 2)
    #expect(result.model == "fallback-answer")
    #expect(await finder.lastUsedFallback == true)
    #expect(result.clips.map(\.title) == ["first", "second"])
    #expect(result.clips.map(\.startWordId) == ["w0", "w60"])
    #expect(result.clips.map(\.endWordId) == ["w59", "w119"])
    _ = try await finder.find(aiIntegrationRequest(), connector: AIIntegrationConnector(), model: "chosen")
    #expect(await finder.lastUsedFallback == false)
    await #expect(throws: LLMError.timeout) {
        try await finder.find(aiIntegrationRequest(), connector: AIIntegrationConnector(failures: [0: .timeout]), model: "chosen")
    }
    #expect(await finder.lastUsedFallback == nil)
}

@Test("Clip input gates use shared messages and never send")
func aiFinderInputGates() async throws {
    let (finder, _) = try aiIntegrationSetup()
    let connector = AIIntegrationConnector()
    let empty = try aiIntegrationRequest(count: 0)
    let custom = try aiIntegrationRequest(preset: .custom)
    let prompt = try AIClipTestData.prompt().document
    await #expect(throws: ClipFinderGateError.noWords(message: prompt[ai: "messages"][ai: "noWords"].aiString ?? "")) { try await finder.find(empty, connector: connector, model: "chosen") }
    await #expect(throws: ClipFinderGateError.needInstructions(message: prompt[ai: "messages"][ai: "needInstructions"].aiString ?? "")) { try await finder.find(custom, connector: connector, model: "chosen") }
    #expect(await connector.requests.isEmpty)
}
