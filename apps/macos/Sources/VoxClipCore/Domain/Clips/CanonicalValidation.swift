import Foundation

extension CanonicalResponseParser {
    public static func extract(_ text: String) throws -> JSONValue {
        var trimmed = AIText.trim(text)
        if trimmed.hasPrefix("```") {
            if let newline = trimmed.firstIndex(of: "\n") { trimmed = String(trimmed[trimmed.index(after: newline)...]) }
            if AIText.trim(trimmed).hasSuffix("```") { trimmed = String(AIText.trim(trimmed).dropLast(3)) }
        }
        if let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) { return parsed }
        guard let first = trimmed.firstIndex(of: "{") else { throw LLMError.invalidOutput(reason: "not JSON") }
        var depth = 0
        var inString = false
        var escaped = false
        for position in trimmed[first...].indices {
            let character = trimmed[position]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" { inString = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let data = Data(trimmed[first...position].utf8)
                    if let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) { return parsed }
                    break
                }
            }
        }
        throw LLMError.invalidOutput(reason: "not JSON")
    }

    public static func validate(_ completion: RawCompletion, schema: JSONValue) throws -> (object: JSONValue, droppedItems: Int) {
        switch completion.stop {
        case .truncated: throw LLMError.truncated
        case .refused(let category): throw LLMError.refused(category: category)
        case .complete: break
        }
        let value = try completion.object ?? extract(completion.text ?? "")
        guard let object = value.aiObject else { throw LLMError.invalidOutput(reason: "not JSON") }
        let properties = schema[ai: "properties"].aiObject ?? [:]
        var result: [String: JSONValue] = [:]
        var dropped = 0
        for key in properties.keys.sorted() {
            let property = properties[key]!
            guard let content = object[key] else { throw LLMError.invalidOutput(reason: "missing \"\(key)\"") }
            if property[ai: "type"].aiString == "array" {
                guard case .array(let items) = content else { throw LLMError.invalidOutput(reason: "missing \"\(key)\"") }
                let valid = items.filter { conforms($0, to: property[ai: "items"]) }
                dropped += items.count - valid.count
                result[key] = .array(valid)
            } else {
                guard conforms(content, to: property) else { throw LLMError.invalidOutput(reason: "missing \"\(key)\"") }
                result[key] = content
            }
        }
        return (.object(result), dropped)
    }

    private static func conforms(_ value: JSONValue, to schema: JSONValue) -> Bool {
        switch schema[ai: "type"].aiString {
        case "object":
            guard let object = value.aiObject else { return false }
            return schema[ai: "required"].aiArray.allSatisfy { required in
                guard let key = required.aiString, let item = object[key] else { return false }
                return conforms(item, to: schema[ai: "properties"][ai: key])
            }
        case "array":
            guard case .array(let items) = value else { return false }
            return items.allSatisfy { conforms($0, to: schema[ai: "items"]) }
        case "number", "integer": return value.aiDouble != nil
        case "string":
            guard let string = value.aiString else { return false }
            let values = schema[ai: "enum"].aiArray
            return values.isEmpty || values.contains(.string(string))
        case "boolean": return value.aiBool != nil
        default: return false
        }
    }

    public static func validateSchemaSubset(_ schema: JSONValue) -> Bool {
        guard let object = schema.aiObject, Set(object.keys).isSubset(of: ["type", "properties", "required", "additionalProperties", "items", "enum"]) else { return false }
        switch schema[ai: "type"].aiString {
        case "object":
            guard schema[ai: "additionalProperties"].aiBool == false, let properties = schema[ai: "properties"].aiObject else { return false }
            return Set(schema[ai: "required"].aiArray.compactMap(\.aiString)) == Set(properties.keys) && properties.values.allSatisfy(validateSchemaSubset)
        case "array": return validateSchemaSubset(schema[ai: "items"])
        case "string": return schema[ai: "enum"] == .null || (!schema[ai: "enum"].aiArray.isEmpty && schema[ai: "enum"].aiArray.allSatisfy { $0.aiString != nil })
        case "integer", "number", "boolean": return schema[ai: "enum"] == .null
        default: return false
        }
    }
}
