import Foundation
import Testing
@testable import VoxClipCore

private struct GalleryFixture: Decodable {
    struct Word: Decodable { var id: String; var text: String; var start: Double; var end: Double }
    struct Expected: Decodable { var source: String; var words: [Word]; var duration: Double; var time: Double }
    struct Case: Decodable {
        var id: String; var project: String; var style: String; var scope: String?; var playhead: Double; var wordsVisible: Bool
        var expected: Expected
    }
    var fixture: String; var projects: [String: Project]; var cases: [Case]

    static func load() throws -> GalleryFixture {
        let url = try CaptionCoreFixtures.shared().appendingPathComponent("fixtures/captions/gallery-samples.json")
        return try ProjectJSON.decoder().decode(GalleryFixture.self, from: Data(contentsOf: url))
    }
}

private func galleryStyle(_ id: String) throws -> CaptionStyle {
    let url = try CaptionCoreFixtures.shared().appendingPathComponent("caption-styles/styles/\(id).json")
    return try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: url))
}

@Test("Every caption gallery sample fixture")
func captionGallerySampleFixtures() throws {
    let resources = try CaptionCoreFixtures.resources(), fixture = try GalleryFixture.load()
    #expect(fixture.fixture == "voxclip-caption-gallery/1")
    #expect(fixture.cases.count >= 86)
    #expect(Set(fixture.cases.map(\.style)).count == 19)
    #expect(Set(fixture.cases.map(\.expected.source)) == ["page", "preview"])
    for item in fixture.cases {
        let project = try #require(fixture.projects[item.project], "\(item.id)")
        let sample = CaptionGallerySample.make(project: project, scope: item.scope.map { .clip($0) } ?? .fullTake, playhead: item.playhead,
                                               style: try galleryStyle(item.style), wordsVisible: item.wordsVisible, resources: resources)
        let expected = item.expected
        #expect(sample.source.rawValue == expected.source, "\(item.id)")
        #expect(sample.words.map(\.id) == expected.words.map(\.id), "\(item.id)")
        #expect(sample.words.map(\.text) == expected.words.map(\.text), "\(item.id)")
        #expect(sample.words.allSatisfy { $0.emphasis == nil && $0.emoji == nil }, "\(item.id)")
        for (actual, wanted) in zip(sample.words, expected.words) {
            #expect(actual.start == wanted.start && actual.end == wanted.end, "\(item.id) \(wanted.id)")
        }
        #expect(sample.duration == expected.duration && sample.time == expected.time, "\(item.id)")
    }
}

@Test("One prepared CaptionGalleryPages gives the sample at every playhead")
func captionGalleryPagesFollowThePlayhead() throws {
    let resources = try CaptionCoreFixtures.resources(), fixture = try GalleryFixture.load()
    var prepared: [String: CaptionGalleryPages] = [:], reused = 0
    for item in fixture.cases {
        let key = [item.project, item.scope ?? "", item.style, String(item.wordsVisible)].joined(separator: "|")
        if prepared[key] == nil {
            let project = try #require(fixture.projects[item.project], "\(item.id)")
            prepared[key] = CaptionGalleryPages(project: project, scope: item.scope.map { .clip($0) } ?? .fullTake, style: try galleryStyle(item.style),
                                                wordsVisible: item.wordsVisible, resources: resources)
        } else {
            reused += 1
        }
        let sample = try #require(prepared[key]).sample(at: item.playhead)
        #expect(sample.source.rawValue == item.expected.source && sample.words.map(\.id) == item.expected.words.map(\.id), "\(item.id)")
        #expect(sample.time == item.expected.time, "\(item.id)")
    }
    #expect(reused >= 30)
}

