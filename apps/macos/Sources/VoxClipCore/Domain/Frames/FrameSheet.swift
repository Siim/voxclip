import Foundation

/// The frames a plan request shows the AI (ADR-R48): one small JPEG per sentence, each labelled with its time, and a
/// compact text summary of what was measured on each. A connector that takes images gets both; one that cannot gets the
/// summary only (ai.md §19.3).
public struct FrameSheet: Sendable, Equatable {
    /// The long edge of each frame, in pixels.
    public static let frameEdge = 320
    /// At most this many frames per clip.
    public static let maximumFrames = FrameSampling.maximumSentences
    /// Anthropic's image token estimate: width × height / 750, rounded up (Claude vision docs). Other providers count
    /// differently; the estimate is for the send line, not for billing.
    public static let pixelsPerToken = 750.0

    public var frames: [FrameSheetFrame]

    public init(frames: [FrameSheetFrame]) { self.frames = Array(frames.prefix(Self.maximumFrames)) }

    /// The images as the request carries them.
    public var images: [LLMImage] { frames.map(\.image) }

    /// The summary block: a header line, then one line per frame.
    public var summary: String {
        guard !frames.isEmpty else { return "" }
        let header = "Frames measured on this Mac (one per sentence; rects are x,y,w,h of the picture, top-left origin):"
        return ([header] + frames.map(\.summaryLine)).joined(separator: "\n")
    }

    /// The JPEG bytes the images add to a request (before base64).
    public var imageBytes: Int { frames.map(\.image.data.count).reduce(0, +) }

    /// The estimated input tokens of the images and of the summary (`AITokenPolicy`'s bytes per token).
    public var estimatedImageTokens: Int { frames.map { Self.imageTokens(width: $0.image.width, height: $0.image.height) }.reduce(0, +) }
    public var estimatedSummaryTokens: Int { Int(ceil(Double(summary.utf8.count) / 2.2)) }

    public static func imageTokens(width: Int, height: Int) -> Int {
        let pixels = Double(max(0, width)) * Double(max(0, height))
        return Int(ceil(pixels / pixelsPerToken))
    }
}

/// One frame of the sheet.
public struct FrameSheetFrame: Sendable, Equatable {
    public var index: Int
    public var observation: FrameObservation
    public var image: LLMImage

    public init(index: Int, observation: FrameObservation, jpeg: Data, width: Int, height: Int) {
        self.index = index
        self.observation = observation
        self.image = LLMImage(label: FrameSheetFrame.label(index: index, time: observation.time), mediaType: "image/jpeg",
                              data: jpeg, width: width, height: height)
    }

    /// "Frame 3 at 12.40 s".
    public static func label(index: Int, time: Double) -> String { "Frame \(index) at \(FrameSheetFrame.seconds(time)) s" }

    /// "F3 12.40 s: face at 0.42,0.18,0.20,0.36, eyes open, quality 0.62, facing camera; screen with text at …".
    public var summaryLine: String {
        var parts: [String] = []
        let frame = observation
        if let face = frame.face {
            var facePart = "face at \(Self.rect(face.rect))"
            if frame.faceCount > 1 { facePart += " (largest of \(frame.faceCount))" }
            parts.append(facePart)
            parts.append("eyes \(face.eyes.rawValue)")
            if let quality = face.captureQuality { parts.append("quality \(Self.fixed(quality))") }
            if let facing = face.facesCamera { parts.append(facing ? "facing camera" : "turned away") }
        } else {
            parts.append("no face")
        }
        for screen in frame.screens {
            parts.append("\(screen.framed ? "screen" : "dense text") with \(screen.textBoxes) text boxes at \(Self.rect(screen.rect))")
        }
        if frame.screens.isEmpty, !frame.textRects.isEmpty { parts.append("\(frame.textRects.count) text boxes") }
        return "F\(index) \(Self.seconds(frame.time)) s: " + parts.joined(separator: ", ")
    }

    static func seconds(_ value: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
    static func fixed(_ value: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
    static func rect(_ rect: ClipEffect.Rect) -> String { [rect.x, rect.y, rect.width, rect.height].map(fixed).joined(separator: ",") }
}
