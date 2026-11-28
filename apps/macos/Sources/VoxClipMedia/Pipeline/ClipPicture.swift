import CoreGraphics
import CoreImage
import Foundation
import VoxClipCore

/// A clip's picture controls in the shared frame compositor (design.md §6.9), so preview and export draw the same frame:
/// the flip and quarter turns on the oriented source before the frame's crop, the grade on the framed picture before Ask
/// Claude's effects, and the finish on the output frame before titles and captions. Every recipe is a fixed Core Image
/// chain on the compositor's unmanaged working space: built-in filters for the classic looks, and the clip grade's own
/// kernels (`ClipGradeKernels`) for the Fix, the new controls and Amount.
enum ClipPicture {
    /// Mirrors, then turns clockwise; the result starts at the origin. Exact integer matrices, so a 1920 × 1080 source turns
    /// into exactly 1080 × 1920.
    static func orient(_ image: CIImage, controls: ProjectClipControls?) -> CIImage {
        guard let controls, controls.flipHorizontal || controls.rotationDegrees != 0 else { return image }
        var result = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if controls.flipHorizontal { result = result.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)) }
        switch controls.rotationDegrees {
        case 90: result = result.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0))
        case 180: result = result.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0))
        case 270: result = result.transformed(by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0))
        default: break
        }
        return result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
    }

    typealias Kernels = Result<ClipGradeKernels, ClipGradeKernels.Unavailable>

    /// The clip's grade of the framed picture `o` (looks spec 2026-11-28, sections 5.2 and 6): the Fix (P), the base look or
    /// a timed `colourLook` in its place (L), the adjustments (A), the tone, vibrance, curves, split tone and fade (T), and
    /// the Amount mix over the Fix's output. Without a Fix, new controls or a partial amount it is exactly the classic chain,
    /// L then A as built-in filters, so the eight classic looks render as they always have and need no custom kernel.
    static func grade(_ image: CIImage, controls: ProjectClipControls, override: ClipLook? = nil, kernels: Kernels = ClipGradeKernels.shared) throws -> CIImage {
        try grade(image, recipe: ClipGradeRecipe(controls: controls, override: override), kernels: kernels)
    }

    static func grade(_ image: CIImage, recipe: ClipGradeRecipe, kernels: Kernels = ClipGradeKernels.shared) throws -> CIImage {
        guard recipe.primary != nil || recipe.tone != nil || recipe.amount != 1 else { return classic(image, recipe) }
        // Amount 0 with no Fix: f, the clamped picture as filmed.
        if recipe.primary == nil, recipe.amount <= 0 { return image.applyingFilter("CIColorClamp") }
        let loaded = try ClipGradeKernels.require(kernels)
        let fixed = try recipe.primary.map { try fix(image, $0, loaded) } ?? image.applyingFilter("CIColorClamp")
        guard recipe.amount > 0 else { return fixed }
        let graded = classic(fixed, recipe)
        guard recipe.tone != nil || recipe.amount < 1 else { return graded }
        return try tone(graded, fixed: fixed, recipe: recipe, loaded)
    }

    /// Whether `recipe` renders through the custom kernels; the classic looks and an amount of 0 with no Fix don't.
    static func needsKernels(_ recipe: ClipGradeRecipe) -> Bool {
        recipe.primary != nil || (recipe.amount > 0 && (recipe.tone != nil || recipe.amount < 1)) || recipe.hasFinish
    }

    /// Stage F on the output frame after the motion crop and companion footage: the vignette, then grain at the rendered
    /// frame index, skipping the context demo's `hole`. Tiles leave the grain out (`grain: false`).
    static func finish(_ image: CIImage, recipe: ClipGradeRecipe, width: Int, height: Int, frameIndex: UInt32, hole: ClipGrain.Hole?,
                       grain: Bool = true, kernels: Kernels = ClipGradeKernels.shared) throws -> CIImage {
        let strength = grain ? recipe.grain : 0
        guard recipe.vignette > 0 || strength > 0 else { return image }
        let loaded = try ClipGradeKernels.require(kernels)
        let hash = ClipGrain.frameHash(frameIndex)
        let gap = hole ?? ClipGrain.Hole(minX: 0, minY: 0, maxX: 0, maxY: 0)
        return try applied(loaded.finish, CGRect(x: 0, y: 0, width: width, height: height), [image,
            CIVector(x: CGFloat(width), y: CGFloat(height), z: recipe.vignette, w: strength),
            CIVector(x: CGFloat(ClipGrain.cellSize(width: width, height: height)), y: CGFloat(hash >> 16), z: CGFloat(hash & 0xFFFF), w: 0),
            CIVector(x: gap.minX, y: gap.minY, z: gap.maxX, w: gap.maxY)])
    }

    /// L then A, as today: no clamp between them, as Core Image never had one.
    private static func classic(_ image: CIImage, _ recipe: ClipGradeRecipe) -> CIImage {
        let base = apply(recipe.look, to: image)
        return recipe.adjustments.map { apply($0, to: base) } ?? base
    }

    private static func fix(_ image: CIImage, _ primary: ClipGradeRecipe.Primary, _ kernels: ClipGradeKernels) throws -> CIImage {
        let gains = primary.gains, shoulders = primary.shoulders
        return try applied(kernels.fix, image.extent, [image,
            CIVector(x: gains[0], y: gains[1], z: gains[2], w: 1),
            CIVector(x: shoulders[0] == nil ? 0 : 1, y: shoulders[1] == nil ? 0 : 1, z: shoulders[2] == nil ? 0 : 1, w: 0),
            CIVector(x: shoulders[0]?.alpha ?? 0, y: shoulders[1]?.alpha ?? 0, z: shoulders[2]?.alpha ?? 0, w: 0)])
    }

    private static func tone(_ graded: CIImage, fixed: CIImage, recipe: ClipGradeRecipe, _ kernels: ClipGradeKernels) throws -> CIImage {
        let tone = recipe.tone
        func vectors(_ curve: ClipGradeRecipe.Curve?) -> [CIVector] {
            (0..<4).map { index in
                let c = curve?.segments[index] ?? [0, 0, 0, 0]
                return CIVector(x: c[0], y: c[1], z: c[2], w: c[3])
            }
        }
        let split = tone?.splitTone
        let params = CIVector(x: tone?.vibrance ?? 0, y: tone?.fade ?? 0, z: recipe.amount, w: 0)
        let flags = CIVector(x: tone?.shadowsHighlights == nil ? 0 : 1, y: tone?.vibrance == nil ? 0 : 1, z: tone?.fade == nil ? 0 : 1,
                             w: split == nil ? 0 : 1)
        var arguments: [Any] = [graded, fixed] + vectors(tone?.shadowsHighlights) + [params, flags]
        guard let tone, tone.master != nil || tone.red != nil || tone.green != nil || tone.blue != nil || split != nil else {
            return try applied(kernels.tone, graded.extent, arguments)
        }
        arguments += vectors(tone.master) + vectors(tone.red) + vectors(tone.green) + vectors(tone.blue)
        arguments.append(CIVector(x: tone.master == nil ? 0 : 1, y: tone.red == nil ? 0 : 1, z: tone.green == nil ? 0 : 1, w: tone.blue == nil ? 0 : 1))
        arguments.append(CIVector(x: split?.shadow[0] ?? 0, y: split?.shadow[1] ?? 0, z: split?.shadow[2] ?? 0, w: split?.balance ?? 0))
        arguments.append(CIVector(x: split?.highlight[0] ?? 0, y: split?.highlight[1] ?? 0, z: split?.highlight[2] ?? 0, w: 0))
        return try applied(kernels.toning, graded.extent, arguments)
    }

    private static func applied(_ kernel: CIColorKernel, _ extent: CGRect, _ arguments: [Any]) throws -> CIImage {
        guard let image = kernel.apply(extent: extent, arguments: arguments) else {
            throw VoxClipError.exportFailed("Cannot apply the clip grade's \(kernel.name) kernel")
        }
        return image
    }

    static func look(_ image: CIImage, _ look: ClipLook) -> CIImage {
        look == .original ? image : apply(ClipLookRecipe(look), to: image)
    }

    private static func apply(_ recipe: ClipLookRecipe, to image: CIImage) -> CIImage {
        guard !recipe.isIdentity else { return image }
        let rows = recipe.matrix
        var result = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: rows[0][0], y: rows[0][1], z: rows[0][2], w: 0),
            "inputGVector": CIVector(x: rows[1][0], y: rows[1][1], z: rows[1][2], w: 0),
            "inputBVector": CIVector(x: rows[2][0], y: rows[2][1], z: rows[2][2], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: recipe.bias[0], y: recipe.bias[1], z: recipe.bias[2], w: 0)])
        if let curve = recipe.curve {
            let coefficients = CIVector(x: curve[0], y: curve[1], z: curve[2], w: curve[3])
            result = result.applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": coefficients, "inputGreenCoefficients": coefficients,
                "inputBlueCoefficients": coefficients, "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0)])
        }
        return result
    }
}
