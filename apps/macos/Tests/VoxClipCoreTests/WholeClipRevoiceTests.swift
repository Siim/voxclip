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
        let hunks = script.hunks(words: long, cutWordIds: [], cutPauseIds: [])
        #expect(hunks.count == 2 && hunks.allSatisfy { $0.kind == .voice })
        #expect(hunks.flatMap(\.newTokens).joined(separator: " ") == script.text)
        #expect(hunks.flatMap(\.sourceWordIds) == long.map(\.id))
        // A short clip is one part.
        #expect(try #require(WholeClipScript.assemble(words: words, cutWordIds: [], voiceHunks: [])).parts.count == 1)
    }
}

struct WholeClipFitTests {
    @Test func withinEightPercentOfTheClipAsEditedTheVoiceIsMatched() {
        #expect(WholeClipRevoice.fit(voiceSeconds: 30.6, videoSeconds: 31, words: 74, round: 0) == .matched(factor: 30.6 / 31))
        #expect(WholeClipRevoice.fit(voiceSeconds: 108, videoSeconds: 100, words: 74, round: 0) == .matched(factor: 1.08))
        #expect(WholeClipRevoice.fit(voiceSeconds: 92, videoSeconds: 100, words: 74, round: 0) == .matched(factor: 0.92))
        #expect(WholeClipRevoice.matchedCopy(factor: 30.6 / 31) == "video matched (−1.3%)")
        #expect(WholeClipRevoice.matchedCopy(factor: 1.02) == "video matched (+2.0%)")
    }

    @Test func aLongerVoiceAsksForAShorterWordingThenSaysSo() {
        #expect(WholeClipRevoice.fit(voiceSeconds: 108.1, videoSeconds: 100, words: 100, round: 0) == .reword(targetWords: 93))
        #expect(WholeClipRevoice.fit(voiceSeconds: 120, videoSeconds: 100, words: 100, round: WholeClipRevoice.maximumRewordRounds)
                == .cannotFit(voiceSeconds: 120, videoSeconds: 100))
        #expect(WholeClipRevoice.fit(voiceSeconds: 0, videoSeconds: 100, words: 10, round: 0) == .cannotFit(voiceSeconds: 0, videoSeconds: 100))
    }

    /// Never pad: a shorter voice is laid out at any round and never asks for more words.
    @Test func aShorterVoiceIsLaidOutNeverReworded() {
        #expect(WholeClipRevoice.fit(voiceSeconds: 80, videoSeconds: 100, words: 80, round: 1) == .laidOut(factor: 0.8))
        #expect(WholeClipRevoice.fit(voiceSeconds: 91.9, videoSeconds: 100, words: 80, round: 0) == .laidOut(factor: 0.919))
        #expect(WholeClipRevoice.fit(voiceSeconds: 10, videoSeconds: 100, words: 80, round: WholeClipRevoice.maximumRewordRounds) == .laidOut(factor: 0.1))
        #expect(WholeClipRevoice.laidOutCopy(factor: 27 / 31.4) == "laid out on the clip's pauses (−14.0%)")
    }

    /// Check before paying: the measured voice scaled by the estimates' ratio, against the clip plus 8%.
    @Test func aRewordIsVoicedOnlyWhenItsEstimateFits() {
        #expect(!WholeClipRevoice.rewordFits(voiceSeconds: 36, estimateSeconds: 10, newEstimateSeconds: 9.8, videoSeconds: 31))
        #expect(WholeClipRevoice.rewordFits(voiceSeconds: 36, estimateSeconds: 10, newEstimateSeconds: 8.6, videoSeconds: 31))
        #expect(WholeClipRevoice.rewordFits(voiceSeconds: 36, estimateSeconds: 10, newEstimateSeconds: 9.3, videoSeconds: 31), "33.48 s is the edge")
        #expect(!WholeClipRevoice.rewordFits(voiceSeconds: 36, estimateSeconds: 10, newEstimateSeconds: 12, videoSeconds: 31), "it came back longer")
        #expect(!WholeClipRevoice.rewordFits(voiceSeconds: 36, estimateSeconds: 0, newEstimateSeconds: 8, videoSeconds: 31))
        #expect(WholeClipRevoice.predictedSeconds(voiceSeconds: 36, estimateSeconds: 10, newEstimateSeconds: 9.8) == 36 * 9.8 / 10)
    }

    /// The pause bound: a sentence-end pause grows to the project's pause threshold at most, and inside a sentence not at all.
    @Test func thePauseBoundIsTheProjectsPauseThreshold() {
        let profile = WholeClipRevoice.layoutPauseProfile(pauseThresholdSeconds: 0.8)
        #expect(profile.betweenSentences.p25 == VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT)
        #expect(profile.betweenSentences.p75 == 0.8 && profile.betweenSentences.p90 == 0.8)
        #expect(profile.withinSentence.p75 == VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE)
        #expect(WholeClipRevoice.layoutPauseBound(0.1) == VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT)
    }
}

