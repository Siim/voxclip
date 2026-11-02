import Foundation

public struct MotionKeyframe: Codable, Sendable, Equatable {
    public let progress: Double
    public let scale: Double
    public let anchorX: Double
    public let anchorY: Double

    public init(progress: Double, scale: Double = 1, anchorX: Double = 0.5, anchorY: Double = 0.5) {
        self.progress = motionClamp(progress, lower: 0, upper: 1, fallback: 0)
        self.scale = motionClamp(scale, lower: 1, upper: MotionCue.maximumScale, fallback: 1)
        self.anchorX = motionClamp(anchorX, lower: 0, upper: 1, fallback: 0.5)
        self.anchorY = motionClamp(anchorY, lower: 0, upper: 1, fallback: 0.5)
    }

    private enum CodingKeys: String, CodingKey { case progress, scale, anchorX, anchorY }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(progress: try values.decode(Double.self, forKey: .progress),
                  scale: try values.decode(Double.self, forKey: .scale),
                  anchorX: try values.decode(Double.self, forKey: .anchorX),
                  anchorY: try values.decode(Double.self, forKey: .anchorY))
    }
}

public struct MotionCropTransform: Sendable, Equatable {
    public let scale: Double
    public let anchorX: Double
    public let anchorY: Double
    public var cropWidth: Double { 1 / scale }
    public var cropHeight: Double { 1 / scale }
    public var cropX: Double { (1 - cropWidth) * anchorX }
    public var cropY: Double { (1 - cropHeight) * anchorY }
    public static let identity = MotionCropTransform(scale: 1)

    public init(scale: Double, anchorX: Double = 0.5, anchorY: Double = 0.5) {
        let frame = MotionKeyframe(progress: 0, scale: scale, anchorX: anchorX, anchorY: anchorY)
        self.scale = frame.scale
        self.anchorX = frame.anchorX
        self.anchorY = frame.anchorY
    }
}

public struct MotionCueInterval: Sendable, Equatable {
    public let source: Range<Double>
    public let edited: Range<Double>
}

public struct MotionCue: Codable, Sendable, Equatable, Identifiable {
    public static let maximumScale = 1.35
    public static let maximumKeyframes = 8
    public static let maximumCuesPerClip = 64
    public static let maximumDuration = 120.0
    public static let minimumDuration = 0.1

    public let id: String
    public let clipID: String
    public let sourceStart: Double
    public let sourceEnd: Double
    public let keyframes: [MotionKeyframe]
    public var isValid: Bool {
        !id.isEmpty && !clipID.isEmpty && sourceEnd - sourceStart + 1e-9 >= Self.minimumDuration
    }

    public init(id: String, clipID: String, sourceStart: Double, sourceEnd: Double, keyframes: [MotionKeyframe] = []) {
        self.id = id
        self.clipID = clipID
        self.sourceStart = sourceStart.isFinite ? max(0, sourceStart) : 0
        self.sourceEnd = sourceStart.isFinite && sourceEnd.isFinite ? max(self.sourceStart, min(sourceEnd, self.sourceStart + Self.maximumDuration)) : self.sourceStart
        let ordered = keyframes.prefix(Self.maximumKeyframes).enumerated().sorted {
            $0.element.progress == $1.element.progress ? $0.offset < $1.offset : $0.element.progress < $1.element.progress
        }.map(\.element)
        var unique: [MotionKeyframe] = []
        for frame in ordered where unique.last?.progress != frame.progress { unique.append(frame) }
        let first = unique.first ?? MotionKeyframe(progress: 0)
        let last = unique.last ?? MotionKeyframe(progress: 1)
        self.keyframes = [MotionKeyframe(progress: 0, scale: first.scale, anchorX: first.anchorX, anchorY: first.anchorY)]
            + Array(unique.filter { $0.progress > 0 && $0.progress < 1 }.prefix(Self.maximumKeyframes - 2))
            + [MotionKeyframe(progress: 1, scale: last.scale, anchorX: last.anchorX, anchorY: last.anchorY)]
    }

    private enum CodingKeys: String, CodingKey { case id, clipID, sourceStart, sourceEnd, keyframes }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  clipID: try values.decode(String.self, forKey: .clipID),
                  sourceStart: try values.decode(Double.self, forKey: .sourceStart),
                  sourceEnd: try values.decode(Double.self, forKey: .sourceEnd),
                  keyframes: try values.decode([MotionKeyframe].self, forKey: .keyframes))
    }

    public func transform(atSourceTime sourceTime: Double) -> MotionCropTransform {
        guard isValid, sourceTime.isFinite, sourceTime >= sourceStart, sourceTime < sourceEnd else { return .identity }
        let progress = (sourceTime - sourceStart) / (sourceEnd - sourceStart)
        let upper = keyframes.firstIndex { $0.progress > progress } ?? (keyframes.count - 1)
        let first = keyframes[max(0, upper - 1)]
        let last = keyframes[upper]
        let fraction = motionClamp((progress - first.progress) / max(1e-12, last.progress - first.progress), lower: 0, upper: 1, fallback: 0)
        let eased = fraction * fraction * (3 - 2 * fraction)
        return MotionCropTransform(scale: first.scale + (last.scale - first.scale) * eased,
                                   anchorX: first.anchorX + (last.anchorX - first.anchorX) * eased,
                                   anchorY: first.anchorY + (last.anchorY - first.anchorY) * eased)
    }

    public static func transform(atSourceTime sourceTime: Double, clipID: String?, cues: [MotionCue], reduceMotion: Bool = false) -> MotionCropTransform {
        guard !reduceMotion, let clipID, sourceTime.isFinite else { return .identity }
        let candidates = cues.lazy.filter { $0.clipID == clipID && $0.isValid }.prefix(maximumCuesPerClip)
        let cue = candidates.filter { sourceTime >= $0.sourceStart && sourceTime < $0.sourceEnd }.min {
            $0.sourceStart == $1.sourceStart ? $0.id < $1.id : $0.sourceStart < $1.sourceStart
        }
        return cue?.transform(atSourceTime: sourceTime) ?? .identity
    }

    public func mappedIntervals(in pieces: TimelinePieces) -> [MotionCueInterval] {
        guard isValid else { return [] }
        return pieces.pieces.compactMap { piece in
            let sourceLower = max(sourceStart, piece.source.lowerBound)
            let sourceUpper = min(sourceEnd, piece.source.upperBound)
            let sourceLength = piece.source.upperBound - piece.source.lowerBound
            let editedLength = piece.edited.upperBound - piece.edited.lowerBound
            guard sourceLower.isFinite, sourceUpper.isFinite, sourceUpper > sourceLower,
                  sourceLength.isFinite, sourceLength > 0, editedLength.isFinite, editedLength > 0,
                  piece.edited.lowerBound.isFinite else { return nil }
            let lower = piece.edited.lowerBound + (sourceLower - piece.source.lowerBound) / sourceLength * editedLength
            let upper = piece.edited.lowerBound + (sourceUpper - piece.source.lowerBound) / sourceLength * editedLength
            return MotionCueInterval(source: sourceLower..<sourceUpper, edited: lower..<upper)
        }
    }
}

private func motionClamp(_ value: Double, lower: Double, upper: Double, fallback: Double) -> Double {
    value.isFinite ? min(upper, max(lower, value)) : fallback
}
