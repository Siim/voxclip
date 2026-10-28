import Foundation
import Testing
@testable import VoxClipCore

@Test("Every caption box text colour vector")
func captionBoxTextColorVectors() throws {
    struct Fixture: Decodable {
        struct Case: Decodable {
            var id: String; var style: String; var overrides: [String: JSONValue]; var state: String
            var box: [UInt8]; var text: [UInt8]; var contrast: Double; var expected: [UInt8]
        }
        var fixture: String; var cases: [Case]
    }
    let shared = try CaptionCoreFixtures.shared()
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: shared.appendingPathComponent("fixtures/captions/box-text-colors.json")))
    #expect(fixture.fixture == "voxclip-caption-box-text-colors/1")
    #expect(fixture.cases.count == 54)
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
        return [UInt8((channels >> 24) & 255), UInt8((channels >> 16) & 255), UInt8((channels >> 8) & 255), UInt8(channels & 255)]
    }
    for item in fixture.cases {
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: shared.appendingPathComponent("caption-styles/styles/\(item.style).json")))
        let input = CaptionLayoutInput(style: style.id, frame: .init(width: 1080, height: 1920), language: "en", duration: 0,
                                       captions: .init(overrides: item.overrides), words: [])
        let resolved = try CaptionStyleResolver.resolve(style, input: input)
        let sidebar = try style.resolved(overrides: item.overrides, frame: .init(width: 1080, height: 1920))
        #expect(resolved == sidebar, "\(item.id)")
        let appearance = CaptionTimeline.wordState(resolved, item.state)
        let paint = appearance?.fill ?? resolved.fill
        guard case .solid(let token) = paint else { Issue.record("\(item.id): solid fill missing"); continue }
        let actual = try rgba(token, style: resolved)
        let box = try #require(appearance?.box?.color ?? resolved.box?.color)
        #expect(try rgba(box, style: resolved) == item.box, "\(item.id)")
        #expect(actual == item.expected, "\(item.id)")
        #expect(abs(CaptionContrast.ratio(rgb(item.text), rgb(item.box)) - item.contrast) < 1e-12, "\(item.id)")
        #expect(CaptionContrast.ratio(rgb(actual), rgb(item.box)) >= 4.5, "\(item.id)")
        if item.style == "box-highlight" { #expect(resolved.words?.active?.hideStroke == true) }
    }
}

@Test("Non-boxed caption colours stay unchanged")
func captionNonBoxTextColorsUnchanged() throws {
    let shared = try CaptionCoreFixtures.shared()
    let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: shared.appendingPathComponent("caption-styles/styles/active-pop.json")))
    #expect(CaptionContrast.resolve(style) == style)
}
