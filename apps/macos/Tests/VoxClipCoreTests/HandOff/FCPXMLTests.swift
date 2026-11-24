import Foundation
import Testing
import VoxClipCore

@Suite struct FCPXMLTests {
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
        let plan = EditPlan(sampleRate: 48_000, totalSamples: 384_000, kept: fixture.kept.map {
            MediaInterval(startSample: $0[0] * 48_000, endSample: $0[1] * 48_000)
        })
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
        if let dtdPath = ProcessInfo.processInfo.environment["VOXCLIP_FCPXML_DTD"] {
            xml.dtd = try XMLDTD(contentsOf: URL(fileURLWithPath: dtdPath))
            xml.dtd?.name = "fcpxml"
            try xml.validate()
        }
    }
}
