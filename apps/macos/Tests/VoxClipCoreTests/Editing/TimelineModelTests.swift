import Foundation
import Testing
@testable import VoxClipCore

/// The v2 timeline's media-free rules (ux/v2 notes.md §2 and §6, impl-plan V7a): the pieces a
/// scope plays, the ruler's ticks and labels, Resolve's timecode and the overview's rows.
@Suite struct TimelineModelTests {
    // MARK: Pieces

    @Test func legacyPlanPiecesButtInOutputOrder() {
        let plan = EditPlan(sampleRate: 48_000, totalSamples: 480_000,
                            cuts: [MediaInterval(startSample: 48_000, endSample: 96_000), MediaInterval(startSample: 144_000, endSample: 480_000)],
                            kept: [MediaInterval(startSample: 0, endSample: 48_000), MediaInterval(startSample: 96_000, endSample: 144_000)])
        let pieces = TimelinePieces(.legacy(plan))
        #expect(pieces.pieces == [TimelinePiece(source: 0..<1, edited: 0..<1), TimelinePiece(source: 2..<3, edited: 1..<2)])
        #expect(pieces.editedDuration == 2)
        #expect(pieces.editedDuration == RenderTimeline.legacy(plan).duration)
        #expect(pieces.sourceSpan == 0..<3)
        #expect(pieces.pieces.allSatisfy { $0.kind == .kept })
        #expect(pieces.pieces[1].range(on: .source) == 2..<3 && pieces.pieces[1].range(on: .edited) == 1..<2)
    }

    @Test func voiceLabPlanMarksSynthPiecesAsAIAndSkipsEmptyOutput() {
        func piece(_ kind: VoiceLabOutputPieceKind, _ source: (Int64, Int64), _ output: (Int64, Int64)) -> VoiceLabOutputPiece {
            VoiceLabOutputPiece(kind: kind, sourceStartSample: source.0, sourceEndSample: source.1, outputStartSample: output.0, outputEndSample: output.1,
                                segmentId: nil, assetId: nil, audio: nil)
        }
        let plan = VoiceLabOutputPlan(sampleRate: 100, totalSourceSamples: 1_000,
                                      pieces: [piece(.source, (0, 100), (0, 100)), piece(.synth, (100, 300), (100, 350)), piece(.source, (300, 300), (350, 350)),
                                               piece(.source, (300, 400), (350, 450))],
                                      captions: [], scope: .full)
        let pieces = TimelinePieces(.voiceLab(plan))
        #expect(pieces.pieces.map(\.kind) == [.kept, .ai, .kept])
        #expect(pieces.pieces[1] == TimelinePiece(source: 1..<3, edited: 1..<3.5, kind: .ai))
        #expect(pieces.editedDuration == 4.5)
        #expect(pieces.sourceSpan == 0..<4)
    }

    @Test func overlappingPiecesAreFoundByBinarySearchOnEitherAxis() {
        let pieces = TimelinePieces((0..<1_500).map { index in
            let source = Double(index) * 2.4
            return TimelinePiece(source: source..<source + 2, edited: Double(index) * 2..<Double(index) * 2 + 2)
        })
        #expect(pieces.indices(overlapping: 10..<14.1, on: .edited) == 5..<8)
        // Source pieces start every 2.4 s: [0, 2) only touches 2, and [4.8, 6.8) starts at the end.
        #expect(pieces.indices(overlapping: 2..<4.8, on: .source) == 1..<2)
        // A piece that only touches the range's edge does not overlap it.
        #expect(pieces.indices(overlapping: 4..<6, on: .edited) == 2..<3)
        #expect(pieces.indices(overlapping: 4_000..<5_000, on: .edited).isEmpty)
        #expect(pieces.indices(overlapping: -10..<0, on: .source).isEmpty)
        #expect(TimelinePieces([]).indices(overlapping: 0..<10, on: .edited) == 0..<0)
        #expect(TimelinePieces([]).editedDuration == 0 && TimelinePieces([]).sourceSpan == nil)
    }

    // MARK: Ruler

    @Test func labelsStepFromFiveToTenSecondsBelowNinetyPoints() {
        #expect(TimelineRuler.majorStep(ptPerSecond: 936 / 45.2) == 5)
        #expect(TimelineRuler.majorStep(ptPerSecond: 18) == 5)
        #expect(TimelineRuler.majorStep(ptPerSecond: 17.9) == 10)
        #expect(TimelineRuler.majorStep(ptPerSecond: 9) == 10)
        // A 5:26 take in 936 pt: coarser steps on the same rule.
        #expect(TimelineRuler.majorStep(ptPerSecond: 936 / 328.0) == 60)
        #expect(TimelineRuler.majorStep(ptPerSecond: 936 / 3_602.0) == 600)
        #expect(TimelineRuler.majorStep(ptPerSecond: 0) == 3_600 && TimelineRuler.majorStep(ptPerSecond: .nan) == 3_600)
        #expect(TimelineRuler.minorStep(ptPerSecond: 936 / 45.2) == 1)
        #expect(TimelineRuler.minorStep(ptPerSecond: 936 / 328.0) == 5)
        #expect(TimelineRuler.minorStep(ptPerSecond: 936 / 3_602.0) == 30)
    }

