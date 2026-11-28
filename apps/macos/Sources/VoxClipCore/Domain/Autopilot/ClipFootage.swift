import Foundation

public struct ClipFootage: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case bRoll, screenshot, videoStack }

    public struct Selection: Codable, Sendable, Equatable {
        public var sourceKey: String
        public var start: Double

        static func read(_ value: JSONValue) -> Self? {
            guard let fields = value.aiObject, Set(fields.keys) == ["sourceKey", "start"],
                  let key = fields["sourceKey"]?.aiString, key.range(of: #"\A[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil,
                  let start = fields["start"]?.aiDouble, start.isFinite, start >= 0 else { return nil }
            return .init(sourceKey: key, start: start)
        }
    }

    public var id: String
    public var clipID: String
    public var kind: Kind
    public var start: Double
    public var end: Double
    public var footage: Selection
    public var fadeInSeconds: Double? = nil
    public var fadeOutSeconds: Double? = nil

    var usesTimelineEditFields: Bool { fadeInSeconds != nil || fadeOutSeconds != nil }

    public func fits(duration: Double, editedLength: Double? = nil) -> Bool {
        let length = editedLength ?? (end - start)
        return hasPlayableSource(duration: duration) && length.isFinite && length > 0 &&
            (kind == .screenshot || length <= duration - footage.start)
    }

    func hasPlayableSource(duration: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && duration.isFinite &&
        footage.start.isFinite && footage.start >= 0 && footage.start < duration &&
        [fadeInSeconds, fadeOutSeconds].compactMap { $0 }.allSatisfy { (0...2).contains($0) }
    }

    func renderInput(clipID: String, span: ClosedRange<Double>, sources: [MediaReference],
                     resolveURL: (URL) -> URL) -> ClipFootageRenderInput? {
        guard self.clipID == clipID, start >= span.lowerBound, end <= span.upperBound,
              let source = sources.first(where: { $0.footageKey == footage.sourceKey }),
              source.video != nil, fits(duration: source.durationSeconds) else { return nil }
        return ClipFootageRenderInput(entry: self, url: resolveURL(URL(fileURLWithPath: source.absolutePath)), expectedKey: source.contentKey)
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

    public mutating func setFootage(_ entry: ClipFootage, editedLength: Double? = nil) -> Bool {
        storeFootage(entry, editedLength: editedLength, allowShortSource: false)
    }

    mutating func storeFootage(_ entry: ClipFootage, editedLength: Double? = nil, allowShortSource: Bool) -> Bool {
        guard let recording = additionalSources.first(where: { $0.footageKey == entry.footage.sourceKey && $0.video != nil }),
              entry.end <= clockDurationSeconds,
              (allowShortSource ? entry.hasPlayableSource(duration: recording.durationSeconds) : entry.fits(duration: recording.durationSeconds, editedLength: editedLength)),
              !footage.contains(where: { $0.id != entry.id && $0.clipID == entry.clipID && $0.start < entry.end && entry.start < $0.end }) else { return false }
        footage.removeAll { $0.id == entry.id }
        footage.append(entry)
        return true
    }
}
