import Foundation

/// What the on-device frame analyzer saw in one source frame (ADR-R48, ai.md §19). Every rect is in picture space:
/// normalized to the frame as it plays, top-left origin. Recognised text is never stored, only where text is.
public struct FrameObservation: Codable, Sendable, Equatable {
    /// The source seconds the frame was asked for; the cache keys on it to the millisecond.
    public var time: Double
    /// How many faces Vision found.
    public var faceCount: Int
    /// The largest face, or nil when there is none.
    public var face: FrameFace?
    /// Every text box `VNRecognizeTextRequest` (fast) found, positions only.
    public var textRects: [ClipEffect.Rect]
    /// Screen-like rectangles with dense text, and dense text clusters: the basis of blur suggestions.
    public var screens: [FrameScreen]

    public init(time: Double, faceCount: Int = 0, face: FrameFace? = nil, textRects: [ClipEffect.Rect] = [], screens: [FrameScreen] = []) {
        self.time = time
        self.faceCount = faceCount
        self.face = face
        self.textRects = textRects
        self.screens = screens
    }

    /// A clear look at the speaker: a face with open eyes, good capture quality and, when Vision measured it, facing the
    /// camera (`FrameFace.facesCamera`, judged against the recording's `pitchBaseline`). The opening frame needs it.
    public func isClearLook(pitchBaseline: Double?) -> Bool {
        guard let face else { return false }
        return face.eyes == .open && (face.captureQuality ?? 0) >= FrameFace.goodQuality
            && face.facesCamera(pitchBaseline: pitchBaseline) != false
    }
}

/// Whether the eyes are open, from the eye aspect ratio (`EyeAspect`).
public enum FrameEyes: String, Codable, Sendable, Equatable { case open, closed, unknown }

/// The largest face in a frame.
public struct FrameFace: Codable, Sendable, Equatable {
    /// `VNDetectFaceCaptureQualityRequest` at or above this counts as good. Apple's score is relative (it ranks frames of
    /// one person); on the user's DJI footage a sharp, lit, frontal face scores about 0.5–0.8, a blurred or turned one
    /// under 0.35 (measured 2026-11-07, ADR-R48).
    public static let goodQuality = 0.4
    /// A face turned left or right further than this (|yaw|, radians, about 20°) does not face the camera.
    public static let yawLimit = 0.35
    /// A face tilted up or down further than this from the recording's typical pitch (radians, about 20°) does not face
    /// the camera. The typical pitch (`pitchBaseline`) is where the camera sits: on the user's footage Vision's pitch rests
    /// at +0.06 to +0.17 rad, and on studio footage at +0.1 to +0.2, so an absolute limit would count camera height as
    /// looking away (ADR-R48, evaluated 2026-11-08).
    public static let pitchLimit = 0.35

    public var rect: ClipEffect.Rect
    /// Vision's capture quality, 0–1, or nil when it was not measured.
    public var captureQuality: Double?
    /// The eye aspect ratio of each eye (`EyeAspect.ratio`), or nil without landmarks.
    public var leftEyeAspect: Double?
    public var rightEyeAspect: Double?
    /// Head rotation in radians, when Vision reports it (`VNDetectFaceRectanglesRequest` revision 3: continuous). Pitch is
    /// negative when the head tilts back (chin up), as from a camera held low.
    public var yaw: Double?
    public var pitch: Double?
    /// Derived from the eye aspect ratios when the face is made, so every reader uses the same threshold.
    public var eyes: FrameEyes

    public init(rect: ClipEffect.Rect, captureQuality: Double? = nil, leftEyeAspect: Double? = nil, rightEyeAspect: Double? = nil,
                yaw: Double? = nil, pitch: Double? = nil) {
        self.rect = rect
        self.captureQuality = captureQuality
        self.leftEyeAspect = leftEyeAspect
        self.rightEyeAspect = rightEyeAspect
        self.yaw = yaw
        self.pitch = pitch
        self.eyes = EyeAspect.state(left: leftEyeAspect, right: rightEyeAspect)
    }

    /// Whether the face faces the camera: |yaw| within `yawLimit`, and pitch within `pitchLimit` of `pitchBaseline`, the
    /// recording's typical pitch (`FrameFace.pitchBaseline`; 0 when nil). Nil when Vision reported neither angle.
    public func facesCamera(pitchBaseline: Double?) -> Bool? {
        var measured = false
        if let yaw, yaw.isFinite {
            measured = true
            if abs(yaw) > Self.yawLimit { return false }
        }
        if let pitch, pitch.isFinite {
            measured = true
            let baseline = pitchBaseline.flatMap { $0.isFinite ? $0 : nil } ?? 0
            if abs(pitch - baseline) > Self.pitchLimit { return false }
        }
        return measured ? true : nil
    }

