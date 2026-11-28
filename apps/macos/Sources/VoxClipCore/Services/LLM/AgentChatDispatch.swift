import Foundation

extension AgentChatSession {
    func perform(_ call: AgentChatReply.Call, run: inout Run, stale: Bool) async throws {
        let start = ContinuousClock.now
        let snapshot = project
        var candidate = snapshot
        var turn = run.turn
        let output: JSONValue
        var ok = false
        do {
            guard let tool = HarnessTool(rawValue: call.tool) else { throw HarnessError.invalid("Unknown tool: \(call.tool)") }
            if tool == .proposeTimeline, stale { throw HarnessError.invalid("stale: the words changed") }
            if tool == .proposeTimeline, mode == .askFirst { throw HarnessError.invalid("Waiting for Go.") }
            let revision = tool == .proposeTimeline ? try HarnessChatTools.timeline(call.args).1 : nil
            let basis: Project
            if let revision {
                guard snapshot.agentThread?.turns.first(where: { $0.id == revision })?.isPending == true else {
                    throw HarnessError.invalid("Turn \(revision.dropFirst()) is already kept. Propose a new change instead.")
                }
                let undo = try AgentTurns.planUndo(snapshot, turnId: revision)
                basis = try AgentTurns.undo(snapshot, plan: undo)
            } else { basis = snapshot }
            let result = try await HarnessTools.call(tool, arguments: call.args, project: basis, shared: shared,
                                                     projectURL: projectURL, decodeFrames: decodeFrames,
                                                     music: music, check: check, postableCap: context.capLeft)
            guard !stopping, !Task.isCancelled else { return }
            guard tool != .proposeTimeline || snapshot == project else { throw HarnessError.invalid("stale: the words changed") }
            candidate = project
            if let proposal = result.proposal {
                let change = try apply(proposal, result: result, basis: basis, to: candidate, turn: &turn, revision: revision)
                candidate = change.project
                run.claims += change.revised
            }
            if tool == .check { turn.check = Self.readCheck(result.fields["checks"] ?? .null) }
            if tool == .readFrames {
                run.images = Array(result.images.prefix(4)).compactMap { frame in
                    guard let jpeg = Data(base64Encoded: frame.jpeg) else { return nil }
                    return LLMImage(label: "Source frame at \(frame.actual) seconds", mediaType: "image/jpeg",
                                    data: jpeg, width: 0, height: 0)
                }
            }
            output = .object(result.fields)
            let refusal = result.fields["refusals"]?.aiArray.last?[ai: "reason"].aiString
            if refusal != nil || run.refusedTool == call.tool {
                run.refusal = refusal
                run.refusedTool = refusal == nil ? nil : call.tool
            }
            ok = refusal == nil
        } catch {
            guard !stopping, !Task.isCancelled else { return }
            candidate = project
            turn = run.turn
            let refusal = (error as? LocalizedError)?.errorDescription ?? "The change was refused."
            run.refusal = refusal
            run.refusedTool = call.tool
            output = .object(["refusal": .string(refusal)])
        }
        let seconds = start.duration(to: .now).components
        let duration = Int(seconds.seconds * 1000 + seconds.attoseconds / 1_000_000_000_000_000)
        turn.steps.append(.init(tool: call.tool, ok: ok, digest: String(AgentChatPrompt.text(output).prefix(240)), ms: duration))
        run.results.append(.object(["tool": .string(call.tool), "args": call.args, "result": output, "ok": .bool(ok)]))
        try save(turn, in: candidate)
        run.turn = turn
    }

    private func apply(_ proposal: HarnessProposal, result: HarnessResult, basis: Project, to live: Project,
                       turn: inout AgentTurn, revision: String?) throws -> (project: Project, revised: [String]) {
        let refused = Set(result.fields["refusals"]?.aiArray.compactMap { $0[ai: "timelineIndex"].aiInt } ?? [])
        var edited = basis
        let labels = result.fields["labels"]?.aiArray ?? []
        for (index, timeline) in proposal.timelines.enumerated() where !refused.contains(index) {
            let single = try HarnessProposal(timeline: timeline, project: edited)
            let transcript = timeline.recordingKey.flatMap { HarnessRecording.cachedTranscript($0, cache: DataLocations().cache) }
            let review = try single.review(edited, shared: shared, recordingTranscript: transcript, preparedMusic: result.preparedMusic)
            if revision == nil, let change = try AgentTurns.change(from: edited, to: review.project,
                id: "\(turn.id)-c\(turn.changes.count + 1)", label: labels.indices.contains(index) ? labels[index].aiString ?? timeline.reason : timeline.reason,
                undoName: "Agent edit") { turn.changes.append(change) }
            edited = review.project
        }
        if mode == .claude { turn.wasKept = true }
        guard let revision else { return (edited, []) }
        guard edited != basis else { return (live, []) }
        let revised = try AgentTurns.revise(live, proposed: edited, turnId: revision, revisionId: turn.id,
                                            changeId: "\(revision)-\(turn.id)", label: labels.first?.aiString ?? proposal.timeline.reason,
                                            undoName: "Revise agent edit")
        if mode == .claude { return (try AgentTurns.keep(revised, turnId: revision), []) }
        return (revised, AgentChatMatch.kinds(in: revised.agentThread?.turns.first(where: { $0.id == revision })?.changes ?? []))
    }

