import Foundation

/// A small frame Auto and the light facts read (looks spec §5.9, §9.3): the framed picture before any grade, 8-bit RGB
/// with rows from the top, and the largest face, normalised from the top left, when there is one. The platforms decode up
/// to `ClipColorMeasure.Auto.frames` of a clip's analysed frames at `frameSize` pixels on the long side.
public struct ClipFrameSample: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width × height` pixels, three bytes each.
    public let rgb: [UInt8]
    public let face: ClipEffect.Rect?

    public init(width: Int, height: Int, rgb: [UInt8], face: ClipEffect.Rect? = nil) {
        precondition(width > 0 && height > 0 && rgb.count == width * height * 3, "a frame sample holds width × height RGB pixels")
        self.width = width
        self.height = height
        self.rgb = rgb
        self.face = face
    }

    /// Every pixel as 0…1 values.
    var pixels: [[Double]] { stride(from: 0, to: rgb.count, by: 3).map { [Double(rgb[$0]) / 255, Double(rgb[$0 + 1]) / 255, Double(rgb[$0 + 2]) / 255] } }

    /// The pixels whose centre lies in the face box.
    var facePixels: [[Double]] {
        guard let face else { return [] }
        let w = Double(width), h = Double(height)
        let x0 = face.x * w, x1 = (face.x + face.width) * w, y0 = face.y * h, y1 = (face.y + face.height) * h
        return pixels.enumerated().compactMap { index, pixel in
            let cx = Double(index % width) + 0.5, cy = Double(index / width) + 0.5
            return x0 <= cx && cx < x1 && y0 <= cy && cy < y1 ? pixel : nil
        }
    }
}

/// `measure` in shared/looks/clip-looks.json: the numbers Auto (`auto`) and the planner's light notes (`light`) share on
/// both platforms (looks spec §5.9, §9.3).
public struct ClipColorMeasure: Sendable, Equatable {
    public struct Auto: Sendable, Equatable {
        /// How many analysed frames Auto reads, and their long side in pixels.
        public let frames: Int
        public let frameSize: Int
        /// A neutral pixel: chroma (max − min) under `neutralChroma` and luma within `neutralLumaMin…neutralLumaMax`.
        public let neutralChroma: Double
        public let neutralLumaMin: Double
        public let neutralLumaMax: Double
        /// Temperature and Tint: the full white-balance correction times `balanceScale` points, clamped to ±`balanceLimit`,
        /// and 0 within ±`balanceDeadZone`.
        public let balanceScale: Double
        public let balanceLimit: Double
        public let balanceDeadZone: Double
        /// Exposure moves the face's median luma toward `faceTarget`, or the frame's toward `frameTarget` without a face,
        /// by `exposureStrength` of the way, clamped to ±`exposureLimit` points with a ±`exposureDeadZone` dead zone.
        public let faceTarget: Double
        public let frameTarget: Double
        public let exposureStrength: Double
        public let exposureLimit: Double
        public let exposureDeadZone: Double
        /// Exposure never rises when more than `faceClipShare` of the face's pixels have a luma above `faceClipLuma`.
        public let faceClipLuma: Double
        public let faceClipShare: Double
    }

    public struct Light: Sendable, Equatable {
        /// "face a little dark" under this face median luma.
        public let dimFaceLuma: Double
        /// A face pixel with a channel at or above this is clipped; "highlights clipped" above `clippedShare` of the face.
        public let clippedChannel: Double
        public let clippedShare: Double
        /// A cast when the neutral pixels' red and blue means differ by more than `warmCool`, or green and the red-blue
        /// mean by more than `greenMagenta`.
        public let warmCool: Double
        public let greenMagenta: Double
        /// "low color" under this mean chroma, "high color" over `highColor`.
        public let lowColor: Double
        public let highColor: Double
    }

    public let auto: Auto
    public let light: Light

    /// The file's groups, which must hold exactly these keys.
    init?(_ groups: [String: [String: Double]]) {
        let autoKeys: Set<String> = ["frames", "frameSize", "neutralChroma", "neutralLumaMin", "neutralLumaMax", "balanceScale", "balanceLimit",
                                     "balanceDeadZone", "faceTarget", "frameTarget", "exposureStrength", "exposureLimit", "exposureDeadZone",
                                     "faceClipLuma", "faceClipShare"]
        let lightKeys: Set<String> = ["dimFaceLuma", "clippedChannel", "clippedShare", "warmCool", "greenMagenta", "lowColor", "highColor"]
        guard Set(groups.keys) == ["auto", "light"], let a = groups["auto"], let l = groups["light"], Set(a.keys) == autoKeys,
              Set(l.keys) == lightKeys, let frames = a["frames"], let size = a["frameSize"], frames >= 1, frames.rounded() == frames,
              size >= 1, size.rounded() == size, a["neutralLumaMin"]! <= a["neutralLumaMax"]! else { return nil }
        auto = Auto(frames: Int(frames), frameSize: Int(size), neutralChroma: a["neutralChroma"]!, neutralLumaMin: a["neutralLumaMin"]!,
                    neutralLumaMax: a["neutralLumaMax"]!, balanceScale: a["balanceScale"]!, balanceLimit: a["balanceLimit"]!,
                    balanceDeadZone: a["balanceDeadZone"]!, faceTarget: a["faceTarget"]!, frameTarget: a["frameTarget"]!,
                    exposureStrength: a["exposureStrength"]!, exposureLimit: a["exposureLimit"]!, exposureDeadZone: a["exposureDeadZone"]!,
                    faceClipLuma: a["faceClipLuma"]!, faceClipShare: a["faceClipShare"]!)
        light = Light(dimFaceLuma: l["dimFaceLuma"]!, clippedChannel: l["clippedChannel"]!, clippedShare: l["clippedShare"]!,
                      warmCool: l["warmCool"]!, greenMagenta: l["greenMagenta"]!, lowColor: l["lowColor"]!, highColor: l["highColor"]!)
    }

    static func chroma(_ c: [Double]) -> Double { c.max()! - c.min()! }

    static func isNeutral(_ c: [Double], _ auto: Auto) -> Bool {
        let l = ClipGradeRecipe.luma(c)
        return chroma(c) < auto.neutralChroma && auto.neutralLumaMin <= l && l <= auto.neutralLumaMax
    }

    /// The grey-world means of the neutral pixels, or nil without any.
    static func neutralMeans(_ pixels: [[Double]], _ auto: Auto) -> [Double]? {
        var sums = [0.0, 0.0, 0.0], count = 0
        for pixel in pixels where isNeutral(pixel, auto) {
            for channel in 0..<3 { sums[channel] += pixel[channel] }
            count += 1
        }
        return count == 0 ? nil : sums.map { $0 / Double(count) }
    }

    static func median(_ values: [Double]) -> Double {
        let ordered = values.sorted(), n = ordered.count
        return n % 2 == 1 ? ordered[n / 2] : (ordered[n / 2 - 1] + ordered[n / 2]) / 2
    }

    static func sum(_ values: [Double]) -> Double { values.reduce(0, +) }

    /// Half away from zero, the rounding every Core uses for points.
    static func points(_ value: Double) -> Int { Int((abs(value) + 0.5).rounded(.down)) * (value >= 0 ? 1 : -1) }

    /// Clamped to ±`limit`, rounded, and 0 within ±`zone`.
    static func deadZone(_ value: Double, limit: Double, zone: Double) -> Int {
        let point = points(min(limit, max(-limit, value)))
        return Double(abs(point)) <= zone ? 0 : point
    }
}

extension ClipColorFix {
    /// Auto (looks spec §5.9): a partial white balance from the neutral pixels and an exposure toward a face or frame target,
    /// on up to `constants.frames` frames before any grade. No AI; each platform measures its own decoded frames, so a value
    /// can differ by a point between them. Nothing measurable gives the neutral Fix.
    public static func measure(_ frames: [ClipFrameSample], constants auto: ClipColorMeasure.Auto) -> ClipColorFix {
        let used = frames.prefix(auto.frames)
        let every = used.flatMap(\.pixels)
        guard !every.isEmpty else { return .neutral }
        var temperature = 0, tint = 0
        if let means = ClipColorMeasure.neutralMeans(every, auto) {
            let (r, g, b) = (means[0], means[1], means[2])
            let t = 2 * log2(b / r), k = log2(g * g / (r * b)) / 0.6
            temperature = ClipColorMeasure.deadZone(auto.balanceScale * t, limit: auto.balanceLimit, zone: auto.balanceDeadZone)
            tint = ClipColorMeasure.deadZone(auto.balanceScale * k, limit: auto.balanceLimit, zone: auto.balanceDeadZone)
        }
        let faces = used.flatMap(\.facePixels)
        let middle = ClipColorMeasure.median((faces.isEmpty ? every : faces).map(ClipGradeRecipe.luma))
        let target = faces.isEmpty ? auto.frameTarget : auto.faceTarget
        let raw = middle > 0 ? auto.exposureStrength * log2(target / middle) / 0.009 : .infinity
        var exposure = ClipColorMeasure.deadZone(raw, limit: auto.exposureLimit, zone: auto.exposureDeadZone)
        let clipped = faces.filter { ClipGradeRecipe.luma($0) > auto.faceClipLuma }.count
        if !faces.isEmpty, Double(clipped) / Double(faces.count) > auto.faceClipShare { exposure = min(exposure, 0) }
        return ClipColorFix(exposure: exposure, temperature: temperature, tint: tint)
    }
}

/// One analysed frame's light (looks spec §9.3), measured on the device and summarised for the planner as one line, such
/// as "light: face a little dark · warm-yellow cast". It never measures or names skin colour.
public struct ClipLightFacts: Sendable, Equatable {
    public enum Note: Sendable, Equatable {
        case dimFace
        case clipped(percent: Int)
        case warmCast, coolCast, greenCast, magentaCast
        case lowColor, highColor

        public var text: String {
            switch self {
            case .dimFace: "face a little dark"
            case .clipped(let percent): "highlights clipped \(percent)%"
            case .warmCast: "warm-yellow cast"
            case .coolCast: "cool-blue cast"
            case .greenCast: "green cast"
            case .magentaCast: "magenta cast"
            case .lowColor: "low color"
            case .highColor: "high color"
            }
        }
    }

    public let medianLuma: Double
    /// The nearest-rank 95th percentile.
    public let p95Luma: Double
    public let faceMeanLuma: Double?
    public let faceMedianLuma: Double?
    /// The share of face pixels with a channel at or above `Light.clippedChannel`.
    public let faceClippedShare: Double?
    /// The neutral pixels' mean red, green and blue, or nil without any.
    public let neutralMeans: [Double]?
    public let meanChroma: Double
    public let notes: [Note]

    public init(_ frame: ClipFrameSample, measure: ClipColorMeasure) { self.init(FrameLight(frame, measure: measure), light: measure.light) }

    /// The facts of a frame's measured light, with its notes from `light`'s thresholds.
    public init(_ facts: FrameLight, light: ClipColorMeasure.Light) {
        medianLuma = facts.medianLuma
        p95Luma = facts.p95Luma
        faceMeanLuma = facts.faceMeanLuma
        faceMedianLuma = facts.faceMedianLuma
        faceClippedShare = facts.faceClippedShare
        neutralMeans = facts.neutralMeans
        meanChroma = facts.meanChroma
        notes = facts.notes(light)
    }

    /// The planner's line: "light: " and the notes, or "light: even".
    public var line: String { "light: " + (notes.isEmpty ? "even" : notes.map(\.text).joined(separator: " · ")) }
}
