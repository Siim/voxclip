import Foundation
import Testing
@testable import VoxClipCore

/// Whole-clip parts tile the clip (voice-lab §8.14 item 3, ADR-R46 2026-11-08): on synthetic clips with cuts beside a part's
/// edge, every part places with no refusal, the parts cover the clip's spoken words exactly once, and the windows validate as
/// the take plan checks them. Before tiling, each of these cases was refused with `seamFadeCrossesCut`.
@Suite(.offlineFixtures) struct WholeClipTilingTests {
    /// A clip in a 48 kHz take. `script` is read left to right: a plain token is a 0.3 s word touching the one before it,
    /// `~um` a cut word, `|0.5` a 0.5 s silence. Three kept words come before the clip and after it, 0.5 s apart from it.
    struct Take {
        var project: Project
        var clip: [TimedWord]
        var cuts: Set<String>
        var envelope: AudioEnvelope
    }

    static func take(_ script: [String], cutPauses: Bool = false) throws -> Take {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        project.voiceLab.segments = []; project.voiceLab.assets = []
        var words: [TimedWord] = [], cuts = Set<String>(), clip: [TimedWord] = []
        var time = 1.0, count = 0
        func say(_ text: String, id: String) -> TimedWord {
            let word = TimedWord(id: id, text: text, start: time, end: time + 0.3)
            time += 0.3
            words.append(word)
            return word
        }
        for (index, text) in ["Before", "the", "clip."].enumerated() { _ = say(text, id: "pre\(index)") }
        time += 0.5
        for token in script {
            if token.hasPrefix("|") { time += Double(token.dropFirst()) ?? 0; continue }
            let cut = token.hasPrefix("~"), id = "w\(count)"
            count += 1
            clip.append(say(cut ? String(token.dropFirst()) : token, id: id))
            if cut { cuts.insert(id) }
        }
        time += 0.5
        for (index, text) in ["After", "the", "clip."].enumerated() { _ = say(text, id: "post\(index)") }
        project.transcript?.words = words
        project.media.source.durationSeconds = time + 1
        project.media.source.audio?.sampleRate = 48_000
        project.edits.cutWordIds = cuts.sorted()
        project.edits.pauseThresholdSeconds = 0.8
        project.edits.cutPauseIds = cutPauses ? try detectPauses(words, thresholdSeconds: 0.8).map(\.id) : []
        project.edits.clips = [ClipRange(id: "clip-main", startWordId: clip[0].id, endWordId: clip[clip.count - 1].id)]
        project.edits.activeClipId = "clip-main"
        // Speech level under every word, room level elsewhere, in 10 ms frames.
        let frames = Int(project.media.source.durationSeconds * 100) + 1
        var levels = [Float](repeating: 0.0005, count: frames)
        for word in words { for frame in Int(word.start * 100)..<min(frames, Int(word.end * 100)) { levels[frame] = 0.1 } }
        return Take(project: project, clip: clip, cuts: cuts, envelope: AudioEnvelope(sampleRate: 48_000, levels: levels))
    }

    /// Twenty words ending in a full stop: 6 s of speech, so two sentences never share a 12 s part.
    static func sentence(_ letter: String) -> [String] { (0..<19).map { "\(letter)\($0)" } + ["\(letter)-end."] }

