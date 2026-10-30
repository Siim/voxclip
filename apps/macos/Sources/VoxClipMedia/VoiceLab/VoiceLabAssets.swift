import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Synchronization
import VoxClipCore

/// Errors from the paid-asset boundary. No case permits a source-audio fallback.
public enum VoiceLabAssetError: Error, LocalizedError, Sendable, Equatable {
    case missing(String), unsafePath(String), altered(String), unsupportedFormat(String)
    case unreadable(String), invalidAudio(String), invalidSelection(String), rateMismatch(String), durationMismatch(String)
    case invalidTrim(String), tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .missing: "The generated Voice Lab audio is missing. Restore the paid file before preview or export."
        case .unsafePath: "The generated Voice Lab audio points outside its paid storage folder. Check the file location."
        case .altered: "The generated Voice Lab audio has changed. Restore the original paid file before preview or export."
        case .unsupportedFormat: "This build cannot decode the generated Voice Lab audio format. Keep the paid file for a supported build."
        case .unreadable, .invalidAudio: "The generated Voice Lab audio cannot be read. Restore a valid paid file before preview or export."
        case .invalidSelection: "The selected Voice Lab take or output plan changed. Rebuild the preview or export request."
        case .rateMismatch, .durationMismatch: "The generated Voice Lab audio no longer matches its project record. Restore the original paid file."
        case .invalidTrim: "The generated Voice Lab audio trim is outside the decoded file. Review the selected take."
        case .tooLarge: "The generated Voice Lab audio exceeds this build's supported length. Keep the paid file for a supported build."
        }
    }
}

/// Owns a private byte-for-byte snapshot until composition releases it. Consumers must read `url`,
/// never reopen the paid-store path after validation.
public final class PreparedVoiceLabAsset: @unchecked Sendable {
    public let segmentId: String
    public let assetId: String
    public let sha256: String
    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public let frameCount: Int64
    public let trimStartFrame: Int64
    public let trimEndFrame: Int64
    public let stretch: Double
    public let gainDb: Double
    private let scratch: VoiceLabAssetRecovery.Operation
    private let valid = Mutex(true)
    public var isValid: Bool { valid.withLock { $0 } }
    public func invalidate() {
        valid.withLock { valid in
            guard valid else { return }
            valid = false
            scratch.discard()
        }
    }

    fileprivate init(segmentId: String, assetId: String, sha256: String, url: URL, sampleRate: Int, channels: Int, frameCount: Int64,
                     trimStartFrame: Int64, trimEndFrame: Int64, stretch: Double, gainDb: Double, scratch: VoiceLabAssetRecovery.Operation) {
        self.segmentId = segmentId; self.assetId = assetId; self.sha256 = sha256; self.url = url; self.sampleRate = sampleRate; self.channels = channels
        self.frameCount = frameCount; self.trimStartFrame = trimStartFrame; self.trimEndFrame = trimEndFrame
        self.stretch = stretch; self.gainDb = gainDb; self.scratch = scratch
    }
    deinit { invalidate() }
}

public enum VoiceLabAssets {
    static let maxBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maxFrames: Int64 = 192_000 * 86_400

    /// Prepare only assets used by this scope; source-only plans need no paid files.
    public static func prepare(project: Project, plan: VoiceLabOutputPlan, paidRoot: URL) throws -> [String: PreparedVoiceLabAsset] {
        try prepare(project: project, plan: plan, paidRoot: paidRoot, scratchRoot: FileManager.default.temporaryDirectory)
    }

