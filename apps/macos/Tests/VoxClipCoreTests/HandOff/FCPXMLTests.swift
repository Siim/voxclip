import Foundation
import Testing
import VoxClipCore

@Suite struct FCPXMLTests {
    @Test func segmentedMusicKeepsItsSourceClockAcrossCuts() throws {
        struct Vector: Decodable { let segments: [MusicSegment]; let expected: [String: [String]] }
        let vector = try JSONDecoder().decode(Vector.self, from: FixtureLoader.data("fixtures/fcpxml/music-segments.json"))
        let plan = EditPlan(sampleRate: 48_000, totalSamples: 288_000,
                            kept: [.init(startSample: 0, endSample: 96_000), .init(startSample: 192_000, endSample: 288_000)])
        var request = RenderRequest(sourceURL: URL(fileURLWithPath: "/Media/take.mov"), plan: plan,
            output: .init(size: .init(width: 320, height: 180), fps: 30, videoBitrate: 0))
        let source = MediaProbeResult(durationSeconds: 6, video: .init(width: 320, height: 180, frameRate: 30),
                                      audio: .init(sampleRate: 48_000, channels: 2), isPlayable: true)
        var entry = ProjectMusic(id: "bed", clipId: nil, asset: .init(file: "bed.wav", sha256: "", durationSeconds: 6),
                                 source: .file, title: "Bed", license: .own, gainDb: -20, startOffsetSeconds: 0)
        entry.segments = vector.segments
        request.music = .init(entry: entry, assetURL: URL(fileURLWithPath: "/Media/bed.wav"))
        let xml = try XMLDocument(data: FCPXML.document(name: "Segmented music", render: request, source: source, musicAudio: source.audio))
        for (path, values) in vector.expected.sorted(by: { $0.key < $1.key }) {
            #expect(try xml.nodes(forXPath: path).compactMap(\.stringValue) == values, "\(path)")
        }
        try validateWithAppleDTD(xml)
        var title = ClipEffect(id: "title", clipId: nil, kind: .title, start: 0, end: 1, text: "Title")
        title.fadeInSeconds = 0.5
        #expect(FCPXML.unsupportedReason(effects: [title]) != nil)
    }

    @Test func storySpineKeepsPlaybackOrder() throws {
        struct Story: Decodable {
            let name: String
            let kept: [[Double]]
            let partSeams: [Double]
            let expected: [String: [String]]
        }
        let fixture = try JSONDecoder().decode(Story.self, from: FixtureLoader.data("fixtures/fcpxml/story.json"))
        let rate = 48_000.0
        let plan = EditPlan(sampleRate: rate, totalSamples: 192_000, kept: fixture.kept.map {
            MediaInterval(startSample: Int64(($0[0] * rate).rounded()), endSample: Int64(($0[1] * rate).rounded()))
        }, partSeams: fixture.partSeams.map { Int64(($0 * rate).rounded()) })
        let request = RenderRequest(sourceURL: URL(fileURLWithPath: "/Media/take.mov"), plan: plan,
            output: .init(size: .init(width: 320, height: 180), fps: 30, videoBitrate: 0))
        let source = MediaProbeResult(durationSeconds: 4, video: .init(width: 320, height: 180, frameRate: 30),
                                      audio: .init(sampleRate: 48_000, channels: 2), isPlayable: true)
        let xml = try XMLDocument(data: FCPXML.document(name: fixture.name, render: request, source: source))
        for (xpath, values) in fixture.expected.sorted(by: { $0.key < $1.key }) {
            #expect(try xml.nodes(forXPath: xpath).compactMap(\.stringValue) == values, "\(xpath)")
        }
        try validateWithAppleDTD(xml)
        #expect(request.timeline.mapTime(3) == 0)
        #expect(request.timeline.mapEndTime(3) == plan.duration)
    }

