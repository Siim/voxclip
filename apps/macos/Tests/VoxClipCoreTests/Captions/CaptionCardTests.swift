import Foundation
import Testing
@testable import VoxClipCore

@Test("Every sidebar colour vector")
func captionCardColorVectors() throws {
    struct Fixture: Decodable {
        struct Case: Decodable { var id: String; var box: [UInt8]; var background: [UInt8]; var expected: [UInt8] }
        var fixture: String
        var cases: [Case]
    }
    let url = try CaptionCoreFixtures.shared().appendingPathComponent("fixtures/captions/card-colors.json")
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    #expect(fixture.fixture == "voxclip-caption-card-colors/1")
    for item in fixture.cases {
        let actual = CaptionCardColors.sidebarKeyText(box: (item.box[0], item.box[1], item.box[2]),
                                                     background: (item.background[0], item.background[1], item.background[2]))
        #expect([actual.r, actual.g, actual.b] == item.expected, "\(item.id)")
    }
}

private struct CardFixture: Decodable {
    struct Surface: Decodable { var surface: String; var lines: Int; var plates: Bool }
    struct Word: Decodable { var id: String; var text: String; var display: String; var weak: Bool }
    struct LayoutWord: Decodable { var id: String; var text: String; var start: Double; var end: Double; var emphasis: Bool }
    struct Layout: Decodable { var words: [LayoutWord]; var duration: Double; var time: Double }
    struct Drop: Decodable { var words: [String]; var keyIndex: Int; var time: Double }
    struct Expected: Decodable {
        var source: String; var keyIndex: Int; var styleMaxLines: Int; var drawsAtLastWord: Bool; var holdGapSec: Double
        var words: [Word]; var maxLines: [String: Int]; var layout: Layout; var drops: [Drop]
    }
    struct Case: Decodable { var id: String; var project: String; var style: String; var scope: String?; var wordsVisible: Bool; var expected: Expected }
    var fixture: String; var maxWords: Int; var surfaces: [Surface]; var projects: [String: Project]; var cases: [Case]
}

@Test("Every caption card fixture")
func captionCardFixtures() throws {
    let root = try CaptionCoreFixtures.shared(), resources = try CaptionCoreFixtures.resources()
    let fixture = try ProjectJSON.decoder().decode(CardFixture.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/captions/cards.json")))
    #expect(fixture.fixture == "voxclip-caption-cards/1")
    #expect(fixture.maxWords == CaptionCardText.maxWords)
    #expect(fixture.surfaces.map(\.surface) == CaptionCardSurface.allCases.map(\.rawValue))
    for surface in fixture.surfaces {
        let value = try #require(CaptionCardSurface(rawValue: surface.surface))
        #expect(value.lineLimit == surface.lines && value.drawsPlates == surface.plates, "\(surface.surface)")
    }
    #expect(fixture.cases.count >= 50)
    for item in fixture.cases {
        let project = try #require(fixture.projects[item.project], "\(item.id)")
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: root.appendingPathComponent("caption-styles/styles/\(item.style).json")))
        let card = CaptionCardText.make(project: project, scope: item.scope.map { .clip($0) } ?? .fullTake, style: style,
                                        wordsVisible: item.wordsVisible, resources: resources)
        let expected = item.expected
        #expect(card.source.rawValue == expected.source, "\(item.id)")
        #expect(card.words.map(\.id) == expected.words.map(\.id), "\(item.id)")
        #expect(card.words.map(\.text) == expected.words.map(\.text), "\(item.id)")
        #expect(card.words.map(\.display) == expected.words.map(\.display), "\(item.id)")
        #expect(card.words.map(\.weak) == expected.words.map(\.weak), "\(item.id)")
        #expect(card.keyIndex == expected.keyIndex, "\(item.id)")
        #expect(card.styleMaxLines == expected.styleMaxLines, "\(item.id)")
        #expect(card.drawsAtLastWord == expected.drawsAtLastWord && card.holdGapSec == expected.holdGapSec, "\(item.id)")
        for surface in CaptionCardSurface.allCases { #expect(card.maxLines(on: surface) == expected.maxLines[surface.rawValue], "\(item.id) \(surface)") }
        let layout = card.layoutWords
        #expect(layout.map(\.id) == expected.layout.words.map(\.id) && layout.map(\.text) == expected.layout.words.map(\.text), "\(item.id)")
        #expect(layout.map { $0.emphasis == true } == expected.layout.words.map(\.emphasis), "\(item.id)")
        for (actual, wanted) in zip(layout, expected.layout.words) {
            #expect(abs(actual.start - wanted.start) <= 1e-9 && abs(actual.end - wanted.end) <= 1e-9, "\(item.id) \(wanted.id)")
        }
        #expect(abs(card.duration - expected.layout.duration) <= 1e-9 && abs(card.time - expected.layout.time) <= 1e-9, "\(item.id)")
        var current = card, drops: [CaptionCardText] = []
        while let shorter = current.droppingLastWord() { drops.append(shorter); current = shorter }
        #expect(drops.map { $0.words.map(\.id) } == expected.drops.map(\.words), "\(item.id)")
        #expect(drops.map(\.keyIndex) == expected.drops.map(\.keyIndex), "\(item.id)")
        #expect(zip(drops, expected.drops).allSatisfy { abs($0.time - $1.time) <= 1e-9 }, "\(item.id)")
    }
}

