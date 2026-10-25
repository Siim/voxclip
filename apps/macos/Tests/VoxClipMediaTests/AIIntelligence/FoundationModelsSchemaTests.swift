import Foundation
import FoundationModels
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

@Suite struct FoundationModelsSchemaTests {
    @Test(arguments: ["clip-finder", "ai-tighten"]) func sharedSchemasBuildWithoutModelCalls(_ prompt: String) throws {
        let output = try FixtureLoader.decode(FoundationModelsTestResources.Prompt.self, at: "prompts/\(prompt).json").output
        let schema = try FoundationModelsSchema.make(output.schema, name: output.name, clipBudget: 3)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any]
        let properties = try #require(encoded?["properties"] as? [String: [String: Any]])
        let array = try #require(properties[prompt == "clip-finder" ? "clips" : "edits"])
        #expect(array["type"] as? String == "array")
        #expect(array["maxItems"] as? Int == (prompt == "clip-finder" ? 3 : nil))
        #expect(encoded?["additionalProperties"] as? Bool == false)
        let mapped = try FoundationModelsFixtures.mapped(schema, name: output.name)
        let arrayName = prompt == "clip-finder" ? "clips" : "edits"
        let item = try #require(mapped[ai: "properties"].aiArray.first)[ai: "schema"][ai: "arrayOf"]
        #expect(item[ai: "name"].aiString == output.name + "_" + arrayName + "_item")
        #expect(item[ai: "name"].aiString != mapped[ai: "name"].aiString)
    }

    @Test func catalogTestSchemaHasRequiredBooleanAndString() throws {
        let request = try FoundationModelsTestResources.request()
        let schema = try FoundationModelsSchema.make(request.schema, name: request.schemaName)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any]
        let properties = try #require(encoded?["properties"] as? [String: [String: Any]])
        #expect(properties["ok"]?["type"] as? String == "boolean")
        #expect(properties["echo"]?["type"] as? String == "string")
        #expect(Set(encoded?["required"] as? [String] ?? []) == ["ok", "echo"])
    }

    @Test func numberAndStringEnumMapWithoutLosingTypes() throws {
        let canonical: JSONValue = .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("weight"), .string("category")]),
            "properties": .object([
                "weight": .object(["type": .string("number")]),
                "category": .object(["type": .string("string"), "enum": .array([.string("first"), .string("second")])])
            ])
        ])
        let schema = try FoundationModelsSchema.make(canonical, name: "example")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any]
        let properties = try #require(encoded?["properties"] as? [String: [String: Any]])
        #expect(properties["weight"]?["type"] as? String == "number")
        let serialized = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
        #expect(serialized.contains("first"))
        #expect(serialized.contains("second"))
    }

    @Test func nonCanonicalSchemasAreRejected() throws {
        #expect(throws: (any Error).self) {
            try FoundationModelsSchema.make(.object(["type": .string("string"), "maxLength": .number(12)]), name: "bad")
        }
        #expect(throws: (any Error).self) {
            try FoundationModelsSchema.make(.object(["type": .string("object"), "properties": .object([:])]), name: "bad")
        }
        #expect(throws: (any Error).self) {
            try FoundationModelsSchema.make(.object(["type": .string("null")]), name: "bad")
        }
        let request = try FoundationModelsTestResources.request()
        #expect(throws: (any Error).self) { try FoundationModelsSchema.make(request.schema, name: request.schemaName, clipBudget: 0) }
    }

    @Test func budgetUsesCanonicalWindowTemplateAndPreset() throws {
        struct Prompt: Decodable {
            struct Request: Decodable { var windowLines: [String] }
            struct Limits: Decodable { var windowMinClips: Int; var windowClipFactor: Double }
            struct Preset: Decodable { var instruction: String; var maxClips: Int }
            var request: Request
            var limits: Limits
            var presets: [Preset]
        }
        let prompt = try FixtureLoader.decode(Prompt.self, at: "prompts/clip-finder.json")
        let shared = try SharedResources(root: FixtureLoader.sharedRoot())
        let template = try #require(prompt.request.windowLines.first(where: { $0.contains("{maxClips}") }))
        let instruction = template.replacingOccurrences(of: "{maxClips}", with: "3")
        #expect(try FoundationModelsConfiguration.clipBudget(instruction: instruction, shared: shared) == 3)
        let custom = template.replacingOccurrences(of: "{maxClips}", with: "99")
        #expect(try FoundationModelsConfiguration.clipBudget(instruction: custom + "\n" + instruction, shared: shared) == 3)
        for preset in prompt.presets where !preset.instruction.isEmpty {
            let budget = max(prompt.limits.windowMinClips, Int(ceil(Double(preset.maxClips) * prompt.limits.windowClipFactor)))
            #expect(try FoundationModelsConfiguration.clipBudget(instruction: preset.instruction, shared: shared) == budget)
        }
    }
}
