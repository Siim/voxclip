import Foundation
import Testing
@testable import VoxClipCore

/// The user's own microphone takes (voice-lab.md §8.13) replayed on Mac from `recorded-take-cases.json`
/// (`voxclip-voice-lab-recorded-take-cases/1`, generate_render_recorded.py) and its three projects. The Windows Core
/// replays the same files; their expected values were written from Mac code, so this checks them against it: a
/// `recorded` segment validates, saves unchanged and renders under its own kind, only its lip sync is disclosed, its
/// recognized words are captioned, accepting it needs no voice reference, changed recipes are refused with the shared
/// error, and the recipe builder makes the recipe the fixture stores.
@Suite(.offlineFixtures) struct VoiceLabRecordedTakeReplayTests {
    struct Cases: Decodable {
        struct Disclosure: Decodable {
            let required: Bool; let kinds: [String]; let aiSeconds: Double; let persistent: Bool
            let labelIntervals: [[Double]]; let text: String?
        }
        struct AISegment: Decodable { let segmentId: String; let kind: String }
        struct Caption: Decodable { let id: String; let text: String; let start: Double; let end: Double }
        struct Render: Decodable {
            let id: String; let project: String; let disclosure: Disclosure; let aiSegments: [AISegment]; let captions: [Caption]
        }
        struct AcceptAll: Decodable { let id: String; let project: String; let segment: String; let kind: String; let error: String? }
        struct Invalid: Decodable { let id: String; let error: String; let project: String; let segment: String }
        let schema: String; let caseCount: Int
        let renders: [Render]; let acceptAll: [AcceptAll]; let invalid: [Invalid]
    }
    private static let path = "fixtures/voice-lab/recorded-take-cases.json"
    private let cases: Cases
    init() throws { cases = try JSONDecoder().decode(Cases.self, from: FixtureLoader.data(Self.path)) }

