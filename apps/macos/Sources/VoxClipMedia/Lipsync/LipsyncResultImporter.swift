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

public struct LipsyncResultImporter: Sendable {
    public init() {}

    public func importResult(provider: FalLipsyncProvider, job: LipsyncJob, quote: LipsyncQuote,
                             projectID: String, paidRoot: URL, sourceWidth: Int, sourceHeight: Int,
                             referenceVideo: LipsyncUploadFile? = nil) async throws -> ImportedLipsyncResult {
        guard UUID(uuidString: projectID)?.uuidString.lowercased() == projectID,
              try await provider.quote(for: job) == quote, quote.model == job.model,
              (16...4_096).contains(sourceWidth), (16...4_096).contains(sourceHeight),
              sourceWidth.isMultiple(of: 2), sourceHeight.isMultiple(of: 2) else { throw LipsyncError.invalidInput }
        try Task.checkCancellation()
        let result = try await provider.wait(job)
        try Task.checkCancellation()
        let root = try LipsyncLocalPath.openDirectory(paidRoot)
        defer { Darwin.close(root) }
        let project = try VoiceLabPaidRoot.directory(projectID, in: root)
        defer { Darwin.close(project) }
        let scratchName = ".lipsync-import-\(UUID().uuidString.lowercased())"
        guard mkdirat(project, scratchName, 0o700) == 0 else { throw LipsyncError.unsafeFile }
        let scratch = paidRoot.appendingPathComponent(projectID, isDirectory: true).appendingPathComponent(scratchName, isDirectory: true)
        let downloaded = scratch.appendingPathComponent("result.mp4")
        defer {
            if let scratchFD = try? LipsyncLocalPath.openDirectory(scratch) {
                for name in ["result.mp4", "reference.mp4", "conformed.mp4"] { unlinkat(scratchFD, name, 0) }
                Darwin.close(scratchFD)
            }
            unlinkat(project, scratchName, AT_REMOVEDIR)
        }
        do {
            try await provider.download(result, to: downloaded)
            try Task.checkCancellation()
            guard let status = await provider.status(quoteID: quote.id), !status.cancelled else { throw CancellationError() }
            let (conformed, colorWarning) = try await LipsyncResultConformer.conform(downloaded,
                duration: quote.outputDurationSeconds, fps: quote.fps, width: sourceWidth, height: sourceHeight, reference: referenceVideo)
            let assetID = UUID().uuidString.lowercased()
            let relative = "\(projectID)/\(assetID).mp4"
            let destination = paidRoot.appendingPathComponent(relative)
            let staged = try LipsyncStagedFile(destination: destination)
            defer { staged.discard() }
            var info = stat()
            guard lstat(conformed.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  (12...Int64(LipsyncLimits.maximumVideoBytes)).contains(info.st_size) else { throw LipsyncError.invalidMedia }
            let hash = try copy(conformed, to: staged.descriptor, byteCount: Int(info.st_size))
            let metadata = try await LipsyncResultValidation.validate(file: staged.temporaryURL, durationSeconds: quote.outputDurationSeconds,
                                                                      fps: quote.fps, width: sourceWidth, height: sourceHeight)
            try Task.checkCancellation()
            guard let status = await provider.status(quoteID: quote.id), !status.cancelled else { throw CancellationError() }
            try staged.commit()
            let provenance = LipsyncResultProvenance(provider: job.model.provider, model: job.model.id, requestID: job.remoteID,
                                                    quoteID: quote.id, videoInputSHA256: quote.video.sha256,
                                                    audioInputSHA256: quote.audio.sha256, outputSHA256: hash,
                                                    syncMode: quote.options.syncMode, seed: quote.options.seed,
                                                    submittedAt: job.submittedAt, importedAt: Date(), estimate: quote.estimate)
            let asset = VoiceLabVideoAsset(id: assetID, file: relative, sha256: hash, durationSeconds: metadata.durationSeconds,
                                          frameRate: metadata.frameRate, width: metadata.width, height: metadata.height)
            await provider.cleanup(job)
            do {
                try Task.checkCancellation()
                guard let status = await provider.status(quoteID: quote.id), !status.cancelled else { throw CancellationError() }
            } catch {
                unlinkat(project, "\(assetID).mp4", 0)
                throw error
            }
            return ImportedLipsyncResult(asset: asset, url: destination, provenance: provenance, colorWarning: colorWarning)
        } catch {
            await provider.cleanup(job)
            throw error
        }
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
