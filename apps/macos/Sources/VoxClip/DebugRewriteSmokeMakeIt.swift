#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

// S-make-it and S-make-top3 (doc/release.md): ✦ Make it postable on the smoke's synthetic recording. The planner and the
// music sources are stubs; the voice is the real MakeItRewriteDriver on Rewrite's own session with the smoke's scripted
// ElevenLabs, so I1–I7 are checked after every step the driver takes, as they are after every click a user makes.

extension DebugRewriteSmoke {
    static var makeItScenarios: [Definition] { [
        Definition(id: "S-make-it", title: "✦ Make it postable on one clip: one click, one review, Export ready", voiced: 1,
            fixture: Fixture(rewrites: [], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.makeItOneClip()
        },
        Definition(id: "S-make-top3", title: "✦ Make top 3 postable: the best three suggestions, one after another", requiresCompletion: false,
            fixture: Fixture(rewrites: [])) { harness in
            try await harness.makeItTopThree()
        },
    ] }

    /// The index of the first word reading `text` (case and punctuation ignored) at or after `from`.
    static func wordIndex(_ text: String, in words: [TimedWord], from: Int = 0) -> Int? {
        func plain(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = plain(text)
        return words.indices.first { $0 >= from && plain(words[$0].text) == wanted }
    }

    static func makeItPlan(span: ClosedRange<Int>, cut: Int?, rewrite: (range: ClosedRange<Int>, text: String)?, zoom: ClosedRange<Int>?,
                           music: Bool, score: Int, title: String) -> ClipAutopilotPlan {
        ClipAutopilotPlan(startWord: span.lowerBound, endWord: span.upperBound, title: title, hook: "Edit video like a doc",
            cuts: cut.map { [.init(startWord: $0, endWord: $0, kind: .other, reason: "Not needed")] } ?? [],
            rewrites: rewrite.map { [.init(startWord: $0.range.lowerBound, endWord: $0.range.upperBound, text: $0.text, reason: "Plainer words")] } ?? [],
            captions: .init(styleId: "vox-bold", font: .init(family: "Roboto", weight: 900), textCase: .upper, wordsPerCaption: 3),
            look: .init(id: .warm, reason: "Friendly"), speed: .init(rate: 1.1, reason: "A slow start"),
            music: music ? [.init(title: "Calm piano", mood: "calm piano", prompt: "Instrumental calm piano", reason: "Warm under the voice", underVoiceDb: 18)] : [],
            musicPick: music ? 0 : nil,
            zooms: zoom.map { [.init(word: $0.lowerBound, untilWord: $0.upperBound, scale: 1.15, reason: "Land the point")] } ?? [],
            postText: "How cloud tools edit video, in one minute.", score: score, verdict: .implied(by: score), scoreReason: "One idea, clear payoff")
    }

    nonisolated static let makeItLibraryTrack = MusicCandidate(id: "smoke-library", source: .library, title: "Quiet piano", creator: "Smoke", license: .cc0,
        sourceUrl: "https://example.com/quiet-piano", audioURL: URL(string: "https://example.com/quiet-piano.wav"), fileExtension: "wav",
        durationSeconds: 60, reason: "calm piano")
}

extension DebugRewriteSmoke.Harness {
    /// The planner requests a scenario's stub received.
    private static var requests: [ObjectIdentifier: [ClipAutopilotRequest.Mode]] = [:]
    var planRequests: [ClipAutopilotRequest.Mode] {
        get { Self.requests[ObjectIdentifier(self)] ?? [] }
        set { Self.requests[ObjectIdentifier(self)] = newValue }
    }

    /// Leaves the Rewrite the harness opened by itself: Make it postable opens its own.
    /// `plan` answers one span of a request; a `.clips` request (Make top 3) gets one plan per span, as the service does.
    private func makeItPrepare(_ plan: @escaping @MainActor (ClosedRange<Int>, [TimedWord]) -> ClipAutopilotPlan?) throws -> EditorModel {
        guard let editor else { throw DebugRewriteSmoke.Failure.setup("no editor") }
        session?.close(); editor.closeRewrite(returnFocus: false); session = nil
        // The record is keyed by the harness's identity, which a later harness may reuse: each scenario starts empty.
        planRequests = []
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.05, count: 48_000), rate: 16_000)
        editor.musicPanel.services = MusicPanelServices(suggest: { _, _ in MusicSuggestionResult(candidates: [DebugRewriteSmoke.makeItLibraryTrack]) },
                                                        fetch: { _ in wav }, folder: { nil })
        editor.makeIt.services = MakeItServices(
            plan: { [weak self] request, _, progress in
                let spans: [ClosedRange<Int>]
                switch request.mode {
                case .clip(let span): spans = [span]
                case .clips(let chosen): spans = chosen
                case .series: spans = []
                }
                self?.planRequests.append(request.mode)
                for index in spans.indices { progress(.planning(clip: index, of: spans.count)) }
                let plans = spans.compactMap { plan($0, request.transcript.words) }
                guard !plans.isEmpty else { throw LLMError.invalidOutput(reason: "no smoke plan") }
                for index in spans.indices { progress(.planned(clip: index, of: spans.count)) }
                return ClipAutopilotSeries(plans: plans)
            },
            voice: MakeItServices.live.voice,
            voiceAvailable: { _ in true })
        editor.makeItGeneration = { [weak self] session in await self?.adopt(session) }
        editor.makeItStepObserver = { [weak self] action in
            guard let self else { return }
            await settle()
            try? await observe(action)
        }
        return editor
    }

