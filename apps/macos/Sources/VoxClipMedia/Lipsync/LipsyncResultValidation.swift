import AVFoundation
import CoreMedia
import Darwin
import Foundation
import VoxClipCore

public struct LipsyncVideoMetadata: Sendable, Equatable {
    /// The video track's own length (a result's audio track may be shorter or longer).
    public let durationSeconds: Double
    public let frameRate: Double
    public let width: Int
    public let height: Int
    public let byteCount: Int
    /// The file carries an audio track (fal.ai's resampled copy of the upload's audio, never used).
    public var hasAudio = false
}

public enum LipsyncResultValidation {
    /// A stored or conformed lip-sync video, bound to its window: `durationSeconds`, `fps` and the size, within a frame.
    public static func validate(file: URL, durationSeconds: Double, fps: Double, width: Int, height: Int) async throws -> LipsyncVideoMetadata {
        let facts: LipsyncVideoMetadata
        do { facts = try await inspect(file: file) }
        catch is LipsyncResultCheck { throw LipsyncError.invalidMedia }
        try validate(facts, durationSeconds: durationSeconds, fps: fps, width: width, height: height)
        return facts
    }

    /// The file's structure, each failure a named check (`LipsyncResultCheck`): a local regular MP4 with no external data,
    /// one H.264 video track (at most one audio track beside it), no rotation, starting at its first frame. Measures the
    /// video track's length, rate and size; the caller decides what they must be.
    public static func inspect(file: URL) async throws -> LipsyncVideoMetadata {
        try Task.checkCancellation()
        let directory = try LipsyncLocalPath.openDirectory(file.deletingLastPathComponent())
        defer { Darwin.close(directory) }
        let descriptor = openat(directory, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw LipsyncError.unsafeFile }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw LipsyncError.invalidMedia }
        guard (12...Int64(LipsyncLimits.maximumVideoBytes)).contains(info.st_size) else {
            throw LipsyncResultCheck.structure(.container, "bytes=\(info.st_size)")
        }
        do { try inspectContainer(descriptor: descriptor, size: Int(info.st_size)) }
        catch LipsyncError.invalidMedia { throw LipsyncResultCheck.structure(.container, "bytes=\(info.st_size)") }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return try await withTaskCancellationHandler {
            guard (try? await asset.load(.isPlayable)) == true, (try? await asset.load(.hasProtectedContent)) == false else {
                throw LipsyncResultCheck.structure(.container, "bytes=\(info.st_size) playable=false")
            }
            let tracks = try await asset.load(.tracks)
            let videos = tracks.filter { $0.mediaType == .video }, audios = tracks.filter { $0.mediaType == .audio }
            guard videos.count == 1, audios.count <= 1, videos.count + audios.count == tracks.count else {
                throw LipsyncResultCheck.structure(.tracks, "videos=\(videos.count) audios=\(audios.count) others=\(tracks.count - videos.count - audios.count)")
            }
            let track = videos[0]
            let formats = try await track.load(.formatDescriptions)
            guard formats.count == 1, CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264 else {
                throw LipsyncResultCheck.structure(.codec, "formats=\(formats.count)")
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(formats[0])
            guard try await track.load(.preferredTransform) == .identity else { throw LipsyncResultCheck.structure(.transform, "identity=false") }
            let rate = Double(try await track.load(.nominalFrameRate))
            let range = try await track.load(.timeRange)
            guard rate.isFinite, rate > 0, range.start.seconds.isFinite, abs(range.start.seconds) <= 1 / rate,
                  range.duration.seconds.isFinite, range.duration.seconds > 0 else {
                throw LipsyncResultCheck.structure(.start, "start=\(LipsyncResultLength.number(range.start.seconds)) fps=\(LipsyncResultLength.number(rate))")
            }
            // The asset's length is the longer track's; a stored file has only the picture, so the two agree.
            let duration = try await asset.load(.duration).seconds
            guard !audios.isEmpty || abs(range.duration.seconds - duration) <= 1 / rate else {
                throw LipsyncResultCheck.structure(.start, "track=\(LipsyncResultLength.number(range.duration.seconds)) movie=\(LipsyncResultLength.number(duration))")
            }
            var facts = LipsyncVideoMetadata(durationSeconds: range.duration.seconds, frameRate: rate, width: Int(dimensions.width),
                                             height: Int(dimensions.height), byteCount: Int(info.st_size))
            facts.hasAudio = !audios.isEmpty
            try Task.checkCancellation()
            var after = stat()
            guard fstatat(directory, file.lastPathComponent, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_dev == after.st_dev, info.st_ino == after.st_ino, info.st_size == after.st_size,
                  info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw LipsyncError.unsafeFile }
            return facts
        } onCancel: { asset.cancelLoading() }
    }

