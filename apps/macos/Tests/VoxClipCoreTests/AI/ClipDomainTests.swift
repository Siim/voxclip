import Foundation
import Testing
@testable import VoxClipCore

@Test("Normative F1 transcript line and pause parity") func aiFormatTranscriptF1() throws {
    let result = try formatTranscript(AIClipTestData.f1())
    #expect(result.rendered == AIClipTestData.f1Rendered)
    #expect(result.lines.map(\.firstIndex) == [0,6,11,13,16,17,19,60,66])
    #expect(result.lines[6].lastPos - result.lines[6].firstPos + 1 == 41)
}

@Test("Transcript formatting preserves sparse absolute indices") func aiSparseIndices() throws {
    let words = [ClipWord(index: 40, text: "we", start: 1, end: 2), ClipWord(index: 49, text: "went.", start: 2, end: 3)]
    let formatted = try formatTranscript(words)
    #expect(formatted.rendered == "[40-49] 0:01 we went.")
    #expect(formatted.lines.first?.lastPos == 1)
    #expect(try formatTranscript([]).rendered.isEmpty)
    #expect(throws: LLMError.self) { try formatTranscript([ClipWord(index: 0, text: "a", start: .nan, end: 1)]) }
}

@Test(arguments: [(0.05,"0.1"),(0.15,"0.1"),(0.25,"0.3"),(0.35,"0.3"),(0.45,"0.5"),(1.25,"1.3"),(1.45,"1.4"),(2.05,"2.0"),(2.25,"2.3"),(9.95,"9.9"),(99.95,"100.0"),(1.2499999999999998,"1.2"),(1.2500000000000002,"1.3")])
func aiJSFixedVector(value: Double, expected: String) { #expect(toFixed1(value) == expected) }

@Test(arguments: [(0.0,"0:00"),(5.9,"0:05"),(70.0,"1:10"),(200.0,"3:20"),(4523.7,"75:23")])
func aiTimeVector(value: Double, expected: String) { #expect(AIText.formatTime(value) == expected) }

@Test("Shared exact rounding matches editing fixtures") func aiEditingPauseRoundingFixtures() throws {
    let fixed = try FixtureLoader.decode(JSONValue.self, at: "fixtures/editing/pauses/label-to-fixed.json")
    let durations = fixed[ai: "input"][ai: "durations"].aiArray.compactMap(\.aiDouble)
    let expected = fixed[ai: "expected"][ai: "labels"].aiArray.compactMap(\.aiString)
    #expect(!durations.isEmpty)
    #expect(durations.count == expected.count)
    for (value, label) in zip(durations, expected) { #expect("pause \(toFixed1(value))s" == label) }
    let rounding = try FixtureLoader.decode(JSONValue.self, at: "fixtures/editing/pauses/label-rounding.json")
    for pause in rounding[ai: "expected"][ai: "pauses"].aiArray {
        #expect("pause \(toFixed1(try #require(pause[ai: "duration"].aiDouble)))s" == pause[ai: "label"].aiString)
    }
}

@Test("C1 ranking normalization clamping and stable maxClips") func aiFinalizeC1() throws {
    let candidate = AIClipTestData.candidate
    let candidates = [candidate(0,20,8.6,"  Strong opener  "," r1 "), candidate(10,30,9,"Best","r2"), candidate(10,30,7,"Duplicate","r3"),
                      candidate(50,55,10,"Short","r4"),candidate(40,130,10,"Range","r5"),candidate(60,59,10,"Reversed","r6"),
                      candidate(60,99,12,"Clamped score","r7"),candidate(5.5,30,10,"Fractional","r8"),
                      candidate(20,45,6,String(repeating:"T",count:130),String(repeating:"R",count:310)),
                      candidate(70,90,-3.5,"Low score","r10"),candidate(0,99,9,"Long","r11"),candidate(30,50,6,"Tie A","r12")]
    let result = try finalizeClips(candidates, words: AIClipTestData.words(), preset: AIClipTestData.preset(.best), lines: [], options: FinalizeClipsOptions(snap: false))
    #expect(result.map(\.startWord) == [0,10,20,30,60])
    #expect(result.map(\.score) == [9,9,6,6,10])
    #expect(result[0].title == "Strong opener")
    #expect(result[2].title.utf16.count == 120)
    #expect(result[2].reason.utf16.count == 300)
}

@Test("C2 inclusive topic overlap and C3 score tie ordering") func aiFinalizeC2C3() throws {
    let words = AIClipTestData.words()
    let candidate = AIClipTestData.candidate
    let topics = try finalizeClips([candidate(0,30,7,"A","a"), candidate(30,60,8,"B","b"),candidate(61,99,6,"C","c"),candidate(70,90,9,"D","d"),candidate(0,20,5,"E","e")], words: words, preset: AIClipTestData.preset(.topics), lines: [], options: FinalizeClipsOptions(snap: false))
    #expect(topics.map(\.title) == ["E","B","D"])
    let quoteCandidates: [ClipCandidate] = (0...7).map { index in
        let startSeconds: Int = 12 * index
        let endSeconds: Int = startSeconds + 5
        let start: Double = Double(startSeconds)
        let end: Double = Double(endSeconds)
        let score: Double = index.isMultiple(of: 2) ? 7 : 8
        return candidate(start, end, score, "Q\(index)", "q")
    }
    let quotes = try finalizeClips(quoteCandidates, words: words, preset: AIClipTestData.preset(.quotes), lines: [], options: FinalizeClipsOptions(snap: false))
    #expect(quotes.map(\.title) == ["Q0","Q1","Q2","Q3","Q5","Q7"])
}

@Test("Mostly-cut and multiwindow near-duplicate extensions") func aiFinalizeExtensions() throws {
    let preset = try AIClipTestData.preset(.best)
    let words = AIClipTestData.words()
    let cut = Set((0...10).map { "w\($0)" } + (30...39).map { "w\($0)" })
    let result = try finalizeClips([AIClipTestData.candidate(0,20),AIClipTestData.candidate(30,50)], words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false, cutWordIds: cut))
    #expect(result.map(\.startWord) == [30])
    let duplicates = [AIClipTestData.candidate(10,30),AIClipTestData.candidate(12,32),AIClipTestData.candidate(40,60,score:7)]
    #expect(try finalizeClips(duplicates, words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap:false, windowCount:2)).map(\.startWord) == [10,40])
    #expect(try finalizeClips(duplicates, words: words, preset: preset, lines: [], options: FinalizeClipsOptions(snap:false)).count == 3)
}

@Test(arguments: [(7,14,6,15),(2,9,0,10),(12,14,11,15),(30,40,30,40),(17,17,17,18),(15,15,15,15)])
func aiSnapVector(start: Int, end: Int, expectedStart: Int, expectedEnd: Int) throws {
    var words = AIClipTestData.words()
    for position in words.indices { words[position].end = words[position].start + 3 }
    let preset = ClipPreset(id:.custom,label:"test",instruction:"",minSeconds:0,maxSeconds:180,maxClips:10,noOverlap:false)
    let lines = try formatTranscript(AIClipTestData.f1()).lines
    let result = try finalizeClips([AIClipTestData.candidate(Double(start),Double(end))], words:words,preset:preset,lines:lines)
    #expect(result.first?.startWord == expectedStart)
    #expect(result.first?.endWord == expectedEnd)
}

@Test("Nonfinite candidates are dropped without invalidating other clips") func aiNonfiniteAndUnicode() throws {
    let preset = try AIClipTestData.preset(.best)
    let title = "\u{FEFF}" + String(repeating:"a",count:119) + "😀x\u{FEFF}"
    let result = try finalizeClips([AIClipTestData.candidate(.nan,20),AIClipTestData.candidate(0,.infinity),AIClipTestData.candidate(0,20,score:.nan),AIClipTestData.candidate(0,20,score:3.5,title:title)], words:AIClipTestData.words(),preset:preset,lines:[],options:FinalizeClipsOptions(snap:false))
    #expect(result.count == 1)
    #expect(result.first?.title == String(repeating:"a",count:119))
    #expect(result.first?.score == 4)
    #expect(AIText.trim("\u{0085}x\u{0085}") == "\u{0085}x\u{0085}")
}

@Test("SHA-256 vectors for caching and input identity") func aiHashVectors() {
    #expect(AIHash.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(AIHash.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}
