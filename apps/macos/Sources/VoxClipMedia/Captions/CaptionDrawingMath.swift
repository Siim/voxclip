import Foundation
import CoreGraphics
import VoxClipCore

public enum CaptionBlur {
    public static func gaussianKernel(sigma: Double) -> [Double] {
        guard sigma > 0 else { return [1] }
        let radius = Int(ceil(3 * sigma))
        let values = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = values.reduce(0, +)
        return values.map { $0 / sum }
    }

    public static func boxWindows(sigma: Double) -> [(Int, Int)] {
        let size = Int(floor(sigma * 3 * sqrt(2 * Double.pi) / 4 + 0.5))
        if size % 2 != 0 { return Array(repeating: (-(size - 1) / 2, (size - 1) / 2), count: 3) }
        return [(-size / 2, size / 2 - 1), (-size / 2 + 1, size / 2), (-size / 2, size / 2)]
    }

    public static func row(_ input: [UInt8], sigma: Double) -> [UInt8] {
        guard sigma > 0, !input.isEmpty else { return input }
        if sigma < 2 {
            let kernel = gaussianKernel(sigma: sigma), radius = kernel.count / 2
            return input.indices.map { index in
                var sum = 0.0
                for offset in kernel.indices {
                    let source = index + offset - radius
                    if input.indices.contains(source) { sum += kernel[offset] * Double(input[source]) }
                }
                return UInt8(clamping: CaptionMath.roundHalfUp(sum))
            }
        }
        var output = input
        for (lower, upper) in boxWindows(sigma: sigma) { output = boxRow(output, lower: lower, upper: upper) }
        return output
    }

    static func boxRow(_ input: [UInt8], lower: Int, upper: Int) -> [UInt8] {
        let size = upper - lower + 1
        var sum = 0
        for source in lower...upper where input.indices.contains(source) { sum += Int(input[source]) }
        var output = [UInt8](repeating: 0, count: input.count)
        for index in input.indices {
            output[index] = UInt8(clamping: (2 * sum + size) / (2 * size))
            if input.indices.contains(index + lower) { sum -= Int(input[index + lower]) }
            if input.indices.contains(index + upper + 1) { sum += Int(input[index + upper + 1]) }
        }
        return output
    }

    public static func mask(_ input: [UInt8], width: Int, height: Int, sigma: Double) throws -> [UInt8] {
        guard width > 0, height > 0, input.count == width * height, sigma.isFinite, sigma >= 0 else { throw CaptionFailure.invalid("Blur surface") }
        if sigma == 0 { return input }
        var output = input
        let scratch = CaptionBlurScratch()
        try output.withUnsafeMutableBufferPointer { buffer in _ = try scratch.apply(buffer, width: width, height: height, sigma: sigma) }
        return output
    }
}

enum CaptionPaths {
    static func gradientEndpoints(_ rect: CGRect, angle: Double) -> (CGPoint, CGPoint) {
        let radians = angle * Double.pi / 180, cosine = cos(radians), sine = sin(radians)
        let half = rect.width / 2 * abs(cosine) + rect.height / 2 * abs(sine)
        return (.init(x: rect.midX - cosine * half, y: rect.midY - sine * half),
                .init(x: rect.midX + cosine * half, y: rect.midY + sine * half))
    }

    static func rounded(_ rect: CGRect, radius: Double) -> CGPath {
        let path = CGMutablePath()
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        let left = rect.minX, top = rect.minY, right = rect.maxX, bottom = rect.maxY
        if radius <= 0 {
            path.move(to: .init(x: left, y: top)); path.addLine(to: .init(x: right, y: top))
            path.addLine(to: .init(x: right, y: bottom)); path.addLine(to: .init(x: left, y: bottom)); path.closeSubpath()
            return path
        }
        let control = 0.5522847498 * radius
        path.move(to: .init(x: left + radius, y: top)); path.addLine(to: .init(x: right - radius, y: top))
        path.addCurve(to: .init(x: right, y: top + radius), control1: .init(x: right - radius + control, y: top), control2: .init(x: right, y: top + radius - control))
        path.addLine(to: .init(x: right, y: bottom - radius))
        path.addCurve(to: .init(x: right - radius, y: bottom), control1: .init(x: right, y: bottom - radius + control), control2: .init(x: right - radius + control, y: bottom))
        path.addLine(to: .init(x: left + radius, y: bottom))
        path.addCurve(to: .init(x: left, y: bottom - radius), control1: .init(x: left + radius - control, y: bottom), control2: .init(x: left, y: bottom - radius + control))
        path.addLine(to: .init(x: left, y: top + radius))
        path.addCurve(to: .init(x: left + radius, y: top), control1: .init(x: left, y: top + radius - control), control2: .init(x: left + radius - control, y: top))
        path.closeSubpath()
        return path
    }
}

extension CaptionRect {
    var cgRect: CGRect { .init(x: x, y: y, width: width, height: height) }
}

struct CaptionColor: Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    init(_ token: String, style: CaptionStyle) throws {
        var text = token
        if token.hasPrefix("$accent") {
            guard let accent = style.accent else { throw CaptionFailure.invalid("Missing accent") }
            let parts = token.split(separator: "/")
            text = accent + (parts.count > 1 ? String(parts[1]) : "FF")
        }
        let hex = String(text.dropFirst())
        guard text.hasPrefix("#"), [6, 8].contains(hex.count), let value = UInt32(hex.count == 6 ? hex + "FF" : hex, radix: 16) else {
            throw CaptionFailure.invalid("Caption colour")
        }
        red = Double((value >> 24) & 255) / 255; green = Double((value >> 16) & 255) / 255
        blue = Double((value >> 8) & 255) / 255; alpha = Double(value & 255) / 255
    }
    var cgColor: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])! }
}
