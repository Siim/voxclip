import Foundation
import Testing
@testable import VoxClipCore

@Suite(.serialized) struct EditingPerformance {
    @Test func bulkOperationsResolveActiveClipOnce() throws {
        let words = (0..<10_000).map { position in
            TimedWord(id: "word-\(position)", text: "um", start: Double(position) * 2, end: Double(position) * 2 + 0.3)
        }
        let clip = ClipRange(id: "scope", startWordId: words[2500].id, endWordId: words[7499].id)
        var state = EditState(transcript: EditingFixtures().transcript(words, duration: 20_000),
                              pauses: try detectPauses(words, thresholdSeconds: 0.8), clips: [clip], activeClipId: clip.id)
        let start = ContinuousClock.now
        state = EditReducer.reduce(state, command: .cutFillers)
        #expect(state.cutWordIds.count == 5000)
        state = EditReducer.reduce(state, command: .tightenPauses)
        #expect(state.cutPauseIds.count == 4999)
        #expect(state.summary.cutWordCount == 5000)
        state = EditReducer.reduce(state, command: .restoreCuts)
        #expect(state.cutWordIds.isEmpty && state.cutPauseIds.isEmpty)
        #expect(state.summary.fillerCount == 5000)
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        print("Editing active-clip bulk operations: 10,000 words; cut fillers + tighten + restore + two summaries: \(milliseconds) ms")
        #if !DEBUG
        #expect(milliseconds < 50)
        #endif
    }

    @Test(arguments: [false, true]) func rebuildTenThousandWordsWithTwoThousandCuts(pauseCuts: Bool) throws {
        var segments = (0..<10_000).map { position in
            let start = Double(position) * 0.5
            return EditSegment(id: "word-\(position)", kind: .word, start: start, end: start + 0.3, cut: !pauseCuts && position % 5 == 2)
        }
        if pauseCuts {
            segments += stride(from: 2, to: 10_000, by: 5).map { position in
                EditSegment(id: "pause-\(position)", kind: .pause, start: segments[position].end, end: segments[position + 1].start, cut: true)
            }
        }
        var elapsed: [Double] = []
        for iteration in 0..<21 {
            let start = ContinuousClock.now
            let plan = try buildEditPlan(segments, duration: 5000, sampleRate: 48000, pauseKeepSeconds: pauseCuts ? 0.05 : 0.15)
            let duration = start.duration(to: .now).components
            if iteration > 0 { elapsed.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15) }
            #expect(plan.cuts.count == 2000)
        }
        elapsed.sort()
        let median = elapsed[elapsed.count / 2]
        print("Editing plan rebuild: 10,000 words / 2,000 \(pauseCuts ? "pause" : "word") cuts; median \(median) ms; p95 \(elapsed[18]) ms; max \(elapsed.last!) ms (20 runs)")
        #if !DEBUG
        #expect(median < 10)
        #endif
    }

    @Test(arguments: ["words", "pauses", "mixed", "alternating"])
    func fullRebuildIncludesCaptionCopyAndSummary(_ scenario: String) throws {
        let words = (0..<10_000).map { position in
            TimedWord(id: "word-\(position)", text: "speech", start: Double(position) * 0.5, end: Double(position) * 0.5 + 0.3)
        }
        let pauses = try detectPauses(words, thresholdSeconds: 0.1)
        let clip = ClipRange(id: "scope", startWordId: words[100].id, endWordId: words[9800].id)
        let cutWords = words.enumerated().filter { scenario != "pauses" && $0.offset % (scenario == "alternating" ? 2 : 5) == 0 }.map { $0.element.id }
        let cutPauses = pauses.enumerated().filter { (scenario == "pauses" || scenario == "mixed") && $0.offset % 5 == 2 }.map { $0.element.id }
        let state = EditState(transcript: EditingFixtures().transcript(words, duration: 5000), pauses: pauses,
                              pauseThresholdSeconds: 0.1, pauseKeepSeconds: 0.05, cutWordIds: Set(cutWords), cutPauseIds: Set(cutPauses),
                              clips: [clip], activeClipId: clip.id)
        func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: end).components
            return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        }
        var totals: [Double] = [], segmentTimes: [Double] = [], planTimes: [Double] = [], captionTimes: [Double] = [], summaryTimes: [Double] = []
        for iteration in 0..<21 {
            let start = ContinuousClock.now
            let segments = try buildSegments(state, activeClip: state.activeClip)
            let afterSegments = ContinuousClock.now
            let plan = try buildEditPlan(segments, duration: 5000, sampleRate: 48000, pauseKeepSeconds: state.pauseKeepSeconds)
            let afterPlan = ContinuousClock.now
            let captions = captionCopy(segments, plan: plan)
            let afterCaptions = ContinuousClock.now
            let summary = state.summary
            let end = ContinuousClock.now
            if iteration > 0 {
                totals.append(milliseconds(start, end))
                segmentTimes.append(milliseconds(start, afterSegments))
                planTimes.append(milliseconds(afterSegments, afterPlan))
                captionTimes.append(milliseconds(afterPlan, afterCaptions))
                summaryTimes.append(milliseconds(afterCaptions, end))
            }
            #expect(!captions.isEmpty && summary.canExport && plan.outputSamples > 0)
            #expect(captions.count <= 9701)
        }
        totals.sort()
        let median = totals[totals.count / 2], captionMedian = captionTimes.sorted()[captionTimes.count / 2]
        print("Editing full rebuild: 10,000 words; \(scenario); median \(median) ms; p95 \(totals[18]) ms; max \(totals.last!) ms (20 runs); stage medians: segments \(segmentTimes.sorted()[10]) ms, plan \(planTimes.sorted()[10]) ms, captions \(captionMedian) ms, summary \(summaryTimes.sorted()[10]) ms")
        #if !DEBUG
        #expect(captionMedian < 10)
        #expect(median < 10)
        #endif
    }
}
