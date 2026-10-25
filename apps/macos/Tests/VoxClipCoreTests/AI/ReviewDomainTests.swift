import Foundation
import Testing
@testable import VoxClipCore

@Test("Finalizer uses shared title, reason, score and length limits")
func aiReviewFinalizerLimits() throws {
    let words = (0..<100).map { TimedWord(id: "w\($0)", text: "word", start: Double($0), end: Double($0) + 0.8) }
    let preset = try AIClipTestData.preset(.quotes)
    let candidate = ClipCandidate(title: "long title", reason: "long reason", score: 100, startWord: 0, endWord: 20)
    let limits: JSONValue = .object(["titleMaxLength": .number(3), "reasonMaxLength": .number(4), "scoreMin": .number(3), "scoreMax": .number(5)])
    let result = try finalizeClips([candidate], words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false, limits: limits))
    #expect(result.first?.title == "lon" && result.first?.reason == "long" && result.first?.score == 5)
    var lowScore = candidate
    lowScore.score = -10
    #expect(try finalizeClips([lowScore], words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false, limits: limits)).first?.score == 3)
    for (name, value, end) in [("minLengthFloorSeconds", 5.0, 3.0), ("minLengthFactor", 1.0, 3.0), ("maxLengthFactor", 1.0, 20.0)] {
        var adjusted = candidate
        adjusted.endWord = end
        #expect(try finalizeClips([adjusted], words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false)).count == 1)
        #expect(try finalizeClips([adjusted], words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false, limits: .object([name: .number(value)]))).isEmpty)
    }
    let cutIds = Set((0...10).map { "w\($0)" })
    #expect(try finalizeClips([candidate], words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false, cutWordIds: cutIds)).isEmpty)
    #expect(try finalizeClips([candidate], words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false, cutWordIds: cutIds, limits: .object(["mostlyCutFraction": .number(0.6)]))).count == 1)
    var overlapping = candidate
    overlapping.startWord = 2
    overlapping.endWord = 22
    #expect(try finalizeClips([candidate, overlapping], words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false, windowCount: 2)).count == 1)
    #expect(try finalizeClips([candidate, overlapping], words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false, windowCount: 2, limits: .object(["nearDuplicateOverlap": .number(0.9)]))).count == 2)
    let entries = AIClipTestData.f1()
    let timed = entries.map { TimedWord(id: "w\($0.index)", text: $0.text, start: $0.start, end: $0.end) }
    let unsnapped = ClipCandidate(title: "clip", reason: "reason", score: 7, startWord: 7, endWord: 14)
    let lines = try formatTranscript(entries).lines
    #expect(try finalizeClips([unsnapped], words: timed, preset: preset, lines: lines).first?.startWord == 6)
    let exact = try finalizeClips([unsnapped], words: timed, preset: preset, lines: lines, options: FinalizeClipsOptions(limits: .object(["snapRadiusWords": .number(0)])))
    #expect(exact.first?.startWord == 7 && exact.first?.endWord == 14)
}

