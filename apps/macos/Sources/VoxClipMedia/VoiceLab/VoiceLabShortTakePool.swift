import Foundation
import VoxClipCore

/// Generated speech and measured failures live for one plan, across separately approved runs.
package actor VoiceLabVoiceCheckSession {
    package init() {}
    struct Sample: Sendable {
        let id: UUID
        let run: UUID
        let phrase: Int?
        let record: VoiceConsentRecord
        let voiced: [Float]
    }
    private var samples: [Sample] = []
    private var mismatches: [String: UUID] = [:]
    private var unmeasured: [UUID: VoiceLabTakeRow] = [:]

    func remember(_ sample: Sample) {
        guard !sample.voiced.isEmpty, !samples.contains(where: { $0.id == sample.id }) else { return }
        samples.append(sample)
    }
    func measured(record: String, run: UUID, passed: Bool) {
        if !passed { mismatches[record] = run }
        // A later passing group in the failing run cannot erase that run's mismatch.
        else if mismatches[record] != run { mismatches.removeValue(forKey: record) }
    }
    func allowsUnmeasured(record: String) -> Bool { mismatches[record] == nil }
    func earlier(record: VoiceConsentRecord, phrase: Int, excluding run: UUID) -> [Sample] {
        let earlier = samples.reversed().filter { $0.run != run && $0.record == record }
        return earlier.filter { $0.phrase == phrase } + earlier.filter { $0.phrase != phrase }
    }
    func rememberUnmeasured(_ row: VoiceLabTakeRow) { unmeasured[row.id] = row }
    func unmeasuredUpdates() -> [UUID: VoiceLabTakeRow] {
        unmeasured.mapValues { row in
            guard let evidence = row.voiceCheck.evidence else { return row }
            let failure: VoiceLabTakeFailure? = mismatches[evidence.recordId] == nil ? nil : .qa([.speaker])
            return row.checkingVoice(row.voiceCheck, failure: failure)
        }
    }
    package func reset() { samples.removeAll(); mismatches.removeAll(); unmeasured.removeAll() }
}