    /// Appends checks to the last observed step.
    private func makeItAppend(_ checks: [DebugRewriteSmoke.Check]) {
        guard let last = steps.popLast() else { return }
        var step = DebugRewriteSmoke.Step(index: last.index, action: last.action, snapshot: last.snapshot, checks: last.checks + checks, capture: last.capture)
        step.seconds = last.seconds; step.waits = last.waits
        steps.append(step)
    }

    func makeItOneClip() async throws {
        var span: ClosedRange<Int> = 0...0
        let editor = try makeItPrepare { range, words in
            span = range
            guard let first = DebugRewriteSmoke.wordIndex("we", in: words, from: range.lowerBound),
                  let last = DebugRewriteSmoke.wordIndex("take", in: words, from: first),
                  let cut = DebugRewriteSmoke.wordIndex("then", in: words, from: last),
                  let keep = DebugRewriteSmoke.wordIndex("keep", in: words, from: cut) else { return nil }
            return DebugRewriteSmoke.makeItPlan(span: range, cut: cut, rewrite: (first...last, "we film a quick clip in one take."),
                                                zoom: keep...(keep + 2), music: true, score: 8, title: "Edit video like a doc")
        }
        let words = editor.project.transcript?.words ?? []
        guard let start = DebugRewriteSmoke.wordIndex("first", in: words), let end = DebugRewriteSmoke.wordIndex("drag", in: words, from: start) else {
            throw DebugRewriteSmoke.Failure.setup("the script lost its second to fourth sentences")
        }
        editor.apply(.addClip(ClipRange(id: "smoke-clip", startWordId: words[start].id, endWordId: words[end].id, title: "Smoke clip",
                                        origin: .manual, selected: true)), name: "Make clip")
        _ = editor.setScope("smoke-clip")
        await editor.makeIt.refreshVoiceReady(editor)
        let cap = editor.makeItCap(clipID: "smoke-clip")
        let steps = editor.undoSteps
        try await act("click [\(editor.makeItTitle(clipID: "smoke-clip"))]", clicked: "makeIt") {
            editor.makeItPostable("smoke-clip")
            await editor.makeIt.run(for: "smoke-clip")?.task?.value
        }
        completed = applied; ended = true
        guard let run = editor.makeIt.run(for: "smoke-clip") else { throw DebugRewriteSmoke.Failure.setup("no run") }
        let rewrite = run.rows.first { $0.id == "rewrite-0" }
        let next = editor.makeItNextStep(run)
        let renderChecks = await makeItRenderChecks(editor, run: run)
        makeItAppend([
            DebugRewriteSmoke.Check(invariant: "M1", passed: run.phase == .ready && next.hasPrefix("Next: Export") && span.lowerBound == start,
                detail: "\(editor.makeItHeadline(run)) · \(next)"),
            DebugRewriteSmoke.Check(invariant: "M2", passed: editor.undoSteps == steps + 1, detail: "\(editor.undoSteps - steps) undo step(s) for the run"),
            DebugRewriteSmoke.Check(invariant: "M3", passed: cap.map { run.spent <= $0 } ?? (run.spent == 0),
                detail: "spent \(EditorModel.makeItDollars(run.spent)) of up to \(cap.map(EditorModel.makeItDollars) ?? "nothing")"),
            DebugRewriteSmoke.Check(invariant: "M4", passed: rewrite?.undoable == true && MusicProject.entry(for: "smoke-clip", in: editor.project) != nil,
                detail: (rewrite.map { "\($0.text) · \($0.detail)" } ?? "no rewrite row") + " · music " + (MusicProject.entry(for: "smoke-clip", in: editor.project)?.title ?? "none")),
        ] + renderChecks)
    }

