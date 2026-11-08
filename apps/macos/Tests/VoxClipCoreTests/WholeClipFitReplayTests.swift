import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/voice-lab/whole-clip-fit-cases.json (ADR-R46 update 2026-11-08; the C# twin WholeClipFitReplayTests
/// replays the same file): the fit on the clip as edited, check before paying, the picture's cuts, the clip's own cuts in a
/// window and the pause bound; and the user's MVP44 clip, as numbers, laid out end to end.
@Suite(.offlineFixtures) struct WholeClipFitReplayTests {
    private struct Cut: Decodable, Equatable { let startSample: Int64; let endSample: Int64 }
    struct FitResult: Decodable { let kind: String; let factor: Double?; let copy: String?; let targetWords: Int? }
    private struct FitCase: Decodable { let voiceSeconds: Double; let videoSeconds: Double; let words: Int; let round: Int; let expected: FitResult }
    private struct RewordCase: Decodable {
        let voiceSeconds: Double; let estimateSeconds: Double; let newEstimateSeconds: Double; let videoSeconds: Double
        let predicted: Double?; let fits: Bool
    }
    private struct LayoutCase: Decodable { let id: String; let cuts: [Cut]; let startSample: Int64; let endSample: Int64; let removedSamples: Int64; let expected: [Cut]? }
    private struct Piece: Decodable { let sourceStartSample: Int64; let sourceEndSample: Int64 }
    private struct EditedCase: Decodable { let id: String; let pieces: [Piece]; let startSample: Int64; let endSample: Int64; let expected: [Cut] }
    private struct BoundCase: Decodable { let pauseThresholdSeconds: Double; let bound: Double }
    struct Shown: Decodable { let editedSeconds: Double; let sourceWindowSeconds: Double }
    struct Before: Decodable { let kind: String; let shorter: Bool; let targetWords: Int }
    struct UsersClip: Decodable {
        let words: [[Double]]
        let clipFirstWord: Int; let clipLastWord: Int; let cutPausesAfterWord: [Int]
        let pauseThresholdSeconds: Double; let pauseKeepSeconds: Double; let durationSeconds: Double; let sampleRate: Int
        let scriptWords: Int; let voiceSeconds: Double
        let shown: Shown; let expected: FitResult; let before: Before
    }
    private struct Constants: Decodable {
        let fitTolerance: Double; let maximumRewordRounds: Int; let editedCutZoom: Double; let maximumEditedCuts: Int
        let pauseFloorPunct: Double; let pauseFloorPhrase: Double
    }
    private struct Cases: Decodable {
        let format: String; let constants: Constants; let usersClip: UsersClip; let fit: [FitCase]; let rewordFits: [RewordCase]
        let layoutCuts: [LayoutCase]; let editedCuts: [EditedCase]; let pauseBound: [BoundCase]
    }

    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/voice-lab/whole-clip-fit-cases.json"))
    }
    private func cuts(_ values: [Cut]) -> [VoiceLabVideoCut] { values.map { VoiceLabVideoCut(startSample: $0.startSample, endSample: $0.endSample) } }

    @Test func formatAndConstants() throws {
        let file = try cases()
        #expect(file.format == "voxclip-whole-clip-fit/1")
        #expect(file.constants.fitTolerance == WholeClipRevoice.fitTolerance && file.constants.maximumRewordRounds == WholeClipRevoice.maximumRewordRounds)
        #expect(file.constants.editedCutZoom == VoiceLabNaturalPacing.EDITED_CUT_ZOOM && file.constants.maximumEditedCuts == VoiceLabNaturalPacing.MAXIMUM_EDITED_CUTS)
        #expect(file.constants.pauseFloorPunct == VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT && file.constants.pauseFloorPhrase == VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE)
    }

    @Test func theFitOnTheClipAsEdited() throws {
        let rows = try cases().fit
        #expect(rows.count == 20)
        for row in rows {
            let fit = WholeClipRevoice.fit(voiceSeconds: row.voiceSeconds, videoSeconds: row.videoSeconds, words: row.words, round: row.round)
            switch row.expected.kind {
            case "matched":
                let factor = row.expected.factor ?? .nan
                #expect(fit == .matched(factor: factor), "\(row)")
                #expect(WholeClipRevoice.matchedCopy(factor: factor) == row.expected.copy)
            case "laidOut":
                let factor = row.expected.factor ?? .nan
                #expect(fit == .laidOut(factor: factor), "\(row)")
                #expect(WholeClipRevoice.laidOutCopy(factor: factor) == row.expected.copy)
            case "reword":
                #expect(fit == .reword(targetWords: row.expected.targetWords ?? -1), "\(row)")
            default:
                #expect(fit == .cannotFit(voiceSeconds: row.voiceSeconds, videoSeconds: row.videoSeconds), "\(row)")
            }
        }
    }

    @Test func checkBeforePaying() throws {
        let rows = try cases().rewordFits
        #expect(rows.count == 11)
        for row in rows {
            #expect(WholeClipRevoice.predictedSeconds(voiceSeconds: row.voiceSeconds, estimateSeconds: row.estimateSeconds,
                                                      newEstimateSeconds: row.newEstimateSeconds) == row.predicted, "\(row)")
            #expect(WholeClipRevoice.rewordFits(voiceSeconds: row.voiceSeconds, estimateSeconds: row.estimateSeconds,
                                                newEstimateSeconds: row.newEstimateSeconds, videoSeconds: row.videoSeconds) == row.fits, "\(row)")
        }
    }

    @Test func thePicturesCuts() throws {
        let rows = try cases().layoutCuts
        #expect(rows.count == 16)
        for row in rows {
            let found = WholeClipRevoice.layoutCuts(cuts(row.cuts), startSample: row.startSample, endSample: row.endSample, removedSamples: row.removedSamples)
            #expect(found == row.expected.map(cuts), "\(row.id)")
        }
    }

    @Test func theClipsOwnCutsInAWindow() throws {
        let rows = try cases().editedCuts
        #expect(rows.count == 7)
        for row in rows {
            let pieces = row.pieces.enumerated().map { index, piece in
                VoiceLabOutputPiece(kind: .source, sourceStartSample: piece.sourceStartSample, sourceEndSample: piece.sourceEndSample,
                                    outputStartSample: Int64(index), outputEndSample: Int64(index + 1), segmentId: nil, assetId: nil, audio: nil)
            }
            let plan = VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: 1_000_000, pieces: pieces, captions: [], scope: .full)
            #expect(WholeClipRevoice.editedCuts(plan, startSample: row.startSample, endSample: row.endSample) == cuts(row.expected), "\(row.id)")
        }
    }

    @Test func thePauseBound() throws {
        for row in try cases().pauseBound {
            #expect(WholeClipRevoice.layoutPauseBound(row.pauseThresholdSeconds) == row.bound)
        }
    }

    // MARK: The user's clip

    /// The user's MVP44 project as numbers (no words): the transcript's timings, the clip, its cuts and tightened pauses.
    static func usersProject(_ clip: UsersClip) throws -> Project {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        project.voiceLab.segments = []; project.voiceLab.assets = []
        let words = clip.words.enumerated().map { index, row in
            TimedWord(id: "w\(index)", text: row[3] == 1 ? "said." : "said", kind: .word, start: row[0], end: row[1],
                      rawStart: nil, rawEnd: nil, conf: nil, speaker: nil)
        }
        project.transcript?.words = words
        project.transcript?.durationSeconds = clip.durationSeconds
        project.media.source.durationSeconds = clip.durationSeconds
        project.media.source.audio?.sampleRate = clip.sampleRate
        var edits = ProjectEdits(pauseThresholdSeconds: clip.pauseThresholdSeconds, pauseKeepSeconds: clip.pauseKeepSeconds)
        edits.cutWordIds = clip.words.indices.filter { clip.words[$0][2] == 1 }.map { "w\($0)" }
        edits.cutPauseIds = clip.cutPausesAfterWord.map { "pause-after-w\($0)" }
        edits.clips = [ClipRange(id: "clip-users", startWordId: "w\(clip.clipFirstWord)", endWordId: "w\(clip.clipLastWord)", title: "Clip 1")]
        edits.activeClipId = "clip-users"
        project.edits = edits
        return project
    }

    /// 49 spoken words, the clip 0:31.4 as edited, 48.6 s of source under its parts and a 27 s voice. The fit reads the clip
    /// as edited and asks for no longer wording; the voice is laid out on it with its sentence pauses within the bound, and
    /// the picture is the clip's own cuts. The old fit read the source and asked for about 88 words.
    @Test func theUsersClipIsLaidOutOnTheEditedClip() throws {
        let clip = try cases().usersClip
        let project = try Self.usersProject(clip)
        let plan = try VoiceLabOutputPlanner.build(project, scope: .clip("clip-users"))
        let rate = plan.sampleRate
        #expect(abs(plan.duration - clip.shown.editedSeconds) < 0.05, "the clip as edited: \(plan.duration) s")
        let words = try #require(project.transcript?.words)
        let start = Int64(EditingPrimitives.jsRound(words[clip.clipFirstWord].start * rate))
        let end = Int64(EditingPrimitives.jsRound(words[clip.clipLastWord].end * rate))
        let edited = WholeClipRevoice.editedCuts(plan, startSample: start, endSample: end)
        let editedSeconds = WholeClipRevoice.editedSeconds(edited, startSample: start, endSample: end, sampleRate: rate)
        // The window runs from the clip's first word to its last; the clip as edited adds only the kept silence at its edges.
        #expect(editedSeconds <= plan.duration && plan.duration - editedSeconds < 0.3, "\(editedSeconds) s of \(plan.duration) s")
        #expect(Double(end - start) / rate > clip.shown.editedSeconds + 15, "the source under it is far longer")
        #expect(edited.count >= clip.cutPausesAfterWord.count, "\(edited.count) cuts")
        // The fit: laid out, never a longer wording.
        let fit = WholeClipRevoice.fit(voiceSeconds: clip.voiceSeconds, videoSeconds: editedSeconds, words: clip.scriptWords, round: 0)
        guard case .laidOut(let factor) = fit else { Issue.record("\(fit)"); return }
        #expect(factor == clip.voiceSeconds / editedSeconds && clip.expected.kind == "laidOut")
        #expect(clip.before.shorter == false && clip.before.targetWords == 88, "the run used to ask for a longer wording")
        // The layout: a 27 s take of the clip's sentences, laid out on the window as edited.
        let sentences = clip.words[clip.clipFirstWord...clip.clipLastWord].filter { $0[2] == 0 && $0[3] == 1 }.count
        let pause = 0.3
        let said = (clip.voiceSeconds - Double(sentences - 1) * pause) / Double(sentences)
        let take = WholeClipLayoutTests.take(sentences: Array(repeating: said, count: sentences), pause: pause, assetRate: 24_000)
        let window = VoiceLabWindow(firstWordId: "w\(clip.clipFirstWord)", lastWordId: "w\(clip.clipLastWord)", leftBridgeWordIds: [],
            rightBridgeWordIds: [], start: Double(start) / rate, end: Double(end) / rate, startSample: start, endSample: end,
            leftSeam: .init(kind: .gap, time: Double(start) / rate, sample: start, fadeSamples: 960),
            rightSeam: .init(kind: .gap, time: Double(end) / rate, sample: end, fadeSamples: 960))
        let result = try VoiceLabNaturalPacing.layout(window: window, incomingSilence: 0, outgoingSilence: 0, take: take,
            sourceSampleRate: Int(rate), hardJoinSmoothing: true,
            pauseProfile: WholeClipRevoice.layoutPauseProfile(pauseThresholdSeconds: clip.pauseThresholdSeconds),
            audioTags: [], editedCuts: edited, tailSeconds: WholeClipRevoice.layoutPauseBound(clip.pauseThresholdSeconds))
        let options = VoiceLabVideoDurationOptions(fit: result, sourceSampleRate: Int(rate), assetSampleRate: 24_000)
        #expect(options.allows(.cut), "the picture is the clip as edited: \(result)")
        let laid = result.plan
        let growth = laid.edits.filter { $0.kind == .insert }.map { Double($0.count) / 24_000 }
        // Each sentence pause grew to the bound at most (the take's measured pause is a frame or two short of 0.3 s).
        #expect(growth.count == sentences - 1 && growth.allSatisfy { $0 + pause <= clip.pauseThresholdSeconds + 0.03 }, "\(growth)")
        #expect(Array(laid.videoCuts.prefix(edited.count)) == edited || laid.videoCuts == edited, "the clip's own cuts lead the picture")
        let output = Double(options.outputSamples ?? 0) / rate
        #expect(output <= editedSeconds + 1e-3 && output > editedSeconds - 0.5, "\(output) s of picture for \(editedSeconds) s as edited")
        var video = VoiceLabVideoRecipe(mode: .cut, sourceStartSample: laid.windowStartSample, sourceEndSample: laid.windowEndSample,
            outputSamples: options.outputSamples ?? 0, retimeFactor: nil, zoom: VoiceLabVideoDurationOptions.cutZoom(laid), faceX: 0.5, faceY: 0.5,
            assetId: nil, provider: nil, model: nil, requestId: nil, windowStartSample: nil, windowEndSample: nil, syncMode: nil)
        video.cuts = options.cuts
        #expect(VoiceLabNaturalPacing.validCuts(video, sampleRate: rate) && video.zoom == 1, "the recipe's picture validates at zoom 1")
        // The lip sync is priced on the clip as edited, not the source windows.
        let catalog = try VoiceLabPriceCatalog(data: FixtureLoader.data("catalog/voice-lab.json"))
        let lipsync = try WholeClipRevoice.lipsyncPrice(videoSeconds: editedSeconds + 2, lipsync: .lipsync2, catalog: catalog)
        #expect(lipsync.units == editedSeconds + 2 && lipsync.units < clip.shown.sourceWindowSeconds)
    }
}
