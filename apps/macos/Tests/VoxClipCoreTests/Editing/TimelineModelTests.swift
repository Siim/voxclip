import Foundation
import Testing
@testable import VoxClipCore

/// The v2 timeline's media-free rules (ux/v2 notes.md §2 and §6, impl-plan V7a): the pieces a
/// scope plays, the ruler's ticks and labels, Resolve's timecode and the overview's rows.
@Suite(.offlineFixtures) struct TimelineModelTests {
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

    /// notes.md §6: on Edited each cut closes to ONE seam; a Voice Lab patch continues its
    /// neighbours' take time and has none. On Source the removed ranges inside the scope are
    /// exactly the cuts there, and gaps shorter than 20 ms are not drawn.
    @Test func seamsAreTheCutsAndSourceGapsAreTheirRanges() {
        let plan = EditPlan(sampleRate: 100, totalSamples: 6_000,
                            cuts: [MediaInterval(startSample: 0, endSample: 1_000), MediaInterval(startSample: 1_400, endSample: 1_600),
                                   MediaInterval(startSample: 2_000, endSample: 2_001), MediaInterval(startSample: 2_500, endSample: 3_000),
                                   MediaInterval(startSample: 4_000, endSample: 6_000)],
                            kept: [MediaInterval(startSample: 1_000, endSample: 1_400), MediaInterval(startSample: 1_600, endSample: 2_000),
                                   MediaInterval(startSample: 2_001, endSample: 2_500), MediaInterval(startSample: 3_000, endSample: 4_000)])
        let pieces = TimelinePieces(.legacy(plan))
        // Three cuts inside the kept span (14–16 s, the 10 ms one at 20 s and 25–30 s), at their edited times.
        #expect(pieces.seams == [4, 8, 12.99])
        #expect(!pieces.isSeam(at: 0) && pieces.isSeam(at: 1) && !pieces.isSeam(at: 9))
        // Inside a clip of 10–40 s the gaps are the cut ranges, less the 10 ms one.
        #expect(pieces.gaps(within: 10..<40) == [14..<16, 25..<30])
        // On Full Take the leading and trailing cuts are gaps too.
        #expect(pieces.gaps(within: 0..<60) == [0..<10, 14..<16, 25..<30, 40..<60])
        #expect(pieces.gaps(within: 0..<60, minimum: 0) == [0..<10, 14..<16, 20..<20.01, 25..<30, 40..<60])
        #expect(TimelinePieces([]).gaps(within: 2..<5) == [2..<5] && TimelinePieces([]).seams.isEmpty)

        func piece(_ kind: VoiceLabOutputPieceKind, _ source: (Int64, Int64), _ output: (Int64, Int64)) -> VoiceLabOutputPiece {
            VoiceLabOutputPiece(kind: kind, sourceStartSample: source.0, sourceEndSample: source.1, outputStartSample: output.0, outputEndSample: output.1,
                                segmentId: nil, assetId: nil, audio: nil)
        }
        let voice = TimelinePieces(.voiceLab(VoiceLabOutputPlan(sampleRate: 100, totalSourceSamples: 1_000,
            pieces: [piece(.source, (0, 100), (0, 100)), piece(.synth, (100, 300), (100, 350)), piece(.source, (300, 400), (350, 450)),
                     piece(.source, (500, 600), (450, 550))], captions: [], scope: .full)))
        // The patch butts on both sides; the cut at 4–5 s is the one seam.
        #expect(voice.seams == [4.5])
        #expect(voice.gaps(within: 0..<6) == [4..<5])
    }