    static func validate(_ facts: LipsyncVideoMetadata, durationSeconds: Double, fps: Double, width: Int, height: Int) throws {
        guard durationSeconds.isFinite, (3...300).contains(durationSeconds), fps.isFinite, (1...120).contains(fps),
              (16...4_096).contains(width), (16...4_096).contains(height), width.isMultiple(of: 2), height.isMultiple(of: 2),
              facts.durationSeconds.isFinite, abs(facts.durationSeconds - durationSeconds) <= 1 / fps,
              facts.frameRate.isFinite, abs(facts.frameRate - fps) <= 0.05,
              facts.width == width, facts.height == height, (12...LipsyncLimits.maximumVideoBytes).contains(facts.byteCount)
        else { throw LipsyncError.invalidMedia }
    }

    static func inspectContainer(descriptor: Int32, size: Int) throws {
        var count = 0, dataReferences = 0, movieCount = 0, mediaCount = 0, fileTypeCount = 0
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "dinf"]
        func bytes(_ offset: Int, _ length: Int) throws -> [UInt8] {
            guard offset >= 0, length >= 0, offset <= size - length else { throw LipsyncError.invalidMedia }
            var buffer = [UInt8](repeating: 0, count: length)
            guard pread(descriptor, &buffer, length, off_t(offset)) == length else { throw LipsyncError.invalidMedia }
            return buffer
        }
        func integer(_ value: ArraySlice<UInt8>) -> UInt64 { value.reduce(0) { $0 << 8 | UInt64($1) } }
        func scan(_ start: Int, _ end: Int, _ depth: Int) throws {
            guard depth <= 8 else { throw LipsyncError.invalidMedia }
            var offset = start
            while offset < end {
                try Task.checkCancellation()
                count += 1
                guard count <= 10_000, end - offset >= 8 else { throw LipsyncError.invalidMedia }
                let header = try bytes(offset, 8), kind = String(decoding: header[4..<8], as: UTF8.self)
                var length = integer(header[0..<4]), headerSize = 8
                if length == 1 { length = integer(try bytes(offset + 8, 8)[...]); headerSize = 16 }
                if length == 0 { length = UInt64(end - offset) }
                guard length >= UInt64(headerSize), length <= UInt64(end - offset) else { throw LipsyncError.invalidMedia }
                let next = offset + Int(length)
                if depth == 0 {
                    switch kind {
                    case "ftyp":
                        fileTypeCount += 1
                        guard offset == 0, length >= 16, length <= 4_096 else { throw LipsyncError.invalidMedia }
                    case "moov":
                        movieCount += 1
                        guard length <= 16 * 1_024 * 1_024 else { throw LipsyncError.responseTooLarge }
                    case "mdat": mediaCount += 1
                    case "free", "skip", "wide": break
                    default: throw LipsyncError.invalidMedia
                    }
                }
                if containers.contains(kind) { try scan(offset + headerSize, next, depth + 1) }
                if kind == "dref" {
                    let payload = try bytes(offset + headerSize, 8)
                    guard payload[0..<4].allSatisfy({ $0 == 0 }), integer(payload[4..<8]) == 1,
                          length == UInt64(headerSize + 20) else { throw LipsyncError.invalidMedia }
                    let entry = try bytes(offset + headerSize + 8, 12)
                    guard integer(entry[0..<4]) == 12, String(decoding: entry[4..<8], as: UTF8.self) == "url ",
                          Array(entry[8..<12]) == [0, 0, 0, 1] else { throw LipsyncError.invalidMedia }
                    dataReferences += 1
                }
                if ["cmov", "rmra", "rdrf", "alis", "urn "].contains(kind) { throw LipsyncError.invalidMedia }
                offset = next
            }
        }
        try scan(0, size, 0)
        guard fileTypeCount == 1, movieCount == 1, mediaCount >= 1, dataReferences >= 1, dataReferences <= 2 else {
            throw LipsyncError.invalidMedia
        }
    }
}
