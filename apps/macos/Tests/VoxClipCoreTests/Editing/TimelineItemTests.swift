import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct TimelineItemTests {
    @Test func cutAnchorPlaysAtTheSeamAndRestoringMovesItBack() throws {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/story-clips/story-project.voxclip"))
        project.clipEffects = [ClipEffect(id: "sound", clipId: nil, kind: .sound, start: 1, end: 1.5)]
        let cut = EditPlan(sampleRate: 48_000, totalSamples: 144_000, kept: [
            .init(startSample: 0, endSample: 24_000), .init(startSample: 72_000, endSample: 144_000)
        ])
        let restored = EditPlan(sampleRate: 48_000, totalSamples: 144_000, kept: [.init(startSample: 0, endSample: 144_000)])
        let cutItem = try #require(TimelineItems.layout(project: project, plan: cut, scope: nil, axis: .edited).items.first { $0.id == .effect("sound") })
        let restoredItem = try #require(TimelineItems.layout(project: project, plan: restored, scope: nil, axis: .edited).items.first { $0.id == .effect("sound") })
        #expect(cutItem.editedIntervals == [TimeRange(start: 0.5, end: 1)])
        #expect(restoredItem.editedIntervals == [TimeRange(start: 1, end: 1.5)])
    }

    @Test func replayEditVectors() throws {
        let fixture = try load("edit-cases")
        #expect(fixture["cases"].array.count >= 345)
        for row in fixture["cases"].array {
            let label = Comment(rawValue: row["name"].string)
            do {
                let basis = fixture["bases"][row["base"].string]
                let project = try decode(basis.value)
                let edit = try command(row["edit"])
                let plan = plan(row["plan"], rate: fixture["sampleRate"].number)
                let scope = optional(row["scope"])
                let first = TimelineEdits.apply(edit, project: project, plan: plan, scope: scope)
                switch first {
                case .failure(let refusal):
                    #expect(refusal.copy == optional(row["refusal"]), label)
                case .success(let result):
                    #expect(result.undoName == optional(row["undo"]), label)
                    let expected = basis.object.merging(row["expected"].object) { _, changed in changed }.filter { $0.value != .null || basis.object[$0.key] == .null }
                    let snapshot = try decode(.object(expected))
                    #expect(result.project == snapshot, label)
                    let data = try JSONProjectStore.encode(result.project)
                    #expect(try JSONProjectStore.decode(data) == snapshot, label)
                    for key in ["clipEffects", "motionCues", "music", "media"] where row["expected"].object[key] != nil {
                        let fields = FixtureValue(expected[key] ?? .null)
                        let times = key == "music" ? fields.array.flatMap { gridTimes($0["segments"].value) } :
                            gridTimes(key == "media" ? fields["footage"].value : fields.value)
                        #expect(times.allSatisfy { abs($0 * plan.sampleRate - ($0 * plan.sampleRate).rounded()) < 1e-7 }, label)
                    }
                    if case .success(let replay) = TimelineEdits.apply(edit, project: project, plan: plan, scope: scope) {
                        #expect(replay.project == result.project && replay.undoName == result.undoName, label)
                    } else { Issue.record(Comment(rawValue: "Non-deterministic replay: " + row["name"].string)) }
                }
            } catch { Issue.record(error, label) }
        }
    }

    @Test func replayLayoutVectors() throws {
        let fixture = try load("layout-cases")
        #expect(fixture["cases"].array.count >= 11)
        for row in fixture["cases"].array {
            let label = Comment(rawValue: row["name"].string)
            let project = try decode(fixture["bases"][row["base"].string].value)
            let axis = try #require(TimelineAxis(rawValue: row["axis"].string))
            let plan = plan(row["plan"], rate: fixture["sampleRate"].number)
            let layout = TimelineItems.layout(project: project, plan: plan,
                                              scope: optional(row["scope"]), axis: axis,
                                              playhead: row["playhead"].isNull ? nil : row["playhead"].number)
            if !row["drop"].isNull {
                let time = row["drop"]["time"].number
                #expect(TimelineItems.sourceAnchor(at: time, axis: axis, plan: plan) == row["drop"]["anchor"].number, label)
                #expect(TimelineItems.dropHint(at: time, axis: axis, plan: plan) == optional(row["drop"]["hint"]), label)
            }
            for expected in row["items"].array {
                let id = try identity(expected["id"])
                let item = try #require(layout.items.first { $0.id == id }, label)
                #expect(item.kind == expected["kind"].string && item.lane.rawValue == expected["lane"].string, label)
                #expect(item.row == expected["row"].int && item.partID == optional(expected["part"]), label)
                #expect(item.sourceAnchor == expected["anchor"].number, label)
                #expect(item.editedIntervals == intervals(expected["edited"]) && item.axisIntervals == intervals(expected["axis"]), label)
                #expect(item.hidden == expected["hidden"].bool && item.reason == optional(expected["reason"]), label)
                #expect(item.marker == (expected["marker"].isNull ? nil : expected["marker"].number), label)
                #expect(item.seamNotches == expected["notches"].array.map(\.number), label)
            }
            if row["allItems"].bool { #expect(layout.items.count == row["items"].array.count, label) }
            for (lane, count) in row["rows"].object {
                #expect(layout.rowCounts[try #require(TimelineItemLane(rawValue: lane))] == FixtureValue(count).int, label)
            }
            for (key, present) in [("snaps", true), ("missing", false)] {
                for vector in row[key].array {
                    let values = vector.array
                    let kind = try #require(TimelineSnapTarget.Kind(rawValue: values[1].string))
                    let item = values[2].isNull ? nil : try identity(values[2])
                    #expect(layout.snapTargets.contains(.init(time: values[0].number, kind: kind, item: item)) == present, label)
                }
            }
        }
    }

    private func load(_ fixture: String) throws -> FixtureValue {
        FixtureValue(try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/timeline-edits/\(fixture).json")))
    }

    private func decode(_ value: JSONValue) throws -> Project { try JSONProjectStore.decode(JSONEncoder().encode(value)) }
    private func optional(_ value: FixtureValue) -> String? { value.isNull ? nil : value.string }

    private func identity(_ value: FixtureValue) throws -> TimelineItemID {
        let fields = value.array
        switch fields[0].string {
        case "effect": return .effect(fields[1].string)
        case "footage": return .footage(fields[1].string)
        case "motion": return .motion(fields[1].string)
        case "music": return .music(fields[1].string)
        case "clip": return .clip(fields[1].string)
        case "part": return .part(fields[1].string)
        case "contextDemo": return .contextDemo(fields[1].string)
        case "voice": return .voice(fields[1].string)
        default: throw TimelineEditRefusal("Unknown fixture identity")
        }
    }

    private func plan(_ value: FixtureValue, rate: Double) -> EditPlan {
        let kept = value["kept"].array.map { pair in
            MediaInterval(startSample: Int64(pair.array[0].int), endSample: Int64(pair.array[1].int))
        }
        let total = Int64(value["total"].int)
        return .init(sampleRate: rate, totalSamples: total, cuts: complement(kept.sorted { $0.startSample < $1.startSample }, total: total), kept: kept,
                     partSeams: value["seams"].array.map { Int64($0.int) })
    }

    private func intervals(_ value: FixtureValue) -> [TimeRange] {
        value.array.map { TimeRange(start: $0.array[0].number, end: $0.array[1].number) }
    }

    private func gridTimes(_ value: JSONValue) -> [Double] {
        let keys: Set<String> = ["start", "end", "sourceStart", "sourceEnd", "t", "anchorSeconds", "lengthSeconds",
                                 "songFromSeconds", "mediaOffsetSeconds", "fadeInSeconds", "fadeOutSeconds"]
        switch value {
        case .object(let fields): return fields.flatMap { key, value -> [Double] in
            if keys.contains(key), case .number(let seconds) = value { return [seconds] }
            return gridTimes(value)
        }
        case .array(let list): return list.flatMap(gridTimes)
        default: return []
        }
    }

    private func command(_ row: FixtureValue) throws -> TimelineEdit {
        func item() throws -> TimelineItemID { try identity(row["item"]) }
        let items = try row["items"].array.map(identity)
        let source = row["source"].number, db = row["db"].number, old = row["old"].number
        let edge = TimelineEdge(rawValue: row["edge"].string) ?? .start
        switch row["op"].string {
        case "move": return .move(items: items, toAnchor: source)
        case "nudge": return .nudge(items: items, by: row["unit"].string == "words" ? .words(row["count"].int) : .frames(row["count"].int))
        case "trim": return try .trim(item: item(), edge: edge, toSource: source)
        case "split": return .split(items: items, atSource: source)
        case "splitAll": return .splitAll(atSource: source)
        case "fade": return try .fade(item: item(), edge: edge, seconds: row["seconds"].number)
        case "setGain": return try .setGain(item: item(), db: db)
        case "setTrackGain": return .setTrackGain(track: row["track"].string, db: db)
        case "dipGain": return try .dipGain(item: item(), fromSource: row["fromSource"].number, toSource: row["toSource"].number, byDb: row["byDb"].number)
        case "addGainPoint": return try .addGainPoint(item: item(), atSource: source, db: db)
        case "moveGainPoint": return try .moveGainPoint(item: item(), from: old, toSource: source, db: db)
        case "removeGainPoint": return try .removeGainPoint(item: item(), at: old)
        case "slip": return try .slip(item: item(), bySeconds: row["seconds"].number)
        case "setLoop": return try .setLoop(item: item(), row["enabled"].bool)
        case "setDuck": return .setDuck(track: row["track"].string, db: db)
        case "duplicate": return .duplicate(items: items, toAnchor: row["source"].isNull ? nil : source)
        case "delete": return .delete(items: items)
        default: throw TimelineEditRefusal("Unknown vector command")
        }
    }
}
