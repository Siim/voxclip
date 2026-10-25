import Foundation
import Testing
@testable import VoxClipCore

struct FixtureValue {
    let value: JSONValue
    init(_ value: JSONValue) { self.value = value }
    subscript(_ key: String) -> FixtureValue { if case .object(let object) = value { return FixtureValue(object[key] ?? .null) }; return FixtureValue(.null) }
    var array: [FixtureValue] { if case .array(let array) = value { return array.map(FixtureValue.init) }; return [] }
    var object: [String: JSONValue] { if case .object(let object) = value { return object }; return [:] }
    var string: String { if case .string(let text) = value { return text }; return "" }
    var bool: Bool { value == .bool(true) }
    var number: Double {
        if case .number(let number) = value { return number }
        switch string { case "NaN": return .nan; case "Infinity": return .infinity; case "-Infinity": return -.infinity; default: return 0 }
    }
    var int: Int { Int(number) }
    var isNull: Bool { value == .null }
    static func encoded<Value: Encodable>(_ value: Value) throws -> FixtureValue {
        FixtureValue(try JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encoder().encode(value)))
    }
    static func number(_ value: Double) -> FixtureValue { FixtureValue(.number(value)) }
}

@Suite struct EditingFixtures {
    static func discover() throws -> [URL] {
        let directory = try FixtureLoader.sharedRoot().appendingPathComponent("fixtures/editing")
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }
    static let files = (try? discover()) ?? []
    static func fixtureKind(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return FixtureValue(value)["kind"].string
    }
    static let normativeFiles = files.filter { fixtureKind($0) != "caption-text" }
    static let informativeFiles = files.filter { fixtureKind($0) == "caption-text" }

    @Test func discovery() throws {
        #expect(try !Self.discover().isEmpty)
        #expect(Self.files.count == (try Self.discover()).count)
        #expect(Self.normativeFiles.count + Self.informativeFiles.count == Self.files.count)
    }

    @Test(.disabled("editing §11.1: caption-text is informative and skipped by editing suites"), arguments: informativeFiles)
    func informativeCaptionText(_ file: URL) {
        #expect(Self.fixtureKind(file) == "caption-text")
    }

