import Foundation

/// The light of one analysed frame (looks spec §9.3), measured on the device from a small picture of it (`ClipFrameSample`)
/// and kept with its `FrameObservation` in the analysis cache. Only numbers: the planner reads them as one line of notes
/// from the shared thresholds (`ClipColorMeasure.Light`), such as "light: face a little dark · warm-yellow cast". No skin
/// colour is measured or sent.
public struct FrameLight: Codable, Sendable, Equatable {
    public var medianLuma: Double
    /// The nearest-rank 95th percentile.
    public var p95Luma: Double
    public var faceMeanLuma: Double?
    public var faceMedianLuma: Double?
    /// The share of face pixels with a channel at or above `Light.clippedChannel`.
    public var faceClippedShare: Double?
    /// The neutral pixels' mean red, green and blue (`Auto`'s neutral mask), or nil without any.
    public var neutralMeans: [Double]?
    public var meanChroma: Double

    public init(medianLuma: Double, p95Luma: Double, faceMeanLuma: Double? = nil, faceMedianLuma: Double? = nil,
                faceClippedShare: Double? = nil, neutralMeans: [Double]? = nil, meanChroma: Double) {
        self.medianLuma = medianLuma; self.p95Luma = p95Luma; self.faceMeanLuma = faceMeanLuma; self.faceMedianLuma = faceMedianLuma
        self.faceClippedShare = faceClippedShare; self.neutralMeans = neutralMeans; self.meanChroma = meanChroma
    }

    /// The light of `frame`, which holds at least one pixel; its face box is the frame's `face`.
    public init(_ frame: ClipFrameSample, measure: ClipColorMeasure) {
        let pixels = frame.pixels, face = frame.facePixels
        let lumas = pixels.map(ClipGradeRecipe.luma), faceLumas = face.map(ClipGradeRecipe.luma)
        let ordered = lumas.sorted()
        medianLuma = ClipColorMeasure.median(lumas)
        p95Luma = ordered[max(0, Int((0.95 * Double(ordered.count)).rounded(.up)) - 1)]
        faceMeanLuma = face.isEmpty ? nil : ClipColorMeasure.sum(faceLumas) / Double(face.count)
        faceMedianLuma = face.isEmpty ? nil : ClipColorMeasure.median(faceLumas)
        faceClippedShare = face.isEmpty ? nil
            : Double(face.filter { $0.max()! >= measure.light.clippedChannel }.count) / Double(face.count)
        neutralMeans = ClipColorMeasure.neutralMeans(pixels, measure.auto)
        meanChroma = ClipColorMeasure.sum(pixels.map(ClipColorMeasure.chroma)) / Double(pixels.count)
    }

    /// The notes `light`'s thresholds give, in the line's order: a dim face, clipped face highlights, a warm or cool cast,
    /// a green or magenta cast, then low or high colour.
    public func notes(_ light: ClipColorMeasure.Light) -> [ClipLightFacts.Note] {
        var notes: [ClipLightFacts.Note] = []
        if let faceMedianLuma, faceMedianLuma < light.dimFaceLuma { notes.append(.dimFace) }
        if let faceClippedShare, faceClippedShare > light.clippedShare { notes.append(.clipped(percent: ClipColorMeasure.points(faceClippedShare * 100))) }
        if let neutralMeans, neutralMeans.count == 3 {
            let (r, g, b) = (neutralMeans[0], neutralMeans[1], neutralMeans[2])
            if r - b > light.warmCool { notes.append(.warmCast) } else if b - r > light.warmCool { notes.append(.coolCast) }
            if g - (r + b) / 2 > light.greenMagenta { notes.append(.greenCast) } else if (r + b) / 2 - g > light.greenMagenta { notes.append(.magentaCast) }
        }
        if meanChroma < light.lowColor { notes.append(.lowColor) } else if meanChroma > light.highColor { notes.append(.highColor) }
        return notes
    }

    /// The planner's line: "light: " and the notes, or "light: even".
    public func line(_ light: ClipColorMeasure.Light) -> String {
        let notes = notes(light)
        return "light: " + (notes.isEmpty ? "even" : notes.map(\.text).joined(separator: " · "))
    }

    /// Whether the face is dim by `light`'s threshold (the planner's dim-face repair, looks spec §9.5).
    public func dimFace(_ light: ClipColorMeasure.Light) -> Bool { faceMedianLuma.map { $0 < light.dimFaceLuma } ?? false }
}
