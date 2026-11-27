import Foundation

enum AgentPatchPath {
    enum Token: Equatable { case key(String), member(String) }
    static let roots: Set<String> = ["edits", "captions", "clipStyle", "clipControls", "clipEffects", "music", "motionCues", "captionTranslations", "voiceLab", "export"]
    static let optionalCollections: Set<String> = ["clipControls", "clipEffects", "music", "motionCues", "captionTranslations"]
    static let voiceUses: Set<String> = ["segments", "cleanAudio", "wholeClipRevoices"]

    static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            .replacingOccurrences(of: "[", with: "~2").replacingOccurrences(of: "]", with: "~3")
    }

    static func unescape(_ string: String) -> String? {
        let decoded = string.replacingOccurrences(of: "~3", with: "]").replacingOccurrences(of: "~2", with: "[")
            .replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        return escape(decoded) == string ? decoded : nil
    }

    static func tokens(_ path: String) -> [Token]? {
        guard path.hasPrefix("/") else { return nil }
        var result: [Token] = []
        for component in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let components = component.components(separatedBy: "[id=")
            guard let key = unescape(components[0]), !key.isEmpty else { return nil }
            result.append(.key(key))
            if components.count > 1 {
                guard components.count == 2, components[1].hasSuffix("]"),
                      let id = unescape(String(components[1].dropLast())), !id.isEmpty else { return nil }
                result.append(.member(id))
            }
        }
        guard result.count <= 40, case .key(let root) = result.first, roots.contains(root) else { return nil }
        if root == "voiceLab" {
            guard result.count > 1, case .key(let name) = result[1], voiceUses.contains(name) else { return nil }
        }
        return result
    }

    static func id(_ item: JSONValue) -> String? {
        guard case .object(let object) = item, case .string(let id) = object["id"], !id.isEmpty else { return nil }
        return id
    }

    static func isValid(_ patch: AgentPatch) -> Bool {
        guard let tokens = tokens(patch.path), patch.beforeMissing != false, patch.afterMissing != false,
              patch.beforeMissing != true || patch.before == .null, patch.afterMissing != true || patch.after == .null,
              patch.before != patch.after || patch.beforeMissing != patch.afterMissing else { return false }
        if case .member(let member) = tokens.last {
            let addition = patch.beforeMissing == true && patch.afterMissing != true && id(patch.after) == member &&
                patch.beforeIndex == nil && (patch.afterIndex ?? -1) >= 0
            let removal = patch.afterMissing == true && patch.beforeMissing != true && id(patch.before) == member &&
                patch.afterIndex == nil && (patch.beforeIndex ?? -1) >= 0
            return (addition || removal) && patch.previousId != member && patch.nextId != member
        }
        let noPosition = patch.beforeIndex == nil && patch.afterIndex == nil && patch.previousId == nil && patch.nextId == nil
        if tokens.last == .key("@order") {
            guard case .array(let before) = patch.before, case .array(let after) = patch.after else { return false }
            return noPosition && before.allSatisfy { if case .string(let value) = $0 { return !value.isEmpty }; return false } &&
                Set(before).count == before.count && after.count == before.count && Set(before) == Set(after)
        }
        if tokens.last == .key("id"), case .member = tokens.dropLast().last { return false }
        return noPosition
    }

    static func overlaps(_ first: AgentPatch, _ second: AgentPatch) -> Bool {
        guard let left = tokens(first.path), let right = tokens(second.path) else { return false }
        if left.starts(with: right) || right.starts(with: left) { return true }
        func orderTouchesMembership(_ order: [Token], _ member: [Token]) -> Bool {
            if order.last == .key("@order"), case .member = member.last { return order.dropLast() == member.dropLast() }
            return false
        }
        return orderTouchesMembership(left, right) || orderTouchesMembership(right, left)
    }

    static func diff(_ before: JSONValue?, _ after: JSONValue?, path: String, into patches: inout [AgentPatch]) {
        guard before != after else { return }
        if case .object(let old) = before, case .object(let new) = after {
            for key in Set(old.keys).union(new.keys).sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                diff(old[key], new[key], path: "\(path)/\(escape(key))", into: &patches)
            }
        } else if case .array(let old) = before, case .array(let new) = after,
                  let oldIDs = identities(old), let newIDs = identities(new) {
            let removed = Set(oldIDs).subtracting(newIDs), added = Set(newIDs).subtracting(oldIDs)
            let oldPositions = Dictionary(uniqueKeysWithValues: oldIDs.enumerated().map { ($0.element, $0.offset) })
            var order = oldIDs
            for index in old.indices.reversed() where removed.contains(oldIDs[index]) {
                let id = oldIDs[index]
                patches.append(AgentPatch(path: "\(path)[id=\(escape(id))]", before: old[index], after: .null, afterMissing: true,
                                          beforeIndex: index, previousId: index > 0 ? order[index - 1] : nil,
                                          nextId: index + 1 < order.count ? order[index + 1] : nil))
                order.remove(at: index)
            }
            for index in new.indices {
                let id = newIDs[index], member = "\(path)[id=\(escape(id))]"
                if added.contains(id) {
                    let position = min(index, order.count)
                    patches.append(AgentPatch(path: member, before: .null, after: new[index], beforeMissing: true,
                                              afterIndex: position, previousId: position > 0 ? order[position - 1] : nil,
                                              nextId: position < order.count ? order[position] : nil))
                    order.insert(id, at: position)
                } else if let oldIndex = oldPositions[id] {
                    diff(old[oldIndex], new[index], path: member, into: &patches)
                }
            }
            if order != newIDs {
                patches.append(AgentPatch(path: "\(path)/@order", before: .array(order.map(JSONValue.string)), after: .array(newIDs.map(JSONValue.string))))
            }
        } else {
            patches.append(AgentPatch(path: path, before: before ?? .null, after: after ?? .null,
                                      beforeMissing: before == nil ? true : nil, afterMissing: after == nil ? true : nil))
        }
    }

    private static func identities(_ values: [JSONValue]) -> [String]? {
        let ids = values.compactMap(id)
        return ids.count == values.count && Set(ids).count == ids.count ? ids : nil
    }

    static func apply(_ patch: AgentPatch, to document: inout JSONValue, reverse: Bool, force: Bool = false) throws {
        guard isValid(patch), let tokens = tokens(patch.path) else { throw AgentTurns.Refusal.invalidPatch(patch.path) }
        let before = patch.beforeMissing == true ? nil : patch.before
        let after = patch.afterMissing == true ? nil : patch.after
        let expected = reverse ? after : before, desired = reverse ? before : after
        func check(_ actual: JSONValue?) throws {
            if !force && actual != expected { throw AgentTurns.Refusal.conflict(patch.path) }
        }
        func replace(_ value: JSONValue?, _ remaining: ArraySlice<Token>) throws -> JSONValue? {
            guard let token = remaining.first else { try check(value); return desired }
            let tail = remaining.dropFirst()
            switch (token, value) {
            case (.key("@order"), .array(let items)) where tail.isEmpty:
                guard let ids = identities(items), case .array(let wanted) = desired else { break }
                try check(.array(ids.map(JSONValue.string)))
                let lookup = Dictionary(uniqueKeysWithValues: zip(ids.map(JSONValue.string), items))
                let reordered = wanted.compactMap { lookup[$0] }
                if reordered.count == items.count && wanted.count == items.count { return .array(reordered) }
            case (.key(let key), .object(var object)):
                if tail.isEmpty || object[key] != nil {
                    object[key] = try replace(object[key], tail)
                    return .object(object)
                }
            case (.member(let member), .array(var items)):
                guard let ids = identities(items) else { break }
                if let index = ids.firstIndex(of: member) {
                    if let result = try replace(items[index], tail) { items[index] = result } else { items.remove(at: index) }
                    return .array(items)
                }
                if tail.isEmpty, let inserted = try replace(nil, tail), let index = reverse ? patch.beforeIndex : patch.afterIndex {
                    let next = patch.nextId.flatMap { ids.firstIndex(of: $0) }
                    let previous = patch.previousId.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 }
                    items.insert(inserted, at: next ?? previous ?? min(index, items.count))
                    return .array(items)
                }
            default: break
            }
            throw AgentTurns.Refusal.conflict(patch.path)
        }
        guard let result = try replace(document, tokens[...]) else { throw AgentTurns.Refusal.invalidPatch(patch.path) }
        document = result
    }
}
