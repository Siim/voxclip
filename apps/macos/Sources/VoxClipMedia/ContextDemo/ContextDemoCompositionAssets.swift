import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import VoxClipCore

public enum ContextDemoCompositionError: Error, Sendable, Equatable {
    case invalidBinding, missingAsset, unsafePath, alteredAsset, invalidVideo, unsupportedVideo, invalidPlacement
}

public final class ContextDemoCompositionLease: Sendable {
    let directory: URL
    let urls: [String: URL]

    init(directory: URL, urls: [String: URL]) {
        self.directory = directory; self.urls = urls
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum ContextDemoCompositionAssets {
    static let maximumBytes: Int64 = 64 * 1_024 * 1_024

    static func prepare(_ assets: [ContextDemoAsset], projectId: String, root: URL,
                        scratchRoot: URL) async throws -> ContextDemoCompositionLease {
        let staging = Task.detached(priority: .userInitiated) {
            try snapshot(assets, projectId: projectId, root: root, scratchRoot: scratchRoot)
        }
        return try await withTaskCancellationHandler {
            let lease = try await staging.value
            try Task.checkCancellation()
            return lease
        } onCancel: { staging.cancel() }
    }

    static func snapshot(_ assets: [ContextDemoAsset], projectId: String, root: URL,
                         scratchRoot: URL) throws -> ContextDemoCompositionLease {
        try Task.checkCancellation()
        guard root.isFileURL, scratchRoot.isFileURL, VoiceLabAssetNaming.isSafeProjectID(projectId),
              Set(assets.map(\.id)).count == assets.count else { throw ContextDemoCompositionError.invalidBinding }
        let directory = scratchRoot.appendingPathComponent("voxclip-context-composition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            var urls: [String: URL] = [:]
            for asset in assets {
                let expected = try ContextDemoAsset.relativePath(projectId: projectId, assetId: asset.id)
                guard asset.relativePath == expected, asset.byteSize > 0, asset.byteSize <= maximumBytes,
                      asset.sha256.count == 64, asset.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                    throw ContextDemoCompositionError.invalidBinding
                }
                let destination = directory.appendingPathComponent("\(asset.id).mp4")
                try copy(asset, root: root, destination: destination)
                urls[asset.id] = destination
            }
            return ContextDemoCompositionLease(directory: directory, urls: urls)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func copy(_ asset: ContextDemoAsset, root: URL, destination: URL) throws {
        let rootFD = Darwin.open(root.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ContextDemoCompositionError.missingAsset }
        defer { Darwin.close(rootFD) }
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors.reversed() { Darwin.close(descriptor) } }
        var parent = rootFD
        let components = asset.relativePath.split(separator: "/").map(String.init)
        guard components.count == 3 else { throw ContextDemoCompositionError.unsafePath }
        for component in components.dropLast() {
            let descriptor = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw pathError() }
            descriptors.append(descriptor); parent = descriptor
        }
        let descriptor = Darwin.openat(parent, components[2], O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw pathError() }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_nlink == 1 else { throw ContextDemoCompositionError.unsafePath }
        guard before.st_size == asset.byteSize else { throw ContextDemoCompositionError.alteredAsset }
        let outputFD = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw ContextDemoCompositionError.unsafePath }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? input.close(); try? output.close() }
        var hash = SHA256(), count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            if count == 0 {
                guard data.count >= 16, String(data: data[4..<8], encoding: .ascii) == "ftyp",
                      let brand = String(data: data[8..<12], encoding: .ascii),
                      ["isom", "iso2", "mp41", "mp42", "avc1", "M4V "].contains(brand) else {
                    throw ContextDemoCompositionError.unsupportedVideo
                }
            }
            count += Int64(data.count)
            guard count <= asset.byteSize else { throw ContextDemoCompositionError.alteredAsset }
            hash.update(data: data)
            try output.write(contentsOf: data)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              count == asset.byteSize,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
            throw ContextDemoCompositionError.alteredAsset
        }
        try output.close()
    }

    private static func pathError() -> ContextDemoCompositionError {
        errno == ELOOP || errno == ENOTDIR ? .unsafePath : .missingAsset
    }

    static func video(_ record: ContextDemoAsset, url: URL) async throws -> (asset: AVURLAsset, track: AVAssetTrack) {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let video = tracks.first else { throw ContextDemoCompositionError.invalidVideo }
        let (size, transform, range, frameRate, descriptions) = try await video.load(
            .naturalSize, .preferredTransform, .timeRange, .nominalFrameRate, .formatDescriptions)
        let duration = try await asset.load(.duration)
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        let coefficients: [CGFloat] = [transform.a, transform.b, transform.c, transform.d]
        let isAxisAligned = coefficients.allSatisfy { $0 == -1 || $0 == 0 || $0 == 1 }
        let determinant: CGFloat = transform.a * transform.d - transform.b * transform.c
        let axisDot: CGFloat = transform.a * transform.c + transform.b * transform.d
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width == Double(record.pixelWidth),
              bounds.height == Double(record.pixelHeight), record.pixelWidth >= 2, record.pixelHeight >= 2,
              record.pixelWidth.isMultiple(of: 2), record.pixelHeight.isMultiple(of: 2),
              record.pixelWidth <= 1_920, record.pixelHeight <= 1_080,
              record.durationSeconds.isFinite, record.durationSeconds > 0, record.durationSeconds <= 30,
              duration.isNumeric, range.start == .zero, range.duration.isNumeric,
              abs(duration.seconds - record.durationSeconds) <= 1 / 600.0,
              abs(range.duration.seconds - record.durationSeconds) <= 1 / 600.0,
              frameRate.isFinite, frameRate > 0, frameRate <= 30,
              isAxisAligned, abs(determinant) == 1, axisDot == 0,
              transform.tx.isFinite, transform.ty.isFinite else {
            throw ContextDemoCompositionError.invalidVideo
        }
        guard !descriptions.isEmpty, descriptions.allSatisfy({
            CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
        }) else { throw ContextDemoCompositionError.unsupportedVideo }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { throw ContextDemoCompositionError.invalidVideo }
        let provider = reader.outputProvider(for: output)
        defer { reader.cancelReading() }
        guard reader.startReading(), let first = try await MediaSupport.nextSample(provider) else {
            throw ContextDemoCompositionError.invalidVideo
        }
        let valid = first.withUnsafeSampleBuffer { sample in
            CMSampleBufferIsValid(sample) && CMSampleBufferGetImageBuffer(sample) != nil
        }
        guard valid else { throw ContextDemoCompositionError.invalidVideo }
        try Task.checkCancellation()
        return (asset, video)
    }
}
