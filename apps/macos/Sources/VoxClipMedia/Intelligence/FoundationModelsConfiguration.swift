import Foundation
import NaturalLanguage
import VoxClipCore

extension FoundationModelsLocale {
    static func recognize(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}

enum FoundationModelsConfiguration {
    struct Connector: Decodable {
        struct Model: Decodable {
            var id: String
            var name: String
            var tier: String?
        }
        var id: String
        var maxOutputTokensCap: Int
        var models: [Model]
    }

    private struct Catalog: Decodable { var connectors: [ConnectorEntry] }
    private struct ConnectorEntry: Decodable {
        var id: String
        var label: String?
        var enabled: Bool?
        var auth: JSONValue?
        var maxOutputTokensCap: Int?
        var models: [Connector.Model]?
    }

    private struct ClipPrompt: Decodable {
        struct Request: Decodable { var windowLines: [String] }
        struct Limits: Decodable { var windowMinClips: Int; var windowClipFactor: Double }
        struct Preset: Decodable {
            var id: String
            var instruction: String
            var maxClips: Int
        }
        var request: Request
        var limits: Limits
        var presets: [Preset]
    }

    static func connector(shared: SharedResources) throws -> Connector {
        let data = try Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard let entry = catalog.connectors.first(where: { $0.id == ConnectorID.appleFoundation.rawValue }) else {
            throw LLMError.unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
        }
        if let auth = entry.auth, auth != .null {
            guard case .object(let fields) = auth, fields["type"] == .string("none"),
                  ["keyAccount", "header", "valueTemplate", "debugEnvVar"].allSatisfy({ fields[$0] == nil }) else {
                throw LLMError.unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
            }
        }
        guard entry.enabled != false else {
            throw LLMError.unavailable(reason: "\(entry.label ?? "Apple Intelligence (on this Mac)") is not enabled.")
        }
        guard let cap = entry.maxOutputTokensCap, cap > 0, let models = entry.models, !models.isEmpty else {
            throw LLMError.unavailable(reason: "The Apple Intelligence catalog entry is incomplete.")
        }
        return Connector(id: entry.id, maxOutputTokensCap: cap, models: models)
    }

    static func clipBudget(instruction: String, shared: SharedResources) throws -> Int {
        let data = try Data(contentsOf: shared.root.appendingPathComponent("prompts/clip-finder.json"))
        let prompt = try JSONDecoder().decode(ClipPrompt.self, from: data)
        let lines = instruction.components(separatedBy: "\n")
        for template in prompt.request.windowLines {
            let parts = template.components(separatedBy: "{maxClips}")
            guard parts.count == 2 else { continue }
            for line in lines.reversed() where line.hasPrefix(parts[0]) && line.hasSuffix(parts[1]) {
                let number = line.dropFirst(parts[0].count).dropLast(parts[1].count)
                if let budget = Int(number), budget > 0 { return budget }
            }
        }
        if let preset = prompt.presets.first(where: { !$0.instruction.isEmpty && lines.contains($0.instruction) }) {
            return max(prompt.limits.windowMinClips, Int(ceil(Double(preset.maxClips) * prompt.limits.windowClipFactor)))
        }
        guard let preset = prompt.presets.first(where: { $0.id == "custom" }) else {
            throw LLMError.badRequest(status: 400, message: "A clip window needs an explicit clip budget.")
        }
        return max(prompt.limits.windowMinClips, Int(ceil(Double(preset.maxClips) * prompt.limits.windowClipFactor)))
    }
}
