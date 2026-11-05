import Foundation

/// The colour look of a clip (design.md §6.9, ai.md §16.2). The planner (`ClipAutopilotPlan.LookID`) and the renderer
/// share these ids; the Core Image recipes live in VoxClipMedia `ClipLookFilter`.
public enum ClipLook: String, Codable, Sendable, CaseIterable {
    /// The footage as filmed.
    case original
    /// A calm grade: about 35% less saturation and lifted blacks.
    case muted
    /// A soft golden grade: a small temperature and tint shift.
    case warm
    /// Black and white with a gentle contrast curve.
    case bw

    /// The name the Clip section shows.
    public var label: String {
        switch self {
        case .original: "Original"
        case .muted: "Muted"
        case .warm: "Warm"
        case .bw: "B&W"
        }
    }
}

/// A clip's own frame (design.md §6.9). Nil on a clip keeps the project's export frame (`export.aspect`); 4:5 exists only
/// here, so `export.aspect` and its schema enum are unchanged.
public enum ClipShape: String, Codable, Sendable, CaseIterable {
    case landscape = "16:9"
    case portrait = "9:16"
    case square = "1:1"
    case portraitFourFive = "4:5"

    /// The rendered size: the same 1080-line frames the export presets use, 1080 × 1350 for 4:5.
    public var size: PixelSize {
        switch self {
        case .landscape: PixelSize(width: 1920, height: 1080)
        case .portrait: PixelSize(width: 1080, height: 1920)
        case .square: PixelSize(width: 1080, height: 1080)
        case .portraitFourFive: PixelSize(width: 1080, height: 1350)
        }
    }

    /// The export bitrate base before the quality and frame-rate multipliers (OutputSizing.videoBitrate's rule).
    var baseBitrate: Double {
        switch self {
        case .landscape, .portrait: 8_000_000
        case .square: 6_000_000
        case .portraitFourFive: 6_500_000
        }
    }
}

/// One clip's playback controls (design.md §6.9): speed, frame, look, source volume, fades, mute, flip and rotation.
/// Stored under the schema-v4 root field `clipControls`, one entry per clip, every key written. An entry that equals
/// the defaults is never stored, so a project without controls saves byte-identically.
public struct ProjectClipControls: Codable, Sendable, Equatable {
    public var clipId: String
    /// Playback rate, 0.5–2.0 (1 plays as recorded). The voice keeps its pitch.
    public var speed: Double
    /// The clip's own frame; nil keeps the project's export frame.
    public var shape: ClipShape?
    public var look: ClipLook
    /// Source audio level, −24…+12 dB.
    public var gainDb: Double
    public var fadeInSeconds: Double
    public var fadeOutSeconds: Double
    /// Silences the clip's own audio; a music bed still plays.
    public var muteSource: Bool
    /// Mirrors the picture left to right.
    public var flipHorizontal: Bool
    /// Clockwise quarter turns: 0, 90, 180 or 270.
    public var rotationDegrees: Int

    public static let speedRange = 0.5...2.0
    public static let speedPresets: [Double] = [0.75, 1, 1.1, 1.25, 1.5, 2]
    public static let gainRange = -24.0...12.0
    public static let fadeRange = 0.0...5.0
    public static let rotations = [0, 90, 180, 270]
    public static let maximumEntries = 64

    public init(clipId: String, speed: Double = 1, shape: ClipShape? = nil, look: ClipLook = .original, gainDb: Double = 0,
                fadeInSeconds: Double = 0, fadeOutSeconds: Double = 0, muteSource: Bool = false, flipHorizontal: Bool = false,
                rotationDegrees: Int = 0) {
        self.clipId = clipId; self.speed = speed; self.shape = shape; self.look = look; self.gainDb = gainDb
        self.fadeInSeconds = fadeInSeconds; self.fadeOutSeconds = fadeOutSeconds; self.muteSource = muteSource
        self.flipHorizontal = flipHorizontal; self.rotationDegrees = rotationDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case clipId, speed, shape, look, gainDb, fadeInSeconds, fadeOutSeconds, muteSource, flipHorizontal, rotationDegrees
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clipId = try values.decode(String.self, forKey: .clipId)
        speed = try values.decode(Double.self, forKey: .speed)
        shape = try values.decode(ClipShape?.self, forKey: .shape)
        look = try values.decode(ClipLook.self, forKey: .look)
        gainDb = try values.decode(Double.self, forKey: .gainDb)
        fadeInSeconds = try values.decode(Double.self, forKey: .fadeInSeconds)
        fadeOutSeconds = try values.decode(Double.self, forKey: .fadeOutSeconds)
        muteSource = try values.decode(Bool.self, forKey: .muteSource)
        flipHorizontal = try values.decode(Bool.self, forKey: .flipHorizontal)
        rotationDegrees = try values.decode(Int.self, forKey: .rotationDegrees)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(clipId, forKey: .clipId)
        try values.encode(speed, forKey: .speed)
        try values.encode(shape, forKey: .shape)
        try values.encode(look, forKey: .look)
        try values.encode(gainDb, forKey: .gainDb)
        try values.encode(fadeInSeconds, forKey: .fadeInSeconds)
        try values.encode(fadeOutSeconds, forKey: .fadeOutSeconds)
        try values.encode(muteSource, forKey: .muteSource)
        try values.encode(flipHorizontal, forKey: .flipHorizontal)
        try values.encode(rotationDegrees, forKey: .rotationDegrees)
    }

