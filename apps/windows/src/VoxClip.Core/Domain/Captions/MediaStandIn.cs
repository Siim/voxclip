namespace VoxClip.Core.Domain.Captions;

/// <summary>The transcription stage a media chip names; design §5.4.8 and §13.</summary>
public enum MediaTranscriptionStage
{
    /// <summary>"Reading video…"</summary>
    ReadingVideo,
    /// <summary>"Extracting audio…"</summary>
    ExtractingAudio,
    /// <summary>"Transcribing · {p}%", or "Transcribing" when the engine reports no fraction.</summary>
    Transcribing,
    /// <summary>"Aligning words…"</summary>
    Aligning,
}

/// <summary>The media state of a project or scope; design §5.4.4. Views overlay its chip, progress line and copy on the
/// stand-in that MediaStandIn.Resolve picks.</summary>
public abstract record MediaStatus
{
    /// <summary>The video is there (state a), including a black first frame (state f).</summary>
    public sealed record None : MediaStatus;
    /// <summary>The project file or the frame is still loading (state b, §5.4.5).</summary>
    public sealed record Loading : MediaStatus;
    /// <summary>The video is not found (state c).</summary>
    public sealed record Missing : MediaStatus;
    /// <summary>The video can't be read (state f, corrupt file).</summary>
    public sealed record Unreadable : MediaStatus;
    /// <summary>Transcribing (state d), with a fraction when the engine reports one.</summary>
    public sealed record Transcribing(double? Fraction, MediaTranscriptionStage Stage) : MediaStatus;
    /// <summary>A demo or sample project with no video (state e).</summary>
    public sealed record Demo : MediaStatus;
    /// <summary>The source has no video track (state f, video == null).</summary>
    public sealed record AudioOnly : MediaStatus;
}

/// <summary>What a frame-backed surface draws (Home tiles, sidebar thumbnails, clip rows); design §5.4.1. Views draw it and
/// never decide the precedence themselves.</summary>
public abstract record MediaStandIn
{
    /// <summary>The first kept frame of the scope, which the view supplies.</summary>
    public sealed record Frame : MediaStandIn;
    /// <summary>The caption card in a style. A card without words draws only the style's backdrop (state d, no frame yet).</summary>
    public sealed record Card(CaptionCardText Text, string StyleId) : MediaStandIn;
    /// <summary>Stage black.</summary>
    public sealed record Black : MediaStandIn;

    /// <summary>Design §5.4.1 precedence over the §5.4.4 states. Missing, unreadable, demo and audio-only media never show a
    /// frame: their card, or black when it has no words. Otherwise a frame wins; holding is the first 300 ms of the §5.4.5
    /// ladder, which shows black until a frame arrives; then the card, and while transcribing the style's backdrop even
    /// without words. styleId is the style the card was made in.</summary>
    public static MediaStandIn Resolve(MediaStatus status, bool hasFrame, CaptionCardText card, string styleId, bool holding = false)
    {
        ArgumentNullException.ThrowIfNull(status);
        ArgumentNullException.ThrowIfNull(card);
        if (status is MediaStatus.Missing or MediaStatus.Unreadable or MediaStatus.Demo or MediaStatus.AudioOnly)
            return card.Words.Count == 0 ? new Black() : new Card(card, styleId);
        if (hasFrame) return new Frame();
        if (holding) return new Black();
        return card.Words.Count > 0 || status is MediaStatus.Transcribing ? new Card(card, styleId) : new Black();
    }
}
