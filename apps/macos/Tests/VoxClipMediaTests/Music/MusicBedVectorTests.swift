import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// The whole beds of shared/fixtures/music/music-mix-cases.json replayed through the Mac renderer's own plan and mix
/// (`MusicBedPlan`, which `MusicBedRenderer.stage` writes), as Windows Media MusicBedTests replays them through MusicBed. The
/// generator ports this arithmetic in double precision; the track and the bed are float32 here, so levels from the track agree
/// within 1e-5 dB and samples within 1e-6.
struct MusicBedVectorTests {
    private struct Entry: Decodable {
        let gainDb: Double
        let ducking: Bool
        let fadeInSeconds: Double
        let fadeOutSeconds: Double
        let startOffsetSeconds: Double
    }
    private struct Piece: Decodable {
        let sourceStart: Int, outputStart: Int, count: Int, fadeIn: Int, fadeOut: Int
    }
    private struct Bed: Decodable {
        let id: String
        let sampleRate: Double
        let entry: Entry
        let trackStereo: [Double]
        let speechLevels: [Double]
        let outputFrames: Int
        let pieces: [Piece]
        let musicDb: Double
        let speechDb: Double?
        let bedGainDb: Double
        let frames: [Int]
        let gains: [Double]
        let samples: [[Double]]
    }
    private struct Cases: Decodable { let beds: [Bed] }

    @Test("Each bed's trim or loop, levels, gains and samples replay through the renderer's plan and mix")
    func bedsReplay() throws {
        let beds = try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/music/music-mix-cases.json")).beds
        #expect(beds.map(\.id) == ["trim-ducked-faded", "loop-no-ducking"])
        for bed in beds {
            let entry = ProjectMusic(id: "music-1", clipId: "c", asset: MusicAsset(file: "test.wav", sha256: String(repeating: "a", count: 64), durationSeconds: 1),
                                     source: .file, title: "Test", license: .own, gainDb: bed.entry.gainDb, ducking: bed.entry.ducking,
                                     fadeInSeconds: bed.entry.fadeInSeconds, fadeOutSeconds: bed.entry.fadeOutSeconds,
                                     startOffsetSeconds: bed.entry.startOffsetSeconds)
            let track = bed.trackStereo.map { Float($0) }
            let plan = try #require(MusicBedPlan(track: track, speech: bed.speechLevels, entry: entry, outputFrames: bed.outputFrames, rate: bed.sampleRate))
            #expect(plan.pieces == bed.pieces.map {
                MusicMix.LoopPiece(sourceStart: $0.sourceStart, outputStart: $0.outputStart, count: $0.count, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut)
            }, "\(bed.id) pieces")
            #expect(abs((plan.musicDb ?? .nan) - bed.musicDb) < 1e-5, "\(bed.id) music \(plan.musicDb ?? .nan)")
            if let speech = bed.speechDb { #expect(abs((plan.speechDb ?? .nan) - speech) < 1e-9, "\(bed.id) speech") } else { #expect(plan.speechDb == nil) }
            #expect(abs(plan.bedGainDb - bed.bedGainDb) < 1e-5, "\(bed.id) bed gain \(plan.bedGainDb)")
            let mixed = plan.mix(track, from: 0, count: bed.outputFrames)
            for (index, frame) in bed.frames.enumerated() {
                let gain = plan.gain(atFrame: frame)
                #expect(abs(gain - bed.gains[index]) <= 1e-6 * max(1, abs(bed.gains[index])), "\(bed.id) gain at \(frame): \(gain) vs \(bed.gains[index])")
                for channel in 0..<2 {
                    let sample = Double(mixed[2 * frame + channel])
                    #expect(abs(sample - bed.samples[index][channel]) < 1e-6, "\(bed.id) frame \(frame) channel \(channel): \(sample)")
                }
            }
            // A block from the middle mixes the same samples as the whole, as the renderer writes it in blocks.
            #expect(plan.mix(track, from: 100, count: bed.outputFrames - 100) == Array(mixed[200...]), "\(bed.id) blocks")
        }
    }
}