    @Test(arguments: normativeFiles) func fixture(_ file: URL) throws {
        let fixture = FixtureValue(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)))
        let root = try FixtureLoader.sharedRoot()
        let fixtureRoot = root.appendingPathComponent("fixtures/editing").path + "/"
        #expect(fixture["schema"].string == "voxclip-editing-fixture/1")
        #expect(fixture["id"].string == String(file.path.dropFirst(fixtureRoot.count).dropLast(5)))
        let input = fixture["input"], expected = fixture["expected"]
        let tolerance = expected["tolerance"].isNull ? 1e-9 : expected["tolerance"].number
        switch fixture["kind"].string {
        case "edit-plan", "join-fades": try runPlan(input, expected, tolerance: tolerance)
        case "pause-detection":
            let pauses = try detectPauses(words(input["words"]), thresholdSeconds: input["hasDecodedAudio"].bool ? 0.8 : 1)
            compare(.init(.array(pauses.map(pauseValue))), expected["pauses"], tolerance: tolerance)
        case "pause-label":
            compare(.init(.array(input["durations"].array.map { .string("pause " + toFixed1($0.number) + "s") })), expected["labels"])
        case "filler-detection":
            compare(.init(.array(try input["words"].array.map { .bool(try isFillerText($0.string)) })), expected["matches"])
        case "transcript-alignment":
            let output = try alignTranscriptWords(rawWords(input["words"], wordKey: "word"), finalText: input["finalText"].string)
            compare(try rawValues(output, confidence: false), expected["words"], tolerance: tolerance)
        case "estimated-words":
            compare(try rawValues(estimateTranscriptWords(input["text"].string, start: input["start"].number, end: input["end"].number), confidence: true), expected["words"], tolerance: tolerance)
        case "text-whitespace":
            compare(.init(.array(input["strings"].array.map { .string(EditingPrimitives.jsTrim($0.string)) })), expected["trim"])
            compare(.init(.array(input["strings"].array.map { .array(EditingPrimitives.splitWords($0.string).map(JSONValue.string)) })), expected["split"])
        case "clip-range":
            let items = words(input["words"])
            let ranges = try input["ranges"].array.map { range -> JSONValue in
                let start = range.array[0].int, end = range.array[1].int
                let times = try clipTimes(items, startIndex: start, endIndex: end)
                return .object(["startWord": .number(Double(start)), "endWord": .number(Double(end)), "start": .number(times.start), "end": .number(times.end)])
            }
            compare(.init(.array(ranges)), expected["ranges"], tolerance: tolerance)
        case "word-boundaries", "word-tightening", "unlabeled-speech":
            let items = words(input["words"]), envelope = syntheticEnvelope(input["audio"])
            let output: [TimedWord]
            switch fixture["kind"].string {
            case "word-boundaries": output = try refineWordBoundaries(items, envelope: envelope)
            case "word-tightening": output = EditingImport.tightenIntoSound(items, envelope: envelope, timing: TimingSource(rawValue: input["timing"].string)!)
            default: output = EditingImport.findUnlabeledSpeech(items, envelope: envelope)
            }
            compare(try .encoded(output), fixture["kind"].string == "unlabeled-speech" ? expected["items"] : expected["words"], tolerance: tolerance)
        case "word-cleanup":
            compare(try .encoded(EditingImport.cleanWords(rawWords(input["rawWords"]), timing: .native)), expected["words"], tolerance: tolerance)
        case "import-pipeline":
            let output = try EditingImport.pipeline(rawWords(input["rawWords"]), envelope: input["audio"].isNull ? nil : syntheticEnvelope(input["audio"]), timing: TimingSource(rawValue: input["timing"].string)!, verbatim: input["verbatim"].bool)
            compare(try .encoded(output.words), expected["words"], tolerance: tolerance)
            compare(.number(output.pauseThresholdSeconds), expected["pauseThresholdSeconds"])
            compare(.init(.array(output.pauses.map(pauseValue))), expected["pauses"], tolerance: tolerance)
        case "content-key":
            let keys = input["sizes"].array.map { size -> JSONValue in
                let count = size.int
                let headCount = count < 2_097_152 ? count : 1_048_576
                let head = Data((0..<headCount).map { UInt8(($0 * 31 + 7) % 251) })
                let tail = count < 2_097_152 ? Data() : Data(((count - 1_048_576)..<count).map { UInt8(($0 * 31 + 7) % 251) })
                return .string(SourceContentKey.hash(sizeBytes: Int64(count), head: head, tail: tail))
            }
            compare(.init(.array(keys)), expected["contentKeys"])
        case "edit-session": try runSession(input, expected, tolerance: tolerance)
        case "project-plan": try runProject(input, expected, root: root, tolerance: tolerance)
        default: Issue.record("Unknown editing fixture kind: \(fixture["kind"].string)")
        }
    }

    func compare(_ actual: FixtureValue, _ expected: FixtureValue, tolerance: Double = 1e-9, path: String = "expected") {
        switch expected.value {
        case .object(let object):
            for (key, value) in object where key != "tolerance" { compare(actual[key], FixtureValue(value), tolerance: tolerance, path: path + "." + key) }
        case .array(let array):
            #expect(actual.array.count == array.count, "\(path): array length")
            for (index, pair) in zip(actual.array, array).enumerated() { compare(pair.0, FixtureValue(pair.1), tolerance: tolerance, path: "\(path)[\(index)]") }
        case .number(let value):
            guard case .number(let number) = actual.value else { Issue.record("\(path): expected number, got \(actual.value)"); return }
            if path.contains(".segmentCuts[") && (path.hasSuffix(".rawStart") || path.hasSuffix(".rawEnd")) {
                #expect(number == value, "\(path): raw ranges differ: \(number), expected \(value)")
            } else { #expect(abs(number - value) <= tolerance, "\(path): got \(number), expected \(value)") }
        case .string(let text):
            guard case .string(let actualText) = actual.value else { Issue.record("\(path): expected string"); return }
            #expect(Array(actualText.unicodeScalars) == Array(text.unicodeScalars), "\(path)")
        default: #expect(actual.value == expected.value, "\(path)")
        }
    }

    func words(_ value: FixtureValue) -> [TimedWord] {
        value.array.enumerated().map { index, item in
            TimedWord(id: item["id"].isNull ? "w\(index)" : item["id"].string,
                      text: item["text"].isNull ? (item["word"].isNull ? "word" : item["word"].string) : item["text"].string,
                      kind: WordKind(rawValue: item["kind"].string) ?? .word, start: item["start"].number, end: item["end"].number)
        }
    }
    func rawWords(_ value: FixtureValue, wordKey: String = "text") -> [RawWord] {
        value.array.map { RawWord(text: $0[wordKey].string, start: $0["start"].isNull ? nil : $0["start"].number,
                                 end: $0["end"].isNull ? nil : $0["end"].number, conf: $0["conf"].isNull ? nil : $0["conf"].number,
                                 speaker: $0["speaker"].isNull ? nil : $0["speaker"].string, kind: WordKind(rawValue: $0["kind"].string) ?? .word) }
    }
    func rawValues(_ words: [RawWord], confidence: Bool) throws -> FixtureValue {
        .init(.array(words.map { word in
            var object: [String: JSONValue] = ["word": .string(word.text), "start": word.start.map(JSONValue.number) ?? .null, "end": word.end.map(JSONValue.number) ?? .null]
            if confidence { object["conf"] = word.conf.map(JSONValue.number) ?? .null }
            return .object(object)
        }))
    }
    func pauseValue(_ pause: Pause) -> JSONValue {
        .object(["id": .string(pause.id), "start": .number(pause.start), "end": .number(pause.end), "duration": .number(pause.duration), "label": .string(pause.label)])
    }
    func segments(_ input: FixtureValue) -> [EditSegment] {
        input["segments"].array.map { EditSegment(id: $0["id"].string, kind: EditSegmentKind(rawValue: $0["kind"].string)!, wordKind: WordKind(rawValue: $0["wordKind"].string) ?? .word,
                                                text: $0["text"].string, start: $0["start"].number, end: $0["end"].number, cut: $0["cut"].bool) }
    }
    func intervals(_ intervals: [MediaInterval]) -> JSONValue { .array(intervals.map { .array([.number(Double($0.startSample)), .number(Double($0.endSample))]) }) }

    func runPlan(_ input: FixtureValue, _ expected: FixtureValue, tolerance: Double) throws {
        let segments = segments(input), duration = input["durationSeconds"].number, rate = input["sampleRate"].number
        let breath = input["pauseKeepSeconds"].isNull ? 0.15 : input["pauseKeepSeconds"].number
        let plan = try buildEditPlan(segments, duration: duration, sampleRate: rate, pauseKeepSeconds: breath)
        var actual: [String: JSONValue] = ["totalSamples": .number(Double(plan.totalSamples)), "outputSamples": .number(Double(plan.outputSamples)), "durationSeconds": .number(plan.duration),
                                         "cuts": intervals(plan.cuts), "kept": intervals(plan.kept), "captions": try FixtureValue.encoded(captionCopy(segments, plan: plan)).value]
        let cutIndex = CutRangeIndex(segments)
        actual["segmentCuts"] = .array(segments.indices.filter { segments[$0].cut && validSegment(segments[$0]) }.map { index in
            let range = rawCutRange(at: index, segments: segments, index: cutIndex, duration: duration, pauseKeep: breath)
            let start = plan.clampSample(range.start), end = plan.clampSample(range.end)
            return .object(["id": .string(segments[index].id), "rawStart": .number(range.start), "rawEnd": .number(range.end), "startSample": .number(Double(start)), "endSample": .number(Double(end)), "empty": .bool(end <= start)])
        })
        for key in ["mapTime", "sourceTime", "previewSkip"] {
            actual[key] = .array(expected[key].array.map { pair in
                let time = pair.array[0].number
                let result: JSONValue
                if key == "mapTime" { result = .number(plan.mapTime(time)) }
                else if key == "sourceTime" { result = .number(plan.sourceTime(time)) }
                else { result = plan.cutContaining(time).map { .number(Double($0.endSample) / rate) } ?? .null }
                return .array([pair.array[0].value, result])
            })
        }
        actual["parts"] = try FixtureValue.encoded(plan.fadeParts).value
        actual["joins"] = .array(plan.joins.map { .array([.number(Double($0.outSample)), .number(Double($0.fadeOutLen)), .number(Double($0.fadeInLen))]) })
        for pair in expected["gains"].array {
            let sample = Int64(pair.array[0].int)
            #expect(gainFromJoins(plan.joins, at: sample) == plan.joinGain(at: sample))
        }
        actual["gains"] = .array(expected["gains"].array.map { .array([$0.array[0].value, .number(Double(Float(plan.joinGain(at: Int64($0.array[0].int)))))]) })
        compare(.init(.object(actual)), expected, tolerance: tolerance)
    }

    func gainFromJoins(_ joins: [Join], at sample: Int64) -> Double {
        var lower = 0, upper = joins.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if joins[middle].outSample <= sample { lower = middle + 1 }
            else { upper = middle }
        }
        if lower > 0 {
            let previous = joins[lower - 1]
            let distance = sample - previous.outSample
            if distance < previous.fadeInLen { return Double(distance) / Double(previous.fadeInLen) }
        }
        if lower < joins.count {
            let next = joins[lower]
            let distance = next.outSample - 1 - sample
            if distance < next.fadeOutLen { return Double(distance) / Double(next.fadeOutLen) }
        }
        return 1
    }

    func transcript(_ words: [TimedWord], duration: Double) -> Transcript {
        Transcript(words: words, durationSeconds: duration, engine: EngineRef(id: .elevenlabs, engineVersion: "test"), rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    }

    func runSession(_ input: FixtureValue, _ expected: FixtureValue, tolerance: Double) throws {
        let items = words(input["words"]), duration = input["durationSeconds"].number, rate = input["sampleRate"].number
        let threshold = input["hasDecodedAudio"].bool ? 0.8 : 1.0
        var state = EditState(transcript: transcript(items, duration: duration), pauses: try detectPauses(items, thresholdSeconds: threshold), pauseThresholdSeconds: threshold)
        let operations = [FixtureValue(.object(["op": .string("initial")]))] + input["ops"].array
        #expect(operations.count == expected["steps"].array.count)
        for (index, operation) in operations.enumerated() {
            let id = operation["id"].string
            switch operation["op"].string {
            case "initial": break
            case "toggle": state = EditReducer.reduce(state, command: .toggle(id: id))
            case "cutSelection": state = EditReducer.reduce(state, command: .cutSelection(ids: operation["ids"].array.map(\.string)))
            case "restoreSelection": state = EditReducer.reduce(state, command: .restoreSelection(ids: operation["ids"].array.map(\.string)))
            case "cutFillers": state = EditReducer.reduce(state, command: .cutFillers)
            case "tightenPauses": state = EditReducer.reduce(state, command: .tightenPauses)
            case "restoreCuts": state = EditReducer.reduce(state, command: .restoreCuts)
            case "correct": state = EditReducer.reduce(state, command: .correct(id: id, text: operation["text"].string))
            case "previewClip":
                if operation["clip"].isNull { state = EditReducer.reduce(state, command: .setActiveClip(clipId: nil)) }
                else {
                    let indices = operation["clip"].array
                    let clip = ClipRange(id: "test-clip-\(index)", startWordId: items[indices[0].int].id, endWordId: items[indices[1].int].id)
                    state = EditReducer.reduce(state, command: .addClip(clip))
                    state = EditReducer.reduce(state, command: .setActiveClip(clipId: clip.id))
                }
            default: Issue.record("Unknown session operation")
            }
            let segments = try buildSegments(state, activeClip: state.activeClip)
            let plan = try buildEditPlan(segments, duration: duration, sampleRate: rate, pauseKeepSeconds: state.pauseKeepSeconds)
            let summary = state.summary
            let status: JSONValue = summary.hasEdits ? .string("\(summary.cutWordCount) \(summary.cutWordCount == 1 ? "word" : "words") and \(summary.cutPauseCount) \(summary.cutPauseCount == 1 ? "pause" : "pauses") cut. Preview before publishing.") : .null
            let ui: JSONValue = .object(["cutFillersLabel": .string(summary.fillerCount > 0 ? "Cut fillers · \(summary.fillerCount)" : "Cut fillers"), "cutFillersEnabled": .bool(summary.canCutFillers), "tightenPausesEnabled": .bool(summary.canTighten), "restoreCutsVisible": .bool(summary.hasEdits), "status": status, "publishEnabled": .bool(summary.canExport)])
            let bounds = clipIndices(state.activeClip, words: items)
            let actual: JSONValue = .object(["after": operation.value, "cutWords": .array(items.filter { state.cutWordIds.contains($0.id) }.map { .string($0.id) }),
                "cutPauses": .array(state.pauses.filter { state.cutPauseIds.contains($0.id) }.map { .string($0.id) }),
                "texts": .object(Dictionary(uniqueKeysWithValues: items.map { ($0.id, .string(state.textOf($0))) })),
                "activeClip": bounds.map { .array([.number(Double($0.lowerBound)), .number(Double($0.upperBound))]) } ?? .null,
                "ui": ui, "durationSeconds": .number(plan.duration), "captions": try FixtureValue.encoded(captionCopy(segments, plan: plan)).value])
            compare(.init(actual), expected["steps"].array[index], tolerance: tolerance, path: "step[\(index)]")
        }
    }

    func runProject(_ input: FixtureValue, _ expected: FixtureValue, root: URL, tolerance: Double) throws {
        let projectURL = root.deletingLastPathComponent().appendingPathComponent(input["projectPath"].string)
        let project = try JSONProjectStore.decode(Data(contentsOf: projectURL))
        let transcript = try #require(project.transcript)
        let state = try EditState(transcript: transcript, edits: project.edits)
        let rate = Double(project.media.source.audio?.sampleRate ?? 48000), duration = project.media.source.durationSeconds
        compare(.number(rate), expected["sampleRate"]); compare(.number(duration), expected["sourceDurationSeconds"])
        compare(.init(.array(state.pauses.map(pauseValue))), expected["pauses"], tolerance: tolerance)
        func result(_ clip: ClipRange?) throws -> [String: JSONValue] {
            let segments = try buildSegments(state, activeClip: clip)
            let plan = try buildEditPlan(segments, duration: duration, sampleRate: rate, pauseKeepSeconds: state.pauseKeepSeconds)
            return ["outputSamples": .number(Double(plan.outputSamples)), "durationSeconds": .number(plan.duration), "kept": intervals(plan.kept), "captions": try FixtureValue.encoded(captionCopy(segments, plan: plan)).value]
        }
        compare(.init(.object(try result(nil))), expected["take"], tolerance: tolerance)
        let clips = try project.edits.clips.map { clip -> JSONValue in
            var actual = try result(clip)
            let indices = try #require(clipIndices(clip, words: transcript.words))
            let times = try clipTimes(transcript.words, startIndex: indices.lowerBound, endIndex: indices.upperBound)
            actual.merge(["id": .string(clip.id), "startWord": .number(Double(indices.lowerBound)), "endWord": .number(Double(indices.upperBound)), "sourceStart": .number(times.start), "sourceEnd": .number(times.end)]) { _, new in new }
            return .object(actual)
        }
        compare(.init(.array(clips)), expected["clips"], tolerance: tolerance)
    }

    func syntheticEnvelope(_ audio: FixtureValue) -> AudioEnvelope {
        let rate = audio["sampleRate"].number
        var samples = [Float](repeating: 0, count: Int(audio["seconds"].number * rate))
        var seed = 7.0
        func noise() -> Double { seed = (seed * 16807).truncatingRemainder(dividingBy: 2147483647); return (seed / 2147483647) * 2 - 1 }
        for index in samples.indices { samples[index] = Float(0.002 * noise()) }
        for section in audio["sections"].array {
            let first = Int(EditingPrimitives.jsRound(section.array[0].number * rate)), last = Int(EditingPrimitives.jsRound(section.array[1].number * rate))
            if first >= last { continue }
            for index in first..<last {
                let value = section.array[2].string == "vowel" ? 0.5 * sin(((2 * Double.pi) * 180 * Double(index)) / rate) : 0.1 * noise()
                if samples.indices.contains(index) { samples[index] = Float(value) }
            }
        }
        let frameSize = max(1, Int(EditingPrimitives.jsRound(rate * 0.01)))
        let levels = (0..<(samples.count / frameSize)).map { frame -> Float in
            var sum = 0.0
            for index in (frame * frameSize)..<((frame + 1) * frameSize) { sum += Double(samples[index]) * Double(samples[index]) }
            return Float(sqrt(sum / Double(frameSize)))
        }
        return AudioEnvelope(sampleRate: rate, frameSeconds: Double(frameSize) / rate, levels: levels)
    }
}
