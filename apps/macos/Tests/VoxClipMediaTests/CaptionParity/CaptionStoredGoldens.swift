import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Testing
import VoxClipCore
@testable import VoxClipMedia

struct CaptionStoredGoldens {
    let root: URL

    private static func canonicalDirectory(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { break }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }
        return suffix.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
    }

    static func generationOutput(_ path: String?, shared: SharedResources) throws -> URL? {
        guard let path else { return nil }
        let output = canonicalDirectory(URL(fileURLWithPath: path, isDirectory: true))
        let committed = try FixtureLoader.sharedRoot(environment: [:]).appendingPathComponent("fixtures/captions/golden", isDirectory: true)
        for protected in [shared.root, committed] {
            let root = canonicalDirectory(protected)
            guard !output.pathComponents.starts(with: root.pathComponents) else {
                throw CaptionFailure.invalid("VOXCLIP_GOLDEN_OUT \(output.path) must be outside protected resources at \(root.path)")
            }
        }
        return output
    }

    init(root: URL, cases: [String]) throws {
        self.root = root
        let expected = Set((cases + ["tiles"]).flatMap { [$0, "\($0).json"] })
        let actual = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let complete = actual == expected
        try #require(complete, "Stored golden root file list: missing \(expected.subtracting(actual)), extra \(actual.subtracting(expected))")
    }

    func images(_ name: String, expected: [CaptionGoldenImage]) throws -> [CaptionGoldenImage] {
        struct Index: Decodable { var images: [CaptionGoldenImage] }
        let images = try JSONDecoder().decode(Index.self, from: Data(contentsOf: root.appendingPathComponent("\(name).json"))).images
        try #require(images.map(\.file) == expected.map(\.file), "\(name): golden file/sample list")
        let expectedFiles = Set(expected.map(\.file))
        try #require(expectedFiles.count == images.count, "\(name): duplicate golden entries")
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(name).path))
        try #require(files == expectedFiles, "\(name): missing \(expectedFiles.subtracting(files)), extra \(files.subtracting(expectedFiles))")
        for (image, sample) in zip(images, expected) {
            try #require(image.sample == sample.sample && image.style == sample.style && abs(image.t - sample.t) <= 1e-9,
                         "\(name)/\(image.file): sample, style or time differs from fixture golden flags")
            try #require(image.frame == sample.frame, "\(name)/\(image.file): frame differs from fixture")
        }
        return images
    }

    func raster(_ image: CaptionGoldenImage, folder: String) throws -> CaptionRaster {
        let url = root.appendingPathComponent(folder).appendingPathComponent(image.file)
        let png = try Data(contentsOf: url)
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        try #require(digest == image.sha256, "\(url.path): stored PNG sha256 differs from index")
        let crop = image.crop, frame = image.frame
        try #require(frame.width > 0 && frame.height > 0 && crop.x >= 0 && crop.y >= 0 && crop.w > 0 && crop.h > 0
                     && crop.w <= frame.width && crop.h <= frame.height && crop.x <= frame.width - crop.w && crop.y <= frame.height - crop.h,
                     "\(url.path): invalid indexed crop")
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil), "\(url.path): PNG source")
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(url.path): PNG decode")
        try #require(decoded.width == crop.w && decoded.height == crop.h && decoded.bitsPerComponent == 8
                     && decoded.bitsPerPixel == 32 && decoded.alphaInfo == .last,
                     "\(url.path): expected straight-alpha 8-bit RGBA crop")
        let storage = try #require(decoded.dataProvider?.data, "\(url.path): decoded pixels") as Data
        try #require(storage.count >= decoded.bytesPerRow * crop.h, "\(url.path): incomplete decoded pixels")
        var rgba = Data(count: frame.width * frame.height * 4)
        rgba.withUnsafeMutableBytes { destinationRaw in
            storage.withUnsafeBytes { sourceRaw in
                let destination = destinationRaw.bindMemory(to: UInt8.self), pixels = sourceRaw.bindMemory(to: UInt8.self)
                for row in 0..<crop.h {
                    for column in 0..<crop.w {
                        let input = row * decoded.bytesPerRow + column * 4
                        let output = ((row + crop.y) * frame.width + column + crop.x) * 4
                        let alpha = Int(pixels[input + 3])
                        for channel in 0..<3 { destination[output + channel] = UInt8((2 * Int(pixels[input + channel]) * alpha + 255) / 510) }
                        destination[output + 3] = UInt8(alpha)
                    }
                }
            }
        }
        return .init(width: frame.width, height: frame.height, bytesPerRow: frame.width * 4, rgba: rgba)
    }

    func compare(_ actual: CaptionRaster, image: CaptionGoldenImage, folder: String) throws {
        let expected = try raster(image, folder: folder)
        let comparison = try CaptionImageComparison.compare(actual, expected)
        if !comparison.matches {
            let output = CaptionFailureArtifacts.write(actual, expected, context: "Stored golden \(folder)/\(image.file)")
            Issue.record("Stored golden mismatch: \(folder)/\(image.file), mean=\(comparison.mean), max=\(comparison.maximum), images: \(output.path)")
        }
    }
}
