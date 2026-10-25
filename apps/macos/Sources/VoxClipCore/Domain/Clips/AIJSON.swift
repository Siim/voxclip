import Foundation

extension JSONValue {
    subscript(ai key: String) -> JSONValue { aiObject?[key] ?? .null }
    var aiObject: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var aiArray: [JSONValue] { if case .array(let value) = self { value } else { [] } }
    var aiString: String? { if case .string(let value) = self { value } else { nil } }
    var aiDouble: Double? { if case .number(let value) = self { value } else { nil } }
    var aiBool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var aiInt: Int? {
        guard let value = aiDouble, value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
    func aiEncoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    func aiCompact() throws -> String { String(decoding: try aiEncoded(), as: UTF8.self) }
}

struct AITokenPolicy: Sendable {
    let bytesPerToken: Double
    let safetyFactor: Double

    init(_ policy: JSONValue = .null) {
        bytesPerToken = policy[ai: "tokenEstimate"][ai: "utf8BytesPerToken"].aiDouble ?? 2.2
        safetyFactor = policy[ai: "tokenEstimate"][ai: "contextSafetyFactor"].aiDouble ?? 0.9
    }

    func estimate(_ text: String) -> Int { Int(ceil(Double(text.utf8.count) / bytesPerToken)) }
}

func aiOutputReserve(generation: Int, cap: Int?, context: Int, localServer: Bool) -> Int {
    let reserve = min(generation, cap ?? generation)
    return localServer ? min(reserve, max(1024, context / 4)) : reserve
}

func aiCompactCanonicalSchema(_ schema: JSONValue) throws -> String {
    guard let object = schema.aiObject else { return try schema.aiCompact() }
    let keywords = ["type", "additionalProperties", "required", "properties", "items", "enum"]
    let keys = keywords.filter { object[$0] != nil } + object.keys.filter { !keywords.contains($0) }.sorted()
    let fields = try keys.map { key -> String in
        let value = object[key] ?? .null
        let encoded: String
        if key == "properties", let properties = value.aiObject {
            let required = object["required"]?.aiArray.compactMap(\.aiString) ?? []
            let names = required.filter { properties[$0] != nil } + properties.keys.filter { !required.contains($0) }.sorted()
            encoded = "{" + (try names.map { try JSONValue.string($0).aiCompact() + ":" + aiCompactCanonicalSchema(properties[$0] ?? .null) }).joined(separator: ",") + "}"
        } else if key == "items" { encoded = try aiCompactCanonicalSchema(value) }
        else { encoded = try value.aiCompact() }
        return try JSONValue.string(key).aiCompact() + ":" + encoded
    }
    return "{" + fields.joined(separator: ",") + "}"
}

public enum AIText {
    public static func trim(_ text: String) -> String { EditingPrimitives.jsTrim(text) }
    public static func prefix(_ text: String, utf16 limit: Int) -> String {
        var units = Array(text.utf16.prefix(max(0, limit)))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let minutes = Int(floor(seconds / 60))
        let remainder = Int(floor(seconds.truncatingRemainder(dividingBy: 60)))
        return "\(minutes):\(remainder < 10 ? "0" : "")\(remainder)"
    }
    public static func estimate(_ text: String) -> Int { Int(ceil(Double(text.utf8.count) / 2.2)) }

}
