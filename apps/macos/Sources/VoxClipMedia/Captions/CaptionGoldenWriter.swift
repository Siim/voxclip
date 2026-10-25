import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import VoxClipCore

public struct CaptionGoldenImage: Codable, Sendable {
    public struct Crop: Codable, Sendable {
        public var x: Int
        public var y: Int
        public var w: Int
        public var h: Int
    }
    public var file: String
    public var sample: Int?
    public var style: String?
    public var t: Double
    public var frame: CaptionLayoutInput.Frame
    public var crop: Crop
    public var sha256: String

    private enum CodingKeys: String, CodingKey { case file, sample, style, t, frame, crop, sha256 }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(file, forKey: .file)
        try values.encode(sample, forKey: .sample)
        try values.encode(style, forKey: .style)
        try values.encode(t, forKey: .t)
        try values.encode(frame, forKey: .frame)
        try values.encode(crop, forKey: .crop)
        try values.encode(sha256, forKey: .sha256)
    }
}

public enum CaptionGoldenWriter {
    public static func write(_ raster: CaptionRaster, to url: URL, sample: Int?, style: String?, time: Double) throws -> CaptionGoldenImage {
        let encoded = try encode(raster, file: url.lastPathComponent, sample: sample, style: style, time: time)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.png.write(to: url, options: .atomic)
        return encoded.image
    }

    static func encode(_ raster: CaptionRaster, file: String, sample: Int?, style: String?, time: Double) throws -> (image: CaptionGoldenImage, png: Data) {
        guard raster.width > 0, raster.height > 0, raster.bytesPerRow >= raster.width * 4, raster.rgba.count == raster.bytesPerRow * raster.height else { throw CaptionFailure.invalid("Golden surface") }
        var left = raster.width, top = raster.height, right = -1, bottom = -1
        raster.rgba.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            for row in 0..<raster.height {
                for column in 0..<raster.width where source[row * raster.bytesPerRow + column * 4 + 3] > 0 {
                    left = min(left, column); right = max(right, column); top = min(top, row); bottom = max(bottom, row)
                }
            }
        }
        if right < left { left = 0; top = 0; right = 0; bottom = 0 }
        else { left = max(0, left - 8); top = max(0, top - 8); right = min(raster.width - 1, right + 8); bottom = min(raster.height - 1, bottom + 8) }
        let width = right - left + 1, height = bottom - top + 1
        var straight = Data(count: width * height * 4)
        straight.withUnsafeMutableBytes { destinationRaw in
            let destination = destinationRaw.bindMemory(to: UInt8.self)
            raster.rgba.withUnsafeBytes { sourceRaw in
                let source = sourceRaw.bindMemory(to: UInt8.self)
                for row in 0..<height {
                    for column in 0..<width {
                        let input = (row + top) * raster.bytesPerRow + (column + left) * 4, output = (row * width + column) * 4
                        let alpha = Int(source[input + 3])
                        for channel in 0..<3 { destination[output + channel] = alpha == 0 ? 0 : UInt8(clamping: CaptionMath.roundHalfUp(Double(source[input + channel]) * 255 / Double(alpha))) }
                        destination[output + 3] = UInt8(alpha)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: straight as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CaptionFailure.invalid("Golden image") }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw CaptionFailure.invalid("Golden PNG destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptionFailure.invalid("Golden PNG write") }
        let data = png as Data
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let metadata = CaptionGoldenImage(file: file, sample: sample, style: style, t: time, frame: .init(width: raster.width, height: raster.height),
                     crop: .init(x: left, y: top, w: width, h: height), sha256: digest)
        return (metadata, data)
    }

    public static func writeIndex(_ images: [CaptionGoldenImage], to url: URL) throws {
        struct Index: Encodable { var images: [CaptionGoldenImage] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Index(images: images)).write(to: url, options: .atomic)
    }
}
