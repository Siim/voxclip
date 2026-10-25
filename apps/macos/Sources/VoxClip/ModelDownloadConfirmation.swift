import Foundation
import Observation
import VoxClipCore

@MainActor @Observable final class ModelDownloadConfirmation {
    private(set) var pending: ModelDescriptor?
    private(set) var totalBytes: Int64 = 0
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?
    #if DEBUG
    @ObservationIgnored var onRequest: (() -> Void)?
    #endif
    func request(_ model: ModelDescriptor, bytes: Int64) async throws -> Bool {
        try Task.checkCancellation()
        let id = UUID()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                respond(false)
                requestID = id; pending = model; totalBytes = bytes; self.continuation = continuation
                #if DEBUG
                onRequest?()
                #endif
            }
        } onCancel: {
            Task { @MainActor [weak self] in if self?.requestID == id { self?.respond(false) } }
        }
        try Task.checkCancellation()
        return accepted
    }
    func respond(_ accepted: Bool) {
        let waiting = continuation
        continuation = nil; requestID = nil; pending = nil
        waiting?.resume(returning: accepted)
    }
}
