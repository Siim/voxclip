import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct ClipPlanEffectTests {
    @Test func sharedFootageEntriesAreRecognised() throws {
        let vectors = try JSONDecoder().decode([JSONValue].self, from: FixtureLoader.data("fixtures/clip-effects/footage-cases.json"))
        for raw in vectors {
            let fields = try #require(raw.aiObject)
            let entry = ClipPlanEffect.read(.object(fields.filter { !["duration", "placement", "invalid"].contains($0.key) }))
            #expect((entry == nil) == (fields["invalid"] == .bool(true)))
            let operation = entry?.operation(id: "extra", clipID: "clip", scope: 0...1,
                anchor: { Double($0) / 2..<(Double($0) / 2 + 0.5) }, stickers: [],
                sources: ["demo": fields["duration"]?.aiDouble ?? 0])
            #expect((operation != nil) == (fields["placement"] == .bool(true)))
            if let entry { #expect(try JSONDecoder().decode(ClipPlanEffect.self, from: JSONEncoder().encode(entry)) == entry) }
        }
    }

    private struct Vectors: Decodable {
        struct Word: Decodable { let start: Double; let end: Double }
        struct Vector: Decodable {
            struct Placement: Decodable {
                let start: Double; let end: Double; let scales: [Double]?
                let overlayKind: String?; let position: String?; let animation: String?
            }
            let id: String; let entry: JSONValue; let placement: Placement?; let cutWords: [Int]?; let invalid: Bool?
        }
        let words: [Word]; let cases: [Vector]
    }

    @Test func sharedVectorsReplayAsSourceTimeMotionAndOverlays() throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/clip-effects/clip-plan-effect-cases.json"))
        for vector in vectors.cases {
            let entry = ClipPlanEffect.read(vector.entry)
            #expect((entry == nil) == (vector.invalid == true), "\(vector.id)")
            let operation = entry?.operation(id: "plan-fx", clipID: "clip", scope: 0...(vectors.words.count - 1),
                anchor: { index in
                    guard vectors.words.indices.contains(index) else { return nil }
                    return vectors.words[index].start..<vectors.words[index].end
                }, isCut: { (vector.cutWords ?? []).contains($0) }, stickers: ["🔥"])
            #expect((operation == nil) == (vector.placement == nil), "\(vector.id)")
            guard let operation, let expected = vector.placement else { continue }
            #expect(operation.reason == entry?.reason)
            switch operation.action {
            case .motion(let cue):
                #expect(cue.sourceStart == expected.start && cue.sourceEnd == expected.end)
                #expect(cue.keyframes.map(\.scale) == expected.scales)
            case .effect(let effect):
                #expect(effect.start == expected.start && effect.end == expected.end)
                #expect(effect.kind.rawValue == expected.overlayKind && effect.position?.rawValue == expected.position)
                #expect(effect.animation?.rawValue == expected.animation)
                #expect(try JSONDecoder().decode(ClipEffect.self, from: JSONEncoder().encode(effect)) == effect)
            default: Issue.record("unexpected operation for \(vector.id)")
            }
        }
    }
}
