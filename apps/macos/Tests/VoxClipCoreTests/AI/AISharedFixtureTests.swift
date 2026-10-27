import Foundation
import Testing
@testable import VoxClipCore

let aiSharedFixturesAvailable = ProcessInfo.processInfo.environment["VOXCLIP_SHARED_DIR"] != nil || (try? aiGoldenSharedRoot()) != nil
let aiSharedFixturesSkipReason: Comment = "No shared/ directory was selected or found by walking from the test source."

func aiGoldenSharedRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                        sourcePath: String = #filePath,
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> URL {
    if let path = environment["VOXCLIP_SHARED_DIR"] {
        guard !path.isEmpty else { throw VoxClipError.sharedResourcesMissing }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard exists(root) else { throw VoxClipError.sharedResourcesMissing }
        return root
    }
    var directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
    while true {
        let root = directory.appendingPathComponent("shared", isDirectory: true)
        if exists(root), exists(directory.appendingPathComponent("apps")) { return root }
        let parent = directory.deletingLastPathComponent()
        if parent == directory { throw VoxClipError.sharedResourcesMissing }
        directory = parent
    }
}

private struct AIGoldenVector: Sendable, CustomStringConvertible {
    let file: String
    let value: JSONValue
    var description: String { file + "/" + (value[ai: "id"].aiString ?? "?") }
}

private enum AIGoldenCorpus {
    static let files = ["ai-tighten-requests", "cli-replies", "clip-finder-requests", "connector-requests", "extensions", "finalize-clips", "format-transcript", "patch-rewrite-requests", "tighten-verifier", "to-fixed", "voice-rewrite-requests"]
    static func document(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: aiGoldenSharedRoot().appendingPathComponent("fixtures/llm/\(file).json")))
    }
    static var vectors: [AIGoldenVector] {
        files.flatMap { vectors(file: $0, load: document) }
    }
    static func vectors(file: String, load: (String) throws -> JSONValue) -> [AIGoldenVector] {
        do {
            guard case .array(let cases) = try load(file)[ai: "cases"], !cases.isEmpty else {
                throw AIGoldenFailure("Missing fixture cases")
            }
            // The CLI connector suites replay connector renderings and CLI replies.
            return cases.filter { !["connector-request", "cli-reply"].contains($0[ai: "kind"].aiString ?? "") }
                .map { AIGoldenVector(file: file, value: $0) }
        } catch { return [AIGoldenVector(file: file, value: .null)] }
    }
    static func number(_ value: JSONValue) throws -> Double {
        if let number = value.aiDouble { return number }
        switch value.aiString {
        case "NaN": return .nan
        case "Infinity": return .infinity
        case "-Infinity": return -.infinity
        case "-0": return -0.0
        default: throw AIGoldenFailure("Expected numeric input")
        }
    }
    static func entries(_ value: JSONValue) throws -> [ClipWord] {
        let source: [JSONValue]
        switch value[ai: "generator"].aiString {
        case "U100": return (0..<100).map { ClipWord(index: $0, text: "w\($0)", start: Double($0), end: Double($0) + 0.8) }
        case "W1": return (0..<20000).map { index in
            let start = 0.3 * Double(index)
            return ClipWord(index: index, text: "w\(index)" + (index % 15 == 14 ? "." : ""), start: start, end: start + 0.25)
        }
        case nil: source = value.aiArray
        default: throw AIGoldenFailure("Unknown word recipe")
        }
        return try source.enumerated().map { position, item in
            ClipWord(index: item[ai: "index"].aiInt ?? position, text: try #require(item[ai: "text"].aiString), start: try number(item[ai: "start"]), end: try number(item[ai: "end"]))
        }
    }
    static func timed(_ source: JSONValue, entries: [ClipWord]) -> [TimedWord] {
        entries.enumerated().map { position, entry in TimedWord(id: source.aiArray.indices.contains(position) ? source.aiArray[position][ai: "id"].aiString ?? "w\(entry.index)" : "w\(entry.index)", text: entry.text, start: entry.start, end: entry.end) }
    }
    static func json<Value: Encodable>(_ value: Value) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    static func canonical(_ request: LLMRequest) -> JSONValue {
        .object(["feature": .string(request.feature.rawValue), "system": .string(request.system), "cachedBlock": request.cachedBlock.map(JSONValue.string) ?? .null,
                 "instruction": .string(request.instruction), "schemaName": .string(request.schemaName), "schema": request.schema,
                 "maxOutputTokens": .number(Double(request.maxOutputTokens)), "effort": request.effort.map { .string($0.rawValue) } ?? .null, "language": request.language.map(JSONValue.string) ?? .null])
    }
}

