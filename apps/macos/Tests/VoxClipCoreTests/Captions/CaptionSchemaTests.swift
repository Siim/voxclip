import Foundation
import Testing
@testable import VoxClipCore

private struct CaptionSchemaDefaults {
    let root: [String: Any]

    func resolve(_ schema: [String: Any]) -> [String: Any] {
        var result = schema
        if let reference = schema["$ref"] as? String {
            let target = reference.split(separator: "/").dropFirst().reduce(root as Any?) { value, component in
                (value as? [String: Any])?[String(component)]
            }
            if let target = target as? [String: Any] { result = resolve(target) }
            else { Issue.record("Unresolved schema reference \(reference)") }
        }
        for part in schema["allOf"] as? [[String: Any]] ?? [] {
            let resolved = resolve(part)
            let properties = (result["properties"] as? [String: Any] ?? [:]).merging(resolved["properties"] as? [String: Any] ?? [:]) { _, value in value }
            result.merge(resolved) { _, value in value }
            result["properties"] = properties
        }
        return result
    }

    func stripped(_ value: Any, schema: [String: Any]) -> Any {
        let schema = resolve(schema)
        if var object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for (key, property) in properties {
                if property["default"] != nil { object.removeValue(forKey: key) }
                else if let value = object[key] { object[key] = stripped(value, schema: property) }
            }
            if object["cursor"] != nil, let original = value as? [String: Any] { object["unit"] = original["unit"] }
            return object
        }
        if let array = value as? [Any], let item = schema["items"] as? [String: Any] {
            return array.map { stripped($0, schema: item) }
        }
        return value
    }

    func assertDefaults(_ value: Any, input: Any, schema: [String: Any], path: String = "") throws -> Int {
        let schema = resolve(schema)
        var count = 0
        if let object = value as? [String: Any], let input = input as? [String: Any] {
            for (key, property) in schema["properties"] as? [String: [String: Any]] ?? [:] {
                let location = path + "." + key
                if let expected = property["default"], input[key] == nil {
                    let actual = object[key] ?? NSNull()
                    if let expectedObject = expected as? [String: Any] {
                        count += try assertDefaults(actual, input: expectedObject, schema: property, path: location)
                    } else {
                        #expect(NSDictionary(dictionary: ["value": actual]).isEqual(to: ["value": expected]), "Schema default \(location)")
                    }
                    count += 1
                } else if let child = object[key] {
                    count += try assertDefaults(child, input: input[key] ?? [:], schema: property, path: location)
                }
            }
        } else if let array = value as? [Any], let inputs = input as? [Any], let item = schema["items"] as? [String: Any] {
            for (index, child) in array.enumerated() { count += try assertDefaults(child, input: inputs[index], schema: item, path: path) }
        }
        return count
    }
}

@Test("Hand-coded caption defaults agree with every exercised schema default")
func captionSchemaDefaults() throws {
    let shared = try CaptionCoreFixtures.shared()
    let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.appendingPathComponent("caption-styles/schema.json"))) as? [String: Any])
    let checker = CaptionSchemaDefaults(root: schema)
    let styles = try FileManager.default.contentsOfDirectory(at: shared.appendingPathComponent("caption-styles/styles"), includingPropertiesForKeys: nil)
    var count = 0
    for url in styles where url.pathExtension == "json" {
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let stripped = checker.stripped(original, schema: schema)
        let style = try JSONDecoder().decode(CaptionStyle.self, from: JSONSerialization.data(withJSONObject: stripped))
        let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style))
        count += try checker.assertDefaults(actual, input: stripped, schema: schema)
    }
    #expect(count >= 400)
    let preview = try JSONDecoder().decode(CaptionPreview.self, from: Data(#"{"text":"Hello"}"#.utf8))
    #expect(CaptionPreview(text: "Hello") == preview)
}

@Test("Invalid project patches use the unpatched style and report rejection")
func invalidCaptionPatches() throws {
    let root = try CaptionCoreFixtures.shared()
    let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: root.appendingPathComponent("caption-styles/styles/karaoke.json")))
    let resources = try CaptionCoreFixtures.resources()
    let stops: [JSONValue] = (0..<6).map { .object(["offset": .number(Double($0) / 5), "color": .string("#FFFFFF")]) }
    for patch: [String: JSONValue] in [["font": .object(["sizeScale": .number(9)])], ["id": .string("another-style")], ["font": .null], ["text": .null], ["unexpected": .bool(true)], ["font": .object(["file": .string("Unbundled.ttf")])],
        ["layout": .object(["breakOnGapSec": .number(-1)])], ["layout": .object(["breakOnGapSec": .number(10.1)])],
        ["fill": .object(["type": .string("linear"), "angleDeg": .number(0), "stops": .array(stops)])]] {
        let input = CaptionLayoutInput(style: style.id, frame: .init(width: 1080, height: 1920), language: "en", duration: 1, captions: .init(overrides: patch), words: [])
        let resolution = try CaptionStyleResolver.resolution(style, input: input, resources: resources)
        #expect(resolution.rejectedOverrides)
        var clean = input
        clean.captions.overrides = [:]
        let unpatched = try CaptionStyleResolver.resolve(style, input: clean)
        #expect(resolution.style == unpatched)
    }
}

