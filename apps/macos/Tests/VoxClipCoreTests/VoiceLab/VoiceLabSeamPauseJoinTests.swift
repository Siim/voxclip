import Foundation
import Testing
@testable import VoxClipCore

/// Live 2026-11-03 14:53–14:58 (casual vlog, Multilingual v2): two phrases failed "loudness check at the join" with no
/// audible jump. The pauses beside their joins held an inhale or a word's decay below `VOICED_FRAME`, and a take shorter
/// than its window ended in a pause where the source spoke on. These are the 10 ms RMS envelopes (dBFS) of the mixed audio
/// and the unedited source over 0.5 s on each side of the six seams, rebuilt as frame-normalised noise; no user audio.
@Suite("Seam pause joins (live casual takes)")
struct VoiceLabSeamPauseJoinTests {
    static let rate = 24_000, frame = 240, seam = 12_000
    static let envelopes: [String: [String]] = [
        "p1InMixed": [
            "-56 -52 -52 -48 -49 -46 -49 -49 -45 -47 -46 -45 -47 -46 -46 -47 -48 -46 -46 -46 -44 -45 -45 -43 -48",
            "-43 -47 -44 -46 -44 -44 -44 -44 -45 -47 -47 -48 -47 -49 -48 -49 -51 -53 -55 -57 -57 -60 -61 -61 -60",
            "-56 -53 -55 -57 -53 -54 -56 -54 -50 -54 -54 -49 -52 -51 -51 -56 -53 -54 -57 -54 -54 -53 -50 -53 -54",
            "-55 -52 -55 -55 -51 -56 -59 -55 -58 -59 -59 -59 -55 -56 -42 -28 -26 -31 -24 -23 -22 -22 -21 -22 -24"
        ],
        "p1InSource": [
            "-56 -52 -52 -48 -49 -46 -49 -49 -45 -47 -46 -45 -47 -46 -46 -47 -48 -46 -46 -46 -44 -45 -45 -43 -48",
            "-43 -47 -44 -46 -44 -44 -44 -44 -45 -47 -47 -48 -47 -49 -48 -49 -51 -53 -55 -57 -57 -60 -61 -61 -65",
            "-62 -52 -61 -63 -59 -46 -34 -40 -50 -43 -29 -31 -27 -26 -25 -25 -25 -25 -25 -25 -25 -25 -25 -25 -26",
            "-24 -25 -24 -25 -25 -25 -25 -25 -25 -25 -26 -26 -26 -26 -26 -25 -26 -26 -26 -26 -26 -25 -26 -26 -27"
        ],
        "p1OutMixed": [
            "-22 -22 -22 -23 -23 -23 -24 -25 -28 -25 -40 -27 -26 -36 -48 -42 -38 -31 -20 -23 -55 -52 -54 -53 -50",
            "-52 -51 -53 -52 -54 -53 -56 -55 -55 -53 -52 -51 -53 -55 -53 -53 -55 -52 -53 -57 -55 -58 -59 -57 -60",
            "-64 -60 -56 -55 -52 -53 -51 -48 -49 -50 -50 -48 -48 -49 -47 -48 -49 -50 -50 -49 -50 -45 -46 -49 -50",
            "-48 -50 -49 -47 -50 -50 -48 -50 -51 -53 -54 -49 -50 -52 -55 -60 -59 -61 -68 -61 -61 -62 -62 -45 -26"
        ],
        "p1OutSource": [
            "-20 -20 -21 -21 -21 -22 -23 -23 -25 -24 -25 -25 -25 -25 -25 -25 -31 -25 -38 -30 -39 -33 -37 -29 -33",
            "-28 -28 -28 -28 -29 -28 -28 -26 -26 -26 -26 -26 -26 -26 -25 -25 -26 -27 -29 -28 -30 -36 -42 -53 -63",
            "-66 -60 -56 -55 -52 -53 -51 -48 -49 -50 -50 -48 -48 -49 -47 -48 -49 -50 -50 -49 -50 -45 -46 -49 -50",
            "-48 -50 -49 -47 -50 -50 -48 -50 -51 -53 -54 -49 -50 -52 -55 -60 -59 -61 -68 -61 -61 -62 -62 -45 -26"
        ],
        "p2InMixed": [
            "-68 -64 -66 -64 -48 -54 -60 -62 -62 -61 -58 -61 -61 -59 -57 -57 -58 -58 -61 -59 -60 -58 -58 -59 -60",
            "-60 -58 -59 -56 -57 -57 -60 -61 -60 -61 -60 -60 -48 -59 -61 -63 -63 -60 -64 -59 -57 -63 -66 -67 -64",
            "-59 -56 -59 -60 -56 -57 -59 -58 -54 -57 -57 -53 -56 -54 -54 -59 -57 -58 -60 -57 -58 -57 -54 -56 -58",
            "-58 -55 -58 -58 -55 -58 -62 -58 -61 -60 -49 -45 -41 -21 -17 -18 -20 -18 -16 -16 -16 -16 -16 -17 -17"
        ],
        "p2InSource": [
            "-68 -64 -66 -64 -48 -54 -60 -62 -62 -61 -58 -61 -61 -59 -57 -57 -58 -58 -61 -59 -60 -58 -58 -59 -60",
            "-60 -58 -59 -56 -57 -57 -60 -61 -60 -61 -60 -60 -48 -59 -61 -63 -63 -60 -64 -59 -57 -63 -66 -67 -70",
            "-65 -46 -29 -30 -25 -21 -21 -20 -19 -17 -16 -13 -15 -16 -17 -17 -16 -17 -17 -18 -19 -19 -19 -20 -21",
            "-21 -21 -22 -22 -22 -23 -21 -25 -27 -29 -28 -32 -32 -31 -31 -30 -38 -49 -56 -60 -64 -67 -67 -36 -31"
        ],
        "p2OutMixed": [
            "-54 -53 -52 -52 -52 -53 -54 -50 -53 -52 -50 -53 -52 -52 -52 -52 -53 -54 -53 -55 -58 -58 -59 -60 -62",
            "-59 -61 -57 -59 -60 -56 -57 -59 -58 -54 -57 -57 -53 -56 -54 -54 -59 -57 -58 -60 -57 -58 -57 -54 -57",
            "-63 -62 -63 -57 -48 -38 -41 -34 -37 -44 -29 -30 -24 -24 -26 -26 -25 -24 -23 -22 -22 -23 -22 -22 -21",
            "-19 -21 -20 -20 -21 -20 -21 -20 -20 -20 -20 -20 -21 -20 -21 -24 -25 -25 -24 -24 -25 -25 -25 -24 -23"
        ],
        "p2OutSource": [
            "-18 -18 -18 -18 -17 -18 -17 -17 -18 -17 -18 -17 -16 -16 -15 -16 -18 -18 -17 -18 -19 -21 -23 -25 -27",
            "-29 -32 -36 -38 -42 -53 -51 -52 -53 -54 -54 -58 -58 -61 -62 -60 -65 -62 -61 -63 -64 -64 -61 -64 -66",
            "-68 -62 -63 -57 -48 -38 -41 -34 -37 -44 -29 -30 -24 -24 -26 -26 -25 -24 -23 -22 -22 -23 -22 -22 -21",
            "-19 -21 -20 -20 -21 -20 -21 -20 -20 -20 -20 -20 -21 -20 -21 -24 -25 -25 -24 -24 -25 -25 -25 -24 -23"
        ],
        "p3InMixed": [
            "-22 -21 -19 -21 -20 -20 -21 -20 -21 -20 -20 -20 -20 -20 -21 -20 -21 -24 -25 -25 -24 -24 -25 -25 -25",
            "-24 -23 -23 -23 -24 -24 -24 -25 -26 -28 -29 -30 -31 -32 -33 -35 -37 -40 -36 -37 -46 -47 -54 -63 -61",
            "-31 -26 -26 -26 -26 -26 -23 -23 -23 -23 -24 -23 -23 -24 -29 -26 -26 -25 -25 -25 -25 -25 -26 -26 -27",
            "-29 -31 -32 -36 -42 -54 -53 -53 -55 -55 -56 -57 -53 -52 -55 -54 -56 -55 -56 -55 -56 -52 -52 -55 -52"
        ],
        "p3InSource": [
            "-22 -21 -19 -21 -20 -20 -21 -20 -21 -20 -20 -20 -20 -20 -21 -20 -21 -24 -25 -25 -24 -24 -25 -25 -25",
            "-24 -23 -23 -23 -24 -24 -24 -25 -26 -28 -29 -30 -31 -32 -33 -35 -37 -40 -36 -37 -46 -47 -54 -63 -66",
            "-62 -61 -56 -53 -50 -49 -50 -50 -49 -48 -48 -50 -50 -52 -49 -48 -47 -47 -49 -49 -48 -49 -51 -50 -53",
            "-52 -49 -49 -47 -46 -46 -45 -47 -45 -48 -48 -49 -50 -51 -47 -49 -49 -52 -55 -51 -50 -51 -58 -57 -59"
        ],
        "p3OutMixed": [
            "-58 -50 -57 -53 -56 -55 -35 -35 -39 -19 -16 -14 -14 -16 -16 -16 -17 -20 -20 -20 -20 -20 -20 -20 -20",
            "-20 -21 -22 -23 -25 -26 -26 -27 -27 -29 -31 -33 -35 -38 -40 -45 -50 -53 -52 -56 -57 -54 -56 -52 -54",
            "-54 -52 -52 -49 -48 -48 -49 -46 -49 -49 -52 -51 -48 -49 -48 -50 -48 -51 -51 -48 -54 -50 -50 -51 -52",
            "-55 -57 -61 -59 -60 -62 -59 -61 -63 -63 -63 -59 -60 -60 -58 -58 -59 -39 -29 -23 -22 -22 -22 -24 -31"
        ],
        "p3OutSource": [
            "-35 -29 -26 -27 -32 -46 -54 -60 -64 -64 -31 -28 -32 -23 -17 -17 -15 -16 -15 -16 -17 -17 -16 -17 -18",
            "-19 -19 -19 -20 -20 -21 -22 -25 -30 -34 -35 -37 -39 -47 -49 -55 -58 -59 -62 -63 -61 -60 -56 -54 -54",
            "-54 -52 -52 -49 -48 -48 -49 -46 -49 -49 -52 -51 -48 -49 -48 -50 -48 -51 -51 -48 -54 -50 -50 -51 -52",
            "-55 -57 -61 -59 -60 -62 -59 -61 -63 -63 -63 -59 -60 -60 -58 -58 -59 -39 -29 -23 -22 -22 -22 -24 -31"
        ]
    ]
    /// Deterministic white noise whose every 10 ms frame has exactly the envelope's RMS.
    static func audio(_ name: String, shift: (Int) -> Double = { _ in 0 }) throws -> [Float] {
        let levels = try #require(envelopes[name]).flatMap { $0.split(separator: " ").compactMap { Double($0) } }
        try #require(levels.count == 100)
        var state: UInt32 = 0x2545_F491
        var samples: [Float] = []
        for (index, level) in levels.enumerated() {
            var noise: [Double] = []
            for _ in 0..<frame {
                state = state &* 1_664_525 &+ 1_013_904_223
                noise.append(Double(state >> 8) / Double(1 << 24) - 0.5)
            }
            let rms = (noise.reduce(0) { $0 + $1 * $1 } / Double(frame)).squareRoot()
            let target: Double = pow(10, (level + shift(index)) / 20)
            samples += noise.map { Float($0 / rms * target) }
        }
        return samples
    }
    /// (plain value of the 400 ms windows, value with pause joins) for one seam.
    static func values(_ name: String, generatedAfter: Bool, mixedShift: (Int) -> Double = { _ in 0 }) throws -> (plain: Double, joined: Double) {
        let mixed = try audio(name + "Mixed", shift: mixedShift), source = try audio(name + "Source")
        let steps = try VoiceLabLoudness.seamStepsLu(mixed, sampleRate: rate, seamSamples: [seam])
        let sourceSteps = try VoiceLabLoudness.seamStepsLu(source, sampleRate: rate, seamSamples: [seam])
        let levels = try VoiceLabLoudness.generatedPauseLufs(mixed, sampleRate: rate, seamSamples: [seam], generatedAfter: [generatedAfter])
        let ranges = try VoiceLabLoudness.sourcePauseRangesLufs(source, sampleRate: rate, seamSamples: [seam], generatedAfter: [generatedAfter])
        let plain = try VoiceLabLoudness.seamExcessLu(mixedSteps: steps, sourceSteps: sourceSteps)
        let joined = try VoiceLabLoudness.seamExcessLu(mixedSteps: steps, sourceSteps: sourceSteps, generatedPauseLevels: levels,
                                                       sourcePauseRanges: ranges)
        return (plain, joined)
    }

