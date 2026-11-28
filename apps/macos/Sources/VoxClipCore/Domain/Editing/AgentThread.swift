import Foundation

public struct AgentThread: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case propose, claude, askFirst }
    public var id: String
    public var mode: Mode
    public var turns: [AgentTurn]

    public init(id: String, mode: Mode = .propose, turns: [AgentTurn] = []) {
        self.id = id; self.mode = mode; self.turns = turns
    }
}

public struct AgentTurn: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case agent, run, outside }
    public enum State: String, Codable, Sendable { case running, pending, kept, undone, partial, stopped, failed }
    public var id: String
    public var kind: Kind
    public var createdAt: Date
    public var request: Request
    public var connector: String
    public var model: String
    public var summary: String
    public var steps: [Step]
    public var state: State
    public var revisionOf: String?
    public var changes: [AgentChange]
    public var offers: [Offer]
    public var check: Check?
    public var events: [Event]
    public var wasKept: Bool?

    public init(id: String, kind: Kind = .agent, createdAt: Date, request: Request, connector: String, model: String,
                summary: String = "", steps: [Step] = [], state: State = .running, revisionOf: String? = nil,
                changes: [AgentChange] = [], offers: [Offer] = [], check: Check? = nil, events: [Event] = []) {
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.request = request
        self.connector = connector; self.model = model; self.summary = summary; self.steps = steps; self.state = state
        self.revisionOf = revisionOf; self.changes = changes; self.offers = offers; self.check = check; self.events = events
    }

    public var isPending: Bool {
        state == .pending || ((state == .partial || state == .stopped) && wasKept != true && changes.contains { $0.state == .applied })
    }

    public struct Request: Codable, Sendable, Equatable {
        public var text: String
        public var context: [Context]
        public init(text: String, context: [Context] = []) { self.text = text; self.context = context }
    }

    public struct Context: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case clip, part, recording, words, line, panel }
        public var kind: Kind
        public var clipId: String?
        public var part: Int?
        public var sourceKey: String?
        public var startWordId: String?
        public var endWordId: String?
        public var line: Int?
        public var panel: String?

        public init(kind: Kind, clipId: String? = nil, part: Int? = nil, sourceKey: String? = nil,
                    startWordId: String? = nil, endWordId: String? = nil, line: Int? = nil, panel: String? = nil) {
            self.kind = kind; self.clipId = clipId; self.part = part; self.sourceKey = sourceKey
            self.startWordId = startWordId; self.endWordId = endWordId; self.line = line; self.panel = panel
        }
    }

    public struct Step: Codable, Sendable, Equatable {
        public var tool: String
        public var ok: Bool
        public var digest: String
        public var ms: Int
        public init(tool: String, ok: Bool, digest: String, ms: Int) { self.tool = tool; self.ok = ok; self.digest = digest; self.ms = ms }
    }

    public struct Offer: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case generateMusic, revoice, illustration, lipSync, makeItPostable }
        public enum State: String, Codable, Sendable { case offered, bought, declined, failed }
        public var id: String
        public var kind: Kind
        public var label: String
        public var quoteUSD: String
        public var state: State
        public var assetId: String?
        public init(id: String, kind: Kind, label: String, quoteUSD: String, state: State = .offered, assetId: String? = nil) {
            self.id = id; self.kind = kind; self.label = label; self.quoteUSD = quoteUSD; self.state = state; self.assetId = assetId
        }
    }

    public struct Check: Codable, Sendable, Equatable {
        public var ok: Bool
        public var lines: [String]
        public init(ok: Bool, lines: [String]) { self.ok = ok; self.lines = lines }
    }

    public struct Event: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case hand, keep, undo, redo, bought }
        public var kind: Kind
        public var undoName: String
        public var target: String
        public var at: Date
        public var patch: [AgentPatch]?
        public init(kind: Kind, undoName: String, target: String, at: Date, patch: [AgentPatch]? = nil) {
            self.kind = kind; self.undoName = undoName; self.target = target; self.at = at; self.patch = patch
        }
    }
}

public struct AgentChange: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case applied, undone }
    public var id: String
    public var label: String
    public var undoName: String
    public var state: State
    public var patch: [AgentPatch]
    public init(id: String, label: String, undoName: String, state: State = .applied, patch: [AgentPatch]) {
        self.id = id; self.label = label; self.undoName = undoName; self.state = state; self.patch = patch
    }
}

public struct AgentPatch: Codable, Sendable, Equatable {
    public var path: String
    public var before: JSONValue
    public var after: JSONValue
    public var beforeMissing: Bool?
    public var afterMissing: Bool?
    public var beforeIndex: Int?
    public var afterIndex: Int?
    public var previousId: String?
    public var nextId: String?

    public init(path: String, before: JSONValue, after: JSONValue, beforeMissing: Bool? = nil, afterMissing: Bool? = nil,
                beforeIndex: Int? = nil, afterIndex: Int? = nil, previousId: String? = nil, nextId: String? = nil) {
        self.path = path; self.before = before; self.after = after; self.beforeMissing = beforeMissing; self.afterMissing = afterMissing
        self.beforeIndex = beforeIndex; self.afterIndex = afterIndex
        self.previousId = previousId; self.nextId = nextId
    }
}