    /// The recording's typical pitch: the median pitch of the faces in `frames` (the whole video's sentence pass, or a
    /// clip's own frames when there is no pass). Nil when no face has a pitch.
    public static func pitchBaseline(_ frames: [FrameObservation]) -> Double? {
        let pitches = frames.compactMap { $0.face?.pitch }.filter(\.isFinite).sorted()
        guard !pitches.isEmpty else { return nil }
        let middle = pitches.count / 2
        return pitches.count % 2 == 1 ? pitches[middle] : (pitches[middle - 1] + pitches[middle]) / 2
    }
}

/// The eye aspect ratio: the height of an eye's landmark contour over its width, in pixels (after Soukupová and Čech,
/// "Real-Time Eye Blink Detection using Facial Landmarks", 2016, which uses the same ratio on six points). Vision gives an
/// eye as a closed contour of 6–8 points; its bounding box's height over width is the ratio. On the user's DJI footage
/// (measured 2026-11-07) open eyes measure 0.22–0.65 and a half-closed blink 0.17–0.19.
public enum EyeAspect {
    /// An eye whose ratio is below this is closed; at or above it, open. Both eyes are averaged first, so a frame is
    /// closed when the mean is below the threshold (ADR-R48). Half-closed counts as closed: "eyes half closed" was the
    /// user's complaint about an agent's opening frame.
    public static let closedBelow = 0.20

    /// The ratio of an eye contour in pixel coordinates, or nil for fewer than three points or a flat contour.
    public static func ratio(_ points: [(x: Double, y: Double)]) -> Double? {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width > 0 else { return nil }
        return height / width
    }

    /// Open or closed from the two eyes' ratios; unknown when neither was measured.
    public static func state(left: Double?, right: Double?) -> FrameEyes {
        let values = [left, right].compactMap { $0 }.filter(\.isFinite)
        guard !values.isEmpty else { return .unknown }
        let mean = values.reduce(0, +) / Double(values.count)
        return mean < closedBelow ? .closed : .open
    }
}

/// A screen-like region with dense text: a phone or laptop screen held to the camera, or a slide.
public struct FrameScreen: Codable, Sendable, Equatable {
    public var rect: ClipEffect.Rect
    /// Text boxes whose centre lies inside the rect.
    public var textBoxes: Int
    /// The text boxes' area over the rect's area, 0–1.
    public var textCoverage: Double
    /// True when Vision found a rectangle around the text; false for a dense text cluster without one.
    public var framed: Bool
    public init(rect: ClipEffect.Rect, textBoxes: Int, textCoverage: Double, framed: Bool) {
        self.rect = rect
        self.textBoxes = textBoxes
        self.textCoverage = textCoverage
        self.framed = framed
    }
}

/// Screens from Vision's rectangles and text boxes (pure, so tests feed fabricated observations).
public enum FrameScreens {
    /// A rectangle needs at least this many text boxes inside it, covering at least `minimumCoverage` of it.
    public static let minimumBoxes = 3
    public static let minimumCoverage = 0.04
    /// A rectangle smaller than this share of the frame is not a screen.
    public static let minimumArea = 0.01
    /// Text outside any rectangle is a screen only as a cluster of at least this many boxes.
    public static let clusterBoxes = 8

    public static func detect(rectangles: [ClipEffect.Rect], texts: [ClipEffect.Rect]) -> [FrameScreen] {
        var screens: [FrameScreen] = []
        var claimed = Set<Int>()
        for rectangle in rectangles where area(rectangle) >= minimumArea {
            let inside = texts.indices.filter { contains(rectangle, x: texts[$0].midX, y: texts[$0].midY) }
            let covered = inside.map { area(texts[$0]) }.reduce(0, +)
            let coverage = min(1, covered / area(rectangle))
            guard inside.count >= minimumBoxes, coverage >= minimumCoverage else { continue }
            claimed.formUnion(inside)
            screens.append(FrameScreen(rect: rectangle.clamped, textBoxes: inside.count, textCoverage: coverage, framed: true))
        }
        for cluster in clusters(texts.indices.filter { !claimed.contains($0) }.map { texts[$0] }) where cluster.count >= clusterBoxes {
            let bounds = union(cluster)
            let covered = cluster.map(area).reduce(0, +)
            screens.append(FrameScreen(rect: bounds.clamped, textBoxes: cluster.count, textCoverage: min(1, covered / max(area(bounds), 1e-9)), framed: false))
        }
        return screens
    }