    /// Phrase 2's outgoing join (31.6 LU live): the take ends 0.4 s before the join in room tone, and the source says
    /// "and" 50 ms after it. The 400 ms windows read where speech falls; the take's pause sits within the pause the source
    /// had there, so the join passes.
    @Test func aShorterTakeEndingInAPauseBeforeSourceSpeechPasses() throws {
        let value = try Self.values("p2Out", generatedAfter: false)
        #expect(value.plain > 20, "\(value)")
        #expect(value.joined <= 2, "\(value)")
    }
    /// Phrase 1's incoming join (7.97 LU plain, 4.97 LU by the pooled pause rule live): the source's pause before the
    /// join is an inhale decaying to the floor, and room tone after it sits within that pause's own levels. Phrase 1's
    /// outgoing join (4.91 LU live) meets an inhale that rises from the source's floor; phrase 2's incoming one (3.00 LU
    /// live) counted the take's speech onset. All pass; phrase 3, which passed live, still passes.
    @Test(arguments: [("p1In", true), ("p1Out", false), ("p2In", true), ("p3In", true), ("p3Out", false)])
    func liveJoinsThatSoundFinePass(name: String, generatedAfter: Bool) throws {
        let value = try Self.values(name, generatedAfter: generatedAfter)
        #expect(value.joined <= 2, "\(name) \(value)")
    }
    /// The rule keeps its intent: room tone louder or quieter than every part of the pause it meets, or room tone that
    /// stops where the source has background, is still a jump at the same joins.
    @Test func roomToneThatDiffersFromThePauseItMeetsStillFails() throws {
        // Phrase 2's outgoing join: the generated side is the half before the seam (frames 0 to 49).
        let louder = try Self.values("p2Out", generatedAfter: false) { $0 < 50 && $0 >= 10 ? 8 : 0 }
        #expect(louder.joined > 2, "\(louder)")
        let dropout = try Self.values("p1Out", generatedAfter: false) { $0 < 50 && $0 >= 20 ? -40 : 0 }
        #expect(dropout.joined > 2, "\(dropout)")
        // Phrase 2's incoming join with room tone 10 dB quieter, or none, before the take's first word (frame 85 on).
        let quieter = try Self.values("p2In", generatedAfter: true) { $0 >= 50 && $0 < 84 ? -10 : 0 }
        #expect(quieter.joined > 2, "\(quieter)")
        let missing = try Self.values("p2In", generatedAfter: true) { $0 >= 50 && $0 < 84 ? -40 : 0 }
        #expect(missing.joined > 2, "\(missing)")
    }
}
