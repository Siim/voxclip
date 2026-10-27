import Foundation

struct ClipFinderRunSummary: Sendable, Equatable {
    let model: String
    let usedFallback: Bool
    let droppedItems: Int
    let inputSHA256: String
    let windowCount: Int
}

extension ClipFinder {
    func loadPrompt() throws -> ClipPromptDocument {
        do { return try ClipPromptDocument(data: Data(contentsOf: shared.root.appendingPathComponent("prompts/clip-finder.json"))) }
        catch { throw VoxClipError.sharedResourcesMissing }
    }

    public func prepare(_ request: ClipFinderRequest, connector: any LLMConnector, model: String) async throws -> [LLMRequest] {
        do { return try await prepareRequests(request, connector: connector, model: model) }
        catch is CancellationError { throw LLMError.cancelled }
    }

    private func prepareRequests(_ request: ClipFinderRequest, connector: any LLMConnector, model: String) async throws -> [LLMRequest] {
        let prompt = try loadPrompt()
        let catalog = try LLMCatalog(shared: shared)
        let builder = ClipRequestBuilder(prompt: prompt, policy: catalog.document[ai: "policy"])
        try checkGates(request, builder: builder)
        try await runner.preflight(connector, feature: .clipFinder, model: model)
        let words = builder.clipWords(request.transcript, corrections: request.corrections)
        let context = try await catalog.resolvedContextTokens(connector: connector, model: model)
        let cap = catalog.connector(connector.id)[ai: "maxOutputTokensCap"].aiInt
        try Task.checkCancellation()
        let estimated = try builder.windows(words: words, preset: request.preset, instruction: request.instruction, contextTokens: context, maxOutputTokensCap: cap, localServer: connector.id == .ollama || connector.id == .lmstudio)
        let windows = try await confirmWindows(estimated, words: words, builder: builder, request: request, connector: connector, context: context, cap: cap)
        return windows.enumerated().map { index, window in
            builder.request(words: words, window: window, preset: request.preset, instruction: request.instruction, windowIndex: index, windowCount: windows.count, timeout: catalog.timeout(for: connector.id, feature: .clipFinder), language: request.transcript.language)
        }
    }

