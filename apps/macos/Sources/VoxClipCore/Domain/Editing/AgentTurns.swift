import Foundation

public enum AgentTurns {
    public enum Refusal: Error, Equatable {
        case wrongProject, unknownTurn, unknownChange, notPending, unavailable(String)
        case invalidPatch(String), conflict(String), confirmationRequired, stalePlan, threadFull
    }

    public static let prunedReason = "This turn is too old to undo from the chat. Undo its changes by hand, or use File › Revert To."

    public struct Dependency: Equatable, Sendable {
        public var turnId: String
        public var changeId: String?
        public var undoName: String
        public var target: String?
    }

    public struct UndoPlan: Equatable, Sendable {
        public let turnId: String
        public let changeId: String?
        public let dependants: [Dependency]
        public let conflictingPaths: [String]
        public var requiresConfirmation: Bool { !dependants.isEmpty || !conflictingPaths.isEmpty }
        fileprivate let projectId: String
        fileprivate let checkpoint: [AgentPatch]
    }

    public static func change(from before: Project, to after: Project, id: String, label: String, undoName: String) throws -> AgentChange? {
        let patch = try diff(before, after)
        return patch.isEmpty ? nil : AgentChange(id: id, label: label, undoName: undoName, patch: patch)
    }

    public static func record(_ turn: AgentTurn, in project: Project, threadId: String) throws -> Project {
        var thread = project.agentThread ?? AgentThread(id: threadId)
        guard thread.id == threadId else { throw Refusal.wrongProject }
        var turn = turn
        turn.summary = String(String.UnicodeScalarView(turn.summary.unicodeScalars.prefix(600)))
        turn.steps = Array(turn.steps.suffix(24))
        if let index = thread.turns.firstIndex(where: { $0.id == turn.id }) {
            guard index == thread.turns.count - 1, thread.turns[index].state == .running else { throw Refusal.notPending }
            thread.turns[index] = turn
        } else {
            thread.turns.append(turn)
        }
        return try finish(project, thread)
    }

    public static func keep(_ project: Project, turnId: String) throws -> Project {
        var thread = try thread(in: project)
        let index = try index(of: turnId, in: thread)
        guard thread.turns[index].isPending else { throw Refusal.notPending }
        markKept(&thread.turns[index])
        return try finish(project, thread)
    }

    public static func keepAll(_ project: Project) throws -> Project {
        guard var thread = project.agentThread else { return project }
        for index in thread.turns.indices where thread.turns[index].isPending { markKept(&thread.turns[index]) }
        return try finish(project, thread)
    }

    public static func recoveringAfterRelaunch(_ project: Project) -> Project {
        var project = project
        guard var thread = project.agentThread else { return project }
        for index in thread.turns.indices where thread.turns[index].state == .running { thread.turns[index].state = .stopped }
        project.agentThread = thread
        return project
    }

    public static func logHandEdit(from before: Project, to after: Project, undoName: String, target: String, at: Date) throws -> Project {
        guard var thread = before.agentThread, let last = thread.turns.indices.last else { return after }
        let watched = thread.turns.flatMap(\.changes).filter { $0.state == .applied }.flatMap(\.patch)
        let patch = try diff(before, after).filter { item in watched.contains { AgentPatchPath.overlaps($0, item) } }
        guard !patch.isEmpty else { return after }
        thread.turns[last].events.append(.init(kind: .hand, undoName: undoName, target: target, at: at, patch: patch))
        return try finish(after, thread)
    }

    public static func planUndo(_ project: Project, turnId: String, changeId: String? = nil) throws -> UndoPlan {
        try prepareUndo(project, turnId: turnId, changeId: changeId).plan
    }

    public static func undo(_ project: Project, plan: UndoPlan, confirmed: Bool = false) throws -> Project {
        let prepared = try prepareUndo(project, turnId: plan.turnId, changeId: plan.changeId)
        guard prepared.plan == plan else { throw Refusal.stalePlan }
        guard confirmed || !plan.requiresConfirmation else { throw Refusal.confirmationRequired }
        return try finish(Self.project(from: prepared.document, basedOn: project), prepared.thread)
    }

    public static func redo(_ project: Project, turnId: String, changeId: String) throws -> Project {
        var thread = try thread(in: project)
        let turnIndex = try index(of: turnId, in: thread)
        guard let changeIndex = thread.turns[turnIndex].changes.firstIndex(where: { $0.id == changeId }) else { throw Refusal.unknownChange }
        let change = thread.turns[turnIndex].changes[changeIndex]
        guard !change.patch.isEmpty else { throw Refusal.unavailable(prunedReason) }
        guard change.state == .undone else { throw Refusal.unknownChange }
        var wire = try document(project)
        for patch in change.patch { try AgentPatchPath.apply(patch, to: &wire, reverse: false) }
        thread.turns[turnIndex].changes[changeIndex].state = .applied
        refreshState(&thread.turns[turnIndex])
        return try finish(Self.project(from: wire, basedOn: project), thread)
    }

