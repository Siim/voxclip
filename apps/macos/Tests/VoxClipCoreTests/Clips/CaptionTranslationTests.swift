import Foundation
import Testing
@testable import VoxClipCore

/// Ask Claude's translated captions (ai.md §18.2): shared/fixtures/caption-translations/caption-translation-cases.json,
/// replayed by both Cores (Windows replays the wire cases), and the edits that store and take them back.
@Suite struct CaptionTranslationTests {
    private static func fixture() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/caption-translations/caption-translation-cases.json"))
    }
    private static func base() throws -> [String: JSONValue] {
        try #require(JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(ClipControlsProjectWireTests.fixture)).aiObject)
    }
    private static func project(_ item: JSONValue, key: String = "captionTranslations") throws -> Project {
        var object = try base()
        object["captionTranslations"] = item[ai: key]
        if let version = item[ai: "version"].aiInt { object["schemaVersion"] = .number(Double(version)) }
        return try ProjectJSON.decode(JSONValue.object(object).aiEncoded())
    }
    private static func words(_ value: JSONValue) throws -> [CaptionWord] { try JSONDecoder().decode([CaptionWord].self, from: value.aiEncoded()) }

    @Test("The file is the generator's, in its own format")
    func fixtureShape() throws {
        let fixture = try Self.fixture()
        #expect(fixture[ai: "schema"].aiString == "voxclip-caption-translation-cases/1" && fixture[ai: "baseProject"].aiString == ClipControlsProjectWireTests.fixture)
        #expect(fixture[ai: "wire"][ai: "valid"].aiArray.count == 4 && fixture[ai: "wire"][ai: "invalid"].aiArray.count == 14)
        #expect(fixture[ai: "spread"].aiArray.count == 9)
    }

    @Test("A project stores each valid list unchanged and refuses each invalid one")
    func wire() throws {
        for item in try Self.fixture()[ai: "wire"][ai: "valid"].aiArray {
            let project = try Self.project(item)
            let saved = try JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encode(project))
            #expect(saved[ai: "captionTranslations"] == item[ai: "captionTranslations"], "\(item[ai: "id"])")
            #expect(try ProjectJSON.decode(ProjectJSON.encode(project)) == project)
        }
        for item in try Self.fixture()[ai: "wire"][ai: "invalid"].aiArray {
            #expect(throws: (any Error).self, "\(item[ai: "id"])") { try Self.project(item) }
        }
    }

    @Test("A translation's words spread over the shown words of its range; the clip's own first, bleeps stay masked")
    func spread() throws {
        for item in try Self.fixture()[ai: "spread"].aiArray {
            let project = try Self.project(item, key: "translations")
            let bleeped = item[ai: "bleeped"].aiArray.compactMap(\.aiString)
            let effects = bleeped.isEmpty ? [] : [ClipEffect(id: "fx-bleep-1", clipId: nil, kind: .bleep, start: 0, end: 3, wordIds: bleeped)]
            let words = CaptionTranslations.applying(try Self.words(item[ai: "words"]), project: project, clipID: item[ai: "clipId"].aiString, effects: effects)
            #expect(words == (try Self.words(item[ai: "expected"])), "\(item[ai: "id"].aiString ?? ""): \(words.map(\.text))")
            #expect(Set(words.map(\.id)).count == words.count, "unique ids")
        }
    }

    @Test("Translating stores the words' captions (promoting to v4, replacing an overlap in its scope); undoing puts back the base's")
    func translatingAndUntranslating() throws {
        let legacy = try ProjectJSON.decode(FixtureLoader.data("fixtures/projects/interview-take.voxclip"))
        #expect(legacy.schemaVersion < 4)
        let first = try CaptionTranslations.translating(1...3, clipID: nil, language: "ES", text: "  hola mundo ", in: legacy)
        let words = try #require(first.transcript?.words)
        #expect(first.schemaVersion == 4)
        #expect(first.captionTranslations == [CaptionTranslation(id: "tr-1", clipId: nil, startWordId: words[1].id, endWordId: words[3].id, language: "es", text: "hola mundo")])
        let second = try CaptionTranslations.translating(3...5, clipID: nil, language: "de", text: "hallo", in: first)
        #expect(second.captionTranslations.map(\.id) == ["tr-1"] && second.captionTranslations.first?.language == "de", "the overlap is replaced")
        let back = try CaptionTranslations.untranslating(3...5, clipID: nil, base: first, from: second)
        #expect(back.captionTranslations == first.captionTranslations)
        #expect(try CaptionTranslations.untranslating(1...3, clipID: nil, base: nil, from: first).captionTranslations.isEmpty)
        #expect(throws: (any Error).self) { try CaptionTranslations.translating(1...3, clipID: nil, language: "Spanish", text: "hola", in: legacy) }
        // Removing the clip or replacing the transcript drops what names it.
        var clipped = first
        clipped.edits.clips = [ClipRange(id: "c1", startWordId: words[0].id, endWordId: words[6].id)]
        clipped = try CaptionTranslations.translating(4...5, clipID: "c1", language: "fr", text: "bonjour", in: clipped)
        try clipped.applyEditing(.removeClip(id: "c1"))
        #expect(clipped.captionTranslations.map(\.clipId) == [nil])
        clipped.replaceTranscript(try #require(first.transcript))
        #expect(clipped.captionTranslations.isEmpty)
    }
}
