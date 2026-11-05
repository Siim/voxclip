import Foundation
import Testing
@testable import VoxClipCore

/// Each clip's caption look (design.md §6.6): shared/fixtures/clip-style/caption-look-cases.json, replayed by both Cores,
/// and the rules that record Claude's and the creator's picks.
@Suite struct CaptionLookTests {
    private static let cases = "fixtures/clip-style/caption-look-cases.json"
    private static func fixture() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(cases)) }
    private static func base() throws -> [String: JSONValue] {
        try #require(JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(ClipControlsProjectWireTests.fixture)).aiObject)
    }
    private static func style(_ picks: [String: JSONValue]) -> JSONValue {
        .object(["preset": .string("auto"), "captions": .string("auto"), "music": .string("auto"), "maxLengthSec": .number(60),
                 "shapes": .array([.string("16:9"), .string("9:16")]), "rewording": .string("fix-only"), "captionPicks": .object(picks)])
    }
    private static func project(_ object: [String: JSONValue]) throws -> Project { try ProjectJSON.decode(JSONValue.object(object).aiEncoded()) }

    @Test("The shared file is the generator's, with its own schema id")
    func fixtureShape() throws {
        let fixture = try Self.fixture()
        #expect(fixture[ai: "schema"].aiString == "voxclip-caption-look-cases/1")
        #expect(fixture[ai: "wire"][ai: "valid"].aiArray.count == 6 && fixture[ai: "wire"][ai: "invalid"].aiArray.count == 7)
        #expect(fixture[ai: "resolve"].aiArray.count == 6)
    }

    @Test("A project stores each valid pick byte-for-byte and refuses each invalid one")
    func wire() throws {
        let fixture = try Self.fixture(), base = try Self.base()
        for item in fixture[ai: "wire"][ai: "valid"].aiArray {
            var object = base
            object["clipStyle"] = Self.style(["clip-1": item[ai: "pick"]])
            let project = try Self.project(object)
            let saved = try JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encode(project))
            #expect(saved[ai: "clipStyle"][ai: "captionPicks"][ai: "clip-1"] == item[ai: "pick"], "\(item[ai: "id"])")
            #expect(try ProjectJSON.decode(ProjectJSON.encode(project)) == project)
        }
        for item in fixture[ai: "wire"][ai: "invalid"].aiArray {
            var object = base
            object["clipStyle"] = Self.style(["clip-1": item[ai: "pick"]])
            #expect(throws: (any Error).self, "\(item[ai: "id"])") { try Self.project(object) }
        }
    }

    @Test("Each clip renders with its own pick when one applies, else the project's captions")
    func resolution() throws {
        let base = try Self.base()
        for item in try Self.fixture()[ai: "resolve"].aiArray {
            var object = base
            var captions = try #require(object["captions"]?.aiObject)
            captions["styleId"] = item[ai: "captions"][ai: "styleId"]
            captions["overrides"] = item[ai: "captions"][ai: "overrides"]
            object["captions"] = .object(captions)
            if item[ai: "clipStyle"] != .null { object["clipStyle"] = item[ai: "clipStyle"] }
            let project = try Self.project(object)
            for (clip, expected) in item[ai: "expected"].aiObject ?? [:] {
                let settings = project.captionSettings(forClip: clip.isEmpty ? nil : clip)
                let id = "\(item[ai: "id"].aiString ?? "") \(clip)"
                #expect(settings.styleId == expected[ai: "styleId"].aiString, "\(id)")
                #expect(JSONValue.object(settings.overrides) == expected[ai: "overrides"], "\(id)")
                #expect(settings.position == project.captions.position && settings.positionByAspect == project.captions.positionByAspect)
                #expect(project.resolvingCaptions(forClip: clip.isEmpty ? nil : clip).captions == settings)
            }
        }
    }

    @Test("Claude never replaces the creator's pick; Make it's look records under Auto or its fixed style only")
    func recordingRules() throws {
        let upper: [String: JSONValue] = ["text": .object(["transform": .string("uppercase")])]
        var auto = ClipStyle(preset: .auto, captions: .auto, music: .auto, maxLengthSec: 60, shapes: [.landscape], rewording: .fixOnly)
        auto.captionPicks["mine"] = ClipCaptionPick(styleId: "glow", reason: "", by: .user)
        let recorded = auto.recording(["mine": .init(styleId: "marker", reason: "Later."), "new": .init(styleId: "minimal", reason: "New.")])
        #expect(recorded.captionPicks["mine"]?.styleId == "glow" && recorded.captionPicks["new"]?.styleId == "minimal")

        let look = ClipCaptionPick(styleId: "marker", reason: "Bold.", overrides: upper, by: .user)
        #expect(auto.recordingLook(look, forClip: "mine") == nil)
        let made = try #require(auto.recordingLook(look, forClip: "clip-2"))
        #expect(made.captionPicks["clip-2"] == ClipCaptionPick(styleId: "marker", reason: "Bold.", overrides: upper, by: .ai))
        let fixed = auto.fixingCaptions(.style("marker"))
        #expect(fixed.recordingLook(look, forClip: "clip-2")?.captionPick(forClip: "clip-2")?.overrides == upper)
        #expect(fixed.recordingLook(ClipCaptionPick(styleId: "glow", reason: ""), forClip: "clip-2") == nil)
        #expect(auto.fixingCaptions(.off).recordingLook(look, forClip: "clip-2") == nil)

        // The creator's choice keeps the clip's overrides only for the same style.
        let current = CaptionSettings(styleId: "marker", overrides: upper)
        #expect(auto.choosingCaptionStyle("marker", forClip: "c", current: current).captionPicks["c"]?.overrides == upper)
        let other = auto.choosingCaptionStyle("minimal", forClip: "c", current: current).captionPicks["c"]
        #expect(other == ClipCaptionPick(styleId: "minimal", reason: "", overrides: nil, by: .user))
        #expect(fixed.choosingCaptionStyle("minimal", forClip: "c", current: current).captionStyle(forClip: "c") == "minimal")
        #expect(fixed.captionStyle(forClip: "mine") == "glow" && fixed.captionStyle(forClip: "other") == "marker")
    }
}