    public static func revise(_ project: Project, proposed: Project, turnId: String, revisionId: String,
                              changeId: String, label: String, undoName: String) throws -> Project {
        var thread = try thread(in: project)
        let index = try index(of: turnId, in: thread)
        guard thread.turns[index].isPending else { throw Refusal.notPending }
        let prepared = try prepareUndo(project, turnId: turnId, changeId: nil)
        guard !prepared.plan.requiresConfirmation else { throw Refusal.confirmationRequired }
        let basis = try Self.project(from: prepared.document, basedOn: project)
        let revised = try change(from: basis, to: proposed, id: changeId, label: label, undoName: undoName)
        let revisionDelta = try diff(project, proposed)
        let later = thread.turns.dropFirst(index + 1).flatMap(\.changes).filter { $0.state == .applied }.flatMap(\.patch)
        if let conflict = revisionDelta.first(where: { item in later.contains { AgentPatchPath.overlaps($0, item) } }) {
            throw Refusal.conflict(conflict.path)
        }
        thread.turns[index].changes = revised.map { [$0] } ?? []
        thread.turns[index].revisionOf = revisionId
        thread.turns[index].state = .pending
        return try finish(proposed, thread)
    }

    private struct Action {
        var turn: Int
        var index: Int
        var change: Bool
        var patch: [AgentPatch]
        var dependency: Dependency?
    }

    private static func prepareUndo(_ project: Project, turnId: String, changeId: String?) throws -> (plan: UndoPlan, document: JSONValue, thread: AgentThread) {
        var thread = try thread(in: project)
        let start = try index(of: turnId, in: thread)
        let target = thread.turns[start]
        let selected = target.changes.indices.filter { index in
            let change = target.changes[index]
            return change.state == .applied && (changeId == nil || change.id == changeId)
        }
        guard let first = selected.first else { throw Refusal.unknownChange }
        guard selected.allSatisfy({ !target.changes[$0].patch.isEmpty }) else { throw Refusal.unavailable(prunedReason) }
        var paths = selected.flatMap { target.changes[$0].patch }
        var actions: [Action] = []
        for turnIndex in start..<thread.turns.count {
            let turn = thread.turns[turnIndex]
            for (index, change) in turn.changes.enumerated() where change.state == .applied {
                if turnIndex == start && index < first { continue }
                let own = turnIndex == start && selected.contains(index)
                guard own || change.patch.contains(where: { item in paths.contains { AgentPatchPath.overlaps($0, item) } }) else { continue }
                let dependency = own ? nil : Dependency(turnId: turn.id, changeId: change.id, undoName: change.undoName, target: nil)
                actions.append(Action(turn: turnIndex, index: index, change: true, patch: change.patch, dependency: dependency))
                if !own { paths.append(contentsOf: change.patch) }
            }
            for (index, event) in turn.events.enumerated() where event.kind == .hand {
                let relevant = (event.patch ?? []).filter { item in paths.contains { AgentPatchPath.overlaps($0, item) } }
                if !relevant.isEmpty {
                    let dependency = Dependency(turnId: turn.id, changeId: nil, undoName: event.undoName, target: event.target)
                    actions.append(Action(turn: turnIndex, index: index, change: false, patch: relevant, dependency: dependency))
                    paths.append(contentsOf: relevant)
                }
            }
        }
        var wire = try document(project)
        var conflicts: [String] = []
        for action in actions.reversed() {
            for patch in action.patch.reversed() {
                do { try AgentPatchPath.apply(patch, to: &wire, reverse: true) }
                catch Refusal.conflict {
                    try AgentPatchPath.apply(patch, to: &wire, reverse: true, force: true)
                    if !conflicts.contains(patch.path) { conflicts.append(patch.path) }
                }
            }
            if action.change {
                if thread.turns[action.turn].state == .kept { thread.turns[action.turn].wasKept = true }
                thread.turns[action.turn].changes[action.index].state = .undone
            } else {
                let remaining = thread.turns[action.turn].events[action.index].patch?.filter { !action.patch.contains($0) } ?? []
                if remaining.isEmpty { thread.turns[action.turn].events.remove(at: action.index) }
                else { thread.turns[action.turn].events[action.index].patch = remaining }
            }
        }
        for turnIndex in Set(actions.filter(\.change).map(\.turn)) { refreshState(&thread.turns[turnIndex]) }
        return (UndoPlan(turnId: turnId, changeId: changeId, dependants: actions.compactMap(\.dependency), conflictingPaths: conflicts,
                         projectId: project.id, checkpoint: actions.flatMap(\.patch)), wire, thread)
    }

