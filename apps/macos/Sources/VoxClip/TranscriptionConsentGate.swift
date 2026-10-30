import Observation

@MainActor @Observable final class TranscriptionConsentGate {
    private(set) var pending = false
    private var operation: (@MainActor () -> Void)?

    func request(engine: String, app: AppModel, operation: @escaping @MainActor () -> Void) {
        guard !pending else { return }
        guard engine == "elevenlabs", !app.bool("transcription.cloudConsent.elevenlabs") else { operation(); return }
        self.operation = operation
        pending = true
    }
    func approve(app: AppModel) {
        guard pending, let operation else { return }
        app.set("transcription.cloudConsent.elevenlabs", .bool(true))
        cancel()
        operation()
    }
    func cancel() { operation = nil; pending = false }
}