    @Test func secondsAreOneDecimalWithANonBreakingSpace() {
        let space = String(Character(Unicode.Scalar(UInt8(0xA0))))
        #expect(SecondsText.format(4.4) == "4.4" + space + "s")
        #expect(SecondsText.format(0.04) == "0.0" + space + "s")
        #expect(SecondsText.format(61.25) == "61.2" + space + "s" || SecondsText.format(61.25) == "61.3" + space + "s")
        #expect(SecondsText.format(-1) == "0.0" + space + "s" && SecondsText.format(.nan) == "0.0" + space + "s")
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
        // 4.1 × 30 is 122.99999999999999 in binary: still frame 123 (4 s 3 f).
        #expect(SMPTETimecode.frame(seconds: 4.1) == 123)
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

    // MARK: Captions (V9)

    /// notes.md §6: a cue holds until the next if the gap is at most 0.6 s, so cues butt (the
    /// lane draws the 1 pt seam); a longer gap stays empty lane. On Source each cue is one
    /// span in the take with the cut parts inside it, and its text is the Edited cue's.
    @Test func cuesHoldAcrossShortGapsAndCarryTheirCutsOnSource() {
        let pages = [
            TimelineCaptions.Page(edited: 0..<1.2, source: 10..<11.6, text: "And one cool"),
            TimelineCaptions.Page(edited: 1.7..<2.5, source: 12.1..<12.9, text: "feature I added,"),
            TimelineCaptions.Page(edited: 3.2..<4, source: 13.6..<14.4, text: "is when"),
            TimelineCaptions.Page(edited: 4..<4, source: 14.4..<14.4, text: "")
        ]
        let edited = TimelineCaptions.cues(pages, on: .edited)
        // 0.5 s to the second page: held; 0.7 s to the third: not held. The empty page is skipped.
        #expect(edited.map(\.range) == [0..<1.7, 1.7..<2.5, 3.2..<4])
        #expect(edited.map(\.text) == ["And one cool", "feature I added,", "is when"])
        #expect(edited.allSatisfy { $0.cuts.isEmpty })
        // Source: the first cue holds to the second's first word in the take, with the cut
        // (11.6–12.1) and one inside the third (13.8–14.0) darkened; a cut before the cues is not.
        let removed: [Range<Double>] = [5..<9, 11.6..<12.1, 13.8..<14.0, 20..<21]
        let source = TimelineCaptions.cues(pages, on: .source, removed: removed)
        #expect(source.map(\.range) == [10..<12.1, 12.1..<12.9, 13.6..<14.4])
        #expect(source.map(\.cuts) == [[11.6..<12.1], [], [13.8..<14.0]])
        #expect(source.map(\.text) == edited.map(\.text))
        // Without the hold rule the first cue would end at its last word, 1.2 s.
        #expect(edited[0].range.upperBound == 1.7)
    }

    @Test func visibleCuesAreFoundByBinarySearch() {
        let cues = (0..<2_000).map { TimelineCue(range: Double($0) * 2..<Double($0) * 2 + 1.5, text: "word") }
        #expect(TimelineCaptions.indices(of: cues, overlapping: 10..<15) == 5..<8)
        #expect(TimelineCaptions.indices(of: cues, overlapping: 11.6..<11.9) == 6..<6)
        #expect(TimelineCaptions.indices(of: cues, overlapping: -5..<0.1) == 0..<1)
        #expect(TimelineCaptions.indices(of: cues, overlapping: 5_000..<6_000).isEmpty)
        #expect(TimelineCaptions.indices(of: [], overlapping: 0..<1).isEmpty)
    }

    /// notes.md §6 and the mockup's fitting: whole words that fit; a dim "…" when words were
    /// dropped; the first word alone when its ellipsis would not fit; nothing under 24 pt; a
    /// trailing comma never shows. Widths here are 6 pt a character and 8 pt for the ellipsis.
    @Test func cueTextFitsWholeWords() {
        func fit(_ text: String, _ width: Double) -> TimelineCueText.Fit? {
            TimelineCueText.fit(text, width: width, ellipsisWidth: 8, measure: { Double($0.count) * 6 })
        }
        // "And one cool" is 72 pt: it needs 80 with the 4 pt padding each side.
        #expect(fit("And one cool", 80) == .init(text: "And one cool", ellipsis: false))
        // "And one" (42) + 1 + 8 = 51 fits 79 − 8; the third word is dropped.
        #expect(fit("And one cool", 79) == .init(text: "And one", ellipsis: true))
        #expect(fit("And one cool", 40) == .init(text: "And", ellipsis: true))
        // "And" + "…" needs 18 + 9 = 27 > 32 − 8: the first word alone.
        #expect(fit("And one cool", 32) == .init(text: "And", ellipsis: false))
        // Under 24 pt nothing draws, even a word that would fit.
        #expect(fit("So", 23.9) == nil)
        #expect(fit("So", 24) == .init(text: "So", ellipsis: false))
        // A first word that does not fit alone draws nothing.
        #expect(fit("Unbelievable things", 30) == nil)
        // A comma before a dropped word, or at the end, folds away.
        #expect(fit("added, to the", 63) == .init(text: "added", ellipsis: true))
        #expect(fit("feature I added,", 200) == .init(text: "feature I added", ellipsis: false))
        #expect(fit("", 200) == nil)
    }

    // MARK: Filmstrip (V9)

    @Test func filmstripCellsAreWholeFramesFromALadder() {
        // A 39 pt tile at 20.7 pt/s (f1) stands for 1.9 s: the 2 s cell (60 frames).
        #expect(TimelineFilmstrip.cellFrames(tileWidth: 39, ptPerSecond: 20.7) == 60)
        // At 200 pt/s a tile is 0.195 s: 6 frames is 0.2 s, so the 10-frame cell after 5.
        #expect(TimelineFilmstrip.cellFrames(tileWidth: 39, ptPerSecond: 200) == 10)
        // A tile exactly a cell long takes that cell.
        #expect(TimelineFilmstrip.cellFrames(tileWidth: 30, ptPerSecond: 30) == 30)
        // A fitted hour (0.26 pt/s) needs 150 s: the 300 s cell. Nonsense zooms take the longest.
        #expect(TimelineFilmstrip.cellFrames(tileWidth: 39, ptPerSecond: 0.26) == 9_000)
        #expect(TimelineFilmstrip.cellFrames(tileWidth: 39, ptPerSecond: 0) == 108_000)
        // A tile shows its cell's first frame, so nearby tiles and zooms share frames.
        #expect(TimelineFilmstrip.frame(at: 4.1, cellFrames: 60) == 120)
        #expect(TimelineFilmstrip.frame(at: 3.99, cellFrames: 60) == 60)
        #expect(TimelineFilmstrip.frame(at: 4.1, cellFrames: 1) == 123)
        #expect(TimelineFilmstrip.frame(at: -1, cellFrames: 60) == 0)
    }
}
