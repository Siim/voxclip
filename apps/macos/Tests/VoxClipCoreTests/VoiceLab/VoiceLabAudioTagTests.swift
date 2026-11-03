import Foundation
import Testing
@testable import VoxClipCore

@Suite("Audio tag annotations", .offlineFixtures)
struct VoiceLabAudioTagTests {
    @Test func sharedEdgeExtentsAndTrimBoundaries() throws {
        for row in try fixture()[ai: "edgeExtents"].aiArray {
            let rate = try #require(row[ai: "sampleRate"].aiInt)
            var samples = [Float](repeating: 0, count: try #require(row[ai: "sampleCount"].aiInt))
            for run in row[ai: "sampleRuns"].aiArray {
                let bounds = run.aiArray.compactMap(\.aiInt)
                for index in bounds[0]..<bounds[1] { samples[index] = 0.1 }
            }
            let words = try JSONDecoder().decode([VoiceLabWord].self, from: row[ai: "words"].aiEncoded())
            let characters = try row[ai: "characters"].aiArray.map { timing in
                VoiceLabCharacterTiming(character: try #require(timing[ai: "character"].aiString),
                    start: try #require(timing[ai: "start"].aiDouble), end: try #require(timing[ai: "end"].aiDouble))
            }
            let extended = VoiceLabAudioTags.edgeExtent(words: words, samples: samples, sampleRate: rate,
                tags: try tags(row[ai: "audioTags"]), tokenCount: try #require(row[ai: "tokenCount"].aiInt),
                modelID: try #require(row[ai: "modelID"].aiString), characters: characters)
            #expect(abs(extended.first!.start - (row[ai: "expectedStart"].aiDouble ?? -1)) < 1e-12, "\(row[ai: "id"])")
            #expect(abs(extended.last!.end - (row[ai: "expectedEnd"].aiDouble ?? -1)) < 1e-12, "\(row[ai: "id"])")
            #expect(extended.map(\.text) == words.map(\.text))
            if let expectedStart = row[ai: "expectedTrimStart"].aiDouble, let expectedEnd = row[ai: "expectedTrimEnd"].aiDouble {
                let trim = try VoiceLabAlignment.trim(words: extended, assetDuration: Double(samples.count) / Double(rate))
                #expect(abs(trim.start - expectedStart) < 1e-12 && abs(trim.end - expectedEnd) < 1e-12)
            }
        }
    }
    @Test func sharedEventFiltersKeepExpectedMultiplicity() throws {
        for row in try fixture()[ai: "eventFilters"].aiArray {
            let expected = VoiceLabTakeQuality.tokens(try #require(row[ai: "expected"].aiString))
            let filtered = VoiceLabAudioTags.filterScribeEvents(recognized: row[ai: "recognized"].aiArray.compactMap(\.aiString),
                expected: expected, hasTags: row[ai: "tagged"] == .bool(true))
            #expect(filtered == row[ai: "filtered"].aiArray.compactMap(\.aiString), "\(row[ai: "id"])")
        }
    }
    private func fixture() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/voice-lab/audio-tag-cases.json"))
    }
    private func tags(_ value: JSONValue) throws -> [VoiceLabAudioTag] {
        try JSONDecoder().decode([VoiceLabAudioTag].self, from: value.aiEncoded())
    }
    @Test func sharedRequestsWhitelistAndDurationAllowances() throws {
        let document = try fixture()
        #expect(document[ai: "schema"].aiString == "voxclip-voice-audio-tags/1")
        for row in document[ai: "requests"].aiArray {
            let words = try #require(row[ai: "words"].aiString)
            let model = try #require(row[ai: "modelID"].aiString)
            let annotations = try tags(row[ai: "audioTags"])
            #expect(VoiceLabAudioTags.requestText(words: words, tags: annotations, modelID: model) == row[ai: "expected"].aiString)
            #expect(abs(VoiceLabAudioTags.allowance(annotations, text: words, modelID: model) - (row[ai: "allowance"].aiDouble ?? -1)) < 1e-12)
        }
        let drop = document[ai: "drop"]
        #expect(VoiceLabAudioTags.validated(try tags(drop[ai: "audioTags"]), text: "Hello there") == (try tags(drop[ai: "expected"])))
        for row in document[ai: "durations"].aiArray {
            let annotation = VoiceLabAudioTag(beforeToken: 1, tag: try #require(row[ai: "tag"].aiString))
            #expect(VoiceLabAudioTags.allowance([annotation], text: "Hello", modelID: "eleven_v4") == row[ai: "seconds"].aiDouble)
        }
    }
    @Test func sharedAlignmentsKeepOnlyTypedWordTimings() throws {
        for row in try fixture()[ai: "alignments"].aiArray {
            let words = try VoiceLabAlignment.words(characters: row[ai: "characters"].aiArray.compactMap(\.aiString),
                starts: row[ai: "starts"].aiArray.compactMap(\.aiDouble), ends: row[ai: "ends"].aiArray.compactMap(\.aiDouble),
                expectedText: try #require(row[ai: "expectedText"].aiString))
            #expect(words.map(\.text) == row[ai: "expectedWords"].aiArray.compactMap(\.aiString))
            #expect(words.map(\.start) == row[ai: "expectedStarts"].aiArray.compactMap(\.aiDouble))
        }
    }
    @Test func normalizedNumbersMapBackToTypedWordsByOrderedDiff() throws {
        for row in try fixture()[ai: "normalized"].aiArray {
            let text = try #require(row[ai: "normalized"].aiString)
            let typed = try #require(row[ai: "typed"].aiString)
            let raw = text.enumerated().map { index, character in
                VoiceLabCharacterTiming(character: String(character), start: Double(index) / 100, end: Double(index + 1) / 100)
            }
            let mapped = try VoiceLabAlignment.retimeNormalized(raw, expectedText: typed)
            let words = try VoiceLabAlignment.words(characters: mapped.map(\.character), starts: mapped.map(\.start), ends: mapped.map(\.end), expectedText: typed)
            #expect(words.map(\.text) == row[ai: "expectedWords"].aiArray.compactMap(\.aiString))
            #expect(words.first?.start == raw.first?.start)
            #expect(words.last?.end == raw.last?.end)
        }
    }
    @Test func nonLexicalScribeEventsNeverLowerTheWordCheck() throws {
        for event in try fixture()[ai: "qaEvents"].aiArray.compactMap(\.aiString) {
            let result = try VoiceLabTakeQuality.evaluate(expected: "Hello there [laughs]", recognized: ["Hello", event, "there"],
                mixed: [Float](repeating: 0.1, count: 480), sampleRate: 24_000, seams: [], speakerScore: nil, threshold: 0.5)
            #expect(result.values.transcriptMatch == 1)
            #expect(!result.failures.contains(.transcript))
        }
    }
    @Test func schemaRoundTripsPreserveOptionalTagsAndOldBytes() throws {
        for row in try fixture()[ai: "roundTrips"].aiArray {
            let original = try row.aiEncoded()
            let decoded = try JSONDecoder().decode(VoiceLabText.self, from: original)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            #expect(try encoder.encode(decoded) == original)
        }
        let bytes = try FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip")
        var project = try JSONProjectStore.decode(bytes)
        project.voiceLab.segments[0].text?.audioTags = [VoiceLabAudioTag(beforeToken: 1, tag: "laughs")]
        try VoiceLabProject.validate(project)
    }
    @Test func structuredSuggestionsDropUnknownTagsAndCapDensity() throws {
        let value = try #require(StrictJSON.parse(#"[{"beforeToken":0,"tag":"shouts"},{"beforeToken":0.5,"tag":"laughs"},{"beforeToken":1,"tag":"laughs"},{"beforeToken":1,"tag":"sighs"}]"#))
        #expect(VoiceLabAudioTags.parse(value, text: "Hello there") == [VoiceLabAudioTag(beforeToken: 1, tag: "laughs")])
        #expect(VoiceLabAudioTags.sanitizedRequest("Hello [laughs] there [shouts]", modelID: "eleven_multilingual_v2") == "Hello  there ")
        #expect(VoiceLabAudioTags.sanitizedRequest("Hello [laughs] there [shouts]", modelID: "eleven_v4") == "Hello [laughs] there ")
    }
    @Test func wordCheckExcludesExpressionAnnotations() {
        #expect(VoiceLabTakeQuality.tokens("Hello [short pause] there [laughs]") == ["hello", "there"])
    }

    @Test func annotationsFollowEditedWordsWithoutBecomingWords() {
        let tags = [VoiceLabAudioTag(beforeToken: 1, tag: "laughs"), VoiceLabAudioTag(beforeToken: 2, tag: "sighs")]
        let edited = VoiceLabAudioTags.reanchored(tags, from: "Hello there", to: "Well Hello there now")
        #expect(edited == [.init(beforeToken: 2, tag: "laughs"), .init(beforeToken: 4, tag: "sighs")])
        #expect(VoiceLabAudioTags.reanchored(edited, from: "Well Hello there now", to: "Hello there") == tags)
        #expect(VoiceLabAudioTags.reanchored(tags, from: "Hello there", to: "Hello") == [.init(beforeToken: 1, tag: "laughs"), .init(beforeToken: 1, tag: "sighs")])
    }

    @Test func repeatedWordsDoNotStealAnotherHunksTags() throws {
        let source = ["Hello", "one", "two", "three", "old"].enumerated().map { index, text in
            TimedWord(id: "w\(index)", text: text, start: Double(index), end: Double(index + 1))
        }
        let result = try VoiceLabWordDiff.diff(source: source, newText: "Hello one two three Hello",
            audioTags: [.init(beforeToken: 1, tag: "laughs"), .init(beforeToken: 5, tag: "sighs")])
        #expect(result.hunks.count == 1)
        #expect(result.hunks.first?.audioTags == [.init(beforeToken: 1, tag: "sighs")])
    }

    @Test func alignmentSkipsTagCharacters() throws {
        let text = "Hello [laughs] there"
        let characters = text.map(String.init)
        let starts = characters.indices.map { Double($0) * 0.01 }
        let ends = starts.map { $0 + 0.01 }
        let words = try VoiceLabAlignment.words(characters: characters, starts: starts, ends: ends, expectedText: "Hello there")
        #expect(words.map(\.text) == ["Hello", "there"])
        #expect(words.last?.start == 0.15)
    }
}
