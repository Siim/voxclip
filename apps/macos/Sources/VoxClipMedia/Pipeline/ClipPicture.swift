import CoreGraphics
import CoreImage
import Foundation
import VoxClipCore

/// A clip's picture controls in the shared frame compositor (design.md §6.9), so preview and export draw the same frame:
/// the flip and quarter turns on the oriented source before the frame's crop, and the look on the finished frame before
/// captions. Every recipe is a fixed Core Image chain on the compositor's unmanaged working space.
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

    /// The look's colour transform: per-pixel matrices and one cubic, so the same numbers render on any platform
    /// (`ClipLookRecipe` in VoxClipCore). Original returns the image untouched, so a clip without a look renders
    /// bit-exactly as before.
    static func look(_ image: CIImage, _ look: ClipLook) -> CIImage {
        let recipe = ClipLookRecipe(look)
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
