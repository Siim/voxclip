import Darwin
import Foundation
import VoxClipCore

public struct LipsyncResultProvenance: Codable, Sendable, Equatable {
    public let provider: String
    public let model: String
    public let requestID: String
    public let quoteID: UUID
    public let videoInputSHA256: String
    public let audioInputSHA256: String
    public let outputSHA256: String
    public let syncMode: SyncMode
    public let seed: UInt32?
    public let submittedAt: Date
    public let importedAt: Date
    public let estimate: CostEstimate
}

public struct ImportedLipsyncResult: Sendable, Equatable {
    public let asset: VoiceLabVideoAsset
    public let url: URL
    public let provenance: LipsyncResultProvenance
    public var colorWarning = false
    /// Imported from an earlier paid attempt's kept file or re-fetched result: nothing new was paid for it.
    public var recovered = false

    public func videoRecipe(sourceStartSample: Int64, sourceEndSample: Int64, outputSamples: Int64,
                            windowStartSample: Int64, windowEndSample: Int64) throws -> VoiceLabVideoRecipe {
        guard sourceStartSample >= 0, sourceEndSample > sourceStartSample, outputSamples > 0,
              windowStartSample >= 0, windowStartSample <= sourceStartSample, windowEndSample >= sourceEndSample,
              windowEndSample > windowStartSample else { throw LipsyncError.invalidInput }
        return VoiceLabVideoRecipe(mode: .lipsync, sourceStartSample: sourceStartSample, sourceEndSample: sourceEndSample,
                                   outputSamples: outputSamples, retimeFactor: nil, zoom: nil, faceX: nil, faceY: nil,
                                   assetId: asset.id, provider: provenance.provider, model: provenance.model,
                                   requestId: provenance.requestID, windowStartSample: windowStartSample,
                                   windowEndSample: windowEndSample, syncMode: provenance.syncMode.rawValue)
    }
}

/// A lip sync that reached fal.ai and failed after it was accepted: fal.ai may have billed `attempt.estimate`.
/// `freeRetry` when its result is kept (the downloaded file, or a request ID fal.ai still answers), so Try Again re-imports
/// it without paying again (design.md, Stopped: "Try Again · free").
public struct LipsyncAttemptFailure: Error, Sendable {
    public let error: any Error
    public let attempt: LipsyncAttempt
    public let freeRetry: Bool
}

/// A free Try Again found nothing it could import (the kept file is gone, or fal.ai no longer has the result). Nothing was paid.
public struct LipsyncRecoveryFailed: Error, Sendable {
    public let error: any Error
}

public struct LipsyncResultImporter: Sendable {
    public init() {}

    /// Downloads a finished job's result and stores it as the window's picture (`neededSeconds` long, the voice's; the
    /// quote's inputs ran `LipsyncLimits.tailMarginSeconds` longer). A failure after the download keeps the file beside
    /// the attempt's record; a failed download leaves the result at fal.ai to be fetched again by its request ID. Either
    /// way it throws `LipsyncAttemptFailure`.
    public func importResult(provider: FalLipsyncProvider, job: LipsyncJob, quote: LipsyncQuote, neededSeconds: Double? = nil,
                             picture: Data? = nil, projectID: String, paidRoot: URL, sourceWidth: Int, sourceHeight: Int,
                             referenceVideo: LipsyncUploadFile? = nil) async throws -> ImportedLipsyncResult {
        let needed = neededSeconds ?? quote.outputDurationSeconds
        guard UUID(uuidString: projectID)?.uuidString.lowercased() == projectID,
              try await provider.quote(for: job) == quote, quote.model == job.model,
              needed.isFinite, needed > 0, needed <= quote.outputDurationSeconds + 1e-6,
              Self.validSize(sourceWidth, sourceHeight) else { throw LipsyncError.invalidInput }
        try Task.checkCancellation()
        let result = try await provider.wait(job)
        try Task.checkCancellation()
        var attempt = LipsyncAttempt(job: job, quote: quote, neededSeconds: needed)
        attempt.picture = picture
        let scratch = try LipsyncImportScratch(projectID: projectID, paidRoot: paidRoot)
        defer { scratch.remove() }
        func stillCurrent() async throws {
            try Task.checkCancellation()
            guard let status = await provider.status(quoteID: quote.id), !status.cancelled else { throw CancellationError() }
        }
        do { try await provider.download(result, to: scratch.result) }
        catch {
            if Task.isCancelled || error is CancellationError { await provider.cleanup(job); throw error }
            // Not downloaded: fal.ai keeps the output for its lifecycle, so its payloads stay for a free re-fetch.
            throw LipsyncAttemptFailure(error: error, attempt: attempt, freeRetry: attempt.refetchable(at: await provider.date()))
        }
        do {
            try await stillCurrent()
            let (imported, length) = try await store(scratch.result, attempt: attempt, scratch: scratch, projectID: projectID,
                paidRoot: paidRoot, width: sourceWidth, height: sourceHeight, reference: referenceVideo, stillCurrent: stillCurrent)
            await provider.note(length.logLine)
            await provider.cleanup(job)
            do { try await stillCurrent() } catch {
                scratch.unlinkAsset(imported.asset.id)
                throw error
            }
            LipsyncAttemptStore.discard(attempt, projectID: projectID, paidRoot: paidRoot)
            return imported
        } catch {
            if Task.isCancelled || error is CancellationError { await provider.cleanup(job); throw error }
            if let check = error as? LipsyncResultCheck { await provider.note(check.logLine) }
            // The paid result is kept beside its attempt before fal.ai deletes its copy.
            let kept = (try? LipsyncAttemptStore.keep(scratch.result, for: attempt, projectID: projectID, paidRoot: paidRoot)) != nil
            if kept { await provider.cleanup(job) }
            let refetchable = attempt.refetchable(at: await provider.date())
            throw LipsyncAttemptFailure(error: error, attempt: attempt, freeRetry: kept || refetchable)
        }
    }

