import Foundation

/// A clip's whole colour grade (looks spec 2026-11-28, sections 5 and 6; design.md §6.9) as per-frame constants in double,
/// with the reference arithmetic both renderers match. The C# twin is `ClipGradeRecipe` in ClipGrade.cs, and both replay
/// shared/fixtures/clip-render/clip-grade-cases.json.
///
/// On encoded Rec. 709 values in 0…1:
/// `o` (the framed picture) → P, the Fix → `f` → L, the base look (or a timed `colourLook`) → A, `colorAdjustments`, with no
/// clamp between L and A, as Core Image → clamp → T1 highlights and shadows → T2 vibrance → T3 preset curves → T4 split
/// tone → T5 fade → clamp → `g` → the mix `f + a·(g − f)` with `a = amount/100`. Amount blends the look over the Fix, which
/// always applies in full; at `a = 0` L, A and T are skipped. Later, after the motion crop and companion footage, F1 vignette
/// and F2 grain act on the output frame by pixel position, scaled by `a`.
///
/// Without a Fix, at full amount and with no new controls, the chain is exactly today's L → A.
public struct ClipGradeRecipe: Sendable, Equatable {
    /// Rec. 709 luma weights.
    static let lumaWeights = [0.2126, 0.7152, 0.0722]

    /// Stage P: white balance and exposure as a gain per channel, normalised so a neutral grey keeps its luma, with a
    /// highlight shoulder on every channel the gain brightens, so nothing clips that wasn't clipped.
    public struct Primary: Sendable, Equatable {
        /// The shoulder's knee: values up to it scale linearly.
        public static let knee = 0.8

        /// Above the knee, `u = (z − 0.8)/0.2` becomes `0.8 + 0.2·u/(1 + α·u)`, which has slope 1 at the knee and maps the
        /// channel's white (`z = G`) to exactly 1.
        public struct Shoulder: Sendable, Equatable {
            public let uMax: Double
            public let alpha: Double
        }

        public let gains: [Double]
        /// Per channel; nil where the gain is 1 or less.
        public let shoulders: [Shoulder?]

        public init(fix: ClipColorFix) {
            let t = Double(fix.temperature) / 100, k = Double(fix.tint) / 100
            let raw = [pow(2, 0.25 * t + 0.10 * k), pow(2, -0.20 * k), pow(2, -0.25 * t + 0.10 * k)]
            let n = ClipGradeRecipe.luma(raw), e = pow(2, 0.009 * Double(fix.exposure))
            gains = raw.map { $0 / n * e }
            shoulders = gains.map { gain in
                guard gain > 1 else { return nil }
                let uMax = (gain - 0.8) / 0.2
                return Shoulder(uMax: uMax, alpha: 1 - 1 / uMax)
            }
        }

        public func apply(_ value: Double, channel: Int) -> Double {
            let z = gains[channel] * ClipGradeRecipe.clamp01(value)
            guard let shoulder = shoulders[channel], z > Self.knee else { return z }
            let u = (z - 0.8) / 0.2
            return 0.8 + 0.2 * u / (1 + shoulder.alpha * u)
        }

        public func apply(_ rgb: [Double]) -> [Double] { (0..<3).map { apply(rgb[$0], channel: $0) } }
    }

    /// A monotone cubic through five knots at x = 0, ¼, ½, ¾ and 1 (stages T1 and T3): Fritsch–Butland tangents, so flat
    /// runs stay flat and nothing overshoots, and four segments in Horner form.
    public struct Curve: Sendable, Equatable {
        public let knots: [Double]
        public let tangents: [Double]
        /// Per segment `(c0, c1, c2, c3)`: `S = c0 + t·(c1 + t·(c2 + t·c3))` with `t = 4v − i`.
        public let segments: [[Double]]