    private static func markKept(_ turn: inout AgentTurn) {
        turn.wasKept = true
        if turn.state != .partial { turn.state = .kept }
    }

    private static func refreshState(_ turn: inout AgentTurn) {
        let applied = turn.changes.filter { $0.state == .applied }.count
        if applied == 0 { turn.state = .undone }
        else if applied != turn.changes.count { turn.state = .partial }
        else { turn.state = turn.wasKept == true ? .kept : .pending }
    }

    private static func thread(in project: Project) throws -> AgentThread {
        guard let thread = project.agentThread else { throw Refusal.unknownTurn }
        return thread
    }

    private static func index(of id: String, in thread: AgentThread) throws -> Int {
        guard let index = thread.turns.firstIndex(where: { $0.id == id }) else { throw Refusal.unknownTurn }
        return index
    }

    private static func finish(_ project: Project, _ source: AgentThread) throws -> Project {
        var thread = source
        while thread.turns.count > AgentThreadWire.maxTurns {
            guard let index = thread.turns.firstIndex(where: { !$0.isPending && $0.state != .running }) else { throw Refusal.threadFull }
            thread.turns.remove(at: index)
        }
        let kept = thread.turns.indices.filter { thread.turns[$0].state == .kept || thread.turns[$0].wasKept == true }
        for index in kept.dropLast(min(kept.count, AgentThreadWire.maxKeptCheckpoints)) { prune(&thread.turns[index]) }
        for index in thread.turns.indices where try AgentThreadWire.size(thread) > AgentThreadWire.maxBytes {
            thread.turns[index].steps = []
            if !thread.turns[index].isPending && thread.turns[index].state != .running { prune(&thread.turns[index]) }
        }
        guard try AgentThreadWire.size(thread) <= AgentThreadWire.maxBytes else { throw Refusal.threadFull }
        var result = project
        result.agentThread = thread
        result = try ProjectMigrations.forWriting(result)
        _ = try ProjectJSON.encode(result)
        return result
    }

    private static func prune(_ turn: inout AgentTurn) {
        for index in turn.changes.indices { turn.changes[index].patch = [] }
        for index in turn.events.indices { turn.events[index].patch = nil }
    }

    private static func diff(_ before: Project, _ after: Project) throws -> [AgentPatch] {
        guard before.id == after.id else { throw Refusal.wrongProject }
        let old = try ProjectValidation.map(document(before)), new = try ProjectValidation.map(document(after))
        var patches: [AgentPatch] = []
        for root in AgentPatchPath.roots.sorted() {
            if root == "voiceLab" {
                let older = try ProjectValidation.map(old[root]), newer = try ProjectValidation.map(new[root])
                for key in AgentPatchPath.voiceUses.sorted() { AgentPatchPath.diff(older[key], newer[key], path: "/\(root)/\(key)", into: &patches) }
            } else {
                AgentPatchPath.diff(old[root], new[root], path: "/\(root)", into: &patches)
            }
        }
        if let invalid = patches.first(where: { !AgentPatchPath.isValid($0) }) { throw Refusal.invalidPatch(invalid.path) }
        return patches
    }

    private static func document(_ project: Project) throws -> JSONValue {
        var project = project.schemaVersion < 4 ? try ContextDemoProject.upgradeToV4(project) : project
        project.agentThread = nil
        let data = try ProjectJSON.encoder().encode(project)
        var wire = try ProjectValidation.map(ProjectJSON.decoder().decode(JSONValue.self, from: data))
        for root in AgentPatchPath.optionalCollections where wire[root] == nil { wire[root] = .array([]) }
        return .object(wire)
    }

    private static func project(from wire: JSONValue, basedOn basis: Project) throws -> Project {
        func object(_ data: Data) throws -> [String: Any] {
            guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Refusal.invalidPatch("/")
            }
            return fields
        }
        var project = basis
        project.agentThread = AgentThread(id: "checkpoint")
        var original = try object(ProjectJSON.encoder().encode(project))
        let edited = try object(ProjectJSON.encoder().encode(wire))
        for key in AgentPatchPath.roots where key != "voiceLab" {
            original[key] = AgentPatchPath.optionalCollections.contains(key) && (edited[key] as? [Any])?.isEmpty == true ? nil : edited[key]
        }
        if var voice = original["voiceLab"] as? [String: Any], let uses = edited["voiceLab"] as? [String: Any] {
            for key in AgentPatchPath.voiceUses { voice[key] = uses[key] }
            original["voiceLab"] = voice
        }
        return try ProjectJSON.decode(JSONSerialization.data(withJSONObject: original))
    }
}
