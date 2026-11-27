import ArgumentParser
import Foundation
import VoxClipCore

enum HarnessTool: String, CaseIterable {
    case readTranscript = "read_transcript"
    case readClips = "read_clips"
    case readTakes = "read_takes"
    case readDecisions = "read_decisions"
    case readFrames = "read_frames"
    case proposeTimeline = "propose_timeline"

    var keys: Set<String> {
        switch self {
        case .readTranscript: ["offset", "limit", "recordingKey"]
        case .readClips, .readTakes: []
        case .readDecisions: ["clipId"]
        case .readFrames: ["times"]
        case .proposeTimeline: HarnessTimeline.keys.union(["timelines"])
        }
    }

    func definition(shared: SharedResources) throws -> JSONValue {
        let description: String
        let schema: JSONValue
        func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
            .object(["type": .string("object"), "additionalProperties": .bool(false), "properties": .object(properties),
                     "required": .array(required.map(JSONValue.string))])
        }
        switch self {
        case .readTranscript:
            description = "Read corrected transcript words with recording labels, project-clock times and zero-based item indices."
            schema = object(["offset": .object(["type": .string("integer"), "minimum": .number(0)]),
                             "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(500)]),
                             "recordingKey": .object(["type": .string("string"), "description": .string("Preview indices for a companion with a cached local transcript before proposing useRecording.")])])
        case .readClips:
            description = "List clips with kind, ordered parts, recordings, inclusive transcript indices and source spans."
            schema = object([:])
        case .readTakes:
            description = "Read matched beats, aligned spans, delivery signals and solo runs across spoken recordings."
            schema = object([:])
        case .readDecisions:
            description = "Read the clip's saved title context, framing, cover, captions, effects and music choices."
            schema = object(["clipId": .object(["type": .string("string")])], required: ["clipId"])
        case .readFrames:
            description = "Decode one to four unedited JPEG thumbnails from the project's local video at source seconds."
            schema = object(["times": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(4),
                                               "items": .object(["type": .string("number"), "minimum": .number(0)])])], required: ["times"])
        case .proposeTimeline:
            description = "Stage one timeline, or up to six in timelines, for individual Keep or Undo. Use newClip and ordered parts to make a story. Never sends, spends or captures consent."
            func load(_ file: String) throws -> JSONValue {
                try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("schemas/" + file)))
            }
            var timeline = try load("harness-timeline.schema.json")
            if case .object(var effect) = try load("clip-plan-effect.schema.json"),
               case .object(var effectProperties) = effect["properties"],
               case .object(var template) = try load("motion-template.schema.json"), case .object(var root) = timeline,
               case .object(var properties) = root["properties"], case .object(var effects) = properties["effects"],
               case .object(let items) = effects["items"], items["$ref"] == .string("clip-plan-effect.schema.json") {
                effect["$id"] = nil
                effect["$schema"] = nil
                template["$id"] = nil
                template["$schema"] = nil
                effectProperties["template"] = .object(template)
                effect["properties"] = .object(effectProperties)
                effects["items"] = .object(effect)
                properties["effects"] = .object(effects)
                root["properties"] = .object(properties)
                timeline = .object(root)
            } else { throw HarnessError.invalid("The harness timeline schema is missing or invalid.") }
            guard case .object(var single) = timeline, case .object(var properties) = single["properties"] else {
                throw HarnessError.invalid("The harness timeline schema is missing or invalid.")
            }
            single["$schema"] = nil; single["$id"] = nil
            let series: JSONValue = .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(6), "items": .object(single)])
            let batch = object(["timelines": series], required: ["timelines"])
            properties["timelines"] = series
            schema = .object(["type": .string("object"), "properties": .object(properties), "oneOf": .array([.object(single), batch])])
        }
        return .object(["name": .string(rawValue), "description": .string(description), "inputSchema": schema,
                        "annotations": .object(["readOnlyHint": .bool(self != .proposeTimeline), "destructiveHint": .bool(false),
                                                 "openWorldHint": .bool(false)])])
    }
}

