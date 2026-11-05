import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/clip-effects/effects-wire-cases.json; the C# twin replays the same file.
@Suite(.offlineFixtures) struct ClipEffectsWireTests {
    private struct Patch: Decodable {
        let path: String
        let value: JSONValue?
        let remove: Bool?
    }
    private struct WireCase: Decodable {
        let id: String
        let patches: [Patch]
        let tooNew: Bool?
    }
    private struct Cases: Decodable {
        let format: String
        let valid: [WireCase]
        let invalid: [WireCase]
    }
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/clip-effects/effects-wire-cases.json"))
    }

    private func replacing(_ original: JSONValue, path: ArraySlice<String>, patch: Patch) throws -> JSONValue {
        guard let key = path.first else { return patch.value ?? .null }
        switch original {
        case .object(var object):
            if path.count == 1 {
                if patch.remove == true { object.removeValue(forKey: key) } else { object[key] = patch.value ?? .null }
            } else {
                object[key] = try replacing(#require(object[key]), path: path.dropFirst(), patch: patch)
            }
            return .object(object)
        case .array(var array):
            let index = try #require(Int(key))
            if path.count == 1, patch.remove == true { array.remove(at: index); return .array(array) }
            array[index] = path.count == 1 ? (patch.value ?? .null) : try replacing(array[index], path: path.dropFirst(), patch: patch)
            return .array(array)
        default:
            throw VoxClipError.projectUnreadable("Invalid fixture patch")
        }
    }

    private func data(_ item: WireCase) throws -> Data {
        var value = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/clip-effects/effects-project.voxclip"))
        for patch in item.patches {
            value = try replacing(value, path: patch.path.split(separator: "/").map(String.init)[...], patch: patch)
        }
        return try JSONEncoder().encode(value)
    }

    private func fixture() throws -> Project { try ProjectJSON.decode(FixtureLoader.data("fixtures/clip-effects/effects-project.voxclip")) }

    @Test func formatIsItsOwnFile() throws {
        #expect(try cases().format == "voxclip-clip-effects-wire-cases/1")
    }

    @Test func validCorpusRoundTripsAtV4AndWritesOnlyEachKindsKeys() throws {
        for item in try cases().valid {
            let input = try data(item)
            let project = try ProjectJSON.decode(input)
            #expect(project.schemaVersion == 4, "\(item.id)")
            let encoded = try ProjectJSON.encode(project)
            #expect(try ProjectJSON.decode(encoded) == project, "\(item.id)")
            #expect(try JSONProjectStore.decode(JSONProjectStore.encode(project)) == project, "\(item.id)")
            let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let original = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
            if project.clipEffects.isEmpty { #expect(raw["clipEffects"] == nil, "\(item.id)") }
            // Saved unchanged: the same entries, key for key, as the file that was opened.
            #expect(NSDictionary(dictionary: ["e": raw["clipEffects"] ?? NSNull()]) == NSDictionary(dictionary: ["e": original["clipEffects"] ?? NSNull()]), "\(item.id)")
            for entry in (raw["clipEffects"] as? [[String: Any]]) ?? [] {
                let kind = try #require(ClipEffect.Kind(rawValue: entry["kind"] as? String ?? ""))
                #expect(Set(entry.keys) == ClipEffect.commonKeys.union(ClipEffect.kindKeys(kind)), "\(item.id) \(kind)")
            }
        }
    }

    @Test func invalidCorpusIsRejected() throws {
        for item in try cases().invalid {
            let input = try data(item)
            if item.tooNew == true {
                #expect(throws: VoxClipError.projectTooNew, "\(item.id)") { try ProjectJSON.decode(input) }
            } else {
                #expect(throws: (any Error).self, "\(item.id)") { try ProjectJSON.decode(input) }
                #expect(throws: (any Error).self, "\(item.id)") { try JSONProjectStore.decode(input) }
            }
        }
    }

    @Test func legacyProjectWithoutEffectsSavesUnchangedAndPromotesOnFirstEffect() throws {
        let input = try FixtureLoader.data("fixtures/projects/interview-take.voxclip")
        let original = try ProjectJSON.decode(input)
        #expect(original.schemaVersion == 1 && original.clipEffects.isEmpty)
        let saved = try #require(JSONSerialization.jsonObject(with: ProjectJSON.encode(original)) as? [String: Any])
        #expect(saved["clipEffects"] == nil && saved["schemaVersion"] as? Int == 1)
        let word = try #require(original.transcript?.words.first)
        let bleep = ClipEffect(id: "fx-bleep-1", clipId: nil, kind: .bleep, start: word.start, end: word.end, wordIds: [word.id])
        var promoted = try ClipEffects.adding([bleep], to: original)
        #expect(promoted.schemaVersion == 4 && promoted.clipEffects == [bleep])
        #expect(try ProjectJSON.decode(ProjectJSON.encode(promoted)) == promoted)
        promoted = try ClipEffects.removing(["fx-bleep-1"], from: promoted)
        #expect(promoted.clipEffects.isEmpty && promoted.schemaVersion == 4)
        var legacy = original
        legacy.clipEffects = [bleep]
        #expect(throws: ClipEffectError.unsupportedVersion) { try ProjectJSON.encode(legacy) }
    }

    @Test func removingAClipRemovesItsEffectsButKeepsFullVideoEffects() throws {
        var project = try fixture()
        #expect(project.clipEffects.filter { $0.clipId == nil }.map(\.id) == ["fx-pixelate-1", "fx-mute-1"])
        try project.applyEditing(.removeClip(id: "clip-main"))
        #expect(project.clipEffects.map(\.id) == ["fx-pixelate-1", "fx-mute-1"])
        #expect(try ProjectJSON.decode(ProjectJSON.encode(project)) == project)
    }

    @Test func censorEffectsRenderEverywhereAndOthersOnlyInTheirClip() throws {
        let project = try fixture()
        let full = ClipEffects.rendered(in: project, clipID: nil).map(\.id)
        #expect(full == ["fx-bleep-1", "fx-blur-1", "fx-pixelate-1", "fx-mute-1"])
        #expect(ClipEffects.rendered(in: project, clipID: "clip-main").count == 12)
    }

    @Test func bleepedWordsAreMaskedInCaptionsAndPunctuationStays() {
        #expect(ClipEffects.masked("damn,") == "\u{2588}\u{2588}\u{2588}\u{2588},")
        #expect(ClipEffects.masked("$4,200") == "$\u{2588},\u{2588}\u{2588}\u{2588}")
        let segments = [EditSegment(id: "w1", kind: .word, text: "keep", start: 0, end: 1, cut: false),
                        EditSegment(id: "w2", kind: .word, text: "secret.", start: 1, end: 2, cut: false)]
        let bleep = ClipEffect(id: "fx-bleep-1", clipId: nil, kind: .bleep, start: 1, end: 2, wordIds: ["w2"])
        let masked = ClipEffects.maskingBleeps(segments, effects: [bleep])
        #expect(masked.map(\.text) == ["keep", "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}."])
        #expect(ClipEffects.maskingBleeps(segments, effects: []) == segments)
    }

    @Test func tracksInterpolateHoldAtTheEndsAndSmooth() throws {
        let a = ClipEffect.Rect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), b = ClipEffect.Rect(x: 0.3, y: 0.1, width: 0.2, height: 0.2)
        let blur = ClipEffect(id: "fx-blur-1", clipId: nil, kind: .blur, start: 1, end: 2, rect: a, tracking: .face,
                              track: [.init(t: 1, rect: a), .init(t: 2, rect: b)])
        #expect(abs((blur.rect(at: 1.5)?.x ?? 0) - 0.2) < 1e-9)
        #expect(blur.rect(at: 0.5) == a && blur.rect(at: 3) == b)
        var still = blur
        still.track = []
        #expect(still.rect(at: 1.7) == a)
        let jitter = [ClipEffect.TrackSample(t: 0, rect: a), .init(t: 0.25, rect: b), .init(t: 0.5, rect: a)]
        let smoothed = ClipEffects.smoothed(jitter)
        #expect(smoothed[0].rect == a && smoothed[2].rect == a)
        #expect(abs(smoothed[1].rect.x - (0.1 + 0.3 + 0.1) / 3) < 1e-9)
        #expect(ClipEffects.trackTimes(start: 1, end: 1.6) == [1, 1.25, 1.5, 1.6])
        #expect(ClipEffect.Rect(x: 0.95, y: -0.2, width: 0.2, height: 0.3).clamped == .init(x: 0.8, y: 0, width: 0.2, height: 0.3))
    }

    @Test func overlaysFadeInsideTheirRange() {
        let title = ClipEffect(id: "fx-title-1", clipId: nil, kind: .title, start: 1, end: 3, text: "Day 1", position: .top)
        #expect(title.opacity(at: 0.99) == 0 && title.opacity(at: 3) == 0)
        #expect(title.opacity(at: 2) == 1)
        #expect(abs(title.opacity(at: 1.06) - 0.5) < 1e-9)
    }
}