    func execute(_ request: ClipFinderRequest, connector: any LLMConnector, model: String) async throws -> ProjectAIResult {
        guard !active else { throw LLMError.unavailable(reason: "Clip finder is already running.") }
        active = true
        lastRun = nil
        defer { active = false }
        let prompt = try loadPrompt()
        let catalog = try LLMCatalog(shared: shared)
        let builder = ClipRequestBuilder(prompt: prompt, policy: catalog.document[ai: "policy"])
        try checkGates(request, builder: builder)
        try await runner.preflight(connector, feature: .clipFinder, model: model)
        let words = builder.clipWords(request.transcript, corrections: request.corrections)
        let lines = try formatTranscript(words)
        let context = try await catalog.resolvedContextTokens(connector: connector, model: model)
        let cap = catalog.connector(connector.id)[ai: "maxOutputTokensCap"].aiInt
        try Task.checkCancellation()
        let estimated = try builder.windows(words: words, preset: request.preset, instruction: request.instruction, contextTokens: context, maxOutputTokensCap: cap, localServer: connector.id == .ollama || connector.id == .lmstudio)
        var windows = try await confirmWindows(estimated, words: words, builder: builder, request: request, connector: connector, context: context, cap: cap)
        var candidates: [ClipCandidate] = []
        var lastTopicEnd: Int?
        var dropped = 0
        var fallback = false
        var fallbackModel: String?
        var answeringModel = model
        var index = 0
        var shrunk: Set<Int> = []
        while index < windows.count {
            try Task.checkCancellation()
            let window = windows[index]
            let canonical = builder.request(words: words, window: window, preset: request.preset, instruction: request.instruction, windowIndex: index, windowCount: windows.count, lastTopicEnd: lastTopicEnd, timeout: catalog.timeout(for: connector.id, feature: .clipFinder), language: request.transcript.language)
            let result: LLMResult
            do { result = try await runner.run(canonical, on: connector, model: model) }
            catch LLMError.contextTooLong where connector.id == .appleFoundation && !shrunk.contains(window.lines.first?.firstIndex ?? -1) {
                let start = window.lines.first!.firstIndex
                let end = window.lines.last!.lastIndex
                shrunk.insert(start)
                let smallerContext = context - Int(ceil(Double(window.tokenBudget) / builder.tokenPolicy.safetyFactor * 0.2))
                let smaller = try builder.windows(words: Array(words[start...end]), preset: request.preset, instruction: request.instruction, contextTokens: smallerContext, maxOutputTokensCap: cap)
                guard smaller.count > 1 else { throw LLMError.contextTooLong }
                for item in smaller { if let first = item.lines.first { shrunk.insert(first.firstIndex) } }
                windows.replaceSubrange(index...index, with: smaller)
                continue
            }
            dropped += result.droppedItems
            fallback = fallback || result.usedFallback
            if result.usedFallback { fallbackModel = result.model }
            answeringModel = result.model
            let items = try JSONDecoder().decode([ClipCandidate].self, from: result.object[ai: "clips"].aiEncoded())
            candidates += items
            let valid = try finalizeClips(items, words: request.transcript.words, preset: ClipPreset(id: request.preset.id, label: request.preset.label, instruction: request.preset.instruction, minSeconds: request.preset.minSeconds, maxSeconds: request.preset.maxSeconds, maxClips: Int.max, noOverlap: false), lines: lines.lines, options: FinalizeClipsOptions(snap: request.snap, limits: prompt.document[ai: "limits"]))
            if let end = valid.map(\.endWord).max() { lastTopicEnd = max(lastTopicEnd ?? -1, end) }
            index += 1
        }
        try Task.checkCancellation()
        var suggestions = try finalizeClips(candidates, words: request.transcript.words, preset: request.preset, lines: lines.lines, options: FinalizeClipsOptions(snap: request.snap, cutWordIds: request.cutWordIds, windowCount: windows.count, limits: prompt.document[ai: "limits"]))
        for position in suggestions.indices where suggestions[position].title.isEmpty {
            let clip = suggestions[position]
            let ownText = words[clip.startWord...clip.endWord].map(\.text).joined(separator: " ")
            var title = AIText.prefix(ownText, utf16: prompt.document[ai: "limits"][ai: "titleMaxLength"].aiInt ?? 120)
            if title.utf16.count < ownText.utf16.count, let space = title.lastIndex(of: " ") { title = String(title[..<space]) }
            suggestions[position].title = AIText.trim(title).isEmpty ? "…" : AIText.trim(title)
        }
        let block = (prompt.document[ai: "transcriptBlock"][ai: "prefix"].aiString ?? "") + lines.rendered + (prompt.document[ai: "transcriptBlock"][ai: "suffix"].aiString ?? "")
        let instructions = builder.instructions(request.instruction)
        let answered = fallbackModel ?? answeringModel
        let resultModel = (1...128).contains(answered.unicodeScalars.count) ? answered : model
        let result = ProjectAIResult(id: UUID().uuidString.lowercased(), createdAt: Date(), provider: connector.id.rawValue,
                                    model: resultModel, preset: request.preset.id,
                                    instructions: instructions.isEmpty ? nil : instructions, language: request.transcript.language,
                                    inputSha256: AIHash.sha256(block), clips: suggestions.map { clip in
            ProjectAIClip(title: clip.title, reason: clip.reason, score: clip.score,
                          startWordId: request.transcript.words[clip.startWord].id,
                          endWordId: request.transcript.words[clip.endWord].id)
        })
        lastRun = ClipFinderRunSummary(model: result.model, usedFallback: fallback, droppedItems: dropped, inputSHA256: result.inputSha256, windowCount: windows.count)
        return result
    }

