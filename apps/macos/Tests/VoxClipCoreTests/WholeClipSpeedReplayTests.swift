import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/voice-lab/whole-clip-speed-cases.json (ADR-R46 "Your own pace"; the C# twin
/// WholeClipSpeedReplayTests replays the same file): the picture's speed-up, the Fit line, the record's range, the sped
/// edited cut and its even mapping.
@Suite(.offlineFixtures) struct WholeClipSpeedReplayTests {
    private struct Constants: Decodable { let maximumPictureSpeed: Double; let fitTolerance: Double; let sampleRate: Double }
    private struct SpeedCase: Decodable { let voiceSeconds: Double; let videoSeconds: Double; let speed: Double }
    private struct CopyCase: Decodable { let speed: Double; let laidOut: Bool; let copy: String }
    private struct RetimeCase: Decodable { let value: Double; let valid: Bool }
    private struct CutCase: Decodable {
        let id: String; let sourceStartSample: Int64; let sourceEndSample: Int64; let outputSamples: Int64
        let retimeFactor: Double?; let zoom: Double; let cuts: [[Int64]]; let valid: Bool
    }
    private struct Piece: Decodable { let sourceStartSample: Int64; let sourceEndSample: Int64; let outputStartSample: Int64; let outputEndSample: Int64 }
    private struct Forward: Decodable { let source: Double; let output: Double }
    private struct Backward: Decodable { let edited: Double; let source: Double }
    private struct MappingCase: Decodable { let id: String; let piece: Piece; let cuts: [[Int64]]; let mapTime: [Forward]; let sourceTime: [Backward] }
    private struct Cases: Decodable {
        let format: String; let constants: Constants; let pictureSpeed: [SpeedCase]; let spedCopy: [CopyCase]
        let validRetime: [RetimeCase]; let spedCuts: [CutCase]; let mapping: [MappingCase]
    }

    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/voice-lab/whole-clip-speed-cases.json"))
    }

    @Test func formatAndConstants() throws {
        let file = try cases()
        #expect(file.format == "voxclip-whole-clip-speed/1")
        #expect(file.constants.maximumPictureSpeed == WholeClipRevoice.maximumPictureSpeed)
        #expect(file.constants.fitTolerance == WholeClipRevoice.fitTolerance)
    }

    @Test func theSpeedTheCopyAndTheRange() throws {
        let file = try cases()
        #expect(file.pictureSpeed.count == 11 && file.spedCopy.count == 5 && file.validRetime.count == 8)
        for row in file.pictureSpeed {
            #expect(WholeClipRevoice.pictureSpeed(voiceSeconds: row.voiceSeconds, videoSeconds: row.videoSeconds) == row.speed, "\(row)")
        }
        for row in file.spedCopy { #expect(WholeClipRevoice.spedCopy(speed: row.speed, laidOut: row.laidOut) == row.copy, "\(row)") }
        for row in file.validRetime { #expect(WholeClipRevoice.validRetime(row.value) == row.valid, "\(row)") }
    }

    @Test func theSpedEditedCut() throws {
        let rows = try cases().spedCuts
        #expect(rows.count == 11)
        for row in rows {
            var video = VoiceLabVideoRecipe(mode: .cut, sourceStartSample: row.sourceStartSample, sourceEndSample: row.sourceEndSample,
                outputSamples: row.outputSamples, retimeFactor: row.retimeFactor, zoom: row.zoom, faceX: 0.5, faceY: 0.5, assetId: nil,
                provider: nil, model: nil, requestId: nil, windowStartSample: nil, windowEndSample: nil, syncMode: nil)
            video.cuts = row.cuts.map { VoiceLabVideoCut(startSample: $0[0], endSample: $0[1]) }
            #expect(VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000) == row.valid, "\(row.id)")
        }
    }

    @Test func theEvenMapping() throws {
        let rows = try cases().mapping
        #expect(rows.count == 2)
        for row in rows {
            let head = VoiceLabOutputPiece(kind: .source, sourceStartSample: 0, sourceEndSample: row.piece.sourceStartSample, outputStartSample: 0,
                outputEndSample: row.piece.outputStartSample, segmentId: nil, assetId: nil, audio: nil)
            let piece = VoiceLabOutputPiece(kind: .synth, sourceStartSample: row.piece.sourceStartSample, sourceEndSample: row.piece.sourceEndSample,
                outputStartSample: row.piece.outputStartSample, outputEndSample: row.piece.outputEndSample, segmentId: "s", assetId: "a", audio: nil)
            var plan = VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: row.piece.sourceEndSample, pieces: [head, piece], captions: [], scope: .full)
            plan.videoCuts["s"] = row.cuts.map { VoiceLabVideoCut(startSample: $0[0], endSample: $0[1]) }
            for value in row.mapTime { #expect(plan.mapTime(value.source) == value.output, "\(row.id) \(value)") }
            for value in row.sourceTime { #expect(plan.sourceTime(value.edited) == value.source, "\(row.id) \(value)") }
        }
    }
}
