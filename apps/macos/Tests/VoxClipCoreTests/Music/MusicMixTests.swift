import Foundation
import Testing
@testable import VoxClipCore

struct MusicMixTests {
    private func activity(_ pattern: [(Bool, Int)]) -> [Bool] { pattern.flatMap { Array(repeating: $0.0, count: $0.1) } }

    @Test func duckingReachesMinusTwelveByEachOnsetAndReleasesOver400Milliseconds() {
        // 1 s silence, 1 s speech, 2 s silence, at 10 ms frames.
        let gains = MusicMix.duckingGainsDb(activity: activity([(false, 100), (true, 100), (false, 200)]))
        #expect(gains.count == 400)
        #expect(gains[0] == 0 && gains[84] == 0)
        // Attack: 150 ms, linear in dB, finished at the onset.
        #expect(abs(gains[85] - 0) < 1e-12)
        #expect(abs(gains[92] - (-12.0 * 7 / 15)) < 1e-9)
        #expect(gains[100] == -12 && gains[150] == -12 && gains[199] == -12)
        // Release: 400 ms back to unity.
        #expect(abs(gains[210] - (-12.0 * 29 / 40)) < 1e-9)
        #expect(gains[240] == 0 && gains[399] == 0)
        #expect(gains.allSatisfy { $0 <= 0 && $0 >= -12 })
    }

    @Test func noDuckingWhenOffOrSilent() {
        #expect(MusicMix.duckingGainsDb(activity: activity([(true, 50)]), ducking: false) == Array(repeating: 0, count: 50))
        #expect(MusicMix.duckingGainsDb(activity: activity([(false, 50)])) == Array(repeating: 0, count: 50))
    }

    @Test func duckFactorInterpolatesBetweenFrames() {
        let gains = [0.0, -12, -12]
        #expect(abs(MusicMix.duckFactor(gains, at: 0.005) - 1) < 1e-12)
        #expect(abs(MusicMix.duckFactor(gains, at: 0.01) - pow(10, -6.0 / 20)) < 1e-12)
        #expect(abs(MusicMix.duckFactor(gains, at: 0.5) - pow(10, -12.0 / 20)) < 1e-12)
    }

    @Test func speechActivityBridgesShortPausesAndDropsBlips() {
        let speech = -20.0, room = -60.0
        var levels = Array(repeating: room, count: 300)
        for index in 50..<120 { levels[index] = speech }   // a word run
        for index in 135..<200 { levels[index] = speech }  // 150 ms pause bridged
        for index in 260..<263 { levels[index] = speech }  // 30 ms click dropped
        let active = MusicMix.speechActivity(levels: levels)
        #expect(!active[49] && active[50] && active[125] && active[199] && !active[200])
        #expect(!active[261])
        #expect(abs((MusicMix.speechLevelDb(levels: levels, activity: active) ?? 0) - (-20)) < 2)
    }

