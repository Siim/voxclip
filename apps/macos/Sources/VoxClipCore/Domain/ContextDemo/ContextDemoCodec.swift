import Foundation

public enum ContextDemoCodec {
    public static func encode(_ document: ContextDemoDocument) throws -> Data {
        try document.validate()
        return try ProjectJSON.encoder().encode(document)
    }

    public static func decode(_ data: Data) throws -> ContextDemoDocument {
        guard data.count <= 4 * 1024 * 1024 else { throw ContextDemoError.invalidRequest }
        try validateWire(JSONSerialization.jsonObject(with: data))
        let document = try ProjectJSON.decoder().decode(ContextDemoDocument.self, from: data)
        try document.validate()
        return document
    }

    static func validateWire(_ raw: Any) throws {
        func object(_ raw: Any?, keys: String) throws -> [String: Any] {
            guard let object = raw as? [String: Any],
                  Set(object.keys).isSubset(of: Set(keys.split(separator: " ").map(String.init))) else {
                throw ContextDemoError.unsupportedVersion
            }
            return object
        }
        func target(_ raw: Any?) throws {
            _ = try object(raw, keys: "kind displayName locator")
        }
        func range(_ raw: Any?) throws {
            _ = try object(raw, keys: "start end")
        }
        let root = try object(raw, keys: "format version projectId planId revision sourceContentKey narration assets placements")
        guard root["format"] as? String == "voxclip-context-demo", root["version"] as? Int == 1 else {
            throw ContextDemoError.unsupportedVersion
        }
        let narration = try object(root["narration"], keys: "sampleRate outputSamples pieces")
        guard let pieces = narration["pieces"] as? [Any], let assets = root["assets"] as? [Any],
              let placements = root["placements"] as? [Any] else { throw ContextDemoError.invalidRequest }
        for raw in pieces {
            let piece = try object(raw, keys: "source output synthetic")
            try range(piece["source"])
            try range(piece["output"])
        }
        for raw in assets {
            let asset = try object(raw, keys: "id requestId target relativePath sha256 durationSeconds pixelWidth pixelHeight byteSize createdAt")
            try target(asset["target"])
        }
        for raw in placements {
            let placement = try object(raw, keys: "id assetId source editedStartSeconds")
            try range(placement["source"])
        }
    }
}