@Test("Clip and tighten budgets use catalog token policy and local reserve")
func aiReviewTokenPolicyAndReserve() throws {
    let policy: JSONValue = .object(["tokenEstimate": .object(["utf8BytesPerToken": .number(4.4), "contextSafetyFactor": .number(0.5)])])
    let words = AIClipTestData.f1()
    let preset = try AIClipTestData.preset(.best)
    let builder = ClipRequestBuilder(prompt: try AIClipTestData.prompt(), policy: policy)
    let window = try #require(builder.windows(words: words, preset: preset, contextTokens: 4096, maxOutputTokensCap: 4096, localServer: true).first)
    let overheadWindow = ClipWindow(lines: AIWindowPacking.longestTimeLines(try formatTranscript(words).lines), estimatedTokens: 0, tokenBudget: 0, maxClips: 99)
    let overheadRequest = builder.request(words: words, window: overheadWindow, preset: preset, windowIndex: 1, windowCount: 2, lastTopicEnd: words.last?.index, timeout: .seconds(1))
    func estimate(_ text: String) -> Int { Int(ceil(Double(text.utf8.count) / 4.4)) }
    let overhead = estimate(overheadRequest.system) + estimate(overheadRequest.instruction) + estimate(try overheadRequest.schema.aiCompact()) + 64
    #expect(window.tokenBudget == Int(floor(Double(4096 - overhead - 1024) * 0.5)))
    #expect(window.estimatedTokens == window.lines.reduce(0) { $0 + estimate($1.text + "\n") + ($1.pauseAfter.map { estimate($0 + "\n") } ?? 0) })
    #expect(builder.request(words: words, window: window, preset: preset, timeout: .seconds(1)).maxOutputTokens == 1024)
    let tighten = try TightenRequestBuilder(document: FixtureLoader.decode(JSONValue.self, at: "prompts/ai-tighten.json"), policy: policy)
    let tightened = try #require(tighten.windows(entries: words, strength: "normal", contextTokens: 4096, maxOutputTokensCap: 4096, localServer: true).first)
    #expect(try tighten.request(entries: words, window: tightened, strength: "normal", timeout: .seconds(1)).maxOutputTokens == 1024)
}

@Test("Local reserves honor context quarters without changing cloud reserves", arguments: [4096, 6145, 8192, 32768])
func aiReviewLocalReserveBoundaries(_ context: Int) throws {
    let expected = [4096: 1024, 6145: 1536, 8192: 2048, 32768: 4096][context]
    #expect(aiOutputReserve(generation: 16000, cap: 4096, context: context, localServer: true) == expected)
    #expect(aiOutputReserve(generation: 16000, cap: 4096, context: context, localServer: false) == 4096)
    #expect(aiOutputReserve(generation: 512, cap: 4096, context: context, localServer: true) == 512)
    #expect(aiOutputReserve(generation: 16000, cap: 512, context: context, localServer: true) == 512)
    let words = AIClipTestData.f1()
    let preset = try AIClipTestData.preset(.best)
    let builder = ClipRequestBuilder(prompt: try AIClipTestData.prompt())
    let windows = try builder.windows(words: words, preset: preset, contextTokens: context, maxOutputTokensCap: 4096, localServer: true)
    #expect(!windows.isEmpty)
    #expect(windows.allSatisfy { window in
        builder.request(words: words, window: window, preset: preset, timeout: .seconds(1)).maxOutputTokens == expected
    })
}

@Test("Connection Test and CLI copy match the public contract")
func aiReviewConnectionTestAndCLICopy() throws {
    let catalog = try LLMCatalog(shared: SharedResources(root: FixtureLoader.sharedRoot()))
    for id in ConnectorID.allCases {
        let request = try catalog.connectionTest(for: id)
        #expect(request.language == "en" && request.cachedBlock == nil)
        #expect(request.timeout == (id == .claudeCode || id == .codex ? .seconds(120) : .seconds(30)))
    }
    for name in ["Claude Code", "Codex"] {
        let label = name + " (installed CLI)"
        #expect(LLMError.cliMissing.userMessage(label: label, installHint: "Install it.") == "\(name) isn't installed. Install it. Your edits are saved.")
        #expect(LLMError.planLimit(message: "Try later.").userMessage(label: label) == "Your \(name) plan's usage limit is reached. Try later. Your edits are saved.")
        #expect(LLMError.cliTooOld(version: "1", missing: []).userMessage(label: label) == "Your \(name) 1 is too old for VoxClip. Update it, then try again. Your edits are saved.")
        #expect(LLMError.cliSignedOut.userMessage(label: label, signInHint: "Sign in.") == "\(name) isn't signed in. Sign in. Your edits are saved.")
        #expect(LLMError.cliFailed("Failure.").userMessage(label: label) == "\(name) stopped with an error: Failure. Your edits are saved.")
        #expect(LLMError.timeout.userMessage(label: label)?.hasPrefix(label) == true)
    }
    let gate = ClipFinderGateError.noWords(message: "Prompt message")
    #expect(gate.userMessage == "Prompt message" && gate.errorDescription == "Prompt message")
}
