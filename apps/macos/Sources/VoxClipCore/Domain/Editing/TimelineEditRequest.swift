import Foundation

public struct TimelineEditRequest: Sendable, Equatable {
    package static let maximum = 30
    let wire: JSONValue
    var operation: String { wire[ai: "op"].aiString ?? "" }

    init(_ wire: JSONValue) throws {
        self.wire = wire
        _ = try command(itemID: { .effect($0) }, time: { index, _ in Double(index) })
    }

    static func read(_ value: JSONValue) throws -> [Self] {
        guard case .array(let entries) = value, (1...maximum).contains(entries.count) else { throw invalid }
        return try entries.map(Self.init)
    }

    static func providerEdits(_ value: JSONValue) throws -> [Self] {
        try read(.array(value.aiArray.map { entry in
            guard let fields = entry.aiObject, let op = fields["op"]?.aiString else { return entry }
            let keys: [String: Set<String>] = ["move": ["toWord"], "nudge": ["frames", "words"], "trim": ["edge", "toWord"],
                "split": ["atWord"], "splitAll": ["atWord"], "fade": ["edge", "seconds"], "setGain": ["db"],
                "setTrackGain": ["track", "db"], "dipGain": ["fromSource", "toSource", "byDb"],
                "addGainPoint": ["atWord", "db"], "moveGainPoint": ["fromSeconds", "toWord", "db"],
                "removeGainPoint": ["atSeconds"], "slip": ["bySeconds"], "setLoop": ["enabled"], "setDuck": ["track", "db"],
                "duplicate": ["toWord"], "delete": []]
            var used = (keys[op] ?? []).union(["op"])
            if !["splitAll", "setDuck", "setTrackGain"].contains(op) {
                used.insert(fields["item"]?.aiString?.isEmpty == false ? "item" : "items")
            }
            if op == "nudge", fields["words"]?.aiInt != 0, fields["words"] != nil { used.remove("frames") }
            else if op == "nudge", fields["frames"] != nil { used.remove("words") }
            if op == "duplicate", (fields["toWord"]?.aiInt ?? -1) < 0 { used.remove("toWord") }
            return .object(fields.filter { used.contains($0.key) })
        }))
    }

    public func applying(to project: Project, scope: String?) throws -> (project: Project, undoName: String) {
        let plan = try RenderCallerInputs.editPlan(project: project, clipID: scope)
        let items = TimelineItems.layout(project: project, plan: plan, scope: scope, axis: .edited).items
        let words = project.transcript?.words ?? []
        let command = try command(itemID: { name in
            if let exact = items.first(where: { TimelineDecisions.id($0.id, project: project, scope: scope) == name }) { return exact.id }
            let matches = items.filter { $0.id.value == name }
            guard matches.count == 1, let match = matches.first else { throw TimelineEditRefusal("Select an item on this timeline.") }
            return match.id
        }, time: { index, end in
            guard words.indices.contains(index) else { throw TimelineEditRefusal("Enter a valid time.") }
            return end ? words[index].end : words[index].start
        })
        return try TimelineEdits.apply(command, project: project, plan: plan, scope: scope).get()
    }

    private static let invalid = HarnessError.invalid("Invalid timeline edit. Use an operation and its supported fields.")

