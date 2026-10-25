import Foundation
import VoxClipCore

public struct CaptionImageComparison: Sendable {
    public var matches: Bool
    public var mean: Double
    public var pixelsOver32: Int
    public var maximum: Int
    public var alphaSSIM: Double?
    public var pixels: Int

    public static func compare(_ first: CaptionRaster, _ second: CaptionRaster) throws -> CaptionImageComparison {
        guard first.width == second.width, first.height == second.height, first.width > 0, first.height > 0,
              first.bytesPerRow >= first.width * 4, second.bytesPerRow >= second.width * 4,
              first.rgba.count == first.bytesPerRow * first.height, second.rgba.count == second.bytesPerRow * second.height else {
            throw CaptionFailure.invalid("Image comparison surfaces")
        }
        let width = first.width, height = first.height
        if first.bytesPerRow == second.bytesPerRow, first.rgba == second.rgba {
            let pixels = first.rgba.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var count = 0
                for row in 0..<height {
                    for column in 0..<width where bytes[row * first.bytesPerRow + column * 4 + 3] > 0 { count += 1 }
                }
                return count
            }
            return .init(matches: true, mean: 0, pixelsOver32: 0, maximum: 0, alphaSSIM: nil, pixels: pixels)
        }
        var left = width, top = height, right = 0, bottom = 0
        var pixels = 0, over32 = 0, maximum = 0, total = 0, firstInk = false, secondInk = false
        var alphaFirst = [Double](repeating: 0, count: width * height), alphaSecond = alphaFirst
        first.rgba.withUnsafeBytes { firstRaw in
            second.rgba.withUnsafeBytes { secondRaw in
                let firstBytes = firstRaw.bindMemory(to: UInt8.self), secondBytes = secondRaw.bindMemory(to: UInt8.self)
                for row in 0..<height {
                    for column in 0..<width {
                        let firstOffset = row * first.bytesPerRow + column * 4
                        let secondOffset = row * second.bytesPerRow + column * 4
                        let alphaA = firstBytes[firstOffset + 3], alphaB = secondBytes[secondOffset + 3]
                        alphaFirst[row * width + column] = Double(alphaA)
                        alphaSecond[row * width + column] = Double(alphaB)
                        firstInk = firstInk || alphaA > 0; secondInk = secondInk || alphaB > 0
                        var difference = 0, sum = 0
                        for channel in 0..<4 {
                            let delta = abs(Int(firstBytes[firstOffset + channel]) - Int(secondBytes[secondOffset + channel]))
                            difference = max(difference, delta); sum += delta
                        }
                        maximum = max(maximum, difference)
                        if alphaA > 0 || alphaB > 0 {
                            pixels += 1; total += sum
                            if difference > 32 { over32 += 1 }
                            left = min(left, column); top = min(top, row)
                            right = max(right, column + 1); bottom = max(bottom, row + 1)
                        }
                    }
                }
            }
        }
        guard firstInk || secondInk else {
            return .init(matches: true, mean: 0, pixelsOver32: 0, maximum: 0, alphaSSIM: nil, pixels: 0)
        }
        let mean = Double(total) / Double(4 * pixels)
        let ssim: Double?
        if maximum <= 2 { ssim = nil }
        else {
            ssim = alphaSSIM(alphaFirst, alphaSecond, width: width, height: height,
                left: max(0, left - 8), top: max(0, top - 8), right: min(width, right + 8), bottom: min(height, bottom + 8))
        }
        return .init(matches: firstInk == secondInk && mean <= 4.5 && Double(over32) <= max(0.02 * Double(pixels), 96)
                && maximum <= 128 && (ssim == nil || ssim! >= 0.98),
            mean: mean, pixelsOver32: over32, maximum: maximum, alphaSSIM: ssim, pixels: pixels)
    }

    public static func difference(_ first: CaptionRaster, _ second: CaptionRaster) throws -> CaptionRaster {
        _ = try compare(first, second)
        var bytes = Data(count: first.width * first.height * 4)
        bytes.withUnsafeMutableBytes { outputRaw in
            first.rgba.withUnsafeBytes { firstRaw in
                second.rgba.withUnsafeBytes { secondRaw in
                    let output = outputRaw.bindMemory(to: UInt8.self)
                    let firstBytes = firstRaw.bindMemory(to: UInt8.self), secondBytes = secondRaw.bindMemory(to: UInt8.self)
                    for row in 0..<first.height {
                        for column in 0..<first.width {
                            let firstOffset = row * first.bytesPerRow + column * 4
                            let secondOffset = row * second.bytesPerRow + column * 4
                            let outputOffset = (row * first.width + column) * 4
                            let delta = (0..<4).map { abs(Int(firstBytes[firstOffset + $0]) - Int(secondBytes[secondOffset + $0])) }.max()!
                            for channel in 0..<3 { output[outputOffset + channel] = UInt8(clamping: delta * 4) }
                            output[outputOffset + 3] = 255
                        }
                    }
                }
            }
        }
        return .init(width: first.width, height: first.height, bytesPerRow: first.width * 4, rgba: bytes)
    }

    private static func alphaSSIM(_ first: [Double], _ second: [Double], width: Int, height: Int,
                                  left: Int, top: Int, right: Int, bottom: Int) -> Double {
        let boxWidth = max(11, right - left), boxHeight = max(11, bottom - top)
        var firstBox = [Double](repeating: 0, count: boxWidth * boxHeight), secondBox = firstBox
        for row in top..<bottom {
            for column in left..<right {
                firstBox[(row - top) * boxWidth + column - left] = first[row * width + column]
                secondBox[(row - top) * boxWidth + column - left] = second[row * width + column]
            }
        }
        let weights: [Double] = (-5...5).map { (offset: Int) in exp(-Double(offset * offset) / (2 * 1.5 * 1.5)) }
        let total = weights.reduce(0, +), kernel = weights.map { $0 / total }
        func filter(_ values: [Double]) -> [Double] {
            let targetWidth = boxWidth - 10, targetHeight = boxHeight - 10
            var horizontal = [Double](repeating: 0, count: boxHeight * targetWidth)
            for row in 0..<boxHeight {
                for column in 0..<targetWidth {
                    var sum = 0.0
                    for offset in 0..<11 { sum += kernel[offset] * values[row * boxWidth + column + offset] }
                    horizontal[row * targetWidth + column] = sum
                }
            }
            var result = [Double](repeating: 0, count: targetWidth * targetHeight)
            for row in 0..<targetHeight {
                for column in 0..<targetWidth {
                    var sum = 0.0
                    for offset in 0..<11 { sum += kernel[offset] * horizontal[(row + offset) * targetWidth + column] }
                    result[row * targetWidth + column] = sum
                }
            }
            return result
        }
        let meanFirst = filter(firstBox), meanSecond = filter(secondBox)
        let squareFirst = filter(firstBox.map { $0 * $0 }), squareSecond = filter(secondBox.map { $0 * $0 })
        let product = filter(zip(firstBox, secondBox).map { $0.0 * $0.1 })
        let constant1 = pow(Double(0.01 * 255.0), 2.0), constant2 = pow(Double(0.03 * 255.0), 2.0)
        var sum = 0.0
        for index in meanFirst.indices {
            let meanA = meanFirst[index], meanB = meanSecond[index]
            let varianceA = squareFirst[index] - meanA * meanA, varianceB = squareSecond[index] - meanB * meanB
            let covariance = product[index] - meanA * meanB
            sum += ((2 * meanA * meanB + constant1) * (2 * covariance + constant2))
                / ((meanA * meanA + meanB * meanB + constant1) * (varianceA + varianceB + constant2))
        }
        return sum / Double(meanFirst.count)
    }
}
