import CoreImage
import Foundation
import Metal
import VoxClipCore
import os

/// The clip grade's Core Image kernels (looks spec 2026-11-28, section 5.10): loaded once from the precompiled library
/// (`ClipGradeKernelLibrary`, built from ClipGradeKernels.ci.metal by tools/looks/build_mac_kernels.py). Core Image
/// concatenates them with the look's matrix and polynomial, so a whole grade is about one GPU pass.
///
/// Custom kernels need a Metal GPU. Without one, or when the library doesn't load (logged with its error), every render
/// that needs them fails with `VoxClipError.looksNeedMetal` instead of leaving the picture ungraded.
final class ClipGradeKernels: @unchecked Sendable {
    /// Stage P, the Fix.
    let fix: CIColorKernel
    /// Stage T and the Amount mix.
    let tone: CIColorKernel
    /// The same with a preset's curves and split toning.
    let toning: CIColorKernel
    /// Stage F, the vignette and grain by output pixel.
    let finish: CIColorKernel

    var names: [String] { [fix.name, tone.name, toning.name, finish.name] }

    private init(fix: CIColorKernel, tone: CIColorKernel, toning: CIColorKernel, finish: CIColorKernel) {
        self.fix = fix; self.tone = tone; self.toning = toning; self.finish = finish
    }

    /// Why the kernels can't run.
    struct Unavailable: Error, Equatable {
        let detail: String
    }

    static let shared: Result<ClipGradeKernels, Unavailable> = {
        let result = load(hasMetal: MTLCreateSystemDefaultDevice() != nil, library: Data(ClipGradeKernelLibrary.base64.utf8))
        if case .failure(let failure) = result {
            Logger(subsystem: "com.voxconvo.voxclip", category: "render").error("Clip grade kernels unavailable: \(failure.detail, privacy: .public)")
        }
        return result
    }()

    /// The kernels from the library's base64 text, or why they can't run.
    static func load(hasMetal: Bool, library base64: Data) -> Result<ClipGradeKernels, Unavailable> {
        guard hasMetal else { return .failure(Unavailable(detail: "no Metal device")) }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
            return .failure(Unavailable(detail: "the kernel library is not base64"))
        }
        do {
            return .success(ClipGradeKernels(fix: try CIColorKernel(functionName: "clipGradeFix", fromMetalLibraryData: data),
                                             tone: try CIColorKernel(functionName: "clipGradeTone", fromMetalLibraryData: data),
                                             toning: try CIColorKernel(functionName: "clipGradeToning", fromMetalLibraryData: data),
                                             finish: try CIColorKernel(functionName: "clipGradeFinish", fromMetalLibraryData: data)))
        } catch {
            return .failure(Unavailable(detail: "the kernel library failed to load: \(error.localizedDescription)"))
        }
    }

    /// The kernels, or the render error every caller shows.
    static func require(_ kernels: Result<ClipGradeKernels, Unavailable> = shared) throws -> ClipGradeKernels {
        guard case .success(let loaded) = kernels else { throw VoxClipError.exportFailed(VoxClipError.looksNeedMetal) }
        return loaded
    }
}
