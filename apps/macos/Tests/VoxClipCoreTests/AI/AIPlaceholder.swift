import Foundation
import Testing
@testable import VoxClipCore

@Test("AI shared prompt and schema contracts") func macAI() throws {
    let prompt = try AIClipTestData.prompt()
    #expect(prompt.presets.map(\.id) == [.best, .hooks, .topics, .quotes, .custom])
    let catalog = try LLMCatalog(shared: SharedResources(root: FixtureLoader.sharedRoot()))
    let tighten = try FixtureLoader.decode(JSONValue.self, at: "prompts/ai-tighten.json")
    for schema in [prompt.document[ai: "output"][ai: "schema"], tighten[ai: "output"][ai: "schema"], catalog.document[ai: "testRequest"][ai: "schema"]] {
        #expect(CanonicalResponseParser.validateSchemaSubset(schema))
    }
    #expect(prompt.document[ai: "limits"][ai: "titleMaxLength"].aiInt == 120)
    #expect(prompt.document[ai: "limits"][ai: "reasonMaxLength"].aiInt == 300)
    #expect(prompt.document[ai: "limits"][ai: "snapRadiusWords"].aiInt == 3)
    #expect(prompt.document[ai: "limits"][ai: "mostlyCutFraction"].aiDouble == 0.5)
    #expect(prompt.document[ai: "limits"][ai: "nearDuplicateOverlap"].aiDouble == 0.6)
}

enum AIClipTestData {
    static func prompt() throws -> ClipPromptDocument { try ClipPromptDocument(data: FixtureLoader.data("prompts/clip-finder.json")) }
    static func preset(_ id: ClipPresetID) throws -> ClipPreset { try #require(prompt().presets.first { $0.id == id }) }
    static func words(_ count: Int = 100) -> [TimedWord] {
        (0..<count).map { TimedWord(id: "w\($0)", text: "w\($0)", start: Double($0), end: Double($0) + 0.8) }
    }
    static func candidate(_ start: Double, _ end: Double, score: Double = 8, title: String = " T ", reason: String = " R ") -> ClipCandidate {
        ClipCandidate(title: title, reason: reason, score: score, startWord: start, endWord: end)
    }
    static func f1() -> [ClipWord] {
        let initial: [(String, Double, Double)] = [
            ("So,",0,0.3),("today",0.35,0.7),("I",0.75,0.85),("want",0.85,1.1),("to",1.1,1.2),("talk.",1.2,1.6),
            ("Um",3.85,4.1),("why",4.2,4.45),("cut",4.5,4.8),("by",4.85,5),("words?",5,5.4),
            ("\"It",5.5,5.7),("works.\"",5.7,6.2),("Fast",7.45,7.8),("and",7.85,8),("clean",8.05,8.5),
            ("Tere!",70,70.4),("Mis",70.5,70.7),("toimub?",70.75,71.2),("「本当",71.3,71.6),("です。」",71.6,72)
        ]
        var words = initial.enumerated().map { ClipWord(index: $0.offset, text: $0.element.0, start: $0.element.1, end: $0.element.2) }
        words += (21...65).map { index in
            let start = Double(721 + (index - 21) * 3) / 10
            let end = Double(7235 + (index - 21) * 30) / 100
            return ClipWord(index: index, text: "w\(index)", start: start, end: end)
        }
        words.append(ClipWord(index: 66, text: "end.", start: 200, end: 200.5))
        return words
    }
    static var f1Rendered: String {
        ["[0-5] 0:00 So, today I want to talk.", "(pause 2.3s)", "[6-10] 0:03 Um why cut by words?", "[11-12] 0:05 \"It works.\"",
         "[13-15] 0:07 Fast and clean", "(pause 61.5s)", "[16-16] 1:10 Tere!", "[17-18] 1:10 Mis toimub?",
         "[19-59] 1:11 「本当 です。」 " + (21...59).map { "w\($0)" }.joined(separator: " "),
         "[60-65] 1:23 " + (60...65).map { "w\($0)" }.joined(separator: " "), "(pause 114.5s)", "[66-66] 3:20 end."].joined(separator: "\n")
    }
}
