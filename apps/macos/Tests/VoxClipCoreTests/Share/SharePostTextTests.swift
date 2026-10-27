import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/share/cases.json; doc/publishing.md §2.1 and doc/spec/voice-lab.md §11.3.
@Suite struct SharePostTextTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let text: String
            let line: String?
            let clusters: [[Int]]
            let xWeight: Int
            let linkedInLength: Int
            let voxConvoLength: Int
            let present: Bool?
            let fieldText: String?
            let composerX: String
            let composerVoxConvo: String
        }
        struct DefaultCaption: Decodable {
            let name: String
            let title: String?
            let words: [String]
            let expected: String
        }
        let defaultCaptions: [DefaultCaption]
        let cases: [Case]
    }

    private static func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: FixtureLoader.data("fixtures/share/cases.json"))
    }

    /// Run-length [scalars per Character, count] of the NFC text, the fixture's cluster encoding.
    private static func clusterRuns(_ text: String) -> [[Int]] {
        var runs: [[Int]] = []
        for character in ShareDisclosure.string(ShareDisclosure.nfc(text)) {
            let size = character.unicodeScalars.count
            if let last = runs.last, last[0] == size { runs[runs.count - 1][1] += 1 } else { runs.append([size, 1]) }
        }
        return runs
    }

    /// UTF-8 bytes: Swift `==` compares canonically equivalent strings as equal, and a caption that fits must come back
    /// byte-identical.
    private static func bytes(_ text: String?) -> [UInt8]? { text.map { Array($0.utf8) } }

    @Test func sharedDataLoadsTheRules() throws {
        let rules = try ShareTextRules.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        try SharePostText.preflight()
        #expect(try rules == SharePostText.rules())
        #expect(try SharePostText.limit(.x) == 280 && SharePostText.limit(.linkedIn) == 3000 && SharePostText.limit(.voxConvo) == 2048)
        #expect(rules.ellipsis == "\u{2026}" && rules.urlLength == 23 && rules.scale == 100 && rules.defaultWeight == 200)
        #expect(rules.emoji.count == 81 && rules.tlds.contains("ee") && rules.trailing.contains(0x2026))
    }

    @Test func invalidRulesFailTheLoad() throws {
        // The real file with one value changed, so each guard rejects it rather than the decoder.
        let text = try String(contentsOf: FixtureLoader.sharedRoot().appendingPathComponent("data/share-text.json"), encoding: .utf8)
        // The cut needs one ellipsis scalar among trailing punctuation that stands alone: not a combining mark, a Hangul
        // vowel NFC composes, or a pictograph that joins a ZWJ sequence.
        let ellipsis = "\"ellipsis\": \"\u{5C}u2026\""
        let mutations = [("\"shareTextVersion\": 1,", "\"shareTextVersion\": 2,"),
                         ("\"ranges\": [[8986, 8987], [9193, 9196]", "\"ranges\": [[8986, 9193], [9193, 9196]"),
                         (ellipsis, "\"ellipsis\": \"...\""), (ellipsis, "\"ellipsis\": \"~\""), (")]}>", ")]}>\u{301}"), (")]}>", ")]}>\u{1161}"),
                         (")]}>", ")]}>\u{203C}")]
        for (original, replacement) in mutations {
            #expect(text.contains(original))
            #expect(throws: VoxClipError.sharedResourcesMissing) {
                try ShareTextRules(data: Data(text.replacingOccurrences(of: original, with: replacement).utf8))
            }
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root.appendingPathComponent("caption-styles"), withIntermediateDirectories: true)
        // A shared root without the file fails the launch probe as well as the load.
        #expect(throws: VoxClipError.sharedResourcesMissing) { try SharedResources.locate(environment: ["VOXCLIP_SHARED_DIR": root.path]) }
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ShareTextRules.load(shared: SharedResources(root: root)) }
        try manager.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: root.appendingPathComponent("data/share-text.json"))
        #expect(try SharedResources.locate(environment: ["VOXCLIP_SHARED_DIR": root.path]).root == root)
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ShareTextRules.load(shared: SharedResources(root: root)) }
    }

    @Test func everyCaseMatchesOnThisPlatform() throws {
        let fixture = try Self.fixture()
        #expect(fixture.cases.count == 76)
        for item in fixture.cases {
            #expect(Self.clusterRuns(item.text) == item.clusters, "\(item.name) clusters")
            #expect(try SharePostText.xWeight(item.text) == item.xWeight, "\(item.name) xWeight")
            #expect(SharePostText.linkedInLength(item.text) == item.linkedInLength, "\(item.name) linkedInLength")
            #expect(SharePostText.voxConvoLength(item.text) == item.voxConvoLength, "\(item.name) voxConvoLength")
            #expect(try Self.bytes(SharePostText.composerText(item.text, destination: .x, disclosureLine: item.line)) == Self.bytes(item.composerX),
                    "\(item.name) composerX")
            #expect(try Self.bytes(SharePostText.composerText(item.text, destination: .voxConvo, disclosureLine: item.line)) == Self.bytes(item.composerVoxConvo),
                    "\(item.name) composerVoxConvo")
            #expect(try Self.bytes(SharePostText.composerText(item.text, destination: .linkedIn, disclosureLine: item.line)) == Self.bytes(item.text),
                    "\(item.name) linkedIn")
            if let line = item.line {
                #expect(ShareDisclosure.isPresent(item.text, line: line) == item.present, "\(item.name) present")
                #expect(try Self.bytes(SharePostText.fieldText(item.text, line: line)) == Self.bytes(item.fieldText), "\(item.name) fieldText")
            } else {
                #expect(try Self.bytes(SharePostText.fieldText(item.text, line: nil)) == Self.bytes(item.text), "\(item.name) fieldText")
            }
        }
    }

    @Test func truncatedTextKeepsTheLineLastAndFitsTheLimit() throws {
        for item in try Self.fixture().cases {
            for (destination, output) in [(ShareDestination.x, item.composerX), (.voxConvo, item.composerVoxConvo)] where output != item.text {
                let measure = try destination == .x ? SharePostText.xWeight(output) : SharePostText.voxConvoLength(output)
                #expect(try measure <= SharePostText.limit(destination), "\(item.name) \(destination)")
                if let line = item.line, item.present == true { #expect(output == line || output.hasSuffix("\n\n" + line), "\(item.name) \(destination)") }
            }
            if let line = item.line, let field = item.fieldText, item.present == false {
                #expect(SharePostText.linkedInLength(field) <= 3000 && (field == line || field.hasSuffix("\n\n" + line)), "\(item.name) fieldText")
            }
        }
    }

    @Test func spaceFreeCaptionsCutQuickly() throws {
        // 3,000 scalars without White_Space: only the first-word fallback cuts them. A word with '.' or ':' was scanned
        // from the longest cut down, about 0.5 s in an optimized build; one pass weighs every cut now.
        let japanese = String(repeating: "今日はVoxClipで動画を編集しました。YouTubeとXに投稿！", count: 90)
        let captions = [japanese, "今日は12:30に" + japanese, "VoxClip1.0で" + japanese]
            .map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(3000))) }
            + [String(repeating: "_a", count: 1500), "a." + String(repeating: "a", count: 2998), String(repeating: "a.", count: 1500),
               "data:" + String(repeating: "A", count: 2995)]
        let clock = ContinuousClock()
        for caption in captions {
            #expect(caption.unicodeScalars.count == 3000)
            let started = clock.now
            let text = try SharePostText.composerText(caption, destination: .x, disclosureLine: nil)
            let elapsed = clock.now - started
            #expect(try SharePostText.xWeight(text) <= 280 && text.hasSuffix("\u{2026}"))
            #expect(elapsed < .seconds(1), "\(elapsed)")
        }
    }

    @Test func xFirstWordCutsMatchTheLongestFirstScan() throws {
        // Random space-free words, many with a URL that comes and goes as the cut grows; the definition scans every cut
        // from the longest down, each measured whole.
        let rules = try SharePostText.rules()
        let heavy = ["日本", "\u{1F642}", "x", "aa", "見"]
        let pool = ["日本", "a", "b", "co", "com", "ee", "info", ".", ".", ":", "/", "//", "https://", "Http://", "voxconvo", "-", "@", "_",
                    "8080", "80", ")", "!", ".,", "\u{2026}", "\u{201D}", "\u{1F642}", "\u{1F1EA}\u{1F1EA}", "\u{1F1EA}", "\u{1F44D}\u{1F3FD}",
                    "\u{600}", "\u{301}", "\u{FE0F}", "\u{200D}", "x", "1.0", ".com", ":443/", "www.", "a.co_", "?q=1"]
        let urls = ["https://", "_voxconvo.com/", "_voxconvo.com:8080", "_a.co", "(www.voxconvo.ee/", "\u{600}http://"]
        var generator = SplitMix(state: 11)
        var cuts = 0
        var cutsWithURL = 0
        for _ in 0..<120 {
            var word = ""
            let withURL = Bool.random(using: &generator)
            let weight = (withURL ? [150, 200, 240, 255] : [180, 230, 260, 275]).randomElement(using: &generator)!
            while rules.xWeight(word) < weight { word += heavy.randomElement(using: &generator)! }
            if withURL {
                word += urls.randomElement(using: &generator)!
                for _ in 0..<[0, 3, 10, 40].randomElement(using: &generator)! { word += pool.randomElement(using: &generator)! }
                let trailing = [")", "!.", "\u{2026}", ".,", ")]"].randomElement(using: &generator)!
                word += String(repeating: trailing, count: [5, 20, 60].randomElement(using: &generator)!)
            } else {
                for _ in 0..<[10, 30, 60, 120].randomElement(using: &generator)! { word += pool.randomElement(using: &generator)! }
            }
            let line = [nil, nil, "Line."].randomElement(using: &generator)!
            let lead = ["", " ", "\n", " \u{301}"].randomElement(using: &generator)!
            let caption = lead + word + (line.map { "\n\n" + $0 } ?? "")
            let text = rules.composerText(caption, destination: .x, disclosureLine: line)
            let expected = rules.xWeight(caption) <= rules.xLimit ? caption
                : Self.longestFirstCut(ShareDisclosure.nfc(lead + word), line: line, rules: rules)
            #expect(Self.bytes(text) == Self.bytes(expected), "\(Array(caption.unicodeScalars.map(\.value)))")
            if text != caption { cuts += 1 }
            if text != caption, !rules.urlRanges(ShareDisclosure.nfc(text)).isEmpty { cutsWithURL += 1 }
        }
        #expect(cuts >= 50 && cutsWithURL >= 15, "\(cuts) cuts, \(cutsWithURL) with a URL")
    }

    /// Composer rule 5 for a body that is one word after leading White_Space: every cut from the longest down, each
    /// measured whole, as doc/publishing.md §2.1 defines it.
    private static func longestFirstCut(_ body: [Unicode.Scalar], line: String?, rules: ShareTextRules) -> String {
        let tail = line.map { "\n\n" + $0 } ?? ""
        var ends = [0]
        for character in ShareDisclosure.string(body) { ends.append(ends[ends.count - 1] + character.unicodeScalars.count) }
        for end in ends.reversed() where end < body.count {
            let text = ShareDisclosure.string(ShareDisclosure.trimmingEnd(body[..<end])) + rules.ellipsis + tail
            if rules.xWeight(text) <= rules.xLimit { return text }
        }
        return line ?? rules.ellipsis
    }

    /// SplitMix64 with a fixed seed, so every run tests the same words.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    @Test func captionsCapAt3000Scalars() {
        // share.captions holds 3,000 Unicode scalars on both platforms; an emoji is one scalar but two UTF-16 units.
        let emoji = String(repeating: "\u{1F642}", count: 3001)
        #expect(SharePostText.capCaption(emoji) == String(repeating: "\u{1F642}", count: 3000))
        let mixed = SharePostText.capCaption("a" + emoji)
        #expect(mixed.unicodeScalars.count == 3000 && mixed.utf16.count == 5999)
        let exact = String(repeating: "a\u{301}", count: 1500)
        #expect(Self.bytes(SharePostText.capCaption(exact)) == Self.bytes(exact))
        #expect(Self.bytes(SharePostText.capCaption(exact + "b")) == Self.bytes(exact))
        // Scalars, not clusters, as ProjectValidation counts them: a combining mark past the cap is dropped.
        let base = String(repeating: "a", count: 2999)
        #expect(Self.bytes(SharePostText.capCaption(base + "e\u{301}")) == Self.bytes(base + "e"))
        #expect(SharePostText.capCaption("").isEmpty)
    }

    @Test func defaultCaptions() throws {
        let fixture = try Self.fixture()
        #expect(fixture.defaultCaptions.count == 12)
        for item in fixture.defaultCaptions {
            #expect(try Self.bytes(SharePostText.defaultCaption(title: item.title, words: item.words)) == Self.bytes(item.expected), "\(item.name)")
        }
    }

    @Test func disclosureCopyIsVerbatim() throws {
        #expect(ShareDisclosure.removedWarning == "Your post no longer says the video contains AI-modified parts.")
        #expect(ShareDisclosure.shareAnyway == "Share anyway" && ShareDisclosure.restoreLine == "Restore line")
        #expect(ShareDisclosure.xMadeWithAITip == "Turn on 'Made with AI' in the post's content disclosure before posting.")
        #expect(ShareDisclosure.isPresent("Caption", line: " \n "))
        #expect(try SharePostText.fieldText("", line: "Line.") == "Line.")
        #expect(try SharePostText.fieldText("Caption \n", line: "Line.") == "Caption\n\nLine.")
    }

    @Test func nfcComposesHangulLVAndT() {
        // Foundation alone leaves U+AC00 U+11A8; NFC composes it to U+AC01. An LVT syllable takes no second T.
        #expect(ShareDisclosure.nfc("\u{AC00}\u{11A8}").map(\.value) == [0xAC01])
        #expect(ShareDisclosure.nfc("\u{C720}\u{11BD}").map(\.value) == [0xC736])
        #expect(ShareDisclosure.nfc("\u{AC01}\u{11A8}").map(\.value) == [0xAC01, 0x11A8])
        #expect(ShareDisclosure.nfc("\u{1100}\u{1161}\u{11A8}").map(\.value) == [0xAC01])
        #expect(ShareDisclosure.nfc("o\u{303}\u{AC00}\u{301}\u{11A8}").map(\.value) == [0xF5, 0xAC00, 0x301, 0x11A8])
    }

    @Test func whiteSpaceIsTheCaptionSet() {
        // Every White_Space scalar is below U+3001.
        for value in UInt32(0)...0x30FF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            #expect(ShareDisclosure.white(scalar) == CaptionTextRules.whitespace(scalar), "U+\(String(value, radix: 16))")
        }
    }
}
