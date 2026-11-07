import Foundation
import Testing
@testable import VoxClipCore

/// Revoice the whole clip (ADR-R46): the switch rule at its edges, the Claude-mode choice within the cap, the script with
/// edits applied, its parts, the fit, the price from the tables, the project record and the disclosure.
struct WholeClipRevoiceRuleTests {
    private func reason(spoken: Int, revoiced: Int, noFit: Int = 0) -> WholeClipRevoice.Reason? {
        WholeClipRevoice.reason(.init(spokenWords: spoken, revoicedWords: revoiced, noFitPhrases: noFit))
    }

    @Test func wordShareSwitchesAtExactlyFortyPercent() {
        #expect(reason(spoken: 100, revoiced: 39) == nil)
        #expect(reason(spoken: 100, revoiced: 40) == .manyWords(revoiced: 40, spoken: 100))
        #expect(reason(spoken: 5, revoiced: 2) == .manyWords(revoiced: 2, spoken: 5))
        #expect(reason(spoken: 74, revoiced: 29) == nil)   // 39.2%
        #expect(reason(spoken: 74, revoiced: 30) != nil)   // 40.5%
        #expect(reason(spoken: 74, revoiced: 58) == .manyWords(revoiced: 58, spoken: 74))
        #expect(reason(spoken: 0, revoiced: 3) == nil)
        #expect(reason(spoken: 10, revoiced: 0) == nil)
        #expect(WholeClipRevoice.wordSharePercent == 40)
    }

    @Test func twoPhrasesThatCantFitSwitch() {
        #expect(reason(spoken: 100, revoiced: 10, noFit: 1) == nil)
        #expect(reason(spoken: 100, revoiced: 10, noFit: 2) == .phrasesCantFit(2))
        #expect(reason(spoken: 100, revoiced: 0, noFit: 3) == .phrasesCantFit(3))
        #expect(WholeClipRevoice.noFitPhrases == 2)
    }

    @Test func claudeModeRevoicesOnlyWithinTheCapAndOffersOverIt() {
        let stitched = WholeClipRevoice.Reason.manyWords(revoiced: 58, spoken: 74)
        let price = Decimal(string: "1.04")!
        #expect(WholeClipRevoice.autoChoice(stitched, price: price, remaining: 2) == .revoice(price: price))
        #expect(WholeClipRevoice.autoChoice(stitched, price: price, remaining: price) == .revoice(price: price))
        #expect(WholeClipRevoice.autoChoice(stitched, price: price, remaining: Decimal(string: "1.03")!) == .patchAndOffer(price: price))
        // No paid step may run: the offer stands, nothing is spent.
        #expect(WholeClipRevoice.autoChoice(stitched, price: price, remaining: nil) == .patchAndOffer(price: price))
        // No price known: never spent and never offered.
        #expect(WholeClipRevoice.autoChoice(stitched, price: nil, remaining: 2) == .patch)
        #expect(WholeClipRevoice.autoChoice(nil, price: price, remaining: 2) == .patch)
    }

    @Test func calloutKeepsTheMockupsCopy() {
        #expect(WholeClipRevoice.callout(.manyWords(revoiced: 58, spoken: 74))
                == "These changes re-voice 58 words, a lot for a 74-word clip. Long stretches in your voice can sound stitched.")
    }
}

struct WholeClipScriptTests {
    private func word(_ index: Int, _ text: String, kind: WordKind = .word) -> TimedWord {
        TimedWord(id: "w\(index)", text: text, kind: kind, start: Double(index) * 0.5, end: Double(index) * 0.5 + 0.4,
                  rawStart: nil, rawEnd: nil, conf: nil, speaker: nil)
    }
    private func hunk(_ ids: [String], _ text: String) -> VoiceLabDiffHunk {
        VoiceLabDiffHunk(kind: .voice, sourceWordIds: ids, newTokens: EditingPrimitives.splitWords(text), correctedTexts: [],
                         absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 0, sourceEndIndex: ids.count, anchorSeconds: nil)
    }
    private var words: [TimedWord] {
        ["So", "we", "drove", "north.", "It", "was", "um", "cold.", "Then", "we", "stopped."].enumerated().map { word($0.offset, $0.element) }
            + [word(11, "[music]", kind: .event)]
    }

