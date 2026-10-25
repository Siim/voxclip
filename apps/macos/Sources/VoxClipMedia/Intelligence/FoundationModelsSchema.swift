import Foundation
import FoundationModels
import VoxClipCore

enum FoundationModelsSchema {
    static func make(_ canonical: JSONValue, name: String, clipBudget: Int? = nil) throws -> GenerationSchema {
        if let clipBudget, clipBudget < 1 { throw invalid("The clip budget must be positive.") }
        return try GenerationSchema(root: dynamic(canonical, name: name, clipBudget: clipBudget), dependencies: [])
    }

    private static func dynamic(_ canonical: JSONValue, name: String, clipBudget: Int?, isClips: Bool = false) throws -> DynamicGenerationSchema {
        guard case .object(let schema) = canonical, case .string(let type) = schema["type"] else {
            throw invalid("A canonical schema must have a type.")
        }
        let allowed: Set<String>
        switch type {
        case "object": allowed = ["type", "properties", "required", "additionalProperties"]
        case "array": allowed = ["type", "items"]
        case "string": allowed = ["type", "enum"]
        default: allowed = ["type"]
        }
        guard Set(schema.keys).isSubset(of: allowed) else { throw invalid("Unsupported canonical schema keyword.") }
        switch type {
        case "object":
            guard case .object(let properties) = schema["properties"],
                  case .array(let required) = schema["required"],
                  schema["additionalProperties"] == .bool(false),
                  required.count == properties.count else {
                throw invalid("Every object property must be required, with no additional properties.")
            }
            let names = try required.map { value -> String in
                guard case .string(let name) = value else { throw invalid("Required property names must be strings.") }
                return name
            }
            guard Set(names) == Set(properties.keys) else { throw invalid("Required properties do not match the object.") }
            let fields = try names.map { property -> DynamicGenerationSchema.Property in
                guard let value = properties[property] else { throw invalid("Missing required property schema.") }
                return try DynamicGenerationSchema.Property(
                    name: property,
                    schema: dynamic(value, name: name + "_" + property, clipBudget: clipBudget,
                                    isClips: property == "clips"),
                    isOptional: false
                )
            }
            return DynamicGenerationSchema(name: name, properties: fields)
        case "array":
            guard let item = schema["items"] else { throw invalid("An array needs an item schema.") }
            return try DynamicGenerationSchema(
                arrayOf: dynamic(item, name: name + "_item", clipBudget: clipBudget),
                maximumElements: isClips ? clipBudget : nil
            )
        case "string":
            if let enumeration = schema["enum"] {
                guard case .array(let values) = enumeration, !values.isEmpty else { throw invalid("An enum needs string values.") }
                let choices = try values.map { value -> String in
                    guard case .string(let choice) = value else { throw invalid("An enum needs string values.") }
                    return choice
                }
                guard Set(choices).count == choices.count else { throw invalid("Enum values must be unique.") }
                return DynamicGenerationSchema(name: name, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: throw invalid("Unsupported canonical schema type.")
        }
    }

    private static func invalid(_ reason: String) -> LLMError {
        .badRequest(status: 400, message: reason)
    }
}

enum FoundationModelsLocale {
    static func language(for request: LLMRequest, supports: (Locale) -> Bool) throws -> String {
        let language = request.language ?? dominantLanguage(in: request.cachedBlock ?? "")
        guard let language, !language.isEmpty, supports(Locale(identifier: language)) else {
            throw LLMError.unsupportedLanguage(language ?? "unknown")
        }
        return language
    }

    static func dominantLanguage(in transcript: String) -> String? {
        let text = transcript.split(separator: "\n").compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("<") || line.hasPrefix("(") { return nil }
            return line.replacingOccurrences(of: #"^\[\d+-\d+\]\s+\d+:\d+(?::\d+)?\s+"#,
                                             with: "", options: .regularExpression)
        }.joined(separator: " ")
        let sample = text.split(whereSeparator: \.isWhitespace).prefix(2_000).joined(separator: " ")
        return recognize(sample)
    }
}
