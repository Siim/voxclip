import AVFoundation
import CoreGraphics
import Foundation
import VoxClipCore

/// A lip-sync upload's picture in a few bytes: 8 frames across the needed length, each 16 × 16 luma. The H.264 upload is not
/// byte-identical when the same window is prepared again (its 48 kHz WAV is), so a paid attempt's sidecar is found again by
/// its audio hash and this fingerprint, within the encoder's noise; a different picture never matches.
enum LipsyncPictureFingerprint {
    static let frames = 8
    static let side = 16
    /// The largest mean difference, in 8-bit luma steps, of any one sampled frame for two uploads of the same picture.
    static let tolerance = 4.0

    static func make(_ url: URL, seconds: Double) async throws -> Data {
        guard seconds.isFinite, seconds > 0 else { throw LipsyncError.invalidInput }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 64)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var bytes = Data(capacity: frames * side * side)
        for index in 0..<frames {
            try Task.checkCancellation()
            let time = CMTime(seconds: (Double(index) + 0.5) / Double(frames) * seconds, preferredTimescale: 600_000)
            let image = try await generator.image(at: time).image
            var pixels = [UInt8](repeating: 0, count: side * side)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { throw LipsyncError.invalidMedia }
            bytes.append(contentsOf: pixels)
        }
        return bytes
    }

    static func matches(_ lhs: Data, _ rhs: Data) -> Bool {
        let count = frames * side * side
        guard lhs.count == count, rhs.count == count else { return false }
        let left = [UInt8](lhs), right = [UInt8](rhs)
        for frame in 0..<frames {
            var total = 0
            for offset in (frame * side * side)..<((frame + 1) * side * side) { total += abs(Int(left[offset]) - Int(right[offset])) }
            let mean: Double = Double(total) / Double(side * side)
            guard mean <= tolerance else { return false }
        }
        return true
    }
}
