import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VoxClipCore

public enum HarnessFrameDecoder {
    public static func decode(source: URL, times: [Double]) async throws -> [HarnessResult.Frame] {
        let asset = AVURLAsset(url: source, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var images: [HarnessResult.Frame] = []
        for time in times {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
            let bytes = NSMutableData()
            guard let jpeg = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw HarnessError.invalid("Can't encode a preview frame.")
            }
            CGImageDestinationAddImage(jpeg, frame.image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
            guard CGImageDestinationFinalize(jpeg) else { throw HarnessError.invalid("Can't encode a preview frame.") }
            images.append(.init(requested: time, actual: frame.actualTime.seconds, jpeg: bytes.base64EncodedString()))
        }
        return images
    }
}
