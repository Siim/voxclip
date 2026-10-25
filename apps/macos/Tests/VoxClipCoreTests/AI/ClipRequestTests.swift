import Foundation
import Testing
@testable import VoxClipCore

@Test("Rendered prompts match shared templates for every preset") func aiPromptParity() throws {
    let prompt = try AIClipTestData.prompt()
    let builder = ClipRequestBuilder(prompt: prompt)
    let raw = try FixtureLoader.decode(JSONValue.self, at: "prompts/clip-finder.json")
    let words = AIClipTestData.f1()
    for preset in prompt.presets {
        for input in ["", "  Funny bits  "] {
            let window = try #require(builder.windows(words:words,preset:preset,instruction:input,contextTokens:128000).first)
            let request = builder.request(words:words,window:window,preset:preset,instruction:input,timeout:.seconds(180))
            var expected = ["The recording is 3:20 long."]
            if !preset.instruction.isEmpty { expected.append(preset.instruction) }
            if !input.isEmpty { expected.append((preset.instruction.isEmpty ? "" : "Also: ") + "Funny bits") }
            #expect(request.system == raw[ai:"system"].aiString)
            #expect(request.cachedBlock == "<transcript>\n" + AIClipTestData.f1Rendered + "\n</transcript>")
            #expect(request.instruction == expected.joined(separator:"\n"))
            #expect(request.schema == raw[ai:"output"][ai:"schema"])
            #expect(request.maxOutputTokens == raw[ai:"generation"][ai:"maxOutputTokens"].aiInt)
        }
    }
}

@Test("W1 windows retain absolute numbers with time-based overlap") func aiW1Windows() throws {
    let builder = ClipRequestBuilder(prompt:try AIClipTestData.prompt())
    let words = (0..<20000).map { index in ClipWord(index:index,text:"w\(index)" + (index % 15 == 14 ? "." : ""),start:0.3 * Double(index),end:0.3 * Double(index) + 0.25) }
    let preset = try AIClipTestData.preset(.best)
    let windows = try builder.windows(words:words,preset:preset,contextTokens:128000)
    #expect(windows.count == 3)
    #expect(windows.map { $0.lines.first?.firstIndex } == [0,7800,15600])
    #expect(windows.map { $0.lines.last?.lastIndex } == [7994,15794,19999])
    #expect(windows.allSatisfy { $0.maxClips == 3 })
    let request = builder.request(words:words,window:windows[1],preset:preset,windowIndex:1,windowCount:3,timeout:.seconds(180))
    #expect(request.instruction.contains("The recording is 99:59 long."))
    #expect(request.instruction.contains("Return at most 3 clips."))
    #expect(request.cachedBlock?.contains("[7800-7814]") == true)
    let small = try builder.windows(words:words,preset:preset,contextTokens:8192,maxOutputTokensCap:1500)
    #expect(small.count > 3)
    #expect(small.allSatisfy { $0.estimatedTokens <= $0.tokenBudget })
}

@Test("Topics continuation uses covered absolute word numbers") func aiTopicContinuation() throws {
    let builder = ClipRequestBuilder(prompt:try AIClipTestData.prompt())
    let words = AIClipTestData.f1()
    let preset = try AIClipTestData.preset(.topics)
    let window = try #require(builder.windows(words:words,preset:preset,contextTokens:128000).first)
    let request = builder.request(words:words,window:window,preset:preset,windowIndex:1,windowCount:2,lastTopicEnd:49,timeout:.seconds(180))
    #expect(request.instruction.hasSuffix("Topics up to word 49 are already covered. Start at word 50 or later."))
}

@Test("Clip entries include cuts and events with bounded corrections") func aiClipWordsCorrections() throws {
    let transcript = Transcript(words:[TimedWord(id:"a",text:"old",start:0,end:1),TimedWord(id:"b",text:"(laughs)",kind:.event,start:1,end:2),TimedWord(id:"c",text:"not sent",kind:.unlabeledSpeech,start:2,end:3)],durationSeconds:3,engine:EngineRef(id:.whispercpp,engineVersion:"test"),rawKey:"test",createdAt:Date(timeIntervalSince1970:0))
    let builder = ClipRequestBuilder(prompt:try AIClipTestData.prompt())
    let words = builder.clipWords(transcript,corrections:["a":String(repeating:"a",count:99) + "😀", "b":"override"])
    #expect(words.map(\.index) == [0,1,2])
    #expect(words[0].text.utf16.count == 99)
    #expect(words[1].text == "(laughs)")
    #expect(words[2].text == "…")
    #expect(builder.instructions("\u{FEFF}" + String(repeating:"a",count:501) + "\u{FEFF}").utf16.count == 500)
}

@Test("Small context refuses before sending") func aiSmallContext() throws {
    let builder = ClipRequestBuilder(prompt:try AIClipTestData.prompt())
    #expect(throws: LLMError.contextTooLong) {
        try builder.windows(words:AIClipTestData.f1(),preset:AIClipTestData.preset(.best),contextTokens:4096,maxOutputTokensCap:4096)
    }
}

@Test("Unknown prompt schemaVersion fails closed") func aiUnknownPromptVersion() throws {
    let original = try FixtureLoader.decode(JSONValue.self,at:"prompts/clip-finder.json")
    var document = try #require(original.aiObject)
    document["schemaVersion"] = .number(999)
    #expect(throws:VoxClipError.sharedResourcesMissing) { try ClipPromptDocument(data:JSONValue.object(document).aiEncoded()) }
}