struct HarnessMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Serve local tools over stdio for one saved .voxclip project.")
    @OptionGroup var scope: HarnessProjectOptions

    func run() async throws {
        let project = try HarnessProject(path: scope.project)
        let shared = try SharedResources.locate()
        var server = HarnessSession(project: project, tools: try HarnessTool.allCases.map { try $0.definition(shared: shared) })
        let input = FileHandle.standardInput
        var line = Data()
        var discard = false
        while !Task.isCancelled {
            let block = input.availableData
            if block.isEmpty { break }
            var start = block.startIndex
            while start < block.endIndex {
                let end = block[start...].firstIndex(of: 10) ?? block.endIndex
                let finished = end != block.endIndex
                if !discard && line.count + (end - start) > HarnessInbox.maximumBytes {
                    try Self.write(HarnessSession.error(.null, code: -32700, "Message is too large."))
                    discard = true
                    line.removeAll(keepingCapacity: true)
                }
                if !discard { line.append(contentsOf: block[start..<end]) }
                if finished {
                    if !discard, !line.isEmpty, let reply = await server.receive(line) { try Self.write(reply) }
                    line.removeAll(keepingCapacity: true)
                    discard = false
                }
                start = finished ? end + 1 : end
            }
        }
    }

    static func write(_ reply: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(reply)
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

private struct HarnessSession {
    let project: HarnessProject
    let tools: [JSONValue]
    private var initialized = false

    init(project: HarnessProject, tools: [JSONValue]) {
        self.project = project
        self.tools = tools
    }

    mutating func receive(_ data: Data) async -> JSONValue? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return Self.error(.null, code: -32700, "Invalid JSON.") }
        guard case .object(let request) = value, request["jsonrpc"] == .string("2.0"), case .string(let method) = request["method"] else {
            return Self.error(.null, code: -32600, "Invalid request.")
        }
        guard let id = request["id"] else { return nil }
        switch id {
        case .number(let number) where number.rounded() == number: break
        case .string: break
        default: return Self.error(.null, code: -32600, "Invalid request id.")
        }
        let params = request["params"] ?? .object([:])
        let fields: [String: JSONValue]
        if case .object(let object) = params { fields = object }
        else { return Self.error(id, code: -32602, "Expected an object for params.") }
        if method == "initialize" {
            guard case .string(let asked) = fields["protocolVersion"] else { return Self.error(id, code: -32602, "Missing protocol version.") }
            let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            initialized = true
            return Self.reply(id, ["protocolVersion": .string(versions.contains(asked) ? asked : "2025-11-25"),
                                   "capabilities": .object(["tools": .object([:])]),
                                   "serverInfo": .object(["name": .string("voxclip"), "version": .string(AppVersion.current)]),
                                   "instructions": .string("Read the saved VoxClip project. Only VoxClip can keep edits or run priced actions.")])
        }
        if method == "ping" { return Self.reply(id, [:]) }
        guard initialized else { return Self.error(id, code: -32002, "Initialize first.") }
        switch method {
        case "tools/list":
            guard fields.isEmpty else { return Self.error(id, code: -32602, "There is no tools cursor.") }
            return Self.reply(id, ["tools": .array(tools)])
        case "tools/call":
            guard Set(fields.keys).isSubset(of: ["name", "arguments", "_meta"]), case .string(let name) = fields["name"], let tool = HarnessTool(rawValue: name) else {
                return Self.error(id, code: -32602, "Unknown tool or invalid call.")
            }
            do {
                let result = try await project.call(tool, arguments: fields["arguments"] ?? .object([:]))
                let metadata = try JSONEncoder().encode(JSONValue.object(result.fields))
                let content = [Self.text(String(decoding: metadata, as: UTF8.self))] + result.images.map {
                    JSONValue.object(["type": .string("image"), "mimeType": .string("image/jpeg"), "data": .string($0.jpeg)])
                }
                return Self.reply(id, ["content": .array(content), "structuredContent": .object(result.fields)])
            } catch let error as HarnessError {
                return Self.reply(id, ["isError": .bool(true), "content": .array([Self.text(error.localizedDescription)])])
            } catch {
                return Self.reply(id, ["isError": .bool(true), "content": .array([Self.text("VoxClip couldn't complete this request. No project edits were applied.")])])
            }
        default: return Self.error(id, code: -32601, "Method not found.")
        }
    }

    private static func text(_ value: String) -> JSONValue { .object(["type": .string("text"), "text": .string(value)]) }

    private static func reply(_ id: JSONValue, _ result: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": .object(result)])
    }

    static func error(_ id: JSONValue, code: Double, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(code), "message": .string(message)])])
    }
}
