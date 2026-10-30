import Foundation
import VoxClipCore

public actor VoiceOperationReconciler {
    private let store: VoiceConsentStore
    private let clients: @Sendable (ElevenLabsRegion) -> ElevenLabsVoiceLab
    private let now: @Sendable () -> Date
    private var regionIsCurrent: @Sendable (ElevenLabsRegion) async -> Bool = { _ in true }
    public init(store: VoiceConsentStore, client: ElevenLabsVoiceLab) {
        self.store = store; clients = { _ in client }; now = { Date() }
    }
    public init(store: VoiceConsentStore, regionIsCurrent: @escaping @Sendable (ElevenLabsRegion) async -> Bool = { _ in true }, clients: @escaping @Sendable (ElevenLabsRegion) -> ElevenLabsVoiceLab) {
        self.store = store; self.clients = clients; self.regionIsCurrent = regionIsCurrent; now = { Date() }
    }
    #if DEBUG
    @_spi(Testing) public init(store: VoiceConsentStore, client: ElevenLabsVoiceLab, now: @escaping @Sendable () -> Date) {
        self.store = store; clients = { _ in client }; self.now = now
    }
    #endif
    public func reconcile(operationID: UUID? = nil, force: Bool = false) async throws {
        var failure: (any Error)?
        for value in try await store.operations() where operationID == nil || value.id == operationID {
            guard value.state != .abandoned, await store.claimOperation(value.id) else { continue }
            do { try await resume(value, force: force) }
            catch {
                try? await store.scheduleRetry(value.id, at: now())
                failure = error
            }
            await store.releaseOperation(value.id)
        }
        if let failure { throw failure }
    }
    private func resume(_ snapshot: VoiceOperation, force: Bool) async throws {
        var value = try await store.operation(snapshot.id)
        if value.remoteStateUnknown == true { try await store.finishLocalRemoval(value); return }
        while true {
            switch (value.kind, value.state) {
            case (.create, .intent):
                value = try await store.transition(value.id, to: .withdrawing, at: now())
            case (.create, .dispatched):
                value = try await store.preserveCreationAudit(value.id)
                try await store.discardStatement(recordID: value.recordID)
                try await store.discardUnresolvedDraft(value)
                guard let remote = try await findRemote(value, force: force) else { return }
                value = try await store.transition(value.id, to: .withdrawing, at: now(), remoteVoiceID: remote.id)
            case (.create, .created):
                let draft = try? await store.load(value.recordID)
                let audio = try? await store.statement(recordID: value.recordID)
                let valid = draft?.status != .deleted && audio.map { VoiceLabFingerprint.bytes($0) == draft?.statement.audioSha256 } == true
                if !valid {
                    value = try await store.transition(value.id, to: .withdrawing, at: now())
                    continue
                }
                try await store.saveCreatedRecord(value)
                value = try await store.transition(value.id, to: .saved, at: now())
            case (.create, .withdrawing):
                value = try await store.preserveCreationAudit(value.id)
                try await store.discardStatement(recordID: value.recordID)
                try await store.discardUnresolvedDraft(value)
                if value.remoteVoiceID == nil, value.wasDispatched {
                    guard let remote = try await findRemote(value, force: force) else { return }
                    value = try await store.transition(value.id, to: .withdrawing, at: now(), remoteVoiceID: remote.id)
                }
                if let voiceID = value.remoteVoiceID {
                    if !force, let next = value.nextAttemptAt, now() < next { return }
                    try await deleteRemote(value, voiceID: voiceID)
                }
                try await store.tombstone(value)
                value = try await store.transition(value.id, to: .withdrawn, at: now())
            case (.delete, .intent):
                if !force, let next = value.nextAttemptAt, now() < next { return }
                guard let voiceID = value.remoteVoiceID else { throw VoiceConsentError.invalidRecord }
                try await deleteRemote(value, voiceID: voiceID)
                value = try await store.transition(value.id, to: .remoteDeleted, at: now())
            case (.delete, .remoteDeleted):
                try await store.discardStatement(recordID: value.recordID)
                value = try await store.transition(value.id, to: .audioRemoved, at: now())
            case (.delete, .audioRemoved):
                try await store.tombstone(value)
                value = try await store.transition(value.id, to: .tombstoned, at: now())
            case (_, .saved), (_, .withdrawn), (_, .tombstoned):
                try await store.removeOperation(value)
                return
            case (_, .abandoned): return
            default: throw VoiceConsentError.invalidRecord
            }
        }
    }
    private func findRemote(_ value: VoiceOperation, force: Bool) async throws -> VoiceLabVoice? {
        guard await regionIsCurrent(value.region) else { throw VoiceConsentError.creatorMismatch }
        if !force, let next = value.nextAttemptAt, now() < next { return nil }
        let client = clients(value.region)
        guard client.region == value.region else { throw VoiceConsentError.invalidRecord }
        if let expected = value.creatorKeyFingerprint {
            guard try await client.creatorKeyFingerprint() == expected else { throw VoiceConsentError.creatorMismatch }
        }
        let discovered = try await client.listOwnClones()
        let start = floor(value.startedAt.timeIntervalSince1970)
        let end = value.startedAt.addingTimeInterval(24 * 60 * 60)
        let voices = discovered.filter { voice in
            voice.consentRecordID == value.providerNonce ||
                (voice.consentRecordID == nil && voice.name == value.expectedVoiceName && voice.createdAt.map { $0.timeIntervalSince1970 >= start && $0 <= end } == true)
        }
        let uncertain = discovered.contains { candidate in
            candidate.name == value.expectedVoiceName && candidate.consentRecordID != value.providerNonce && !voices.contains(where: { $0.id == candidate.id })
        }
        guard voices.count <= 1, !uncertain else {
            try await store.requireRecoveryReview(value.id)
            throw VoiceConsentError.invalidRecord
        }
        if let voice = voices.first { return voice }
        if value.recoveryNeedsReview == true {
            try await store.scheduleRetry(value.id, at: now())
            return nil
        }
        if now().timeIntervalSince(value.startedAt) >= 24 * 60 * 60 {
            try await store.tombstone(value)
            _ = try await store.transition(value.id, to: .abandoned, at: now())
        } else {
            try await store.scheduleRetry(value.id, at: now())
        }
        return nil
    }
    private func deleteRemote(_ value: VoiceOperation, voiceID: String) async throws {
        guard await regionIsCurrent(value.region) else { throw VoiceConsentError.creatorMismatch }
        let client = clients(value.region)
        guard client.region == value.region else { throw VoiceConsentError.invalidRecord }
        let requestID = UUID()
        let policy = OwnVoicePolicy(recordID: value.recordID, cloneVoiceID: voiceID, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let quote = try await client.prepareOperationDeletion(value, requestID: requestID)
        _ = try await client.deleteOwnClone(voiceID: voiceID, policy: policy, requestID: requestID, authorization: .init(quote: quote, approved: true))
    }
}
