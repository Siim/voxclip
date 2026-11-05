import Foundation
import Testing
@testable import VoxClipCore

/// The music bed's arithmetic (doc/spec/music.md §4) replayed from shared/fixtures/music/music-mix-cases.json, which
/// tools/fixtures/music/generate_music_mix.py writes as a port of this MusicMix and Windows replays (Core MusicMixVectorTests,
/// Media MusicBedTests). Media MusicBedVectorTests replays its whole beds through the Mac renderer.
struct MusicMixVectorTests {
    private static func cases() throws -> [String: JSONValue] {
        try #require(JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/music/music-mix-cases.json")).aiObject)
    }
    private static func doubles(_ value: JSONValue?) -> [Double] { (value?.aiArray ?? []).compactMap(\.aiDouble) }
    private static func optional(_ value: JSONValue?) -> Double? { value?.aiDouble }
    private static func near(_ expected: Double, _ actual: Double?, _ tolerance: Double = 1e-9) -> Bool {
        guard let actual else { return false }
        return abs(expected - actual) < tolerance
    }

    @Test("The file has its keys, its count and the Mac's constants")
    func fileShape() throws {
        let cases = try Self.cases()
        #expect(Set(cases.keys) == ["format", "description", "constants", "levels", "activity", "bedGain", "musicLevel", "fades", "loops", "beds", "caseCount"])
        #expect(cases["format"]?.aiString == "voxclip-music-mix-cases/1")
        #expect(cases["caseCount"]?.aiInt == 35)
        let constants = try #require(cases["constants"]?.aiObject)
        let expected: [String: Double] = [
            "frameSeconds": MusicMix.frameSeconds, "duckDb": MusicMix.duckDb, "attackSeconds": MusicMix.attackSeconds,
            "releaseSeconds": MusicMix.releaseSeconds, "loopCrossfadeSeconds": MusicMix.loopCrossfadeSeconds,
            "fallbackSpeechDb": MusicMix.fallbackSpeechDb, "silenceFloorDb": MusicMix.silenceFloorDb, "maximumBoostDb": MusicMix.maximumBoostDb,
            "minimumBedDb": MusicMix.minimumBedDb, "bridgeGapSeconds": MusicMix.bridgeGapSeconds, "minimumSpeechSeconds": MusicMix.minimumSpeechSeconds,
        ]
        #expect(Set(constants.keys) == Set(expected.keys))
        for (key, value) in expected { #expect(constants[key]?.aiDouble == value, "\(key)") }
    }

    @Test("10 ms levels, speech activity, ducking, bed gain, music level and fades replay")
    func levelsActivityDuckingAndGains() throws {
        let cases = try Self.cases()
        for item in cases["levels"]?.aiArray ?? [] {
            // The samples are float32 on the Mac as on Windows, so the levels agree within 1e-5 dB.
            let levels = MusicMix.frameLevels(Self.doubles(item[ai: "mono"]).map { Float($0) }, sampleRate: try #require(item[ai: "sampleRate"].aiDouble))
            let expected = Self.doubles(item[ai: "levels"])
            #expect(levels.count == expected.count)
            for (index, level) in levels.enumerated() { #expect(Self.near(expected[index], level, 1e-5), "level \(index)") }
        }
        for item in cases["activity"]?.aiArray ?? [] {
            let id = item[ai: "id"].aiString ?? ""
            let levels = Self.doubles(item[ai: "levels"])
            let activity = MusicMix.speechActivity(levels: levels)
            #expect(activity == (item[ai: "activity"].aiArray.compactMap(\.aiBool)), "\(id)")
            let speech = MusicMix.speechLevelDb(levels: levels, activity: activity)
            if let expected = Self.optional(item[ai: "speechDb"]) { #expect(Self.near(expected, speech), "\(id) speech") } else { #expect(speech == nil, "\(id)") }
            let gains = MusicMix.duckingGainsDb(activity: activity)
            let expected = Self.doubles(item[ai: "duckingDb"])
            #expect(gains.count == expected.count, "\(id)")
            for (index, gain) in gains.enumerated() { #expect(Self.near(expected[index], gain), "\(id) ducking \(index)") }
            #expect(MusicMix.duckingGainsDb(activity: activity, ducking: false) == Self.doubles(item[ai: "duckingOff"]), "\(id) off")
            for factor in item[ai: "duckFactors"].aiArray {
                let seconds = try #require(factor[ai: "seconds"].aiDouble)
                #expect(Self.near(try #require(factor[ai: "factor"].aiDouble), MusicMix.duckFactor(gains, at: seconds)), "\(id) factor at \(seconds)")
            }
        }
        for item in cases["bedGain"]?.aiArray ?? [] {
            let gain = MusicMix.bedGainDb(speechDb: Self.optional(item[ai: "speechDb"]), musicDb: Self.optional(item[ai: "musicDb"]),
                                          gainDb: try #require(item[ai: "gainDb"].aiDouble))
            #expect(Self.near(try #require(item[ai: "bedGainDb"].aiDouble), gain), "bed gain \(item)")
        }
        for item in cases["musicLevel"]?.aiArray ?? [] {
            let level = MusicMix.musicLevelDb(levels: Self.doubles(item[ai: "levels"]))
            if let expected = Self.optional(item[ai: "musicDb"]) { #expect(Self.near(expected, level), "music level") } else { #expect(level == nil) }
        }
        for item in cases["fades"]?.aiArray ?? [] {
            let factor = MusicMix.fadeFactor(at: try #require(item[ai: "seconds"].aiDouble), duration: try #require(item[ai: "duration"].aiDouble),
                                             fadeIn: try #require(item[ai: "fadeIn"].aiDouble), fadeOut: try #require(item[ai: "fadeOut"].aiDouble))
            #expect(Self.near(try #require(item[ai: "factor"].aiDouble), factor), "fade \(item)")
        }
    }

    @Test("Trims, loops and their equal-power crossfade weights replay")
    func trimsLoopsAndWeights() throws {
        for item in try Self.cases()["loops"]?.aiArray ?? [] {
            let pieces = MusicMix.loopPieces(trackFrames: try #require(item[ai: "trackFrames"].aiInt), offsetFrames: try #require(item[ai: "offsetFrames"].aiInt),
                                             outputFrames: try #require(item[ai: "outputFrames"].aiInt), crossfadeFrames: try #require(item[ai: "crossfadeFrames"].aiInt))
            let expected = try item[ai: "pieces"].aiArray.map { piece in
                MusicMix.LoopPiece(sourceStart: try #require(piece[ai: "sourceStart"].aiInt), outputStart: try #require(piece[ai: "outputStart"].aiInt),
                                   count: try #require(piece[ai: "count"].aiInt), fadeIn: try #require(piece[ai: "fadeIn"].aiInt),
                                   fadeOut: try #require(piece[ai: "fadeOut"].aiInt))
            }
            #expect(pieces == expected, "\(item[ai: "trackFrames"]) \(item[ai: "offsetFrames"]) \(item[ai: "outputFrames"])")
            let at = item[ai: "weightAt"].aiArray, weights = item[ai: "weights"].aiArray
            #expect(at.count == pieces.count && weights.count == pieces.count)
            for (number, piece) in pieces.enumerated() where number < at.count && number < weights.count {
                let indices = at[number].aiArray.compactMap(\.aiInt), values = Self.doubles(weights[number])
                for (index, frame) in indices.enumerated() {
                    #expect(Self.near(values[index], MusicMix.pieceWeight(piece, at: frame)), "weight \(number)/\(frame)")
                }
            }
        }
    }
}