    /// Each snapshot goes in a fresh folder under `scratchRoot`.
    static func prepare(project: Project, plan: VoiceLabOutputPlan, paidRoot: URL, scratchRoot: URL) throws -> [String: PreparedVoiceLabAsset] {
        try VoiceLabProject.validate(project)
        guard try VoiceLabOutputPlanner.build(project, scope: plan.scope) == plan else {
            throw VoiceLabAssetError.invalidSelection("output plan")
        }
        var prepared: [String: PreparedVoiceLabAsset] = [:]
        for piece in plan.pieces where piece.kind == .synth {
            try Task.checkCancellation()
            guard let id = piece.assetId, let segmentId = piece.segmentId, let audio = piece.audio,
                  let asset = project.voiceLab.assets?.first(where: { $0.id == id }) else {
                throw VoiceLabAssetError.invalidSelection(piece.segmentId ?? "segment")
            }
            if prepared[segmentId] == nil {
                prepared[segmentId] = try prepare(asset: asset, audio: audio, segmentId: segmentId, project: project, paidRoot: paidRoot,
                                                  scratchRoot: scratchRoot)
            }
        }
        return prepared
    }

    public static func prepare(asset: VoiceLabAsset, audio: VoiceLabAudio, segmentId: String, project: Project, paidRoot: URL) throws -> PreparedVoiceLabAsset {
        try prepare(asset: asset, audio: audio, segmentId: segmentId, project: project, paidRoot: paidRoot,
                    scratchRoot: FileManager.default.temporaryDirectory)
    }

    static func prepare(asset: VoiceLabAsset, audio: VoiceLabAudio, segmentId: String, project: Project, paidRoot: URL,
                        scratchRoot: URL) throws -> PreparedVoiceLabAsset {
        try VoiceLabProject.validate(project)
        guard project.voiceLab.assets?.contains(asset) == true,
              project.voiceLab.segments.first(where: { $0.id == segmentId })?.audio == audio,
              audio.assetId == asset.id else { throw VoiceLabAssetError.invalidSelection(asset.id) }
        return try snapshot(asset: asset, audio: audio, segmentId: segmentId, projectId: project.id, paidRoot: paidRoot, scratchRoot: scratchRoot)
    }

    public static func preparePaid(asset: VoiceLabAsset, projectId: String, paidRoot: URL, scratchRoot: URL) throws -> PreparedVoiceLabAsset {
        let audio = VoiceLabAudio(assetId: asset.id, trimStart: 0, trimEnd: asset.durationSeconds)
        return try snapshot(asset: asset, audio: audio, segmentId: asset.id, projectId: projectId, paidRoot: paidRoot, scratchRoot: scratchRoot)
    }

