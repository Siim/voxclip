import AVFoundation
import CoreMedia
import Darwin
import Foundation
import VoxClipCore

public struct LipsyncVideoMetadata: Sendable, Equatable {
    public let durationSeconds: Double
    public let frameRate: Double
    public let width: Int
    public let height: Int
    public let byteCount: Int
}

public enum LipsyncResultValidation {
    public static func validate(file: URL, durationSeconds: Double, fps: Double, width: Int, height: Int) async throws -> LipsyncVideoMetadata {
        try Task.checkCancellation()
        let directory = try LipsyncLocalPath.openDirectory(file.deletingLastPathComponent())
        defer { Darwin.close(directory) }
        let descriptor = openat(directory, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw LipsyncError.unsafeFile }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              (12...Int64(LipsyncLimits.maximumVideoBytes)).contains(info.st_size) else { throw LipsyncError.invalidMedia }
        try inspectContainer(descriptor: descriptor, size: Int(info.st_size))
        try Task.checkCancellation()
        let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return try await withTaskCancellationHandler {
            guard try await asset.load(.isPlayable), !(try await asset.load(.hasProtectedContent)) else { throw LipsyncError.invalidMedia }
            let tracks = try await asset.load(.tracks)
            let videos = tracks.filter { $0.mediaType == .video }
            guard videos.count == 1, tracks.allSatisfy({ [.video, .audio].contains($0.mediaType) }),
                  tracks.filter({ $0.mediaType == .audio }).count <= 1 else { throw LipsyncError.invalidMedia }
            let track = videos[0]
            let formats = try await track.load(.formatDescriptions)
            guard formats.count == 1, CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264 else {
                throw LipsyncError.invalidMedia
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(formats[0])
            let transform = try await track.load(.preferredTransform)
            guard transform == .identity else { throw LipsyncError.invalidMedia }
            let duration = try await asset.load(.duration).seconds
            let rate = Double(try await track.load(.nominalFrameRate))
            let range = try await track.load(.timeRange)
            guard range.start.seconds.isFinite, abs(range.start.seconds) <= 1 / fps,
                  range.duration.seconds.isFinite, abs(range.duration.seconds - duration) <= 1 / fps else { throw LipsyncError.invalidMedia }
            let facts = LipsyncVideoMetadata(durationSeconds: duration, frameRate: rate, width: Int(dimensions.width),
                                             height: Int(dimensions.height), byteCount: Int(info.st_size))
            try validate(facts, durationSeconds: durationSeconds, fps: fps, width: width, height: height)
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
