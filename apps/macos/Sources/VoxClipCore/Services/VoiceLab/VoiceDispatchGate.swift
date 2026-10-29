import Foundation
import Synchronization

package final class VoiceDispatchGate: Sendable {
    private struct State {
        var revoked: Set<String> = []
        var active: [String: Set<UUID>] = [:]
    }
    private static let roots = Mutex<[String: VoiceDispatchGate]>([:])
    private let state = Mutex(State())
    package static func shared(root: URL) -> VoiceDispatchGate {
        roots.withLock { roots in
            let key = root.standardizedFileURL.resolvingSymlinksInPath().path
            if let existing = roots[key] { return existing }
            let gate = VoiceDispatchGate(); roots[key] = gate; return gate
        }
    }
    package func revoke(_ recordID: String) -> [UUID] {
        state.withLock { state in
            state.revoked.insert(recordID)
            return Array(state.active[recordID] ?? []).sorted { $0.uuidString < $1.uuidString }
        }
    }
    package func start(recordID: String, requestID: UUID, transport: @Sendable () throws -> Void) throws {
        try state.withLock { state in
            guard !state.revoked.contains(recordID) else { throw VoiceConsentError.inactive }
            state.active[recordID, default: []].insert(requestID)
            do { try transport() }
            catch { state.active[recordID]?.remove(requestID); throw error }
        }
    }
    package func finish(recordID: String, requestID: UUID) {
        _ = state.withLock { $0.active[recordID]?.remove(requestID) }
    }
}

package struct VoiceDispatchPermit: Sendable {
    let gate: VoiceDispatchGate
    let recordID: String
    let requestID: UUID
    package func start(_ transport: @Sendable () throws -> Void) throws {
        try gate.start(recordID: recordID, requestID: requestID, transport: transport)
    }
    package func finish() { gate.finish(recordID: recordID, requestID: requestID) }
}

extension VoiceConsentStore {
    package func creationDispatchPermit(recordID: String, requestID: UUID, statementHash: String) throws -> VoiceDispatchPermit {
        try validateCreation(recordID: recordID, requestID: requestID, statementHash: statementHash)
        return VoiceDispatchPermit(gate: dispatchGate, recordID: recordID, requestID: requestID)
    }
    package func dispatchPermit(_ record: VoiceConsentRecord, requestID: UUID) throws -> VoiceDispatchPermit {
        try validateUse(record)
        return VoiceDispatchPermit(gate: dispatchGate, recordID: record.id, requestID: requestID)
    }
    package var dispatchGate: VoiceDispatchGate { VoiceDispatchGate.shared(root: root) }
}
