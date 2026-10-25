import Foundation
import Dispatch
import VoxClipCore

struct CaptionBlurRegion: Sendable {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int
    var isEmpty: Bool { left >= right || top >= bottom }
}

private struct CaptionBoxBuffers: @unchecked Sendable {
    var input: UnsafePointer<UInt8>
    var output: UnsafeMutablePointer<UInt8>
    var values: UnsafePointer<UInt8>
}

final class CaptionBlurScratch: @unchecked Sendable {
    private var storage: UnsafeMutablePointer<UInt8>?
    private var capacity = 0
    private var sums: UnsafeMutablePointer<Int>?
    private var columns = 0
    private var rounding: [Int: [UInt8]] = [:]
    deinit { storage?.deallocate(); sums?.deallocate() }

    func apply(_ mask: UnsafeMutableBufferPointer<UInt8>, width: Int, height: Int, sigma: Double) throws -> CaptionBlurRegion {
        guard width > 0, height > 0, mask.count == width * height, sigma.isFinite, sigma >= 0 else { throw CaptionFailure.invalid("Blur surface") }
        if capacity < mask.count {
            storage?.deallocate(); storage = .allocate(capacity: mask.count); capacity = mask.count
        }
        if columns < width {
            sums?.deallocate(); sums = .allocate(capacity: width); columns = width
        }
        var region = CaptionBlurRegion(left: width, top: height, right: 0, bottom: 0)
        let base = mask.baseAddress!
        for row in 0..<height {
            let source = base + row * width
            for column in 0..<width where source[column] != 0 {
                region.left = min(region.left, column); region.right = max(region.right, column + 1)
                region.top = min(region.top, row); region.bottom = row + 1
            }
        }
        guard !region.isEmpty, sigma > 0 else { return region }
        var input = base, output = storage!
        let windows = sigma >= 2 ? CaptionBlur.boxWindows(sigma: sigma) : []
        let kernel = sigma < 2 ? CaptionBlur.gaussianKernel(sigma: sigma) : []
        let radius = kernel.count / 2
        for vertical in [false, true] {
            if sigma < 2 {
                let target = expanded(region, lower: -radius, upper: radius, vertical: vertical, width: width, height: height)
                for row in target.top..<target.bottom {
                    for column in target.left..<target.right {
                        var sum = 0.0
                        for offset in kernel.indices {
                            let sourceX = vertical ? column : column + offset - radius
                            let sourceY = vertical ? row + offset - radius : row
                            if sourceX >= region.left, sourceX < region.right, sourceY >= region.top, sourceY < region.bottom {
                                sum += kernel[offset] * Double(input[sourceY * width + sourceX])
                            }
                        }
                        output[row * width + column] = UInt8(clamping: CaptionMath.roundHalfUp(sum))
                    }
                }
                region = target; swap(&input, &output)
            } else {
                for (lower, upper) in windows {
                    let target = expanded(region, lower: lower, upper: upper, vertical: vertical, width: width, height: height)
                    boxPass(input, output, region: region, target: target, width: width, lower: lower, upper: upper, vertical: vertical)
                    region = target; swap(&input, &output)
                }
            }
        }
        return region
    }

    private func expanded(_ region: CaptionBlurRegion, lower: Int, upper: Int, vertical: Bool, width: Int, height: Int) -> CaptionBlurRegion {
        if vertical { return .init(left: region.left, top: max(0, region.top - upper), right: region.right, bottom: min(height, region.bottom - lower)) }
        return .init(left: max(0, region.left - upper), top: region.top, right: min(width, region.right - lower), bottom: region.bottom)
    }

    private func boxPass(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>, region: CaptionBlurRegion,
                         target: CaptionBlurRegion, width: Int, lower: Int, upper: Int, vertical: Bool) {
        let table = roundingTable(upper - lower + 1)
        table.withUnsafeBufferPointer { lookup in
            let buffers = CaptionBoxBuffers(input: input, output: output, values: lookup.baseAddress!)
            let count = (target.right - target.left) * (target.bottom - target.top) >= 65_536 ? 2 : 1
            DispatchQueue.concurrentPerform(iterations: count) { index in
                var stripe = target
                if vertical {
                    stripe.left = target.left + (target.right - target.left) * index / count
                    stripe.right = target.left + (target.right - target.left) * (index + 1) / count
                    self.boxColumns(buffers.input, buffers.output, region: region, target: stripe, width: width,
                        lower: lower, upper: upper, values: buffers.values)
                } else {
                    stripe.top = target.top + (target.bottom - target.top) * index / count
                    stripe.bottom = target.top + (target.bottom - target.top) * (index + 1) / count
                    self.boxRows(buffers.input, buffers.output, region: region, target: stripe, width: width,
                        lower: lower, upper: upper, values: buffers.values)
                }
            }
        }
    }

    private func boxRows(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>, region: CaptionBlurRegion, target: CaptionBlurRegion, width: Int, lower: Int, upper: Int, values: UnsafePointer<UInt8>) {
        for row in target.top..<target.bottom {
            let source = input + row * width, destination = output + row * width
            var sum = 0
            let start = max(region.left, target.left + lower), end = min(region.right, target.left + upper + 1)
            if start < end { for index in start..<end { sum += Int(source[index]) } }
            for column in target.left..<target.right {
                destination[column] = values[sum]
                let remove = column + lower, add = column + upper + 1
                if remove >= region.left, remove < region.right { sum -= Int(source[remove]) }
                if add >= region.left, add < region.right { sum += Int(source[add]) }
            }
        }
    }

    private func boxColumns(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>, region: CaptionBlurRegion, target: CaptionBlurRegion, width: Int, lower: Int, upper: Int, values: UnsafePointer<UInt8>) {
        let sums = sums!
        sums.advanced(by: target.left).initialize(repeating: 0, count: target.right - target.left)
        let start = max(region.top, target.top + lower), end = min(region.bottom, target.top + upper + 1)
        if start < end {
            for row in start..<end {
                let source = input + row * width
                for column in target.left..<target.right { sums[column] += Int(source[column]) }
            }
        }
        for row in target.top..<target.bottom {
            let destination = output + row * width
            let remove = row + lower, add = row + upper + 1
            for column in target.left..<target.right { destination[column] = values[sums[column]] }
            if remove >= region.top, remove < region.bottom {
                let source = input + remove * width
                for column in target.left..<target.right { sums[column] -= Int(source[column]) }
            }
            if add >= region.top, add < region.bottom {
                let source = input + add * width
                for column in target.left..<target.right { sums[column] += Int(source[column]) }
            }
        }
    }

    private func roundingTable(_ size: Int) -> [UInt8] {
        if let table = rounding[size] { return table }
        let table = (0...(255 * size)).map { UInt8((2 * $0 + size) / (2 * size)) }
        if rounding.count >= 8 { rounding.removeAll(keepingCapacity: true) }
        rounding[size] = table
        return table
    }
}