        public init(knots: [Double]) {
            precondition(knots.count == 5, "a curve has five knots")
            let h = 0.25
            let slopes = (0..<4).map { (knots[$0 + 1] - knots[$0]) / h }
            var m = [slopes[0], 0, 0, 0, slopes[3]]
            for i in 1...3 {
                m[i] = slopes[i - 1] > 0 && slopes[i] > 0 ? 2 * slopes[i - 1] * slopes[i] / (slopes[i - 1] + slopes[i]) : 0
            }
            self.knots = knots
            tangents = m
            segments = (0..<4).map { (i: Int) -> [Double] in
                let left: Double = h * m[i], right: Double = h * m[i + 1], rise: Double = knots[i + 1] - knots[i]
                let c2: Double = 3 * rise - 2 * h * m[i] - right
                let c3: Double = 2 * (knots[i] - knots[i + 1]) + left + right
                return [knots[i], left, c2, c3]
            }
        }

        /// A preset curve's five values in thousandths.
        public init(thousandths: [Int]) { self.init(knots: thousandths.map { Double($0) / 1000 }) }

        /// Highlights and Shadows (stage T1): the quarter knots move by up to 0.12; the ends stay at 0 and 1.
        public static func tone(highlights: Int, shadows: Int) -> Curve {
            Curve(knots: [0, 0.25 + 0.12 * Double(shadows) / 100, 0.5, 0.75 + 0.12 * Double(highlights) / 100, 1])
        }

        public func evaluate(_ value: Double) -> Double {
            let v = ClipGradeRecipe.clamp01(value)
            let i = min(3, Int((4 * v).rounded(.down)))
            let t = 4 * v - Double(i)
            let c = segments[i]
            return c[0] + t * (c[1] + t * (c[2] + t * c[3]))
        }
    }

    /// Stage T4's constants: the shadow and highlight tints as zero-luma vectors already scaled by `0.12·saturation/100`,
    /// and the balance's luma offset.
    public struct SplitTone: Sendable, Equatable {
        public let shadow: [Double]
        public let highlight: [Double]
        public let balance: Double

        public init(_ split: ClipSplitTone) {
            shadow = Self.hueVector(split.shadowHue).map { 0.12 * Double(split.shadowSaturation) / 100 * $0 }
            highlight = Self.hueVector(split.highlightHue).map { 0.12 * Double(split.highlightSaturation) / 100 * $0 }
            balance = 0.25 * Double(split.balance) / 100
        }

        /// The fully saturated colour of `hue` degrees, less its luma.
        public static func hueVector(_ hue: Int) -> [Double] {
            let hp = Double(((hue % 360) + 360) % 360) / 60
            let f = hp - hp.rounded(.down)
            let rgb: [Double] = switch Int(hp.rounded(.down)) % 6 {
            case 0: [1, f, 0]
            case 1: [1 - f, 1, 0]
            case 2: [0, 1, f]
            case 3: [0, 1 - f, 1]
            case 4: [f, 0, 1]
            default: [1, 0, 1 - f]
            }
            let l = ClipGradeRecipe.luma(rgb)
            return rgb.map { $0 - l }
        }

        func apply(_ y: [Double]) -> [Double] {
            let t = ClipGradeRecipe.clamp01(ClipGradeRecipe.luma(y) + balance)
            let ws = (1 - t) * (1 - t), wh = t * t
            return (0..<3).map { y[$0] + ws * shadow[$0] + wh * highlight[$0] }
        }
    }

    /// Stage T, after the adjustments: each step present only when its control isn't neutral.
    public struct Tone: Sendable, Equatable {
        /// T1, Highlights and Shadows, applied to luma as a shift that keeps chroma.
        public let shadowsHighlights: Curve?
        /// T2, Vibrance as `vibrance/100`.
        public let vibrance: Double?
        /// T3, the preset's curves: master on every channel, then each channel's own.
        public let master: Curve?
        public let red: Curve?
        public let green: Curve?
        public let blue: Curve?
        /// T4.
        public let splitTone: SplitTone?
        /// T5, Fade as `0.0015·fade`: blacks lift by up to 0.15, white stays.
        public let fade: Double?

