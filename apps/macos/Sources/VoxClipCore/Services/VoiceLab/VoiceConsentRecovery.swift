import Darwin
import Foundation

package enum VoiceConsentCheckpoint: String, Sendable, CaseIterable {
    case saveDraft, removeDraft, saveRecord, tombstoneRecord, creationIntent, creationDispatched, creationResult, saveCreation, clearCreation
    case withdrawing, withdrawn, deletionIntent, remoteDeleted, removeStatement, audioRemoved, saveTombstone, clearDeletion
    case retryScheduled, abandoned, saveAudit
}

public struct VoiceOperation: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case create, delete }
    public enum State: String, Codable, Sendable {
        case intent, dispatched, created, saved, withdrawing, withdrawn
        case remoteDeleted, audioRemoved, tombstoned, abandoned
    }
    public let id: UUID
    public let kind: Kind
    public let recordID: String
    public let providerNonce: String
    public let region: ElevenLabsRegion
    public let startedAt: Date
    public var updatedAt: Date
    public var state: State
    public var remoteVoiceID: String?
    public var wasDispatched: Bool
    public var requiresVerification: Bool?
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var failed: Bool
    public var audit: VoiceConsentAudit?
    public var ambiguousDispatchIDs: [UUID]?
    public var expectedVoiceName: String?
    public var recoveryNeedsReview: Bool?
    public var finished: Bool { [.saved, .withdrawn, .tombstoned, .abandoned].contains(state) }
    public var blocksCreation: Bool { blocksCreation(at: Date()) }
    public func blocksCreation(at date: Date) -> Bool {
        kind == .create && [.dispatched, .created].contains(state) && date < startedAt.addingTimeInterval(24 * 60 * 60)
    }
    public var displayState: String {
        if recoveryNeedsReview == true { return "More than one voice may match. Check your ElevenLabs voices, then Retry. No voice was deleted." }
        if kind == .create, wasDispatched, remoteVoiceID == nil, !finished {
            return "Checking your ElevenLabs account for an unfinished voice…"
        }
        if failed { return "Couldn't finish — Retry" }
        return kind == .delete || state == .withdrawing ? "Removing…" : "Finishing…"
    }
    package init(id: UUID, kind: Kind, recordID: String, region: ElevenLabsRegion, at date: Date, remoteVoiceID: String? = nil) {
        self.id = id; self.kind = kind; self.recordID = recordID; providerNonce = recordID; self.region = region
        startedAt = date; updatedAt = date; state = .intent; self.remoteVoiceID = remoteVoiceID
        wasDispatched = false; requiresVerification = nil
        attempts = 0; nextAttemptAt = nil; failed = false
    }
}

extension VoiceConsentRecord {
    package func assigningVoice(_ voiceID: String, requiresVerification: Bool) -> Self {
        Self(schema: schema, recordId: recordId, provider: provider, type: type, voiceId: voiceID, voiceName: voiceName,
             status: requiresVerification ? .verificationRequired : .active, createdAt: createdAt, deletedAt: nil,
             statement: statement, attestations: attestations, samples: samples, speaker: speaker, app: app)
    }
}

