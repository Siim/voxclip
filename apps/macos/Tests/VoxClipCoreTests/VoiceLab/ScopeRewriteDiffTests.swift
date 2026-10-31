import Foundation
import Testing
@testable import VoxClipCore

/// Shared `scope-rewrite-diff-cases.json` vectors (tools/fixtures/voice-lab/generate_scope_rewrite_diff.py): a clip or Full
/// take proposal as review hunks (voice-lab.md §8.1 item 1 and §8.2). Only the Swift suite replays them until the C# twin
/// lands (plan W1).
@Suite("Scope rewrite diff")
struct ScopeRewriteDiffTests {
    private func document() throws -> JSONValue {
        let document = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/voice-lab/scope-rewrite-diff-cases.json"))
        #expect(document[ai: "schema"].aiString == "voxclip-voice-lab-scope-rewrite-diff/1")
        return document
    }

    /// Equal as scalar sequences, so a decomposed spelling never passes for a precomposed one.
    private func same(_ values: [String], _ value: JSONValue) -> Bool {
        let expected = value.aiArray
        return values.count == expected.count && zip(values, expected).allSatisfy { (pair: (String, JSONValue)) -> Bool in
            guard let text = pair.1.aiString else { return false }
            return pair.0.unicodeScalars.elementsEqual(text.unicodeScalars)
        }
    }

