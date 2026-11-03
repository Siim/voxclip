import Darwin
import Foundation
import VoxClipCore

public enum LipsyncReceiptStore {
    private struct Receipt: Encodable {
        let requestID: String
        let quoteID: UUID
        let provider: String
        let model: String
        let syncMode: SyncMode
        let estimate: CostEstimate
        let submittedAt: Date
        let videoSHA256: String
        let audioSHA256: String
    }

    public static func record(job: LipsyncJob, quote: LipsyncQuote, projectID: String, paidRoot: URL) throws {
        guard UUID(uuidString: job.remoteID) != nil, UUID(uuidString: projectID)?.uuidString.lowercased() == projectID,
              job.model == quote.model else { throw LipsyncError.invalidInput }
        let root = try LipsyncLocalPath.openDirectory(paidRoot)
        defer { Darwin.close(root) }
        let project = try VoiceLabPaidRoot.directory(projectID, in: root)
        defer { Darwin.close(project) }
        let receipts = try VoiceLabPaidRoot.directory("lipsync-receipts", in: project)
        defer { Darwin.close(receipts) }
        let descriptor = openat(receipts, "\(job.remoteID).json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LipsyncError.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let value = Receipt(requestID: job.remoteID, quoteID: quote.id, provider: job.model.provider, model: job.model.id,
            syncMode: quote.options.syncMode, estimate: quote.estimate, submittedAt: job.submittedAt,
            videoSHA256: quote.video.sha256, audioSHA256: quote.audio.sha256)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try handle.write(contentsOf: encoder.encode(value))
        guard fsync(descriptor) == 0, fsync(receipts) == 0 else { throw LipsyncError.unsafeFile }
    }
}