/// One half-em glyph per kept scalar, so card and gallery layouts page and time without CoreText.
struct FixedAdvanceShaper: GlyphShaper {
    let resources: CaptionResources
    func shape(_ request: GlyphShapeRequest) async throws -> [ShapedRun] {
        try CaptionFontCascade.resolve(request, resources: resources).runs.map { run in
            let unitsPerEm = try resources.font(run.file).unitsPerEm
            let glyphs = run.clusters.map { ShapedGlyph(id: 1, advance: unitsPerEm / 2, cluster: $0) }
            return ShapedRun(file: run.file, text: run.text, unitsPerEm: unitsPerEm, units: glyphs.count * (unitsPerEm / 2), glyphs: glyphs)
        }
    }
}

@Test("Every caption card shows its key word, or every word of a reveal style, at its drawn moment")
func captionCardDrawnMoment() async throws {
    let root = try CaptionCoreFixtures.shared(), resources = try CaptionCoreFixtures.resources()
    let fixture = try ProjectJSON.decoder().decode(CardFixture.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/captions/cards.json")))
    let shaper = FixedAdvanceShaper(resources: resources)
    var drawnCards = 0
    for item in fixture.cases {
        let project = try #require(fixture.projects[item.project], "\(item.id)")
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: root.appendingPathComponent("caption-styles/styles/\(item.style).json")))
        var next: CaptionCardText? = CaptionCardText.make(project: project, scope: item.scope.map { .clip($0) } ?? .fullTake, style: style,
                                                          wordsVisible: item.wordsVisible, resources: resources)
        while let card = next, !card.words.isEmpty {
            let label = "\(item.id) (\(card.words.count) words)", frame = CaptionCardText.exportFrame(project)
            let input = CaptionLayoutInput(style: style.id, frame: .init(width: frame.width, height: frame.height), language: project.transcript?.language ?? "und",
                duration: card.duration, captions: .init(overrides: project.captions.overrides, position: project.captions.position,
                                                         positionByAspect: project.captions.positionByAspect), words: card.layoutWords)
            let track = try await CaptionLayoutEngine.build(input: input, style: style, resources: resources, shaper: shaper)
            #expect(track.words.count == card.words.count, "\(label)")
            for reduceMotion in [false, true] {
                let state = CaptionTimeline.evaluate(track, time: card.time, reduceMotion: reduceMotion)
                #expect(state.page != nil, "\(label) at \(card.time)")
                if card.drawsAtLastWord {
                    let drawn = state.words.filter { $0.visible && ($0.visibleClusters == nil || $0.visibleClusters == track.words[$0.word].shaped.clusters) }
                    #expect(drawn.map(\.word).sorted() == Array(card.words.indices), "\(label) at \(card.time)")
                } else {
                    #expect(state.activeWord == card.keyIndex, "\(label) at \(card.time)")
                }
            }
            drawnCards += 1
            next = card.droppingLastWord()
        }
    }
    #expect(drawnCards > 40)
}

@Test("Media stand-in precedence matches the shared cases")
func mediaStandInPrecedence() throws {
    struct Fixture: Decodable {
        struct Case: Decodable { var status: String; var hasFrame: Bool; var holding: Bool; var hasWords: Bool; var standIn: String }
        var standIns: [Case]
    }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: try CaptionCoreFixtures.shared().appendingPathComponent("fixtures/captions/cards.json")))
    let statuses: [String: MediaStatus] = ["none": MediaStatus.none, "loading": .loading, "missing": .missing, "unreadable": .unreadable,
                                           "transcribing": .transcribing(fraction: 0.42, stage: .transcribing), "demo": .demo, "audioOnly": .audioOnly]
    let words = CaptionCardText(source: .transcript, words: [.init(id: "w1", text: "Coffee", display: "COFFEE", weak: false)],
                                keyIndex: 0, styleMaxLines: 2, drawsAtLastWord: false, holdGapSec: 0)
    #expect(fixture.standIns.count == 56 && Set(fixture.standIns.map(\.status)) == Set(statuses.keys))
    for item in fixture.standIns {
        let status = try #require(statuses[item.status])
        let card = item.hasWords ? words : CaptionCardText.none
        let expected: MediaStandIn = item.standIn == "frame" ? .frame : item.standIn == "card" ? .card(card, styleId: "vox-highlight") : .black
        #expect(MediaStandIn.resolve(status: status, hasFrame: item.hasFrame, card: card, styleId: "vox-highlight", holding: item.holding) == expected,
                "\(item.status) frame \(item.hasFrame) holding \(item.holding) words \(item.hasWords)")
    }
}

@Test("Caption cards round-trip for the Home metadata cache")
func captionCardCoding() throws {
    let card = CaptionCardText(source: .title, words: [.init(id: "title-0", text: "Grinder", display: "GRINDER", weak: false)],
                               keyIndex: 0, styleMaxLines: 2, drawsAtLastWord: false, holdGapSec: 0)
    #expect(try JSONDecoder().decode(CaptionCardText.self, from: JSONEncoder().encode(card)) == card)
    #expect(CaptionCardText.none.maxLines(on: .homeTile) == 0 && CaptionCardText.none.layoutWords.isEmpty && CaptionCardText.none.droppingLastWord() == nil)
}
