import Foundation
import VoxClipCore

/// One approved run's generated speech. Never retains source speech, adds padding or buys audio.
public actor VoiceLabShortTakePool {
    private struct Member: Sendable {
        let row: VoiceLabTakeRow
        let voiced: [Float]
        let record: VoiceConsentRecord
        let speaker: VoiceSpeakerCheck
        let store: VoiceConsentStore
        let current: @Sendable () async -> Bool
    }
    private var members: [Member] = []
    private var finishing: Task<[UUID: VoiceLabTakeRow], Never>?
    public init() {}

    func append(_ row: VoiceLabTakeRow, voiced: [Float], record: VoiceConsentRecord,
                speaker: VoiceSpeakerCheck, store: VoiceConsentStore,
                current: @escaping @Sendable () async -> Bool) throws {
        guard finishing == nil, row.voiceCheck == .waiting,
              voiced.count < SpeakerAudio.windowSize, voiced.allSatisfy(\.isFinite),
              !members.contains(where: { $0.row.id == row.id }) else { throw VoiceLabError.invalidInput }
        members.append(Member(row: row, voiced: voiced, record: record, speaker: speaker, store: store, current: current))
    }

    /// Stop cancels dispatch, then drains this local check in a fresh task. Its cancellation must not
    /// prevent measurement of completed takes. Current inputs and active consent are checked again.
    public func finish() async -> [UUID: VoiceLabTakeRow] {
        if let finishing { return await finishing.value }
        let snapshot = members
        members.removeAll()
        let operation = Task.detached(priority: .utility) { await Self.check(snapshot) }
        finishing = operation
        return await operation.value
    }

    private static func check(_ members: [Member]) async -> [UUID: VoiceLabTakeRow] {
        var results: [UUID: VoiceLabTakeRow] = [:]
        var checked = Set<String>()
        for first in members where checked.insert(first.record.id).inserted {
            let group = members.filter { $0.record.id == first.record.id }
            do {
                guard group.allSatisfy({ $0.record == first.record }) else { throw VoiceConsentError.invalidRecord }
                try await first.store.validateUse(first.record)
                for member in group {
                    guard await member.current() else { throw VoiceLabError.consentRequired }
                }
                let voiced = group.flatMap(\.voiced)
                let mode: VoiceLabShortSpeechEvidence.Mode = voiced.count >= SpeakerAudio.windowSize ? .pooled : .unmeasured
                let evidence = VoiceLabShortSpeechEvidence(mode: mode, recordID: first.record.id,
                    consentMethod: first.record.consentMethod, voicedFrames: voiced.count, takeCount: group.count)
                let score: Double?
                if mode == .pooled {
                    guard let owner = VoiceConsentRecord.decodeEmbedding(first.record.speaker.embedding) else { throw VoiceConsentError.invalidRecord }
                    let vector = try await first.speaker.generatedVoicedEmbedding(voiced)
                    score = try VoiceSpeakerCheck.cosine(owner, vector)
                } else { score = nil }
                try await first.store.validateUse(first.record)
                for member in group {
                    guard await member.current() else { throw VoiceLabError.consentRequired }
                }
                let failure: VoiceLabTakeFailure? = score.map { $0 < first.record.speaker.threshold } == true ? .qa([.speaker]) : nil
                for member in group {
                    results[member.row.id] = member.row.checkingVoice(.shortSpeech(evidence), score: score, failure: failure)
                }
            } catch {
                let failure: VoiceLabTakeFailure
                if let error = error as? VoiceConsentError {
                    failure = error == .speakerMismatch ? .qa([.speaker]) : .consent(error)
                } else if let error = error as? VoiceLabError { failure = .provider(error) }
                else { failure = .invalidAudio }
                for member in group {
                    results[member.row.id] = member.row.checkingVoice(.perTake, failure: failure)
                }
            }
        }
        return results
    }
}
