import Foundation
import Testing
@testable import VoxClipCore

@Test("Every caption box text colour vector")
func captionBoxTextColorVectors() throws {
    struct Fixture: Decodable {
        struct Case: Decodable {
            var id: String; var style: String; var overrides: [String: JSONValue]; var state: String
            var boxState: String; var emphasised: Bool; var palette: String?; var box: [UInt8]?
            var paint: CaptionPaint; var contrasts: [Double]; var expected: CaptionPaint; var source: String; var replaced: Bool
        }
        var fixture: String; var cases: [Case]
    }
    let shared = try CaptionCoreFixtures.shared()
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: shared.appendingPathComponent("fixtures/captions/box-text-colors.json")))
    #expect(fixture.fixture == "voxclip-caption-box-text-colors/2")
    #expect(fixture.cases.count == 74)
    func rgb(_ channels: [UInt8]) -> (r: UInt8, g: UInt8, b: UInt8) { (channels[0], channels[1], channels[2]) }
    func rgba(_ token: String, style: CaptionStyle) throws -> [UInt8] {
        var value = token
        if token.hasPrefix("$accent") {
            let accent = try #require(style.accent)
            let alpha = token.split(separator: "/").dropFirst().first.map(String.init) ?? "FF"
            value = accent + alpha
        }
        let hex = String(value.dropFirst())
        let channels = try #require(UInt32(hex.count == 6 ? hex + "FF" : hex, radix: 16))
        let redShift: UInt32 = channels >> 24
        let greenShift: UInt32 = channels >> 16
        let blueShift: UInt32 = channels >> 8
        let red: UInt32 = redShift & 255
        let green: UInt32 = greenShift & 255
        let blue: UInt32 = blueShift & 255
        let alpha: UInt32 = channels & 255
        return [UInt8(red), UInt8(green), UInt8(blue), UInt8(alpha)]
    }
    func normalized(_ paint: CaptionPaint, style: CaptionStyle) throws -> CaptionPaint {
        func token(_ value: String) throws -> String {
            let channels = try rgba(value, style: style)
            return String(format: "#%02X%02X%02X%02X", channels[0], channels[1], channels[2], channels[3])
        }
        switch paint {
        case .solid(let color): return .solid(color: try token(color))
        case .linear(let angle, let space, let stops):
            let resolved: [CaptionPaintStop] = try stops.map { stop in .init(offset: stop.offset, color: try token(stop.color)) }
            return .linear(angleDeg: angle, space: space, stops: resolved)
        }
    }
    func colors(_ paint: CaptionPaint, style: CaptionStyle) throws -> [[UInt8]] {
        switch paint {
        case .solid(let color): return [try rgba(color, style: style)]
        case .linear(_, _, let stops): return try stops.map { try rgba($0.color, style: style) }
        }
    }
    for item in fixture.cases {
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: shared.appendingPathComponent("caption-styles/styles/\(item.style).json")))
        let input = CaptionLayoutInput(style: style.id, frame: .init(width: 1080, height: 1920), language: "en", duration: 0,
                                       captions: .init(overrides: item.overrides), words: [])
        let resolved = try CaptionStyleResolver.resolve(style, input: input)
        let sidebar = try style.resolved(overrides: item.overrides, frame: .init(width: 1080, height: 1920))
        #expect(resolved == sidebar, "\(item.id)")
        let actual = CaptionTimeline.fill(style: resolved, state: item.state, emphasised: item.emphasised, palette: item.palette, boxState: item.boxState)
        #expect(try normalized(actual.0, style: resolved) == item.expected, "\(item.id)")
        #expect(actual.1 == item.source, "\(item.id)")
        #expect(actual.2 == item.replaced, "\(item.id)")
        let box = CaptionTimeline.wordState(resolved, item.boxState)?.box?.color ?? resolved.box?.color
        #expect(try box.map { try rgba($0, style: resolved) } == item.box, "\(item.id)")
        if let background = item.box {
            let original = try colors(item.paint, style: resolved)
            #expect(original.count == item.contrasts.count, "\(item.id)")
            for (foreground, expected) in zip(original, item.contrasts) {
                #expect(abs(CaptionContrast.ratio(rgb(foreground), rgb(background)) - expected) < 1e-12, "\(item.id)")
            }
            for foreground in try colors(actual.0, style: resolved) {
                #expect(CaptionContrast.ratio(rgb(foreground), rgb(background)) >= 4.5, "\(item.id)")
            }
        } else {
            #expect(item.contrasts.isEmpty && !actual.2, "\(item.id)")
            #expect(item.paint == item.expected, "\(item.id)")
        }
        if item.style == "box-highlight" { #expect(resolved.words?.active?.hideStroke == true) }
    }
}

@Test("Non-boxed caption colours stay unchanged")
func captionNonBoxTextColorsUnchanged() throws {
    let shared = try CaptionCoreFixtures.shared()
    let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: shared.appendingPathComponent("caption-styles/styles/active-pop.json")))
    for state in ["past", "active", "future"] {
        let actual = CaptionTimeline.fill(style: style, state: state, emphasised: false, palette: nil)
        #expect(actual.0 == (CaptionTimeline.wordState(style, state)?.fill ?? style.fill))
        #expect(!actual.2)
    }
}