    func digest() async -> JSONValue {
        let snapshot = project
        let clip = openClipID
        let listing = try? await HarnessTools.call(.readClips, arguments: .object([:]), project: snapshot, shared: shared)
        var digest: [String: JSONValue] = ["mode": .string(mode.rawValue), "openClip": clip.map(JSONValue.string) ?? .null,
                                          "playhead": context.playhead.map(JSONValue.number) ?? .null,
                                          "capLeft": context.capLeft.map { .string(NSDecimalNumber(decimal: $0).stringValue) } ?? .null]
        func add(_ name: String, _ value: JSONValue) {
            var proposed = digest
            proposed[name] = value
            if AgentChatPrompt.text(.object(proposed)).utf8.count <= 3_000 { digest = proposed }
        }
        func addRows(_ name: String, _ rows: [JSONValue]) {
            var kept: [JSONValue] = []
            for row in rows {
                add(name, .array(kept + [row]))
                kept = digest[name]?.aiArray ?? []
            }
        }
        addRows("selection", context.selection.map(AgentChatPrompt.json))
        add("style", AgentChatPrompt.json(snapshot.clipStyle))
        if let clip, let decisions = try? await HarnessTools.call(.readDecisions, arguments: .object(["clipId": .string(clip)]), project: snapshot, shared: shared) {
            add("openClipDecisions", .object(decisions.fields))
        }
        let clips = listing?.fields["clips"]?.aiArray ?? []
        addRows("recordings", listing?.fields["recordings"]?.aiArray ?? [])
        addRows("clips", clips.filter { $0[ai: "id"].aiString == clip } + clips.filter { $0[ai: "id"].aiString != clip })
        let turns = snapshot.agentThread?.turns ?? []
        addRows("pending", turns.filter(\.isPending).map { turn in
            .object(["id": .string(turn.id), "changes": .array(turn.changes.map { .string($0.label) })])
        })
        addRows("handEdits", turns.suffix(2).flatMap(\.events).filter { $0.kind == .hand }.map {
            .object(["name": .string($0.undoName), "target": .string($0.target)])
        })
        return .object(digest)
    }

    func history(excluding currentID: String) -> [JSONValue] {
        let turns = (project.agentThread?.turns ?? []).filter { $0.id != currentID }
        return turns.suffix(30).enumerated().map { index, turn in
            var fields: [String: JSONValue] = ["id": .string(turn.id), "user": .string(turn.request.text), "summary": .string(turn.summary)]
            if index >= max(0, min(30, turns.count) - 6) {
                fields["state"] = .string(turn.state.rawValue)
                fields["changes"] = .array(turn.changes.map { .object(["label": .string($0.label), "state": .string($0.state.rawValue)]) })
                fields["offers"] = AgentChatPrompt.json(turn.offers)
                fields["events"] = .array(turn.events.map { .object(["kind": .string($0.kind.rawValue), "name": .string($0.undoName), "target": .string($0.target)]) })
            }
            return .object(fields)
        }
    }
}

enum AgentChatMatch {
    private static let categories: [(name: String, mentions: [String], paths: [String])] = [
        ("music", ["music", "soundtrack", "track"], ["music"]),
        ("captions", ["caption", "subtitles"], ["caption"]),
        ("look", ["look", "grade", "color", "colour"], ["look", "grade"]),
        ("punch-in", ["punch-in", "punch in", "zoom"], ["effects", "frame", "zoom"]),
        ("title", ["title", "headline"], ["title"])
    ]

    static func kinds(in changes: [AgentChange]) -> [String] {
        let paths = changes.filter { $0.state == .applied }.flatMap(\.patch).map { $0.path.lowercased() }
        return categories.filter { category in paths.contains { path in category.paths.contains { path.contains($0) } } }.map(\.name)
    }

    static func missing(in summary: String, changes: [AgentChange], revised: [String]) -> String? {
        let existing = Set(kinds(in: changes) + revised)
        let clauses = summary.lowercased().components(separatedBy: CharacterSet(charactersIn: ".;!?\n"))
        return categories.first { category in
            !existing.contains(category.name) && clauses.contains { clause in
                !["no ", "not ", "didn't", "couldn't", "can't", "offered", "suggested", "can add"].contains(where: clause.contains)
                    && ["added", "set ", "applied", "changed", "updated", "picked", "selected", "removed"].contains(where: clause.contains)
                    && category.mentions.contains(where: clause.contains)
            }
        }?.name
    }
}