    @Test func assemblesTheClipsWordsWithEditsAndRewritesInOrder() throws {
        let script = try #require(WholeClipScript.assemble(words: words, cutWordIds: ["w6"], voiceHunks: [hunk(["w8", "w9", "w10"], "Then we finally stopped.")]))
        #expect(script.text == "So we drove north. It was cold. Then we finally stopped.")
        #expect(script.words == 11 && script.sentences.count == 3)
        #expect(script.sentences[2].sourceWordIds == ["w8", "w9", "w10"])
        #expect(script.sentences[1].sourceWordIds == ["w4", "w5", "w7"])
        // Without the edits, the cut word and the original wording come back.
        let plain = try #require(WholeClipScript.assemble(words: words, cutWordIds: [], voiceHunks: []))
        #expect(plain.text == "So we drove north. It was um cold. Then we stopped.")
        #expect(WholeClipScript.assemble(words: [word(0, "[music]", kind: .event)], cutWordIds: [], voiceHunks: []) == nil)
    }

    @Test func aRewriteSpanningSentencesKeepsItsPlace() throws {
        let script = try #require(WholeClipScript.assemble(words: words, cutWordIds: [], voiceHunks: [hunk(["w3", "w4", "w5"], "east, and it got")]))
        #expect(script.text == "So we drove east, and it got um cold. Then we stopped.")
    }

    @Test func partsSplitAtSentencesWithinTheirSeconds() throws {
        // Twelve sentences of four words, 2 s each: 24 s of source in parts of at most 12 s, so two parts of six.
        let long = (0..<48).map { index -> TimedWord in
            let start: Double = Double(index) * 0.5
            let end: Double = start + 0.45
            let text: String = index % 4 == 3 ? "end." : "word"
            return TimedWord(id: "l\(index)", text: text, start: start, end: end)
        }
        let script = try #require(WholeClipScript.assemble(words: long, cutWordIds: [], voiceHunks: []))
        let parts = script.parts
        #expect(parts.count == 2 && parts.map(\.words) == [24, 24])
        #expect(parts.allSatisfy { $0.end - $0.start <= WholeClipRevoice.maximumPartSeconds })
        #expect(parts.map(\.words).reduce(0, +) == script.words)
        #expect(parts.flatMap(\.sourceWordIds) == long.map(\.id))
        let hunks = script.hunks(words: long)
        #expect(hunks.count == 2 && hunks.allSatisfy { $0.kind == .voice })
        #expect(hunks.flatMap(\.newTokens).joined(separator: " ") == script.text)
        #expect(hunks.flatMap(\.sourceWordIds) == long.map(\.id))
        // A short clip is one part.
        #expect(try #require(WholeClipScript.assemble(words: words, cutWordIds: [], voiceHunks: [])).parts.count == 1)
    }
}

struct WholeClipFitTests {
    @Test func withinEightPercentTheVideoIsMatched() {
        #expect(WholeClipRevoice.fit(voiceSeconds: 30.6, videoSeconds: 31, words: 74, round: 0) == .matched(factor: 30.6 / 31))
        #expect(WholeClipRevoice.fit(voiceSeconds: 108, videoSeconds: 100, words: 74, round: 0) == .matched(factor: 1.08))
        #expect(WholeClipRevoice.fit(voiceSeconds: 92, videoSeconds: 100, words: 74, round: 0) == .matched(factor: 0.92))
        #expect(WholeClipRevoice.matchedCopy(factor: 30.6 / 31) == "video matched (−1.3%)")
        #expect(WholeClipRevoice.matchedCopy(factor: 1.02) == "video matched (+2.0%)")
    }

    @Test func outsideItAsksForAMeasuredWordingThenSaysSo() {
        #expect(WholeClipRevoice.fit(voiceSeconds: 108.1, videoSeconds: 100, words: 100, round: 0) == .reword(shorter: true, targetWords: 93))
        #expect(WholeClipRevoice.fit(voiceSeconds: 80, videoSeconds: 100, words: 80, round: 1) == .reword(shorter: false, targetWords: 100))
        #expect(WholeClipRevoice.fit(voiceSeconds: 120, videoSeconds: 100, words: 100, round: WholeClipRevoice.maximumRewordRounds)
                == .cannotFit(voiceSeconds: 120, videoSeconds: 100))
        #expect(WholeClipRevoice.fit(voiceSeconds: 0, videoSeconds: 100, words: 10, round: 0) == .cannotFit(voiceSeconds: 0, videoSeconds: 100))
    }
}