    /// Single-link clusters of boxes that touch once each is grown by half its height on every side.
    static func clusters(_ boxes: [ClipEffect.Rect]) -> [[ClipEffect.Rect]] {
        var parent = Array(boxes.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current { current = parent[current] }
            return current
        }
        let grown = boxes.map { box -> ClipEffect.Rect in
            let pad = box.height / 2
            return ClipEffect.Rect(x: box.x - pad, y: box.y - pad, width: box.width + 2 * pad, height: box.height + 2 * pad)
        }
        for first in boxes.indices {
            for second in boxes.indices where second > first && overlaps(grown[first], grown[second]) {
                parent[root(second)] = root(first)
            }
        }
        var groups: [Int: [ClipEffect.Rect]] = [:]
        var order: [Int] = []
        for index in boxes.indices {
            let key = root(index)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(boxes[index])
        }
        return order.compactMap { groups[$0] }
    }

    static func area(_ rect: ClipEffect.Rect) -> Double { max(0, rect.width) * max(0, rect.height) }

    static func contains(_ rect: ClipEffect.Rect, x: Double, y: Double) -> Bool {
        x >= rect.x && x <= rect.x + rect.width && y >= rect.y && y <= rect.y + rect.height
    }

    static func overlaps(_ a: ClipEffect.Rect, _ b: ClipEffect.Rect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    static func union(_ rects: [ClipEffect.Rect]) -> ClipEffect.Rect {
        let left = rects.map(\.x).min() ?? 0
        let top = rects.map(\.y).min() ?? 0
        let right = rects.map { $0.x + $0.width }.max() ?? 0
        let bottom = rects.map { $0.y + $0.height }.max() ?? 0
        return ClipEffect.Rect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func intersectionOverUnion(_ a: ClipEffect.Rect, _ b: ClipEffect.Rect) -> Double {
        let left = max(a.x, b.x), right = min(a.x + a.width, b.x + b.width)
        let top = max(a.y, b.y), bottom = min(a.y + a.height, b.y + b.height)
        guard right > left, bottom > top else { return 0 }
        let overlap = (right - left) * (bottom - top)
        let total = area(a) + area(b) - overlap
        return total > 0 ? overlap / total : 0
    }
}

/// The analysis of one clip: its sentence frames, its opening scan and how long each took.
public struct FrameAnalysis: Codable, Sendable, Equatable {
    /// 2: faces from `VNDetectFaceRectanglesRequest` revision 3 with continuous yaw and pitch (2026-11-08); a version-1
    /// cache holds Vision's coarse revision-2 pose and is never read.
    public static let version = 2
    public var version: Int = FrameAnalysis.version
    public var contentKey: String
    /// One frame per sampled sentence, in time order (`FrameSampling.sentenceSamples`).
    public var sentences: [FrameObservation]
    /// 10 fps over ±0.6 s at the clip's start (`FrameSampling.openingTimes`).
    public var opening: [FrameObservation]
    public var timings: FrameAnalysisTimings

    /// The clip's own typical pitch (`FrameFace.pitchBaseline` over its sentence frames and opening scan), for a caller
    /// without the whole video's pass.
    public var pitchBaseline: Double? { FrameFace.pitchBaseline(sentences + opening) }

    public init(contentKey: String, sentences: [FrameObservation], opening: [FrameObservation], timings: FrameAnalysisTimings) {
        self.contentKey = contentKey
        self.sentences = sentences
        self.opening = opening
        self.timings = timings
    }
}

/// Seconds spent, and how many frames came from the cache.
public struct FrameAnalysisTimings: Codable, Sendable, Equatable {
    public var sentenceSeconds: Double
    public var openingSeconds: Double
    public var cachedFrames: Int
    public var analyzedFrames: Int
    public init(sentenceSeconds: Double = 0, openingSeconds: Double = 0, cachedFrames: Int = 0, analyzedFrames: Int = 0) {
        self.sentenceSeconds = sentenceSeconds
        self.openingSeconds = openingSeconds
        self.cachedFrames = cachedFrames
        self.analyzedFrames = analyzedFrames
    }
}