    /// Every control at its default: nothing to store or render.
    public var isDefault: Bool { self == ProjectClipControls(clipId: clipId) }
    /// Speed, volume, fades or mute change the clip's audio.
    public var changesAudio: Bool { speed != 1 || gainDb != 0 || fadeInSeconds > 0 || fadeOutSeconds > 0 || muteSource }
    /// Look, flip or rotation change each frame.
    public var changesPicture: Bool { look != .original || flipHorizontal || rotationDegrees != 0 }
    /// A quarter turn swaps the picture's width and height.
    public var isQuarterTurn: Bool { rotationDegrees == 90 || rotationDegrees == 270 }

    /// "1.1×", "0.75×", "2×": the speed with no trailing zeros.
    public static func speedLabel(_ rate: Double) -> String {
        let hundredths = Int((rate * 100).rounded())
        var text = String(hundredths / 100)
        let fraction = hundredths % 100
        if fraction != 0 { text += "." + (fraction % 10 == 0 ? String(fraction / 10) : String(format: "%02d", fraction)) }
        return text + "\u{00D7}"
    }

    /// The speed a slider or command asks for, clamped to the range and rounded to hundredths.
    public static func normalizedSpeed(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        return (rate.clamped(to: speedRange) * 100).rounded() / 100
    }

    /// Volume clamped and rounded to half decibels.
    public static func normalizedGain(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return (db.clamped(to: gainRange) * 2).rounded() / 2
    }

    /// Fade lengths clamped and rounded to tenths of a second.
    public static func normalizedFade(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return (seconds.clamped(to: fadeRange) * 10).rounded() / 10
    }

    /// The nearest quarter turn, clockwise, in 0…270.
    public static func normalizedRotation(_ degrees: Int) -> Int { ((degrees % 360 + 360) % 360 + 45) / 90 % 4 * 90 }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

public enum ClipControlsProjectError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedVersion, invalidEntry(String), unknownClip, duplicateClip, defaultEntry

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Clip controls need the current project format."
        case .invalidEntry(let reason): "The project's clip controls are invalid: \(reason)."
        case .unknownClip: "Clip controls refer to a clip that is not in the project."
        case .duplicateClip: "A clip has more than one set of clip controls."
        case .defaultEntry: "Clip controls at their defaults are not stored."
        }
    }
}

/// The `clipControls` root field: schema v4 only, omitted when empty (design.md §6.9 and project schema
/// `$defs.clipControls`). Version decision: stays in v4, as `music` does (tools/schemas/generate_clip_controls_schema.py).
public enum ClipControlsProject {
    static let identifier = #"\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z"#

    /// The typed rules the schema cannot express: the clip exists, one entry per clip, no stored default entry.
    public static func validate(_ project: Project) throws {
        guard !project.clipControls.isEmpty else { return }
        guard project.schemaVersion == 4 else { throw ClipControlsProjectError.unsupportedVersion }
        guard project.clipControls.count <= ProjectClipControls.maximumEntries else { throw ClipControlsProjectError.invalidEntry("too many entries") }
        let clips = Set(project.edits.clips.map(\.id))
        var seen = Set<String>()
        for entry in project.clipControls {
            try validate(entry)
            guard clips.contains(entry.clipId) else { throw ClipControlsProjectError.unknownClip }
            guard seen.insert(entry.clipId).inserted else { throw ClipControlsProjectError.duplicateClip }
        }
    }

