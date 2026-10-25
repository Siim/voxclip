import Foundation
import CoreText
import VoxClipCore

struct OpenTypePairPlacement {
    let bytes: [UInt8]
    private var kernLookups: [Int] = []
    init(bytes: [UInt8]) {
        self.bytes = bytes
        guard bytes.count >= 10 else { return }
        let featureList = unsigned(6), lookupList = unsigned(8), featureCount = unsigned(featureList)
        guard featureCount <= bytes.count / 6 else { return }
        var indices = Set<Int>()
        for index in 0..<featureCount {
            let record = featureList + 2 + 6 * index
            if long(record) == 0x6B65726E {
                let feature = featureList + unsigned(record + 4), count = unsigned(feature + 2)
                guard count <= bytes.count / 2 else { continue }
                for lookup in 0..<count { indices.insert(unsigned(feature + 4 + 2 * lookup)) }
            }
        }
        kernLookups = indices.sorted().filter { $0 < unsigned(lookupList) }.map { lookupList + unsigned(lookupList + 2 + $0 * 2) }
    }
    func unsigned(_ offset: Int) -> Int {
        guard offset >= 0, offset + 1 < bytes.count else { return 0 }
        return Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
    }
    func signed(_ offset: Int) -> Int { Int(Int16(bitPattern: UInt16(unsigned(offset)))) }
    func long(_ offset: Int) -> Int { unsigned(offset) * 65536 + unsigned(offset + 2) }
    func coverage(_ offset: Int, glyph: Int) -> Int? {
        let count = unsigned(offset + 2)
        guard count <= bytes.count / 2 else { return nil }
        if unsigned(offset) == 1 {
            for index in 0..<count where unsigned(offset + 4 + 2 * index) == glyph { return index }
        } else if unsigned(offset) == 2 {
            for index in 0..<count {
                let record = offset + 4 + 6 * index, first = unsigned(record), last = unsigned(record + 2)
                if first <= glyph && glyph <= last { return unsigned(record + 4) + glyph - first }
            }
        }
        return nil
    }
    func glyphClass(_ offset: Int, glyph: Int) -> Int {
        if unsigned(offset) == 1 {
            let first = unsigned(offset + 2), count = unsigned(offset + 4)
            if glyph >= first && glyph < first + count { return unsigned(offset + 6 + 2 * (glyph - first)) }
        } else if unsigned(offset) == 2 {
            let count = unsigned(offset + 2)
            guard count <= bytes.count / 6 else { return 0 }
            for index in 0..<count {
                let record = offset + 4 + 6 * index
                if unsigned(record) <= glyph && glyph <= unsigned(record + 2) { return unsigned(record + 4) }
            }
        }
        return 0
    }
    func valueSize(_ format: Int) -> Int { format.nonzeroBitCount * 2 }
    func placement(_ offset: Int, format: Int, component: Int) -> Int {
        format & component != 0 ? signed(offset + (format & (component - 1)).nonzeroBitCount * 2) : 0
    }

    func pair(_ offset: Int, left: Int, right: Int, component: Int) -> (Int, Int)? {
        guard let covered = coverage(offset + unsigned(offset + 2), glyph: left) else { return nil }
        let firstFormat = unsigned(offset + 4), secondFormat = unsigned(offset + 6)
        let firstSize = valueSize(firstFormat), secondSize = valueSize(secondFormat)
        if unsigned(offset) == 1 {
            guard covered < unsigned(offset + 8) else { return nil }
            let pairSet = offset + unsigned(offset + 10 + 2 * covered)
            let count = unsigned(pairSet)
            guard count <= bytes.count / max(2, firstSize + secondSize + 2) else { return nil }
            for index in 0..<count {
                let record = pairSet + 2 + index * (2 + firstSize + secondSize)
                if unsigned(record) == right { return (placement(record + 2, format: firstFormat, component: component), placement(record + 2 + firstSize, format: secondFormat, component: component)) }
            }
        } else if unsigned(offset) == 2 {
            let firstClass = glyphClass(offset + unsigned(offset + 8), glyph: left)
            let secondClass = glyphClass(offset + unsigned(offset + 10), glyph: right)
            guard firstClass < unsigned(offset + 12), secondClass < unsigned(offset + 14) else { return nil }
            let record = offset + 16 + (firstClass * unsigned(offset + 14) + secondClass) * (firstSize + secondSize)
            return (placement(record, format: firstFormat, component: component), placement(record + firstSize, format: secondFormat, component: component))
        }
        return nil
    }

