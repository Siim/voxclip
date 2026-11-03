import Foundation
import Testing
@testable import VoxClipCore

/// Shared changed-duration framing vectors (video-framing-cases.json): every output frame's source time through the
/// output plan's source mapping, including retimed zoom-cover pieces and quiet-boundary cuts. Windows replays the span
/// zoom/anchor rows too; the crop rectangles are replayed by the Media suite.
@Suite struct VoiceLabVideoFramingReplayTests {
    private struct Document: Decodable {
        struct Video: Decodable { let mode: String; let cuts: [[Int64]]? }
        struct Piece: Decodable {
            let kind: String
            let sourceStartSample: Int64
            let sourceEndSample: Int64
            let outputStartSample: Int64
            let outputEndSample: Int64
            let video: Video?
        }
        struct FrameCase: Decodable {
            let id: String
            let fps: Int
            let totalSourceSamples: Int64
            let pieces: [Piece]
            let frames: [[Double]]
        }
        let schema: String
        let sampleRate: Double
        let matchZoom: Double
        let cutPunchIn: Double
        let frameCaseCount: Int
        let frameCases: [FrameCase]
        let cropCaseCount: Int
    }

    @Test func frameSourceTimesMatchTheSharedVectors() throws {
        let fixture = try FixtureLoader.decode(Document.self, at: "fixtures/voice-lab/video-framing-cases.json")
        #expect(fixture.schema == "voxclip-video-framing/1")
        #expect(fixture.frameCaseCount == fixture.frameCases.count && fixture.frameCases.count == 5)
        #expect(fixture.cutPunchIn == VoiceLabNaturalPacing.CUT_PUNCH_IN && fixture.matchZoom == 1.12)
        for row in fixture.frameCases {
            var cuts: [String: [VoiceLabVideoCut]] = [:]
            var pieces: [VoiceLabOutputPiece] = []
            for (index, piece) in row.pieces.enumerated() {
                let id: String? = piece.kind == "synth" ? "segment-\(index)" : nil
                if let id, let spans = piece.video?.cuts {
                    cuts[id] = spans.map { VoiceLabVideoCut(startSample: $0[0], endSample: $0[1]) }
                }
                pieces.append(VoiceLabOutputPiece(kind: piece.kind == "synth" ? .synth : .source,
                    sourceStartSample: piece.sourceStartSample, sourceEndSample: piece.sourceEndSample,
                    outputStartSample: piece.outputStartSample, outputEndSample: piece.outputEndSample,
                    segmentId: id, assetId: nil, audio: nil))
            }
            var plan = VoiceLabOutputPlan(sampleRate: fixture.sampleRate, totalSourceSamples: row.totalSourceSamples,
                pieces: pieces, captions: [], scope: .full)
            plan.videoCuts = cuts
            let fps: Double = Double(row.fps)
            for frame in row.frames {
                let edited: Double = frame[0] / fps
                #expect(plan.sourceTime(edited) == frame[1], "\(row.id) frame \(Int(frame[0]))")
            }
        }
    }
}