@Suite(.offlineFixtures) struct WholeClipPriceAndRecordTests {
    private func catalog() throws -> VoiceLabPriceCatalog {
        try VoiceLabPriceCatalog(data: FixtureLoader.data("catalog/voice-lab.json"))
    }

    @Test func pricesComeFromTheTables() throws {
        let catalog = try catalog()
        let standard = try WholeClipRevoice.price(characters: 400, ttsModel: "eleven_v4", videoSeconds: 31, lipsync: .lipsync2, catalog: catalog)
        // lipsync-2 at $0.05 a second; eleven_v4 at $0.08 per 1,000 characters.
        #expect(standard.lipsync.usd == Decimal(string: "1.55"))
        #expect(standard.voice.usd == Decimal(string: "0.032"))
        #expect(standard.usd == Decimal(string: "1.582"))
        let upgrade = try WholeClipRevoice.lipsyncPrice(videoSeconds: 31, lipsync: .sync3, catalog: catalog)
        // sync-3 at $8 a minute: 31 s is $4.1333…, shown with the shared formatter's two significant digits.
        #expect(upgrade.usd.map { abs(NSDecimalNumber(decimal: $0).doubleValue - 31.0 * 8 / 60) < 0.000_001 } == true)
        #expect(VoiceLabCostPresentation.format(upgrade.usd!) == "≈ $4.10")
        #expect(WholeClipRevoice.Lipsync.standard == .lipsync2)
        #expect(WholeClipRevoice.Lipsync.lipsync2.endpoint == "fal-ai/sync-lipsync/v2" && WholeClipRevoice.Lipsync.lipsync2.model == "lipsync-2")
        #expect(WholeClipRevoice.Lipsync.sync3.endpoint == "fal-ai/sync-lipsync/v3" && WholeClipRevoice.Lipsync.sync3.model == nil)
        // An unknown voice model has no price, so the whole has none.
        let unknown = try WholeClipRevoice.price(characters: 400, ttsModel: "no-such-model", videoSeconds: 31, lipsync: .lipsync2, catalog: catalog)
        #expect(unknown.usd == nil)
    }

    @Test func eachModelIsOneOfTheProvidersOwn() {
        let provider = Set(["fal-ai/latentsync", "fal-ai/sync-lipsync/v2:lipsync-2", "fal-ai/sync-lipsync/v2:lipsync-2-pro", "fal-ai/sync-lipsync/v3"])
        #expect(WholeClipRevoice.Lipsync.allCases.allSatisfy { provider.contains($0.lipsyncModel.id) })
    }

