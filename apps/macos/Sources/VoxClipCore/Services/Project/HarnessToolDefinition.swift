import Foundation

extension HarnessTool {
    package static func agentDefinitions(shared: SharedResources) throws -> [JSONValue] {
        let data = try Data(contentsOf: shared.root.appendingPathComponent("schemas/agent-tools.schema.json"))
        let definitions = try JSONDecoder().decode(JSONValue.self, from: data)[ai: "$defs"]
        return try allCases.map { tool in
            let name = tool.rawValue
            guard let schema = definitions[ai: name].aiObject else { return try tool.definition(shared: shared) }
            return .object(["name": .string(name), "inputSchema": .object(schema)])
        }
    }

    package func definition(shared: SharedResources) throws -> JSONValue {
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
        default: throw HarnessError.invalid("Unknown tool or invalid call.")
        }
        return .object(["name": .string(rawValue), "description": .string(description), "inputSchema": schema,
                        "annotations": .object(["readOnlyHint": .bool(self != .proposeTimeline), "destructiveHint": .bool(false),
                                                 "openWorldHint": .bool(false)])])
    }
}