/// One approved run's generated speech. Never retains source speech, pads or buys audio.
public actor VoiceLabShortTakePool {
    private struct Member: Sendable {
        let row: VoiceLabTakeRow
        let voiced: [Float]
        let phrase: Int?
        let record: VoiceConsentRecord
        let speaker: VoiceSpeakerCheck
        let store: VoiceConsentStore
        let current: @Sendable () async -> Bool
    }
    private let session: VoiceLabVoiceCheckSession
    private let run = UUID()
    private let retryPhrase: Int?
    private var members: [Member] = []
    private var finishing: Task<[UUID: VoiceLabTakeRow], Never>?
    public init() { session = VoiceLabVoiceCheckSession(); retryPhrase = nil }
    package init(session: VoiceLabVoiceCheckSession, retryPhrase: Int? = nil) {
        self.session = session; self.retryPhrase = retryPhrase
    }

    func append(_ row: VoiceLabTakeRow, voiced: [Float], record: VoiceConsentRecord,
                speaker: VoiceSpeakerCheck, store: VoiceConsentStore, phrase: Int? = nil,
                current: @escaping @Sendable () async -> Bool) async throws {
        guard finishing == nil, row.voiceCheck == .waiting,
              voiced.count < SpeakerAudio.windowSize, voiced.allSatisfy(\.isFinite),
              !members.contains(where: { $0.row.id == row.id }) else { throw VoiceLabError.invalidInput }
        members.append(Member(row: row, voiced: voiced, phrase: phrase, record: record, speaker: speaker, store: store, current: current))
        // Preserve generation order alongside long takes, whose measurements finish immediately.
        await session.remember(.init(id: row.id, run: run, phrase: phrase, record: record, voiced: voiced))
    }

    func measured(id: UUID, voiced: [Float], record: VoiceConsentRecord, phrase: Int?, passed: Bool) async {
        await session.measured(record: record.id, run: run, passed: passed)
        await session.remember(.init(id: id, run: run, phrase: phrase, record: record, voiced: voiced))
    }

    /// Stop drains the local check in a fresh task; consent and current inputs are checked again.
    public func finish() async -> [UUID: VoiceLabTakeRow] {
        if let finishing { return await finishing.value }
        let snapshot = members
        members.removeAll()
        let session = session, run = run, retryPhrase = retryPhrase
        let operation = Task.detached(priority: .utility) {
            await Self.check(snapshot, session: session, run: run, retryPhrase: retryPhrase)
        }
        finishing = operation
        return await operation.value
    }

    /// Consecutive groups stop at the first take reaching three seconds. An undersized tail
    /// joins the last complete group, rather than diluting every take in the approved run.
    private static func groups(_ members: [Member]) -> [[Member]] {
        var groups: [[Member]] = [], pending: [Member] = []
        var frames = 0
        for member in members {
            pending.append(member); frames += member.voiced.count
            if frames >= SpeakerAudio.windowSize {
                groups.append(pending); pending = []; frames = 0
            }
        }
        if !pending.isEmpty {
            if groups.isEmpty { groups.append(pending) }
            else { groups[groups.count - 1].append(contentsOf: pending) }
        }
        return groups
    }

    private static func check(_ members: [Member], session: VoiceLabVoiceCheckSession,
                              run: UUID, retryPhrase: Int?) async -> [UUID: VoiceLabTakeRow] {
        var results: [UUID: VoiceLabTakeRow] = [:]
        var checked = Set<String>()
        for first in members where checked.insert(first.record.id).inserted {
            let recordMembers = members.filter { $0.record.id == first.record.id }
            for group in groups(recordMembers) {
                do {
                    guard group.allSatisfy({ $0.record == first.record }) else { throw VoiceConsentError.invalidRecord }
                    try await first.store.validateUse(first.record)
                    for member in group {
                        guard await member.current() else { throw VoiceLabError.consentRequired }
                    }
                    var voiced = group.flatMap(\.voiced)
                    var takeCount = group.count
                    if let retryPhrase, voiced.count < SpeakerAudio.windowSize {
                        let earlier = await session.earlier(record: first.record, phrase: retryPhrase, excluding: run)
                        for sample in earlier {
                            let needed = SpeakerAudio.windowSize - voiced.count
                            guard needed > 0 else { break }
                            voiced.append(contentsOf: sample.voiced.prefix(needed))
                            takeCount += 1
                        }
                    }
                    let mode: VoiceLabShortSpeechEvidence.Mode = voiced.count >= SpeakerAudio.windowSize ? .pooled : .unmeasured
                    let evidence = VoiceLabShortSpeechEvidence(mode: mode, recordId: first.record.id,
                        consentMethod: first.record.consentMethod, voicedFrames: voiced.count, takeCount: takeCount)
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
                    let mismatch: Bool
                    if let score {
                        mismatch = score < first.record.speaker.threshold
                        await session.measured(record: first.record.id, run: run, passed: !mismatch)
                    } else { mismatch = !(await session.allowsUnmeasured(record: first.record.id)) }
                    let failure: VoiceLabTakeFailure? = mismatch ? .qa([.speaker]) : nil
                    for member in group {
                        if mode == .unmeasured {
                            let unmeasured = member.row.checkingVoice(.shortSpeech(evidence))
                            await session.rememberUnmeasured(unmeasured)
                        }
                        results[member.row.id] = member.row.checkingVoice(.shortSpeech(evidence), score: score, failure: failure)
                    }
                } catch {
                    let failure: VoiceLabTakeFailure
                    if let error = error as? VoiceConsentError {
                        if error == .speakerMismatch {
                            await session.measured(record: first.record.id, run: run, passed: false)
                            failure = .qa([.speaker])
                        } else { failure = .consent(error) }
                    } else if let error = error as? VoiceLabError { failure = .provider(error) }
                    else { failure = .invalidAudio }
                    for member in group {
                        results[member.row.id] = member.row.checkingVoice(.perTake, failure: failure)
                    }
                }
            }
        }
        results.merge(await session.unmeasuredUpdates()) { _, current in current }
        return results
    }
}
