import Foundation

package enum VoiceLabQuoteClock {
    package static func continuousSource() -> @Sendable () -> Duration {
        let origin = ContinuousClock.now
        return { origin.duration(to: .now) }
    }
}
