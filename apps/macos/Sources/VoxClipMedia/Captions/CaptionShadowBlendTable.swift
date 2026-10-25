import Foundation
import VoxClipCore

struct CaptionShadowBlendTable {
    let bytes: Data

    init(color: CaptionColor) {
        var bytes = Data(count: 256 * 256 * 4)
        bytes.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt8.self)
            for mask in 0...255 {
                let alpha = Double(mask) * color.alpha / 255, inverse = 1 - alpha
                for value in 0...255 {
                    let offset = (mask * 256 + value) * 4
                    let destination = Double(value) * inverse
                    output[offset] = UInt8(clamping: CaptionMath.roundHalfUp(color.blue * alpha * 255 + destination))
                    output[offset + 1] = UInt8(clamping: CaptionMath.roundHalfUp(color.green * alpha * 255 + destination))
                    output[offset + 2] = UInt8(clamping: CaptionMath.roundHalfUp(color.red * alpha * 255 + destination))
                    output[offset + 3] = UInt8(clamping: CaptionMath.roundHalfUp(alpha * 255 + destination))
                }
            }
        }
        self.bytes = bytes
    }
}