    /// Places the script's hunks as the take plan does and checks every rule. Returns the hunks and the placed windows.
    @discardableResult
    static func placeAndCheck(_ take: Take, voiceHunks: [VoiceLabDiffHunk] = [], _ name: String) throws -> ([VoiceLabDiffHunk], [VoiceLabWindow]) {
        let comment = Comment(rawValue: name)
        let script = try #require(WholeClipScript.assemble(words: take.clip, cutWordIds: take.cuts, voiceHunks: voiceHunks), comment)
        let hunks = script.hunks(words: take.clip, cutWordIds: take.cuts, cutPauseIds: Set(take.project.edits.cutPauseIds))
        // The spoken indices tile the clip's spoken words, each word in exactly one hunk.
        let spoken = take.clip.filter { $0.kind == .word }.count
        #expect(hunks.first?.sourceStartIndex == 0 && hunks.last?.sourceEndIndex == spoken, comment)
        #expect(zip(hunks, hunks.dropFirst()).allSatisfy { $0.sourceEndIndex == $1.sourceStartIndex && $0.sourceStartIndex < $0.sourceEndIndex }, comment)
        #expect(hunks.first?.sourceWordIds.first == take.clip.first?.id && hunks.last?.sourceWordIds.last == take.clip.last?.id, comment)
        #expect(hunks.flatMap(\.newTokens).joined(separator: " ") == script.text, comment)
        let results = VoiceLabWindowPlanner.placeAll(project: take.project, scope: .clip("clip-main"), envelope: take.envelope, hunks: hunks)
        var windows: [VoiceLabWindow] = []
        for result in results {
            switch result {
            case .placed(_, _, let window): windows.append(window)
            case .refused(let index, _, let reason): Issue.record("\(name): hunk \(index) refused: \(reason)")
            }
        }
        #expect(results.count >= 1, comment)
        // Every word of the clip, kept or cut, lies inside exactly one window, so each is replaced once.
        for word in take.clip {
            #expect(windows.filter { $0.start <= word.start && word.end <= $0.end }.count == 1, "\(name): \(word.id)")
        }
        try VoiceLabRenderContract.validatePlacement(take.project, scope: .clip("clip-main"), windows: windows)
        return (hunks, windows)
    }

    @Test func aFillerCutRightBeforeASentence() throws {
        let take = try Self.take(Self.sentence("a") + ["|0.5", "~um"] + Self.sentence("b") + ["|0.5", "~uh"] + Self.sentence("c"))
        let (hunks, _) = try Self.placeAndCheck(take, "filler before")
        // The fillers go with the sentence after the pause they follow, so both seams sit in that pause.
        #expect(hunks.count == 3)
        #expect(hunks[1].sourceWordIds.first == "w20" && hunks[2].sourceWordIds.first == "w41")
    }

    @Test func aFillerCutRightAfterASentence() throws {
        let take = try Self.take(Self.sentence("a") + ["~um", "|0.5"] + Self.sentence("b") + ["~so", "|0.5"] + Self.sentence("c"))
        let (hunks, _) = try Self.placeAndCheck(take, "filler after")
        #expect(hunks.count == 3)
        #expect(hunks[0].sourceWordIds.last == "w20" && hunks[1].sourceWordIds.last == "w41")
    }

    @Test func cutWordsAtTheClipsStartAndEnd() throws {
        let take = try Self.take(["~um", "~so"] + Self.sentence("a") + ["|0.5"] + Self.sentence("b") + ["|0.5"] + Self.sentence("c") + ["~yeah"])
        let (hunks, _) = try Self.placeAndCheck(take, "clip edges")
        #expect(hunks.first?.sourceWordIds.prefix(2) == ["w0", "w1"] && hunks.last?.sourceWordIds.last == "w62")
    }

    @Test func consecutiveCutWordsAtAPartBoundary() throws {
        let take = try Self.take(Self.sentence("a") + ["~so", "~um", "|0.5", "~like", "~uh"] + Self.sentence("b") + ["|0.5"] + Self.sentence("c"))
        let (hunks, _) = try Self.placeAndCheck(take, "consecutive cuts")
        // The widest gap, the pause, splits the run: two cut words on each side.
        #expect(hunks.count == 3 && hunks[0].sourceWordIds.suffix(2) == ["w20", "w21"] && hunks[1].sourceWordIds.prefix(2) == ["w22", "w23"])
    }

