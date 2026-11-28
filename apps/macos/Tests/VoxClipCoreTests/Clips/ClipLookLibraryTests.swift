import Foundation
import Testing
@testable import VoxClipCore

/// shared/looks/clip-looks.json and its loader (looks spec §4). The C# twin `ClipLookLibraryTests` checks the same file.
@Suite(.offlineFixtures) struct ClipLookLibraryTests {
    static func library() throws -> ClipLookLibrary { try ClipLookLibrary.load(shared: SharedResources(root: FixtureLoader.sharedRoot())) }
    static func document() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(ClipLookLibrary.path)) }

    /// The shipped file with one look's field replaced (nil removes it).
    static func changed(_ id: String, _ key: String, _ value: JSONValue?) throws -> Data {
        guard case .object(var root) = try document(), case .array(var looks) = root["looks"],
              let index = looks.firstIndex(where: { $0[ai: "id"] == .string(id) }), case .object(var look) = looks[index] else {
            throw VoxClipError.sharedResourcesMissing
        }
        look[key] = value
        if value == nil { look.removeValue(forKey: key) }
        looks[index] = .object(look)
        root["looks"] = .array(looks)
        return try JSONEncoder().encode(JSONValue.object(root))
    }

    @Test func theFileHoldsTwentyFourLooksInSixCategories() throws {
        let library = try Self.library()
        #expect(library.categories.map(\.id) == ["natural", "bright", "warm", "film", "cinematic", "bw"])
        #expect(library.categories.map(\.label) == ["Natural", "Bright", "Warm", "Film", "Cinematic", "B&W"])
        #expect(library.looks.map(\.id) == ["original", "muted", "naturalBoost", "softSkin", "evenLight", "studioClean", "softLight",
                                            "brightAiry", "cleanPop", "boldPop", "warm", "goldenHour", "peachTone", "vintageFade",
                                            "coolFilm", "warmPrint", "matteFilm", "throwback", "tealAmber", "cinematicSoft", "moody",
                                            "bw", "softBW", "sepia"])
        #expect(library.visible.count == 24)
        #expect(Dictionary(grouping: library.looks, by: \.category).mapValues(\.count) ==
                ["natural": 6, "bright": 4, "warm": 3, "film": 5, "cinematic": 3, "bw": 3])
        for look in library.looks {
            #expect(!look.line.isEmpty && !look.pickWhen.isEmpty && (0...100).contains(look.plannerAmount), "\(look.id)")
            #expect(look.grade.fix == .neutral && look.grade.amount == 100 && look.grade.preset == nil, "\(look.id)")
        }
        let warmPrint = try #require(library.look("warmPrint"))
        #expect(warmPrint.label == "Warm Print" && warmPrint.category == "film" && warmPrint.strength == .medium)
        #expect(warmPrint.plannerAmount == 85 && warmPrint.base == .original && !warmPrint.classic && !warmPrint.hidden)
        #expect(warmPrint.adjustments == ClipColorAdjustments(saturation: -10, warmth: 26))
        #expect(warmPrint.grade == ClipColorGrade(highlights: -12, fade: 20, grain: 20, curve: ClipToneCurve(master: [0, 245, 500, 760, 965]),
                                                  splitTone: ClipSplitTone(shadowHue: 200, shadowSaturation: 10, highlightHue: 38,
                                                                           highlightSaturation: 30, balance: 0)))
        #expect(library.look("sepia")?.grade.splitTone == ClipSplitTone(shadowHue: 30, shadowSaturation: 60, highlightHue: 40, highlightSaturation: 40, balance: 0))
        #expect(library.measure["auto"]?["balanceLimit"] == 40 && library.measure["light"]?["dimFaceLuma"] == 0.3)
    }

    /// Today's eight looks keep their IDs, labels and values, and are the file's classic looks; the four Mac presets that
    /// were an enum now come from the file.
    @Test func todaysEightLooksAreTheClassicOnesUnchanged() throws {
        let library = try Self.library()
        let classic = library.looks.filter(\.classic)
        #expect(Set(classic.map(\.id)) == ["original", "muted", "warm", "bw", "cleanPop", "softLight", "coolFilm", "vintageFade"])
        for look in classic { #expect(look.grade == .neutral, "\(look.id)") }
        for base in ClipLook.allCases {
            let look = try #require(library.look(base.rawValue))
            #expect(look.base == base && look.adjustments == nil && look.label == base.label)
        }
        #expect(library.look("cleanPop")?.adjustments == ClipColorAdjustments(brightness: 8, contrast: 22, saturation: 18))
        #expect(library.look("softLight")?.adjustments == ClipColorAdjustments(brightness: 26, contrast: -16, saturation: -8))
        #expect(library.look("coolFilm")?.adjustments == ClipColorAdjustments(contrast: 23, saturation: -22, warmth: -30))
        #expect(library.look("vintageFade")?.adjustments == ClipColorAdjustments(brightness: 8, contrast: -36, saturation: -32, warmth: 30))
        #expect(classic.map(\.label).sorted() == ["As filmed", "B&W", "Clean Pop", "Cool Film", "Muted", "Soft Light", "Vintage Fade", "Warm"])
    }

    /// A shipped look never changes: a retune ships under a new ID and the old entry stays, hidden if need be
    /// (shared/fixtures/looks/frozen-looks.json is the last release's looks).
    @Test func shippedLooksAreFrozen() throws {
        let library = try Self.library()
        let frozen = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/looks/frozen-looks.json"))
        #expect(frozen[ai: "format"] == .string("voxclip-frozen-looks/1"))
        let shipped = try #require(Self.document()[ai: "looks"].aiArray)
        #expect(!frozen[ai: "looks"].aiArray.isEmpty)
        for entry in frozen[ai: "looks"].aiArray {
            let id = try #require(entry[ai: "id"].aiString)
            let current = try #require(shipped.first { $0[ai: "id"].aiString == id }, "\(id) was removed")
            for key in ["label", "base", "adjustments", "grade"] { #expect(current[ai: key] == entry[ai: key], "\(id).\(key) changed") }
            #expect(library.look(id) != nil)
        }
    }

    /// For every look but As filmed, the label with case and non-letters dropped is the ID with case dropped.
    @Test func idsFollowTheLabels() throws {
        for look in try Self.library().looks where look.id != "original" {
            #expect(look.label.lowercased().filter(\.isLetter) == look.id.lowercased(), "\(look.id)")
        }
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ClipLookLibrary.parse(Self.changed("warmPrint", "label", .string("Warm Prints"))) }
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ClipLookLibrary.parse(Self.changed("tealAmber", "label", .string("Teal and Amber"))) }
    }

    /// Presets never set the Fix, and every field is checked as strictly as a project's colorGrade.
    @Test(arguments: [
        ("goldenHour", "grade", #"{"highlights":-20,"temperature":10}"#),
        ("goldenHour", "grade", #"{"exposure":5}"#),
        ("goldenHour", "grade", #"{"tint":-3}"#),
        ("goldenHour", "grade", #"{"amount":80}"#),
        ("goldenHour", "grade", #"{"preset":"goldenHour"}"#),
        ("goldenHour", "grade", #"{"glow":10}"#),
        ("goldenHour", "grade", #"{"vibrance":101}"#),
        ("goldenHour", "grade", #"{"fade":-1}"#),
        ("goldenHour", "grade", #"{"grain":10.5}"#),
        ("warmPrint", "grade", #"{"curve":{"master":[0,500,400,760,965]}}"#),
        ("warmPrint", "grade", #"{"curve":{}}"#),
        ("warmPrint", "grade", #"{"splitTone":{"shadowHue":360,"shadowSaturation":10,"highlightHue":38,"highlightSaturation":30,"balance":0}}"#),
        ("warmPrint", "adjustments", #"{"warmth":101}"#),
        ("warmPrint", "adjustments", #"{"gamma":1}"#),
        ("warmPrint", "base", #""sepia""#),
        ("warmPrint", "category", #""vintage""#),
        ("warmPrint", "strength", #""bold""#),
        ("warmPrint", "planner", #"{"pickWhen":"x","amount":101}"#),
        ("warmPrint", "planner", #"{"amount":85}"#),
        ("warmPrint", "line", #""""#),
        ("warmPrint", "classic", #""no""#),
        ("warmPrint", "hidden", #""yes""#),
        ("warmPrint", "id", #""muted""#),
        ("warmPrint", "id", #""warm-print""#),
        ("warmPrint", "unexpected", #"true"#),
    ])
    func aBrokenLookIsRefused(_ id: String, _ key: String, _ json: String) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ClipLookLibrary.parse(Self.changed(id, key, value)) }
    }

    @Test func aHiddenLookStaysKnownButLeavesTheVisibleList() throws {
        let library = try ClipLookLibrary.parse(Self.changed("throwback", "hidden", .bool(true)))
        #expect(library.look("throwback")?.hidden == true)
        #expect(!library.visible.contains { $0.id == "throwback" } && library.visible.count == 23)
    }
}