    @Test func frameLevelsMeasureRMS() {
        let rate = 48_000.0
        let tone = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 400 * Double($0) / rate)) }
        let levels = MusicMix.frameLevels(tone, sampleRate: rate)
        #expect(levels.count == 100)
        // A 0.5-amplitude sine is RMS 0.3536, −9.03 dBFS.
        #expect(levels.allSatisfy { abs($0 - (-9.0309)) < 0.05 })
        #expect(MusicMix.frameLevels(Array(repeating: 0, count: 480), sampleRate: rate) == [MusicMix.silenceFloorDb])
    }

    @Test func bedGainPutsMusicTwentyDecibelsUnderSpeech() {
        #expect(MusicMix.bedGainDb(speechDb: -18, musicDb: -12, gainDb: -20) == -26)
        #expect(MusicMix.bedGainDb(speechDb: nil, musicDb: -14, gainDb: -20) == -26)
        #expect(MusicMix.bedGainDb(speechDb: -18, musicDb: -80, gainDb: 0) == MusicMix.maximumBoostDb)
        #expect(MusicMix.bedGainDb(speechDb: -18, musicDb: nil, gainDb: -20) == -20)
    }

    @Test func fadesStartAndEndInSilence() {
        #expect(MusicMix.fadeFactor(at: 0, duration: 10, fadeIn: 0.5, fadeOut: 1.5) == 0)
        #expect(MusicMix.fadeFactor(at: 0.25, duration: 10, fadeIn: 0.5, fadeOut: 1.5) == 0.5)
        #expect(MusicMix.fadeFactor(at: 5, duration: 10, fadeIn: 0.5, fadeOut: 1.5) == 1)
        #expect(abs(MusicMix.fadeFactor(at: 9.25, duration: 10, fadeIn: 0.5, fadeOut: 1.5) - 0.5) < 1e-12)
        #expect(MusicMix.fadeFactor(at: 10, duration: 10, fadeIn: 0.5, fadeOut: 1.5) == 0)
        #expect(MusicMix.fadeFactor(at: 0, duration: 10, fadeIn: 0, fadeOut: 0) == 1)
    }

    @Test func longTracksAreTrimmedFromTheOffset() {
        #expect(MusicMix.loopPieces(trackFrames: 1_000, offsetFrames: 200, outputFrames: 500, crossfadeFrames: 100)
                == [.init(sourceStart: 200, outputStart: 0, count: 500)])
    }

    @Test func shortTracksLoopWithEqualPowerCrossfades() {
        let pieces = MusicMix.loopPieces(trackFrames: 400, offsetFrames: 100, outputFrames: 1_000, crossfadeFrames: 200)
        // A quarter of the track caps the crossfade at 100 frames.
        #expect(pieces == [.init(sourceStart: 100, outputStart: 0, count: 300, fadeOut: 100),
                           .init(sourceStart: 0, outputStart: 200, count: 400, fadeIn: 100, fadeOut: 100),
                           .init(sourceStart: 0, outputStart: 500, count: 400, fadeIn: 100, fadeOut: 100),
                           .init(sourceStart: 0, outputStart: 800, count: 200, fadeIn: 100)])
        // Overlapping weights keep constant power.
        for offset in 0..<100 {
            let outgoing = MusicMix.pieceWeight(pieces[0], at: 200 + offset)
            let incoming = MusicMix.pieceWeight(pieces[1], at: offset)
            #expect(abs(outgoing * outgoing + incoming * incoming - 1) < 1e-12)
        }
        #expect(pieces.last.map { $0.outputStart + $0.count } == 1_000)
        #expect(MusicMix.loopPieces(trackFrames: 3, offsetFrames: 0, outputFrames: 10, crossfadeFrames: 1).isEmpty)
        #expect(MusicMix.loopPieces(trackFrames: 100, offsetFrames: 100, outputFrames: 10, crossfadeFrames: 1).isEmpty)
    }

    @Test func elevenMusicIsFifteenCentsAMinuteAndBounded() throws {
        let catalog = try VoiceLabPriceCatalog(data: FixtureLoader.data("catalog/voice-lab.json"))
        let minute = try MusicPricing.estimate(seconds: 60, catalog: catalog)
        #expect(minute.usd == Decimal(string: "0.15") && minute.basis == "list-2026-11-04" && minute.operation == "musicCompose")
        let clip = try MusicPricing.estimate(seconds: MusicPricing.lengthSeconds(forClip: 41.2), catalog: catalog)
        #expect(clip.units == 42 && MusicPricing.label(clip) == "$0.11")
        #expect(MusicPricing.lengthSeconds(forClip: 1) == 3 && MusicPricing.lengthSeconds(forClip: 900) == 300)
        #expect(MusicPricing.lengthSeconds(forClip: .nan) == 3)
        #expect(MusicPricing.label(try MusicPricing.estimate(seconds: 300, catalog: catalog)) == "$0.75")
    }

    @Test func briefsBuildSearchWordsPromptAndKeywords() {
        let brief = MusicBrief(mood: "Calm piano", reason: "Reflective talk")
        #expect(brief.searchText == "Calm piano")
        #expect(brief.compositionPrompt.hasPrefix("Instrumental background music, Calm piano mood"))
        #expect(brief.keywords == ["calm", "piano"])
        #expect(MusicBrief(mood: "x", query: " lofi beat ", prompt: "Lo-fi").searchText == "lofi beat")
        #expect(MusicBrief(mood: "x", prompt: "Lo-fi").compositionPrompt == "Lo-fi")
    }
}
