import Foundation

public enum LipsyncBillingStatus: String, Sendable, Equatable {
    case notSubmitted, submissionUncertain, accepted, cancellationRequested, removedBeforeRun, alreadyCompleted
    public var mayBill: Bool { ![.notSubmitted, .removedBeforeRun].contains(self) }
}

public enum LipsyncCleanupStatus: String, Sendable, Equatable { case pending, completed, failed }

public struct LipsyncJobStatus: Sendable, Equatable {
    public let quoteID: UUID
    public let job: LipsyncJob?
    public let billing: LipsyncBillingStatus
    public let cancelled: Bool
    public let cleanup: LipsyncCleanupStatus
    public let spendWarning: VoiceLabSpendWarning?
}
