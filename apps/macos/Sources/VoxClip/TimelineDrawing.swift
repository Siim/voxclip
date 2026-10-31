import Foundation
import VoxClipCore

func timelineSpokenTime(_ time: Double) -> String {
    let finite: Double = time.isFinite ? max(0, time) : 0
    let rounded: Double = finite.rounded(.toNearestOrEven)
    let seconds: Int = Int(min(rounded, Double(Int32.max)))
    guard seconds >= 60 else { return "\(seconds) seconds" }
    let minutes: Int = seconds / 60
    let remainder: Int = seconds % 60
    let tail: String = remainder < 10 ? "0\(remainder)" : String(remainder)
    return "\(minutes) \(seconds < 120 ? "minute" : "minutes") \(tail)"
}

func timelineValueText(time: Double, total: Double, cuts: Int, edited: Bool) -> String {
    "\(timelineSpokenTime(time)) of \(timelineSpokenTime(total))\(edited ? " after cuts" : " source"), \(cuts) cuts"
}

struct TimelineTimeIndex {
    let plan: EditPlan?
    private let removed: [Int64]
    private var previousSample: Int64 = 0
    private var position = 0
    init(plan: EditPlan?) {
        self.plan = plan
        var prefix: [Int64] = [0]
        for cut in plan?.cuts ?? [] { prefix.append(prefix.last! + cut.count) }
        removed = prefix
    }
    mutating func map(_ time: Double) -> Double {
        guard let plan else { return time }
        let rounded = floor((time.isFinite ? time : 0) * plan.sampleRate + 0.5)
        let sample = rounded >= Double(plan.totalSamples) ? plan.totalSamples : Int64(max(0, rounded))
        if sample < previousSample {
            var lower = 0, upper = position
            while lower < upper {
                let middle = (lower + upper) / 2
                if plan.cuts[middle].startSample < sample { lower = middle + 1 } else { upper = middle }
            }
            position = lower
        } else {
            while position < plan.cuts.count, plan.cuts[position].startSample < sample { position += 1 }
        }
        previousSample = sample
        var cutSamples = removed[position]
        if position > 0 { cutSamples -= max(0, plan.cuts[position - 1].endSample - sample) }
        return Double(min(plan.outputSamples, max(0, sample - cutSamples))) / plan.sampleRate
    }
}