extension VoiceConsentStore {
    public var operationsRoot: URL { root.deletingLastPathComponent().appendingPathComponent("voice-ops", isDirectory: true) }
    private func operationFile(_ id: UUID, create: Bool = false) throws -> URL {
        let manager = FileManager.default
        for directory in [root.deletingLastPathComponent(), operationsRoot] {
            if let attributes = try? manager.attributesOfItem(atPath: directory.path), attributes[.type] as? FileAttributeType != .typeDirectory {
                throw VoiceConsentError.invalidRecord
            }
            if create, !manager.fileExists(atPath: directory.path) {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try synchronizeDirectory(directory.deletingLastPathComponent())
            }
        }
        return try file(id.uuidString + ".json", in: operationsRoot)
    }
    public func operations() throws -> [VoiceOperation] {
        _ = try operationFile(UUID())
        guard FileManager.default.fileExists(atPath: operationsRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: operationsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw VoiceConsentError.invalidRecord }
                return try operation(id)
            }.sorted { $0.startedAt < $1.startedAt }
    }
    package func operation(_ id: UUID) throws -> VoiceOperation {
        let url = try operationFile(id)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1_024 else { throw VoiceConsentError.invalidRecord }
        let value = try JSONDecoder().decode(VoiceOperation.self, from: Data(contentsOf: url))
        guard value.id == id, UUID(uuidString: value.recordID) != nil, value.providerNonce == value.recordID,
              value.attempts >= 0, value.updatedAt >= value.startedAt,
              value.remoteVoiceID.map({ $0.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }) ?? true else { throw VoiceConsentError.invalidRecord }
        try value.audit?.validate(recordID: value.recordID)
        guard value.audit == nil || value.audit?.remoteVoiceID == value.remoteVoiceID else { throw VoiceConsentError.invalidRecord }
        let allowed: Set<VoiceOperation.State> = value.kind == .create
            ? [.intent, .dispatched, .created, .saved, .withdrawing, .withdrawn, .abandoned]
            : [.intent, .remoteDeleted, .audioRemoved, .tombstoned]
        guard allowed.contains(value.state), ![.created, .saved, .remoteDeleted, .audioRemoved, .tombstoned].contains(value.state) || value.remoteVoiceID != nil else { throw VoiceConsentError.invalidRecord }
        return value
    }
    private func writeOperation(_ value: VoiceOperation, checkpoint step: VoiceConsentCheckpoint) throws {
        var value = value
        if value.kind == .delete || value.state == .withdrawing || value.state == .withdrawn {
            let active = dispatchGate.revoke(value.recordID)
            let ambiguous = Set(value.ambiguousDispatchIDs ?? []).union(active)
            value.ambiguousDispatchIDs = ambiguous.isEmpty ? nil : ambiguous.sorted { $0.uuidString < $1.uuidString }
        }
        try checkpoint(step)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(encoder.encode(value), to: operationFile(value.id, create: true))
    }
    package func beginClaimedCreation(record: VoiceConsentRecord, requestID: UUID, region: ElevenLabsRegion, at date: Date) throws -> VoiceOperation {
        try migrateLegacyOperations()
        guard !claimedOperations.contains(requestID),
              !(try operations()).contains(where: { $0.id == requestID || $0.blocksCreation(at: date) || (!$0.finished && $0.recordID == record.id) }) else { throw VoiceConsentError.creationPending }
        try checkpoint(.saveDraft)
        try save(record)
        var value = VoiceOperation(id: requestID, kind: .create, recordID: record.id, region: region, at: date)
        value.audit = try VoiceConsentAudit(record: record)
        value.expectedVoiceName = record.voiceName + " (VoxClip)"
        try writeOperation(value, checkpoint: .creationIntent)
        claimedOperations.insert(value.id)
        return value
    }
    package func transition(_ id: UUID, to state: VoiceOperation.State, at date: Date, remoteVoiceID: String? = nil, requiresVerification: Bool? = nil) throws -> VoiceOperation {
        var value = try operation(id)
        let permitted: Bool
        switch (value.kind, value.state, state) {
        case (.create, .intent, .dispatched), (.create, .dispatched, .created), (.create, .created, .saved),
             (.create, .withdrawing, .withdrawn), (.create, .dispatched, .abandoned), (.create, .withdrawing, .abandoned),
             (.delete, .intent, .remoteDeleted), (.delete, .remoteDeleted, .audioRemoved), (.delete, .audioRemoved, .tombstoned): permitted = true
        default: permitted = value.kind == .create && ![.withdrawn, .abandoned].contains(value.state) && state == .withdrawing
        }
        guard permitted else { throw VoiceConsentError.invalidRecord }
        value.state = state; value.updatedAt = max(date, value.updatedAt); value.failed = false; value.nextAttemptAt = nil
        if state == .dispatched { value.wasDispatched = true }
        if let remoteVoiceID { value.remoteVoiceID = remoteVoiceID }
        value.audit?.remoteVoiceID = value.remoteVoiceID
        if let requiresVerification { value.requiresVerification = requiresVerification }
        let step: VoiceConsentCheckpoint
        switch state {
        case .dispatched: step = .creationDispatched
        case .created: step = .creationResult
        case .saved: step = .saveCreation
        case .withdrawing: step = .withdrawing
        case .withdrawn: step = .withdrawn
        case .remoteDeleted: step = .remoteDeleted
        case .audioRemoved: step = .audioRemoved
        case .tombstoned: step = .saveTombstone
        case .abandoned: step = .abandoned
        case .intent: throw VoiceConsentError.invalidRecord
        }
        try writeOperation(value, checkpoint: step)
        return value
    }
    package func scheduleRetry(_ id: UUID, at date: Date) throws {
        var value = try operation(id)
        value.attempts += 1; value.failed = true; value.updatedAt = max(date, value.updatedAt)
        let delay = min(3_600.0, 30 * pow(2, Double(min(value.attempts - 1, 7))))
        value.nextAttemptAt = date.addingTimeInterval(delay)
        if value.kind == .create, [.dispatched, .withdrawing].contains(value.state), value.remoteVoiceID == nil,
           date < value.startedAt.addingTimeInterval(24 * 60 * 60) {
            value.nextAttemptAt = min(value.nextAttemptAt!, value.startedAt.addingTimeInterval(24 * 60 * 60))
        }
        try writeOperation(value, checkpoint: .retryScheduled)
    }
    package func requireRecoveryReview(_ id: UUID) throws {
        var value = try operation(id)
        value.recoveryNeedsReview = true
        try writeOperation(value, checkpoint: .retryScheduled)
    }
    package func removeOperation(_ value: VoiceOperation) throws {
        guard value.finished, value.state != .abandoned else { throw VoiceConsentError.invalidRecord }
        try checkpoint(value.kind == .create ? .clearCreation : .clearDeletion)
        let url = try operationFile(value.id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url); try synchronizeDirectory(operationsRoot)
        }
    }
    package func beginDeletion(_ id: String, region: ElevenLabsRegion, at date: Date) throws -> VoiceOperation {
        try migrateLegacyOperations()
        if let existing = try operations().first(where: { $0.recordID == id && !$0.finished }) {
            if existing.kind == .create { return try transition(existing.id, to: .withdrawing, at: date) }
            return existing
        }
        let record = try load(id)
        var value = VoiceOperation(id: UUID(), kind: .delete, recordID: id, region: region, at: date, remoteVoiceID: record.voiceId)
        value.audit = try VoiceConsentAudit(record: record)
        try writeOperation(value, checkpoint: .deletionIntent)
        return value
    }
    public func withdrawCreation(recordID: String, remoteVoiceID: String? = nil, region: ElevenLabsRegion = .default, at date: Date = Date()) throws {
        if let value = try operations().first(where: { $0.recordID == recordID && $0.kind == .create && ![.withdrawn, .abandoned].contains($0.state) }) {
            _ = try transition(value.id, to: .withdrawing, at: date, remoteVoiceID: remoteVoiceID)
        } else if let voiceID = remoteVoiceID {
            var value = VoiceOperation(id: UUID(), kind: .create, recordID: recordID, region: region, at: date, remoteVoiceID: voiceID)
            value.state = .withdrawing; value.wasDispatched = true
            try writeOperation(value, checkpoint: .withdrawing)
        }
        if let value = try operations().first(where: { $0.recordID == recordID && $0.kind == .create && !$0.finished }) {
            _ = try preserveCreationAudit(value.id)
        }
        try discardStatement(recordID: recordID)
    }
    package func saveCreatedRecord(_ value: VoiceOperation) throws {
        guard value.state == .created, let voiceID = value.remoteVoiceID else { throw VoiceConsentError.invalidRecord }
        let draft = try load(value.recordID)
        try checkpoint(.saveRecord)
        try save(draft.assigningVoice(voiceID, requiresVerification: value.requiresVerification ?? true))
    }
    package func discardUnresolvedDraft(_ value: VoiceOperation) throws {
        guard value.kind == .create, value.remoteVoiceID == nil else { return }
        let directory = try directory(value.recordID)
        let url = try file("record.json", in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let draft = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: url))
        guard draft.id == value.recordID, draft.voiceId == "pending" else { throw VoiceConsentError.invalidRecord }
        try checkpoint(.removeDraft)
        try FileManager.default.removeItem(at: url)
        try synchronizeDirectory(directory)
    }
    package func preserveCreationAudit(_ id: UUID) throws -> VoiceOperation {
        var value = try operation(id)
        guard value.audit == nil else { return value }
        let url = try file("record.json", in: directory(value.recordID))
        guard FileManager.default.fileExists(atPath: url.path) else { return value }
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: url))
        guard record.id == value.recordID else { throw VoiceConsentError.invalidRecord }
        value.audit = try VoiceConsentAudit(record: record)
        value.audit?.remoteVoiceID = value.remoteVoiceID
        try writeOperation(value, checkpoint: .saveAudit)
        return value
    }
    package func auditTombstone(recordID: String) throws -> VoiceConsentAudit? {
        let url = try file("audit.json", in: directory(recordID))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1_024 else { throw VoiceConsentError.invalidRecord }
        let audit = try JSONDecoder().decode(VoiceConsentAudit.self, from: Data(contentsOf: url))
        try audit.validate(recordID: recordID)
        guard audit.deletedAt != nil, audit.remoteVoiceID != nil else { throw VoiceConsentError.invalidRecord }
        return audit
    }
    package func tombstone(_ value: VoiceOperation) throws {
        if var audit = value.audit, let voiceID = value.remoteVoiceID {
            audit.remoteVoiceID = voiceID; audit.deletedAt = VoiceConsentRecord.timestamp(value.updatedAt)
            try audit.validate(recordID: value.recordID)
            try checkpoint(.tombstoneRecord)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writePrivate(encoder.encode(audit), to: file("audit.json", in: directory(value.recordID, create: true)))
        }
        let url = try file("record.json", in: directory(value.recordID))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: url))
        try record.validate()
        guard record.id == value.recordID else { throw VoiceConsentError.invalidRecord }
        if let voiceID = value.remoteVoiceID { record = record.assigningVoice(voiceID, requiresVerification: false) }
        record.status = .deleted; record.deletedAt = VoiceConsentRecord.timestamp(value.updatedAt)
        try checkpoint(.tombstoneRecord)
        try save(record)
    }
    package func hasOperation(_ id: String) throws -> Bool { try operations().contains { $0.recordID == id && !$0.finished } }
    package func hasDeletion(_ id: String) throws -> Bool { try operations().contains { $0.recordID == id && !$0.finished && ($0.kind == .delete || $0.state == .withdrawing) } }
    package func claimOperation(_ id: UUID) -> Bool { claimedOperations.insert(id).inserted }
    package func releaseOperation(_ id: UUID) { claimedOperations.remove(id) }
    package func validateUse(_ snapshot: VoiceConsentRecord) throws {
        try migrateLegacyOperations()
        guard snapshot.status == .active, !(try hasOperation(snapshot.id)), try load(snapshot.id) == snapshot else { throw VoiceConsentError.inactive }
    }
    package func dispatchCreation(recordID: String, requestID: UUID, statementHash: String) throws {
        let value = try operation(requestID)
        guard value.state == .intent, value.recordID == recordID,
              !(try operations()).contains(where: { $0.id != requestID && $0.blocksCreation }),
              VoiceLabFingerprint.bytes(try statement(recordID: recordID)) == statementHash else { throw VoiceConsentError.invalidRecord }
        _ = try transition(requestID, to: .dispatched, at: Date())
    }
    package func validateCreation(recordID: String, requestID: UUID, statementHash: String) throws {
        let value = try operation(requestID)
        guard value.kind == .create, value.state == .dispatched, value.recordID == recordID,
              VoiceLabFingerprint.bytes(try statement(recordID: recordID)) == statementHash else { throw VoiceConsentError.invalidRecord }
    }
    func migrateLegacyOperations() throws {
        struct LegacyCreate: Decodable {
            let requestID: UUID
            let region: ElevenLabsRegion
            let startedAt: Date
            let record: VoiceConsentRecord
            let cancelled: Bool?
        }
        struct LegacyDelete: Decodable {
            let record: VoiceConsentRecord
            let region: ElevenLabsRegion
            let requestedAt: Date
            let remoteDeleted: Bool
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return }
        for entry in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where UUID(uuidString: entry.lastPathComponent) != nil {
            let directory = try directory(entry.lastPathComponent)
            let creationFile = try file("creation.json", in: directory)
            let deletionFile = try file("deletion.json", in: directory)
            func read<Value: Decodable>(_ type: Value.Type, _ url: URL) throws -> Value? {
                guard manager.fileExists(atPath: url.path) else { return nil }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512 * 1_024 else { throw VoiceConsentError.invalidRecord }
                return try JSONDecoder().decode(type, from: Data(contentsOf: url))
            }
            let creation = try read(LegacyCreate.self, creationFile)
            let deletion = try read(LegacyDelete.self, deletionFile)
            guard let record = deletion?.record ?? creation?.record else { continue }
            try record.validate()
            guard record.id == entry.lastPathComponent else { throw VoiceConsentError.invalidRecord }
            if !(try operations()).contains(where: { $0.recordID == record.id }) {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let recordFile = try file("record.json", in: directory)
                if !manager.fileExists(atPath: recordFile.path) { try writePrivate(encoder.encode(record), to: recordFile) }
                var value = VoiceOperation(id: creation?.requestID ?? UUID(), kind: creation == nil ? .delete : .create,
                                           recordID: record.id, region: deletion?.region ?? creation!.region,
                                           at: deletion?.requestedAt ?? creation!.startedAt,
                                           remoteVoiceID: record.voiceId == "pending" ? nil : record.voiceId)
                if creation != nil {
                    value.wasDispatched = true
                    value.state = deletion != nil || creation?.cancelled == true ? .withdrawing : (value.remoteVoiceID == nil ? .dispatched : .created)
                    value.requiresVerification = record.status == .verificationRequired
                } else if deletion?.remoteDeleted == true { value.state = .remoteDeleted }
                value.audit = try VoiceConsentAudit(record: record)
                try writeOperation(value, checkpoint: value.kind == .create ? .creationIntent : .deletionIntent)
            }
            for url in [creationFile, deletionFile] where manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            try synchronizeDirectory(directory)
        }
    }
    func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize(); try synchronizeDirectory(url.deletingLastPathComponent())
    }
    func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
