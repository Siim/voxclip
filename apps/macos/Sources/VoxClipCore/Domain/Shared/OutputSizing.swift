import Foundation

/// One output geometry and encoding policy for the Mac app and media pipeline.
public enum OutputSizing {
    public static func orientedSize(_ video: MediaVideo) -> PixelSize {
        let quarterTurn = video.rotationDegrees == 90 || video.rotationDegrees == 270
        return PixelSize(width: quarterTurn ? video.height : video.width,
                         height: quarterTurn ? video.width : video.height)
    }

    public static func outputSize(source: PixelSize, aspect: AspectRatio) throws -> PixelSize {
        guard source.width > 0, source.height > 0 else { throw VoxClipError.decodeFailed("No video track") }
        switch aspect {
        case .source:
            let scale = min(1, 1920 / Double(max(source.width, source.height)))
            return PixelSize(width: max(2, Int((Double(source.width) * scale / 2).rounded()) * 2),
                             height: max(2, Int((Double(source.height) * scale / 2).rounded()) * 2))
        case .landscape: return PixelSize(width: 1920, height: 1080)
        case .portrait: return PixelSize(width: 1080, height: 1920)
        case .square: return PixelSize(width: 1080, height: 1080)
        }
    }

    public static func outputFrameRate(nominal: Double) throws -> Double {
        guard nominal.isFinite, nominal > 0 else { throw VoxClipError.exportFailed("Invalid frame rate") }
        return [24.0, 25, 30, 50, 60].min { abs($0 - nominal) < abs($1 - nominal) }!
    }

    public static func videoBitrate(size: PixelSize, aspect: AspectRatio, quality: ExportQuality, fps: Double) -> Int {
        let base = aspect == .square ? 6_000_000.0 : aspect == .source
            ? max(2_000_000, 8_000_000 * Double(size.width * size.height) / (1920 * 1080)) : 8_000_000
        return Int(floor(base * (quality == .high ? 1.5 : 1) * (fps >= 50 ? 1.5 : 1) + 0.5))
    }

    /// Returns a crop in oriented source pixels. Even rounding of source output may
    /// change an edge by one pixel without changing the intended source aspect.
    public static func centerCrop(source: PixelSize, output: PixelSize) -> CaptionRect {
        let width = Double(source.width), height = Double(source.height)
        let outputWidth = Double(output.width), outputHeight = Double(output.height)
        guard width > 0, height > 0, outputWidth > 0, outputHeight > 0 else {
            return CaptionRect(x: 0, y: 0, width: max(0, width), height: max(0, height))
        }
        let scale = max(outputWidth / width, outputHeight / height)
        if abs(width * scale - outputWidth) <= 1, abs(height * scale - outputHeight) <= 1 {
            return CaptionRect(x: 0, y: 0, width: width, height: height)
        }
        let ratio = outputWidth / outputHeight
        let cropHeight = min(height, width / ratio)
        let cropWidth = cropHeight * ratio
        return CaptionRect(x: (width - cropWidth) / 2, y: (height - cropHeight) / 2,
                           width: cropWidth, height: cropHeight)
    }
}
