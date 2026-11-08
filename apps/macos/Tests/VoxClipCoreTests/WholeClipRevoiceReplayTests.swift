import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/voice-lab/whole-clip-revoice-cases.json (ADR-R46; the C# twin WholeClipRevoiceReplayTests replays the same
/// file): the switch rule, Claude mode's choice, the script, its parts and hunks, the fit and its copy, the price and the ledger.
@Suite(.offlineFixtures) struct WholeClipRevoiceReplayTests {
    private struct Found: Decodable { let kind: String; let revoiced: Int?; let spoken: Int?; let count: Int? }
    private struct RuleCase: Decodable { let spokenWords: Int; let revoicedWords: Int; let noFitPhrases: Int; let reason: Found?; let callout: String? }
    private struct Choice: Decodable { let kind: String; let price: String? }
    private struct ChoiceCase: Decodable { let stitched: Bool; let price: String?; let remaining: String?; let expected: Choice }
    private struct Word: Decodable { let id: String; let text: String; let kind: String; let start: Double; let end: Double }
    private struct Hunk: Decodable { let sourceWordIds: [String]; let newText: String }
    private struct Sentence: Decodable { let text: String; let sourceWordIds: [String]; let start: Double; let end: Double }
    private struct Part: Decodable { let text: String; let words: Int; let sourceWordIds: [String]; let start: Double; let end: Double }
    private struct MadeHunk: Decodable {
        let sourceWordIds: [String]; let newTokens: [String]; let absorbedItemIds: [String]; let sourceStartIndex: Int; let sourceEndIndex: Int
    }
    private struct Script: Decodable {
        let text: String; let words: Int; let characters: Int; let sentences: [Sentence]; let parts: [Part]; let hunks: [MadeHunk]
    }
    private struct ScriptCase: Decodable {
        let id: String; let words: [Word]; let cutWordIds: [String]; let cutPauseIds: [String]; let voiceHunks: [Hunk]; let expected: Script?
    }
    private struct FitResult: Decodable { let kind: String; let factor: Double?; let copy: String?; let targetWords: Int? }
    private struct FitCase: Decodable { let voiceSeconds: Double; let videoSeconds: Double; let words: Int; let round: Int; let expected: FitResult }
    private struct Prices: Decodable { let voiceUsd: String?; let lipsyncUsd: String?; let usd: String? }
    private struct PriceCase: Decodable { let characters: Int; let ttsModel: String; let videoSeconds: Double; let lipsync: String; let expected: Prices }
    private struct VoiceKey: Decodable { let script: String; let recordId: String; let model: String }
    private struct LipsyncKey: Decodable { let voice: VoiceKey; let retime: Double; let model: String }
    private struct Asked: Decodable { let voice: VoiceKey; let voiceUsd: String; let lipsync: LipsyncKey?; let lipsyncUsd: String }
    private struct Step: Decodable {
        let total: String?; let recordVoice: VoiceKey?; let recordLipsync: LipsyncKey?; let usd: String?
        let paidVoice: VoiceKey?; let paidLipsync: LipsyncKey?; let remaining: Asked?
        let expected: Expected?
        enum Expected: Decodable {
            case flag(Bool), money(String)
            init(from decoder: any Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let flag = try? value.decode(Bool.self) { self = .flag(flag) } else { self = .money(try value.decode(String.self)) }
            }
        }
    }
    private struct LedgerCase: Decodable { let id: String; let steps: [Step] }
    private struct Cases: Decodable {
        let format: String; let rule: [RuleCase]; let autoChoice: [ChoiceCase]; let script: [ScriptCase]; let fit: [FitCase]
        let price: [PriceCase]; let ledger: [LedgerCase]
    }

    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/voice-lab/whole-clip-revoice-cases.json"))
    }
    private func money(_ text: String?) -> Decimal? { text.flatMap { Decimal(string: $0) } }

    @Test func formatIsItsOwnFile() throws {
        #expect(try cases().format == "voxclip-whole-clip-revoice/1")
    }

    @Test func theSwitchRuleAndItsCallout() throws {
        let rows = try cases().rule
        #expect(rows.count == 16)
        for row in rows {
            let found = WholeClipRevoice.reason(.init(spokenWords: row.spokenWords, revoicedWords: row.revoicedWords, noFitPhrases: row.noFitPhrases))
            var expected: WholeClipRevoice.Reason?
            if let reason = row.reason {
                expected = reason.kind == "manyWords" ? .manyWords(revoiced: reason.revoiced ?? -1, spoken: reason.spoken ?? -1) : .phrasesCantFit(reason.count ?? -1)
            }
            #expect(found == expected)
            #expect(found.map(WholeClipRevoice.callout) == row.callout)
        }
    }

    @Test func claudeModeRevoicesOnlyWithinTheCap() throws {
        let rows = try cases().autoChoice
        #expect(rows.count == 10)
        for row in rows {
            let stitched: WholeClipRevoice.Reason? = row.stitched ? .manyWords(revoiced: 58, spoken: 74) : nil
            let choice = WholeClipRevoice.autoChoice(stitched, price: money(row.price), remaining: money(row.remaining))
            let price: Decimal = money(row.expected.price) ?? -1
            let expected: WholeClipRevoice.AutoChoice = row.expected.kind == "patch" ? .patch : row.expected.kind == "revoice" ? .revoice(price: price) : .patchAndOffer(price: price)
            #expect(choice == expected)
        }
    }

    private func timed(_ word: Word) -> TimedWord {
        let kind: WordKind = word.kind == "word" ? .word : word.kind == "event" ? .event : .unlabeledSpeech
        return TimedWord(id: word.id, text: word.text, kind: kind, start: word.start, end: word.end, rawStart: nil, rawEnd: nil, conf: nil, speaker: nil)
    }

    @Test func theScriptItsPartsAndTheirVoiceChanges() throws {
        let rows = try cases().script
        #expect(rows.count == 28)
        for row in rows {
            let words = row.words.map(timed)
            let hunks = row.voiceHunks.map { hunk in
                VoiceLabDiffHunk(kind: .voice, sourceWordIds: hunk.sourceWordIds, newTokens: EditingPrimitives.splitWords(hunk.newText), correctedTexts: [],
                                 absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 0, sourceEndIndex: 0, anchorSeconds: nil)
            }
            let script = WholeClipScript.assemble(words: words, cutWordIds: Set(row.cutWordIds), voiceHunks: hunks)
            guard let expected = row.expected else { #expect(script == nil, "\(row.id)"); continue }
            let made = try #require(script, "\(row.id)")
            #expect(made.text == expected.text && made.words == expected.words && made.characters == expected.characters, "\(row.id)")
            #expect(made.sentences.map(\.text) == expected.sentences.map(\.text), "\(row.id)")
            #expect(made.sentences.map(\.sourceWordIds) == expected.sentences.map(\.sourceWordIds), "\(row.id)")
            #expect(made.sentences.map(\.start) == expected.sentences.map(\.start), "\(row.id)")
            #expect(made.sentences.map(\.end) == expected.sentences.map(\.end), "\(row.id)")
            let parts = made.parts
            #expect(parts.map(\.text) == expected.parts.map(\.text), "\(row.id)")
            #expect(parts.map(\.words) == expected.parts.map(\.words), "\(row.id)")
            #expect(parts.map(\.sourceWordIds) == expected.parts.map(\.sourceWordIds), "\(row.id)")
            #expect(parts.map(\.start) == expected.parts.map(\.start) && parts.map(\.end) == expected.parts.map(\.end), "\(row.id)")
            let voice = made.hunks(words: words, cutWordIds: Set(row.cutWordIds), cutPauseIds: Set(row.cutPauseIds))
            #expect(voice.map(\.sourceWordIds) == expected.hunks.map(\.sourceWordIds), "\(row.id)")
            #expect(voice.map(\.newTokens) == expected.hunks.map(\.newTokens), "\(row.id)")
            #expect(voice.map(\.absorbedItemIds) == expected.hunks.map(\.absorbedItemIds), "\(row.id)")
            #expect(voice.map(\.sourceStartIndex) == expected.hunks.map(\.sourceStartIndex), "\(row.id)")
            #expect(voice.map(\.sourceEndIndex) == expected.hunks.map(\.sourceEndIndex), "\(row.id)")
            #expect(voice.allSatisfy { $0.kind == .voice }, "\(row.id)")
        }
    }

    @Test func theFitAndItsCopy() throws {
        let rows = try cases().fit
        #expect(rows.count == 20)
        for row in rows {
            let fit = WholeClipRevoice.fit(voiceSeconds: row.voiceSeconds, videoSeconds: row.videoSeconds, words: row.words, round: row.round)
            switch row.expected.kind {
            case "matched":
                let factor: Double = row.expected.factor ?? .nan
                #expect(fit == .matched(factor: factor))
                #expect(WholeClipRevoice.matchedCopy(factor: factor) == row.expected.copy)
            case "laidOut":
                #expect(fit == .laidOut(factor: row.expected.factor ?? .nan), "a shorter voice is laid out, never reworded longer")
            case "reword":
                #expect(fit == .reword(targetWords: row.expected.targetWords ?? -1))
            default:
                #expect(fit == .cannotFit(voiceSeconds: row.voiceSeconds, videoSeconds: row.videoSeconds))
            }
        }
    }

    @Test func pricesComeFromTheTables() throws {
        let catalog = try VoiceLabPriceCatalog(data: FixtureLoader.data("catalog/voice-lab.json"))
        let rows = try cases().price
        #expect(rows.count == 8)
        for row in rows {
            let lipsync = try #require(WholeClipRevoice.Lipsync(rawValue: row.lipsync))
            let price = try WholeClipRevoice.price(characters: row.characters, ttsModel: row.ttsModel, videoSeconds: row.videoSeconds,
                                                   lipsync: lipsync, catalog: catalog)
            #expect(price.voice.usd == money(row.expected.voiceUsd))
            #expect(price.lipsync.usd == money(row.expected.lipsyncUsd))
            #expect(price.usd == money(row.expected.usd))
        }
    }

    private func voiceKey(_ key: VoiceKey) -> WholeClipRevoiceLedger.VoiceKey {
        WholeClipRevoiceLedger.VoiceKey(script: key.script, recordId: key.recordId, model: key.model)
    }
    private func lipsyncKey(_ key: LipsyncKey) throws -> WholeClipRevoiceLedger.LipsyncKey {
        WholeClipRevoiceLedger.LipsyncKey(voice: voiceKey(key.voice), retime: key.retime, model: try #require(WholeClipRevoice.Lipsync(rawValue: key.model)))
    }

    @Test func aPaidStepIsNeverPaidAgain() throws {
        for row in try cases().ledger {
            var ledger = WholeClipRevoiceLedger()
            for step in row.steps {
                if let total = step.total {
                    #expect(ledger.total == money(total), "\(row.id)")
                } else if let key = step.recordVoice {
                    ledger.record(voiceKey(key), usd: try #require(money(step.usd)))
                } else if let key = step.recordLipsync {
                    ledger.record(try lipsyncKey(key), usd: try #require(money(step.usd)))
                } else if let key = step.paidVoice, case .flag(let paid) = step.expected {
                    #expect(ledger.paid(voiceKey(key)) == paid, "\(row.id)")
                } else if let key = step.paidLipsync, case .flag(let paid) = step.expected {
                    #expect(ledger.paid(try lipsyncKey(key)) == paid, "\(row.id)")
                } else if let asked = step.remaining, case .money(let due) = step.expected {
                    let lipsync = try asked.lipsync.map(lipsyncKey)
                    let remaining = ledger.remaining(voice: voiceKey(asked.voice), voiceUSD: try #require(money(asked.voiceUsd)), lipsync: lipsync,
                                                     lipsyncUSD: try #require(money(asked.lipsyncUsd)))
                    #expect(remaining == money(due), "\(row.id)")
                } else {
                    Issue.record("Unknown ledger step in \(row.id)")
                }
            }
        }
    }
}
