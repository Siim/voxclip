import Foundation

public struct GainPoint: Codable, Sendable, Equatable {
    public var t: Double
    public var db: Double

    public init(t: Double, db: Double) {
        self.t = t
        self.db = db
    }
}

public struct ItemShape: Codable, Sendable, Equatable {
    public var fadeInSeconds: Double?
    public var fadeOutSeconds: Double?
    public var gainPoints: [GainPoint]?

    public init(fadeInSeconds: Double? = nil, fadeOutSeconds: Double? = nil, gainPoints: [GainPoint]? = nil) {
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
        self.gainPoints = gainPoints
    }

    public static let maximumGainPoints = 64

    static func validGainPoints(_ points: [GainPoint]) -> Bool {
        points.count <= maximumGainPoints && points.allSatisfy { $0.t.isFinite && $0.t >= 0 && (-60...12).contains($0.db) }
            && zip(points, points.dropFirst()).allSatisfy { $0.t < $1.t }
    }

    static func validGainPointsWire(_ value: JSONValue) -> Bool {
        guard case .array(let values) = value, values.count <= maximumGainPoints else { return false }
        return values.allSatisfy { point in
            guard case .object(let fields) = point, Set(fields.keys) == ["t", "db"],
                  case .number(let time) = fields["t"], case .number(let db) = fields["db"] else { return false }
            return time.isFinite && db.isFinite
        }
    }
}

enum TimelineEditFields {
    static let version = 6

    static func promoting(_ project: Project) throws -> Project {
        guard (1..<version).contains(project.schemaVersion),
              project.clipEffects.contains(where: \.usesTimelineEditFields) ||
              project.music.contains(where: \.usesTimelineEditFields) ||
              project.media.footage.contains(where: \.usesTimelineEditFields) else { return project }
        var result = project.schemaVersion < 4 ? try ContextDemoProject.upgradeToV4(project) : project
        result.schemaVersion = version
        return result
    }
}
