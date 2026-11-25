public struct TimelineEditUndo: Sendable {
    private let before: Project
    private let after: Project

    public init(before: Project, after: Project) {
        self.before = before; self.after = after
    }

    public func restoring(in project: Project) throws -> Project {
        var result = project
        result.clipEffects = try restore(before.clipEffects, after.clipEffects, project.clipEffects, id: \.id)
        result.media.footage = try restore(before.media.footage, after.media.footage, project.media.footage, id: \.id)
        result.motionCues = try restore(before.motionCues, after.motionCues, project.motionCues, id: \.id)
        result.music = try restore(before.music, after.music, project.music, id: \.id)
        result.edits.clips = try restore(before.edits.clips, after.edits.clips, project.edits.clips, id: \.id)
        if before.edits.activeClipId != after.edits.activeClipId && project.edits.activeClipId == after.edits.activeClipId {
            result.edits.activeClipId = before.edits.activeClipId
        }
        _ = try JSONProjectStore.encode(result)
        return result
    }

    private func restore<Value: Equatable>(_ before: [Value], _ after: [Value], _ current: [Value], id: KeyPath<Value, String>) throws -> [Value] {
        var result = current
        for value in after where !before.contains(value) {
            guard let index = result.firstIndex(where: { $0[keyPath: id] == value[keyPath: id] }), result[index] == value else {
                throw TimelineEditRefusal("This item has changed since Ask Claude edited it.")
            }
            if let original = before.first(where: { $0[keyPath: id] == value[keyPath: id] }) { result[index] = original }
            else { result.remove(at: index) }
        }
        for (index, value) in before.enumerated() where !after.contains(where: { $0[keyPath: id] == value[keyPath: id] }) {
            guard !result.contains(where: { $0[keyPath: id] == value[keyPath: id] }) else {
                throw TimelineEditRefusal("This item has changed since Ask Claude edited it.")
            }
            result.insert(value, at: min(index, result.count))
        }
        return result
    }
}
