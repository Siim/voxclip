import Foundation

public enum VoiceLabPatchBudgetFlag: String, Sendable { case allowed, reRecordInstead }
public struct VoiceLabPatchBudgetResult: Sendable, Equatable {
    public let voiceTokenCount: Int
    public let wordItems: Int
    public let flag: VoiceLabPatchBudgetFlag
    public let copy: String?
}

public enum VoiceLabPatchBudget {
    public static let disabledCopy = "That's a lot to re-voice. Re-record these sentences instead."

    /// §8.2 patch budget over a review's hunks after every merge: a passage's `VoiceLabWordDiff` hunks, or a clip or Full
    /// take's `ScopeRewriteDiff` hunks. `transcript` is the whole take's.
    public static func evaluate(hunks: [VoiceLabDiffHunk], transcript: [TimedWord]) -> VoiceLabPatchBudgetResult {
        let count: Int = hunks.filter { $0.kind == .voice }.reduce(0) { (total: Int, hunk: VoiceLabDiffHunk) -> Int in
            total + hunk.newTokens.count
        }
        let wordItems: Int = transcript.filter { $0.kind == .word }.count
        let disabled: Bool = count * 100 > 15 * wordItems || count > 60
        return VoiceLabPatchBudgetResult(voiceTokenCount: count, wordItems: wordItems,
                                         flag: disabled ? .reRecordInstead : .allowed, copy: disabled ? disabledCopy : nil)
    }
}
