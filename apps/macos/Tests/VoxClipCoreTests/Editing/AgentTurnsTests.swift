import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct AgentTurnsTests {
    private static let at = Date(timeIntervalSince1970: 1_795_790_000)

    private struct PatchCase: Decodable {
        let name: String
        let before: JSONValue?
        let after: JSONValue
        let patch: [AgentPatch]
    }

    private struct UndoCase: Decodable {
        struct Turn: Decodable {
            struct Edit: Decodable { let id: String; let set: JSONValue }
            struct Hand: Decodable { let set: JSONValue; let target: String }
            let id: String
            let changes: [Edit]
            let hand: Hand?
        }
        let name: String
        let turns: [Turn]
        let unlogged: JSONValue?
        let turnId: String
        let changeId: String?
        let redo: Bool?
        let dependants: [String]
        let conflicts: [String]?
        let states: [AgentTurn.State]
        let expected: JSONValue
    }

    @Test func sharedPatchCases() throws {
        let cases = try FixtureLoader.decode([PatchCase].self, at: "fixtures/agent-chat/patch-cases.json")
        let base = try Self.base()
        for item in cases {
            let before = try item.before.map { try Self.setting($0, in: base) } ?? base
            let after = try Self.setting(item.after, in: before)
            let change = try AgentTurns.change(from: before, to: after, id: "change", label: item.name, undoName: "Edit clip")
            #expect(change?.patch ?? [] == item.patch, "\(item.name)")
            guard let change else { continue }
            let recorded = try Self.record("t1", [change], in: after)
            let undone = try AgentTurns.undo(recorded, plan: AgentTurns.planUndo(recorded, turnId: "t1", changeId: "change"))
            #expect(try Self.editingBytes(undone) == Self.editingBytes(before), "\(item.name)")
            #expect(try Self.editingBytes(AgentTurns.redo(undone, turnId: "t1", changeId: "change")) == Self.editingBytes(after), "\(item.name)")
        }
    }

    @Test func sharedUndoCases() throws {
        let cases = try FixtureLoader.decode([UndoCase].self, at: "fixtures/agent-chat/undo-cases.json")
        let base = try Self.base()
        for item in cases {
            var project = base
            for turn in item.turns {
                var changes: [AgentChange] = []
                for edit in turn.changes {
                    let after = try Self.setting(edit.set, in: project)
                    changes.append(try #require(try AgentTurns.change(from: project, to: after, id: edit.id, label: edit.id, undoName: edit.id)))
                    project = after
                }
                project = try Self.record(turn.id, changes, in: project)
                if let hand = turn.hand {
                    project = try AgentTurns.logHandEdit(from: project, to: Self.setting(hand.set, in: project), undoName: "Hand edit", target: hand.target, at: Self.at)
                }
            }
            if let unlogged = item.unlogged { project = try Self.setting(unlogged, in: project) }
            let data = try ProjectJSON.encode(project)
            project = try ProjectJSON.decode(data)
            #expect(try ProjectJSON.encode(project) == data, "\(item.name)")
            let plan = try AgentTurns.planUndo(project, turnId: item.turnId, changeId: item.changeId)
            #expect(plan.dependants.compactMap { $0.changeId ?? $0.target } == item.dependants, "\(item.name)")
            #expect(plan.conflictingPaths == item.conflicts ?? [], "\(item.name)")
            if !item.dependants.isEmpty || !(item.conflicts ?? []).isEmpty {
                #expect(throws: AgentTurns.Refusal.confirmationRequired) { try AgentTurns.undo(project, plan: plan) }
            }
            let undone = try AgentTurns.undo(project, plan: plan, confirmed: plan.requiresConfirmation)
            #expect(undone.agentThread?.turns.map(\.state) == item.states, "\(item.name)")
            #expect(undone.agentThread?.turns.allSatisfy { $0.events.isEmpty } == true, "\(item.name)")
            #expect(try Self.editingBytes(undone) == Self.editingBytes(Self.setting(item.expected, in: base)), "\(item.name)")
            if item.redo == true, let changeId = item.changeId {
                let redone = try AgentTurns.redo(undone, turnId: item.turnId, changeId: changeId)
                #expect(try ProjectJSON.encode(redone) == data, "\(item.name)")
            }
        }
    }

    @Test func revisionRetainsTheOriginalBeforeValueAndKeepDoesNotEdit() throws {
        let base = try Self.base()
        let first = try Self.setting(.object(["captions": .object(["styleId": .string("off")])]), in: base)
        let later = try Self.setting(.object(["captions": .object(["styleId": .string("vox-bold")])]), in: first)
        let change = try #require(try AgentTurns.change(from: base, to: first, id: "style", label: "Style", undoName: "Style"))
        let pending = try Self.record("t1", [change], in: first)
        var proposed = later
        proposed.agentThread = pending.agentThread
        let revised = try AgentTurns.revise(pending, proposed: proposed, turnId: "t1", revisionId: "follow-up", changeId: "style", label: "Style", undoName: "Style")
        #expect(revised.agentThread?.turns.map(\.revisionOf) == ["follow-up"])
        let kept = try AgentTurns.keepAll(revised)
        #expect(kept.agentThread?.turns.map(\.state) == [.kept])
        #expect(try Self.editingBytes(kept) == Self.editingBytes(revised))
        #expect(throws: AgentTurns.Refusal.notPending) {
            try AgentTurns.revise(kept, proposed: proposed, turnId: "t1", revisionId: "another", changeId: "style", label: "Style", undoName: "Style")
        }
        let undone = try AgentTurns.undo(kept, plan: AgentTurns.planUndo(kept, turnId: "t1"))
        #expect(try Self.editingBytes(undone) == Self.editingBytes(base))
    }

    @Test func keepPrunesTheThirtyFirstKeptCheckpointButNeverAPendingOne() throws {
        let before = try Self.base()
        let after = try Self.setting(.object(["captions": .object(["styleId": .string("off")])]), in: before)
        let change = try #require(try AgentTurns.change(from: before, to: after, id: "style", label: "Style", undoName: "Style"))
        var project = try Self.record("pending", [change], in: after)
        for index in 1...31 { project = try AgentTurns.keep(Self.record("kept-\(index)", [change], in: project), turnId: "kept-\(index)") }
        #expect(project.agentThread?.turns[0].changes[0].patch == change.patch)
        #expect(project.agentThread?.turns[1].changes[0].patch.isEmpty == true)
        #expect(project.agentThread?.turns[1].summary == "Changed the edit")
        #expect(project.agentThread?.turns[2].changes[0].patch == change.patch)
        #expect(throws: AgentTurns.Refusal.unavailable(AgentTurns.prunedReason)) { try AgentTurns.planUndo(project, turnId: "kept-1") }
    }

    private static func record(_ id: String, _ changes: [AgentChange], in project: Project) throws -> Project {
        try AgentTurns.record(.init(id: id, createdAt: at, request: .init(text: "Edit this"), connector: "claude-code", model: "default",
                                    summary: "Changed the edit", state: .pending, changes: changes), in: project, threadId: "th-test")
    }

    private static func base() throws -> Project {
        var project = try ProjectJSON.decode(FixtureLoader.data("fixtures/projects/clip-from-long-take.voxclip"))
        project.agentThread = AgentThread(id: "th-test")
        return try ProjectJSON.decode(ProjectJSON.encode(project))
    }

    private static func editingBytes(_ project: Project) throws -> Data {
        var copy = project
        copy.agentThread?.turns = []
        return try ProjectJSON.encode(copy)
    }

    private static func setting(_ changes: JSONValue, in project: Project) throws -> Project {
        func merge(_ before: JSONValue?, _ after: JSONValue) -> JSONValue {
            guard case .object(let overrides) = after, case .object(var result) = before else { return after }
            for (key, value) in overrides { result[key] = merge(result[key], value) }
            return .object(result)
        }
        let document = try ProjectJSON.decoder().decode(JSONValue.self, from: ProjectJSON.encode(project))
        return try ProjectJSON.decode(ProjectJSON.encoder().encode(merge(document, changes)))
    }
}
