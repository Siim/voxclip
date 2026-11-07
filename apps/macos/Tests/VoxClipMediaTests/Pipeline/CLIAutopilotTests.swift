import Foundation
import Testing
@testable import VoxClipCore
@testable import voxclip_cli

/// Virtual time for the stub connectors: a send waits until the driver reaches its finish time, so no real time passes and
/// nothing sleeps. The driver releases one send at a time, earliest finish first.
private actor Timeline {
    private(set) var now = 0.0
    private var pending: [(finish: Double, tag: String, wake: CheckedContinuation<Void, Never>)] = []
    private var waiters: [(count: Int, wake: CheckedContinuation<Void, Never>)] = []
    private var used: [(count: Int, wake: CheckedContinuation<Void, Never>)] = []
    private(set) var mostPlansAtOnce = 0
    /// Each send's tag and finish time, in the order they finished.
    private(set) var finished: [(tag: String, at: Double)] = []
    /// The virtual time at which the pipeline took each clip (applied it and handed it to export), in that order.
    private(set) var taken: [Double] = []

    func sleep(_ seconds: Double, tag: String) async {
        await withCheckedContinuation { continuation in
            pending.append((now + seconds, tag, continuation))
            mostPlansAtOnce = max(mostPlansAtOnce, pending.filter { $0.tag.hasPrefix("plan") }.count)
            wake()
        }
    }
    func take() { taken.append(now); wake() }
    /// Returns once `count` sends wait.
    func waitForSends(_ count: Int) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    /// Returns once the pipeline took `count` clips.
    func waitForTaken(_ count: Int) async {
        guard taken.count < count else { return }
        await withCheckedContinuation { used.append((count, $0)) }
    }
    /// Moves to the earliest finish and lets that send return.
    func advance() {
        guard let index = pending.indices.min(by: { pending[$0].finish < pending[$1].finish }) else { return }
        let next = pending.remove(at: index)
        now = next.finish
        finished.append((next.tag, now))
        next.wake.resume()
    }
    private func wake() {
        let sends = waiters.filter { pending.count >= $0.count }, clips = used.filter { taken.count >= $0.count }
        waiters.removeAll { pending.count >= $0.count }; used.removeAll { taken.count >= $0.count }
        for waiter in sends + clips { waiter.wake.resume() }
    }
}

/// Claude Code's measured latency shape (doc/agent-clipping-benchmark.md): about 4.6 s to start a call, then time in
/// proportion to the output tokens (thinking included). A plan of 8,000 tokens takes the measured median of 74 s.
private struct LatencyShape: Sendable {
    static let measuredPlan: Double = 74, measuredFind: Double = 77, measuredStartup: Double = 4.6, planOutput: Double = 8000
    var startup = Self.measuredStartup
    var secondsPerToken: Double = (Self.measuredPlan - Self.measuredStartup) / Self.planOutput
    /// Find Clips' output at extra high effort, sized so the call takes the measured 77 s.
    var findTokens: Int = {
        let thinking: Double = Self.measuredFind - Self.measuredStartup
        let perToken: Double = (Self.measuredPlan - Self.measuredStartup) / Self.planOutput
        let tokens: Double = (thinking / perToken).rounded()
        return Int(tokens)
    }()
    /// Each plan's output by rank: the best clip a median plan, the second slower and the third quicker.
    var planTokens = [8000, 10000, 6500]
    func seconds(_ tokens: Int) -> Double { startup + Double(tokens) * secondsPerToken }
}

