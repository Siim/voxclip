import Foundation
import Testing
@testable import VoxClipCore

/// Rewrite next steps (voice-lab.md §8.2.1): the optional `nextActions` of both Rewrite replies, the scoped feedback a
/// next step sends, and how a scoped reply lands on the asked phrases, replayed from the independent generator's
/// `rewrite-next-actions-cases.json`, then through both services with a stub connector. Nothing is sent anywhere.
@Suite(.offlineFixtures) struct RewriteNextActionsTests {
    struct Vectors: Decodable {
        struct Parsing: Decodable { let id: String; let input: JSONValue; let expected: [RewriteNextAction] }
        struct Feedback: Decodable {
            let id: String; let instruction: String; let phrases: [RewriteBlockedPhrase]
            let budget: Budget?; let limit: Int?; let merge: [Int]?; let expected: String
            struct Budget: Decodable { let voiceWords: Int; let scopeWords: Int }
        }
        struct Landing: Decodable { let id: String; let current: [[Int]]; let asked: [Int]; let reply: [[Int]]; let expected: [String: String] }
        let schema: String; let sources: [String: String]
        let parsing: [Parsing]; let feedback: [Feedback]; let landing: [Landing]; let caseCount: Int
    }
    private func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/rewrite-next-actions-cases.json"))
    }

    @Test func sharedVectorsPinThePromptsTheyWereMadeFrom() throws {
        let vectors = try vectors()
        #expect(vectors.schema == "voxclip-voice-lab-next-actions-cases/1")
        #expect(vectors.caseCount == vectors.parsing.count + vectors.feedback.count + vectors.landing.count)
        let root = try FixtureLoader.sharedRoot()
        for (path, hash) in vectors.sources {
            let text = try String(contentsOf: root.deletingLastPathComponent().appendingPathComponent(path), encoding: .utf8)
            #expect(AIHash.sha256(text.replacingOccurrences(of: "\r\n", with: "\n")) == hash, "\(path)")
        }
    }

    @Test func parsingKeepsAtMostFourValidActionsAndDropsBadEntries() throws {
        for row in try vectors().parsing {
            #expect(RewriteNextAction.parse(row.input) == row.expected, "\(row.id)")
        }
        #expect(RewriteNextAction.parse(.null).isEmpty)
    }

    @Test func feedbackIsRenderedFromTheSharedTemplatesOnly() throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        for row in try vectors().feedback {
            let rendered: String
            if let merge = row.merge {
                rendered = try RewriteNextActionFeedback.merge(first: merge[0], second: merge[1], shared: shared)
            } else if let limit = row.limit {
                rendered = try RewriteNextActionFeedback.fewerWords(limit: limit, shared: shared)
            } else if row.phrases.isEmpty {
                rendered = try RewriteNextActionFeedback.open(instruction: row.instruction, shared: shared)
            } else {
                rendered = try RewriteNextActionFeedback.scoped(instruction: row.instruction, phrases: row.phrases,
                    budget: row.budget.map { .init(voiceWords: $0.voiceWords, scopeWords: $0.scopeWords) }, shared: shared)
            }
            #expect(rendered == row.expected, "\(row.id)")
        }
        // No instruction, no phrase, or a repeated phrase is invalid input, never an empty request.
        let phrase = RewriteBlockedPhrase(ordinal: 1, reason: .asked, original: "a", proposed: "b")
        #expect(throws: VoiceLabError.invalidInput) { try RewriteNextActionFeedback.scoped(instruction: " \n", phrases: [phrase], shared: shared) }
        #expect(throws: VoiceLabError.invalidInput) { try RewriteNextActionFeedback.scoped(instruction: "Shorter", phrases: [], shared: shared) }
        #expect(throws: VoiceLabError.invalidInput) { try RewriteNextActionFeedback.scoped(instruction: "Shorter", phrases: [phrase, phrase], shared: shared) }
        #expect(throws: VoiceLabError.invalidInput) { try RewriteNextActionFeedback.open(instruction: String(repeating: "x", count: 1_001), shared: shared) }
    }

    @Test func aScopedReplyChangesOnlyTheAskedPhrases() throws {
        func hunk(_ span: [Int]) -> VoiceLabDiffHunk {
            VoiceLabDiffHunk(kind: .voice, sourceWordIds: span[0] == span[1] ? [] : (span[0]..<span[1]).map { "w\($0)" }, newTokens: ["x"],
                             correctedTexts: [], absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: span[0], sourceEndIndex: span[1], anchorSeconds: nil)
        }
        for row in try vectors().landing {
            let outcomes = RewriteScopedReply.assign(current: row.current.map(hunk), asked: Set(row.asked), reply: row.reply.map(hunk))
            let named = Dictionary(uniqueKeysWithValues: outcomes.map { index, outcome -> (String, String) in
                switch outcome {
                case .replace(let found): (String(index), "replace:\(found)")
                case .keepOriginal: (String(index), "keepOriginal")
                case .absorbed(let into): (String(index), "absorbed:\(into)")
                case .conflict: (String(index), "conflict")
                }
            })
            #expect(named == row.expected, "\(row.id)")
        }
    }

    @Test func bothPromptsOfferOptionalNextActionsThatStrictShapingRequires() throws {
        for name in ["voice-rewrite", "patch-rewrite"] {
            let prompt = try FixtureLoader.decode(JSONValue.self, at: "prompts/\(name).json")
            #expect(prompt[ai: "promptVersion"].aiInt == 4, "\(name)")
            let schema = prompt[ai: "schema"]
            #expect(CanonicalResponseParser.validateSchemaSubset(schema), "\(name)")
            #expect(!schema[ai: "required"].aiArray.contains(.string("nextActions")), "\(name): optional in the canonical schema")
            let item = schema[ai: "properties"][ai: "nextActions"][ai: "items"]
            #expect(Set(item[ai: "required"].aiArray.compactMap(\.aiString)) == ["label", "instruction"], "\(name)")
            let strict = CanonicalResponseParser.strictSchema(schema)
            #expect(strict[ai: "required"].aiArray.contains(.string("nextActions")), "\(name): HTTP shaping requires it")
            let strictItem = strict[ai: "properties"][ai: "nextActions"][ai: "items"]
            #expect(Set(strictItem[ai: "required"].aiArray.compactMap(\.aiString)) == ["label", "instruction", "ordinals"], "\(name)")
            #expect(prompt[ai: "system"].aiString?.contains("nextActions") == true, "\(name)")
        }
    }

    @Test func patchRepliesCarryTheirNextActionsWithoutCountingThemAsMalformedEdits() async throws {
        let request = try PatchRewriteFixtures.request(try PatchRewriteFixtures.document())
        let actions = (1...6).map { #"{"label":"Fix \#($0)","instruction":"Fix phrase \#($0).","ordinals":[\#($0)]}"# }.joined(separator: ",")
        let reply = #"{"edits":[],"nextActions":[{"label":7},{"label":"Too many words in this one label","instruction":"x"},"#
            + actions + "]}"
        let (proposal, connector) = try await PatchRewriteFixtures.propose(request, reply: reply)
        #expect(proposal.nextActions.map(\.label) == ["Fix 1", "Fix 2", "Fix 3", "Fix 4"])
        #expect(proposal.nextActions.first?.ordinals == [1] && proposal.malformedItems == 0)
        #expect(await connector.requests.count == 1)
        // A reply without the field has no next steps.
        let (plain, _) = try await PatchRewriteFixtures.propose(request, reply: #"{"edits":[]}"#)
        #expect(plain.nextActions.isEmpty)
    }

    @Test func passageRepliesCarryTheirNextActions() async throws {
        let request = VoiceRewriteRequest(id: UUID(), scope: .passage,
            sourceWords: [TimedWord(id: "w1", text: "We", start: 0, end: 0.2), TimedWord(id: "w2", text: "shipped", start: 0.25, end: 0.6)],
            instruction: "Shorter", language: "en", targetSeconds: 1, minChars: 4, maxChars: 20)
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = CapturingRewriteConnector(output: #"{"rewrite":"We shipped","nextActions":[{"label":"Drop 'shipped'","instruction":"Drop the word shipped.","ordinals":[1, 1.5]},{"label":"Say it in 6 words","instruction":"Say it in six words."}]}"#)
        let quote = try await service.prepare(request, connector: .openai, model: "selected-model")
        let proposal = try await service.propose(request, connector: connector, model: "selected-model",
                                                 authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
        #expect(proposal.nextActions == [RewriteNextAction(label: "Say it in 6 words", instruction: "Say it in six words.")])
    }
}