    /// M5: the plan's look and speed are on the clip, each with an Undo row. M6: the export is the rendered length the
    /// review's headline shows (edited ÷ speed), through the real exporter.
    private func makeItRenderChecks(_ editor: EditorModel, run: MakeItRun) async -> [DebugRewriteSmoke.Check] {
        let controls = ClipControlsProject.controls(for: run.clipID, in: editor.project)
        let look = run.rows.first { $0.id == "look" }, speed = run.rows.first { $0.id == "speed" }
        var checks = [DebugRewriteSmoke.Check(invariant: "M5",
            passed: controls?.look == .warm && controls?.speed == 1.1 && look?.undoable == true && speed?.undoable == true,
            detail: "clip \(controls.map { "\($0.speed)× \($0.look.rawValue)" } ?? "none") · \(look?.text ?? "no look row") · \(speed?.text ?? "no speed row")")]
        do {
            let request = try await editor.renderRequest(target: .clip(run.clipID))
            let folder = directory.appendingPathComponent("S-make-it", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let video = folder.appendingPathComponent("clip.mp4")
            defer { try? FileManager.default.removeItem(at: video) }
            let result = try await AVExporter().export(ExportJob(target: .clip(run.clipID), render: request, outputURL: video)) { _ in }
            let frame = 1 / request.output.fps
            checks.append(DebugRewriteSmoke.Check(invariant: "M6",
                passed: request.clipControls?.speed == 1.1 && abs(result.durationSeconds - run.seconds) <= frame && abs(request.renderedDuration - run.seconds) < 0.001,
                detail: String(format: "export %.3f s, review %.3f s, edited %.3f s at 1.1×", result.durationSeconds, run.seconds, request.timeline.duration)))
        } catch {
            checks.append(DebugRewriteSmoke.Check(invariant: "M6", passed: false, detail: "export failed: \(error)"))
        }
        return checks
    }

    func makeItTopThree() async throws {
        let editor = try makeItPrepare { range, words in
            let score = words[range.lowerBound].text.count % 3 + 7
            return DebugRewriteSmoke.makeItPlan(span: range, cut: range.count > 4 ? range.lowerBound + 1 : nil, rewrite: nil, zoom: nil,
                                                music: false, score: score, title: "Clip at \(range.lowerBound)")
        }
        let words = editor.project.transcript?.words ?? []
        let sentences = ["first", "then", "the", "finally"].compactMap { DebugRewriteSmoke.wordIndex($0, in: words) }
        guard sentences.count == 4 else { throw DebugRewriteSmoke.Failure.setup("the script lost a sentence") }
        let scores = [6, 9, 7, 5]
        var project = editor.project
        let clips = sentences.enumerated().map { offset, start in
            ProjectAIClip(title: "Suggestion \(offset + 1)", reason: "Smoke", score: scores[offset], startWordId: words[start].id,
                          endWordId: words[min(words.count - 1, start + 5)].id)
        }
        project.ai.results = [ProjectAIResult(id: "smoke-result", createdAt: Date(timeIntervalSince1970: 0), provider: "smoke", model: "smoke",
                                              preset: .best, inputSha256: String(repeating: "0", count: 64), clips: clips)]
        project.edits.clips = clips.enumerated().map { offset, clip in
            ClipRange(id: "smoke-\(offset)", startWordId: clip.startWordId, endWordId: clip.endWordId, title: clip.title, origin: .ai,
                      aiResultId: "smoke-result", aiClipIndex: offset, selected: false)
        }
        editor.replace(project, name: "Find clips")
        let ranked = editor.suggestedClips.prefix(3).map(\.id)
        let steps = editor.undoSteps
        try await act("click [✦ Make top 3 postable]", clicked: "makeTop") {
            editor.makeTopPostable(3)
            await editor.makeIt.waitForQueue()
        }
        let runs = ranked.compactMap { editor.makeIt.run(for: $0) }
        makeItAppend([
            DebugRewriteSmoke.Check(invariant: "T1", passed: ranked == ["smoke-1", "smoke-2", "smoke-0"] && editor.makeIt.series == ranked,
                detail: "ranked " + ranked.joined(separator: ", ")),
            DebugRewriteSmoke.Check(invariant: "T2", passed: runs.count == 3 && runs.allSatisfy { $0.phase == .ready },
                detail: runs.map { "\($0.clipID) \(editor.makeItHeadline($0))" }.joined(separator: "; ")),
            DebugRewriteSmoke.Check(invariant: "T3", passed: ranked.allSatisfy { !editor.isSuggestion($0) } && editor.isSuggestion("smoke-3"),
                detail: "kept: " + editor.keptClips.map(\.id).joined(separator: ", ")),
            DebugRewriteSmoke.Check(invariant: "T4", passed: editor.undoSteps == steps + 3, detail: "\(editor.undoSteps - steps) undo steps for 3 runs"),
            DebugRewriteSmoke.Check(invariant: "T5", passed: planRequests.count == 1 && { if case .clips(let spans) = planRequests[0] { spans.count == 3 } else { false } }(),
                detail: "\(planRequests.count) planner request(s): " + planRequests.map { "\($0)" }.joined(separator: "; ")),
        ])
    }
}
#endif
