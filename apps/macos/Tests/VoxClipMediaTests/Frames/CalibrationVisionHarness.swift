import CoreGraphics
import CryptoKit
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// The Windows faces' calibration (ADR-R48 Windows, W7; tools/frames/calibrate): the Mac's production `AppleFrameVision` on
/// the calibration's decoded frames. A harness, not a check: it runs only when `VOXCLIP_CALIBRATION_FRAMES` names a job file
/// written by `tools/frames/calibrate/calibrate.py mac`, and is skipped everywhere else (CI included).
///
/// The job is JSON: `{"out": path, "frames": [{"sha256", "path", "width", "height"}]}`, each frame raw RGB24 rows (no
/// padding), as the tool decoded and hashed them. Every frame's bytes are hashed again here and a frame that differs is
/// refused. The output is one JSON line per frame: the hash, the face count and the largest face's fields, exactly what
/// `AppleFrameVision.observe` returned (no pixels).
@Suite struct CalibrationVisionHarness {
    static let job = ProcessInfo.processInfo.environment["VOXCLIP_CALIBRATION_FRAMES"]

    struct Job: Decodable {
        struct Frame: Decodable { let sha256: String; let path: String; let width: Int; let height: Int }
        let out: String
        let frames: [Frame]
    }

    struct Line: Encodable {
        let sha256: String
        let faceCount: Int
        let face: FrameFace?
    }

    @Test(.enabled(if: job != nil)) func observeTheCalibrationFrames() throws {
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(Self.job))))
        let vision = AppleFrameVision()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines = Data()
        for frame in job.frames {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: frame.path))
            #expect(bytes.count == frame.width * frame.height * 3)
            #expect(Self.sha256(bytes) == frame.sha256, "\(frame.path) is not the frame the manifest pins")
            guard bytes.count == frame.width * frame.height * 3, Self.sha256(bytes) == frame.sha256 else { continue }
            let image = try #require(Self.image(bytes, width: frame.width, height: frame.height))
            let observation = try vision.observe(image, time: 0)
            lines.append(try encoder.encode(Line(sha256: frame.sha256, faceCount: observation.faceCount, face: observation.face)))
            lines.append(0x0A)
        }
        try lines.write(to: URL(fileURLWithPath: job.out), options: .atomic)
    }

    /// RGB24 rows as an sRGB image, as a decoded video frame reaches Vision.
    static func image(_ bytes: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