private struct AIGoldenFailure: Error { let detail: String; init(_ detail: String) { self.detail = detail } }

@Test("Empty selected fixture paths cannot fall back to worktree resources")
private func aiSharedGoldenEmptyOverrideFailsClosed() {
    #expect(throws: VoxClipError.sharedResourcesMissing) {
        try aiGoldenSharedRoot(environment: ["VOXCLIP_SHARED_DIR": ""])
    }
}

@Test("Golden resources walk from source when no override is set")
private func aiSharedGoldenWalksFromSource() throws {
    let root = try aiGoldenSharedRoot(environment: [:], sourcePath: "/worktree/apps/macos/Tests/fixture.swift",
                                      exists: { ["/worktree/shared", "/worktree/apps"].contains($0.path) })
    #expect(root.path == "/worktree/shared")
}

@Test("Missing selected golden roots never fall back to the worktree")
private func aiSharedGoldenMissingOverrideFailsClosed() {
    #expect(throws: VoxClipError.sharedResourcesMissing) {
        try aiGoldenSharedRoot(environment: ["VOXCLIP_SHARED_DIR": "/missing/shared"], sourcePath: "/worktree/apps/macos/Tests/fixture.swift",
                               exists: { ["/worktree/shared", "/worktree/apps"].contains($0.path) })
    }
}

@Test("No selected or discoverable shared directory is unavailable")
private func aiSharedGoldenMissingRoot() {
    #expect(throws: VoxClipError.sharedResourcesMissing) {
        try aiGoldenSharedRoot(environment: [:], sourcePath: "/missing/fixture.swift", exists: { _ in false })
    }
}

@Test("Malformed pure-golden case lists retain a failing vector", arguments: [
    JSONValue.null, .object([:]), .object(["cases": .null]),
    .object(["cases": .object([:])]), .object(["cases": .array([])])
])
private func aiSharedGoldenMalformedCasesRetainFailure(_ document: JSONValue) {
    let vectors = AIGoldenCorpus.vectors(file: "fixture") { _ in document }
    #expect(vectors.count == 1)
    #expect(vectors.first?.file == "fixture")
    #expect(vectors.first?.value == .null)
}

@Test("Unreadable pure-golden files retain a failing vector")
private func aiSharedGoldenUnreadableFileRetainsFailure() {
    let vectors = AIGoldenCorpus.vectors(file: "missing") { _ in throw AIGoldenFailure("Unreadable fixture") }
    #expect(vectors.count == 1)
    #expect(vectors.first?.file == "missing")
    #expect(vectors.first?.value == .null)
}

@Test("Pure-golden loading preserves order and excludes connector renderings")
private func aiSharedGoldenLoadingPreservesPureCases() {
    let first: JSONValue = .object(["id": .string("first"), "kind": .string("format-time")])
    let connector: JSONValue = .object(["id": .string("connector"), "kind": .string("connector-request")])
    let second: JSONValue = .object(["id": .string("second"), "kind": .string("format-time")])
    let vectors = AIGoldenCorpus.vectors(file: "fixture") { _ in .object(["cases": .array([first, connector, second])]) }
    #expect(vectors.map(\.value) == [first, second])
    #expect(AIGoldenCorpus.vectors(file: "connector-requests") { _ in .object(["cases": .array([connector])]) }.isEmpty)
}

