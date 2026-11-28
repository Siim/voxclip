import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/clip-render/clip-grade-cases.json (looks spec 2026-11-28, sections 5, 6 and 11.1): bytes and
/// integers exactly, floats within 1e-9, curve coefficients within 1e-12. The C# twin `ClipGradeVectorTests` replays the
/// same file.
@Suite(.offlineFixtures) struct ClipGradeRecipeTests {
    static let floats = 1e-9
    static let coefficients = 1e-12

    static func corpus() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/clip-render/clip-grade-cases.json"))
    }

    static func controls(_ value: JSONValue) throws -> ProjectClipControls {
        try ProjectJSON.decoder().decode(ProjectClipControls.self, from: JSONEncoder().encode(value))
    }

    static func doubles(_ value: JSONValue) -> [Double] { value.aiArray.compactMap(\.aiDouble) }
    static func ints(_ value: JSONValue) -> [Int] { value.aiArray.compactMap(\.aiInt) }
    static func unit(_ value: JSONValue) -> [Double] { ints(value).map { Double($0) / 255 } }
    static func bytes(_ rgb: [Double]) -> [Int] { rgb.map(ClipGradeRecipe.byte) }

    static func close(_ found: [Double], _ expected: [Double], _ tolerance: Double = floats) -> Bool {
        found.count == expected.count && zip(found, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static func recipe(_ item: JSONValue) throws -> ClipGradeRecipe {
        try ClipGradeRecipe(controls: controls(item[ai: "controls"]), override: item[ai: "override"].aiString.flatMap(ClipLook.init(rawValue:)))
    }

    @Test func theFileHoldsEveryCategoryBothCoresReplay() throws {
        let corpus = try Self.corpus()
        #expect(corpus[ai: "format"] == .string("voxclip-clip-grade-cases/1"))
        #expect(Set(corpus.aiObject?.keys.map { $0 } ?? []) == [
            "format", "looks", "tolerance", "swatches8", "primary", "controls", "curves", "vignette", "pcg", "frameHash", "frameIndex",
            "grain", "demo", "finish", "chains", "looksOnSwatches", "adjustments", "skinCheck", "measure"])
        #expect(corpus[ai: "swatches8"].aiObject?.count == 10)
    }

    @Test func theFixIsAGainPerChannelWithAShoulder() throws {
        let cases = try Self.corpus()[ai: "primary"].aiArray
        #expect(cases.count == 7)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let fix = ClipColorFix(exposure: item[ai: "fix"][ai: "exposure"].aiInt ?? 0, temperature: item[ai: "fix"][ai: "temperature"].aiInt ?? 0,
                                   tint: item[ai: "fix"][ai: "tint"].aiInt ?? 0)
            let primary = ClipGradeRecipe.Primary(fix: fix)
            #expect(Self.close(primary.gains, Self.doubles(item[ai: "gains"])), "\(id)")
            for (channel, shoulder) in item[ai: "shoulders"].aiArray.enumerated() {
                if shoulder == .null {
                    #expect(primary.shoulders[channel] == nil, "\(id)")
                } else {
                    #expect(Self.close([primary.shoulders[channel]?.uMax ?? .nan, primary.shoulders[channel]?.alpha ?? .nan],
                                       Self.doubles(shoulder)), "\(id)")
                }
            }
        }
    }

    @Test func eachControlAloneAndTheWholeChainMatchTheReference() throws {
        let corpus = try Self.corpus()
        let cases = corpus[ai: "controls"].aiArray + corpus[ai: "chains"].aiArray
        #expect(cases.count == 51)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let output = try Self.recipe(item).apply(Self.unit(item[ai: "input"]))
            #expect(Self.close(output, Self.doubles(item[ai: "output"])), "\(id): \(output)")
            #expect(Self.bytes(output) == Self.ints(item[ai: "bytes"]), "\(id)")
        }
    }

    @Test func goldenHourAtSixtyPercentMixesOverTheFix() throws {
        let item = try #require(try Self.corpus()[ai: "chains"].aiArray.first { $0[ai: "id"] == .string("E8 Golden Hour 60% skin") })
        let recipe = try Self.recipe(item)
        #expect(Self.bytes(recipe.apply([217, 158, 128].map { $0 / 255 })) == [234, 158, 113])
        let fixed = recipe.fixed([217, 158, 128].map { $0 / 255 })
        #expect(Self.close(fixed, Self.doubles(item[ai: "stages"][ai: "P"])))
    }

    @Test func curvesAreMonotoneCubicsThroughTheirKnots() throws {
        let cases = try Self.corpus()[ai: "curves"].aiArray
        #expect(cases.count == 8)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let curve = ClipGradeRecipe.Curve(knots: Self.doubles(item[ai: "knots"]))
            #expect(Self.close(curve.tangents, Self.doubles(item[ai: "tangents"]), Self.coefficients), "\(id)")
            #expect(Self.close(curve.segments.flatMap { $0 }, item[ai: "segments"].aiArray.flatMap(Self.doubles), Self.coefficients), "\(id)")
            for sample in item[ai: "samples"].aiArray {
                let pair = Self.doubles(sample)
                #expect(abs(curve.evaluate(pair[0]) - pair[1]) <= Self.coefficients, "\(id) at \(pair[0])")
            }
        }
        let tone = ClipGradeRecipe.Curve.tone(highlights: -60, shadows: 40)
        #expect(Self.close(tone.knots, Self.doubles(cases[0][ai: "knots"]), Self.coefficients))
        #expect(ClipGradeRecipe.Curve(thousandths: [0, 245, 500, 760, 965]) == ClipGradeRecipe.Curve(knots: Self.doubles(cases[4][ai: "knots"])))
    }

    @Test func theVignetteWeightsAnOutputPixelByItsPlace() throws {
        let cases = try Self.corpus()[ai: "vignette"].aiArray
        #expect(cases.count == 14)
        for item in cases {
            let weight = ClipGradeRecipe.vignetteWeight(x: item[ai: "x"].aiInt ?? 0, y: item[ai: "y"].aiInt ?? 0,
                                                        width: item[ai: "width"].aiInt ?? 0, height: item[ai: "height"].aiInt ?? 0)
            #expect(Self.close([weight.q, weight.s], [item[ai: "q"].aiDouble ?? .nan, item[ai: "s"].aiDouble ?? .nan]), "\(item)")
        }
    }

    @Test func grainIsTheSameIntegerFieldOnEveryPlatform() throws {
        let corpus = try Self.corpus()
        for pair in corpus[ai: "pcg"].aiArray.map(Self.ints) {
            #expect(Int(ClipGrain.pcg(UInt32(pair[0]))) == pair[1], "pcg(\(pair[0]))")
        }
        for pair in corpus[ai: "frameHash"].aiArray.map(Self.ints) {
            #expect(Int(ClipGrain.frameHash(UInt32(pair[0]))) == pair[1], "frame \(pair[0])")
        }
        for item in corpus[ai: "frameIndex"].aiArray {
            let index = ClipGrain.frameIndex(renderedSeconds: item[ai: "seconds"].aiDouble ?? .nan, fps: item[ai: "fps"].aiDouble ?? .nan)
            #expect(Int(index) == item[ai: "n"].aiInt, "\(item)")
        }
        let cases = corpus[ai: "grain"].aiArray
        #expect(cases.count == 13)
        for item in cases {
            let (x, y, width, height) = (item[ai: "x"].aiInt ?? 0, item[ai: "y"].aiInt ?? 0, item[ai: "width"].aiInt ?? 0, item[ai: "height"].aiInt ?? 0)
            #expect(ClipGrain.cellSize(width: width, height: height) == item[ai: "cellSize"].aiInt, "\(item)")
            let cell = ClipGrain.cell(x: x, y: y, width: width, height: height)
            #expect([cell.a, cell.b, cell.fx4, cell.fy4] == [item[ai: "a"], item[ai: "b"], item[ai: "fx4"], item[ai: "fy4"]].compactMap(\.aiInt), "\(item)")
            let hash = ClipGrain.frameHash(UInt32(item[ai: "n"].aiInt ?? 0))
            #expect(ClipGrain.total(x: x, y: y, width: width, height: height, frameHash: hash) == item[ai: "total"].aiInt, "\(item)")
        }
    }

    @Test func grainSkipsTheContextDemosRenderedRectangle() throws {
        let cases = try Self.corpus()[ai: "demo"].aiArray
        #expect(cases.count == 4)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let (width, height) = (item[ai: "width"].aiInt ?? 0, item[ai: "height"].aiInt ?? 0)
            let motion = MotionCropTransform(scale: item[ai: "motion"][ai: "scale"].aiDouble ?? 1, anchorX: item[ai: "motion"][ai: "anchorX"].aiDouble ?? 0.5,
                                             anchorY: item[ai: "motion"][ai: "anchorY"].aiDouble ?? 0.5)
            let placement = item[ai: "placement"]
            let hole = ClipGrain.demoHole(width: width, height: height, motion: motion,
                                          placement: ClipEffect.Rect(x: placement[ai: "x"].aiDouble ?? 0, y: placement[ai: "y"].aiDouble ?? 0,
                                                                     width: placement[ai: "width"].aiDouble ?? 0, height: placement[ai: "height"].aiDouble ?? 0))
            #expect(Self.close([hole.minX, hole.minY, hole.maxX, hole.maxY], Self.doubles(item[ai: "rect"])), "\(id)")
            for probe in item[ai: "probes"].aiArray.map(\.aiArray) {
                #expect(hole.contains(x: probe[0].aiInt ?? -1, y: probe[1].aiInt ?? -1) == probe[2].aiBool, "\(id) \(probe)")
            }
        }
    }

    @Test func theFinishDarkensCornersAndAddsGrainOnBytes() throws {
        let cases = try Self.corpus()[ai: "finish"].aiArray
        #expect(cases.count == 20)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let grade = ClipColorGrade(amount: item[ai: "amount"].aiInt ?? 100, vignette: item[ai: "vignette"].aiInt ?? 0, grain: item[ai: "grain"].aiInt ?? 0)
            let recipe = ClipGradeRecipe(look: .original, adjustments: nil, grade: grade)
            let hole = item[ai: "hole"] == .null ? nil : Self.doubles(item[ai: "hole"])
            let output = recipe.finish(Self.unit(item[ai: "input"]), x: item[ai: "x"].aiInt ?? 0, y: item[ai: "y"].aiInt ?? 0,
                                       width: item[ai: "width"].aiInt ?? 0, height: item[ai: "height"].aiInt ?? 0,
                                       frameHash: ClipGrain.frameHash(UInt32(item[ai: "n"].aiInt ?? 0)),
                                       hole: hole.map { ClipGrain.Hole(minX: $0[0], minY: $0[1], maxX: $0[2], maxY: $0[3]) })
            #expect(Self.close(output, Self.doubles(item[ai: "output"])), "\(id): \(output)")
            #expect(Self.bytes(output) == Self.ints(item[ai: "bytes"]), "\(id)")
        }
    }

    @Test func everyLookRendersEverySwatchAtFullAndSeventyPercent() throws {
        let corpus = try Self.corpus()
        let swatches = try #require(corpus[ai: "swatches8"].aiObject)
        let looks = try ClipLookLibraryTests.library()
        let cases = corpus[ai: "looksOnSwatches"].aiArray + corpus[ai: "adjustments"].aiArray
        #expect(corpus[ai: "looksOnSwatches"].aiArray.count == 2 * looks.looks.count)
        #expect(cases.count == 56)
        for item in cases {
            let id = "\(item[ai: "look"].aiString ?? item[ai: "id"].aiString ?? "") \(item[ai: "amount"].aiInt ?? 100)"
            let recipe = try Self.recipe(item)
            for (name, expected) in item[ai: "bytes"].aiObject ?? [:] {
                let input = Self.unit(swatches[name] ?? .null)
                #expect(Self.bytes(recipe.apply(input)) == Self.ints(expected), "\(id) on \(name)")
            }
        }
    }

    @Test func theSkinTableMatchesTheSpec() throws {
        let corpus = try Self.corpus()
        let swatches = try #require(corpus[ai: "swatches8"].aiObject)
        let cases = corpus[ai: "skinCheck"].aiArray
        #expect(cases.count == 16)
        for item in cases {
            let recipe = try Self.recipe(item)
            for (key, swatch) in [("mid", "skin"), ("deep", "deepSkin"), ("veryDeep", "veryDeepSkin")] {
                #expect(Self.bytes(recipe.apply(Self.unit(swatches[swatch] ?? .null))) == Self.ints(item[ai: key]),
                        "\(item[ai: "look"].aiString ?? "") \(key)")
            }
        }
    }

    @Test func anUnchangedClipLeavesThePictureAlone() {
        let recipe = ClipGradeRecipe(controls: ProjectClipControls(clipId: "clip"))
        #expect(!recipe.changesColor && !recipe.hasFinish)
        #expect(recipe.apply([0.2, 0.4, 0.8]) == [0.2, 0.4, 0.8])
        let atZero = ClipGradeRecipe(look: .bw, adjustments: ClipColorAdjustments(contrast: 30), grade: ClipColorGrade(amount: 0, grain: 40))
        #expect(!atZero.changesColor && !atZero.hasFinish, "amount 0 with no Fix renders as filmed")
        let fixOnly = ClipGradeRecipe(look: .original, adjustments: nil, grade: ClipColorGrade(amount: 0, exposure: 10))
        #expect(fixOnly.changesColor && !fixOnly.hasFinish, "the Fix applies at any amount")
    }

    @Test func autoAndTheLightFactsReadSyntheticFrames() throws {
        let looks = try ClipLookLibraryTests.library()
        let cases = try Self.corpus()[ai: "measure"].aiArray
        #expect(cases.count == 12)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let frames = item[ai: "frames"].aiArray.map { frame in
                ClipFrameSample(width: frame[ai: "width"].aiInt ?? 0, height: frame[ai: "height"].aiInt ?? 0,
                                rgb: Self.ints(frame[ai: "rgb"]).map(UInt8.init),
                                face: frame[ai: "face"] == .null ? nil : ClipEffect.Rect(
                                    x: frame[ai: "face"][ai: "x"].aiDouble ?? 0, y: frame[ai: "face"][ai: "y"].aiDouble ?? 0,
                                    width: frame[ai: "face"][ai: "width"].aiDouble ?? 0, height: frame[ai: "face"][ai: "height"].aiDouble ?? 0))
            }
            let fix = ClipColorFix.measure(frames, constants: looks.measure.auto)
            let expected = item[ai: "fix"]
            #expect(fix == ClipColorFix(exposure: expected[ai: "exposure"].aiInt ?? -999, temperature: expected[ai: "temperature"].aiInt ?? -999,
                                        tint: expected[ai: "tint"].aiInt ?? -999), "\(id): \(fix)")
            let facts = item[ai: "facts"].aiArray
            #expect(facts.count == frames.count, "\(id)")
            for (frame, wanted) in zip(frames, facts) {
                let found = ClipLightFacts(frame, measure: looks.measure)
                func optional(_ value: Double?, _ key: String) -> Bool {
                    guard let value else { return wanted[ai: key] == .null }
                    return abs(value - (wanted[ai: key].aiDouble ?? .nan)) <= Self.floats
                }
                #expect(Self.close([found.medianLuma, found.p95Luma, found.meanChroma],
                                   [wanted[ai: "medianLuma"], wanted[ai: "p95Luma"], wanted[ai: "meanChroma"]].compactMap(\.aiDouble)), "\(id)")
                #expect(optional(found.faceMeanLuma, "faceMeanLuma") && optional(found.faceMedianLuma, "faceMedianLuma") &&
                        optional(found.faceClippedShare, "faceClippedShare"), "\(id)")
                if wanted[ai: "neutralMeans"] == .null {
                    #expect(found.neutralMeans == nil, "\(id)")
                } else {
                    #expect(Self.close(found.neutralMeans ?? [], Self.doubles(wanted[ai: "neutralMeans"])), "\(id)")
                }
                #expect(found.notes.map(\.text) == wanted[ai: "notes"].aiArray.compactMap(\.aiString), "\(id)")
                #expect(found.line == wanted[ai: "line"].aiString, "\(id)")
            }
        }
    }
}