        init?(_ grade: ClipColorGrade) {
            shadowsHighlights = grade.highlights != 0 || grade.shadows != 0 ? .tone(highlights: grade.highlights, shadows: grade.shadows) : nil
            vibrance = grade.vibrance != 0 ? Double(grade.vibrance) / 100 : nil
            master = grade.curve?.master.map(Curve.init(thousandths:))
            red = grade.curve?.red.map(Curve.init(thousandths:))
            green = grade.curve?.green.map(Curve.init(thousandths:))
            blue = grade.curve?.blue.map(Curve.init(thousandths:))
            splitTone = grade.splitTone.map(SplitTone.init)
            fade = grade.fade != 0 ? 0.0015 * Double(grade.fade) : nil
            if shadowsHighlights == nil, vibrance == nil, master == nil, red == nil, green == nil, blue == nil, splitTone == nil, fade == nil {
                return nil
            }
        }

        /// The clamped picture after the adjustments in, `g` (clamped) out.
        func apply(_ input: [Double]) -> [Double] {
            var y = input
            if let shadowsHighlights {
                let l = ClipGradeRecipe.luma(y)
                let delta = shadowsHighlights.evaluate(l) - l
                y = y.map { $0 + delta }
            }
            if let vibrance { y = Self.vibrance(y, vibrance) }
            if let master { y = y.map(master.evaluate) }
            for (channel, curve) in [red, green, blue].enumerated() {
                if let curve { y[channel] = curve.evaluate(y[channel]) }
            }
            if let splitTone { y = splitTone.apply(y) }
            if let fade {
                y = y.map { value in
                    let c = ClipGradeRecipe.clamp01(value)
                    return c + fade * (1 - c) * (1 - c) * (1 - c)
                }
            }
            return y.map(ClipGradeRecipe.clamp01)
        }

        /// Vibrance favours dull colours over saturated ones, spares skin-like hues (red to yellow) by 60%, keeps luma and
        /// never leaves 0…1.
        static func vibrance(_ y: [Double], _ v: Double) -> [Double] {
            let l = ClipGradeRecipe.luma(y)
            let c = y.max()! - y.min()!
            let (r, g, b) = (y[0], y[1], y[2])
            var skin = 0.0
            if r >= g, g >= b, c > 0 {
                let q = ((g - b) / c - 0.45) / 0.35
                skin = max(0, 1 - q * q) * ClipGradeRecipe.smoothstep(0.02, 0.10, c)
            }
            let weight = v >= 0 ? (1 - c) * (1 - c) * (1 - 0.6 * skin) : (0.5 + 0.5 * c) * (1 - 0.6 * skin)
            var k = 1 + v * weight
            for channel in y {
                let d = channel - l
                if d > 1e-6 { k = min(k, (1 - l) / d) } else if d < -1e-6 { k = min(k, l / -d) }
            }
            return y.map { l + k * ($0 - l) }
        }
    }

    /// Stage P, or nil without a Fix.
    public let primary: Primary?
    /// Stage L: the base look, or a timed `colourLook` in its place.
    public let look: ClipLookRecipe
    /// Stage A, or nil when neutral.
    public let adjustments: ClipLookRecipe?
    /// Stage T, or nil when every T control is neutral.
    public let tone: Tone?
    /// The look's strength, `amount/100`.
    public let amount: Double
    /// Stage F1's strength, `0.006·vignette·a`: the corners darken by up to 60%.
    public let vignette: Double
    /// Stage F2's strength, `0.0012·grain·a`.
    public let grain: Double

    public init(look: ClipLook, adjustments: ClipColorAdjustments?, grade: ClipColorGrade?) {
        let fix = grade?.fix ?? .neutral
        let a = Double(grade?.amount ?? 100) / 100
        primary = fix == .neutral ? nil : Primary(fix: fix)
        self.look = ClipLookRecipe(look)
        self.adjustments = adjustments.flatMap { $0 == .neutral ? nil : ClipLookRecipe(adjustments: $0) }
        tone = grade.flatMap(Tone.init)
        amount = a
        vignette = 0.006 * Double(grade?.vignette ?? 0) * a
        grain = 0.0012 * Double(grade?.grain ?? 0) * a
    }

    /// The recipe a clip's controls render with; a timed Ask Claude `colourLook` replaces only the base look.
    public init(controls: ProjectClipControls, override: ClipLook? = nil) {
        self.init(look: override ?? controls.look, adjustments: controls.colorAdjustments, grade: controls.colorGrade)
    }

