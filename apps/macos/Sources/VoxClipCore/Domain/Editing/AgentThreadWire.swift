import Foundation

enum AgentThreadWire {
    static let maxTurns = 200
    static let maxKeptCheckpoints = 30
    static let maxBytes = 2 * 1024 * 1024

    static func size(_ thread: AgentThread) throws -> Int {
        let encoder = ProjectJSON.encoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(thread).count
    }

    static func validate(_ raw: JSONValue?) throws {
        func fields(_ value: JSONValue?, _ required: String, _ optional: String = "") throws -> [String: JSONValue] {
            try ProjectValidation.object(value, required: required, optional: optional, at: "agentThread")
        }
        func patch(_ value: JSONValue?) throws {
            for item in try ProjectValidation.array(value, at: "agentThread/patch") {
                _ = try fields(item, "path before after", "beforeMissing afterMissing beforeIndex afterIndex previousId nextId")
            }
        }
        let thread = try fields(raw, "id mode turns")
        for item in try ProjectValidation.array(thread["turns"], at: "agentThread/turns") {
            let turn = try fields(item, "id kind createdAt request connector model summary steps state changes offers events", "revisionOf check wasKept")
            let request = try fields(turn["request"], "text context")
            for context in try ProjectValidation.array(request["context"]) {
                _ = try fields(context, "kind", "clipId part sourceKey startWordId endWordId line panel")
            }
            for step in try ProjectValidation.array(turn["steps"]) { _ = try fields(step, "tool ok digest ms") }
            for item in try ProjectValidation.array(turn["changes"]) {
                let change = try fields(item, "id label undoName state patch")
                try patch(change["patch"])
            }
            for offer in try ProjectValidation.array(turn["offers"]) { _ = try fields(offer, "id kind label quoteUSD state", "assetId target brief words") }
            if let check = turn["check"], check != .null { _ = try fields(check, "ok lines") }
            for item in try ProjectValidation.array(turn["events"]) {
                let event = try fields(item, "kind undoName target at", "patch")
                if let value = event["patch"], value != .null { try patch(value) }
            }
        }
    }

    static func validate(_ thread: AgentThread) throws {
        func require(_ valid: Bool, _ reason: String) throws {
            if !valid { try ProjectValidation.fail(reason, at: "agentThread") }
        }
        func ids(_ values: [String]) -> Bool { !values.contains("") && Set(values).count == values.count }
        try require(!thread.id.isEmpty && thread.turns.count <= maxTurns && ids(thread.turns.map(\.id)), "Invalid thread id or turns")
        for turn in thread.turns {
            try require(turn.summary.unicodeScalars.count <= 600 && turn.steps.count <= 24 && turn.steps.allSatisfy { $0.ms >= 0 }, "Invalid summary or steps")
            try require(ids(turn.changes.map(\.id)) && ids(turn.offers.map(\.id)), "Invalid change or offer id")
            try require(turn.request.context.allSatisfy { ($0.part ?? 1) > 0 && ($0.line ?? 1) > 0 }, "Invalid context")
            try require(turn.offers.allSatisfy { $0.quoteUSD.range(of: #"\A[0-9]+\.[0-9]{2}\z"#, options: .regularExpression) != nil }, "Invalid offer quote")
            for patch in turn.changes.map(\.patch) + turn.events.compactMap(\.patch) {
                try require(Set(patch.map(\.path)).count == patch.count && patch.allSatisfy(AgentPatchPath.isValid), "Invalid checkpoint patch")
            }
            try require(turn.events.allSatisfy { $0.kind == .hand || $0.patch == nil }, "Only hand events may store patches")
        }
        let bytes = try size(thread)
        try require(bytes <= maxBytes, "Thread exceeds the 2 MiB limit")
    }
}
