import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite(.offlineFixtures) struct VoiceLabAssetRetentionTests {
    @Test(arguments: ["replacement", "live-instance", "late-reference"])
    func deletionRequiresOwnedIdentityAndNoActiveDocuments(scenario: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project,
            assetId: "candidate", paidRoot: root, createdAt: now)
        try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: now,
            observation: .init(session: "test", monotonicSeconds: 0))
        let activity = scenario == "live-instance" ? try VoiceLabAssetActivity(paidRoot: root) : nil
        var rechecked = false
        let result = try withExtendedLifetime(activity) {
            try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [],
                now: now.addingTimeInterval(7 * 86400), observation: .init(session: "test", monotonicSeconds: 7 * 86400),
                recheckReferences: {
                    rechecked = true
                    if scenario == "replacement" {
                        try Data("replacement user file".utf8).write(to: root.appendingPathComponent(asset.file), options: .atomic)
                    }
                    return scenario == "late-reference" ? [asset.file] : []
                })
        }
        #expect(result.isEmpty && FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
        #expect(rechecked == (scenario != "live-instance"))
        if scenario == "replacement" { #expect(try Data(contentsOf: root.appendingPathComponent(asset.file)) == Data("replacement user file".utf8)) }
    }
    @Test func observedCandidatesRespectSevenDaysAndReferencesNeverExpire() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let orphan = try VoiceLabAssetStore.write(pcm16: Data([0, 1, 0, 1]), sampleRate: 24000, projectId: project,
            assetId: "orphan", paidRoot: root, createdAt: date.addingTimeInterval(-30 * 86400))
        let historical = try VoiceLabAssetStore.write(pcm16: Data([0, 1, 0, 1]), sampleRate: 24000, projectId: project,
            assetId: "historical", paidRoot: root, createdAt: date)
        let video = "\(project)/orphan-video.mp4"
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent(video))
        #expect(try VoiceLabAssetStore.recoverStalePartials(paidRoot: root) == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan.file).path))
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [historical.file], now: date,
            observation: .init(session: "test", monotonicSeconds: 0)).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(7 * 86400 - 1),
            observation: .init(session: "test", monotonicSeconds: 7 * 86400 - 1)).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(7 * 86400),
            observation: .init(session: "test", monotonicSeconds: 7 * 86400)) == [orphan.file])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(video).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(historical.file).path))
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(100 * 86400)).isEmpty)
    }
    @Test(arguments: ["forward", "backward", "restart", "reference"])
    func clockDiscontinuitiesRestartGraceAndReferencesAreCheckedAtDeletion(_ change: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project,
            assetId: "candidate", paidRoot: root, createdAt: date)
        try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date,
            observation: .init(session: "first", monotonicSeconds: 0))
        let elapsed: Double = change == "backward" ? -1 : 8 * 86400
        var observations = 0
        let removed = try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [],
            now: date.addingTimeInterval(elapsed), observation: .init(session: change == "restart" ? "next" : "first",
                monotonicSeconds: change == "reference" ? elapsed : 1), recheckReferences: {
                    observations += 1; return [asset.file]
                })
        #expect(removed.isEmpty && FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
        #expect(observations == (change == "reference" ? 1 : 0))
        let ledger = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(project + "/.asset-retention.json"))) as? [String: Any]
        let entries = try #require(ledger?["unreferenced"] as? [String: [String: Any]])
        #expect(entries["candidate.wav"]?["lastObservedAt"] != nil)
        if change != "reference" {
            #expect(entries["candidate.wav"]?["discovered"] as? Double == date.addingTimeInterval(elapsed).timeIntervalSinceReferenceDate)
        }
    }
    @Test func startupCompleteUnlistedPaidAssetsArePermanentlyPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project,
            assetId: "complete", paidRoot: root, createdAt: date)
        try VoiceLabAssetRetention.discoverUnlisted(paidRoot: root, now: date)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(100 * 86400)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
    }
    @Test func newReferenceBackwardClockAndAnotherWindowPreventDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project, assetId: "candidate", paidRoot: root, createdAt: date)
        try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(-1)).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(8 * 86400), allowDeletion: false).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [asset.file], now: date.addingTimeInterval(9 * 86400)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
    }
    private func journal(_ asset: VoiceLabAsset, project: String, root: URL, createdAt: Date) throws {
        let key = VoiceLabTakeJournalKey(recordID: "record", voiceID: "voice", modelID: "eleven_v3", language: "en", requestText: "Hello",
                                         previousText: "", nextText: "", pace: nil)
        try VoiceLabTakeJournal.write(VoiceLabTakeJournalEntry(assetFile: asset.file, assetSha256: asset.sha256, requestID: UUID(),
            providerRequestID: nil, key: key, seed: 1, sampleRate: asset.sampleRate, frames: 1, alignment: nil,
            receipt: .init(provider: "elevenlabs", region: "default", endpoint: "v1/text-to-speech/voice/with-timestamps"),
            estimateUSD: nil, createdAt: createdAt), projectID: project, paidRoot: root)
    }
    /// A journaled paid take that no project uses yet is a reference, never a deletion candidate: an unused take survives
    /// eight days unreferenced in one run, where an unjournaled file goes after seven. Use ends its entry, and the asset is
    /// then the project's own reference. It used to be deleted with the other file.
    @Test func journaledPaidTakesAreReferencesUntilUsedThenTheirEntryGoes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let take = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project, assetId: "take", paidRoot: root, createdAt: date)
        let other = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project, assetId: "other", paidRoot: root, createdAt: date)
        try journal(take, project: project, root: root, createdAt: date)
        func close(_ references: Set<String>, days: Double) throws -> [String] {
            try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: references,
                now: date.addingTimeInterval(days * 86400), observation: .init(session: "test", monotonicSeconds: days * 86400))
        }
        #expect(try close([], days: 0).isEmpty)
        #expect(try close([], days: 8) == [other.file])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(take.file).path))
        #expect(VoiceLabTakeJournal.list(projectID: project, paidRoot: root).map(\.assetFile) == [take.file])
        #expect(try close([take.file], days: 9).isEmpty)
        #expect(VoiceLabTakeJournal.list(projectID: project, paidRoot: root).isEmpty)
        #expect(try close([], days: 100).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(take.file).path))
    }
    /// An entry the project never used stays 60 days, then goes at a real close (never at launch's discovery); its asset
    /// is kept and from then on follows the ordinary rules. An entry whose asset is gone goes at once.
    @Test func unusedJournalEntriesAgeOutAfterSixtyDays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let take = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project, assetId: "take", paidRoot: root, createdAt: date)
        let gone = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project, assetId: "gone", paidRoot: root, createdAt: date)
        try journal(take, project: project, root: root, createdAt: date)
        try journal(gone, project: project, root: root, createdAt: date)
        try FileManager.default.removeItem(at: root.appendingPathComponent(gone.file))
        func entries() -> [String] { VoiceLabTakeJournal.list(projectID: project, paidRoot: root).map(\.assetFile) }
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(59 * 86400)).isEmpty)
        #expect(entries() == [take.file])
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(61 * 86400),
                                                       allowDeletion: false).isEmpty)
        #expect(entries() == [take.file])
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(61 * 86400)).isEmpty)
        #expect(entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(take.file).path))
    }
    /// An imported lip-sync result the attempt index points at (voice-lab §9.4) is kept, so the same inputs get it again
    /// for free. The importer writes no ownership journal, so the file was never a candidate; the index now also names it
    /// a reference, should a later writer add one.
    @Test func importedLipsyncResultsTheIndexPointsAtAreKept() async throws {
        let root = try LipsyncImportFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let project = LipsyncImportFixture.projectID
        let provider = try LipsyncImportFixture.provider(http: LipsyncImportHTTP(bytes: try FixtureLoader.data("fixtures/media/counter-1080p.mp4")))
        let (quote, job) = try await LipsyncImportFixture.submit(root: root, provider: provider, model: provider.models[0], seconds: 4, fps: 30)
        let result = try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: project,
                                                                   paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date,
            observation: .init(session: "test", monotonicSeconds: 0)).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(8 * 86400),
            observation: .init(session: "test", monotonicSeconds: 8 * 86400)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: result.url.path))
    }
    @Test func corruptLedgerAndSymlinkNeverAuthorizeDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project, assetId: "keep", paidRoot: root, createdAt: date)
        let directory = root.appendingPathComponent(project), target = root.appendingPathComponent("outside.wav")
        try Data([1, 2, 3]).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.wav"), withDestinationURL: target)
        try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [asset.file], now: date)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(".asset-retention.json"))
        #expect(throws: (any Error).self) {
            try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(100 * 86400))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
        #expect(try Data(contentsOf: target) == Data([1, 2, 3]))
    }
}
