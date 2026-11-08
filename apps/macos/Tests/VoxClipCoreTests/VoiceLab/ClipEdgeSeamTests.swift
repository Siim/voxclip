import Foundation
import Testing
@testable import VoxClipCore

/// A clip that starts or ends mid-take on a word touching the one outside it (voice-lab §8.4, a clip's own edges). Whisper
/// word ends are back to back (transcription.md §5.5), so most such clips leave no silence at their edge. The seam there is
/// the clip's output edge: nothing renders beside it in the clip, and it keeps the hard seam the full take renders. Before
/// this rule each window below was refused with `seamFadeCrossesCut(incoming:needed: 288, available: 0)` or its outgoing twin.
@Suite(.offlineFixtures) struct ClipEdgeSeamTests {
    struct Take {
        var project: Project
        var clip: [TimedWord]
        var cuts: Set<String>
        var envelope: AudioEnvelope
    }

    /// A 48 kHz take: three kept words, the clip's `script`, three kept words. A plain token is a 0.3 s word touching the
    /// one before it, `~um` a cut word and `|0.5` a 0.5 s silence. `before` and `after` are the silences between the clip and
    /// the words outside it; zero is the mid-take case.
    static func take(_ script: [String], before: Double, after: Double, cutOutside: [String] = []) throws -> Take {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        project.voiceLab.segments = []; project.voiceLab.assets = []
        var words: [TimedWord] = [], cuts = Set(cutOutside), clip: [TimedWord] = []
        var time = 1.0, count = 0
        func say(_ text: String, id: String) -> TimedWord {
            let word = TimedWord(id: id, text: text, start: time, end: time + 0.3)
            time += 0.3
            words.append(word)
            return word
        }
        for (index, text) in ["We", "said", "and"].enumerated() { _ = say(text, id: "pre\(index)") }
        time += before
        for token in script {
            if token.hasPrefix("|") { time += Double(token.dropFirst()) ?? 0; continue }
            let cut = token.hasPrefix("~"), id = "w\(count)"
            count += 1
            clip.append(say(cut ? String(token.dropFirst()) : token, id: id))
            if cut { cuts.insert(id) }
        }
        time += after
        for (index, text) in ["so", "we", "left."].enumerated() { _ = say(text, id: "post\(index)") }
        project.transcript?.words = words
        project.media.source.durationSeconds = time + 1
        project.media.source.audio?.sampleRate = 48_000
        project.edits.cutWordIds = cuts.sorted()
        project.edits.cutPauseIds = []
        project.edits.pauseThresholdSeconds = 0.8
        project.edits.clips = [ClipRange(id: "clip-main", startWordId: clip[0].id, endWordId: clip[clip.count - 1].id)]
        project.edits.activeClipId = "clip-main"
        let frames = Int(project.media.source.durationSeconds * 100) + 1
        var levels = [Float](repeating: 0.0005, count: frames)
        for word in words { for frame in Int(word.start * 100)..<min(frames, Int(word.end * 100)) { levels[frame] = 0.1 } }
        return Take(project: project, clip: clip, cuts: cuts, envelope: AudioEnvelope(sampleRate: 48_000, levels: levels))
    }

    static func sentence(_ letter: String) -> [String] { (0..<19).map { "\(letter)\($0)" } + ["\(letter)-end."] }
    static let scope = VoiceLabOutputScope.clip("clip-main")
    static let clipScript = sentence("a") + ["|0.5"] + sentence("b") + ["|0.5"] + sentence("c")

    /// The three mid-take shapes: no silence before the clip, none after it, and neither.
    enum Edges: String, CaseIterable { case opens, closes, both }
    static func take(_ edges: Edges) throws -> Take {
        try take(clipScript, before: edges == .closes ? 0.5 : 0, after: edges == .opens ? 0.5 : 0)
    }

    /// The windows validate as the take plan checks them in the clip, and as the full take renders their segments.
    static func validateInBothScopes(_ take: Take, _ windows: [VoiceLabWindow], _ name: String) {
        for scope in [Self.scope, .full] {
            do { try VoiceLabRenderContract.validatePlacement(take.project, scope: scope, windows: windows) } catch {
                Issue.record("\(name) does not validate in \(scope): \(error)")
            }
        }
    }

