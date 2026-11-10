import CoreGraphics
import Foundation
import Vision
import VoxClipCore

/// Looks at one decoded frame. The seam between the analyzer and Apple Vision, so tests count and stub it.
public protocol FrameObserving: Sendable {
    func observe(_ image: CGImage, time: Double) throws -> FrameObservation
}

/// Apple Vision, on device (ADR-R48): the largest face's rect, capture quality, eye aspect ratios and head angles; text
/// boxes from the fast recognizer (positions only: the strings are dropped here); and rectangles, which with dense text
/// make a screen.
///
/// Faces come from `VNDetectFaceRectanglesRequest` revision 3, which reports continuous yaw, pitch and roll. Its largest
/// face is handed to the landmarks and capture-quality requests (`inputFaceObservations`), so all three describe the
/// same face box. Landmarks run alone use an internal revision-2 detector instead ("creating VNFaceBBoxAligner from
/// VNFaceDetectorRevision2"), whose yaw is 0 or ±π/4 and whose pitch is nil (ADR-R48, 2026-11-08).
public struct AppleFrameVision: FrameObserving {
    public init() {}

    /// Synchronous Vision: `FrameAnalyzer.look` runs it on `VisionQueue`.
    public func observe(_ image: CGImage, time: Double) throws -> FrameObservation {
        VisionQueue.assertOnQueue()
        let faces = Self.faceRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 6
        rectangles.minimumAspectRatio = 0.3
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.1
        rectangles.minimumConfidence = 0.6
        rectangles.quadratureTolerance = 25
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([faces, text, rectangles])
        let found = faces.results ?? []
        let largest = found.max { area($0.boundingBox) < area($1.boundingBox) }
        let size = CGSize(width: image.width, height: image.height)
        var face: FrameFace?
        if let largest {
            let landmarks = VNDetectFaceLandmarksRequest()
            landmarks.inputFaceObservations = [largest]
            let capture = VNDetectFaceCaptureQualityRequest()
            capture.inputFaceObservations = [largest]
            try handler.perform([landmarks, capture])
            let regions = landmarks.results?.first?.landmarks
            let quality = (capture.results?.first?.faceCaptureQuality).map(Double.init)
            face = FrameFace(rect: Self.rect(largest.boundingBox), captureQuality: quality,
                             leftEyeAspect: Self.eyeAspect(regions?.leftEye, size: size),
                             rightEyeAspect: Self.eyeAspect(regions?.rightEye, size: size),
                             yaw: largest.yaw?.doubleValue, pitch: largest.pitch?.doubleValue)
        }
        // Only where text is: the recognised strings never leave this function.
        let texts = (text.results ?? []).map { Self.rect($0.boundingBox) }
        let boxes = (rectangles.results ?? []).map { Self.rect($0.boundingBox) }
        return FrameObservation(time: time, faceCount: found.count, face: face, textRects: texts,
                                screens: FrameScreens.detect(rectangles: boxes, texts: texts))
    }

    /// The face detector, pinned to revision 3: continuous yaw, pitch and roll.
    static func faceRequest() -> VNDetectFaceRectanglesRequest {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }

    /// Vision's bottom-left normalized box as a picture-space rect.
    static func rect(_ box: CGRect) -> ClipEffect.Rect {
        ClipEffect.Rect(x: Double(box.minX), y: Double(1 - box.maxY), width: Double(box.width), height: Double(box.height)).clamped
    }

    static func eyeAspect(_ region: VNFaceLandmarkRegion2D?, size: CGSize) -> Double? {
        guard let region, region.pointCount >= 3 else { return nil }
        let points = region.pointsInImage(imageSize: size).map { (x: Double($0.x), y: Double($0.y)) }
        return EyeAspect.ratio(points)
    }

    private func area(_ box: CGRect) -> CGFloat { box.width * box.height }
}
