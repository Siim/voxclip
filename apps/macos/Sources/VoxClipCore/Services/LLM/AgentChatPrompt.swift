import Foundation

struct AgentChatPrompt {
    let system: String
    let schemaName: String
    let schema: JSONValue
    let headings: [String: JSONValue]
    let tools: String

    init(shared: SharedResources) throws {
        let data = try Data(contentsOf: shared.root.appendingPathComponent("prompts/agent-chat.json"))
        let prompt = try JSONDecoder().decode(JSONValue.self, from: data)
        guard prompt[ai: "promptVersion"].aiInt == 1,
              let system = prompt[ai: "system"].aiString, let headings = prompt[ai: "request"].aiObject,
              let schemaName = prompt[ai: "output"][ai: "name"].aiString else {
            throw LLMError.invalidOutput(reason: "The agent chat prompt is missing or invalid.")
        }
        self.system = system; self.headings = headings; self.schemaName = schemaName
        let wire = prompt[ai: "output"][ai: "schema"]
        guard var schema = wire.aiObject, var properties = schema["properties"]?.aiObject,
              var calls = properties["calls"]?.aiObject, var items = calls["items"]?.aiObject,
              var fields = items["properties"]?.aiObject else { throw LLMError.invalidOutput(reason: "Invalid agent_step schema.") }
        fields["args"] = .object(["type": .string("object"), "additionalProperties": .bool(false),
                                  "required": .array([.string("json")]),
                                  "properties": .object(["json": .object(["type": .string("string")])])])
        items["properties"] = .object(fields)
        calls["items"] = .object(items)
        properties["calls"] = .object(calls)
        schema["properties"] = .object(properties)
        self.schema = CanonicalResponseParser.strictSchema(.object(schema))
        tools = Self.text(.array(try HarnessTool.agentDefinitions(shared: shared)))
    }

    func instruction(digest: JSONValue, thread: [JSONValue], message: JSONValue, results: [JSONValue],
                     steering: [JSONValue], feedback: String?) -> String {
        let sections = [("tools", tools), ("project", Self.text(digest)), ("thread", Self.text(.array(thread))),
                        ("message", Self.text(message)), ("results", Self.text(.array(results)))]
        var blocks = sections.map { key, value in "\(headings[key]?.aiString ?? key)\n\(value)" }
        if let strictArgs = headings["strictArgs"]?.aiString { blocks.append(strictArgs) }
        if !steering.isEmpty { blocks.append("\(headings["steer"]?.aiString ?? "Steer:")\n\(Self.text(.array(steering)))") }
        if let feedback { blocks.append(feedback) }
        return blocks.joined(separator: "\n\n")
    }

    static func text(_ value: JSONValue) -> String {
        (try? String(decoding: value.aiEncoded(), as: UTF8.self)) ?? "null"
    }

    static func json(_ value: some Encodable) -> JSONValue { (try? HarnessTools.json(value)) ?? .null }
}

struct AgentChatReply {
    struct Call: Decodable { let tool: String; let args: JSONValue }
    let say: String
    let calls: [Call]
    let done: Bool
    let question: AgentChatSession.Question?
    let next: [String]

    init(_ raw: RawCompletion) throws {
        let error = LLMError.invalidOutput(reason: "Expected an agent_step with say, calls and done, and valid optional question and next fields.")
        guard raw.stop == .complete else { throw error }
        let root = try raw.object ?? CanonicalResponseParser.extract(raw.text ?? "")
        guard let fields = root.aiObject, Set(fields.keys).isSubset(of: ["say", "calls", "done", "question", "next"]),
              !StrictJSON.nests(root, deeperThan: StrictJSON.maxDepth),
              let say = fields["say"]?.aiString, say.unicodeScalars.count <= 600,
              case .array(let calls) = fields["calls"], calls.count <= 6,
              let done = fields["done"]?.aiBool else { throw error }
        self.say = say; self.done = done
        self.calls = try calls.map { call in
            guard let fields = call.aiObject, Set(fields.keys) == ["tool", "args"],
                  let tool = fields["tool"]?.aiString, let args = fields["args"]?.aiObject else { throw error }
            if Set(args.keys) == ["json"], let text = args["json"]?.aiString {
                guard let value = StrictJSON.parse(text), value.aiObject != nil else { throw error }
                return Call(tool: tool, args: value)
            }
            return Call(tool: tool, args: .object(args))
        }
        if let question = fields["question"], question != .null {
            guard let fields = question.aiObject, Set(fields.keys) == ["text", "answers"],
                  let text = fields["text"]?.aiString, case .array(let answers) = fields["answers"],
                  answers.count >= 2, answers.allSatisfy({ $0.aiString != nil }) else { throw error }
            self.question = .init(text: text, answers: answers.compactMap(\.aiString))
        } else { question = nil }
        if let next = fields["next"] {
            guard case .array(let items) = next, items.count <= 2, items.allSatisfy({ $0.aiString != nil }) else { throw error }
            self.next = items.compactMap(\.aiString)
        } else { next = [] }
    }
}
