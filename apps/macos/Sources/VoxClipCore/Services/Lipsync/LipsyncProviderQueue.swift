import Foundation

/// One lip-sync job per provider account at a time (voice-lab §9.6), across every run in the app. A run reserves the slot
/// before it uploads anything, so a held slot refuses at once (`busy`) with nothing uploaded or paid. The run gives it
/// back whenever it stops tracking its job: the job finished, failed or was cancelled, a poll gave up, the submit's answer
/// was lost (the session's own flag blocks a resubmit), or the payload delete failed. A lease no one gives back ends by
/// itself at its expiry: the job's deadline (30 minutes) after it is reserved, renewed to the deadline plus 5 minutes once
/// fal.ai accepts the job (FalLipsyncProvider). One lost lease never blocks lip sync for the rest of the app's run.
package actor LipsyncProviderQueue {
    package struct Lease: Sendable, Equatable { let account: String; let id: UUID }
    private struct Held { let lease: Lease; var expires: Duration }
    package static let shared = LipsyncProviderQueue()
    private let clock: @Sendable () -> Duration
    private var active: [String: Held] = [:]

    /// `clock` is monotonic (a test's fixed one).
    package init(clock: @escaping @Sendable () -> Duration = VoiceLabQuoteClock.continuousSource()) { self.clock = clock }

    /// Takes the account's slot for `seconds`, or throws `busy` while another run holds an unexpired one.
    func reserve(account: String, for seconds: Double) throws -> Lease {
        if let held = active[account], held.expires > clock() { throw LipsyncError.busy }
        let lease = Lease(account: account, id: UUID())
        active[account] = Held(lease: lease, expires: clock() + .seconds(seconds))
        return lease
    }

    /// Moves a held lease's expiry to `seconds` from now (an accepted job's deadline).
    func renew(_ lease: Lease, for seconds: Double) {
        guard active[lease.account]?.lease == lease else { return }
        active[lease.account]?.expires = clock() + .seconds(seconds)
    }

    func release(_ lease: Lease) {
        guard active[lease.account]?.lease == lease else { return }
        active.removeValue(forKey: lease.account)
    }

    /// The account's slot is held and not expired (tests).
    package func isHeld(account: String) -> Bool { active[account].map { $0.expires > clock() } ?? false }
}