    private func checkGates(_ request: ClipFinderRequest, builder: ClipRequestBuilder) throws {
        let messages = builder.prompt.document[ai: "messages"]
        guard !request.transcript.words.isEmpty else { throw ClipFinderGateError.noWords(message: messages[ai: "noWords"].aiString ?? "") }
        guard !request.preset.requiresInstructions || !builder.instructions(request.instruction).isEmpty else {
            throw ClipFinderGateError.needInstructions(message: messages[ai: "needInstructions"].aiString ?? "")
        }
    }

    private func confirmWindows(_ estimated: [ClipWindow], words: [ClipWord], builder: ClipRequestBuilder, request: ClipFinderRequest, connector: any LLMConnector, context: Int, cap: Int?) async throws -> [ClipWindow] {
        guard connector.id == .appleFoundation, let counter = connector as? any LLMTokenCounting, let first = estimated.first else { return estimated }
        let lines = try formatTranscript(words).lines
        let output = min(builder.prompt.document[ai: "generation"][ai: "maxOutputTokens"].aiInt ?? 16000, cap ?? 1500)
        let schemaCost = builder.tokenPolicy.estimate(try builder.prompt.document[ai: "output"][ai: "schema"].aiCompact())
        let systemCost = try await counter.tokenCount(for: builder.prompt.document[ai: "system"].aiString ?? "")
        let overlap = min(request.preset.maxSeconds, builder.prompt.document[ai: "limits"][ai: "windowOverlapMaxSeconds"].aiDouble ?? 90)
        let maxWords = builder.prompt.document[ai: "limits"][ai: "maxWordsPerRequest"].aiInt ?? 8000
        var confirmed: [ClipWindow] = []
        var start = 0
        while start < lines.count {
            var end = start
            var estimatedCost = 0
            while end < lines.count {
                let line = lines[end]
                let cost = builder.tokenPolicy.estimate(line.text + "\n") + (line.pauseAfter.map { builder.tokenPolicy.estimate($0 + "\n") } ?? 0)
                if end > start && (estimatedCost + cost > first.tokenBudget || line.lastPos - lines[start].firstPos + 1 > maxWords) { break }
                estimatedCost += cost
                end += 1
            }
            while true {
                try Task.checkCancellation()
                let selected = Array(lines[start..<end])
                let window = ClipWindow(lines: selected, estimatedTokens: estimatedCost, tokenBudget: first.tokenBudget, maxClips: 99)
                let canonical = builder.request(words: words, window: window, preset: request.preset, instruction: request.instruction, windowCount: start == 0 && end == lines.count ? 1 : 2, timeout: .seconds(120), language: request.transcript.language)
                let actual = try await counter.tokenCount(for: aiUserContent(canonical))
                if systemCost + actual + schemaCost + output <= context { break }
                guard end - start > 1 else { throw LLMError.contextTooLong }
                end -= 1
                let removed = lines[end]
                estimatedCost -= builder.tokenPolicy.estimate(removed.text + "\n") + (removed.pauseAfter.map { builder.tokenPolicy.estimate($0 + "\n") } ?? 0)
            }
            confirmed.append(ClipWindow(lines: Array(lines[start..<end]), estimatedTokens: estimatedCost, tokenBudget: first.tokenBudget, maxClips: 99))
            if end == lines.count { break }
            let threshold = lines[end - 1].end - overlap
            start = (start + 1..<end).first { lines[$0].start >= threshold } ?? end
        }
        let minimum = builder.prompt.document[ai: "limits"][ai: "windowMinClips"].aiInt ?? 2
        let factor = builder.prompt.document[ai: "limits"][ai: "windowClipFactor"].aiDouble ?? 1.5
        let maxClips = max(minimum, Int(ceil(Double(request.preset.maxClips) * factor / Double(confirmed.count))))
        return confirmed.map { ClipWindow(lines: $0.lines, estimatedTokens: $0.estimatedTokens, tokenBudget: $0.tokenBudget, maxClips: maxClips, maxOutputTokens: output) }
    }
}