    public static func validate(_ entry: ProjectClipControls) throws {
        func require(_ condition: Bool, _ reason: String) throws { if !condition { throw ClipControlsProjectError.invalidEntry(reason) } }
        try require(entry.clipId.range(of: identifier, options: .regularExpression) != nil, "clip id")
        try require(entry.speed.isFinite && ProjectClipControls.speedRange.contains(entry.speed), "speed")
        try require(entry.gainDb.isFinite && ProjectClipControls.gainRange.contains(entry.gainDb), "gain")
        try require(entry.fadeInSeconds.isFinite && ProjectClipControls.fadeRange.contains(entry.fadeInSeconds), "fade-in")
        try require(entry.fadeOutSeconds.isFinite && ProjectClipControls.fadeRange.contains(entry.fadeOutSeconds), "fade-out")
        try require(ProjectClipControls.rotations.contains(entry.rotationDegrees), "rotation")
        guard !entry.isDefault else { throw ClipControlsProjectError.defaultEntry }
    }

    /// Strict wire shape before decoding: exact keys and JSON types.
    static func validateWire(_ value: JSONValue) throws {
        guard case .array(let entries) = value, !entries.isEmpty, entries.count <= ProjectClipControls.maximumEntries else {
            throw ClipControlsProjectError.invalidEntry("not a list")
        }
        let keys: Set<String> = ["clipId", "speed", "shape", "look", "gainDb", "fadeInSeconds", "fadeOutSeconds", "muteSource",
                                 "flipHorizontal", "rotationDegrees"]
        for entry in entries {
            guard case .object(let object) = entry, Set(object.keys) == keys else {
                throw ClipControlsProjectError.invalidEntry("unknown or missing field")
            }
            func number(_ key: String) -> Bool { if case .number(let value) = object[key] { return value.isFinite } else { return false } }
            func bool(_ key: String) -> Bool { if case .bool = object[key] { return true } else { return false } }
            func string(_ key: String, nullable: Bool = false) -> Bool {
                if case .string = object[key] { return true }
                return nullable && object[key] == .null
            }
            guard string("clipId"), number("speed"), string("shape", nullable: true), string("look"), number("gainDb"),
                  number("fadeInSeconds"), number("fadeOutSeconds"), bool("muteSource"), bool("flipHorizontal"),
                  case .number(let rotation) = object["rotationDegrees"], rotation.rounded() == rotation else {
                throw ClipControlsProjectError.invalidEntry("field type")
            }
        }
    }

    /// The controls a clip renders with: its stored entry, or the defaults.
    public static func controls(for clipId: String?, in project: Project) -> ProjectClipControls? {
        guard let clipId else { return nil }
        return project.clipControls.first { $0.clipId == clipId } ?? ProjectClipControls(clipId: clipId)
    }

    /// Stores `controls` for its clip, removing the entry when it is back at the defaults; the first stored entry promotes
    /// the project to v4.
    public static func setting(_ controls: ProjectClipControls, in project: Project) throws -> Project {
        guard project.edits.clips.contains(where: { $0.id == controls.clipId }) else { throw ClipControlsProjectError.unknownClip }
        var result = project
        result.clipControls.removeAll { $0.clipId == controls.clipId }
        if !controls.isDefault {
            try validate(controls)
            result = try ContextDemoProject.upgradeToV4(result)
            result.clipControls.append(controls)
        }
        try validate(result)
        return result
    }

    /// `project` with one clip's speed set to `rate` (normalised, as the Clip section's slider is) and its other controls
    /// kept. Make it postable's planner speed and Ask Claude's whole-clip stretch go through here.
    public static func settingSpeed(_ rate: Double, clipId: String, in project: Project) throws -> Project {
        guard var controls = controls(for: clipId, in: project) else { throw ClipControlsProjectError.unknownClip }
        controls.speed = ProjectClipControls.normalizedSpeed(rate)
        return try setting(controls, in: project)
    }

    /// `project` with one clip's look set and its other controls kept.
    public static func settingLook(_ look: ClipLook, clipId: String, in project: Project) throws -> Project {
        guard var controls = controls(for: clipId, in: project) else { throw ClipControlsProjectError.unknownClip }
        controls.look = look
        return try setting(controls, in: project)
    }