    @Test func aCutRunWithNoSilenceBesideItJoinsTheParts() throws {
        let take = try Self.take(Self.sentence("a") + ["~um", "~uh"] + Self.sentence("b") + ["|0.5"] + Self.sentence("c"))
        let (hunks, _) = try Self.placeAndCheck(take, "touching run")
        // No seam can sit beside the cut words, so the first two sentences are one change.
        #expect(hunks.count == 2 && hunks[0].newTokens.count == 40 && hunks[0].sourceEndIndex == 42)
    }

    @Test func aTightenedPauseBesideAFillerJoinsTheParts() throws {
        // A cut pause keeps its breath only beside kept words; with both neighbouring parts replaced none is left, so no
        // seam can sit there.
        let take = try Self.take(Self.sentence("a") + ["|1.2", "~um"] + Self.sentence("b") + ["~uh", "|1.2"] + Self.sentence("c"), cutPauses: true)
        #expect(take.project.edits.cutPauseIds == ["pause-after-w19", "pause-after-w41"])
        let (hunks, _) = try Self.placeAndCheck(take, "tightened pauses beside fillers")
        #expect(hunks.count == 1)
    }

    @Test func tightenedPausesBetweenSentencesKeepTheirSplit() throws {
        let take = try Self.take(Self.sentence("a") + ["|1.2"] + Self.sentence("b") + ["|1.2"] + Self.sentence("c"), cutPauses: true)
        #expect(take.project.edits.cutPauseIds.count == 2)
        let (hunks, _) = try Self.placeAndCheck(take, "tightened pauses")
        #expect(hunks.count == 3)
    }

    @Test func aPartMadeOnlyOfNewWords() throws {
        let take = try Self.take(Self.sentence("a") + ["|0.5", "~um"] + Self.sentence("b") + ["|0.5"] + Self.sentence("c"))
        let rewrite = VoiceLabDiffHunk(kind: .voice, sourceWordIds: (21...40).map { "w\($0)" },
                                       newTokens: EditingPrimitives.splitWords("Then everything changed for good."), correctedTexts: [],
                                       absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 21, sourceEndIndex: 41, anchorSeconds: nil)
        let (hunks, _) = try Self.placeAndCheck(take, voiceHunks: [rewrite], "new words")
        #expect(hunks.count == 3 && hunks[1].newTokens == ["Then", "everything", "changed", "for", "good."])
        #expect(hunks[1].sourceWordIds.first == "w20")
    }

    /// Rewrite's diff folds a cut filler into the change before it, so a part's own last source word is the cut "um" that
    /// touches the next sentence (the smoke's S-revoice-whole-cuts). The boundary is read from the parts' kept words.
    @Test func aRewriteThatEndsOnACutFillerGivesItToTheNextPart() throws {
        let take = try Self.take(Self.sentence("a") + ["|0.5", "~um"] + Self.sentence("b") + ["|0.5"] + Self.sentence("c"))
        let rewrite = VoiceLabDiffHunk(kind: .voice, sourceWordIds: (0...20).map { "w\($0)" },
                                       newTokens: EditingPrimitives.splitWords("A whole new first sentence."), correctedTexts: [],
                                       absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 0, sourceEndIndex: 21, anchorSeconds: nil)
        let (hunks, _) = try Self.placeAndCheck(take, voiceHunks: [rewrite], "rewrite ending on a cut filler")
        #expect(hunks.count == 3 && hunks[0].sourceWordIds.last == "w19" && hunks[1].sourceWordIds.first == "w20")
        #expect(hunks[0].newTokens == ["A", "whole", "new", "first", "sentence."])
    }

    @Test func partsWithNothingBetweenThemKeepTheirSplit() throws {
        let take = try Self.take(Self.sentence("a") + ["|0.5"] + Self.sentence("b") + ["|0.5"] + Self.sentence("c"))
        let (hunks, windows) = try Self.placeAndCheck(take, "plain")
        #expect(hunks.count == 3 && hunks.map(\.sourceWordIds.count) == [20, 20, 20])
        // Touching windows join, as before: the three parts are said as one take.
        #expect(windows.count == 1)
    }
}