    /// The picture's colour changes: a Fix at any amount, or a look, an adjustment or a T control above amount 0.
    public var changesColor: Bool { primary != nil || (amount > 0 && (!look.isIdentity || adjustments != nil || tone != nil)) }

    /// Stage F runs: vignette or grain above amount 0.
    public var hasFinish: Bool { vignette > 0 || grain > 0 }

    /// `f`: the Fix's output, or the clamped input without one.
    public func fixed(_ rgb: [Double]) -> [Double] { primary?.apply(rgb) ?? rgb.map(Self.clamp01) }

    /// The graded colour before stage F: P, L, A, T and the mix.
    public func apply(_ rgb: [Double]) -> [Double] {
        let f = fixed(rgb)
        guard amount > 0 else { return f }
        var y = look.isIdentity ? f : look.transform(f)
        if let adjustments { y = adjustments.transform(y) }
        y = y.map(Self.clamp01)
        let g = tone?.apply(y) ?? y
        guard amount != 1 else { return g }
        return (0..<3).map { f[$0] + amount * (g[$0] - f[$0]) }
    }

    /// Stage F on one output pixel `(x, y)` (top-left origin) of a `width × height` frame: the vignette, then grain unless
    /// the pixel lies in the context demo's `hole`. `frameHash` is `ClipGrain.frameHash` of the rendered frame index.
    public func finish(_ rgb: [Double], x: Int, y: Int, width: Int, height: Int, frameHash: UInt32, hole: ClipGrain.Hole?) -> [Double] {
        var value = rgb
        if vignette > 0 {
            let factor = 1 - vignette * Self.vignetteWeight(x: x, y: y, width: width, height: height).s
            value = value.map { $0 * factor }
        }
        if grain > 0, hole?.contains(x: x, y: y) != true {
            let l = Self.luma(value)
            let m = 0.25 + 3 * l * (1 - l)
            let g = ClipGrain.value(x: x, y: y, width: width, height: height, frameHash: frameHash)
            value = value.map { $0 + grain * m * g }
        }
        return value
    }

    /// Stage F1's weight at a pixel: `q` is the squared distance on an ellipse through the corners (half-axes in proportion
    /// to √W and √H), and `s` its smoothstep from 0.16 to 1.
    public static func vignetteWeight(x: Int, y: Int, width: Int, height: Int) -> (q: Double, s: Double) {
        let w = Double(width), h = Double(height)
        let nx = Double(2 * x + 1 - width) / w, ny = Double(2 * y + 1 - height) / h
        let q = (nx * nx * w + ny * ny * h) / (w + h)
        let t = clamp01((q - 0.16) / 0.84)
        return (q, t * t * (3 - 2 * t))
    }

    /// The stored byte of a value: `floor(255·clamp01(v) + 0.5)`.
    public static func byte(_ value: Double) -> Int { Int((255 * clamp01(value) + 0.5).rounded(.down)) }

    static func luma(_ c: [Double]) -> Double { lumaWeights[0] * c[0] + lumaWeights[1] * c[1] + lumaWeights[2] * c[2] }