    private func fixture() throws -> Project { try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/lipsync-render-v3.voxclip")) }
    private func record(_ segments: [String] = ["vl-passage", "vl-thanks"]) -> WholeClipRevoiceRecord {
        WholeClipRevoiceRecord(id: "wholeclip-1", clipId: "clip-main", segmentIds: segments, script: "Thanks for watching.",
                               consentRecordId: "consent-1", videoRetime: 0.987, lipsyncModel: WholeClipRevoice.Lipsync.lipsync2.rawValue,
                               usd: 1.58, match: .init(take: 0.81, anchorBaseline: 0.54, realSpeech: nil),
                               createdAt: Date(timeIntervalSince1970: 1_793_000_000))
    }

    @Test func aRecordSavesAndReopens() throws {
        var project = try fixture()
        project.voiceLab.wholeClipRevoices = [record()]
        try VoiceLabProject.validate(project)
        let saved = try JSONProjectStore.encode(project)
        let reopened = try JSONProjectStore.decode(saved)
        #expect(reopened.voiceLab.wholeClipRevoices == [record()])
        #expect(WholeClipRevoice.isRevoiced(clipId: "clip-main", in: reopened) && !WholeClipRevoice.isRevoiced(clipId: "other", in: reopened))
        #expect(!WholeClipRevoice.isRevoiced(clipId: "clip-main", in: try fixture()))
        #expect(try JSONProjectStore.encode(reopened) == saved)
        let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let voiceLab = try #require(object["voiceLab"] as? [String: Any])
        let first = try #require((voiceLab["wholeClipRevoices"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["id", "clipId", "segmentIds", "script", "consentRecordId", "videoRetime", "lipsyncModel", "usd", "match", "createdAt"])
        // None: the key is left out, so earlier files save unchanged.
        let plain = try JSONProjectStore.encode(try fixture())
        #expect(!String(decoding: plain, as: UTF8.self).contains("wholeClipRevoices"))
    }

    @Test func aRecordThatBreaksItsRulesIsRefused() throws {
        func refused(_ change: (inout Project) -> Void) throws -> Bool {
            var project = try fixture()
            project.voiceLab.wholeClipRevoices = [record()]
            change(&project)
            return (try? VoiceLabProject.validate(project)) == nil
        }
        #expect(try refused { $0.voiceLab.wholeClipRevoices![0].segmentIds = ["missing"] })
        #expect(try refused { $0.voiceLab.wholeClipRevoices![0].segmentIds = [] })
        #expect(try refused { $0.voiceLab.wholeClipRevoices![0].segmentIds = ["vl-passage", "vl-passage"] })
        #expect(try refused { $0.voiceLab.wholeClipRevoices![0].clipId = "no-clip" })
        #expect(try refused { $0.voiceLab.wholeClipRevoices![0].lipsyncModel = "fal-ai/latentsync" })
        #expect(try refused { $0.voiceLab.wholeClipRevoices![0].videoRetime = 1.09 })
        #expect(try refused { $0.voiceLab.wholeClipRevoices![0].usd = -1 })
        #expect(try refused { $0.voiceLab.wholeClipRevoices![0].match = .init(take: 1.5, anchorBaseline: nil, realSpeech: nil) })
        #expect(try refused { $0.voiceLab.wholeClipRevoices = [] })
        #expect(try refused { project in
            var second = self.record(["vl-thanks"]); second.id = "wholeclip-2"
            project.voiceLab.wholeClipRevoices = [self.record(["vl-passage", "vl-thanks"]), second]
        })
        #expect(try refused { $0.schemaVersion = 2 })
        #expect(try !refused { _ in })
    }

    @Test func exportsSayVoiceAndLipMovementGeneratedWithAI() throws {
        var project = try fixture()
        let before = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        #expect(before.disclosure.kinds.contains(WholeClipRevoice.disclosureKind) == false)
        project.voiceLab.wholeClipRevoices = [record()]
        let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        #expect(prepared.disclosure.kinds.contains(WholeClipRevoice.disclosureKind))
        #expect(prepared.disclosure.postText == "Voice and lip movement generated with AI.")
        #expect(prepared.disclosure.required)
    }
}

struct WholeClipLedgerTests {
    @Test func aPaidStepIsNeverPaidAgain() {
        var ledger = WholeClipRevoiceLedger()
        let voice = WholeClipRevoiceLedger.VoiceKey(script: "So we drove north.", recordId: "r1", model: "eleven_v4")
        let standard = WholeClipRevoiceLedger.LipsyncKey(voice: voice, retime: 0.99, model: .lipsync2)
        let upgrade = WholeClipRevoiceLedger.LipsyncKey(voice: voice, retime: 0.99, model: .sync3)
        #expect(ledger.remaining(voice: voice, voiceUSD: 1, lipsync: standard, lipsyncUSD: 2) == 3)
        ledger.record(voice, usd: 1)
        // A failed lip sync's Try Again pays only the lip sync.
        #expect(ledger.remaining(voice: voice, voiceUSD: 1, lipsync: standard, lipsyncUSD: 2) == 2)
        ledger.record(standard, usd: 2)
        #expect(ledger.remaining(voice: voice, voiceUSD: 1, lipsync: standard, lipsyncUSD: 2) == 0)
        // The sync-3 upgrade reuses the voice.
        #expect(ledger.remaining(voice: voice, voiceUSD: 1, lipsync: upgrade, lipsyncUSD: 4) == 4)
        // Another script is another voice.
        let other = WholeClipRevoiceLedger.VoiceKey(script: "Shorter.", recordId: "r1", model: "eleven_v4")
        #expect(ledger.remaining(voice: other, voiceUSD: 1, lipsync: nil, lipsyncUSD: 0) == 1)
        #expect(ledger.total == 3)
    }
}