/// The picture under a laid-out voice (ADR-R46 "One timeline"): the clip's own cuts, trimmed or given back, as a cut recipe
/// at zoom 1 that validates, renders and maps the clip's edited length.
struct WholeClipLayoutTests {
    @Test func theClipsOwnCutsAreTrimmedOrGivenBack() {
        let cuts = [VoiceLabVideoCut(startSample: 1000, endSample: 1500), VoiceLabVideoCut(startSample: 3000, endSample: 3200)]
        #expect(WholeClipRevoice.layoutCuts(cuts, startSample: 0, endSample: 5000, removedSamples: 700) == cuts)
        #expect(WholeClipRevoice.layoutCuts(cuts, startSample: 0, endSample: 5000, removedSamples: 1000)
                == cuts + [VoiceLabVideoCut(startSample: 4700, endSample: 5000)], "a shorter voice trims the end")
        #expect(WholeClipRevoice.layoutCuts(cuts, startSample: 0, endSample: 5000, removedSamples: 600)
                == [cuts[0], VoiceLabVideoCut(startSample: 3100, endSample: 3200)], "a longer voice gives the latest cut back first")
        #expect(WholeClipRevoice.layoutCuts(cuts, startSample: 0, endSample: 5000, removedSamples: 5000) == nil)
    }

    @Test func anEditedCutRecipeValidatesAtZoomOneWithManyCuts() {
        let cuts = (0..<6).map { VoiceLabVideoCut(startSample: Int64($0) * 10_000 + 2_000, endSample: Int64($0) * 10_000 + 6_000) }
        var video = VoiceLabVideoRecipe(mode: .cut, sourceStartSample: 0, sourceEndSample: 60_000, outputSamples: 36_000, retimeFactor: nil,
            zoom: VoiceLabNaturalPacing.EDITED_CUT_ZOOM, faceX: 0.5, faceY: 0.5, assetId: nil, provider: nil, model: nil, requestId: nil,
            windowStartSample: nil, windowEndSample: nil, syncMode: nil)
        video.cuts = cuts
        #expect(VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000))
        video.zoom = VoiceLabNaturalPacing.CUT_PUNCH_IN
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000), "a punched-in cut keeps its one or two cuts")
        video.zoom = 1
        video.outputSamples = 36_001
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000))
        video.outputSamples = 40_000
        video.cuts = [VoiceLabVideoCut(startSample: 0, endSample: 20_000)]
        #expect(VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000), "a cut at the window's start, with no edge guard")
        video.cuts = [VoiceLabVideoCut(startSample: 2_000, endSample: 12_000), VoiceLabVideoCut(startSample: 8_000, endSample: 18_000)]
        video.outputSamples = 40_000
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000), "overlapping cuts")
    }

    /// A take of three sentences, 4.8 s said, fitted to an 8 s window whose clip as edited is 7 s: its two sentence pauses
    /// grow to the bound, it ends on the clip's last pause (0.8 s at most), and the picture holds the clip's cut plus the trim.
    @Test func aShortTakeIsLaidOutOnTheClipAsEdited() throws {
        let rate = 48_000, assetRate = 24_000
        let take = Self.take(sentences: [1.6, 1.4, 1.2], pause: 0.3, assetRate: assetRate)
        let window = try Self.window(start: 10, end: 18, rate: Double(rate))
        let edited = [VoiceLabVideoCut(startSample: 13 * 48_000, endSample: 14 * 48_000)]
        let result = try VoiceLabNaturalPacing.layout(window: window, incomingSilence: 0.4, outgoingSilence: 0.4, take: take,
            sourceSampleRate: rate, hardJoinSmoothing: true, pauseProfile: WholeClipRevoice.layoutPauseProfile(pauseThresholdSeconds: 0.8),
            audioTags: [], editedCuts: edited, tailSeconds: 0.8)
        let plan = result.plan
        #expect(plan.editedTimeline)
        // Both sentence pauses grew to the bound (the measured 0.28 s pause to 0.8 s), and nothing else was inserted.
        let inserted = plan.edits.filter { $0.kind == .insert }.map { Double($0.count) / Double(assetRate) }
        #expect(inserted.count == 2 && inserted.allSatisfy { $0 > 0.45 && $0 <= 0.55 }, "\(plan.edits)")
        #expect(plan.outgoing.padFrames >= Int64(0.75 * Double(assetRate)) && plan.outgoing.padFrames <= Int64(0.85 * Double(assetRate)),
                "it ends on the clip's own last pause: \(plan.outgoing.padFrames)")
        let options = VoiceLabVideoDurationOptions(fit: result, sourceSampleRate: rate, assetSampleRate: assetRate)
        #expect(options.allows(.cut) && !options.allows(.source))
        #expect(plan.videoCuts.first == edited[0] && plan.videoCuts.count == 2, "the clip's cut, then the trim: \(plan.videoCuts)")
        #expect(plan.videoCuts.last?.endSample == plan.windowEndSample, "the trim is the picture's end")
        let output = Double(options.outputSamples ?? 0) / Double(rate)
        #expect(abs(output - Double(plan.outputFrames) / Double(assetRate)) < 0.001, "the picture is as long as the voice")
        #expect(output < 7, "shorter than the clip as edited: it ends on the clip's last pause")
    }

    /// A take as long as the clip as edited fills it exactly: the picture is the clip's own cut.
    @Test func aTakeOfTheEditedLengthKeepsTheClipsCuts() throws {
        let rate = 48_000, assetRate = 24_000
        let take = Self.take(sentences: [2.4, 2.0, 1.8], pause: 0.35, assetRate: assetRate)
        let window = try Self.window(start: 10, end: 18, rate: Double(rate))
        let natural = Double(take.assetFrames) / Double(assetRate)
        let edited = [VoiceLabVideoCut(startSample: 13 * 48_000, endSample: 13 * 48_000 + Int64((8 - natural - 0.1) * 48_000))]
        let result = try VoiceLabNaturalPacing.layout(window: window, incomingSilence: 0.4, outgoingSilence: 0.4, take: take,
            sourceSampleRate: rate, hardJoinSmoothing: true, pauseProfile: WholeClipRevoice.layoutPauseProfile(pauseThresholdSeconds: 0.8),
            audioTags: [], editedCuts: edited, tailSeconds: 0.8)
        let options = VoiceLabVideoDurationOptions(fit: result, sourceSampleRate: rate, assetSampleRate: assetRate)
        #expect(options.allows(.cut), "\(result)")
        #expect(result.plan.videoCuts == edited, "\(result.plan.videoCuts)")
    }

    /// The take: silence, then each sentence's voiced span with `pause` of silence between, then silence; one aligned word a
    /// sentence, each ending its sentence.
    static func take(sentences: [Double], pause: Double, assetRate: Int) -> VoiceLabFitTake {
        let lead = 0.05
        // Every time on the asset's frame grid, so a word's frame span is exactly its aligned span.
        func frame(_ seconds: Double) -> Double { (seconds * Double(assetRate)).rounded() / Double(assetRate) }
        var words: [VoiceLabWord] = []
        var time = lead
        for (index, seconds) in sentences.enumerated() {
            words.append(VoiceLabWord(text: "said\(index).", start: frame(time), end: frame(time + seconds), synthetic: true))
            time = frame(time + seconds + (index == sentences.count - 1 ? 0 : pause))
        }
        let total = time + lead
        let frames = Int64((total * Double(assetRate)).rounded())
        let size = Int(VoiceLabGeometry.frameSize(Double(assetRate)))
        let levels: [Float] = (0..<(Int(frames) / size)).map { block in
            let t = Double(block * size) / Double(assetRate)
            return words.contains { t >= $0.start - 0.01 && t <= $0.end + 0.01 } ? 0.3 : 0
        }
        return VoiceLabFitTake(assetFrames: frames, assetSampleRate: assetRate, trimStart: lead, trimEnd: time,
                               words: words, envelope: AudioEnvelope(sampleRate: Double(assetRate), frameSeconds: 0.01, levels: levels))
    }

    static func window(start: Double, end: Double, rate: Double) throws -> VoiceLabWindow {
        let a = Int64(start * rate), b = Int64(end * rate)
        return VoiceLabWindow(firstWordId: "w0", lastWordId: "w2", leftBridgeWordIds: [], rightBridgeWordIds: [], start: start, end: end,
                              startSample: a, endSample: b, leftSeam: .init(kind: .gap, time: start, sample: a, fadeSamples: 960),
                              rightSeam: .init(kind: .gap, time: end, sample: b, fadeSamples: 960))
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

    /// Removing the revoiced clip or one of its segments, or replacing the transcript, drops the record in the same step,
    /// so the project still validates, saves and plans its render; an unrelated edit keeps it.
    @Test func removingTheClipOrASegmentDropsTheRecordAndTheProjectStillSaves() throws {
        var base = try fixture()
        base.voiceLab.wholeClipRevoices = [record()]
        let otherClip = ClipRange(id: "clip-other", startWordId: try #require(base.transcript?.words.first?.id),
                                  endWordId: try #require(base.transcript?.words.first?.id))
        base.edits.clips.append(otherClip)
        try VoiceLabProject.validate(base)

        // Removing another clip keeps the record.
        var unrelated = base
        try unrelated.applyEditing(.removeClip(id: "clip-other"))
        #expect(unrelated.voiceLab.wholeClipRevoices == [record()])

        // Removing the revoiced clip drops it; the segments stay as voiced patches.
        var removed = base
        try removed.applyEditing(.removeClip(id: "clip-main"))
        #expect(removed.voiceLab.wholeClipRevoices == nil)
        #expect(removed.voiceLab.segments.map(\.id) == base.voiceLab.segments.map(\.id))
        try VoiceLabProject.validate(removed)
        _ = try JSONProjectStore.encode(removed)

        // Deleting one of its segments drops it too.
        let deleted = try VoiceLabProject.delete(id: "vl-thanks", in: base)
        #expect(deleted.voiceLab.wholeClipRevoices == nil)
        _ = try JSONProjectStore.encode(deleted)

        // New source words drop every record with the segments.
        var replaced = base
        replaced.replaceTranscript(try #require(base.transcript))
        #expect(replaced.voiceLab.wholeClipRevoices == nil)
        _ = try JSONProjectStore.encode(replaced)

        // Saving cleans a dangling record as it cleans other stale references…
        var dangling = base
        dangling.edits.clips.removeAll { $0.id == "clip-main" }
        let cleaned = try JSONProjectStore.decode(try JSONProjectStore.encode(dangling))
        #expect(cleaned.voiceLab.wholeClipRevoices == nil)
        // …but a file that arrives with one is still refused.
        #expect((try? VoiceLabProject.validate(dangling)) == nil)
        var object = try #require(JSONSerialization.jsonObject(with: try JSONProjectStore.encode(base)) as? [String: Any])
        var edits = try #require(object["edits"] as? [String: Any])
        edits["clips"] = (edits["clips"] as? [[String: Any]])?.filter { $0["id"] as? String != "clip-main" }
        edits["activeClipId"] = nil
        object["edits"] = edits
        #expect((try? JSONProjectStore.decode(try JSONSerialization.data(withJSONObject: object))) == nil)
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