@Test("Every shared LLM fixture has a valid independent envelope", .enabled(if: aiSharedFixturesAvailable, aiSharedFixturesSkipReason))
func aiSharedFixtureEnvelopes() throws {
    let root = try aiGoldenSharedRoot()
    let actualFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("fixtures/llm"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    #expect(actualFiles == AIGoldenCorpus.files)
    let knownKinds: Set<String> = ["format-transcript", "to-fixed-1", "format-time", "to-fixed-random", "finalize-clips", "snap-pair", "prepare-entries", "string-helpers", "windows", "pack-lines", "tighten-verifier", "render-request", "connector-request", "voice-rewrite-request", "patch-rewrite-request", "cli-reply"]
    for file in actualFiles {
        let document = try AIGoldenCorpus.document(file)
        #expect(document[ai: "schema"].aiString == "voxclip-llm-fixtures/1")
        #expect(document[ai: "id"].aiString == file)
        #expect(document[ai: "origin"].aiString == "voxclip")
        let cases = document[ai: "cases"].aiArray
        #expect(!cases.isEmpty)
        let ids = cases.compactMap { $0[ai: "id"].aiString }
        #expect(ids.count == cases.count && Set(ids).count == cases.count)
        for item in cases { #expect(knownKinds.contains(item[ai: "kind"].aiString ?? ""), "Unknown fixture kind in \(file)") }
        for (relative, expected) in document[ai: "sources"].aiObject ?? [:] {
            #expect(relative.hasPrefix("shared/") && !relative.contains(".."))
            let text = try String(contentsOf: root.appendingPathComponent(String(relative.dropFirst("shared/".count))), encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
            #expect(AIHash.sha256(text) == expected.aiString, "Source drift: \(relative)")
        }
    }
}

@Test("Shared pure AI golden vectors", .enabled(if: aiSharedFixturesAvailable, aiSharedFixturesSkipReason), arguments: AIGoldenCorpus.vectors)
private func aiSharedGoldenVector(_ vector: AIGoldenVector) async throws {
    let item = try #require(vector.value == .null ? nil : vector.value,
        "Missing, unreadable or invalid required LLM fixture: fixtures/llm/\(vector.file).json")
    let input = item[ai: "input"]
    let expected = item[ai: "expected"]
    let actual: JSONValue
    switch item[ai: "kind"].aiString {
    case "format-transcript": actual = try AIGoldenCorpus.json(formatTranscript(AIGoldenCorpus.entries(input[ai: "entries"])))
    case "to-fixed-1": actual = .string(toFixed1(try AIGoldenCorpus.number(input[ai: "value"])))
    case "format-time": actual = .string(AIText.formatTime(try AIGoldenCorpus.number(input[ai: "seconds"])))
    case "to-fixed-random":
        #expect(input[ai: "generator"].aiString == "lcg32-scaled-binary64-v1")
        var state = UInt32(try #require(input[ai: "seed"].aiInt))
        let oracle = expected.aiArray
        #expect(oracle.count == input[ai: "count"].aiInt)
        let scale = try AIGoldenCorpus.number(input[ai: "scale"])
        for value in oracle {
            state = 1664525 &* state &+ 1013904223
            let sample = (Double(state) / 4294967296) * scale
            #expect(toFixed1(sample) == value.aiString)
        }
        return
    case "finalize-clips":
        let entries = try AIGoldenCorpus.entries(input[ai: "words"])
        let candidates = try input[ai: "candidates"].aiArray.map { candidate in
            ClipCandidate(title: candidate[ai: "title"].aiString ?? "", reason: candidate[ai: "reason"].aiString ?? "", score: try AIGoldenCorpus.number(candidate[ai: "score"]), startWord: try AIGoldenCorpus.number(candidate[ai: "start_word"]), endWord: try AIGoldenCorpus.number(candidate[ai: "end_word"]))
        }
        let preset = try AIClipTestData.preset(#require(ClipPresetID(rawValue: input[ai: "preset"].aiString ?? "")))
        let clips = try finalizeClips(candidates, words: AIGoldenCorpus.timed(input[ai: "words"], entries: entries), preset: preset, lines: formatTranscript(entries).lines,
                                      options: FinalizeClipsOptions(snap: input[ai: "snap"].aiBool ?? false, cutWordIds: Set(input[ai: "cutWordIds"].aiArray.compactMap(\.aiString)), windowCount: input[ai: "windowCount"].aiInt ?? 1))
        actual = try AIGoldenCorpus.json(clips)
    case "snap-pair":
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: input[ai: "lines"].aiEncoded())
        let pair = input[ai: "pair"].aiArray.compactMap(\.aiInt)
        let snapped = clipsSnapPair(start: pair[0], end: pair[1], lines: lines, radius: input[ai: "radius"].aiInt ?? 3)
        actual = .array([.number(Double(snapped.0)), .number(Double(snapped.1))])
    case "string-helpers": actual = .string(AIText.prefix(AIText.trim(input[ai: "text"].aiString ?? ""), utf16: input[ai: "maxLength"].aiInt ?? 0))
    case "pack-lines":
        let lines = try JSONDecoder().decode([TranscriptLine].self, from: input[ai: "lines"].aiEncoded())
        if expected[ai: "error"].aiString == "contextTooLong" {
            #expect(throws: LLMError.contextTooLong) { try AIWindowPacking.pack(lines: lines, budget: input[ai: "budget"].aiInt ?? 0, maxWords: input[ai: "maxWords"].aiInt ?? 0, overlap: input[ai: "overlapSeconds"].aiDouble ?? 0) }
            return
        }
        let ranges = try AIWindowPacking.pack(lines: lines, budget: input[ai: "budget"].aiInt ?? 0, maxWords: input[ai: "maxWords"].aiInt ?? 0, overlap: input[ai: "overlapSeconds"].aiDouble ?? 0)
        actual = .array(ranges.map { aiGoldenWindow(Array(lines[$0.range]), allLines: lines, cost: $0.estimatedCost, labels: false) })
    case "windows": try aiGoldenWindows(input, expected: expected); return
    case "prepare-entries": actual = try aiGoldenPrepared(input)
    case "tighten-verifier":
        let entries = try AIGoldenCorpus.entries(input[ai: "entries"])
        let ids = Dictionary(uniqueKeysWithValues: zip(entries, input[ai: "entries"].aiArray).map { ($0.0.index, $0.1[ai: "id"].aiString ?? "w\($0.0.index)") })
        let edits = try JSONDecoder().decode([TightenLineEdit].self, from: input[ai: "edits"].aiEncoded())
        let result = try TightenValidator.validate(edits, entries: entries, wordIds: ids, lines: formatTranscript(entries).lines, eligibleWordIds: Set(ids.values), config: FixtureLoader.decode(JSONValue.self, at: "prompts/ai-tighten.json"))
        #expect(try AIGoldenCorpus.json(result.proposals).aiEncoded() == expected[ai: "proposals"].aiEncoded(), "\(vector)")
        #expect(result.rejectedCount == expected[ai: "rejectedCount"].aiInt, "\(vector)")
        #expect(result.rejectedEdits.map { $0.reason.rawValue } == expected[ai: "rejected"].aiArray.compactMap { $0[ai: "reason"].aiString })
        return
    case "render-request":
        try await aiGoldenRequest(vector)
        return
    case "voice-rewrite-request":
        try await voiceRewriteGoldenRequest(item, label: vector.description)
        return
    case "patch-rewrite-request":
        try await patchRewriteGoldenRequest(item, label: vector.description)
        return
    default: throw AIGoldenFailure("Unknown fixture kind in \(vector)")
    }
    #expect(try actual.aiEncoded() == expected.aiEncoded(), "\(vector)")
}

private func aiGoldenWindow(_ lines: [TranscriptLine], allLines: [TranscriptLine], cost: Int, labels: Bool = true) -> JSONValue {
    guard let first = lines.first, let last = lines.last else { return .null }
    var result: [String: JSONValue] = ["firstLine": .number(Double(allLines.firstIndex(of: first) ?? -1)), "lastLine": .number(Double(allLines.firstIndex(of: last) ?? -1)),
                                      "firstIndex": .number(Double(first.firstIndex)), "lastIndex": .number(Double(last.lastIndex)), "entryCount": .number(Double(last.lastPos - first.firstPos + 1)), "estimatedCost": .number(Double(cost))]
    if labels { result["lineLabels"] = .array(lines.map { .string(String($0.text.prefix(while: { $0 != " " }))) }) }
    return .object(result)
}

private func aiGoldenWindows(_ input: JSONValue, expected: JSONValue) throws {
    let entries = try AIGoldenCorpus.entries(input[ai: "words"])
    let lines = try formatTranscript(entries).lines
    let windows: [ClipWindow]
    let sample: LLMRequest
    let requests: [LLMRequest]
    if input[ai: "feature"].aiString == "aiTighten" {
        let builder = try TightenRequestBuilder(document: FixtureLoader.decode(JSONValue.self, at: "prompts/ai-tighten.json"))
        windows = try builder.windows(entries: entries, strength: input[ai: "choice"].aiString ?? "normal", contextTokens: input[ai: "context"].aiInt ?? 0, maxOutputTokensCap: input[ai: "maxOutputTokensCap"].aiInt, localServer: input[ai: "localServer"].aiBool ?? false)
        requests = try windows.enumerated().map { index, window in
            try builder.request(entries: entries, window: window, strength: input[ai: "choice"].aiString ?? "normal", windowIndex: index, windowCount: windows.count, timeout: .seconds(180))
        }
        sample = try builder.request(entries: entries, window: ClipWindow(lines: AIWindowPacking.longestTimeLines(lines), estimatedTokens: 0, tokenBudget: 0, maxClips: 99), strength: input[ai: "choice"].aiString ?? "normal", windowCount: 2, timeout: .seconds(180))
    } else {
        let builder = ClipRequestBuilder(prompt: try AIClipTestData.prompt())
        let preset = try AIClipTestData.preset(#require(ClipPresetID(rawValue: input[ai: "choice"].aiString ?? "")))
        windows = try builder.windows(words: entries, preset: preset, contextTokens: input[ai: "context"].aiInt ?? 0, maxOutputTokensCap: input[ai: "maxOutputTokensCap"].aiInt, localServer: input[ai: "localServer"].aiBool ?? false)
        requests = windows.enumerated().map { index, window in
            builder.request(words: entries, window: window, preset: preset, windowIndex: index, windowCount: windows.count, timeout: .seconds(180))
        }
        sample = builder.request(words: entries, window: ClipWindow(lines: AIWindowPacking.longestTimeLines(lines), estimatedTokens: 0, tokenBudget: 0, maxClips: 99), preset: preset, windowIndex: 1, windowCount: 2, lastTopicEnd: entries.last?.index, timeout: .seconds(180))
    }
    let overhead = AIText.estimate(sample.system) + AIText.estimate(sample.instruction) + AIText.estimate(try sample.schema.aiCompact()) + 64
    #expect(overhead == expected[ai: "overhead"].aiInt)
    #expect(windows.first?.tokenBudget == expected[ai: "budget"].aiInt)
    #expect(windows.allSatisfy { $0.maxOutputTokens == expected[ai: "outputReserve"].aiInt })
    #expect(requests.allSatisfy { $0.maxOutputTokens == expected[ai: "outputReserve"].aiInt })
    if let maxClips = expected[ai: "maxClips"].aiInt { #expect(windows.allSatisfy { $0.maxClips == maxClips }) }
    let actual = JSONValue.array(windows.map { aiGoldenWindow($0.lines, allLines: lines, cost: $0.estimatedTokens) })
    #expect(try actual.aiEncoded() == expected[ai: "windows"].aiEncoded())
}

private func aiGoldenPrepared(_ input: JSONValue) throws -> JSONValue {
    let items = input[ai: "items"].aiArray
    let words = try items.map { item in
        let kind = try #require(WordKind(rawValue: item[ai: "kind"].aiString ?? ""))
        return try TimedWord(id: item[ai: "id"].aiString ?? "", text: item[ai: "text"].aiString ?? "", kind: kind, start: AIGoldenCorpus.number(item[ai: "start"]), end: AIGoldenCorpus.number(item[ai: "end"]))
    }
    let transcript = Transcript(words: words, durationSeconds: words.last?.end ?? 0, engine: EngineRef(id: .whispercpp, engineVersion: "fixture"), rawKey: "fixture", createdAt: Date(timeIntervalSince1970: 0))
    let corrections = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in guard let correction = item[ai: "correction"].aiString, let id = item[ai: "id"].aiString else { return nil }; return (id, correction) })
    let entries: [ClipWord]
    if input[ai: "options"][ai: "feature"].aiString == "aiTighten" {
        let scope = input[ai: "options"][ai: "scope"].aiArray.compactMap(\.aiInt)
        let range = scope.count == 2 ? ClipRange(id: "fixture", startWordId: words[scope[0]].id, endWordId: words[scope[1]].id) : nil
        entries = try TightenInput(transcript: transcript, corrections: corrections, cutWordIds: Set(input[ai: "options"][ai: "cutWordIds"].aiArray.compactMap(\.aiString)), scope: range, maxWordTextLength: input[ai: "options"][ai: "maxWordTextLength"].aiInt ?? 100).entries
    } else { entries = ClipRequestBuilder(prompt: try AIClipTestData.prompt()).clipWords(transcript, corrections: corrections) }
    return .array(entries.map { .object(["id": .string(words[$0.index].id), "index": .number(Double($0.index)), "text": .string($0.text), "start": .number($0.start), "end": .number($0.end)]) })
}

private func aiGoldenRequest(_ vector: AIGoldenVector) async throws {
    let input = vector.value[ai: "input"]
    let expected = vector.value[ai: "expected"]
    let source = input[ai: "entries"].aiArray.isEmpty ? try #require(AIGoldenCorpus.document("format-transcript")[ai: "cases"].aiArray.first { $0[ai: "id"].aiString == "F1" })[ai: "input"][ai: "entries"] : input[ai: "entries"]
    let entries = try AIGoldenCorpus.entries(source)
    let lines = try formatTranscript(entries).lines
    let selection = input[ai: "window"]
    let firstLine = selection[ai: "firstLine"].aiInt ?? 0
    let lastLine = selection[ai: "lastLine"].aiInt ?? lines.count - 1
    let window = ClipWindow(lines: Array(lines[firstLine...lastLine]), estimatedTokens: 0, tokenBudget: 0, maxClips: selection[ai: "maxClips"].aiInt ?? 99)
    let request: LLMRequest
    if vector.file == "ai-tighten-requests" {
        request = try TightenRequestBuilder(document: FixtureLoader.decode(JSONValue.self, at: "prompts/ai-tighten.json")).request(entries: entries, window: window, strength: input[ai: "choice"].aiString ?? "normal", instruction: input[ai: "instructions"].aiString, windowIndex: selection[ai: "index"].aiInt ?? 0, windowCount: selection[ai: "count"].aiInt ?? 1, timeout: .seconds(180), language: input[ai: "language"].aiString)
    } else {
        let builder = ClipRequestBuilder(prompt: try AIClipTestData.prompt())
        let preset = try AIClipTestData.preset(#require(ClipPresetID(rawValue: input[ai: "choice"].aiString ?? "")))
        if expected[ai: "error"].aiString != nil {
            #expect(preset.requiresInstructions && builder.instructions(input[ai: "instructions"].aiString).isEmpty)
            #expect(expected[ai: "message"] == builder.prompt.document[ai: "messages"][ai: "needInstructions"])
            return
        }
        request = builder.request(words: entries, window: window, preset: preset, instruction: input[ai: "instructions"].aiString, windowIndex: selection[ai: "index"].aiInt ?? 0, windowCount: selection[ai: "count"].aiInt ?? 1, lastTopicEnd: selection[ai: "lastEnd"].aiInt, timeout: .seconds(180), language: input[ai: "language"].aiString)
    }
    #expect(try AIGoldenCorpus.canonical(request).aiEncoded() == expected[ai: "request"].aiEncoded(), "\(vector)")
}
