import Foundation
import VoxClipCore

public enum CaptionEmojiResampler {
    public static func resize(_ source: [UInt8], size: Int) throws -> [UInt8] {
        guard source.count == 128 * 128 * 4, (1...8192).contains(size) else { throw CaptionFailure.invalid("Emoji resample size") }
        if size == 128 { return source }
        var output = [UInt8](repeating: 0, count: size * size * 4)
        let ratio = 128.0 / Double(size)
        for row in 0..<size {
            for column in 0..<size {
                let destination = (row * size + column) * 4
                if size <= 128 {
                    let left = Double(column) * ratio, right = Double(column + 1) * ratio
                    let top = Double(row) * ratio, bottom = Double(row + 1) * ratio
                    var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
                    for sourceY in Int(floor(top))..<Int(ceil(bottom)) {
                        let weightY = max(0, min(bottom, Double(sourceY + 1)) - max(top, Double(sourceY)))
                        for sourceX in Int(floor(left))..<Int(ceil(right)) {
                            let weightX = max(0, min(right, Double(sourceX + 1)) - max(left, Double(sourceX)))
                            let weight = weightX * weightY
                            let sourceIndex = (sourceY * 128 + sourceX) * 4
                            red += Double(source[sourceIndex]) * weight; green += Double(source[sourceIndex + 1]) * weight
                            blue += Double(source[sourceIndex + 2]) * weight; alpha += Double(source[sourceIndex + 3]) * weight
                        }
                    }
                    let area = ratio * ratio
                    output[destination] = UInt8(clamping: CaptionMath.roundHalfUp(red / area))
                    output[destination + 1] = UInt8(clamping: CaptionMath.roundHalfUp(green / area))
                    output[destination + 2] = UInt8(clamping: CaptionMath.roundHalfUp(blue / area))
                    output[destination + 3] = UInt8(clamping: CaptionMath.roundHalfUp(alpha / area))
                } else {
                    let sourceX = CaptionMath.clamp((Double(column) + 0.5) * ratio - 0.5, 0, 127)
                    let sourceY = CaptionMath.clamp((Double(row) + 0.5) * ratio - 0.5, 0, 127)
                    let left = Int(floor(sourceX)), top = Int(floor(sourceY)), right = min(127, left + 1), bottom = min(127, top + 1)
                    let fractionX = sourceX - Double(left), fractionY = sourceY - Double(top)
                    for channel in 0..<4 {
                        let upper = Double(source[(top * 128 + left) * 4 + channel]) * (1 - fractionX) + Double(source[(top * 128 + right) * 4 + channel]) * fractionX
                        let lower = Double(source[(bottom * 128 + left) * 4 + channel]) * (1 - fractionX) + Double(source[(bottom * 128 + right) * 4 + channel]) * fractionX
                        output[destination + channel] = UInt8(clamping: CaptionMath.roundHalfUp(upper * (1 - fractionY) + lower * fractionY))
                    }
                }
            }
        }
        return output
    }
}
