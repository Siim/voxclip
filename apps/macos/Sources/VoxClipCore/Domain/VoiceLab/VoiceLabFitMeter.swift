import Foundation

public enum VoiceLabFitVerdict: String, Sendable { case fits, willChangeLength }
public struct VoiceLabFitMeterResult: Sendable, Equatable {
    public let estimateSeconds: Double
    public let gapSeconds: Double
    public let lowerBoundSeconds: Double
    public let upperBoundSeconds: Double
    public let verdict: VoiceLabFitVerdict
    public let copy: String
}

public enum VoiceLabFitMeter {
    public static func measure(text: String, window: VoiceLabWindow, incomingSilence: Double?, outgoingSilence: Double?,
                               rate: Double, newWords: String, multipleHunks: Bool = false) throws -> VoiceLabFitMeterResult {
        let geometry = try VoiceLabLengthBudget.geometry(window: window, incomingSilence: incomingSilence, outgoingSilence: outgoingSilence)
        let estimate: Double = try VoiceLabLengthBudget.estimate(text: text, rate: rate)
        let leftPad: Double = pad(window.leftSeam.kind)
        let rightPad: Double = pad(window.rightSeam.kind)
        let lowerLeft: Double = geometry.target - leftPad
        let lower: Double = lowerLeft - rightPad
        let leftBorrow: Double = borrow(window.leftSeam.kind, incomingSilence)
        let rightBorrow: Double = borrow(window.rightSeam.kind, outgoingSilence)
        let upperLeft: Double = geometry.target + leftBorrow
        let upper: Double = upperLeft + rightBorrow
        let verdict: VoiceLabFitVerdict = estimate >= lower && estimate <= upper ? .fits : .willChangeLength
        let ending: String = verdict == .fits ? "fits" : "will change length"
        let prefix: String = multipleHunks ? "“\(newWords)” · " : ""
        let copy: String = prefix + "about \(toFixed1(estimate)) s for a \(toFixed1(geometry.target)) s gap: " + ending
        return VoiceLabFitMeterResult(estimateSeconds: estimate, gapSeconds: geometry.target, lowerBoundSeconds: lower,
                                      upperBoundSeconds: upper, verdict: verdict, copy: copy)
    }

    private static func pad(_ kind: VoiceLabSeamKind) -> Double {
        kind == .hard ? VoiceLabPatchConstants.HARD_SEAM_PAD_MAX : VoiceLabPatchConstants.SEAM_PAD_MAX
    }
    private static func borrow(_ kind: VoiceLabSeamKind, _ silence: Double?) -> Double {
        kind == .gap ? max(0, silence! - VoiceLabPatchConstants.PAUSE_SLACK_KEEP) : 0
    }
}
