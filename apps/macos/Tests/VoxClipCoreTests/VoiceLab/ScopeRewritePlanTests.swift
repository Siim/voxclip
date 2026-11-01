import Foundation
import Testing
@testable import VoxClipCore

/// Shared `scope-rewrite-plan-cases.json` vectors (tools/fixtures/voice-lab/generate_scope_rewrite.py): the Fix with AI request
/// for a clip or Full take (voice-lab.md §8.1 item 1), its lines and their §8.9.1 ranges. Only the Swift suite replays them
/// until the C# twin lands (plan W1).
@Suite("Scope rewrite plan")
struct ScopeRewritePlanTests {
    /// The passage fixture's take is the template every vector's take starts from.
    private static let passage = try? JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))

    private func document() throws -> JSONValue {
        let document = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/voice-lab/scope-rewrite-plan-cases.json"))
        #expect(document[ai: "schema"].aiString == "voxclip-voice-lab-scope-rewrite-plan/1")
        return document
    }
    /// The vector's items, literal or from the README's `wordsRepeat` recipe.
    private func words(_ input: JSONValue) throws -> [TimedWord] {
        let recipe = input[ai: "wordsRepeat"]
        if recipe != .null {
            let token = try #require(recipe[ai: "token"].aiString), prefix = try #require(recipe[ai: "idPrefix"].aiString)
            let step = try #require(recipe[ai: "timingStep"].aiDouble), count = try #require(recipe[ai: "count"].aiInt)
            return (0..<count).map { index in
                let start = Double(index) * step
                return TimedWord(id: prefix + String(index), text: token, start: start, end: start + step / 2)
            }
        }
        return try input[ai: "words"].aiArray.map { item in
            TimedWord(id: try #require(item[ai: "id"].aiString), text: try #require(item[ai: "text"].aiString),
                      kind: try #require(WordKind(rawValue: item[ai: "kind"].aiString ?? "")),
                      start: try #require(item[ai: "start"].aiDouble), end: try #require(item[ai: "end"].aiDouble))
        }
    }
    /// The passage fixture's replacement on a vector's range and seams. `place` reads only the range and the kind and fade of
    /// the selected recipe's seams.
    private func segment(_ value: JSONValue, template: VoiceLabSegment) throws -> VoiceLabSegment {
        func seam(_ value: JSONValue) throws -> VoiceLabSeam {
            VoiceLabSeam(kind: try #require(VoiceLabSeamKind(rawValue: value[ai: "kind"].aiString ?? "")),
                         fadeSamples: Int64(try #require(value[ai: "fadeSamples"].aiInt)), sourceHandleSamples: 0, assetHandleFrames: 0)
        }
        var segment = template
        segment.id = try #require(value[ai: "id"].aiString)
        segment.enabled = try #require(value[ai: "enabled"].aiBool)
        segment.replace = VoiceLabReplacement(start: try #require(value[ai: "start"].aiDouble), end: try #require(value[ai: "end"].aiDouble),
                                              firstWordId: try #require(value[ai: "firstWordId"].aiString),
                                              lastWordId: try #require(value[ai: "lastWordId"].aiString))
        var candidate = try #require(template.candidates.first)
        var recipe = try #require(candidate.recipe)
        recipe.seams = VoiceLabSeams(in: try seam(value[ai: "inSeam"]), out: try seam(value[ai: "outSeam"]))
        candidate.recipe = recipe
        segment.candidates = [candidate]
        segment.selectedCandidateIndex = 0
        return segment
    }
    /// The passage fixture with the vector's items, duration, sample rate, edits and replacements (none unless it lists them).
    func take(_ input: JSONValue) throws -> Project {
        var project = try #require(Self.passage)
        let edits = input[ai: "edits"]
        let template = try #require(project.voiceLab.segments.first)
        project.voiceLab.segments = try input[ai: "segments"].aiArray.map { try segment($0, template: template) }
        project.voiceLab.assets = []
        project.media.source.audio?.sampleRate = try #require(input[ai: "sampleRate"].aiInt)
        project.media.source.durationSeconds = try #require(input[ai: "durationSeconds"].aiDouble)
        project.transcript?.words = try words(input)
        project.edits.cutWordIds = edits[ai: "cutWordIds"].aiArray.compactMap(\.aiString)
        project.edits.cutPauseIds = edits[ai: "cutPauseIds"].aiArray.compactMap(\.aiString)
        project.edits.corrections = (edits[ai: "corrections"].aiObject ?? [:]).compactMapValues(\.aiString)
        project.edits.pauseThresholdSeconds = try #require(edits[ai: "pauseThresholdSeconds"].aiDouble)
        project.edits.pauseKeepSeconds = try #require(edits[ai: "pauseKeepSeconds"].aiDouble)
        project.edits.clips = try edits[ai: "clips"].aiArray.map { clip in
            ClipRange(id: try #require(clip[ai: "id"].aiString), startWordId: try #require(clip[ai: "startWordId"].aiString),
                      endWordId: try #require(clip[ai: "endWordId"].aiString),
                      origin: try #require(ClipOrigin(rawValue: clip[ai: "origin"].aiString ?? "")),
                      selected: try #require(clip[ai: "selected"].aiBool))
        }
        project.edits.activeClipId = nil
        return project
    }
    func envelope(_ value: JSONValue) throws -> AudioEnvelope? {
        guard value != .null else { return nil }
        let levels = try value[ai: "runs"].aiArray.flatMap { run -> [Float] in
            let level = try #require(run.aiArray.first?.aiDouble), count = try #require(run.aiArray.last?.aiInt)
            return Array(repeating: Float(level), count: count)
        }
        return AudioEnvelope(sampleRate: try #require(value[ai: "sampleRate"].aiDouble), levels: levels)
    }
    func scope(_ value: JSONValue) throws -> RewriteScope {
        switch value[ai: "kind"].aiString {
        case "clip": return .clip(try #require(value[ai: "clipId"].aiString))
        case "selection":
            let first = try #require(value[ai: "first"].aiInt), last = try #require(value[ai: "last"].aiInt)
            return .selection(first...last)
        default: return .fullTake
        }
    }
    /// The vector's stored candidates for the rate key (§8.9.1), none unless it lists them.
    private func candidates(_ value: JSONValue) throws -> [VoiceLabRateCandidate] {
        try value.aiArray.map { row in
            VoiceLabRateCandidate(text: try #require(row[ai: "text"].aiString), firstCharStart: try #require(row[ai: "firstCharStart"].aiDouble),
                                  lastCharEnd: try #require(row[ai: "lastCharEnd"].aiDouble))
        }
    }
    private func described(_ error: ScopeRewritePlanError) -> String {
        switch error {
        case .tooManyEntries(let count): "tooManyEntries \(count)"
        case .tooMuchText(let bytes): "tooMuchText \(bytes)"
        case .empty: "empty"
        case .invalidInput: "invalidInput"
        }
    }
    /// The vector's `{error}` in `described` form, with the entry or byte count the error carries.
    private func described(expected: JSONValue) -> String? {
        let code = expected[ai: "error"].aiString
        if code == "tooManyEntries" { return "tooManyEntries \(expected[ai: "count"].aiInt ?? -1)" }
        if code == "tooMuchText" { return "tooMuchText \(expected[ai: "bytes"].aiInt ?? -1)" }
        return code
    }
    private func expectEntry(_ entry: ClipWord, _ value: JSONValue, _ name: String) {
        #expect(entry.index == value[ai: "index"].aiInt && entry.start == value[ai: "start"].aiDouble && entry.end == value[ai: "end"].aiDouble,
                "\(name) entry \(entry.index)")
        #expect(entry.text.unicodeScalars.elementsEqual((value[ai: "text"].aiString ?? "").unicodeScalars), "\(name) entry \(entry.index) text")
    }

    private func expectRange(_ line: ScopeRewritePlan.Line, _ value: JSONValue, _ name: String) {
        #expect(line.range.lowerBound == value[ai: "minChars"].aiInt && line.range.upperBound == value[ai: "maxChars"].aiInt
                && line.rangeSource.rawValue == value[ai: "rangeSource"].aiString, "\(name) \(line.line) range")
    }

    @Test func replaysEveryCase() async throws {
        let document = try document()
        let cases = document[ai: "cases"].aiArray
        #expect(cases.count == document[ai: "caseCount"].aiInt)
        let service = PatchRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        for test in cases {
            let name = test[ai: "name"].aiString ?? "?", input = test[ai: "input"], expected = test[ai: "expected"]
            let id = UUID()
            let plan: ScopeRewritePlan
            do {
                plan = try ScopeRewritePlan.make(project: take(input), scope: scope(input[ai: "scope"]),
                                                 instruction: try #require(input[ai: "instruction"].aiString),
                                                 language: try #require(input[ai: "language"].aiString), envelope: envelope(input[ai: "envelope"]),
                                                 candidates: candidates(input[ai: "rateCandidates"]), id: id)
            } catch let failure as ScopeRewritePlanError {
                #expect(described(failure) == described(expected: expected), "\(name)")
                continue
            }
            guard expected[ai: "error"] == .null else { Issue.record("\(name): expected \(expected[ai: "error"])"); continue }
            #expect(plan.request.id == id && plan.request.instruction == input[ai: "instruction"].aiString
                    && plan.request.language == input[ai: "language"].aiString, "\(name) request")
            #expect(plan.request.ranges == plan.lines.map { PatchRewriteLineRange(line: $0.line, minChars: $0.range.lowerBound, maxChars: $0.range.upperBound) },
                    "\(name) ranges")
            let summary = expected[ai: "summary"]
            let bytes = plan.entries.map(\.text).joined(separator: " ").utf8.count
            if summary != .null {
                #expect(plan.entries.count == summary[ai: "entryCount"].aiInt && bytes == summary[ai: "utf8Bytes"].aiInt, "\(name) size")
                if let first = plan.entries.first, let last = plan.entries.last {
                    expectEntry(first, summary[ai: "firstEntry"], name)
                    expectEntry(last, summary[ai: "lastEntry"], name)
                }
                let lines = summary[ai: "lines"].aiArray
                #expect(plan.lines.count == lines.count, "\(name) lines")
                for (line, value) in zip(plan.lines, lines) {
                    #expect(line.line == value[ai: "line"].aiString && line.itemIDs.count == value[ai: "itemCount"].aiInt
                            && line.itemIDs.first == value[ai: "firstItemId"].aiString && line.itemIDs.last == value[ai: "lastItemId"].aiString,
                            "\(name) \(line.line)")
                    expectRange(line, value, name)
                }
            } else {
                let entries = expected[ai: "entries"].aiArray
                #expect(plan.entries.count == entries.count && bytes == expected[ai: "utf8Bytes"].aiInt, "\(name) entries")
                for (entry, value) in zip(plan.entries, entries) { expectEntry(entry, value, name) }
                let lines = expected[ai: "lines"].aiArray
                #expect(plan.lines.count == lines.count, "\(name) lines")
                for (line, value) in zip(plan.lines, lines) {
                    #expect(line.line == value[ai: "line"].aiString && line.itemIDs == value[ai: "itemIds"].aiArray.compactMap(\.aiString),
                            "\(name) \(line.line)")
                    // The items a re-voiced run precedes, as the vector lists them.
                    let revoiced = zip(line.items, line.revoicedBefore).compactMap { (pair: (TimedWord, Bool)) -> String? in
                        pair.1 ? pair.0.id : nil
                    }
                    #expect(line.revoicedBefore.count == line.items.count
                            && revoiced == value[ai: "revoicedBefore"].aiArray.compactMap(\.aiString), "\(name) \(line.line) revoicedBefore")
                    expectRange(line, value, name)
                }
            }
            // The plan is a request PatchRewriteService accepts: one range per line, within every request bound.
            _ = try await service.estimate(plan.request, connector: .openai)
        }
    }

    @Test func limitsMatchTheGenerator() throws {
        let limits = try document()[ai: "limits"]
        #expect(limits[ai: "maxEntries"].aiInt == ScopeRewritePlan.maxEntries)
        #expect(limits[ai: "maxBytes"].aiInt == ScopeRewritePlan.maxBytes)
        #expect(limits[ai: "maxWordTextLength"].aiInt == ScopeRewritePlan.maxWordTextLength)
        #expect(limits[ai: "maxChars"].aiInt == ScopeRewritePlan.maxChars)
    }
}