@Test("Every gallery sample is drawn with its word active at the tile time")
func captionGallerySampleDrawnMoment() async throws {
    let resources = try CaptionCoreFixtures.resources(), fixture = try GalleryFixture.load()
    let shaper = FixedAdvanceShaper(resources: resources)
    for item in fixture.cases {
        let project = try #require(fixture.projects[item.project], "\(item.id)")
        let style = try galleryStyle(item.style)
        let sample = CaptionGallerySample.make(project: project, scope: item.scope.map { .clip($0) } ?? .fullTake, playhead: item.playhead,
                                               style: style, wordsVisible: item.wordsVisible, resources: resources)
        let frame = CaptionCardText.exportFrame(project)
        let overrides = style.id == project.captions.styleId ? project.captions.overrides : [:]
        let settings = CaptionLayoutInput.Settings(overrides: overrides, position: project.captions.position,
                                                   positionByAspect: project.captions.positionByAspect)
        let input = CaptionLayoutInput(style: style.id, frame: .init(width: frame.width, height: frame.height),
                                       language: sample.source == .preview ? "en" : project.transcript?.language ?? "und", duration: sample.duration, captions: settings,
                                       words: sample.words)
        let track = try await CaptionLayoutEngine.build(input: input, style: style, resources: resources, shaper: shaper)
        #expect(track.words.count == sample.words.count, "\(item.id)")
        if item.id.hasPrefix("selected-line-") { #expect(track.pages.count > 1, "\(item.id)") }
        // The tile time lies inside word a, which has started while the next word has not: the active word (§8.2).
        let anchor = Int((sample.time / 0.4).rounded(.down))
        for reduceMotion in [true, false] {
            let state = CaptionTimeline.evaluate(track, time: sample.time, reduceMotion: reduceMotion)
            #expect(state.page != nil && state.activeWord == anchor, "\(item.id) at \(sample.time)")
        }
    }
}

@Test("A playhead that is not finite counts as the start of the scope")
func captionGallerySampleNonFinitePlayhead() throws {
    let resources = try CaptionCoreFixtures.resources(), fixture = try GalleryFixture.load()
    let project = try #require(fixture.projects["interview-take"])
    for id in ["karaoke", "vox-highlight", "typewriter"] {
        let style = try galleryStyle(id)
        let start = CaptionGallerySample.make(project: project, scope: .fullTake, playhead: 0, style: style, wordsVisible: true, resources: resources)
        for playhead in [Double.nan, .infinity, -.infinity] {
            let sample = CaptionGallerySample.make(project: project, scope: .fullTake, playhead: playhead, style: style, wordsVisible: true,
                                                   resources: resources)
            #expect(sample == start, "\(id) at \(playhead)")
        }
    }
}

@Test("The preview sample uses progress 1 when a style has none")
func captionGalleryPreviewDefaultProgress() throws {
    var style = try galleryStyle("active-pop")
    style.preview.progress = nil
    let sample = CaptionGallerySample.preview(style)
    #expect(sample.source == .preview && sample.words.map(\.text) == ["This", "changes", "everything"])
    #expect(sample.words.map(\.id) == ["preview-0", "preview-1", "preview-2"])
    #expect(abs(sample.time - (0.4 + 0.35 * 0.98)) <= 1e-12 && abs(sample.duration - 1.7) <= 1e-12)
    style.preview.activeWord = 15
    #expect(abs(CaptionGallerySample.preview(style).time - (0.8 + 0.35 * 0.98)) <= 1e-12)
}

@Test("Binary gallery lookup agrees with a linear reference on a 2,304-word take")
func captionGalleryLongTakeLookup() throws {
    let resources = try CaptionCoreFixtures.resources(), fixture = try GalleryFixture.load()
    var project = try #require(fixture.projects["interview-take"])
    var transcript = try #require(project.transcript)
    let texts = ["So", "bright", "12", "ideas", "travel", "far", "in", "the"]
    transcript.words = (0..<2_304).map { index in
        let start = 0.2 + Double(index) * 0.45 + Double(index / 9) * 0.8
        let text = texts[index % texts.count] + (index % 13 == 12 ? "." : "")
        return TimedWord(id: "long-\(index)", text: text, start: start, end: start + 0.3)
    }
    let duration = try #require(transcript.words.last).end + 0.5
    transcript.durationSeconds = duration
    project.transcript = transcript
    project.media.source.durationSeconds = duration
    project.edits.cutWordIds = []; project.edits.cutPauseIds = []; project.edits.corrections = [:]
    project.edits.clips = []; project.edits.activeClipId = nil
    project.captions.overrides = [:]
    struct ReferencePage {
        var start: Double, end: Double
        var words: [CaptionCardText.Candidate]
        var keyTime: Double
    }
    for id in ["vox-highlight", "karaoke", "typewriter"] {
        let style = try galleryStyle(id)
        let copy = try #require(CaptionCardText.ScopeWords(project: project, scope: .fullTake, style: style, overrides: [:], resources: resources))
        #expect(copy.words.count == 2_304)
        let words = copy.words, layout = copy.style.layout
        let groups = CaptionLayoutEngine.pageGroups(count: words.count, layout: layout, raw: { words[$0].raw },
                                                     start: { words[$0].start }, end: { words[$0].end }) { _ in true }
        let reference = groups.enumerated().map { index, group in
            let page = group.map { words[$0] }
            let next = index + 1 < groups.count ? words[groups[index + 1][0]].start : Double.infinity
            let end = CaptionLayoutEngine.pageEnd(start: page[0].start, lastEnd: page[page.count - 1].end, next: next,
                                                  layout: layout, duration: copy.duration)
            return ReferencePage(start: page[0].start, end: end, words: page, keyTime: copy.card(source: .transcript, words: page).time)
        }
        var probes = [-1.0, 0, duration, duration + 1]
        for page in reference {
            probes += [page.start.nextDown, page.start, page.start.nextUp, page.end.nextDown, page.end, page.end.nextUp]
        }
        for index in stride(from: 0, to: words.count, by: 31) { probes += [words[index].start, words[index].end] }
        let prepared = CaptionGalleryPages(project: project, scope: .fullTake, style: style, wordsVisible: true, resources: resources)
        for time in probes {
            let visible = reference.firstIndex { $0.start <= time && time < $0.end }
            let next = reference.firstIndex { $0.start > time }
            let page = reference[visible ?? next ?? reference.count - 1]
            var expectedTime = page.keyTime
            if visible != nil, let active = page.words.lastIndex(where: { $0.start <= time }), time < page.words[active].end {
                expectedTime = Double(active) * 0.4 + 0.35 * 0.98
            }
            let actual = prepared.sample(at: time)
            #expect(actual.source == .page, "\(id) at \(time)")
            #expect(actual.words.map(\.id) == page.words.map(\.id), "\(id) at \(time)")
            #expect(actual.time == expectedTime, "\(id) at \(time)")
        }
    }
}
