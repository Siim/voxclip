import Foundation
import Testing
@testable import VoxClipCore

enum CaptionCoreFixtures {
    static func shared() throws -> URL {
        try FixtureLoader.sharedRoot()
    }
    static func resources() throws -> CaptionResources {
        let root = try shared()
        func data(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
        return try .init(fontManifest: data("fonts/fonts.json"), caseMap: data("caption-styles/casemap.json"), stopwords: data("caption-styles/stopwords.json"), emojiKeywords: data("caption-styles/emoji-keywords.json"))
    }
}

@Test("Every caption text-normalization fixture")
func captionTextFixtures() throws {
    struct Fixture: Decodable {
        struct Case: Decodable { var input: String; var language: String; var results: [String: String]; var matchingKey: String; var endsSentence: Bool; var endsClause: Bool }
        var cases: [Case]
    }
    let resources = try CaptionCoreFixtures.resources()
    let root = try CaptionCoreFixtures.shared()
    let fixtures = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/captions/text-normalization.json")))
    for fixture in fixtures.cases {
        for (key, expected) in fixture.results {
            let options = key.split(separator: "|")
            let actual = CaptionTextRules.normalize(fixture.input, options: .init(transform: CaptionTextTransform(rawValue: String(options[1]))!, punctuation: CaptionTextPunctuation(rawValue: String(options[0]))!), language: fixture.language, resources: resources)
            #expect(actual == expected, "\(fixture.input): \(key)")
        }
        #expect(CaptionTextRules.matchingKey(fixture.input, language: fixture.language, resources: resources) == fixture.matchingKey)
        #expect(CaptionTextRules.sentenceEnd(fixture.input) == fixture.endsSentence)
        #expect(CaptionTextRules.clauseEnd(fixture.input) == fixture.endsClause)
    }
}

@Test("All bundled styles decode with strict keys and defaults")
func captionStyleFixtures() throws {
    let root = try CaptionCoreFixtures.shared()
    let styles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("caption-styles/styles"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    #expect(styles.count >= 19)
    for url in styles {
        let data = try Data(contentsOf: url)
        let style = try JSONDecoder().decode(CaptionStyle.self, from: data)
        #expect(style.id == url.deletingPathExtension().lastPathComponent)
        let roundTrip = try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style))
        #expect(style == roundTrip)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["unexpected"] = true
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CaptionStyle.self, from: JSONSerialization.data(withJSONObject: json)) }
        json.removeValue(forKey: "unexpected")
        var font = try #require(json["font"] as? [String: Any]); font["sizeScale"] = 9; json["font"] = font
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CaptionStyle.self, from: JSONSerialization.data(withJSONObject: json)) }
    }
    let layout = try JSONDecoder().decode(CaptionLayout.self, from: Data(#"{"maxWords":4,"maxLines":2,"maxLineWidthW":0.8,"breakOnGapSec":null}"#.utf8))
    #expect(layout.breakOnGapSec == nil)
    let roundTrip = try JSONDecoder().decode(CaptionLayout.self, from: JSONEncoder().encode(layout))
    #expect(roundTrip.breakOnGapSec == nil)
}

@Test("Caption rounding, easing, random and fixed frame times")
func captionMathFixtures() throws {
    struct Math: Decodable {
        struct Jitter: Decodable { var t: Double; var rateHz: Double; var seed: UInt32; var k: UInt32; var r: [Double] }
        var roundHalfUp: [[Double]]; var easing: [String: [[Double]]]; var mulberry32: [String: [Double]]; var jitter: [Jitter]
    }
    let root = try CaptionCoreFixtures.shared()
    let math = try JSONDecoder().decode(Math.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/captions/math.json")))
    for pair in math.roundHalfUp { #expect(CaptionMath.roundHalfUp(pair[0]) == Int(pair[1])) }
    for (name, values) in math.easing {
        let easing: CaptionAnimEasing = name.hasPrefix("easeOutBack") ? .easeOutBack : CaptionAnimEasing(rawValue: name)!
        let overshoot = name.split(separator: "(").last.flatMap { Double($0.dropLast()) } ?? 1.70158
        for pair in values { #expect(abs(CaptionMath.ease(easing, pair[0], overshoot: overshoot) - pair[1]) <= 1e-9) }
    }
    for (seed, values) in math.mulberry32 {
        var random = Mulberry32(seed: UInt32(seed)!)
        for expected in values { #expect(random.next() == expected) }
    }
    for jitter in math.jitter {
        let key = CaptionMath.jitterKey(time: jitter.t, rateHz: jitter.rateHz)
        #expect(key == jitter.k)
        var random = Mulberry32(seed: jitter.seed ^ key)
        for expected in jitter.r { #expect(random.next() == expected) }
    }
    #expect(try CaptionMath.frameTime(index: 123, fpsNum: 30000, fpsDen: 1001) == Double(123 * 1001) / 30000)
}

@Test("Caption easing clamps progress and preserves exact endpoints")
func captionEasingEndpoints() {
    for easing in CaptionAnimEasing.allCases {
        for overshoot in [0.0, 1.70158, 2.5] {
            for progress in [-Double.infinity, -1, -Double.leastNonzeroMagnitude, 0] {
                #expect(CaptionMath.ease(easing, progress, overshoot: overshoot) == 0)
            }
            for progress in [1, 1.nextUp, 2, Double.infinity] {
                #expect(CaptionMath.ease(easing, progress, overshoot: overshoot) == 1)
            }
        }
    }
    #expect(CaptionMath.ease(.easeOutBack, 0.8) > 1)
}