    private static func snapshot(asset: VoiceLabAsset, audio: VoiceLabAudio, segmentId: String, projectId: String,
                                 paidRoot: URL, scratchRoot: URL) throws -> PreparedVoiceLabAsset {
        let expected = try VoiceLabAssetNaming.file(projectId: projectId, assetId: asset.id, extension: (asset.file as NSString).pathExtension)
        guard asset.file == expected, asset.kind == "audio", asset.durationSeconds.isFinite, asset.durationSeconds > 0,
              asset.sha256.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else { throw VoiceLabAssetError.invalidSelection(asset.id) }
        let root = paidRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw errno == EACCES || errno == EPERM ? VoiceLabAssetError.unreadable(asset.file) : VoiceLabAssetError.missing(asset.file)
        }
        defer { Darwin.close(rootFD) }
        let projectFD = Darwin.openat(rootFD, projectId, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard projectFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw VoiceLabAssetError.unsafePath(asset.file) }
            throw errno == EACCES || errno == EPERM ? VoiceLabAssetError.unreadable(asset.file) : VoiceLabAssetError.missing(asset.file)
        }
        defer { Darwin.close(projectFD) }
        let name = String(asset.file.split(separator: "/").last!)
        let sourceFD = Darwin.openat(projectFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else {
            if errno == ELOOP { throw VoiceLabAssetError.unsafePath(asset.file) }
            throw errno == EACCES || errno == EPERM ? VoiceLabAssetError.unreadable(asset.file) : VoiceLabAssetError.missing(asset.file)
        }
        let source = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        var info = stat()
        guard fstat(sourceFD, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw VoiceLabAssetError.unsafePath(asset.file) }
        guard info.st_size > 0, info.st_size <= maxBytes else { throw VoiceLabAssetError.tooLarge(asset.file) }

        let operation: VoiceLabAssetRecovery.Operation
        do { operation = try VoiceLabAssetRecovery.Operation.create(in: scratchRoot) }
        catch { throw VoiceLabAssetError.unreadable(asset.file) }
        let scratch = scratchRoot.appendingPathComponent(operation.name, isDirectory: true)
        do {
            let snapshot = scratch.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: snapshot.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VoiceLabAssetError.unreadable(asset.file) }
            let writer = try FileHandle(forWritingTo: snapshot)
            defer { try? writer.close() }
            var hash = SHA256()
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                let bytes = try source.read(upToCount: 1024 * 1024) ?? Data()
                if bytes.isEmpty { break }
                copied += Int64(bytes.count)
                guard copied <= maxBytes else { throw VoiceLabAssetError.tooLarge(asset.file) }
                hash.update(data: bytes)
                try writer.write(contentsOf: bytes)
            }
            guard copied == info.st_size,
                  hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
                throw VoiceLabAssetError.altered(asset.file)
            }
            try writer.close()
            guard name.hasSuffix(".wav") || name.hasSuffix(".flac") else { throw VoiceLabAssetError.unsupportedFormat(asset.file) }
            let reader: AVAudioFile
            do { reader = try AVAudioFile(forReading: snapshot, commonFormat: .pcmFormatFloat32, interleaved: false) }
            catch { throw VoiceLabAssetError.unsupportedFormat(asset.file) }
            let format = reader.processingFormat
            let rate = format.sampleRate
            let channels = Int(format.channelCount)
            guard rate.isFinite, rate >= 8_000, rate <= 192_000, rate.rounded() == rate,
                  channels >= 1, channels <= 8, Int(rate) == asset.sampleRate else { throw VoiceLabAssetError.rateMismatch(asset.file) }
            guard reader.length > 0, reader.length <= maxFrames,
                  abs(Double(reader.length) - asset.durationSeconds * rate) <= 1 else { throw VoiceLabAssetError.durationMismatch(asset.file) }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw VoiceLabAssetError.unreadable(asset.file) }
            var decoded: Int64 = 0
            while decoded < reader.length {
                try Task.checkCancellation()
                let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), reader.length - decoded))
                do { try reader.read(into: buffer, frameCount: requested) } catch { throw VoiceLabAssetError.unreadable(asset.file) }
                if buffer.frameLength == 0 { throw VoiceLabAssetError.durationMismatch(asset.file) }
                guard let planes = buffer.floatChannelData else { throw VoiceLabAssetError.invalidAudio(asset.file) }
                for channel in 0..<channels {
                    for index in 0..<Int(buffer.frameLength) where !planes[channel][index].isFinite {
                        throw VoiceLabAssetError.invalidAudio(asset.file)
                    }
                }
                decoded += Int64(buffer.frameLength)
                guard decoded <= maxFrames else { throw VoiceLabAssetError.tooLarge(asset.file) }
            }
            guard abs(decoded - reader.length) <= 1, abs(Double(decoded) - asset.durationSeconds * rate) <= 1 else {
                throw VoiceLabAssetError.durationMismatch(asset.file)
            }
            let start = frame(audio.trimStart, rate: asset.sampleRate)
            let end = frame(audio.trimEnd, rate: asset.sampleRate)
            guard start >= 0, end > start, end <= decoded else { throw VoiceLabAssetError.invalidTrim(asset.file) }
            return PreparedVoiceLabAsset(segmentId: segmentId, assetId: asset.id, sha256: asset.sha256, url: snapshot, sampleRate: Int(rate), channels: channels,
                                         frameCount: decoded, trimStartFrame: start, trimEndFrame: end,
                                         stretch: audio.stretch, gainDb: audio.gainDb, scratch: operation)
        } catch {
            operation.discard()
            if error is CancellationError || error is VoiceLabAssetError { throw error }
            throw VoiceLabAssetError.unreadable(asset.file)
        }
    }

    private static func frame(_ seconds: Double, rate: Int) -> Int64 { Int64((seconds * Double(rate) + 0.5).rounded(.down)) }
}
