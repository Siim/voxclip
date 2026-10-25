import Foundation
import CoreGraphics
import CoreText
import Dispatch

final class ProbeCanvas: @unchecked Sendable {
    let context: CGContext
    let bytes: UnsafeMutableRawPointer
    let byteCount: Int

    init(width: Int, height: Int, alphaOnly: Bool = true) {
        let channels = alphaOnly ? 1 : 4
        byteCount = width * height * channels
        bytes = .allocate(byteCount: byteCount, alignment: 64)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        context = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * channels,
            space: alphaOnly ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alphaOnly ? CGImageAlphaInfo.alphaOnly.rawValue
                : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.translateBy(x: 0, y: Double(height)); context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true); context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(false); context.setAllowsFontSmoothing(false)
        context.setLineJoin(.round); context.setLineCap(.round)
    }

    deinit { bytes.deallocate() }
}

struct ProbeWord: @unchecked Sendable {
    let text: String
    let path: CGPath
    let outline: CGPath
}

func draw(_ word: ProbeWord, into context: CGContext) {
    context.saveGState(); context.setAlpha(1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.addPath(word.path); context.fillPath()
    context.addPath(word.outline); context.fillPath()
    context.restoreGState()
}

guard CommandLine.arguments.count == 3, ["cold", "warm"].contains(CommandLine.arguments[2]) else {
    print("Usage: cg-first-fill-probe <shared-directory> cold|warm")
    exit(2)
}
let shared = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fontURL = shared.appendingPathComponent("fonts/righteous/Righteous-Regular.ttf")
guard let provider = CGDataProvider(url: fontURL as CFURL), let graphicsFont = CGFont(provider) else {
    print("Cannot load bundled font: \(fontURL.path)")
    exit(2)
}
let font = CTFontCreateWithGraphicsFont(graphicsFont, 122.88, nil, nil)
let width = 900, height = 260
var words: [ProbeWord] = []
var penOrigin = 20.0
var glyphCache: [CGGlyph: CGPath] = [:]
for text in ["SO", "HERE'S", "THE", "THING,"] {
    let characters = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    var advances = [CGSize](repeating: .zero, count: characters.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, characters.count)
    let path = CGMutablePath()
    var pen = penOrigin
    for (glyph, advance) in zip(glyphs, advances) {
        if glyphCache[glyph] == nil { glyphCache[glyph] = CTFontCreatePathForGlyph(font, glyph, nil) }
        if let outline = glyphCache[glyph] {
            path.addPath(outline, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: pen, ty: 160))
        }
        pen += advance.width
    }
    penOrigin = pen + 37
    words.append(.init(text: text, path: path,
        outline: path.copy(strokingWithWidth: 4.3008, lineCap: .round, lineJoin: .round, miterLimit: 10)))
}
if CommandLine.arguments[2] == "warm" {
    let bounds = words[0].path.boundingBoxOfPath
    let scale = 64 / max(bounds.width, bounds.height)
    var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
        tx: 16 - bounds.minX * scale, ty: 16 - bounds.minY * scale)
    let glyph = words[0].path.copy(using: &transform)!
    let outline = glyph.copy(strokingWithWidth: 4.3008, lineCap: .round, lineJoin: .round, miterLimit: 10)
    for alphaOnly in [true, false] {
        let canvas = ProbeCanvas(width: 128, height: 128, alphaOnly: alphaOnly)
        canvas.context.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.context.addPath(glyph); canvas.context.fillPath()
        canvas.context.addPath(outline); canvas.context.fillPath()
        canvas.context.setStrokeColor(CGColor(gray: 1, alpha: 1)); canvas.context.setLineWidth(4.3008)
        canvas.context.addPath(glyph); canvas.context.strokePath()
    }
}
let lanes = words.map { _ in ProbeCanvas(width: width, height: height) }
let sharedWords = words
DispatchQueue.concurrentPerform(iterations: lanes.count) { index in draw(sharedWords[index], into: lanes[index].context) }
var mismatches: [String] = []
for index in words.indices {
    let reference = ProbeCanvas(width: width, height: height)
    draw(words[index], into: reference.context)
    let actual = UnsafeRawBufferPointer(start: lanes[index].bytes, count: lanes[index].byteCount)
    let expected = UnsafeRawBufferPointer(start: reference.bytes, count: reference.byteCount)
    var differing = 0, actualSum = 0, expectedSum = 0
    for byteIndex in actual.indices {
        if actual[byteIndex] != expected[byteIndex] { differing += 1 }
        actualSum += Int(actual[byteIndex]); expectedSum += Int(expected[byteIndex])
    }
    if differing > 0 {
        mismatches.append("lane \(index) \(words[index].text): differing=\(differing) concurrentSum=\(actualSum) serialSum=\(expectedSum)")
    }
}
print(mismatches.isEmpty ? "OK" : "MISMATCH " + mismatches.joined(separator: "; "))
exit(mismatches.isEmpty ? 0 : 1)
