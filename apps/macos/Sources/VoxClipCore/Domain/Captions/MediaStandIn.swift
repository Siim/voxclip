import Foundation

/// The transcription stage a media chip names; design §5.4.8 and §13.
public enum MediaTranscriptionStage: String, Codable, Sendable, CaseIterable {
    /// "Reading video…"
    case readingVideo
    /// "Extracting audio…"
    case extractingAudio
    /// "Transcribing · {p}%", or "Transcribing" when the engine reports no fraction.
    case transcribing
    /// "Aligning words…"
    case aligning
}

/// The media state of a project or scope; design §5.4.4. Views overlay its chip, progress line and copy on the
/// stand-in that `MediaStandIn.resolve` picks.
public enum MediaStatus: Sendable, Equatable {
    /// The video is there (state a), including a black first frame (state f).
    case none
    /// The project file or the frame is still loading (state b, §5.4.5).
    case loading
    /// The video is not found (state c).
    case missing
    /// The video can't be read (state f, corrupt file).
    case unreadable
    /// Transcribing (state d), with a fraction when the engine reports one.
    case transcribing(fraction: Double?, stage: MediaTranscriptionStage)
    /// A demo or sample project with no video (state e).
    case demo
    /// The source has no video track (state f, `video == null`).
    case audioOnly
}

/// What a frame-backed surface draws (Home tiles, sidebar thumbnails, clip rows); design §5.4.1. Views draw it and
/// never decide the precedence themselves.
public enum MediaStandIn: Sendable, Equatable {
    /// The first kept frame of the scope, which the view supplies.
    case frame
    /// The caption card in a style. A card without words draws only the style's backdrop (state d, no frame yet).
    case card(CaptionCardText, styleId: String)
    /// Stage black.
    case black

    /// Design §5.4.1 precedence over the §5.4.4 states. Missing, unreadable, demo and audio-only media never show a
    /// frame: their card, or black when it has no words. Otherwise a frame wins; `holding` is the first 300 ms of the
    /// §5.4.5 ladder, which shows black until a frame arrives; then the card, and while transcribing the style's
    /// backdrop even without words. `styleId` is the style the card was made in.
    public static func resolve(status: MediaStatus, hasFrame: Bool, card: CaptionCardText, styleId: String, holding: Bool = false) -> MediaStandIn {
        switch status {
        case .missing, .unreadable, .demo, .audioOnly:
            return card.words.isEmpty ? .black : .card(card, styleId: styleId)
        case .none, .loading, .transcribing:
            if hasFrame { return .frame }
            if holding { return .black }
            if case .transcribing = status { return .card(card, styleId: styleId) }
            return card.words.isEmpty ? .black : .card(card, styleId: styleId)
        }
    }
}