    private func command(itemID: (String) throws -> TimelineItemID, time: (Int, Bool) throws -> Double) throws -> TimelineEdit {
        guard case .object(let fields) = wire else { throw Self.invalid }
        func check(_ required: Set<String>, optional: Set<String> = []) throws {
            let keys = Set(fields.keys).subtracting(["op"])
            guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)), !fields.values.contains(.null) else { throw Self.invalid }
        }
        func text(_ key: String) throws -> String {
            guard let value = fields[key]?.aiString, !value.isEmpty else { throw Self.invalid }
            return value
        }
        func number(_ key: String, unsigned: Bool = false) throws -> Double {
            guard let value = fields[key]?.aiDouble, value.isFinite, !unsigned || value >= 0 else { throw Self.invalid }
            return value
        }
        func integer(_ key: String, unsigned: Bool = false) throws -> Int {
            guard let value = fields[key]?.aiInt, !unsigned || value >= 0 else { throw Self.invalid }
            return value
        }
        func anchor(_ key: String, end: Bool = false) throws -> Double { try time(integer(key, unsigned: true), end) }
        func item() throws -> TimelineItemID { try itemID(text("item")) }
        func items(empty: Bool = false) throws -> [TimelineItemID] {
            let names: [String]
            if fields["item"] != nil { names = [try text("item")] }
            else {
                guard case .array(let list) = fields["items"], ((empty ? 0 : 1)...Self.maximum).contains(list.count) else { throw Self.invalid }
                names = list.compactMap(\.aiString)
                guard names.count == list.count, names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else { throw Self.invalid }
            }
            return try names.map(itemID)
        }
        func selection(_ required: Set<String>, optional: Set<String> = [], single: Bool = false) throws {
            try check(required.union(single && fields["item"] != nil ? ["item"] : ["items"]), optional: optional)
        }
        switch operation {
        case "move":
            try selection(["toWord"], single: true)
            return try .move(items: items(), toAnchor: anchor("toWord"))
        case "nudge":
            let unit = fields["frames"] == nil ? "words" : "frames"
            try selection([unit], single: true)
            let count = try integer(unit)
            guard Int32(exactly: count) != nil else { throw Self.invalid }
            return try .nudge(items: items(), by: unit == "frames" ? .frames(count) : .words(count))
        case "trim":
            try check(["item", "edge", "toWord"])
            guard let edge = try TimelineEdge(rawValue: text("edge")) else { throw Self.invalid }
            return try .trim(item: item(), edge: edge, toSource: anchor("toWord", end: edge == .end))
        case "split":
            try selection(["atWord"], single: true)
            return try .split(items: items(empty: true), atSource: anchor("atWord"))
        case "splitAll":
            try check(["atWord"])
            return try .splitAll(atSource: anchor("atWord"))
        case "fade":
            try check(["item", "edge", "seconds"])
            let edge = try text("edge")
            guard edge == "in" || edge == "out" else { throw Self.invalid }
            return try .fade(item: item(), edge: edge == "in" ? .start : .end, seconds: number("seconds", unsigned: true))
        case "setGain":
            try check(["item", "db"])
            return try .setGain(item: item(), db: number("db"))
        case "setTrackGain":
            try check(["track", "db"])
            return try .setTrackGain(track: text("track"), db: number("db"))
        case "dipGain":
            try check(["item", "fromSource", "toSource", "byDb"])
            return try .dipGain(item: item(), fromSource: number("fromSource", unsigned: true), toSource: number("toSource", unsigned: true), byDb: number("byDb"))
        case "addGainPoint":
            try check(["item", "atWord", "db"])
            return try .addGainPoint(item: item(), atSource: anchor("atWord"), db: number("db"))
        case "moveGainPoint":
            try check(["item", "fromSeconds", "toWord", "db"])
            return try .moveGainPoint(item: item(), from: number("fromSeconds", unsigned: true), toSource: anchor("toWord"), db: number("db"))
        case "removeGainPoint":
            try check(["item", "atSeconds"])
            return try .removeGainPoint(item: item(), at: number("atSeconds", unsigned: true))
        case "slip":
            try check(["item", "bySeconds"])
            return try .slip(item: item(), bySeconds: number("bySeconds"))
        case "setLoop":
            try check(["item", "enabled"])
            guard case .bool(let enabled) = fields["enabled"] else { throw Self.invalid }
            return try .setLoop(item: item(), enabled)
        case "setDuck":
            try check(["track", "db"])
            return try .setDuck(track: text("track"), db: number("db"))
        case "duplicate":
            try selection([], optional: ["toWord"], single: true)
            return try .duplicate(items: items(), toAnchor: fields["toWord"] == nil ? nil : anchor("toWord"))
        case "delete":
            try selection([], single: true)
            return try .delete(items: items())
        default: throw Self.invalid
        }
    }
}
