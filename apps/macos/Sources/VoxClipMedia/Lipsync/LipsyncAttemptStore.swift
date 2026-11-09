import Darwin
import Foundation
import VoxClipCore

/// A lip-sync job that reached fal.ai (accepted, so it may bill): its request ID and model, never the signed result URL,
/// with what the import needs to finish it later, even after a restart (voice-lab §9.4 "Paid results are kept").
public struct LipsyncAttempt: Codable, Sendable, Equatable {
    public let requestID: String
    public let provider: String
    public let model: String
    public let quoteID: UUID
    public let syncMode: SyncMode
    public let seed: UInt32?
    public let estimate: CostEstimate
    public let submittedAt: Date
    public let videoSHA256: String
    public let audioSHA256: String
    /// The voice's length, what the result is cut back to, and what was uploaded (with the tail margin).
    public let neededSeconds: Double
    public let uploadedSeconds: Double
    public let fps: Double
    /// The downloaded result is kept beside this record because its import failed.
    public var keptResult = false
    /// The upload's picture fingerprint (`LipsyncPictureFingerprint`): the upload's H.264 differs when the window is
    /// prepared again, so a record whose video hash differs is matched by its audio hash and this.
    var picture: Data?

    public init(job: LipsyncJob, quote: LipsyncQuote, neededSeconds: Double) {
        requestID = job.remoteID; provider = job.model.provider; model = job.model.id; quoteID = quote.id
        syncMode = quote.options.syncMode; seed = quote.options.seed; estimate = quote.estimate; submittedAt = job.submittedAt
        videoSHA256 = quote.video.sha256; audioSHA256 = quote.audio.sha256
        self.neededSeconds = neededSeconds; uploadedSeconds = quote.outputDurationSeconds; fps = quote.fps
    }

    /// The sidecar's name: the quote's input hashes.
    var key: String { "\(videoSHA256)-\(audioSHA256)" }

    /// fal.ai keeps a finished request's output for its lifecycle (`X-Fal-Object-Lifecycle-Preference`, one hour), so a
    /// result that was never downloaded can be fetched again by its request ID until then.
    public func refetchable(at now: Date) -> Bool { now < submittedAt.addingTimeInterval(3_600 - 120) }
}

/// The paid attempts of one project, under `VoiceLab/<projectId>/lipsync-attempts/` (0700): `<video>-<audio>.json` (0600)
/// and, after a failed import, the downloaded result `<video>-<audio>.mp4` (0600). A record goes when a later import of it
/// succeeds or the attempt is discarded; a new paid attempt over the same inputs replaces it. No project-format change.
public enum LipsyncAttemptStore {
    static let folder = "lipsync-attempts"