    /// A clip's span in source seconds: its first word's start to its last word's end.
    public static func sourceSpan(of clipId: String, in project: Project) -> ClosedRange<Double>? {
        guard let clip = project.edits.clips.first(where: { $0.id == clipId }), let words = project.transcript?.words,
              let first = words.first(where: { $0.id == clip.startWordId }), let last = words.first(where: { $0.id == clip.endWordId }),
              last.end > first.start else { return nil }
        return first.start...last.end
    }

    /// How far a stretch may miss a clip's ends and still count as the whole clip (Ask Claude's speed, ai.md §18).
    public static let wholeClipToleranceSeconds = 0.25

    /// The clip a stretch of source seconds plays whole: `clipId`'s, else the one clip whose span it matches, within
    /// `wholeClipToleranceSeconds` at each end. Nil for a part of a clip, which a clip's single speed cannot play.
    public static func wholeClip(_ clipId: String?, start: Double, end: Double, in project: Project) -> String? {
        let tolerance = wholeClipToleranceSeconds + 1e-9
        func covers(_ id: String) -> Bool {
            guard let span = sourceSpan(of: id, in: project) else { return false }
            return abs(span.lowerBound - start) <= tolerance && abs(span.upperBound - end) <= tolerance
        }
        if let clipId { return covers(clipId) ? clipId : nil }
        let matching = project.edits.clips.map(\.id).filter(covers)
        return matching.count == 1 ? matching[0] : nil
    }

    /// Keeps only entries whose clip still exists.
    public static func pruned(_ controls: [ProjectClipControls], clips: [ClipRange]) -> [ProjectClipControls] {
        let identities = Set(clips.map(\.id))
        return controls.filter { identities.contains($0.clipId) }
    }
}

/// How a clip's speed maps the 1× edited timeline onto the rendered one (design.md §6.9). Every caption, word, cut and motion
/// cue keeps its 1× edited time; the renderer and the preview clock divide by the speed, and the compositor multiplies a
/// rendered frame time back before it looks up captions, motion and Voice Lab layers.
public struct ClipSpeedTiming: Sendable, Equatable {
    public let speed: Double

    public init(speed: Double) { self.speed = speed.isFinite && speed > 0 ? speed : 1 }

    /// Rendered seconds for an edited time.
    public func rendered(_ edited: Double) -> Double { speed == 1 ? edited : edited / speed }
    /// Edited seconds for a rendered time.
    public func edited(_ rendered: Double) -> Double { speed == 1 ? rendered : rendered * speed }
    /// The rendered sample count of `samples` edited samples.
    public func renderedSamples(_ samples: Int64) -> Int64 {
        speed == 1 ? samples : Int64((Double(samples) / speed).rounded())
    }
}

extension RenderRequest {
    /// The clip's speed (1 without controls).
    public var speed: Double { clipControls?.speed ?? 1 }
    public var speedTiming: ClipSpeedTiming { ClipSpeedTiming(speed: speed) }
    /// The rendered length in samples at the timeline's rate: the edited length divided by the speed.
    public var renderedSamples: Int64 { speedTiming.renderedSamples(timeline.outputSamples) }
    /// The rendered length in seconds.
    public var renderedDuration: Double { Double(renderedSamples) / timeline.sampleRate }

    /// The same render at 1× with no clip controls: edited-audio checks and probes read the clip as recorded.
    public var withoutClipControls: RenderRequest {
        var result = self
        result.clipControls = nil
        return result
    }
}

extension OutputSizing {
    /// The frame a clip renders in (design.md §6.9): its own shape, else the project frame. An Original frame turns with a
    /// quarter turn so the whole picture stays in view; a fixed shape keeps its size and crops the turned picture to fill.
    public static func outputSize(source: PixelSize, aspect: AspectRatio, controls: ProjectClipControls?) throws -> PixelSize {
        if let shape = controls?.shape { return shape.size }
        let turned = controls?.isQuarterTurn == true ? PixelSize(width: source.height, height: source.width) : source
        return try outputSize(source: turned, aspect: aspect)
    }

    /// The export bitrate for a clip's frame; without a shape, the project frame's rule.
    public static func videoBitrate(size: PixelSize, aspect: AspectRatio, quality: ExportQuality, fps: Double,
                                    controls: ProjectClipControls?) -> Int {
        guard let shape = controls?.shape else { return videoBitrate(size: size, aspect: aspect, quality: quality, fps: fps) }
        let qualityScale: Double = quality == .high ? 1.5 : 1
        let rateScale: Double = fps >= 50 ? 1.5 : 1
        return Int(floor(shape.baseBitrate * qualityScale * rateScale + 0.5))
    }
}