@Test("Caption schema string lengths count Unicode scalars, not graphemes")
func captionSchemaStringLengths() throws {
    let shared = try CaptionCoreFixtures.shared()
    let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
        shared.appendingPathComponent("caption-styles/styles/karaoke.json"))) as? [String: Any])
    for (field, limit) in [("name", 24), ("description", 200), ("preview", 60)] {
        for valid in [false, true] {
            var payload = original
            let text = String(repeating: "e\u{301}", count: limit / 2 + (valid ? 0 : 1))
            if field == "preview" {
                var preview = try #require(payload["preview"] as? [String: Any])
                preview["text"] = text; preview["activeWord"] = 0
                payload[field] = preview
            } else { payload[field] = text }
            let data = try JSONSerialization.data(withJSONObject: payload)
            if valid { _ = try JSONDecoder().decode(CaptionStyle.self, from: data) }
            else { #expect(throws: (any Error).self) { try JSONDecoder().decode(CaptionStyle.self, from: data) } }
        }
    }
    var payload = original
    payload["name"] = String(repeating: "😀", count: 24)
    _ = try JSONDecoder().decode(CaptionStyle.self, from: JSONSerialization.data(withJSONObject: payload))
}

@Test("Caption array elements and unique tags obey the schema")
func captionSchemaArrays() throws {
    let shared = try CaptionCoreFixtures.shared()
    let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
        shared.appendingPathComponent("caption-styles/styles/karaoke.json"))) as? [String: Any])
    for tags in [["bold", "bold"], ["invalid_tag"], [""]] {
        var payload = original
        payload["tags"] = tags
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CaptionStyle.self, from: JSONSerialization.data(withJSONObject: payload)) }
    }
    for file in ["../font.ttf", "font.otf", ""] {
        var payload = original
        var font = try #require(payload["font"] as? [String: Any])
        font["fallbackFiles"] = [file]; payload["font"] = font
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CaptionStyle.self, from: JSONSerialization.data(withJSONObject: payload)) }
    }
    for color in ["red", "#123", "#112233ZZ", "$accent/XYZ"] {
        let data = try JSONSerialization.data(withJSONObject: ["palette": [color]])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CaptionEmphasis.self, from: data) }
    }
    var payload = original
    payload["tags"] = ["bold", "latin-extended"]
    let style = try JSONDecoder().decode(CaptionStyle.self, from: JSONSerialization.data(withJSONObject: payload))
    #expect(style.tags == ["bold", "latin-extended"])
    let colors = ["#FFCC00", "#FFCC0080", "$accent", "$accent/CC"]
    let emphasis = try JSONDecoder().decode(CaptionEmphasis.self, from: JSONSerialization.data(withJSONObject: ["palette": colors]))
    #expect(emphasis.palette == colors)
}

@Test("Context-free caption seams fail explicitly rather than fabricate layout")
func captionContextRequirements() throws {
    #expect(try CaptionEasing.evaluate(.easeOutCubic, progress: 0.5) == 0.875)
    #expect(throws: CaptionFailure.self) { try CaptionEasing.evaluate(.linear, progress: .nan) }
    let resources = try CaptionCoreFixtures.resources()
    let root = try CaptionCoreFixtures.shared()
    let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: root.appendingPathComponent("caption-styles/styles/vox-bold.json")))
    #expect(throws: CaptionFailure.self) { try CaptionTextTransformer.apply("Straße", style: style, options: .init()) }
    #expect(try CaptionTextTransformer.apply("Straße 03:15.", style: style, options: .init(), language: "de", resources: resources) == "STRASSE 03:15")
    #expect(try CaptionTextTransformer.apply("i ı", style: style, options: .init(), language: "tr", resources: resources) == "İ I")
}