    /// Try Again after a paid failure, for free: imports the attempt's kept file, else fetches its result again from fal.ai by
    /// request ID. Throws `LipsyncRecoveryFailed` when neither is there; a result that still fails its checks stays kept.
    public func importRecovered(_ attempt: LipsyncAttempt, provider: FalLipsyncProvider, projectID: String, paidRoot: URL,
                                sourceWidth: Int, sourceHeight: Int, referenceVideo: LipsyncUploadFile? = nil) async throws -> ImportedLipsyncResult {
        guard UUID(uuidString: projectID)?.uuidString.lowercased() == projectID, Self.validSize(sourceWidth, sourceHeight),
              let model = provider.models.first(where: { $0.id == attempt.model }) else { throw LipsyncError.invalidInput }
        let scratch = try LipsyncImportScratch(projectID: projectID, paidRoot: paidRoot)
        defer { scratch.remove() }
        let refetched: Bool
        if let kept = LipsyncAttemptStore.keptResult(attempt, projectID: projectID, paidRoot: paidRoot) {
            do { try FileManager.default.copyItem(at: kept, to: scratch.result) } catch { throw LipsyncRecoveryFailed(error: error) }
            refetched = false
        } else if attempt.refetchable(at: await provider.date()) {
            do { try await provider.refetch(requestID: attempt.requestID, model: model, to: scratch.result) }
            catch {
                if Task.isCancelled || error is CancellationError { throw error }
                throw LipsyncRecoveryFailed(error: error)
            }
            refetched = true
        } else { throw LipsyncRecoveryFailed(error: LipsyncError.unknownJob) }
        do {
            var (imported, length) = try await store(scratch.result, attempt: attempt, scratch: scratch, projectID: projectID,
                paidRoot: paidRoot, width: sourceWidth, height: sourceHeight, reference: referenceVideo, stillCurrent: { try Task.checkCancellation() })
            await provider.note(length.logLine + " recovered=\(refetched ? "refetch" : "kept")")
            if refetched { await provider.cleanup(requestID: attempt.requestID) }
            LipsyncAttemptStore.discard(attempt, projectID: projectID, paidRoot: paidRoot)
            imported.recovered = true
            return imported
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            if let check = error as? LipsyncResultCheck { await provider.note(check.logLine + " recovered=\(refetched ? "refetch" : "kept")") }
            if refetched, (try? LipsyncAttemptStore.keep(scratch.result, for: attempt, projectID: projectID, paidRoot: paidRoot)) != nil {
                await provider.cleanup(requestID: attempt.requestID)
            }
            throw LipsyncAttemptFailure(error: error, attempt: attempt, freeRetry: false)
        }
    }

    private static func validSize(_ width: Int, _ height: Int) -> Bool {
        (16...4_096).contains(width) && (16...4_096).contains(height) && width.isMultiple(of: 2) && height.isMultiple(of: 2)
    }

