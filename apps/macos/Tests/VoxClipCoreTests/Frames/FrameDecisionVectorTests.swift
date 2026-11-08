import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/clip-frames/decision-cases.json (ADR-R48, ai.md §19), which
/// tools/fixtures/clip-frames/generate_frame_decisions.py writes and the Windows Core replays too (C# FrameDecisionVectorTests).
/// Inputs are decoded and answers encoded in the Mac's JSON shape, compared with numbers within 1e-12.
@Suite(.offlineFixtures) struct FrameDecisionVectorTests {
    static let path = "fixtures/clip-frames/decision-cases.json"
    static let sections = ["eyes", "looks", "openings", "covers", "crops", "screens", "blurSpans", "summaries", "imageTokens", "samplings",
                           "openingTimes", "decimals"]

    static func vectors() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(path)) }
    static func rows(_ key: String) throws -> [JSONValue] { try vectors()[ai: key].aiArray }

    static func decode<Value: Decodable>(_ value: JSONValue, as type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    static func encoded(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encoder().encode(value))
    }

    static func optional<Value: Encodable>(_ value: Value?) throws -> JSONValue {
        guard let value else { return .null }
        return try encoded(value)
    }

    static func words(_ value: JSONValue) -> [TimedWord] {
        value.aiArray.map { item in
            TimedWord(id: item[ai: "id"].aiString ?? "", text: item[ai: "text"].aiString ?? "",
                      kind: item[ai: "kind"].aiString == "event" ? .event : .word,
                      start: item[ai: "start"].aiDouble ?? 0, end: item[ai: "end"].aiDouble ?? 0)
        }
    }

    static func clip(_ words: [TimedWord], _ row: JSONValue) throws -> FrameClip {
        let cut = Set(row[ai: "cut"].aiArray.compactMap(\.aiString))
        return try #require(FrameClip(words: words, first: row[ai: "first"].aiInt ?? -1, last: row[ai: "last"].aiInt ?? -1, cutWordIds: cut))
    }

    static func baseline(_ row: JSONValue) -> Double? { row[ai: "pitchBaseline"].aiDouble }

    /// Equal JSON: the same keys, arrays of the same length, equal strings and booleans, numbers within 1e-12.
    static func same(_ expected: JSONValue, _ actual: JSONValue) -> Bool {
        switch (expected, actual) {
        case let (.object(left), .object(right)):
            return Set(left.keys) == Set(right.keys) && left.allSatisfy { key, value in same(value, right[key] ?? .null) }
        case let (.array(left), .array(right)):
            return left.count == right.count && zip(left, right).allSatisfy { same($0, $1) }
        case let (.number(left), .number(right)):
            return abs(left - right) <= 1e-12
        default:
            return expected == actual
        }
    }

    @Test func theFileHasItsSchemaKeysAndCount() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: FixtureLoader.data(Self.path)) as? [String: Any])
        #expect(Set(object.keys) == Set(["schema", "description", "constants", "caseCount", "counts", "transcripts", "analysis"] + Self.sections))
        let vectors = try Self.vectors()
        #expect(vectors[ai: "schema"].aiString == "voxclip-frame-decision-cases/1")
        #expect(vectors[ai: "caseCount"].aiInt == 136)
        let counts = Self.sections.map { vectors[ai: $0].aiArray.count }
        #expect(counts == [11, 11, 22, 11, 11, 12, 7, 6, 6, 9, 6, 24])
        #expect(counts.reduce(0, +) == 136)
        #expect(Self.sections.allSatisfy { vectors[ai: "counts"][ai: $0].aiInt == vectors[ai: $0].aiArray.count })
        #expect(vectors[ai: "counts"].aiObject.map { Set($0.keys) } == Set(Self.sections))
        #expect(vectors[ai: "transcripts"].aiObject.map { Set($0.keys) } == ["thirty-sentences", "run-on", "mixed", "empty"])
    }

    @Test func theConstantsAreTheCores() throws {
        let expected: [String: Double] = [
            "closedBelow": EyeAspect.closedBelow, "goodQuality": FrameFace.goodQuality, "yawLimit": FrameFace.yawLimit,
            "pitchLimit": FrameFace.pitchLimit, "startTolerance": OpeningFrame.startTolerance, "qualityMargin": OpeningFrame.qualityMargin,
            "openingSpan": FrameSampling.openingSpan, "openingStep": FrameSampling.openingStep, "deadZone": FaceFollowCrop.deadZone,
            "maximumSpeed": FaceFollowCrop.maximumSpeed, "medianWindow": Double(FaceFollowCrop.medianWindow), "blinkWindow": CoverFrame.blinkWindow,
            "qualityWeight": CoverFrame.qualityWeight, "centredWeight": CoverFrame.centredWeight, "eyesWeight": CoverFrame.eyesWeight,
            "facingWeight": CoverFrame.facingWeight, "minimumBoxes": Double(FrameScreens.minimumBoxes),
            "minimumCoverage": FrameScreens.minimumCoverage, "minimumArea": FrameScreens.minimumArea,
            "clusterBoxes": Double(FrameScreens.clusterBoxes), "minimumOverlap": FrameBlurSpans.minimumOverlap,
            "blurMaxGap": ClipFrameCandidates.blurMaxGap, "blurPad": ClipFrameCandidates.blurPad,
            "maximumCovers": Double(ClipFrameCandidates.maximumCovers), "maximumSentences": Double(FrameSampling.maximumSentences),
            "maximumSentenceWords": Double(FrameSampling.maximumSentenceWords), "pixelsPerToken": FrameSheet.pixelsPerToken,
        ]
        let constants = try Self.vectors()[ai: "constants"]
        #expect(constants.aiObject.map { Set($0.keys) } == Set(expected.keys))
        for (key, value) in expected { #expect(constants[ai: key].aiDouble == value, "\(key)") }
    }

    @Test func eyesReplay() throws {
        for row in try Self.rows("eyes") {
            let id = row[ai: "id"].aiString ?? ""
            if row[ai: "kind"].aiString == "ratio" {
                let points = row[ai: "points"].aiArray.map { (x: $0.aiArray[0].aiDouble ?? .nan, y: $0.aiArray[1].aiDouble ?? .nan) }
                #expect(EyeAspect.ratio(points) == row[ai: "expect"].aiDouble, "\(id)")
            } else {
                let state = EyeAspect.state(left: row[ai: "left"].aiDouble, right: row[ai: "right"].aiDouble)
                #expect(state.rawValue == row[ai: "expect"].aiString, "\(id)")
            }
        }
    }

    @Test func looksReplay() throws {
        for row in try Self.rows("looks") {
            let frame: FrameObservation = try Self.decode(row[ai: "frame"])
            #expect(frame.isClearLook(pitchBaseline: Self.baseline(row)) == row[ai: "expect"][ai: "clearLook"].aiBool, "\(row[ai: "id"])")
            #expect(frame.face?.facesCamera(pitchBaseline: Self.baseline(row)) == row[ai: "expect"][ai: "facing"].aiBool, "\(row[ai: "id"])")
        }
    }

    @Test func openingsReplay() throws {
        for row in try Self.rows("openings") {
            let id = row[ai: "id"].aiString ?? ""
            let clip = try Self.clip(Self.words(row[ai: "words"]), row)
            let shape: JSONValue = .object(["start": .number(clip.start), "end": .number(clip.end), "leadInFloor": .number(clip.leadInFloor),
                                            "kept": .array(clip.kept.map { .number(Double($0)) })])
            #expect(Self.same(row[ai: "expect"][ai: "clip"], shape), "\(id) clip")
            let scan: [FrameObservation] = try Self.decode(row[ai: "scan"])
            let choice = try Self.optional(OpeningFrame.choose(clip, scan: scan, pitchBaseline: Self.baseline(row)))
            #expect(Self.same(row[ai: "expect"][ai: "choice"], choice), "\(id): \(choice)")
        }
    }

    @Test func coversReplay() throws {
        for row in try Self.rows("covers") {
            let id = row[ai: "id"].aiString ?? ""
            let frames: [FrameObservation] = try Self.decode(row[ai: "frames"])
            let baseline = Self.baseline(row)
            let scores: JSONValue = .array(frames.map { frame in
                CoverFrame.score(frame, neighbours: frames, pitchBaseline: baseline).map(JSONValue.number) ?? .null
            })
            #expect(Self.same(row[ai: "expect"][ai: "scores"], scores), "\(id) scores")
            #expect(Self.same(row[ai: "expect"][ai: "pick"], try Self.optional(CoverFrame.pick(frames, pitchBaseline: baseline))), "\(id) pick")
            let sheet = frames.enumerated().map { FrameSheetFrame(index: $0.offset + 1, observation: $0.element, jpeg: Data(), width: 320, height: 180) }
            #expect(Self.same(row[ai: "expect"][ai: "candidates"], try Self.encoded(ClipFrameCandidates.cover(sheet, pitchBaseline: baseline))), "\(id) candidates")
        }
    }

    @Test func cropsReplay() throws {
        for row in try Self.rows("crops") {
            let samples: [(time: Double, face: ClipEffect.Rect?)] = try row[ai: "samples"].aiArray.map { sample in
                (sample[ai: "time"].aiDouble ?? .nan, sample[ai: "face"] == .null ? nil : try Self.decode(sample[ai: "face"]))
            }
            let plan = FaceFollowCrop.plan(samples, sourceAspect: row[ai: "sourceAspect"].aiDouble ?? 0, targetAspect: row[ai: "targetAspect"].aiDouble ?? 0)
            #expect(Self.same(row[ai: "expect"], try Self.optional(plan)), "\(row[ai: "id"])")
        }
    }

    @Test func screensReplay() throws {
        for row in try Self.rows("screens") {
            let rectangles: [ClipEffect.Rect] = try Self.decode(row[ai: "rectangles"])
            let texts: [ClipEffect.Rect] = try Self.decode(row[ai: "texts"])
            #expect(Self.same(row[ai: "expect"], try Self.encoded(FrameScreens.detect(rectangles: rectangles, texts: texts))), "\(row[ai: "id"])")
        }
    }

    @Test func blurSpansReplay() throws {
        for row in try Self.rows("blurSpans") {
            let id = row[ai: "id"].aiString ?? ""
            let frames: [FrameObservation] = try Self.decode(row[ai: "frames"])
            let spans = FrameBlurSpans.merge(frames, maxGap: row[ai: "maxGap"].aiDouble ?? 0, pad: row[ai: "pad"].aiDouble ?? 0)
            #expect(Self.same(row[ai: "expect"][ai: "spans"], try Self.encoded(spans)), "\(id) spans")
            let candidates = ClipFrameCandidates.blur(frames, clipStart: row[ai: "clipStart"].aiDouble ?? 0, clipEnd: row[ai: "clipEnd"].aiDouble ?? 0)
            #expect(Self.same(row[ai: "expect"][ai: "candidates"], try Self.encoded(candidates)), "\(id) candidates")
        }
    }

    @Test func summariesReplay() throws {
        for row in try Self.rows("summaries") {
            let frames: [FrameObservation] = try Self.decode(row[ai: "frames"])
            let sheet = FrameSheet(frames: frames.enumerated().map {
                FrameSheetFrame(index: $0.offset + 1, observation: $0.element, jpeg: Data([1, 2, 3]), width: 320, height: 180)
            })
            #expect(sheet.summary(pitchBaseline: Self.baseline(row)) == row[ai: "expect"][ai: "summary"].aiString, "\(row[ai: "id"])")
            #expect(sheet.estimatedSummaryTokens(pitchBaseline: Self.baseline(row)) == row[ai: "expect"][ai: "summaryTokens"].aiInt, "\(row[ai: "id"])")
        }
        for row in try Self.rows("imageTokens") {
            #expect(FrameSheet.imageTokens(width: row[ai: "width"].aiInt ?? 0, height: row[ai: "height"].aiInt ?? 0) == row[ai: "expect"].aiInt)
        }
    }

    @Test func samplingsReplay() throws {
        let transcripts = try Self.vectors()[ai: "transcripts"]
        for (name, transcript) in transcripts.aiObject ?? [:] {
            #expect(Self.same(transcript[ai: "video"], try Self.encoded(FrameSampling.videoSamples(Self.words(transcript[ai: "words"])))), "\(name)")
        }
        for row in try Self.rows("samplings") {
            let id = row[ai: "id"].aiString ?? ""
            let clip = try Self.clip(Self.words(transcripts[ai: row[ai: "transcript"].aiString ?? ""][ai: "words"]), row)
            let limit = row[ai: "limit"].aiInt ?? 0
            let video = FrameSampling.videoSamples(clip.words)
            #expect(Self.same(row[ai: "expect"][ai: "sentences"], try Self.encoded(FrameSampling.sentenceSamples(clip, limit: limit))), "\(id) sentences")
            #expect(Self.same(row[ai: "expect"][ai: "clip"], try Self.encoded(FrameSampling.clipSamples(video, clip: clip, limit: limit))), "\(id) clip")
        }
        for row in try Self.rows("openingTimes") {
            #expect(Self.same(row[ai: "expect"], try Self.encoded(FrameSampling.openingTimes(start: row[ai: "start"].aiDouble ?? 0))))
        }
    }

    /// The two decimals of the summary and the frames block: the shortest decimal rounded half to even (not printf's).
    @Test func decimalsAreTheMacs() throws {
        for row in try Self.rows("decimals") {
            let value = try #require(row[ai: "value"].aiDouble)
            #expect(FrameSheetFrame.seconds(value) == row[ai: "expect"].aiString, "\(value)")
            #expect(FrameSheetFrame.fixed(value) == row[ai: "expect"].aiString, "\(value)")
        }
        #expect(FrameAnalysisCache.pass(tolerance: 0.25) == "0.250")
    }

    /// The fixture's analysis-v2.json is the Mac's: the cache reads it, and writes the same keys and values back.
    @Test func theAnalysisSampleIsTheMacsFile() async throws {
        let sample = try Self.vectors()[ai: "analysis"]
        #expect(sample[ai: "fileName"].aiString == FrameAnalysisCache.fileName)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoxClip-frame-vectors-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": folder.path])
        let key = String(repeating: "ab", count: 32)
        let frames = try CacheStore(locations: locations).entryDirectory(contentKey: key).appendingPathComponent(FrameAnalysisCache.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let file = frames.appendingPathComponent(FrameAnalysisCache.fileName)
        try JSONEncoder().encode(sample[ai: "file"]).write(to: file)
        let cache = FrameAnalysisCache(locations: locations)
        let expected: [String: FrameObservation] = try Self.decode(sample[ai: "file"][ai: "frames"])
        var read: [String: [(requested: Double, observation: FrameObservation)]] = [:]
        for pass in ["0.250", "0.033"] {
            for (millisecond, observation) in cache.observations(contentKey: key, pass: pass) {
                #expect(expected["\(pass):\(millisecond)"] == observation)
                read[pass, default: []].append((Double(millisecond) / 1000, observation))
            }
        }
        #expect(read.values.map(\.count).reduce(0, +) == expected.count)
        // Written back by the cache itself: the same keys and values.
        try FileManager.default.removeItem(at: file)
        for (pass, items) in read { await cache.store(items, contentKey: key, pass: pass) }
        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        #expect(written == sample[ai: "file"], "the cache writes exactly the fixture's keys and values")

        let analysis: FrameAnalysis = try Self.decode(sample[ai: "frameAnalysis"])
        #expect(try Self.encoded(analysis) == sample[ai: "frameAnalysis"])
        #expect(analysis.version == FrameAnalysis.version)
        #expect(analysis.pitchBaseline == sample[ai: "pitchBaseline"].aiDouble)
    }

    /// The plan request's frames (shared/fixtures/autopilot/plan-frames-cases.json) come out of the decisions.
    @Test func thePlanRequestFramesComeFromTheDecisions() throws {
        let plan = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/autopilot/plan-frames-cases.json"))[ai: "frames"]
        let row = try #require(try Self.rows("summaries").first { $0[ai: "id"].aiString == "the-plan-request-summary" })
        let frames: [FrameObservation] = try Self.decode(row[ai: "frames"])
        let sheet = FrameSheet(frames: frames.enumerated().map { FrameSheetFrame(index: $0.offset + 1, observation: $0.element, jpeg: Data(), width: 320, height: 180) })
        #expect(sheet.summary(pitchBaseline: nil) == plan[ai: "summary"].aiString)
        let blur = ClipFrameCandidates.blur(frames, clipStart: 0, clipEnd: 15)
        #expect(blur.map(\.id) == plan[ai: "blur"].aiArray.compactMap { $0[ai: "id"].aiString })
        #expect(blur.map(\.start) == plan[ai: "blur"].aiArray.compactMap { $0[ai: "start"].aiDouble })
        #expect(blur.map(\.end) == plan[ai: "blur"].aiArray.compactMap { $0[ai: "end"].aiDouble })
        for (candidate, item) in zip(blur, plan[ai: "blur"].aiArray) {
            let box = item[ai: "rect"].aiArray.compactMap(\.aiDouble)
            #expect(zip([candidate.rect.x, candidate.rect.y, candidate.rect.width, candidate.rect.height], box).allSatisfy { abs($0 - $1) < 1e-9 })
        }
        let cover = ClipFrameCandidates.cover(sheet.frames, pitchBaseline: nil)
        #expect(cover.map { "\($0.id):\($0.frame)" } == plan[ai: "cover"].aiArray.map { "\($0[ai: "id"].aiString ?? ""):\($0[ai: "frame"].aiInt ?? 0)" })
    }
}