    public static func record(_ attempt: LipsyncAttempt, projectID: String, paidRoot: URL) throws {
        try validate(attempt, projectID: projectID)
        try withFolder(projectID: projectID, paidRoot: paidRoot) { attempts in
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(attempt)
            let partial = ".\(attempt.key).json.partial"
            unlinkat(attempts, partial, 0)
            let descriptor = openat(attempts, partial, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw LipsyncError.unsafeFile }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                guard fsync(descriptor) == 0 else { throw LipsyncError.unsafeFile }
                try handle.close()
                guard renameat(attempts, partial, attempts, "\(attempt.key).json") == 0, fsync(attempts) == 0 else { throw LipsyncError.unsafeFile }
            } catch {
                unlinkat(attempts, partial, 0)
                throw error
            }
        }
    }

    /// The attempt over these inputs, if one reached fal.ai and was not finished.
    public static func load(videoSHA256: String, audioSHA256: String, projectID: String, paidRoot: URL) -> LipsyncAttempt? {
        guard isHash(videoSHA256), isHash(audioSHA256) else { return nil }
        return try? withFolder(projectID: projectID, paidRoot: paidRoot, create: false) { attempts -> LipsyncAttempt? in
            guard let attempt = read(attempts, "\(videoSHA256)-\(audioSHA256).json", projectID: projectID),
                  attempt.videoSHA256 == videoSHA256, attempt.audioSHA256 == audioSHA256 else { return nil }
            return attempt
        }
    }

    /// The attempt for a window prepared again: the exact input hashes, else the same audio (the WAV is byte-identical)
    /// with the same model, lengths and a matching picture fingerprint (the H.264 upload is not).
    static func find(_ prepared: PreparedLipsyncWindow, model: String, projectID: String, paidRoot: URL) -> LipsyncAttempt? {
        if let exact = load(videoSHA256: prepared.video.sha256, audioSHA256: prepared.audio.sha256, projectID: projectID, paidRoot: paidRoot),
           exact.model == model { return exact }
        guard isHash(prepared.audio.sha256) else { return nil }
        return try? withFolder(projectID: projectID, paidRoot: paidRoot, create: false) { attempts -> LipsyncAttempt? in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: paidRoot.appendingPathComponent(projectID, isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true).path)) ?? []
            let candidates = names.filter { $0.hasSuffix("-\(prepared.audio.sha256).json") }.sorted().prefix(16)
            for name in candidates {
                guard let attempt = read(attempts, name, projectID: projectID), attempt.audioSHA256 == prepared.audio.sha256,
                      attempt.model == model, abs(attempt.neededSeconds - prepared.neededSeconds) < 1e-6,
                      abs(attempt.uploadedSeconds - prepared.video.durationSeconds) < 1e-6, abs(attempt.fps - prepared.fps) < 1e-6,
                      let picture = attempt.picture, LipsyncPictureFingerprint.matches(picture, prepared.picture) else { continue }
                return attempt
            }
            return nil
        }
    }

    private static func read(_ attempts: Int32, _ name: String, projectID: String) -> LipsyncAttempt? {
        let descriptor = openat(attempts, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              (1...65_536).contains(info.st_size), let data = try? handle.readToEnd() else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let attempt = try? decoder.decode(LipsyncAttempt.self, from: data), "\(attempt.key).json" == name,
              (try? validate(attempt, projectID: projectID)) != nil else { return nil }
        return attempt
    }

    /// Moves a downloaded result (`file`, inside this project's paid folder) beside its record and marks it kept.
    public static func keep(_ file: URL, for attempt: LipsyncAttempt, projectID: String, paidRoot: URL) throws {
        var kept = attempt
        kept.keptResult = true
        try withFolder(projectID: projectID, paidRoot: paidRoot) { attempts in
            let source = try LipsyncLocalPath.openDirectory(file.deletingLastPathComponent())
            defer { Darwin.close(source) }
            guard renameat(source, file.lastPathComponent, attempts, "\(attempt.key).mp4") == 0 else { throw LipsyncError.unsafeFile }
            let descriptor = openat(attempts, "\(attempt.key).mp4", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw LipsyncError.unsafeFile }
            defer { Darwin.close(descriptor) }
            guard fchmod(descriptor, 0o600) == 0, fsync(attempts) == 0 else { throw LipsyncError.unsafeFile }
        }
        try record(kept, projectID: projectID, paidRoot: paidRoot)
    }

    /// The kept result's file, when there is one.
    public static func keptResult(_ attempt: LipsyncAttempt, projectID: String, paidRoot: URL) -> URL? {
        guard attempt.keptResult else { return nil }
        let exists = (try? withFolder(projectID: projectID, paidRoot: paidRoot, create: false) { attempts -> Bool in
            var info = stat()
            return fstatat(attempts, "\(attempt.key).mp4", &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFREG
        }) ?? false
        guard exists else { return nil }
        return paidRoot.appendingPathComponent(projectID, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(attempt.key).mp4")
    }

    /// The attempt is finished (imported) or let go: its record and any kept result go.
    public static func discard(_ attempt: LipsyncAttempt, projectID: String, paidRoot: URL) {
        _ = try? withFolder(projectID: projectID, paidRoot: paidRoot, create: false) { attempts in
            unlinkat(attempts, "\(attempt.key).mp4", 0)
            unlinkat(attempts, "\(attempt.key).json", 0)
            _ = fsync(attempts)
        }
    }

    private static func isHash(_ text: String) -> Bool { text.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil }

    private static func validate(_ attempt: LipsyncAttempt, projectID: String) throws {
        guard UUID(uuidString: attempt.requestID) != nil, UUID(uuidString: projectID)?.uuidString.lowercased() == projectID,
              isHash(attempt.videoSHA256), isHash(attempt.audioSHA256), attempt.neededSeconds.isFinite,
              (3...LipsyncLimits.maximumUploadSeconds).contains(attempt.neededSeconds),
              attempt.uploadedSeconds.isFinite, attempt.uploadedSeconds >= attempt.neededSeconds,
              attempt.uploadedSeconds <= LipsyncLimits.maximumUploadSeconds, attempt.fps.isFinite, (1...120).contains(attempt.fps)
        else { throw LipsyncError.invalidInput }
    }

    private static func withFolder<Value>(projectID: String, paidRoot: URL, create: Bool = true,
                                          _ body: (Int32) throws -> Value) throws -> Value {
        guard UUID(uuidString: projectID)?.uuidString.lowercased() == projectID else { throw LipsyncError.invalidInput }
        let root = try LipsyncLocalPath.openDirectory(paidRoot)
        defer { Darwin.close(root) }
        let project: Int32
        if create { project = try VoiceLabPaidRoot.directory(projectID, in: root) }
        else {
            project = openat(root, projectID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard project >= 0 else { throw LipsyncError.unsafeFile }
        }
        defer { Darwin.close(project) }
        let attempts: Int32
        if create { attempts = try VoiceLabPaidRoot.directory(folder, in: project) }
        else {
            attempts = openat(project, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard attempts >= 0 else { throw LipsyncError.unsafeFile }
        }
        defer { Darwin.close(attempts) }
        return try body(attempts)
    }
}