    static func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }

    static func smoothstep(_ e0: Double, _ e1: Double, _ value: Double) -> Double {
        let t = clamp01((value - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }
}

/// Stage F2's grain (looks spec §5.7): one integer field, identical on every platform. Cells of 2 output pixels on frames
/// whose short side is 720 or more (else 1), a PCG hash of each cell and the rendered frame index, and bilinear weights in
/// quarters, so every intermediate value is an integer below 2^24.
public enum ClipGrain {
    public static let seed: UInt32 = 0x9E37_79B9

    /// Where a pixel samples the cell grid: the cell `(a, b)` up and left of it and the weights of the next cells, in quarters.
    public struct Cell: Sendable, Equatable {
        public let a: Int
        public let b: Int
        public let fx4: Int
        public let fy4: Int
    }

    /// The context demo's rendered rectangle in output pixels, where grain is skipped so a screen recording stays legible.
    /// A pixel is inside when its centre is.
    public struct Hole: Sendable, Equatable {
        public let minX: Double
        public let minY: Double
        public let maxX: Double
        public let maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        }

        public func contains(x: Int, y: Int) -> Bool {
            let cx = Double(x) + 0.5, cy = Double(y) + 0.5
            return minX <= cx && cx < maxX && minY <= cy && cy < maxY
        }
    }

    /// PCG (Jarzynski and Olano 2020), mod 2^32.
    public static func pcg(_ value: UInt32) -> UInt32 {
        let state = value &* 747_796_405 &+ 2_891_336_453
        let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277_803_737
        return (word >> 22) ^ word
    }

    /// The per-frame hash `pcg(n ^ seed)`.
    public static func frameHash(_ index: UInt32) -> UInt32 { pcg(index ^ seed) }

    /// The rendered frame index `floor(t·fps + 0.5)` for `t` seconds from the clip's start, so preview, export and the cover
    /// agree and a paused frame's grain stands still.
    public static func frameIndex(renderedSeconds: Double, fps: Double) -> UInt32 {
        let index = (renderedSeconds * fps + 0.5).rounded(.down)
        guard index.isFinite, index >= 0 else { return 0 }
        return UInt32(truncatingIfNeeded: Int64(min(index, Double(Int64.max / 2))))
    }

    public static func cellSize(width: Int, height: Int) -> Int { min(width, height) >= 720 ? 2 : 1 }

    public static func cell(x: Int, y: Int, width: Int, height: Int) -> Cell {
        let s = cellSize(width: width, height: height)
        func axis(_ p: Int) -> (Int, Int) {
            let q = 2 * p + 1 - s, span = 2 * s
            let i = q >= 0 ? q / span : -((span - 1 - q) / span)
            return (i + 1, 4 * (q - span * i) / span)
        }
        let (a, fx4) = axis(x), (b, fy4) = axis(y)
        return Cell(a: a, b: b, fx4: fx4, fy4: fy4)
    }

    /// The exact bilinear total, within ±2^19.
    public static func total(x: Int, y: Int, width: Int, height: Int, frameHash: UInt32) -> Int {
        let cell = cell(x: x, y: y, width: width, height: height)
        func value(_ i: Int, _ j: Int) -> Int {
            Int(pcg(UInt32(truncatingIfNeeded: i) &+ pcg(UInt32(truncatingIfNeeded: j) &+ frameHash)) >> 16) - 32768
        }
        let (a, b, fx, fy) = (cell.a, cell.b, cell.fx4, cell.fy4)
        return ((4 - fx) * value(a, b) + fx * value(a + 1, b)) * (4 - fy) + ((4 - fx) * value(a, b + 1) + fx * value(a + 1, b + 1)) * fy
    }

    /// The grain at a pixel, `total / 2^20`, in −0.5…0.5.
    public static func value(x: Int, y: Int, width: Int, height: Int, frameHash: UInt32) -> Double {
        Double(total(x: x, y: y, width: width, height: height, frameHash: frameHash)) / 1_048_576
    }

    /// The context demo's placement (normalised, top-left; today the whole frame) mapped through the motion crop into a
    /// `width × height` output frame and clamped to it. Footage drawn over the demo leaves the hole as it is.
    public static func demoHole(width: Int, height: Int, motion: MotionCropTransform, placement: ClipEffect.Rect) -> Hole {
        let w = Double(width), h = Double(height), scale = motion.scale
        let cropWidth = w / scale, cropHeight = h / scale
        let cropX = (w - cropWidth) * motion.anchorX, cropY = (h - cropHeight) * motion.anchorY
        func clamp(_ value: Double, _ limit: Double) -> Double { min(limit, max(0, value)) }
        return Hole(minX: clamp((placement.x * w - cropX) * scale, w), minY: clamp((placement.y * h - cropY) * scale, h),
                    maxX: clamp(((placement.x + placement.width) * w - cropX) * scale, w),
                    maxY: clamp(((placement.y + placement.height) * h - cropY) * scale, h))
    }
}