    func horizontalPlacements(_ glyphs: [ShapedGlyph]) -> [Int] {
        horizontalValues(glyphs, component: 1)
    }

    func horizontalAdvances(_ glyphs: [ShapedGlyph]) -> [Int] {
        horizontalValues(glyphs, component: 4)
    }

    private func horizontalValues(_ glyphs: [ShapedGlyph], component: Int) -> [Int] {
        var placements = Array(repeating: 0, count: glyphs.count)
        guard bytes.count >= 10, glyphs.count >= 2 else { return placements }
        for lookup in kernLookups {
            let type = unsigned(lookup), count = unsigned(lookup + 4)
            guard count <= bytes.count / 2 else { continue }
            for glyphIndex in 0..<(glyphs.count - 1) {
                for subtableIndex in 0..<count {
                    var subtable = lookup + unsigned(lookup + 6 + 2 * subtableIndex), subtableType = type
                    if type == 9 { subtableType = unsigned(subtable + 2); subtable += long(subtable + 4) }
                    guard subtableType == 2 else { continue }
                    if let value = pair(subtable, left: Int(glyphs[glyphIndex].id), right: Int(glyphs[glyphIndex + 1].id), component: component) {
                        placements[glyphIndex] += value.0; placements[glyphIndex + 1] += value.1; break
                    }
                }
            }
        }
        return placements
    }
}

struct OpenTypeLegacyKerning {
    let bytes: [UInt8]

    func horizontalPlacements(_ glyphs: [ShapedGlyph]) -> [Int] {
        horizontalValues(glyphs, placementsOnly: true)
    }

    func horizontalAdvances(_ glyphs: [ShapedGlyph]) -> [Int] {
        horizontalValues(glyphs, placementsOnly: false)
    }

    private func horizontalValues(_ glyphs: [ShapedGlyph], placementsOnly: Bool) -> [Int] {
        let reader = OpenTypePairPlacement(bytes: bytes)
        var placements = Array(repeating: 0, count: glyphs.count)
        guard bytes.count >= 4, reader.unsigned(0) == 0, glyphs.count > 1 else { return placements }
        var offset = 4
        for _ in 0..<reader.unsigned(2) {
            guard offset + 14 <= bytes.count else { break }
            let length = reader.unsigned(offset + 2), coverage = reader.unsigned(offset + 4)
            guard length >= 14, offset + length <= bytes.count else { break }
            defer { offset += length }
            guard coverage >> 8 == 0, coverage & 7 == 1 else { continue }
            let pairCount = reader.unsigned(offset + 6)
            guard pairCount <= (length - 14) / 6 else { continue }
            for index in 0..<(glyphs.count - 1) {
                let key = Int(glyphs[index].id) * 65536 + Int(glyphs[index + 1].id)
                var lower = 0, upper = pairCount
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if reader.long(offset + 14 + middle * 6) < key { lower = middle + 1 }
                    else { upper = middle }
                }
                if lower < pairCount, reader.long(offset + 14 + lower * 6) == key {
                    let kerning = reader.signed(offset + 18 + lower * 6)
                    let adjustment = kerning - (kerning >> 1)
                    if coverage & 8 != 0 {
                        if !placementsOnly { placements[index] = kerning >> 1 }
                        placements[index + 1] = adjustment
                    } else {
                        if !placementsOnly { placements[index] += kerning >> 1 }
                        placements[index + 1] += adjustment
                    }
                }
            }
        }
        return placements
    }
}
