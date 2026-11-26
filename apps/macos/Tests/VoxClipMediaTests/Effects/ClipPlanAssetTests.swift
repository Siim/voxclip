@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import VoxClipCore
import VoxClipMedia

private actor EffectFixtureHTTP: MusicHTTP {
    var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let (file, type) = switch (url.host, url.path) {
        case ("api.openverse.org", _): ("fixtures/clip-effects/openverse-sound.json", "application/json")
        case ("audio.example.test", "/pop.wav"): ("data/sfx/pop.wav", "audio/wav")
        case ("fal.run", "/fal-ai/flux/schnell"): ("fixtures/clip-effects/fal-illustration.json", "application/json")
        default: throw URLError(.unsupportedURL)
        }
        return (try FixtureLoader.data(file), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])))
    }
}

@Suite struct ClipPlanAssetTests {
    private let project = "57aab2ac-6116-4552-8d0e-4f569ced5d67"

    @Test func findsOnlyALicensedSoundThatFitsAndKeepsItsCredit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = EffectFixtureHTTP()
        let asset = ClipPlanAsset(id: "sound", kind: .sound, clipID: "clip", start: 1, end: 2, text: "pop")
        let placed = try #require(await ClipPlanAssets(http: http).sound(asset, projectID: project, root: root))
        let sound = try #require(placed.sound)
        #expect(sound.license == "by")
        #expect(sound.attribution == "Pop by Fixture creator (CC BY 4.0)")
        #expect(sound.sourceUrl == "https://audio.example.test/credits/pop")
        #expect(placed.gainDb == -15)
        let requests = await http.requests
        #expect(requests.count == 2)
        #expect(requests.first?.url?.query()?.contains("category=sound_effect") == true)
        #expect(requests.last?.url?.path == "/pop.wav")
    }

    @Test func savesThePaidImageBeforePlacementAndReusesItWithoutARequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = EffectFixtureHTTP()
        let client = ClipPlanAssets(http: http)
        let quote = try ClipIllustrationQuote.load(shared: SharedResources.locate())
        let asset = ClipPlanAsset(id: "image", kind: .illustration, clipID: "clip", start: 1, end: 2, text: "a paper boat")
        #expect(client.savedIllustration(asset, projectID: project, root: root, quote: quote) == nil)
        let placed = try await client.illustration(asset, projectID: project, root: root, quote: quote, key: "offline-fixture")
        let file = ClipEffectsRenderInput.imageRoot(dataRoot: root).appendingPathComponent(try #require(placed.imageFile))
        #expect(try Data(contentsOf: file).starts(with: [137, 80, 78, 71]))
        #expect(client.savedIllustration(asset, projectID: project, root: root, quote: quote) == placed)
        #expect(await http.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(2))) func realExportCarriesTheSoundCreditAndTheTimedCutaway() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ClipPlanAssets(http: EffectFixtureHTTP())
        let soundRequest = ClipPlanAsset(id: "sound", kind: .sound, clipID: "clip", start: 0.6, end: 1.4, text: "pop")
        let imageRequest = ClipPlanAsset(id: "image", kind: .illustration, clipID: "clip", start: 0.6, end: 1.4, text: "a paper boat")
        let sound = try #require(await client.sound(soundRequest, projectID: project, root: root))
        let quote = try ClipIllustrationQuote.load(shared: SharedResources.locate())
        let image = try await client.illustration(imageRequest, projectID: project, root: root, quote: quote, key: "offline-fixture")
        let soundURL = ClipEffectsRenderInput.soundRoot(dataRoot: root).appendingPathComponent(try #require(sound.sound?.file))
        let imageURL = ClipEffectsRenderInput.imageRoot(dataRoot: root).appendingPathComponent(try #require(image.imageFile))
        let source = try await NativeMediaFixtures.shared.file("counter.mov")
        var render = EffectRenderTests.request(source, effects: [])
        render.effects = ClipEffectsRenderInput(effects: [sound, image], soundURLs: [sound.id: soundURL], imageURLs: [image.id: imageURL])
        let output = root.appendingPathComponent("with-effects.mp4")
        _ = try await AVExporter().export(.init(render: render, outputURL: output, loudness: .off)) { _ in }
        let payload = try #require(try iTunesMetadataPayload(output, itemType: iTunesCommentAtom))
        let comment = try #require(String(data: payload, encoding: .utf8))
        #expect(comment.contains("Pop by Fixture creator (CC BY 4.0)"))
        let exported = AVURLAsset(url: output)
        let generator = AVAssetImageGenerator(asset: exported)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let outside = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
        let inside = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        func center(_ frame: CGImage) throws -> [UInt8] {
            let crop = try #require(frame.cropping(to: CGRect(x: frame.width / 2, y: frame.height / 2, width: 1, height: 1)))
            var pixels: [UInt8] = [0, 0, 0, 0]
            let context = try #require(CGContext(data: &pixels, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return pixels
        }
        let picture = try center(inside)
        #expect((95...155).contains(picture[0]) && picture[1] < 90 && picture[2] > 170)
        #expect(try center(outside) != picture)
    }
}
