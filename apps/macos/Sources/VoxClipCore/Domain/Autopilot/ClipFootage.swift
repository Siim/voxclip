import Foundation

public struct ClipFootage: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case bRoll, screenshot, videoStack }

    public struct Selection: Codable, Sendable, Equatable {
        public let sourceKey: String
        public let start: Double

        static func read(_ value: JSONValue) -> Self? {
            guard let fields = value.aiObject, Set(fields.keys) == ["sourceKey", "start"],
                  let key = fields["sourceKey"]?.aiString, key.range(of: #"\A[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil,
                  let start = fields["start"]?.aiDouble, start.isFinite, start >= 0 else { return nil }
            return .init(sourceKey: key, start: start)
        }
    }

    public let id: String
    public let clipID: String
    public let kind: Kind
    public let start: Double
    public let end: Double
    public let footage: Selection

    public func fits(duration: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && duration.isFinite &&
        footage.start.isFinite && footage.start >= 0 && footage.start < duration &&
        (kind == .screenshot || footage.start + (end - start) <= duration)
    }

    func renderInput(clipID: String, span: ClosedRange<Double>, sources: [MediaReference],
                     resolveURL: (URL) -> URL) -> ClipFootageRenderInput? {
        guard self.clipID == clipID, start >= span.lowerBound, end <= span.upperBound,
              let source = sources.first(where: { $0.footageKey == footage.sourceKey }),
              source.video != nil, fits(duration: source.durationSeconds) else { return nil }
        return ClipFootageRenderInput(entry: self, url: resolveURL(URL(fileURLWithPath: source.absolutePath)), expectedKey: source.contentKey)
    }

    static func extendingPlanSchema(_ schema: JSONValue) -> JSONValue {
        guard var root = schema.aiObject, var properties = root["properties"]?.aiObject,
              var effects = properties["effects"]?.aiObject, var items = effects["items"]?.aiObject,
              var fields = items["properties"]?.aiObject, var kind = fields["kind"]?.aiObject else { return schema }
        kind["enum"] = .array((kind["enum"]?.aiArray ?? []) + ["bRoll", "screenshot", "videoStack"].map(JSONValue.string))
        fields["kind"] = .object(kind)
        fields["footage"] = .object(["type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("sourceKey"), .string("start")]), "properties": .object([
                "sourceKey": .object(["type": .string("string")]), "start": .object(["type": .string("number")])])])
        items["required"] = .array((items["required"]?.aiArray ?? []) + [.string("footage")])
        items["properties"] = .object(fields)
        effects["items"] = .object(items)
        properties["effects"] = .object(effects)
        root["properties"] = .object(properties)
        return .object(root)
    }
}

public struct ClipFootageRenderInput: Sendable, Equatable {
    public let entry: ClipFootage
    public let url: URL
    public let expectedKey: String?

    public init(entry: ClipFootage, url: URL, expectedKey: String? = nil) {
        self.entry = entry; self.url = url; self.expectedKey = expectedKey
    }
}

extension ProjectMedia {
    public var footageDurations: [String: Double] {
        Dictionary(additionalSources.filter { $0.video != nil }.map { ($0.footageKey, $0.durationSeconds) }, uniquingKeysWith: { first, _ in first })
    }

    public mutating func setFootage(_ entry: ClipFootage) -> Bool {
        guard let recording = additionalSources.first(where: { $0.footageKey == entry.footage.sourceKey && $0.video != nil }),
              entry.end <= source.durationSeconds, entry.fits(duration: recording.durationSeconds),
              !footage.contains(where: { $0.id != entry.id && $0.clipID == entry.clipID && $0.start < entry.end && entry.start < $0.end }) else { return false }
        footage.removeAll { $0.id == entry.id }
        footage.append(entry)
        return true
    }
}
