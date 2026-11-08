using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>One output span of source video: its source and output sample ranges and the crop it is drawn with. A zoom of 1
/// draws the plain center crop; a larger zoom crops in around (AnchorX, AnchorY) measured from the top-left.</summary>
public sealed record VoiceLabVideoSpan(long SourceStartSample, long SourceEndSample, long OutputStartSample, long OutputEndSample,
    double Zoom, double AnchorX, double AnchorY);

/// <summary>Changed-duration video framing for a verified Voice Lab render (voice-lab.md ADR-R38, render contract): the
/// port of Mac CompositionVideoSpan and CompositionFrameGeometry.faceCrop. Matched video (ZoomCover) is one retimed span
/// with its 1.12× crop; a quiet-boundary cut splits the replacement at each cut, the first span unzoomed and every later
/// span at the 1.06× centered punch-in. Source pieces and fitting takes keep zoom 1, so older projects draw unchanged.</summary>
public sealed class VoiceLabVideoFraming
{
    private VoiceLabVideoFraming(double sampleRate, IReadOnlyList<VoiceLabVideoSpan> spans) { SampleRate = sampleRate; Spans = spans; }

    /// <summary>Output sample rate the spans are measured in.</summary>
    public double SampleRate { get; }
    /// <summary>Contiguous output spans in output order.</summary>
    public IReadOnlyList<VoiceLabVideoSpan> Spans { get; }

    /// <summary>Build the spans, refusing any piece whose recipe does not describe its own source/output samples.</summary>
    public static VoiceLabVideoFraming Build(VoiceLabOutputPlan plan, IReadOnlyList<VoiceLabSelectedRecipe> selected)
    {
        ArgumentNullException.ThrowIfNull(selected);
        return Build(plan, piece => selected.FirstOrDefault(entry => entry.SegmentId == piece.SegmentId && entry.Piece == piece)?.Recipe.Video);
    }

    /// <summary>The span rule over each synthetic piece's video recipe; null refuses the piece as stale.</summary>
    internal static VoiceLabVideoFraming Build(VoiceLabOutputPlan plan, Func<VoiceLabOutputPiece, VoiceLabVideoRecipe?> videoFor)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (!double.IsFinite(plan.SampleRate) || plan.SampleRate < 1 || plan.SampleRate != Math.Truncate(plan.SampleRate) || plan.OutputSamples <= 0)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidRange);
        var spans = new List<VoiceLabVideoSpan>();
        long cursor = 0;
        foreach (var piece in plan.Pieces)
        {
            if (piece.SourceStartSample < 0 || piece.SourceEndSample <= piece.SourceStartSample || piece.SourceEndSample > plan.TotalSourceSamples ||
                piece.OutputStartSample != cursor || piece.OutputEndSample <= cursor)
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidRange);
            var sourceCount = piece.SourceEndSample - piece.SourceStartSample;
            var outputCount = piece.OutputEndSample - piece.OutputStartSample;
            double zoom = 1, anchorX = 0.5, anchorY = 0.5;
            if (piece.Kind == VoiceLabOutputPieceKind.Synth)
            {
                var video = videoFor(piece) ?? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
                if (video.SourceStartSample != piece.SourceStartSample || video.SourceEndSample != piece.SourceEndSample || video.OutputSamples != outputCount)
                    throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
                switch (video.Mode)
                {
                    case VoiceLabVideoMode.Cut:
                        if (!VoiceLabNaturalPacing.ValidCuts(video, plan.SampleRate) || video.Cuts is not { } cuts)
                            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.VideoModeUnsupported);
                        // A pause's jump cut punches in after its first span; the clip's own cuts under a whole-clip layout
                        // (zoom 1, ADR-R46) don't, and a cut at either edge leaves no span there.
                        var punch = video.Zoom ?? VoiceLabNaturalPacing.CUT_PUNCH_IN;
                        long sourceStart = piece.SourceStartSample, outputStart = piece.OutputStartSample;
                        var first = true;
                        foreach (var cut in cuts)
                        {
                            var count = cut.StartSample - sourceStart;
                            if (count > 0)
                            {
                                spans.Add(new(sourceStart, cut.StartSample, outputStart, outputStart + count, first ? 1 : punch, 0.5, 0.5));
                                first = false;
                            }
                            sourceStart = cut.EndSample; outputStart += count;
                        }
                        if (piece.SourceEndSample > sourceStart)
                            spans.Add(new(sourceStart, piece.SourceEndSample, outputStart, piece.OutputEndSample, punch, 0.5, 0.5));
                        cursor = piece.OutputEndSample;
                        continue;
                    case VoiceLabVideoMode.Source:
                        if (sourceCount != outputCount) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.VideoModeUnsupported);
                        break;
                    case VoiceLabVideoMode.ZoomCover:
                        var factor = (double)sourceCount / outputCount;
                        if (factor is not (>= VoiceLabVideoDurationOptions.MinimumRetime and <= VoiceLabVideoDurationOptions.MaximumRetime) ||
                            video.RetimeFactor is not { } declared || !double.IsFinite(declared) || Math.Abs(factor - declared) > 1e-6 ||
                            video.Zoom is not { } crop || !double.IsFinite(crop) || Math.Abs(crop - VoiceLabVideoDurationOptions.MatchZoom) > 1e-9 ||
                            video.FaceX is not { } faceX || !double.IsFinite(faceX) || faceX is < 0 or > 1 ||
                            video.FaceY is not { } faceY || !double.IsFinite(faceY) || faceY is < 0 or > 1)
                            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.VideoModeUnsupported);
                        zoom = crop; anchorX = faceX; anchorY = faceY;
                        break;
                    default: throw new VoiceLabProjectException(VoiceLabProjectErrorCode.VideoModeUnsupported);
                }
            }
            else if (sourceCount != outputCount) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.VideoModeUnsupported);
            cursor = piece.OutputEndSample;
            spans.Add(new(piece.SourceStartSample, piece.SourceEndSample, piece.OutputStartSample, piece.OutputEndSample, zoom, anchorX, anchorY));
        }
        return new(plan.SampleRate, spans.AsReadOnly());
    }

    /// <summary>The span drawn at an output time: the one whose half-open [start, end) output range holds it, as an
    /// AVFoundation instruction does for its composition time. Times at or past the end use the last span.</summary>
    public VoiceLabVideoSpan At(double editedTime)
    {
        if (Spans.Count == 0) throw new InvalidOperationException("The framing has no spans.");
        int low = 0, high = Spans.Count - 1;
        while (low < high)
        {
            var middle = (low + high + 1) / 2;
            if (editedTime >= Spans[middle].OutputStartSample / SampleRate) low = middle; else high = middle - 1;
        }
        return Spans[low];
    }

    /// <summary>The crop for a zoomed span in top-left coordinates: the aspect crop divided by scale, centered on the anchor
    /// point of the oriented source and kept inside it. Mac CompositionFrameGeometry.faceCrop, with Y measured downward.</summary>
    public static RectD FaceCrop(RectD source, RectD aspectCrop, double scale, double faceX, double faceY)
    {
        var width = aspectCrop.Width / scale;
        var height = aspectCrop.Height / scale;
        var centerX = source.X + source.Width * faceX;
        var centerY = source.Y + source.Height * faceY;
        return new(Math.Min(source.X + source.Width - width, Math.Max(source.X, centerX - width / 2)),
            Math.Min(source.Y + source.Height - height, Math.Max(source.Y, centerY - height / 2)), width, height);
    }
}
