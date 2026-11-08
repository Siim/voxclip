import Foundation
import Testing
@testable import VoxClipCore

/// The export self-check's rules (ADR-R49) replayed from shared/fixtures/export-check/check-cases.json, which
/// tools/fixtures/export-check/generate_check_cases.py writes and the Windows twin replays too, and the numbers file
/// beside it (number-check-cases.json, SpokenNumbers).
struct ExportCheckReplayTests {
    static let path = "fixtures/export-check/check-cases.json"
    static let numbersPath = "fixtures/export-check/number-check-cases.json"

    static func document(_ path: String = path) throws -> [String: JSONValue] {
        try #require(JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(path)).aiObject)
    }

    static func input(_ value: JSONValue) throws -> ExportCheckInput {
        func number(_ value: JSONValue) throws -> Double { try #require(value.aiDouble) }
        func track(_ value: JSONValue) throws -> ExportCheckInput.Track? {
            value == .null ? nil : ExportCheckInput.Track(start: try number(value[ai: "start"]), end: try number(value[ai: "end"]))
        }
        let expected = try value[ai: "expected"].aiArray.map { word in
            ExportCheckInput.Word(text: try #require(word[ai: "text"].aiString), start: try number(word[ai: "start"]),
                                  end: try number(word[ai: "end"]), optional: word[ai: "optional"] == .bool(true),
                                  phrase: word[ai: "phrase"].aiString)
        }
        let heard: [ExportCheckInput.Heard]? = value[ai: "heard"] == .null ? nil : try value[ai: "heard"].aiArray.map { word in
            ExportCheckInput.Heard(text: try #require(word[ai: "text"].aiString), start: try number(word[ai: "start"]), end: try number(word[ai: "end"]))
        }
        let phrases = try value[ai: "phrases"].aiArray.map { phrase in
            ExportCheckInput.Phrase(id: try #require(phrase[ai: "id"].aiString), start: try number(phrase[ai: "start"]), end: try number(phrase[ai: "end"]))
        }
        let measured = value[ai: "loudness"]
        let loudness: ExportCheckInput.Loudness? = measured == .null ? nil : ExportCheckInput.Loudness(
            setting: try #require(measured[ai: "setting"].aiString.flatMap(ExportLoudness.init(rawValue:))),
            integratedLufs: measured[ai: "integratedLufs"].aiDouble, truePeakDbtp: measured[ai: "truePeakDbtp"].aiDouble)
        let boxes = try value[ai: "boxes"].aiArray.map { box in
            let rect = box[ai: "rect"]
            return ExportCheckInput.Box(kind: try #require(box[ai: "kind"].aiString.flatMap(ExportCheckInput.Box.Kind.init(rawValue:))),
                time: try number(box[ai: "time"]), rect: CaptionRect(x: try number(rect[ai: "x"]), y: try number(rect[ai: "y"]),
                                                                    width: try number(rect[ai: "width"]), height: try number(rect[ai: "height"])))
        }
        let frame = PixelSize(width: Int(try number(value[ai: "frame"][ai: "width"])), height: Int(try number(value[ai: "frame"][ai: "height"])))
        return ExportCheckInput(expected: expected, heard: heard, cuts: try value[ai: "cuts"].aiArray.map(number), phrases: phrases,
                                video: try track(value[ai: "video"]), audio: try track(value[ai: "audio"]),
                                frameSeconds: try number(value[ai: "frameSeconds"]), loudness: loudness, boxes: boxes, frame: frame)
    }

    /// Where `result` differs from `expect`: the status, the reason, each item's kind, time, words, band, phrase and value,
    /// and the result's own numbers. Numbers compare within 1e-9.
    static func differences(_ result: ExportCheckResult, _ expect: JSONValue) -> [String] {
        var found: [String] = []
        func near(_ wanted: JSONValue, _ actual: Double?, _ what: String) {
            if wanted == .null { if actual != nil { found.append("\(what): \(actual!) where none was expected") }; return }
            guard let wanted = wanted.aiDouble, let actual, abs(wanted - actual) < 1e-9 else {
                found.append("\(what): \(String(describing: actual)) against \(wanted)"); return
            }
        }
        if result.status.rawValue != expect[ai: "status"].aiString { found.append("status \(result.status) against \(expect[ai: "status"])") }
        if result.reason != expect[ai: "reason"].aiString { found.append("reason \(String(describing: result.reason))") }
        for key in ["matched", "total", "unverified"] {
            let actual = key == "matched" ? result.matched : key == "total" ? result.total : result.unverified
            near(expect[ai: key], actual.map(Double.init), key)
        }
        near(expect[ai: "integratedLufs"], result.integratedLufs, "integratedLufs")
        near(expect[ai: "truePeakDbtp"], result.truePeakDbtp, "truePeakDbtp")
        near(expect[ai: "startOffset"], result.startOffset, "startOffset")
        near(expect[ai: "endOffset"], result.endOffset, "endOffset")
        let items = expect[ai: "items"].aiArray
        guard items.count == result.items.count else { return found + ["\(result.items.count) items against \(items.count): \(result.items)"] }
        for (index, (item, wanted)) in zip(result.items, items).enumerated() {
            if item.kind.rawValue != wanted[ai: "kind"].aiString { found.append("item \(index) kind \(item.kind)") }
            near(wanted[ai: "time"], item.time, "item \(index) time")
            near(wanted[ai: "value"], item.value, "item \(index) value")
            near(wanted[ai: "limit"], item.limit, "item \(index) limit")
            if item.expected != wanted[ai: "expected"].aiString { found.append("item \(index) expected \(String(describing: item.expected))") }
            if item.heard != wanted[ai: "heard"].aiString { found.append("item \(index) heard \(String(describing: item.heard))") }
            if item.band?.rawValue != wanted[ai: "band"].aiString { found.append("item \(index) band \(String(describing: item.band))") }
            if item.phrase != wanted[ai: "phrase"].aiString { found.append("item \(index) phrase \(String(describing: item.phrase))") }
            if item.reason != wanted[ai: "reason"].aiString { found.append("item \(index) reason \(String(describing: item.reason))") }
            near(wanted[ai: "count"], item.count.map(Double.init), "item \(index) count")
        }
        return found
    }

    @Test func theFileHasItsOwnSchemaAndEveryCheck() throws {
        let document = try Self.document()
        #expect(document["schema"] == .string("voxclip-export-check-cases/1"))
        let cases = document["cases"]?.aiArray ?? []
        #expect(document["caseCount"]?.aiDouble == Double(cases.count))
        let checks = Set(cases.compactMap { $0[ai: "check"].aiString })
        #expect(checks == Set(ExportCheckKind.allCases.map(\.rawValue)))
        // The constants the file was derived with are the engine's.
        let constants = try #require(document["constants"])
        #expect(constants[ai: "matchFloor"].aiDouble == ExportCheck.matchFloor)
        #expect(constants[ai: "phraseToleranceSeconds"].aiDouble == ExportCheck.phraseToleranceSeconds)
        #expect(constants[ai: "targetLufs"].aiDouble == ExportCheck.targetLufs)
        #expect(constants[ai: "loudnessToleranceLu"].aiDouble == ExportCheck.loudnessToleranceLu)
        #expect(constants[ai: "ceilingDbtp"].aiDouble == ExportCheck.ceilingDbtp)
        #expect(constants[ai: "truePeakToleranceDb"].aiDouble == ExportCheck.truePeakToleranceDb)
        for (aspect, edges) in try #require(constants[ai: "bands"].aiObject) {
            let bands = CaptionSafeZones.bands(aspectClass: aspect)
            #expect(bands.count == edges.aiObject?.count, "\(aspect)")
            for band in bands { #expect(edges[ai: band.edge.rawValue].aiDouble == band.fraction, "\(aspect) \(band.edge)") }
        }
    }

    @Test func theNumbersFileHasItsOwnSchemaAndCount() throws {
        let document = try Self.document(Self.numbersPath)
        #expect(Set(document.keys) == ["schema", "description", "constants", "caseCount", "counts", "cases"])
        #expect(document["schema"] == .string("voxclip-export-check-number-cases/1"))
        let cases = document["cases"]?.aiArray ?? []
        #expect(cases.count == 4 && document["caseCount"]?.aiDouble == Double(cases.count))
        #expect(document["constants"]?[ai: "matchFloor"].aiDouble == ExportCheck.matchFloor)
    }

    @Test(arguments: [path, numbersPath]) func everyCaseReplays(_ path: String) throws {
        let cases = try Self.document(path)["cases"]?.aiArray ?? []
        #expect(!cases.isEmpty)
        for entry in cases {
            let id = entry[ai: "id"].aiString ?? "?"
            let check = try #require(entry[ai: "check"].aiString.flatMap(ExportCheckKind.init(rawValue:)), "\(id)")
            let report = ExportCheck.run(try Self.input(entry[ai: "input"]))
            let result = try #require(report[check], "\(id)")
            let found = Self.differences(result, entry[ai: "expect"])
            #expect(found.isEmpty, "\(id): \(found)")
            #expect(report.passed == !report.results.contains { $0.status == .warning }, "\(id)")
        }
    }
}
