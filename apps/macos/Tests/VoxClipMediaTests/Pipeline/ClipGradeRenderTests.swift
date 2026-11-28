import CoreImage
import CryptoKit
import Foundation
import Metal
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// The clip grade through the Mac's Core Image kernels (looks spec 2026-11-28, section 11.1). Every grade and finish case of
/// shared/fixtures/clip-render/clip-grade-cases.json is rendered by `ClipPicture.grade` and `finish` on its stored bytes:
/// within 2 of the recipe's bytes, and within 1 of the Mac goldens in clip-grade-mac-goldens.json, which Windows replays too.
/// `VOXCLIP_RECORD_CLIP_GRADE_GOLDENS=1` rewrites the goldens from this Mac's renders.
@Suite(.serialized, .offlineFixtures) struct ClipGradeRenderTests {
    static let goldensPath = "fixtures/clip-render/clip-grade-mac-goldens.json"
    static let recording = ProcessInfo.processInfo.environment["VOXCLIP_RECORD_CLIP_GRADE_GOLDENS"] == "1"
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .cacheIntermediates: false]
        return MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    static func corpus() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/clip-render/clip-grade-cases.json"))
    }

    static func controls(_ value: JSONValue) throws -> ProjectClipControls {
        try ProjectJSON.decoder().decode(ProjectClipControls.self, from: JSONEncoder().encode(value))
    }

    static func ints(_ value: JSONValue) -> [Int] { value.aiArray.compactMap(\.aiInt) }
    static func doubles(_ value: JSONValue) -> [Double] { value.aiArray.compactMap(\.aiDouble) }

    /// A one-row frame of stored bytes, as a decoded frame holds them.
    static func frame(_ pixels: [[Int]]) -> CIImage {
        let bytes: [UInt8] = pixels.flatMap { (pixel: [Int]) -> [UInt8] in [UInt8(pixel[0]), UInt8(pixel[1]), UInt8(pixel[2]), 255] }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: 4 * pixels.count, size: CGSize(width: pixels.count, height: 1),
                       format: .RGBA8, colorSpace: nil)
    }

    /// RGB bytes of `bounds` (Core Image coordinates), top row first.
    static func bytes(_ image: CIImage, _ bounds: CGRect) -> [[Int]] {
        let width = Int(bounds.width), height = Int(bounds.height)
        var raw = [UInt8](repeating: 0, count: 4 * width * height)
        context.render(image, toBitmap: &raw, rowBytes: 4 * width, bounds: bounds, format: .RGBA8, colorSpace: nil)
        return (0..<(width * height)).map { [Int(raw[4 * $0]), Int(raw[4 * $0 + 1]), Int(raw[4 * $0 + 2])] }
    }

    static func near(_ found: [Int], _ expected: [Int], _ tolerance: Int) -> Bool {
        found.count == expected.count && zip(found, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// Every grade case as (golden key, recipe, named inputs and the recipe's bytes for each).
    static func gradeCases() throws -> [(key: String, recipe: ClipGradeRecipe, inputs: [(name: String, input: [Int], expected: [Int])])] {
        let corpus = try corpus()
        let swatches = try #require(corpus[ai: "swatches8"].aiObject)
        func recipe(_ item: JSONValue) throws -> ClipGradeRecipe {
            try ClipGradeRecipe(controls: controls(item[ai: "controls"]), override: item[ai: "override"].aiString.flatMap(ClipLook.init(rawValue:)))
        }
        var cases: [(key: String, recipe: ClipGradeRecipe, inputs: [(name: String, input: [Int], expected: [Int])])] = []
        for category in ["controls", "chains"] {
            for item in corpus[ai: category].aiArray {
                cases.append(("\(category)/\(item[ai: "id"].aiString ?? "")", try recipe(item),
                              [("input", ints(item[ai: "input"]), ints(item[ai: "bytes"]))]))
            }
        }
        for item in corpus[ai: "adjustments"].aiArray + corpus[ai: "looksOnSwatches"].aiArray {
            let key = item[ai: "id"].aiString.map { "adjustments/\($0)" } ?? "looks/\(item[ai: "look"].aiString ?? "") \(item[ai: "amount"].aiInt ?? 100)"
            let inputs = (item[ai: "bytes"].aiObject ?? [:]).sorted { $0.key < $1.key }.map { name, expected in
                (name, ints(swatches[name] ?? .null), ints(expected))
            }
            cases.append((key, try recipe(item), inputs))
        }
        for item in corpus[ai: "skinCheck"].aiArray {
            let inputs = [("mid", "skin"), ("deep", "deepSkin"), ("veryDeep", "veryDeepSkin")].map { key, swatch in
                (key, ints(swatches[swatch] ?? .null), ints(item[ai: key]))
            }
            cases.append(("skin/\(item[ai: "look"].aiString ?? "")", try recipe(item), inputs))
        }
        return cases
    }

    static func goldens() throws -> JSONValue? {
        recording ? nil : try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(goldensPath))
    }

    // MARK: The kernel library

    @Test func theKernelLibraryIsBuiltFromTheCurrentSource() throws {
        let source = try FixtureLoader.sharedRoot().deletingLastPathComponent()
            .appendingPathComponent("apps/macos/Sources/VoxClipMedia/Pipeline/ClipGradeKernels.ci.metal")
        let digest = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == ClipGradeKernelLibrary.sourceSHA256, "run python3 tools/looks/build_mac_kernels.py")
        #expect(try ClipGradeKernels.shared.get().names == ["clipGradeFix", "clipGradeTone", "clipGradeToning", "clipGradeFinish"])
    }

    /// Without a Metal GPU, or with a library that doesn't load, a grade that needs the kernels fails with one clear message
    /// instead of rendering the picture ungraded; the classic looks still render.
    @Test func withoutTheKernelsAGradeFailsClearly() throws {
        let noMetal = ClipGradeKernels.load(hasMetal: false, library: Data(ClipGradeKernelLibrary.base64.utf8))
        let broken = ClipGradeKernels.load(hasMetal: true, library: Data("not a library".utf8))
        let picture = Self.frame([[128, 128, 128]])
        var fixed = ProjectClipControls(clipId: "c")
        fixed.colorGrade = ClipColorGrade(exposure: 20)
        for kernels in [noMetal, broken] {
            #expect(throws: VoxClipError.exportFailed(VoxClipError.looksNeedMetal)) {
                try ClipPicture.grade(picture, controls: fixed, kernels: kernels)
            }
            let warm = try ClipPicture.grade(picture, controls: ProjectClipControls(clipId: "c", look: .warm), kernels: kernels)
            #expect(Self.bytes(warm, picture.extent) == Self.bytes(ClipPicture.look(picture, .warm), picture.extent))
            #expect(Self.bytes(warm, picture.extent) != Self.bytes(picture, picture.extent))
            // An amount with nothing to blend, or amount 0 with no Fix, is the picture as filmed and needs no kernel.
            for grade in [ClipColorGrade(preset: "softLight", amount: 60), ClipColorGrade(amount: 0, vibrance: 40, grain: 30)] {
                var controls = ProjectClipControls(clipId: "c")
                controls.colorGrade = grade
                #expect(!ClipPicture.needsKernels(ClipGradeRecipe(controls: controls)))
                #expect(Self.bytes(try ClipPicture.grade(picture, controls: controls, kernels: kernels), picture.extent) == Self.bytes(picture, picture.extent))
            }
        }
        #expect(ClipPicture.needsKernels(ClipGradeRecipe(controls: fixed)) && !ClipPicture.needsKernels(ClipGradeRecipe(controls: .init(clipId: "c", look: .bw))))
        #expect(VoxClipError.exportFailed(VoxClipError.looksNeedMetal).errorDescription == "Looks need a Metal GPU on this Mac.")
    }

    // MARK: Shared vectors

    /// P, L, A, T and the mix on every swatch case: the 24 looks at 100% and 70%, each control alone, the Golden Hour
    /// chains, the adjustments and the skin table.
    @Test func everyGradeCaseThroughTheKernelsMatchesTheRecipeAndTheGoldens() throws {
        let goldens = try Self.goldens()
        var recorded: [String: [String: [Int]]] = [:]
        var worst = 0
        for item in try Self.gradeCases() {
            let picture = Self.frame(item.inputs.map(\.input))
            let rendered = Self.bytes(try ClipPicture.grade(picture, recipe: item.recipe), picture.extent)
            for (index, input) in item.inputs.enumerated() {
                let found = rendered[index]
                worst = max(worst, zip(found, input.expected).map { abs($0 - $1) }.max() ?? 0)
                #expect(Self.near(found, input.expected, 2), "\(item.key) \(input.name): \(found) vs recipe \(input.expected)")
                recorded[item.key, default: [:]][input.name] = found
                if let goldens {
                    let golden = Self.ints(goldens[ai: "grade"][ai: item.key][ai: input.name])
                    #expect(Self.near(found, golden, 1), "\(item.key) \(input.name): \(found) vs golden \(golden)")
                }
            }
        }
        if let goldens { #expect(Set(goldens[ai: "grade"].aiObject?.keys.map { $0 } ?? []) == Set(recorded.keys)) }
        print("clip grade kernels: worst byte difference from the recipe \(worst) over \(recorded.count) cases")
        if Self.recording { try Self.record(grade: recorded) }
    }

    /// The vignette and grain at single output pixels, by place and rendered frame index, with the context demo's hole.
    @Test func everyFinishCaseThroughTheKernelMatchesTheRecipeAndTheGoldens() throws {
        let goldens = try Self.goldens()
        var recorded: [String: [Int]] = [:]
        let cases = try Self.corpus()[ai: "finish"].aiArray
        #expect(cases.count == 20)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let (width, height) = (item[ai: "width"].aiInt ?? 0, item[ai: "height"].aiInt ?? 0)
            let (x, y) = (item[ai: "x"].aiInt ?? 0, item[ai: "y"].aiInt ?? 0)
            let input = Self.ints(item[ai: "input"])
            let grade = ClipColorGrade(amount: item[ai: "amount"].aiInt ?? 100, vignette: item[ai: "vignette"].aiInt ?? 0, grain: item[ai: "grain"].aiInt ?? 0)
            let recipe = ClipGradeRecipe(look: .original, adjustments: nil, grade: grade)
            let hole = item[ai: "hole"] == .null ? nil : Self.doubles(item[ai: "hole"])
            let picture = CIImage(color: CIColor(red: Double(input[0]) / 255, green: Double(input[1]) / 255, blue: Double(input[2]) / 255))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let finished = try ClipPicture.finish(picture, recipe: recipe, width: width, height: height,
                                                  frameIndex: UInt32(item[ai: "n"].aiInt ?? 0),
                                                  hole: hole.map { ClipGrain.Hole(minX: $0[0], minY: $0[1], maxX: $0[2], maxY: $0[3]) })
            let found = Self.bytes(finished, CGRect(x: x, y: height - 1 - y, width: 1, height: 1))[0]
            let expected = Self.ints(item[ai: "bytes"])
            #expect(Self.near(found, expected, 2), "\(id): \(found) vs recipe \(expected)")
            recorded[id] = found
            if let goldens {
                let golden = Self.ints(goldens[ai: "finish"][ai: id])
                #expect(Self.near(found, golden, 1), "\(id): \(found) vs golden \(golden)")
            }
        }
        if let goldens { #expect(Set(goldens[ai: "finish"].aiObject?.keys.map { $0 } ?? []) == Set(recorded.keys)) }
        if Self.recording { try Self.record(finish: recorded) }
    }

    /// The grain field is the Core's integer field on the GPU: across whole windows of the frame (edges and middle, both
    /// cell sizes, two frame indices) the kernel's float output matches the recipe's to float precision, so every cell,
    /// quarter weight and hash agrees; an off cell or hash would move a pixel by thousands of times more.
    @Test func theGrainFieldIsTheCoresIntegerField() throws {
        for (width, height) in [(1080, 1920), (320, 180)] {
            for n: UInt32 in [0, 7] {
                let recipe = ClipGradeRecipe(look: .original, adjustments: nil, grade: ClipColorGrade(vignette: 40, grain: 100))
                let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                let finished = try ClipPicture.finish(grey, recipe: recipe, width: width, height: height, frameIndex: n, hole: nil)
                let hash = ClipGrain.frameHash(n)
                for (left, top) in [(0, 0), (width - 24, height - 24), (width / 2 - 12, height / 2 - 12)] {
                    var raw = [Float](repeating: 0, count: 4 * 24 * 24)
                    Self.context.render(finished, toBitmap: &raw, rowBytes: 16 * 24, bounds: CGRect(x: left, y: height - top - 24, width: 24, height: 24),
                                        format: .RGBAf, colorSpace: nil)
                    var worst = 0.0
                    for row in 0..<24 {
                        for column in 0..<24 {
                            let expected = recipe.finish([0.5, 0.5, 0.5], x: left + column, y: top + row, width: width, height: height,
                                                         frameHash: hash, hole: nil)
                            let found = Double(raw[4 * (row * 24 + column)])
                            worst = max(worst, abs(found - expected[0]))
                        }
                    }
                    #expect(worst < 2e-6, "\(width)×\(height) frame \(n) at (\(left), \(top)): \(worst)")
                }
            }
        }
    }

    /// Amount 0 with no Fix leaves the picture as filmed; the Fix alone still applies at amount 0.
    @Test func amountZeroLeavesThePictureAsFilmedExceptTheFix() throws {
        let picture = Self.frame([[217, 158, 128], [26, 51, 229], [128, 128, 128]])
        var controls = ProjectClipControls(clipId: "c", look: .bw, colorAdjustments: ClipColorAdjustments(contrast: 40))
        controls.colorGrade = ClipColorGrade(amount: 0, vibrance: 30, fade: 20)
        #expect(Self.bytes(try ClipPicture.grade(picture, controls: controls), picture.extent) == Self.bytes(picture, picture.extent))
        controls.colorGrade?.exposure = 50
        let fixed = Self.bytes(try ClipPicture.grade(picture, controls: controls), picture.extent)
        #expect(fixed[2] == [175, 175, 175], "\(fixed)")
    }

    // MARK: Recording

    static func record(grade: [String: [String: [Int]]]? = nil, finish: [String: [Int]]? = nil) throws {
        let url = try FixtureLoader.sharedRoot().appendingPathComponent(goldensPath)
        var file = (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))) ?? .null
        func encode(_ value: some Encodable) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
        let previousGrade = file[ai: "grade"], previousFinish = file[ai: "finish"]
        file = .object([
            "format": .string("voxclip-clip-grade-mac-goldens/1"),
            "description": .string("The Mac's Core Image bytes for every grade and finish case of clip-grade-cases.json, by case. Recorded by ClipGradeRenderTests with VOXCLIP_RECORD_CLIP_GRADE_GOLDENS=1; do not hand-edit."),
            "tolerance": .number(1),
            "grade": try grade.map(encode) ?? previousGrade,
            "finish": try finish.map(encode) ?? previousFinish,
        ])
        try lines(file).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sorted keys, one case a line.
    static func lines(_ file: JSONValue) throws -> String {
        func compact(_ value: JSONValue) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        let object = file.aiObject ?? [:]
        var out = ["{"]
        let keys = object.keys.sorted()
        for (index, key) in keys.enumerated() {
            let comma = index == keys.count - 1 ? "" : ","
            if let inner = object[key]?.aiObject {
                out.append("  \(try compact(.string(key))): {")
                let innerKeys = inner.keys.sorted()
                for (position, name) in innerKeys.enumerated() {
                    out.append("    \(try compact(.string(name))): \(try compact(inner[name] ?? .null))\(position == innerKeys.count - 1 ? "" : ",")")
                }
                out.append("  }\(comma)")
            } else {
                out.append("  \(try compact(.string(key))): \(try compact(object[key] ?? .null))\(comma)")
            }
        }
        out.append("}")
        return out.joined(separator: "\n") + "\n"
    }
}
