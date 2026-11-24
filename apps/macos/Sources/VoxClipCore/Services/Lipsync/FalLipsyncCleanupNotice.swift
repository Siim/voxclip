import Observation

@MainActor @Observable public final class FalLipsyncCleanupNotice {
    private var deniedFingerprints: Set<String> = []

    public init() {}

    package var hasDeniedKeys: Bool { !deniedFingerprints.isEmpty }

    package func applies(toFingerprint fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        return deniedFingerprints.contains(fingerprint)
    }

    func recordDenial(forFingerprint fingerprint: String) {
        guard !deniedFingerprints.contains(fingerprint) else { return }
        deniedFingerprints.insert(fingerprint)
    }
}