    @Test func ticksAreWholeSecondsWithLabelledMajors() {
        let ticks = TimelineRuler.ticks(visible: -1...44.2, ptPerSecond: 936 / 45.2)
        #expect(ticks.first == TimelineTick(time: -1, major: false))
        #expect(ticks.last == TimelineTick(time: 44, major: false))
        #expect(ticks.count == 46)
        #expect(ticks.filter(\.major).map(\.time) == [0, 5, 10, 15, 20, 25, 30, 35, 40])
        #expect(ticks.allSatisfy { $0.time == $0.time.rounded() })
        // Far into a long take the ticks stay exact.
        let late = TimelineRuler.ticks(visible: 3_500.3...3_600, ptPerSecond: 936 / 99.7)
        #expect(late.first?.time == 3_501 && late.filter(\.major).map(\.time) == [3_510, 3_520, 3_530, 3_540, 3_550, 3_560, 3_570, 3_580, 3_590, 3_600])
        #expect(TimelineRuler.ticks(visible: 0...10, ptPerSecond: 0).isEmpty)
        #expect(TimelineRuler.ticks(visible: 0...Double.infinity, ptPerSecond: 20).isEmpty)
    }

    @Test func labelsNeverCrossABracketOrTheLaneEnd() {
        let width = 66.0
        // 4 pt after its tick.
        #expect(TimelineRuler.labelX(tickX: 300, width: width, brackets: [], inBracket: nil, laneEnd: 1_048) == 304)
        // An In bracket standing on the tick: 9 pt, clear of its foot (f1's 00:00:00:00).
        #expect(TimelineRuler.labelX(tickX: 132, width: width, brackets: [132, 1_040], inBracket: 132, laneEnd: 1_048) == 141)
        // A bracket inside the label's run hides it, as do brackets just before or after it.
        #expect(TimelineRuler.labelX(tickX: 300, width: width, brackets: [340], inBracket: nil, laneEnd: 1_048) == nil)
        #expect(TimelineRuler.labelX(tickX: 300, width: width, brackets: [302], inBracket: nil, laneEnd: 1_048) == nil)
        #expect(TimelineRuler.labelX(tickX: 300, width: width, brackets: [371], inBracket: nil, laneEnd: 1_048) == nil)
        #expect(TimelineRuler.labelX(tickX: 300, width: width, brackets: [373], inBracket: nil, laneEnd: 1_048) == 304)
        // Never past the lane's end plus 6.
        #expect(TimelineRuler.labelX(tickX: 980, width: width, brackets: [], inBracket: nil, laneEnd: 1_048) == 984)
        #expect(TimelineRuler.labelX(tickX: 985, width: width, brackets: [], inBracket: nil, laneEnd: 1_048) == nil)
    }

    // MARK: Timecode

    @Test func smpteDimsLeadingZeroGroupsAt30fps() {
        #expect(SMPTETimecode.format(seconds: 0) == ("00:00:", "00:00"))
        #expect(SMPTETimecode.format(seconds: 14 + 23.0 / 30) == ("00:00:", "14:23"))
        #expect(SMPTETimecode.format(seconds: 443.0 / 30) == ("00:00:", "14:23"))
        #expect(SMPTETimecode.format(seconds: 4 * 60 + 19 + 26.0 / 30) == ("00:", "04:19:26"))
        #expect(SMPTETimecode.format(seconds: 3_600 + 61.5) == ("", "01:01:01:15"))
        #expect(SMPTETimecode.format(seconds: 100 * 3_600) == ("", "100:00:00:00"))
        #expect(SMPTETimecode.string(seconds: 326) == "00:05:26:00")
    }

    @Test func smpteFramesRoundDownAndClampBadTimes() {
        // A frame runs from k/30 up to (k + 1)/30.
        #expect(SMPTETimecode.frame(seconds: 1.0 / 30) == 1)
        #expect(SMPTETimecode.frame(seconds: 1.0 / 30 - 0.0001) == 0)
        #expect(SMPTETimecode.frame(seconds: 0.999) == 29)
        #expect(SMPTETimecode.format(seconds: 59.999) == ("00:00:", "59:29"))
        #expect(SMPTETimecode.format(seconds: 60) == ("00:", "01:00:00"))
        #expect(SMPTETimecode.frame(seconds: -3) == 0 && SMPTETimecode.frame(seconds: .nan) == 0 && SMPTETimecode.frame(seconds: .infinity) == 0)
        #expect(SMPTETimecode.format(seconds: 2.5, fps: 25) == ("00:00:", "02:12"))
    }

    // MARK: Overview

    @Test func overlappingClipsStackInTheFirstFreeRow() {
        #expect(TimelineOverview.rows(for: [0...10, 5...15, 10...20, 12...14]) == [0, 1, 0, 2])
        // Clips that only touch share a row; f5's proposals stack in a second.
        #expect(TimelineOverview.rows(for: [0...10, 10...20]) == [0, 0])
        #expect(TimelineOverview.rows(for: [221...264, 280...305, 48...70, 196...215, 131...160]) == [0, 0, 0, 0, 0])
        #expect(TimelineOverview.rows(for: [221...264, 236...262]) == [0, 1])
        #expect(TimelineOverview.rows(for: []).isEmpty)
    }
}
