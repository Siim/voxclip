import Foundation
import Testing
@testable import VoxClipCore

@Suite("Speech word assembly")
struct WordAssemblyTests {
    @Test func whisperGroupingAndEvents() throws {
        let result = try WordAssembler.group(RecordedSpeech.whisper, rule: GroupingRule(end: .nextWordStart, conf: .mean, bracketEvents: true), timelineStart: 0.5)
        #expect(result.map(\.text) == ["Tere,", "maailm", "(soft music)", "[laughs]"])
        #expect(result[0].start == 0.5)
        #expect(result[0].end == 1)
        #expect(abs((result[0].conf ?? 0) - 0.8) < 0.000001)
        #expect(result[1].end == 1.04)
        #expect(result[2].kind == .event)
        #expect(result[2].end == 3.3)
    }
    @Test func groupsAndEventsAreHardBoundaries() throws {
        let tokens = [RawToken(text: "one", start: 0, end: 0.2, conf: 0.8, speaker: "a"), RawToken(text: "two", joinsPrevious: true, start: 0.3, end: 0.5, conf: 0.2, group: 1), RawToken(text: "(laughs)", joinsPrevious: true, start: 0.6, end: 1, kind: .event, group: 1), RawToken(text: "three", joinsPrevious: true, start: 1, end: 1.5, group: 1)]
        let result = try WordAssembler.group(tokens, rule: GroupingRule(end: .lastToken, conf: .min, bracketEvents: false), timelineStart: 0)
        #expect(result.count == 4)
        #expect(result[0].speaker == "a")
    }
    @Test func exactJSWhitespace() {
        #expect(SpeechText.trim("\u{FEFF} hi\u{00A0}") == "hi")
        #expect(SpeechText.trim("\u{0085}hi\u{200B}") == "\u{0085}hi\u{200B}")
    }
    @Test func unknownTimingIsDroppedAndConfidencePolicies() throws {
        let tokens = [RawToken(text: "un", conf: 1), RawToken(text: "timed", joinsPrevious: true, conf: 0.2), RawToken(text: "yes", start: 1, end: 2, conf: 0.3)]
        let raw = try WordAssembler.group(tokens, rule: GroupingRule(end: .lastToken, conf: .min, bracketEvents: false), timelineStart: 0)
        #expect(raw[0].conf == 0.2)
        #expect(SpeechEditingImportAdapter.cleanWords(raw, timing: .native).map(\.text) == ["yes"])
    }
    @Test func estonianNeverRoutesToAppleOrCloudImplicitly() throws {
        let local = try LanguageRouter.route(language: .forced("et"), preferred: .whispercpp, installedModels: ["taltech-et-verbatim-2604-q4_0"])
        #expect(local.engine == .whispercpp)
        #expect(local.model == "taltech-et-verbatim-2604-q4_0")
        #expect(throws: VoxClipError.self) { try LanguageRouter.route(language: .forced("et-EE"), preferred: .appleSpeech, installedModels: []) }
        let cloud = try LanguageRouter.route(language: .forced("et"), preferred: .elevenlabs, installedModels: [])
        #expect(cloud.engine == .elevenlabs)
        #expect(throws: VoxClipError.self) { try LanguageRouter.route(language: .auto, preferred: .whispercpp, installedModels: []) }
    }
    @Test func publicEditingSeamsForwardToEditingImport() throws {
        let words = [TimedWord(id: "a", text: "a", start: 0, end: 1)]
        let raw = [RawWord(text: "a", start: 0, end: 1)]
        let envelope = AudioEnvelope(sampleRate: 16000, levels: [Float](repeating: 1, count: 100))
        #expect(try cleanWords(raw, timing: .native) == EditingImport.cleanWords(raw, timing: .native))
        #expect(try tightenIntoSound(words, envelope: envelope, timing: .native) == EditingImport.tightenIntoSound(words, envelope: envelope, timing: .native))
        #expect(try findUnlabeledSpeech(words, envelope: envelope) == EditingImport.findUnlabeledSpeech(words, envelope: envelope))
        let result = try SpeechEditingImportAdapter.pipeline([RawWord(text: "a", start: 0, end: 1)], envelope: nil, timing: .native, verbatim: false, duration: 1.005)
        #expect(!result.refined)
        #expect(result.words.map(\.id) == ["w1"])
    }
    @Test func bracketMergeIsBoundedAndStaysInGroup() throws {
        let tokens = (0..<8).map { RawToken(text: $0 == 0 ? "(start" : "piece\($0)", start: Double($0), end: Double($0) + 0.4) }
            + [RawToken(text: "other)", start: 10, end: 11, group: 1)]
        let words = try WordAssembler.group(tokens, rule: GroupingRule(end: .lastToken, conf: .single, bracketEvents: true), timelineStart: 0)
        #expect(words.count == 3)
        #expect(words[0].text == "(start piece1 piece2 piece3 piece4 piece5 piece6")
        #expect(words[0].end == 6.4)
        #expect(words.last?.text == "other)")
    }
    @Test func punctuationDoesNotEndWhisperWordAndInvalidOriginIsRejected() throws {
        let tokens = [RawToken(text: "hello", start: 0, end: 0.1), RawToken(text: ",", start: 0.2, end: 0.2), RawToken(text: "next", start: 0.6, end: 0.61)]
        let words = try WordAssembler.group(tokens, rule: GroupingRule(end: .nextWordStart, conf: .mean, bracketEvents: false), timelineStart: 0)
        #expect(words[0].end == 0.6)
        #expect(words.last?.end == 0.64)
        #expect(throws: VoxClipError.self) { try WordAssembler.group(tokens, rule: GroupingRule(end: .lastToken, conf: .single, bracketEvents: false), timelineStart: .nan) }
    }
    @Test func sevenDraftBracketEventCloses() throws {
        let tokens = ["(soft", "a", "b", "c", "d", "e", "music)"].enumerated().map {
            RawToken(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.4)
        }
        let words = try WordAssembler.group(tokens, rule: GroupingRule(end: .lastToken, conf: .single, bracketEvents: true), timelineStart: 0)
        #expect(words == [RawWord(text: "(soft a b c d e music)", start: 0, end: 6.4, kind: .event)])
    }
}
