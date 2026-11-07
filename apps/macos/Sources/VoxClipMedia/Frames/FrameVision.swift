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
public struct AppleFrameVision: FrameObserving {
    public init() {}

    public func observe(_ image: CGImage, time: Double) throws -> FrameObservation {
        let landmarks = VNDetectFaceLandmarksRequest()
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
        try handler.perform([landmarks, text, rectangles])
        let faces = landmarks.results ?? []
        let largest = faces.max { area($0.boundingBox) < area($1.boundingBox) }
        var quality: Double?
        if let largest {
            let request = VNDetectFaceCaptureQualityRequest()
            request.inputFaceObservations = [largest]
            try handler.perform([request])
            quality = (request.results?.first?.faceCaptureQuality).map(Double.init)
        }
        let size = CGSize(width: image.width, height: image.height)
        let face = largest.map { observation in
            FrameFace(rect: Self.rect(observation.boundingBox), captureQuality: quality,
                      leftEyeAspect: Self.eyeAspect(observation.landmarks?.leftEye, size: size),
                      rightEyeAspect: Self.eyeAspect(observation.landmarks?.rightEye, size: size),
                      yaw: observation.yaw?.doubleValue, pitch: observation.pitch?.doubleValue)
        }
        // Only where text is: the recognised strings never leave this function.
        let texts = (text.results ?? []).map { Self.rect($0.boundingBox) }
        let boxes = (rectangles.results ?? []).map { Self.rect($0.boundingBox) }
        return FrameObservation(time: time, faceCount: faces.count, face: face, textRects: texts,
                                screens: FrameScreens.detect(rectangles: boxes, texts: texts))
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
