import AVFoundation
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VoxClipCore

public enum IllustrativeCutawayAssetError: Error, Equatable {
    case invalidImage, invalidVideo
}

public struct IllustrativeCutawayDraft: Sendable {
    public let asset: ContextDemoAsset
    public let url: URL
    public let image: CGImage
}

public struct IllustrativeCutawayAssets: Sendable {
    public static let maximumSeconds: Double = 8
    public static let target = ContextDemoTarget(kind: .desktopApp, displayName: "Generated illustration",
                                                  locator: "com.voxclip.generated-cutaway")
    private static let byteLimit = 16 * 1024 * 1024
    private let store: ContextDemoAssetStore

    public init(root: URL) {
        store = ContextDemoAssetStore(rootURL: root.standardizedFileURL.resolvingSymlinksInPath())
    }

    public static func isGenerated(_ asset: ContextDemoAsset) -> Bool {
        asset.target.kind == target.kind && asset.target.locator == target.locator
    }

    public static func readImage(at url: URL) throws -> Data {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw IllustrativeCutawayAssetError.invalidImage
        }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw IllustrativeCutawayAssetError.invalidImage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= byteLimit,
              let data = try handle.read(upToCount: Int(before.st_size) + 1), data.count == before.st_size,
              fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw IllustrativeCutawayAssetError.invalidImage
        }
        return data
    }

    @MainActor public func prepare(_ bytes: Data, projectID: String, reviewID: UUID,
                                   duration: Double) async throws -> IllustrativeCutawayDraft {
        try Task.checkCancellation()
        guard duration.isFinite, duration > 0, duration <= Self.maximumSeconds else {
            throw IllustrativeCutawayAssetError.invalidVideo
        }
        let image = try Self.decode(bytes)
        let file = try store.create(projectId: projectID)
        var published = false
        do {
            try await Self.write(image, duration: duration, to: file.partialURL)
            let metadata = try await ContextDemoRecordingInspector().inspect(file.partialURL)
            guard metadata.duration >= duration else { throw IllustrativeCutawayAssetError.invalidVideo }
            try Task.checkCancellation()
            let digest = try store.publish(file)
            published = true
            try store.complete(file)
            let asset = ContextDemoAsset(id: file.assetID, requestId: reviewID.uuidString, target: Self.target,
                relativePath: file.relativePath, sha256: digest.sha256, durationSeconds: metadata.duration,
                pixelWidth: metadata.width, pixelHeight: metadata.height, byteSize: Int64(digest.byteCount), createdAt: Date())
            return IllustrativeCutawayDraft(asset: asset, url: file.finalURL, image: image)
        } catch {
            try? store.remove(file, published: published)
            throw error
        }
    }

    public func verifiedURL(for asset: ContextDemoAsset) throws -> URL {
        guard Self.isGenerated(asset), let count = Int(exactly: asset.byteSize) else {
            throw IllustrativeCutawayAssetError.invalidVideo
        }
        return try store.verify(relativePath: asset.relativePath, expected: .init(byteCount: count, sha256: asset.sha256),
                                checkingCancellation: false)
    }

    public func discard(_ asset: ContextDemoAsset) throws {
        _ = try verifiedURL(for: asset)
        try store.remove(relativePath: asset.relativePath)
    }

    private static func decode(_ bytes: Data) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !bytes.isEmpty, bytes.count <= byteLimit, let source = CGImageSourceCreateWithData(bytes as CFData, options),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (64...2048).contains(width), (64...2048).contains(height),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw IllustrativeCutawayAssetError.invalidImage
        }
        return image
    }

    private static func write(_ image: CGImage, duration: Double, to url: URL) async throws {
        let width = image.width + image.width % 2, height = image.height + image.height % 2
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw IllustrativeCutawayAssetError.invalidVideo }
        try draw(image, in: buffer)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey: MediaSupport.colorProperties])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw IllustrativeCutawayAssetError.invalidVideo }
        writer.add(input)
        guard writer.startWriting() else { throw IllustrativeCutawayAssetError.invalidVideo }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let frameCount = Int64((duration * 10).rounded(.up)) + 1
        let deadline = ContinuousClock.now + .seconds(15)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw IllustrativeCutawayAssetError.invalidVideo
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: 10)) else {
                throw IllustrativeCutawayAssetError.invalidVideo
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: frameCount, timescale: 10))
        await writer.finishWriting()
        guard writer.status == .completed else { throw IllustrativeCutawayAssetError.invalidVideo }
    }

    private static func draw(_ image: CGImage, in buffer: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw IllustrativeCutawayAssetError.invalidVideo
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let pixels = CVPixelBufferGetBaseAddress(buffer), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw IllustrativeCutawayAssetError.invalidVideo
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
    }
}