    /// The edge seams: hard, at the clip's own start or end sample, with the full hard fade.
    static func expectClipEdges(_ take: Take, _ windows: [VoiceLabWindow], _ edges: Edges, _ name: String) throws {
        let words = try #require(take.project.transcript?.words)
        let range = try clipTimes(words, startIndex: 3, endIndex: 2 + take.clip.count)
        let opening = try #require(windows.min { $0.startSample < $1.startSample })
        let closing = try #require(windows.max { $0.endSample < $1.endSample })
        if edges != .closes {
            let sample = VoiceLabGeometry.samples(range.start, 48_000)
            #expect(opening.leftSeam == VoiceLabSeamPlacement(kind: .hard, time: range.start, sample: sample, fadeSamples: 576), "\(name)")
        }
        if edges != .opens {
            #expect(closing.rightSeam.kind == .hard && closing.rightSeam.time == range.end && closing.rightSeam.fadeSamples == 576, "\(name)")
        }
    }

    @Test(arguments: Edges.allCases) func wholeClipRevoicePlacesEveryPart(_ edges: Edges) throws {
        let take = try Self.take(edges)
        let script = try #require(WholeClipScript.assemble(words: take.clip, cutWordIds: take.cuts, voiceHunks: []))
        let hunks = script.hunks(words: take.clip, cutWordIds: take.cuts, cutPauseIds: [])
        #expect(hunks.count == 3)
        var windows: [VoiceLabWindow] = []
        for result in VoiceLabWindowPlanner.placeAll(project: take.project, scope: Self.scope, envelope: take.envelope, hunks: hunks) {
            switch result {
            case .placed(_, _, let window): windows.append(window)
            case .refused(let index, _, let reason): Issue.record("\(edges): part \(index) refused: \(reason)")
            }
        }
        for word in take.clip {
            #expect(windows.filter { $0.start <= word.start && word.end <= $0.end }.count == 1, "\(edges): \(word.id)")
        }
        try Self.expectClipEdges(take, windows, edges, "\(edges)")
        Self.validateInBothScopes(take, windows, "\(edges) whole clip")
    }

    @Test(arguments: Edges.allCases) func patchOfTheClipsFirstAndLastWord(_ edges: Edges) throws {
        let take = try Self.take(edges)
        for word in [take.clip[0], take.clip[take.clip.count - 1]] {
            let window = try VoiceLabWindowPlanner.place(project: take.project, scope: Self.scope, envelope: take.envelope,
                                                         firstWordId: word.id, lastWordId: word.id)
            Self.validateInBothScopes(take, [window], "\(edges) \(word.id)")
        }
        // The patch path reaches the same seam as the whole clip on the side that touches the word outside.
        let first = try VoiceLabWindowPlanner.place(project: take.project, scope: Self.scope, envelope: take.envelope,
                                                    firstWordId: take.clip[0].id, lastWordId: take.clip[0].id)
        let last = try VoiceLabWindowPlanner.place(project: take.project, scope: Self.scope, envelope: take.envelope,
                                                   firstWordId: take.clip[take.clip.count - 1].id, lastWordId: take.clip[take.clip.count - 1].id)
        try Self.expectClipEdges(take, [first, last], edges, "\(edges) patch")
    }

    /// A 65 ms silence before and after the clip: its edges sit 32.5 ms out and a hard seam 30 ms out, so 2.5 ms of the clip's
    /// source would lie beside each seam, too little for its fade. The seams move to the clip's own edges.
    @Test func aSliverOfSilenceMovesTheSeamToTheClipsEdge() throws {
        let take = try Self.take(Self.clipScript, before: 0.065, after: 0.065)
        let words = try #require(take.project.transcript?.words)
        let range = try clipTimes(words, startIndex: 3, endIndex: 2 + take.clip.count)
        let first = try VoiceLabWindowPlanner.place(project: take.project, scope: Self.scope, envelope: take.envelope,
                                                    firstWordId: "w0", lastWordId: "w0")
        let last = try VoiceLabWindowPlanner.place(project: take.project, scope: Self.scope, envelope: take.envelope,
                                                   firstWordId: "w59", lastWordId: "w59")
        #expect(first.leftSeam.kind == .hard && first.start == range.start && first.start == take.clip[0].start - 0.0325)
        #expect(last.rightSeam.kind == .hard && last.end == range.end)
        Self.validateInBothScopes(take, [first], "sliver first")
        Self.validateInBothScopes(take, [last], "sliver last")
    }

