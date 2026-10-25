import Foundation
import VoxClipCore
@testable import VoxClipMedia

enum CaptionFailureArtifacts {
    static func write(_ actual: CaptionRaster, _ expected: CaptionRaster, context: String) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-caption-diff-\(UUID().uuidString)", isDirectory: true)
        print("Caption mismatch \(context); images: \(root.path)")
        for name in ["actual", "expected", "difference-x4"] {
            do {
                let raster: CaptionRaster
                if name == "actual" { raster = actual }
                else if name == "expected" { raster = expected }
                else { raster = try CaptionImageComparison.difference(actual, expected) }
                _ = try CaptionGoldenWriter.write(raster, to: root.appendingPathComponent("\(name).png"), sample: nil, style: nil, time: 0)
            } catch { print("Could not write \(root.path)/\(name).png: \(error)") }
        }
        return root
    }
}
