import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

/// Claude mode's planner (ai.md §16.6): Find Clips' moments in a `clips` request, at most three plans in flight, each plan
/// sent to the caller the moment it is ready, and a cancel that reaches every plan in flight. Stub connectors only; nothing
/// waits on a clock.
@Suite struct ClipAutopilotStreamingTests {
    /// Holds clip-plan sends until the test opens it; counts how many wait at once and how many were cancelled.
    private actor Hold {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var inFlight = 0
        private(set) var most = 0
        private(set) var cancelled = 0
        private var watchers: [(count: Int, wake: CheckedContinuation<Void, Never>)] = []
        private var cancelWatchers: [(count: Int, wake: CheckedContinuation<Void, Never>)] = []
        func enter() async {
            inFlight += 1; most = max(most, inFlight)
            wake()
            if !open { await withCheckedContinuation { waiting.append($0) } }
            inFlight -= 1
        }
        func release() { open = true; let all = waiting; waiting = []; for continuation in all { continuation.resume() } }
        func cancel() { cancelled += 1; wake(); release() }
        /// Returns once `count` sends wait here.
        func waitUntil(inFlight count: Int) async {
            guard inFlight < count else { return }
            await withCheckedContinuation { watchers.append((count, $0)) }
        }
        /// Returns once `count` sends saw the cancel.
        func waitUntil(cancelled count: Int) async {
            guard cancelled < count else { return }
            await withCheckedContinuation { cancelWatchers.append((count, $0)) }
        }
        private func wake() {
            let sends = watchers.filter { inFlight >= $0.count }, cancels = cancelWatchers.filter { cancelled >= $0.count }
            watchers.removeAll { inFlight >= $0.count }; cancelWatchers.removeAll { cancelled >= $0.count }
            for watcher in sends + cancels { watcher.wake.resume() }
        }
    }

    private actor Stub: LLMConnector {
        nonisolated let id = ConnectorID.ollama
        let hold: Hold
        private(set) var requests: [LLMRequest] = []
        init(hold: Hold) { self.hold = hold }
        func status() -> ConnectorStatus { .ready }
        func models(refresh: Bool) -> [LLMModel] { [.init(id: "fixture", name: "Fixture", contextTokens: 256_000, source: .curated)] }
        func contextTokens(model: String) -> Int? { 256_000 }
        func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
            requests.append(request)
            let hold = self.hold
            await withTaskCancellationHandler { await hold.enter() } onCancel: { Task { await hold.cancel() } }
            if Task.isCancelled { throw LLMError.cancelled }
            return RawCompletion(text: try ClipAutopilotV2Tests.planReply(request), model: model, stop: .complete)
        }
    }

    private final class Events: Sendable {
        private let store = Mutex<[ClipAutopilotProgress]>([])
        func add(_ event: ClipAutopilotProgress) { store.withLock { $0.append(event) } }
        var all: [ClipAutopilotProgress] { store.withLock { $0 } }
    }

    private static func moments(_ spans: [ClosedRange<Int>]) -> [ClipAutopilotMoment] {
        spans.enumerated().map { ClipAutopilotMoment.found($0.element, title: "Found \($0.offset + 1)", reason: "Reason \($0.offset + 1).", score: 9 - $0.offset) }
    }

    @Test(.timeLimit(.minutes(1)))
    func findClipsMomentsPlanAtMostThreeAtOnceEachToldTheOthersAndSentAsReady() async throws {
        let hold = Hold()
        let main = Stub(hold: hold), lanes = [Stub(hold: hold), Stub(hold: hold), Stub(hold: hold)]
        let spans = [0...14, 15...29, 30...44, 45...59, 60...74]
        let input = ClipAutopilotRequest(transcript: try ClipAutopilotV2Tests.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1),
                                         mode: .clips(spans), moments: Self.moments(spans))
        let service = ClipAutopilotService(runner: try ClipAutopilotTests.runner(), shared: try ClipAutopilotTests.shared())
        let events = Events()
        let run = Task { try await service.plan(input, connector: main, model: "fixture", lanes: lanes, progress: { events.add($0) }) }
        await hold.waitUntil(inFlight: 3)
        #expect(await hold.inFlight == 3, "the first three plan at once")
        await hold.release()
        let result = try await run.value
        #expect(await hold.most == 3, "never more than three in flight")
        #expect(await lanes[2].requests.isEmpty, "a fourth lane is never used")
        var sent = await main.requests
        for lane in lanes { sent += await lane.requests }
        #expect(sent.count == 5 && sent.allSatisfy { $0.tag == "clip-autopilot-series-clip" && $0.effort == .xhigh })
        // Each plan knows its rank, Find Clips' title and reason, and the other clips by title and start; no caption style
        // is suggested, since Find Clips picks none.
        let first = try #require(sent.first { $0.instruction.contains("from word 0 to word 14") })
        #expect(first.instruction.hasPrefix("This clip is moment 1 of 5 picked from a longer video for a series: “Found 1”. Reason 1.\n"
            + "The other clips of this series: “Found 2” at 0:"), "\(first.instruction.prefix(300))")
        #expect(first.instruction.contains("“Found 5” at ") && !first.instruction.contains("“Found 1” at ") && !first.instruction.contains("Caption style picked"))
        #expect(try await service.request(input, connector: .ollama).instruction == first.instruction, "the first request is the one sent")
        #expect(result.series.plans.count == 5)
        // Every clip's plan is sent as ready between its planning and planned events.
        let all = events.all
        for clip in 0..<5 {
            let planning = try #require(all.firstIndex(of: .planning(clip: clip, of: 5)))
            let ready = try #require(all.firstIndex { if case .ready(clip, 5, let plan) = $0 { spans[clip].contains(plan.startWord) } else { false } })
            let planned = try #require(all.firstIndex(of: .planned(clip: clip, of: 5)))
            #expect(planning < ready && ready < planned)
        }
        await #expect(throws: VoiceLabError.invalidInput) {
            try await service.plan(ClipAutopilotRequest(transcript: try ClipAutopilotV2Tests.transcript(), mode: .clips(spans), moments: Self.moments([0...14])),
                                   connector: main, model: "fixture")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingThePlanStopsEveryPlanInFlight() async throws {
        let hold = Hold()
        let main = Stub(hold: hold), lanes = [Stub(hold: hold), Stub(hold: hold)]
        let spans = [0...14, 15...29, 30...44, 45...59]
        let input = ClipAutopilotRequest(transcript: try ClipAutopilotV2Tests.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1),
                                         mode: .clips(spans), moments: Self.moments(spans))
        let service = ClipAutopilotService(runner: try ClipAutopilotTests.runner(), shared: try ClipAutopilotTests.shared())
        let run = Task { try await service.plan(input, connector: main, model: "fixture", lanes: lanes) }
        await hold.waitUntil(inFlight: 3)
        run.cancel()
        await #expect(throws: (any Error).self) { try await run.value }
        await hold.waitUntil(cancelled: 3)
        #expect(await hold.cancelled == 3, "all three plans in flight saw the cancel")
        var sent = await main.requests
        for lane in lanes { sent += await lane.requests }
        #expect(sent.count == 3, "the fourth clip is never sent")
    }
}
