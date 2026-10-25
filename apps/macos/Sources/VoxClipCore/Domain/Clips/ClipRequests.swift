import Foundation

public struct ClipPromptDocument: Sendable, Equatable {
    public let document: JSONValue
    public let presets: [ClipPreset]

    public init(data: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard value[ai: "schemaVersion"].aiInt == 1, value[ai: "system"].aiString != nil,
              CanonicalResponseParser.validateSchemaSubset(value[ai: "output"][ai: "schema"]) else { throw VoxClipError.sharedResourcesMissing }
        document = value
        presets = try JSONDecoder().decode([ClipPreset].self, from: value[ai: "presets"].aiEncoded())
    }
}

public struct ClipWindow: Sendable, Equatable {
    public let lines: [TranscriptLine]
    public let estimatedTokens: Int
    public let tokenBudget: Int
    public let maxClips: Int
    public var maxOutputTokens: Int? = nil
    public var rendered: String { lines.flatMap { [$0.text] + ($0.pauseAfter.map { [$0] } ?? []) }.joined(separator: "\n") }
}

public struct ClipRequestBuilder: Sendable {
    public let prompt: ClipPromptDocument
    let tokenPolicy: AITokenPolicy
    public init(prompt: ClipPromptDocument, policy: JSONValue = .null) { self.prompt = prompt; tokenPolicy = AITokenPolicy(policy) }

    public func clipWords(_ transcript: Transcript, corrections: [String: String] = [:]) -> [ClipWord] {
        let limit = prompt.document[ai: "limits"][ai: "maxWordTextLength"].aiInt ?? 100
        return transcript.words.enumerated().map { index, word in
            let text: String
            switch word.kind {
            case .word: text = corrections[word.id] ?? word.text
            case .event: text = word.text
            case .unlabeledSpeech: text = "…"
            }
            return ClipWord(index: index, text: AIText.prefix(text, utf16: limit), start: word.start, end: word.end)
        }
    }

    public func instructions(_ text: String?) -> String {
        AIText.prefix(AIText.trim(text ?? ""), utf16: prompt.document[ai: "request"][ai: "maxInstructionsLength"].aiInt ?? 500)
    }

    public func windows(words: [ClipWord], preset: ClipPreset, instruction: String? = nil, contextTokens: Int, maxOutputTokensCap: Int? = nil, localServer: Bool = false) throws -> [ClipWindow] {
        guard !words.isEmpty else { return [] }
        let formatted = try formatTranscript(words)
        let document = prompt.document
        let outputReserve = aiOutputReserve(generation: document[ai: "generation"][ai: "maxOutputTokens"].aiInt ?? 16000, cap: maxOutputTokensCap, context: contextTokens, localServer: localServer)
        let overheadInstruction = renderInstruction(words: words, lines: AIWindowPacking.longestTimeLines(formatted.lines), preset: preset, instruction: instruction, windowCount: 2, maxClips: 99, lastTopicEnd: words.last?.index)
        let overhead = tokenPolicy.estimate(document[ai: "system"].aiString ?? "") + tokenPolicy.estimate(overheadInstruction) + tokenPolicy.estimate(try document[ai: "output"][ai: "schema"].aiCompact()) + 64
        let budget = Int(floor(Double(contextTokens - overhead - outputReserve) * tokenPolicy.safetyFactor))
        guard budget >= 600 else { throw LLMError.contextTooLong }
        let maxWords = document[ai: "limits"][ai: "maxWordsPerRequest"].aiInt ?? 8000
        let overlap = min(preset.maxSeconds, document[ai: "limits"][ai: "windowOverlapMaxSeconds"].aiDouble ?? 90)
        let packed = try AIWindowPacking.pack(lines: formatted.lines, budget: budget, maxWords: maxWords, overlap: overlap, tokenPolicy: tokenPolicy)
        let factor = document[ai: "limits"][ai: "windowClipFactor"].aiDouble ?? 1.5
        let minimum = document[ai: "limits"][ai: "windowMinClips"].aiInt ?? 2
        let clipBudget = max(minimum, Int(ceil(Double(preset.maxClips) * factor / Double(packed.count))))
        return packed.map { ClipWindow(lines: Array(formatted.lines[$0.range]), estimatedTokens: $0.estimatedCost, tokenBudget: budget, maxClips: clipBudget, maxOutputTokens: outputReserve) }
    }

    public func request(words: [ClipWord], window: ClipWindow, preset: ClipPreset, instruction: String? = nil, windowIndex: Int = 0, windowCount: Int = 1, lastTopicEnd: Int? = nil, timeout: Duration, language: String? = nil) -> LLMRequest {
        let document = prompt.document
        let block = (document[ai: "transcriptBlock"][ai: "prefix"].aiString ?? "") + window.rendered + (document[ai: "transcriptBlock"][ai: "suffix"].aiString ?? "")
        return LLMRequest(feature: .clipFinder, system: document[ai: "system"].aiString ?? "", cachedBlock: block,
                          instruction: renderInstruction(words: words, lines: window.lines, preset: preset, instruction: instruction, windowCount: windowCount, maxClips: window.maxClips, lastTopicEnd: windowIndex > 0 ? lastTopicEnd : nil),
                          schemaName: document[ai: "output"][ai: "name"].aiString ?? "clips", schema: document[ai: "output"][ai: "schema"],
                          maxOutputTokens: window.maxOutputTokens ?? document[ai: "generation"][ai: "maxOutputTokens"].aiInt ?? 16000,
                          effort: Effort(rawValue: document[ai: "generation"][ai: "effort"].aiString ?? "medium"), timeout: timeout, language: language,
                          tag: "clips/\(preset.id.rawValue)\(windowCount > 1 ? " part \(windowIndex + 1) of \(windowCount)" : "")")
    }

    private func renderInstruction(words: [ClipWord], lines: [TranscriptLine], preset: ClipPreset, instruction: String?, windowCount: Int, maxClips: Int, lastTopicEnd: Int?) -> String {
        let templates = prompt.document[ai: "request"]
        var parts = [(templates[ai: "durationLine"].aiString ?? "").replacingOccurrences(of: "{duration}", with: AIText.formatTime(words.last?.end ?? 0))]
        if !preset.instruction.isEmpty { parts.append(preset.instruction) }
        let custom = instructions(instruction)
        if !custom.isEmpty { parts.append((preset.instruction.isEmpty ? "" : templates[ai: "alsoPrefix"].aiString ?? "") + custom) }
        if windowCount > 1 {
            for template in templates[ai: "windowLines"].aiArray.compactMap(\.aiString) {
                parts.append(template.replacingOccurrences(of: "{windowStart}", with: AIText.formatTime(lines.first?.start ?? 0))
                    .replacingOccurrences(of: "{windowEnd}", with: AIText.formatTime(lines.last?.end ?? 0))
                    .replacingOccurrences(of: "{maxClips}", with: String(maxClips)))
            }
            if preset.id == .topics, let lastTopicEnd {
                parts.append((templates[ai: "topicsContinuationLine"].aiString ?? "")
                    .replacingOccurrences(of: "{lastEnd}", with: String(lastTopicEnd))
                    .replacingOccurrences(of: "{nextWord}", with: String(lastTopicEnd + 1)))
            }
        }
        return parts.joined(separator: "\n")
    }
}