    private func expectHunks(_ hunks: [ScopeRewriteDiff.Hunk], _ expected: JSONValue, _ name: String) {
        let values = expected.aiArray
        #expect(hunks.count == values.count, "\(name): hunk count")
        for (index, (found, value)) in zip(hunks, values).enumerated() {
            let hunk = found.hunk, label = "\(name) hunk \(index)"
            #expect(hunk.kind.rawValue == value[ai: "kind"].aiString, "\(label) kind")
            #expect(same(hunk.sourceWordIds, value[ai: "sourceWordIds"]), "\(label) sourceWordIds")
            #expect(same(hunk.newTokens, value[ai: "newTokens"]), "\(label) newTokens")
            #expect(same(hunk.correctedTexts, value[ai: "correctedTexts"]), "\(label) correctedTexts")
            #expect(same(hunk.absorbedItemIds, value[ai: "absorbedItemIds"]), "\(label) absorbedItemIds")
            #expect(same(hunk.bridgeWordIds, value[ai: "bridgeWordIds"]), "\(label) bridgeWordIds")
            #expect(hunk.sourceStartIndex == value[ai: "sourceStartIndex"].aiInt && hunk.sourceEndIndex == value[ai: "sourceEndIndex"].aiInt,
                    "\(label) source token range")
            #expect(hunk.anchorSeconds == value[ai: "anchorSeconds"].aiDouble, "\(label) anchor")
            #expect(same(found.lines, value[ai: "lines"]) && same(found.reasons, value[ai: "reasons"]), "\(label) lines and reasons")
            #expect(found.checkThis == value[ai: "checkThis"].aiBool, "\(label) checkThis")
        }
    }

    /// Each case's take is planned by `ScopeRewritePlan.make`, as the plan vectors build it, and its reply goes through
    /// `PatchRewriteService` with a canned connector, so the hunks come from the path the app runs.
    @Test func replaysEveryScopeCase() async throws {
        let document = try document()
        let cases = document[ai: "cases"].aiArray
        #expect(cases.count == document[ai: "caseCount"].aiInt)
        let plans = ScopeRewritePlanTests()
        for test in cases {
            let name = test[ai: "name"].aiString ?? "?", input = test[ai: "input"], expected = test[ai: "expected"]
            let plan = try ScopeRewritePlan.make(project: plans.take(input), scope: plans.scope(input[ai: "scope"]),
                                                 instruction: try #require(input[ai: "instruction"].aiString),
                                                 language: try #require(input[ai: "language"].aiString),
                                                 envelope: plans.envelope(input[ai: "envelope"]))
            let proposal: PatchRewriteProposal
            if let reply = input[ai: "reply"].aiString {
                proposal = try await PatchRewriteFixtures.propose(plan.request, reply: reply).0
                let edits = expected[ai: "edits"].aiArray
                #expect(proposal.edits.count == edits.count, "\(name): edits")
                for (edit, value) in zip(proposal.edits, edits) {
                    #expect(edit.line == value[ai: "line"].aiString && edit.inRange == value[ai: "inRange"].aiBool
                            && edit.checkThis == value[ai: "checkThis"].aiBool && edit.isDeletion == value[ai: "isDeletion"].aiBool,
                            "\(name) \(edit.line)")
                }
            } else {
                // A proposal the validator would not have produced for this plan, taken as it is.
                let edits = try input[ai: "proposal"].aiArray.map { (item: JSONValue) throws -> PatchRewriteEdit in
                    let text = try #require(item[ai: "text"].aiString)
                    return PatchRewriteEdit(line: try #require(item[ai: "line"].aiString), text: text,
                                            reason: try #require(item[ai: "reason"].aiString), length: VoiceLabTextLength.length(text),
                                            inRange: true, checkThis: try #require(item[ai: "checkThis"].aiBool),
                                            isDeletion: AIText.trim(text).isEmpty)
                }
                proposal = PatchRewriteProposal(id: UUID(), edits: edits, unknownLines: 0, duplicateLines: 0, malformedItems: 0,
                                                checkThisMessage: "", connector: .openai, model: "selected-model", providerRequestID: nil)
            }
            if let error = expected[ai: "error"].aiString {
                #expect(error == "invalidInput", "\(name)")
                #expect(throws: VoiceLabWordDiffError.invalidInput, "\(name)") { try ScopeRewriteDiff.hunks(plan: plan, proposal: proposal) }
                continue
            }
            expectHunks(try ScopeRewriteDiff.hunks(plan: plan, proposal: proposal), expected[ai: "hunks"], name)
        }
    }

    /// Every `patch-rewrite-cases.json` reply, through `PatchRewriteService`, then mapped to hunks over a plan whose lines are
    /// the `formatTranscript` lines of the case's entries, each entry a word item with ID "i" + index.
    @Test func mapsEveryFixWithAIReply() async throws {
        let document = try document()
        let patch = try PatchRewriteFixtures.document()
        let vectors = patch[ai: "cases"].aiArray
        let results = document[ai: "patchRewriteCases"].aiArray
        #expect(results.count == vectors.count && results.count == document[ai: "patchRewriteCaseCount"].aiInt)
        for (vector, result) in zip(vectors, results) {
            let id = vector[ai: "id"].aiString ?? "?", expected = result[ai: "expected"]
            #expect(result[ai: "id"].aiString == id)
            if expected[ai: "error"] != .null {
                #expect(vector[ai: "expected"][ai: "error"] == expected[ai: "error"], "\(id)")
                continue
            }
            let request = try PatchRewriteFixtures.request(patch, instruction: try #require(vector[ai: "instruction"].aiString),
                                                           entries: vector[ai: "entries"], ranges: vector[ai: "ranges"])
            let proposal = try await PatchRewriteFixtures.propose(request, reply: try #require(vector[ai: "reply"].aiString)).0
            let formatted = try formatTranscript(request.entries)
            #expect(formatted.lines.count == request.ranges.count, "\(id): lines")
            let lines = zip(formatted.lines, request.ranges).map { (pair: (TranscriptLine, PatchRewriteLineRange)) -> ScopeRewritePlan.Line in
                let entries = Array(request.entries[pair.0.firstPos...pair.0.lastPos])
                let items = entries.map { TimedWord(id: "i\($0.index)", text: $0.text, start: $0.start, end: $0.end) }
                return ScopeRewritePlan.Line(line: pair.1.line, items: items, entries: entries,
                                             range: pair.1.minChars...pair.1.maxChars, rangeSource: .lineSpan)
            }
            #expect(lines.map(\.line) == formatted.lines.map { "[\($0.firstIndex)-\($0.lastIndex)]" }, "\(id): labels")
            let plan = ScopeRewritePlan(scope: .fullTake, lines: lines, request: request)
            expectHunks(try ScopeRewriteDiff.hunks(plan: plan, proposal: proposal), expected[ai: "hunks"], id)
        }
    }

    @Test func mergeLimitsMatchTheGenerator() throws {
        let merge = try document()[ai: "merge"]
        #expect(merge[ai: "words"].aiInt == ScopeRewriteDiff.mergeWords)
        #expect(merge[ai: "seconds"].aiDouble == ScopeRewriteDiff.mergeSeconds)
    }

    /// The per-token rule partitions the edit's flag: `flags` is true exactly when one token is, for every Fix with AI reply.
    @Test func tokenFlagsPartitionTheEditFlag() throws {
        let patch = try PatchRewriteFixtures.document()
        for vector in patch[ai: "cases"].aiArray {
            let entries = vector[ai: "entries"] == .null ? patch[ai: "entries"] : vector[ai: "entries"]
            let sources = PatchRewriteValidator.Sources(entries.aiArray.compactMap { $0[ai: "text"].aiString }
                                                        + [vector[ai: "instruction"].aiString ?? ""])
            for edit in vector[ai: "expected"][ai: "edits"].aiArray {
                let text = edit[ai: "text"].aiString ?? ""
                let tokens = sources.flaggedTokens(text)
                #expect(tokens.count == EditingPrimitives.splitWords(text).count, "\(vector[ai: "id"]): token count")
                #expect(tokens.contains(true) == edit[ai: "checkThis"].aiBool, "\(vector[ai: "id"]): flag")
            }
        }
    }
}