    @Test func partSpeedRetimesPictureAndDialogueWithoutRetimingMusic() throws {
        let source = MediaProbeResult(durationSeconds: 6, video: MediaVideo(width: 1920, height: 1080, frameRate: 30),
            audio: MediaAudio(sampleRate: 48_000, channels: 2), isPlayable: true)
        let plan = EditPlan(sampleRate: 48_000, totalSamples: 288_000,
            cuts: [.init(startSample: 0, endSample: 48_000), .init(startSample: 240_000, endSample: 288_000)],
            kept: [.init(startSample: 48_000, endSample: 240_000)])
        var request = RenderRequest(sourceURL: URL(fileURLWithPath: "/Media/take.mov"), plan: plan, captions: .init(),
            output: .init(size: .init(width: 1080, height: 1920), fps: 30, videoBitrate: 0))
        var speed = ClipEffect(id: "pace", clipId: nil, kind: .speedForPart, start: 2, end: 4)
        speed.rate = 2
        request.effects = .init(effects: [speed], soundURLs: [:])
        request.music = MusicRenderInput(entry: ProjectMusic(id: "bed", clipId: nil,
            asset: MusicAsset(file: "bed.wav", sha256: "", durationSeconds: 6), source: .file,
            title: "Bed", license: .own, startOffsetSeconds: 0), assetURL: URL(fileURLWithPath: "/Media/bed.wav"))
        let xml = try XMLDocument(data: FCPXML.document(name: "Part speed", render: request, source: source, musicAudio: source.audio))
        #expect(try xml.nodes(forXPath: "//sequence/@duration").compactMap(\.stringValue) == ["3s"])
        #expect(try xml.nodes(forXPath: "//asset-clip/timeMap/timept/@time").compactMap(\.stringValue) == ["2s", "3s"])
        #expect(try xml.nodes(forXPath: "//asset-clip/timeMap/timept/@value").compactMap(\.stringValue) == ["2s", "4s"])
        #expect(try xml.nodes(forXPath: "//audio[@role='dialogue']/timeMap/timept/@value").compactMap(\.stringValue) == ["2s", "4s"])
        #expect(try xml.nodes(forXPath: "//audio[@role='music']/@start").compactMap(\.stringValue) == ["0s", "1s", "2s"])
        #expect(try xml.nodes(forXPath: "//audio[@role='music']/timeMap").isEmpty)
        try validateWithAppleDTD(xml)
    }

    private struct Fixture: Decodable {
        let name: String
        let kept: [[Int64]]
        let title: String
        let caption: String
        let expected: [String: [String]]
    }

    @Test func editableTimelineMatchesGoldenAndAppleDTD() throws {
        let shared = try SharedResources.locate()
        let fixtureURL = shared.root.appendingPathComponent("fixtures/fcpxml/cut-titles-roles.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let kept = fixture.kept.map {
            MediaInterval(startSample: $0[0] * 48_000, endSample: $0[1] * 48_000)
        }
        let cuts = zip([0] + kept.map(\.endSample), kept.map(\.startSample) + [384_000]).compactMap { start, end in
            start < end ? MediaInterval(startSample: start, endSample: end) : nil
        }
        let plan = EditPlan(sampleRate: 48_000, totalSamples: 384_000, cuts: cuts, kept: kept)
        let word = CaptionWord(id: "caption", text: fixture.caption, start: 1.5, end: 2.5)
        let rect = CaptionRect(x: 0, y: 0, width: 0, height: 0)
        let page = CaptionPage(index: 0, words: [word], start: word.start, end: word.end, fontPx: 54, block: rect, visual: rect)
        let effect = ClipEffect(id: "title", clipId: nil, kind: .title, start: 2, end: 6, text: fixture.title)
        let music = ProjectMusic(id: "bed", clipId: nil,
            asset: MusicAsset(file: "bed.wav", sha256: "", durationSeconds: 2), source: .file,
            title: "Bed", license: .own, startOffsetSeconds: 1)
        var request = RenderRequest(sourceURL: URL(fileURLWithPath: "/Media/Voice & image.mov"), plan: plan,
            captions: CaptionTrack(words: [word], pages: [page]),
            output: OutputSpec(size: PixelSize(width: 1080, height: 1920), fps: 30, videoBitrate: 0))
        request.music = MusicRenderInput(entry: music, assetURL: URL(fileURLWithPath: "/Media/bed.wav"))
        request.effects = ClipEffectsRenderInput(effects: [effect], soundURLs: [:])
        let source = MediaProbeResult(durationSeconds: 8, video: MediaVideo(width: 1920, height: 1080, frameRate: 30),
            audio: MediaAudio(sampleRate: 48_000, channels: 2), isPlayable: true)
        let data = try FCPXML.document(name: fixture.name, render: request, source: source,
            musicAudio: MediaAudio(sampleRate: 48_000, channels: 2))
        let xml = try XMLDocument(data: data)
        for (xpath, values) in fixture.expected.sorted(by: { $0.key < $1.key }) {
            let actual = try xml.nodes(forXPath: xpath).compactMap { $0.stringValue }
            #expect(actual == values, "\(xpath)")
        }
        try validateWithAppleDTD(xml)
    }

    private func validateWithAppleDTD(_ xml: XMLDocument) throws {
        if let dtdPath = ProcessInfo.processInfo.environment["VOXCLIP_FCPXML_DTD"] {
            xml.dtd = try XMLDTD(contentsOf: URL(fileURLWithPath: dtdPath))
            xml.dtd?.name = "fcpxml"
            try xml.validate()
        }
    }
}