    /// Cut fillers open and close the clip, touching the words outside it: the windows absorb them up to the clip's edges.
    @Test func cutFillersAtTheClipsEdgesAreAbsorbed() throws {
        let take = try Self.take(["~um"] + Self.clipScript + ["~yeah"], before: 0, after: 0)
        let script = try #require(WholeClipScript.assemble(words: take.clip, cutWordIds: take.cuts, voiceHunks: []))
        let hunks = script.hunks(words: take.clip, cutWordIds: take.cuts, cutPauseIds: [])
        var windows: [VoiceLabWindow] = []
        for result in VoiceLabWindowPlanner.placeAll(project: take.project, scope: Self.scope, envelope: take.envelope, hunks: hunks) {
            if case .placed(_, _, let window) = result { windows.append(window) } else { Issue.record("refused: \(result)") }
        }
        #expect(windows.first?.firstWordId == "w0" && windows.last?.lastWordId == "w61")
        Self.validateInBothScopes(take, windows, "cut fillers")
        let patch = try VoiceLabWindowPlanner.place(project: take.project, scope: Self.scope, envelope: take.envelope,
                                                    firstWordId: "w1", lastWordId: "w1")
        #expect(patch.firstWordId == "w0" && patch.leftSeam.time == take.clip[0].start)
        Self.validateInBothScopes(take, [patch], "cut filler patch")
    }

    /// The full take holds the seam as prepare does: with the word before the clip cut, the fade's outer half lies in the
    /// source before that cut. With every word before the clip cut and the take opening on them, nothing renders beside the
    /// seam in the full take, where a fade seam is refused, so the window is refused with the full take's numbers.
    @Test func theFullTakeDecidesTheSeam() throws {
        let acrossCut = try Self.take(Self.clipScript, before: 0, after: 0.5, cutOutside: ["pre2"])
        let window = try VoiceLabWindowPlanner.place(project: acrossCut.project, scope: Self.scope, envelope: acrossCut.envelope,
                                                     firstWordId: "w0", lastWordId: "w0")
        #expect(window.leftSeam.kind == .hard)
        Self.validateInBothScopes(acrossCut, [window], "across a cut")

        var opening = try Self.take(Self.clipScript, before: 0, after: 0.5)
        let shift = try #require(opening.project.transcript?.words.first?.start)
        let shifted = (opening.project.transcript?.words ?? []).map {
            TimedWord(id: $0.id, text: $0.text, kind: $0.kind, start: $0.start - shift, end: $0.end - shift)
        }
        opening.project.transcript?.words = shifted
        let frames = Int(opening.project.media.source.durationSeconds * 100) + 1
        var levels = [Float](repeating: 0.0005, count: frames)
        for word in opening.project.transcript?.words ?? [] {
            for frame in Int(word.start * 100)..<min(frames, Int(word.end * 100)) { levels[frame] = 0.1 }
        }
        opening.envelope = AudioEnvelope(sampleRate: 48_000, levels: levels)
        let placed = try VoiceLabWindowPlanner.place(project: opening.project, scope: Self.scope, envelope: opening.envelope,
                                                     firstWordId: "w0", lastWordId: "w0")
        Self.validateInBothScopes(opening, [placed], "take opening on the words before the clip")
        opening.project.edits.cutWordIds += ["pre0", "pre1", "pre2"]
        #expect(throws: VoiceLabGeometryError.seamFadeCrossesCut(incoming: true, needed: 288, available: 0)) {
            try VoiceLabWindowPlanner.place(project: opening.project, scope: Self.scope, envelope: opening.envelope,
                                            firstWordId: "w0", lastWordId: "w0")
        }
        // A fade seam on the full take's first piece is still refused; the clip still renders it as its output edge.
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) {
            try VoiceLabRenderContract.validatePlacement(opening.project, scope: .full, window: placed)
        }
        try VoiceLabRenderContract.validatePlacement(opening.project, scope: Self.scope, window: placed)
    }

    /// The render contract plays a clip's edge seam as an output edge only in a clip scope, only for the first or last piece,
    /// and only away from the take's edges. The full take keeps the seam's fade and its source beside it.
    @Test func prepareRendersTheEdgeSeamInBothScopes() throws {
        let take = try Self.take(.both)
        let window = try VoiceLabWindowPlanner.place(project: take.project, scope: Self.scope, envelope: take.envelope,
                                                     firstWordId: "w0", lastWordId: "w59")
        let clipPlan = try VoiceLabOutputPlanner.build(take.project, scope: Self.scope, placing: [(window, "pending")])
        #expect(clipPlan.pieces.count == 1 && clipPlan.pieces[0].segmentId == "pending")
        let fullPlan = try VoiceLabOutputPlanner.build(take.project, scope: .full, placing: [(window, "pending")])
        let index = try #require(fullPlan.pieces.firstIndex { $0.segmentId == "pending" })
        #expect(fullPlan.pieces[index - 1].kind == .source && fullPlan.pieces[index + 1].kind == .source)
        Self.validateInBothScopes(take, [window], "whole clip window")
    }
}
