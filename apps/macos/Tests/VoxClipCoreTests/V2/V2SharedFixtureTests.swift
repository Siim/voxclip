import Foundation
import Testing
@testable import VoxClipCore

/// WC1's independent, byte-exact reference. No epsilon comparisons: both Cores replay the same values.
@Suite("v2 Core shared vectors", .offlineFixtures) struct V2SharedFixtureTests {
    private func number(_ value: Any) -> Double {
        if let name = value as? String {
            switch name { case "NaN": return .nan; case "Infinity": return .infinity; default: return -.infinity }
        }
        return (value as! NSNumber).doubleValue
    }
    private func range(_ value: Any) -> Range<Double> {
        let values = value as! [Any]
        return number(values[0])..<number(values[1])
    }
    private func pair(_ value: Range<Double>) -> [Double] { [value.lowerBound, value.upperBound] }
    private func indices(_ value: Range<Int>) -> [Int] { [value.lowerBound, value.upperBound] }
    private func axis(_ value: Any) -> TimelineAxis { TimelineAxis(rawValue: value as! String)! }

    @Test(arguments: ["paragraphs.json", "timeline-cases.json"])
    func replay(_ filename: String) throws {
        let data = try FixtureLoader.data("fixtures/v2/" + filename)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == Set(["schema", "caseCount", "cases"]))
        let paragraphs = filename == "paragraphs.json"
        #expect(root["schema"] as? String == (paragraphs ? "voxclip.v2.paragraphs.v1" : "voxclip.v2.timeline.v1"))
        let count = paragraphs ? 27 : 44
        #expect(root["caseCount"] as? Int == count)
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(cases.count == count)
        for item in cases {
            let id = item["id"] as! String
            if paragraphs {
                let rows = item["words"] as! [[Any]]
                let words = rows.enumerated().map { index, row in
                    TimedWord(id: "w\(index)", text: row[0] as! String, start: number(row[1]), end: number(row[2]), speaker: row[3] as? String)
                }
                let actual = TranscriptParagraphs.split(words: words).map(indices)
                #expect(NSArray(array: actual).isEqual(to: item["expected"] as! [Any]), "\(id)")
            } else {
                let actual = try timeline(item)
                let expected = item["expected"] as! [String: Any]
                #expect(NSDictionary(dictionary: actual).isEqual(to: expected), "\(id): \(actual)")
            }
        }
    }

    private func timeline(_ item: [String: Any]) throws -> [String: Any] {
        let input = item["input"] as! [String: Any]
        switch item["kind"] as! String {
        case "pieces":
            let rate = number(input["rate"]!), raw = input["raw"] as! [[Any]]
            let pieces: TimelinePieces
            if input["mode"] as! String == "legacy" {
                let kept = raw.map { MediaInterval(startSample: ($0[0] as! NSNumber).int64Value, endSample: ($0[1] as! NSNumber).int64Value) }
                pieces = TimelinePieces(.legacy(EditPlan(sampleRate: rate, totalSamples: kept.last?.endSample ?? 0, cuts: [], kept: kept)))
            } else {
                let voice = raw.map { row in
                    VoiceLabOutputPiece(kind: row[4] as! String == "ai" ? .synth : .source,
                        sourceStartSample: (row[0] as! NSNumber).int64Value, sourceEndSample: (row[1] as! NSNumber).int64Value,
                        outputStartSample: (row[2] as! NSNumber).int64Value, outputEndSample: (row[3] as! NSNumber).int64Value,
                        segmentId: nil, assetId: nil, audio: nil)
                }
                pieces = TimelinePieces(.voiceLab(VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: 1_000, pieces: voice, captions: [], scope: .full)))
            }
            let overlaps = (input["queries"] as! [[Any]]).map { query in
                indices(pieces.indices(overlapping: number(query[1])..<number(query[2]), on: axis(query[0])))
            }
            return ["pieces": pieces.pieces.map { ["source": pair($0.source), "edited": pair($0.edited), "kind": $0.kind.rawValue] },
                    "editedDuration": pieces.editedDuration, "sourceSpan": pieces.sourceSpan.map(pair) as Any? ?? NSNull(),
                    "seams": pieces.seams, "overlaps": overlaps, "gaps": pieces.gaps(within: range(input["span"]!), minimum: number(input["minimum"]!)).map(pair)]
        case "ruler":
            let scale = number(input["scale"]!), visible = range(input["visible"]!)
            return ["major": TimelineRuler.majorStep(ptPerSecond: scale), "minor": TimelineRuler.minorStep(ptPerSecond: scale),
                    "ticks": TimelineRuler.ticks(visible: visible.lowerBound...visible.upperBound, ptPerSecond: scale).map { ["time": $0.time, "major": $0.major] }]
        case "timecode":
            let seconds = number(input["seconds"]!), fps = input["fps"] as! Int
            let text = SMPTETimecode.format(seconds: seconds, fps: fps)
            return ["frame": SMPTETimecode.frame(seconds: seconds, fps: fps), "dimPrefix": text.dimPrefix, "value": text.value, "string": SMPTETimecode.string(seconds: seconds, fps: fps)]
        case "captions":
            let pages = (input["pages"] as! [[String: Any]]).map { row in TimelineCaptions.Page(edited: range(row["edited"]!), source: range(row["source"]!), text: row["text"] as! String) }
            let removed = (input["removed"] as! [Any]).map(range)
            let cues = TimelineCaptions.cues(pages, on: axis(input["axis"]!), removed: removed)
            return ["cues": cues.map { ["range": pair($0.range), "text": $0.text, "cuts": $0.cuts.map(pair)] },
                    "indices": indices(TimelineCaptions.indices(of: cues, overlapping: range(input["query"]!)))]
        default:
            Issue.record("Unknown v2 fixture kind")
            return [:]
        }
    }
}
