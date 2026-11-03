import AVFoundation
import CoreGraphics
import CoreImage
import Darwin
import Foundation
import VoxClipCore

enum LipsyncResultConformer {
    static func conform(_ file: URL, duration: Double, fps: Double, width: Int, height: Int,
                        reference: LipsyncUploadFile?) async throws -> (URL, Bool) {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LipsyncError.unsafeFile }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 12, info.st_size <= LipsyncLimits.maximumVideoBytes else { throw LipsyncError.invalidMedia }
        try LipsyncResultValidation.inspectContainer(descriptor: descriptor, size: Int(info.st_size))
        let probe = try await AVMediaProbe().probe(file)
        guard let native = probe.video, let size = probe.orientedSize else { throw LipsyncError.invalidMedia }
        _ = try await LipsyncResultValidation.validate(file: file, durationSeconds: duration,
            fps: native.frameRate, width: size.width, height: size.height)
        let referenceURL = file.deletingLastPathComponent().appendingPathComponent("reference.mp4")
        var correction: (scale: Double, bias: Double)?
        var referenceMean: Double?
        if let reference {
            try reference.data.write(to: referenceURL, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: referenceURL.path)
            referenceMean = try await meanLuma(referenceURL)
            let resultMean = try await meanLuma(file)
            if let referenceMean, abs(referenceMean - resultMean) > 8 {
                let candidates = [(255.0 / 219.0, -16.0 * 255 / 219), (219.0 / 255.0, 16.0)]
                if let best = candidates.min(by: {
                    abs(referenceMean - (resultMean * $0.0 + $0.1)) < abs(referenceMean - (resultMean * $1.0 + $1.1))
                }), abs(referenceMean - (resultMean * best.0 + best.1)) < abs(referenceMean - resultMean) {
                    correction = (best.0, best.1 / 255)
                }
            }
        }
        guard native.width != width || native.height != height || abs(native.frameRate - fps) > 0.05 || correction != nil else {
            let warning: Bool
            if let referenceMean { warning = abs(referenceMean - (try await meanLuma(file))) > 8 } else { warning = false }
            return (file, warning)
        }
        let total = Int64((duration * 48_000).rounded())
        let plan = EditPlan(sampleRate: 48_000, totalSamples: total,
            kept: [MediaInterval(startSample: 0, endSample: total)])
        let output = OutputSpec(size: PixelSize(width: width, height: height), fps: fps,
            videoBitrate: Int((0.33 * Double(width) * Double(height) * fps).rounded()))
        let request = RenderRequest(sourceURL: file, plan: plan, output: output)
        let graph = try await CompositionBuilder().build(request, colorCorrection: correction)
        let conformed = file.deletingLastPathComponent().appendingPathComponent("conformed.mp4")
        try await LipsyncMezzanine.write(graph: graph, range: CMTimeRange(start: .zero,
            duration: CMTime(value: total, timescale: 48_000)), output: output, to: conformed)
        let warning: Bool
        if let referenceMean { warning = abs(referenceMean - (try await meanLuma(conformed))) > 8 } else { warning = false }
        return (conformed, warning)
    }

    static func meanLuma(_ url: URL) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 64, height: 64)
        let image = try await generator.image(at: .zero).image
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn, width * height > 0 else { throw LipsyncError.invalidMedia }
        var total = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])
        }
        return total / Double(width * height)
    }
}