    private func raw(_ project: String) throws -> Data { try FixtureLoader.data("fixtures/voice-lab/\(project)") }
    private func dictionary(_ data: Data) throws -> NSDictionary { try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary) }
    private func code(_ error: (any Error)?) -> String? { (error as? VoiceLabProjectError).map { String(describing: $0) } }

    @Test func casesHaveTheirSchemaAndCount() throws {
        let keys = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data(Self.path)) as? [String: Any]).keys
        #expect(Set(keys) == ["schema", "caseCount", "renders", "acceptAll", "invalid"])
        #expect(cases.schema == "voxclip-voice-lab-recorded-take-cases/1" && cases.caseCount == 17)
        #expect(cases.renders.count + cases.acceptAll.count + cases.invalid.count == cases.caseCount)
        #expect(cases.renders.map(\.id) == ["recorded-source", "recorded-lipsync", "recorded-beside-tts"])
    }

    @Test func recordedProjectsValidateSaveUnchangedAndRender() throws {
        for row in cases.renders {
            let source = try raw(row.project)
            let project = try JSONProjectStore.decode(source)
            try VoiceLabProject.validate(project)
            try VoiceLabRenderValidation.validate(project)
            let saved = try JSONProjectStore.encode(project)
            #expect(try dictionary(source) == dictionary(saved), "\(row.id): a save changed the project")
            #expect(try JSONProjectStore.encode(JSONProjectStore.decode(saved)) == saved, "\(row.id)")
            #expect(project.voiceLab.segments.contains { $0.kind == .recorded }, "\(row.id)")

            let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
            try prepared.verify(project: project, scope: .full, labelPosition: .topRight)
            let disclosure = prepared.disclosure, expected = row.disclosure
            #expect(disclosure.required == expected.required && disclosure.kinds == expected.kinds, "\(row.id)")
            #expect(abs(disclosure.outputAISeconds - expected.aiSeconds) < 1e-9, "\(row.id): \(disclosure.outputAISeconds)")
            #expect(disclosure.persistent == expected.persistent, "\(row.id)")
            let intervals = expected.labelIntervals.map { VoiceLabLabelInterval(start: $0[0], end: $0[1]) }
            #expect(disclosure.intervals == intervals, "\(row.id): \(disclosure.intervals)")
            #expect(disclosure.postText == expected.text, "\(row.id)")

            // Every selected take is rendered and listed under its own kind, the recorded one included.
            let kinds = Dictionary(uniqueKeysWithValues: project.voiceLab.segments.map { ($0.id, $0.kind.rawValue) })
            #expect(prepared.selectedSegmentRecipes.map(\.segmentId) == row.aiSegments.map(\.segmentId), "\(row.id)")
            #expect(prepared.selectedSegmentRecipes.map { kinds[$0.segmentId] } == row.aiSegments.map(\.kind), "\(row.id)")
            // The export label follows the segments' own AI rule.
            #expect(project.voiceLab.segments.contains(where: \.isAIModified) == expected.required, "\(row.id)")

            // Captions are the recognized words of a recorded take, placed as a generated take's words are.
            let captions = prepared.outputPlan.captions.filter { $0.id.contains(":word:") }
            #expect(captions.map(\.id) == row.captions.map(\.id) && captions.map(\.text) == row.captions.map(\.text), "\(row.id)")
            for (caption, item) in zip(captions, row.captions) {
                #expect(abs(caption.start - item.start) < 1e-9 && abs(caption.end - item.end) < 1e-9, "\(row.id) \(item.id): \(caption)")
            }
        }
    }

    @Test func acceptingARecordedTakeNeedsNoVoiceReference() throws {
        for row in cases.acceptAll {
            let source = try raw(row.project)
            let target = try JSONProjectStore.decode(source)
            var segment = try #require(target.voiceLab.segments.first { $0.id == row.segment })
            if row.kind == "tts" {
                // The same take as a cloned one: generated words and the same own-voice recipe, with no consent.
                func synthetic(_ words: [VoiceLabWord]?) -> [VoiceLabWord]? {
                    words?.map { VoiceLabWord(text: $0.text, start: $0.start, end: $0.end, synthetic: true) }
                }
                segment.kind = .tts
                segment.words = synthetic(segment.words)
                for index in segment.candidates.indices {
                    let words = synthetic(segment.candidates[index].recipe?.words)
                    segment.candidates[index].recipe?.words = words
                }
            } else {
                #expect(row.kind == "recorded")
            }
            let assetIDs = Set(segment.candidates.map(\.assetId))
            let assets = (target.voiceLab.assets ?? []).filter { assetIDs.contains($0.id) }
            var before = target
            before.voiceLab.segments.removeAll { $0.id == row.segment }
            before.voiceLab.assets?.removeAll { assetIDs.contains($0.id) }
            try VoiceLabProject.validate(before)
            #expect(before.voiceLab.voices?.isEmpty ?? true, "\(row.id)")
            let command = VoiceLabEditCommand.acceptAll(segments: [segment], assets: assets, voice: nil)
            if let error = row.error {
                var direct: (any Error)?, edit: (any Error)?
                do { _ = try VoiceLabProject.acceptAll([segment], assets: assets, into: before) } catch { direct = error }
                do { _ = try command.applying(to: before) } catch { edit = error }
                #expect(code(direct) == error && code(edit) == error, "\(row.id): \(String(describing: direct)) \(String(describing: edit))")
                continue
            }
            let accepted = try command.applying(to: before)
            #expect(accepted.voiceLab.voices?.isEmpty ?? true, "\(row.id)")
            #expect(try dictionary(source) == dictionary(JSONProjectStore.encode(accepted)), "\(row.id): accepting changed the recorded take")
        }
    }

    @Test func changedRecordedRecipesAreRefusedWithTheSharedError() throws {
        let root = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data(Self.path)) as? [String: Any])
        let rows = try #require(root["invalid"] as? [[String: Any]])
        #expect(rows.count == cases.invalid.count)
        func setting(_ node: Any, _ path: ArraySlice<String>, _ value: Any) throws -> Any {
            guard let head = path.first else { return value }
            if var array = node as? [Any] {
                let index = try #require(Int(head))
                array[index] = try setting(array[index], path.dropFirst(), value)
                return array
            }
            var object = try #require(node as? [String: Any])
            object[head] = try setting(object[head] ?? NSNull(), path.dropFirst(), value)
            return object
        }
        for (row, json) in zip(cases.invalid, rows) {
            var document = try #require(JSONSerialization.jsonObject(with: raw(row.project)) as? [String: Any])
            var voice = try #require(document["voiceLab"] as? [String: Any])
            var segments = try #require(voice["segments"] as? [[String: Any]])
            let position = try #require(segments.firstIndex { $0["id"] as? String == row.segment })
            var segment: Any = segments[position]
            for (path, value) in try #require(json["set"] as? [String: Any]) {
                segment = try setting(segment, path.split(separator: "/").map(String.init)[...], value)
            }
            segments[position] = try #require(segment as? [String: Any])
            voice["segments"] = segments; document["voiceLab"] = voice
            var refusal: (any Error)?
            do {
                let project = try JSONProjectStore.decode(JSONSerialization.data(withJSONObject: document))
                try VoiceLabProject.validate(project)
                try VoiceLabRenderValidation.validate(project)
            } catch { refusal = error }
            #expect(code(refusal) == row.error, "\(row.id): \(String(describing: refusal))")
        }
    }

    /// The recipe builder makes the recorded recipe the fixture stores, from the take Mac records (ClipTakePlan's
    /// microphone path): no receipt, quote or speaker score, the recognizer as model, the take's own request ID.
    @Test func theRecipeBuilderMakesTheStoredRecordedRecipe() throws {
        let project = try JSONProjectStore.decode(raw("recorded-render-v3.voxclip"))
        let stored = try #require(project.voiceLab.segments.first)
        let saved = try #require(stored.candidates[0].recipe)
        let window = VoiceLabWindow(firstWordId: stored.replace.firstWordId, lastWordId: stored.replace.lastWordId,
            leftBridgeWordIds: [], rightBridgeWordIds: [], start: 2.5, end: 3.2, startSample: 2500, endSample: 3200,
            leftSeam: .init(kind: .gap, time: 2.5, sample: 2500, fadeSamples: 20), rightSeam: .init(kind: .gap, time: 3.2, sample: 3200, fadeSamples: 20))
        // The fitted words carry the alignment's synthetic flag; the recorded recipe stores them as heard.
        let words = try #require(saved.words).map { VoiceLabWord(text: $0.text, start: $0.start, end: $0.end, synthetic: true) }
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 2400, trimEndFrame: 19200, windowStart: 2.5, windowEnd: 3.2, windowStartSample: 2500, windowEndSample: 3200,
            outputFrames: 16800, words: words)
        let input = VoiceLabTakeInput(text: try #require(stored.text?.new), modelID: "own-take", recordID: "own-take", language: "en", seed: 7,
            contentKey: project.media.source.contentKey, source: [], sourceSampleRate: 1000, items: try #require(project.transcript).words,
            window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let take = VoiceLabTakeAudio(sampleRate: 24000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0,
            roomTone: saved.roomTone, fit: .exact(plan))
        let id = try #require(saved.provenance.requestId.flatMap(UUID.init(uuidString:)))
        let row = VoiceLabTakeRow(id: id, index: 0, seed: saved.seed, audio: take,
            qa: VoiceLabTakeQAResult(values: stored.qa, failures: []), score: stored.candidates[0].score)
        var audio = saved.audio; audio.stretch = 1
        let asset = try #require(project.voiceLab.assets?.first { $0.id == saved.audio.assetId })
        let published = VoiceLabPublishedTake(assets: [asset], audio: audio, outDuration: saved.outDuration, words: words, chunks: saved.chunks)
        let createdAt = saved.provenance.createdAt
        let candidate = try VoiceLabRecordedTake.candidate(row: row, input: input, published: published,
            model: saved.provenance.model, createdAt: createdAt, videoChoice: .source)
        // The fixture's stretch is the passage fixture's 0.9999999999999999; a recorded take is never stretched.
        var expected = saved; expected.audio.stretch = 1
        #expect(candidate.recipe == expected)
        #expect(candidate.assetId == stored.candidates[0].assetId && candidate.score == stored.candidates[0].score)

        let built = try VoiceLabRecordedTake.segment(id: stored.id, candidate: candidate, input: input, plan: plan)
        #expect(built.kind == .recorded && built.replace == stored.replace && built.text == stored.text)
        #expect(built.words == stored.words && built.provenance == stored.provenance && built.qa == stored.qa)
        #expect(built.outDuration == stored.outDuration && built.scope == stored.scope)

        var empty = project
        empty.voiceLab.segments = []; empty.voiceLab.assets = []
        let accepted = try VoiceLabEditCommand.acceptAll(segments: [built], assets: [asset], voice: nil).applying(to: empty)
        #expect(accepted.voiceLab.segments.map(\.kind) == [.recorded] && (accepted.voiceLab.voices?.isEmpty ?? true))
        #expect(try VoiceLabRenderContract.prepare(accepted, scope: .full, labelPosition: .topRight).disclosure.required == false)
    }
}