    /// Conforms `downloaded` (in `scratch`) to the attempt's window and stores it as a new paid video asset.
    private func store(_ downloaded: URL, attempt: LipsyncAttempt, scratch: LipsyncImportScratch, projectID: String, paidRoot: URL,
                       width: Int, height: Int, reference: LipsyncUploadFile?,
                       stillCurrent: () async throws -> Void) async throws -> (ImportedLipsyncResult, LipsyncResultLength) {
        let conformed = try await LipsyncResultConformer.conform(downloaded, needed: attempt.neededSeconds,
            uploaded: attempt.uploadedSeconds, fps: attempt.fps, width: width, height: height, reference: reference)
        let assetID = UUID().uuidString.lowercased()
        let relative = "\(projectID)/\(assetID).mp4"
        let destination = paidRoot.appendingPathComponent(relative)
        let staged = try LipsyncStagedFile(destination: destination)
        defer { staged.discard() }
        var info = stat()
        guard lstat(conformed.url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (12...Int64(LipsyncLimits.maximumVideoBytes)).contains(info.st_size) else { throw LipsyncError.invalidMedia }
        let hash = try copy(conformed.url, to: staged.descriptor, byteCount: Int(info.st_size))
        let metadata = try await LipsyncResultValidation.validate(file: staged.temporaryURL, durationSeconds: attempt.neededSeconds,
                                                                  fps: attempt.fps, width: width, height: height)
        try await stillCurrent()
        try staged.commit()
        let provenance = LipsyncResultProvenance(provider: attempt.provider, model: attempt.model, requestID: attempt.requestID,
                                                quoteID: attempt.quoteID, videoInputSHA256: attempt.videoSHA256,
                                                audioInputSHA256: attempt.audioSHA256, outputSHA256: hash,
                                                syncMode: attempt.syncMode, seed: attempt.seed,
                                                submittedAt: attempt.submittedAt, importedAt: Date(), estimate: attempt.estimate)
        let asset = VoiceLabVideoAsset(id: assetID, file: relative, sha256: hash, durationSeconds: metadata.durationSeconds,
                                      frameRate: metadata.frameRate, width: metadata.width, height: metadata.height)
        return (ImportedLipsyncResult(asset: asset, url: destination, provenance: provenance, colorWarning: conformed.colorWarning),
                conformed.length)
    }

    private func copy(_ file: URL, to output: Int32, byteCount: Int) throws -> String {
        let directory = try LipsyncLocalPath.openDirectory(file.deletingLastPathComponent())
        defer { Darwin.close(directory) }
        let input = openat(directory, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw LipsyncError.unsafeFile }
        defer { Darwin.close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == byteCount else {
            throw LipsyncError.unsafeFile
        }
        var count = 0, hash = SpeechSHA256()
        let bufferCapacity = 64 * 1_024
        var buffer = [UInt8](repeating: 0, count: bufferCapacity)
        while true {
            try Task.checkCancellation()
            let length = read(input, &buffer, bufferCapacity)
            if length < 0 && errno == EINTR { continue }
            guard length >= 0, length <= byteCount - count else { throw LipsyncError.invalidMedia }
            if length == 0 { break }
            let data = Data(buffer.prefix(length)); hash.update(data)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < length {
                    let written = write(output, bytes.baseAddress!.advanced(by: offset), length - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw LipsyncError.unsafeFile }
                    offset += written
                }
            }
            count += length
        }
        guard count == byteCount else { throw LipsyncError.invalidMedia }
        return hash.hexDigest()
    }
}

/// The import's private scratch folder inside the project's paid folder (same volume, so a kept result moves, never copies).
final class LipsyncImportScratch {
    let projectID: String
    let paidRoot: URL
    let name = ".lipsync-import-\(UUID().uuidString.lowercased())"
    let folder: URL
    var result: URL { folder.appendingPathComponent("result.mp4") }

    init(projectID: String, paidRoot: URL) throws {
        self.projectID = projectID; self.paidRoot = paidRoot
        let root = try LipsyncLocalPath.openDirectory(paidRoot)
        defer { Darwin.close(root) }
        let project = try VoiceLabPaidRoot.directory(projectID, in: root)
        defer { Darwin.close(project) }
        guard mkdirat(project, name, 0o700) == 0 else { throw LipsyncError.unsafeFile }
        folder = paidRoot.appendingPathComponent(projectID, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    private func withProject(_ body: (Int32) -> Void) {
        guard let root = try? LipsyncLocalPath.openDirectory(paidRoot) else { return }
        defer { Darwin.close(root) }
        let project = openat(root, projectID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard project >= 0 else { return }
        defer { Darwin.close(project) }
        body(project)
    }

    func unlinkAsset(_ assetID: String) { withProject { unlinkat($0, "\(assetID).mp4", 0) } }

    func remove() {
        if let scratch = try? LipsyncLocalPath.openDirectory(folder) {
            for file in ["result.mp4", "reference.mp4", "conformed.mp4"] { unlinkat(scratch, file, 0) }
            Darwin.close(scratch)
        }
        withProject { unlinkat($0, name, AT_REMOVEDIR) }
    }
}
