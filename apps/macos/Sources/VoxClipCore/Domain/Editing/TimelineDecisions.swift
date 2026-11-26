import Foundation

public enum TimelineDecisions {
    public static func read(project: Project, scope: String?) throws -> JSONValue {
        let plan = try RenderCallerInputs.editPlan(project: project, clipID: scope)
        let layout = TimelineItems.layout(project: project, plan: plan, scope: scope, axis: .edited)
        let clock = TimelineClock(project, plan: plan, scope: scope)
        let spans = TimelineEntries(project, clock: clock).values
        let track = project.music.first { $0.clipId == scope }
        let music = track.map { $0.segments ?? clock.bed($0).map { [$0] } ?? [] } ?? []
        let words = project.transcript?.words ?? []
        func word(at time: Double, end: Bool = false) -> JSONValue {
            let index = end ? words.lastIndex { $0.start < time } : words.firstIndex { $0.end > time }
            return index.map { .number(Double($0)) } ?? .null
        }
        func number(_ value: Double?) -> JSONValue { value.map(JSONValue.number) ?? .null }
        func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        func shape(fadeIn: Double?, fadeOut: Double?, gainDb: Double? = nil, points: [GainPoint]? = nil) -> [String: JSONValue] {
            ["fadeIn": number(fadeIn), "fadeOut": number(fadeOut), "gainDb": number(gainDb),
             "gainPoints": .array((points ?? []).map { .object(["t": .number($0.t), "db": .number($0.db)]) })]
        }
        let items: [JSONValue] = layout.items.map { item in
            var fields: [String: JSONValue] = [:]
            var paid = false
            switch item.id {
            case .effect(let id):
                if let effect = project.clipEffects.first(where: { $0.id == id }) {
                    fields = shape(fadeIn: effect.fadeInSeconds, fadeOut: effect.fadeOutSeconds, gainDb: effect.gainDb, points: effect.gainPoints)
                    fields["soundFrom"] = number(effect.mediaOffsetSeconds)
                    fields["text"] = string(effect.text)
                    paid = effect.kind == .illustration
                }
            case .footage(let id):
                if let footage = project.media.footage.first(where: { $0.id == id }) {
                    fields = shape(fadeIn: footage.fadeInSeconds, fadeOut: footage.fadeOutSeconds)
                    fields["mediaFrom"] = .number(footage.footage.start)
                }
            case .music(let id):
                if let segment = music.first(where: { $0.id == id }), let track {
                    fields = shape(fadeIn: segment.fadeInSeconds, fadeOut: segment.fadeOutSeconds, gainDb: segment.gainDb, points: segment.gainPoints)
                    fields["track"] = .string(track.id)
                    fields["duckDb"] = .number(track.duckDb ?? (track.ducking ? -12 : 0))
                    fields["songFrom"] = .number(segment.songFromSeconds)
                    fields["lengthSeconds"] = .number(segment.lengthSeconds)
                    fields["loop"] = .bool(segment.loop)
                    paid = track.source == .generated
                }
            case .voice: paid = true
            default: break
            }
            let span = spans.first { $0.id == item.id }?.span
            let end = span?.end ?? item.sourceAnchor
            return .object(["id": .string(id(item.id, project: project, scope: scope)), "kind": .string(item.kind),
                            "lane": .string(item.lane.rawValue), "row": .number(Double(item.row)), "partId": string(item.partID),
                            "sourceAnchor": .number(item.sourceAnchor), "startWord": word(at: item.sourceAnchor), "endWord": word(at: end, end: true),
                            "editedIntervals": .array(item.editedIntervals.map { .object(["start": .number($0.start), "end": .number($0.end)]) }),
                            "hidden": .bool(item.hidden), "marker": number(item.marker), "reason": string(item.reason),
                            "seamNotches": .array(item.seamNotches.map(JSONValue.number)), "paid": .bool(paid), "shape": .object(fields)])
        }
        return .object(["items": .array(items), "rowCounts": .object(Dictionary(uniqueKeysWithValues: layout.rowCounts.map { ($0.key.rawValue, .number(Double($0.value))) })),
                        "snapTargets": .array(layout.snapTargets.map { target in
                            .object(["time": .number(target.time), "kind": .string(target.kind.rawValue),
                                     "item": string(target.item.map { id($0, project: project, scope: scope) })])
                        })])
    }

    static func id(_ item: TimelineItemID, project: Project, scope: String?) -> String {
        switch item {
        case .effect(let id): "effect:\(id)"
        case .footage(let id): "footage:\(id)"
        case .motion(let id): "motion:\(id)"
        case .music(let id): "music:\(project.music.first { $0.clipId == scope }?.id ?? "")/\(id)"
        case .clip(let id): "clip:\(id)"
        case .part(let id): "part:\(id)"
        case .contextDemo(let id): "contextDemo:\(id)"
        case .voice(let id): "voice:\(id)"
        }
    }
}
