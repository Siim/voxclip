import Foundation

public enum RelinkDecision: String, Sendable {
    case match, needsConfirmation, different, refused

    public static func decide(storedSize: Int64, storedKey: String, storedDuration: Double,
                              size: Int64, key: String, duration: Double, confirmedDifferent: Bool) -> Self {
        // Content keys compare as UTF-8 bytes, as the C# ordinal comparison does.
        if size == storedSize && key.utf8.elementsEqual(storedKey.utf8) { return .match }
        if !confirmedDifferent { return .needsConfirmation }
        guard duration.isFinite && storedDuration.isFinite else { return .refused }
        let millisecondsPerSecond: Double = 1000
        let probedScaled: Double = duration * millisecondsPerSecond
        let storedScaled: Double = storedDuration * millisecondsPerSecond
        let probedMilliseconds: Double = EditingPrimitives.jsRound(probedScaled)
        let storedMilliseconds: Double = EditingPrimitives.jsRound(storedScaled)
        let difference: Double = abs(probedMilliseconds - storedMilliseconds)
        let tolerance: Double = 50
        return difference <= tolerance ? .different : .refused
    }
}