private actor LatencyStub: LLMConnector {
    nonisolated let id = ConnectorID.ollama
    let timeline: Timeline
    let shape: LatencyShape
    let findReply: String
    init(timeline: Timeline, shape: LatencyShape, findReply: String) { self.timeline = timeline; self.shape = shape; self.findReply = findReply }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [.init(id: "fixture", name: "Fixture", contextTokens: 200_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 200_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        if request.feature == .clipFinder {
            await timeline.sleep(shape.seconds(shape.findTokens), tag: "find")
            return RawCompletion(text: findReply, model: model, stop: .complete)
        }
        guard let span = request.instruction.firstMatch(of: #/Plan the clip from word (\d+) to word (\d+)/#), let start = Int(span.1), let end = Int(span.2),
              let moment = request.instruction.firstMatch(of: #/moment (\d+) of (\d+)/#), let rank = Int(moment.1) else {
            throw LLMError.invalidOutput(reason: "not a Claude mode clip plan")
        }
        await timeline.sleep(shape.seconds(shape.planTokens[(rank - 1) % shape.planTokens.count]), tag: "plan\(rank)")
        if Task.isCancelled { throw LLMError.cancelled }
        // A plan with nothing to cut, built in typed parts so it type-checks quickly.
        var reply: [String: Any] = [:]
        let numbers: [String: Int] = ["startWord": start, "endWord": end, "captionWeight": 900, "wordsPerCaption": 3, "speed": 1, "musicPick": 0, "score": 9 - rank]
        let texts: [String: String] = ["title": "Clip \(rank)", "hook": "Hook \(rank)", "lengthReason": "", "captionStyle": "vox-bold", "captionReason": "punchy",
                                       "captionFont": "Roboto", "captionCase": "upper", "look": "original", "lookReason": "", "speedReason": "",
                                       "postText": "Post \(rank).", "verdict": "post", "scoreReason": "Clear.", "tone": "none", "toneSummary": ""]
        let lists = ["corrections", "cuts", "pauseCuts", "rewrites", "zooms", "music", "questions"]
        for (key, value) in numbers { reply[key] = value }
        for (key, value) in texts { reply[key] = value }
        for key in lists { reply[key] = [Any]() }
        return RawCompletion(text: String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self), model: model, stop: .complete)
    }
}

/// The 29-minute benchmark's shape, synthetic: 2,900 words of short sentences over 1,740 s, a pause every few sentences.
private func benchmarkTranscript() -> Transcript {
    var seed: UInt64 = 20261107
    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
    let vocabulary = "the so and we it that this is was to of in for on with but what like just really think know people software deals business clone because actually going right thing quality quantity build make every somebody nobody would could never always about there here time work product market users money".split(separator: " ").map(String.init)
    var words: [TimedWord] = []
    var time = 0.0
    while words.count < 2900 {
        let length = 6 + Int(next() * 17)
        for position in 0..<length where words.count < 2900 {
            var text = vocabulary[Int(next() * Double(vocabulary.count))]
            if position == length - 1 { text += "." }
            let spoken = 0.18 + next() * 0.3
            words.append(TimedWord(id: "w\(words.count)", text: text, start: time, end: time + spoken))
            time += spoken + 0.05 + next() * 0.1
        }
        time += next() < 0.2 ? 1.6 + next() * 1.5 : 0.3 + next() * 0.5
    }
    let scale = 1740 / (words.last?.end ?? 1)
    words = words.map { TimedWord(id: $0.id, text: $0.text, start: $0.start * scale, end: $0.end * scale) }
    return Transcript(words: words, language: "en", durationSeconds: 1740, engine: EngineRef(id: .whispercpp, engineVersion: "fixture"),
                      rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
}

/// Find Clips' reply: five clips of about 35 s at five places, scored 9…5, as the lines that hold them.
private func findReply(_ transcript: Transcript) throws -> String {
    let words = transcript.words
    let clips: [[String: Any]] = (0..<5).map { index in
        let first = words.firstIndex { $0.start >= Double(index) * 330 + 30 } ?? 0
        let last = words.lastIndex { $0.end <= words[first].start + 35 } ?? first
        let lines = ClipRequestBuilder.lineRange(of: first...last, words: words)
        return ["title": "Moment \(index + 1)", "reason": "Idea \(index + 1).", "score": 9 - index, "start_line": lines.lowerBound, "end_line": lines.upperBound]
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: ["clips": clips]), as: UTF8.self)
}

private func benchmarkProject(_ transcript: Transcript) throws -> Project {
    let shared = try FixtureLoader.sharedRoot(environment: [:])
    var project = try ProjectJSON.decode(Data(contentsOf: shared.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
    project.transcript = transcript
    project.media.source.durationSeconds = transcript.durationSeconds
    project.edits = ProjectEdits()
    return project
}

@Suite("Claude mode, headless: the CLI autopilot and its stub benchmark", .offlineFixtures)
struct CLIAutopilotTests {
    struct Run {
        let find: Double
        /// When each plan finished, by rank.
        let plans: [Double]
        /// When the pipeline took each clip, in the order it did.
        let taken: [Double]
        let mostPlansAtOnce: Int
        let timings: JSONValue
        let clips: [JSONValue]
    }

    /// The stub benchmark scene: the CLI's own pipeline (Find Clips, the top three planned at once, each applied as it is
    /// ready) over three latency stubs on virtual time.
    private func benchmark(shape: LatencyShape = LatencyShape()) async throws -> Run {
        let transcript = benchmarkTranscript()
        let timeline = Timeline()
        let reply = try findReply(transcript)
        let main = LatencyStub(timeline: timeline, shape: shape, findReply: reply)
        let lanes = [LatencyStub(timeline: timeline, shape: shape, findReply: reply), LatencyStub(timeline: timeline, shape: shape, findReply: reply)]
        let shared = try SharedResources.locate()
        let catalog = try LLMCatalog(shared: shared)
        let clock = ClaudeModeClock()
        let project = try benchmarkProject(transcript)
        let run = Task {
            try await CLIWorkflow.autopilot(project: project, connector: main, lanes: lanes, model: "fixture", preset: .best, count: 3,
                                            shared: shared, catalog: catalog, clock: clock, report: AutopilotReport(quiet: true)) { _, _, _ in
                await timeline.take()
                return []
            }
        }
        await timeline.waitForSends(1)
        await timeline.advance()
        // The three plans start together; each one released waits until the pipeline took its clip.
        for done in 0..<3 {
            await timeline.waitForSends(3 - done)
            await timeline.advance()
            await timeline.waitForTaken(done + 1)
        }
        let made = try await run.value
        let finished = await timeline.finished
        let plans = (1...3).map { rank in finished.first { $0.tag == "plan\(rank)" }?.at ?? -1 }
        return Run(find: finished.first { $0.tag == "find" }?.at ?? -1, plans: plans, taken: await timeline.taken,
                   mostPlansAtOnce: await timeline.mostPlansAtOnce, timings: clock.json(), clips: made.clips)
    }

    @Test(.timeLimit(.minutes(1)))
    func eachClipIsTakenTheMomentItsPlanIsReadyAndTheBenchmarkShowsTheGain() async throws {
        let shape = LatencyShape()
        let run = try await benchmark(shape: shape)
        #expect(run.mostPlansAtOnce == 3, "the top three plan at once")
        // Streaming: a clip is taken at its own plan's finish, quickest first, not after the slowest.
        #expect(run.taken == run.plans.sorted(), "\(run.taken) vs \(run.plans)")
        #expect(abs(run.find - shape.seconds(shape.findTokens)) < 1e-9 && abs(run.find - 77) < 0.01)
        #expect(run.clips.count == 3 && run.clips.allSatisfy { $0[ai: "error"] == .null })
        // The numbers. Before (until 2026-11-07) every clip waited for the slowest plan and then applied one after another;
        // now each applies at its own plan's finish. `plans` are finish times from the start; apply is about a second.
        let apply = 1.0, transcription = 53.0
        let slowest = run.plans.max() ?? 0, quickest = run.plans.min() ?? 0
        let before = (first: slowest + apply, all: slowest + 3 * apply)
        let after = (first: quickest + apply, best: run.plans[0] + apply, all: slowest + apply)
        let warm = LatencyShape(startup: 0.5)
        let warmFirst = warm.seconds(warm.findTokens) + (warm.planTokens.map(warm.seconds).min() ?? 0) + apply
        let durations = run.plans.map { $0 - run.find }
        print(String(format: "claude-mode stub benchmark: find %.1f s; plans by rank %.1f / %.1f / %.1f s, three at once; first clip before %.1f s, after %.1f s (the best clip %.1f s); all three before %.1f s, after %.1f s; from the video (+%.0f s local transcription) first clip before %.1f s, after %.1f s; with a 0.5 s warm start %.1f s",
                     run.find, durations[0], durations[1], durations[2], before.first, after.first, after.best, before.all, after.all,
                     transcription, before.first + transcription, after.first + transcription, warmFirst + transcription))
        #expect(after.first < before.first && before.first - after.first > 25, "streaming takes the first clip at the quickest plan")
        // The CLI's timings name each stage it ran, numbers only.
        let stages = run.timings[ai: "stages"].aiArray.compactMap { $0[ai: "stage"].aiString }
        #expect(stages.filter { $0 == "find" }.count == 1 && stages.filter { $0 == "plan" }.count == 3 && stages.filter { $0 == "apply" }.count == 3)
        #expect(run.timings[ai: "firstClipSeconds"] != .null && run.timings[ai: "totalSeconds"].aiDouble != nil)
    }

    @Test func theCommandValidatesItsOptions() throws {
        #expect(throws: (any Error).self) { try Autopilot.parse(["--open", "/tmp/x.mov", "--connector", "nope"]) }
        #expect(throws: (any Error).self) { try Autopilot.parse(["--open", "/tmp/x.mov", "--connector", "claude-code", "--count", "0"]) }
        #expect(throws: (any Error).self) { try Autopilot.parse(["--open", "/tmp/x.mov", "--connector", "claude-code", "--preset", "custom"]) }
        #expect(throws: (any Error).self) { try Autopilot.parse(["--open", "/tmp/x.mov", "--connector", "claude-code", "--aspect", "source"]) }
        let options = try Autopilot.parse(["--open", "/tmp/x.mov", "--connector", "claude-code", "--timings", "--json"])
        #expect(options.count == 3 && options.aspect == "9:16" && options.timings && options.preset == "best")
    }
}