/// The source-audio level of a clip at a rendered time (design.md §6.9): volume times the linear fades, or silence when the
/// source is muted. It acts on the clip's voice track (the source with any Voice Lab phrases already mixed in), before a music
/// bed measures that voice for ducking.
public enum ClipAudioMix {
    public static func linearGain(_ controls: ProjectClipControls) -> Double {
        controls.muteSource ? 0 : pow(10, controls.gainDb / 20)
    }

    public static func gain(at seconds: Double, duration: Double, controls: ProjectClipControls) -> Double {
        linearGain(controls) * MusicMix.fadeFactor(at: seconds, duration: duration, fadeIn: controls.fadeInSeconds,
                                                   fadeOut: controls.fadeOutSeconds)
    }
}

extension ProjectClipControls {
    /// Where a framing anchor (x right, y down, 0…1 of the source) lands after the flip and the quarter turns.
    public func mapAnchor(x: Double, y: Double) -> (x: Double, y: Double) {
        var point = (x: flipHorizontal ? 1 - x : x, y: y)
        switch rotationDegrees {
        case 90: point = (x: 1 - point.y, y: point.x)
        case 180: point = (x: 1 - point.x, y: 1 - point.y)
        case 270: point = (x: point.y, y: 1 - point.x)
        default: break
        }
        return point
    }

    /// Where a region of the source as filmed (top-left normalized, as Ask Claude and Vision give it) lands after the flip
    /// and the quarter turns, so a blur or a pointer stays on the same content.
    public func mapRect(_ rect: ClipEffect.Rect) -> ClipEffect.Rect {
        guard flipHorizontal || rotationDegrees != 0 else { return rect }
        let first = mapAnchor(x: rect.x, y: rect.y), second = mapAnchor(x: rect.x + rect.width, y: rect.y + rect.height)
        let x = min(first.x, second.x), y = min(first.y, second.y)
        return ClipEffect.Rect(x: x, y: y, width: max(first.x, second.x) - x, height: max(first.y, second.y) - y)
    }
}

/// A look's numbers (design.md §6.9): a 3 × 3 colour matrix with a bias, then an optional cubic per channel
/// (`a0 + a1·x + a2·x² + a3·x³`), on encoded 0…1 values. The Mac compositor runs them as CIColorMatrix and
/// CIColorPolynomial; a Windows renderer can run the same numbers.
public struct ClipLookRecipe: Sendable, Equatable {
    public let matrix: [[Double]]
    public let bias: [Double]
    public let curve: [Double]?

    /// Rec. 709 luma weights.
    static let luma = [0.2126, 0.7152, 0.0722]

    /// Saturation `s` about luma: `(1 − s)·L + s·I`, scaled by `scale`.
    static func saturation(_ s: Double, scale: Double = 1) -> [[Double]] {
        (0..<3).map { row in (0..<3).map { column in scale * ((1 - s) * luma[column] + (row == column ? s : 0)) } }
    }

    public init(_ look: ClipLook) {
        switch look {
        case .original:
            matrix = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]; bias = [0, 0, 0]; curve = nil
        case .muted:
            // 35% less saturation, then blacks lifted 4% (white stays white).
            matrix = Self.saturation(0.65, scale: 0.96); bias = [0.04, 0.04, 0.04]; curve = nil
        case .warm:
            // A small temperature shift (red up 6%, blue down 10%) with a slight green tint.
            matrix = [[1.06, 0, 0], [0, 1.01, 0], [0, 0, 0.9]]; bias = [0.01, 0.01, 0.01]; curve = nil
        case .bw:
            // Luma mono, then a gentle S curve: 0.5 + 1.15u − 0.6u³ for u = x − 0.5 (0 → 0, ½ → ½, 1 → 1).
            matrix = Self.saturation(0); bias = [0, 0, 0]; curve = [0, 0.7, 0.9, -0.6]
        }
    }

    public var isIdentity: Bool { self == ClipLookRecipe(.original) }

    /// The recipe on one RGB value, clamped to 0…1 as an 8-bit frame stores it.
    public func apply(_ rgb: [Double]) -> [Double] {
        (0..<3).map { row in
            var value = bias[row]
            for column in 0..<3 { value += matrix[row][column] * rgb[column] }
            value = min(1, max(0, value))
            if let curve {
                let squared = value * value
                value = curve[0] + curve[1] * value + curve[2] * squared + curve[3] * squared * value
            }
            return min(1, max(0, value))
        }
    }
}
