using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using System.Text.Json;

namespace VoxClip.Core.Domain.Shared;

/// <summary>One isolated, verified public project request for native media preparation.</summary>
public sealed class VoiceLabRenderInput
{
    private readonly string projectJson;
    private VoiceLabRenderInput(string projectJson, VoiceLabPreparedRender prepared, string paidRoot)
    { this.projectJson = projectJson; Prepared = prepared; PaidRoot = paidRoot; }

    /// <summary>Verified immutable Core render instructions.</summary>
    public VoiceLabPreparedRender Prepared { get; }
    /// <summary>Private paid asset storage root, never serialized to output.</summary>
    public string PaidRoot { get; }
    /// <summary>Exact captured project bytes for snapshot reuse checks.</summary>
    public string Fingerprint => projectJson;

    /// <summary>Verify the caller's project and take an isolated value copy before asynchronous native work.</summary>
    public static VoiceLabRenderInput Capture(Project project, VoiceLabPreparedRender prepared, string paidRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(paidRoot);
        prepared.Verify(project, prepared.OutputPlan.Scope, prepared.Disclosure.Position);
        if (prepared.SelectedSegmentRecipes.Any(item => item.Recipe.Video.Mode != VoiceLabVideoMode.Source))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.VideoModeUnsupported);
        var json = ProjectSerialization.Serialize(project);
        var isolated = ProjectSerialization.Deserialize(json);
        prepared.Verify(isolated, prepared.OutputPlan.Scope, prepared.Disclosure.Position);
        prepared.Verify(project, prepared.OutputPlan.Scope, prepared.Disclosure.Position);
        return new(json, prepared, Path.GetFullPath(paidRoot));
    }

    /// <summary>Return a fresh isolated project value, with contract verification.</summary>
    public Project IsolatedProject()
    {
        var isolated = ProjectSerialization.Deserialize(projectJson);
        Prepared.Verify(isolated, Prepared.OutputPlan.Scope, Prepared.Disclosure.Position);
        return isolated;
    }

    /// <summary>Reject stale media/captions and capture mutable companion collections for a native job.</summary>
    public ComposeSnapshot CaptureSnapshot(ComposeSnapshot snapshot)
    {
        if (!ReferenceEquals(snapshot.VoiceLab, this))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
        var project = IsolatedProject();
        var reference = project.Media.Source;
        var media = snapshot.Media;
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var video = reference.Video;
        var oriented = video is null ? default : video.RotationDegrees is 90 or 270
            ? new PixelSize(video.Height, video.Width) : new PixelSize(video.Width, video.Height);
        if (!string.Equals(Path.GetFullPath(media.Path), Path.GetFullPath(reference.AbsolutePath), comparison) ||
            media.Audio != reference.Audio || media.Audio?.SampleRate != Prepared.OutputPlan.SampleRate ||
            media.Video != video || media.OrientedSize.Width <= 0 || media.OrientedSize.Height <= 0 ||
            (long)media.OrientedSize.Width * oriented.Height != (long)media.OrientedSize.Height * oriented.Width ||
            media.VideoTrackIndex < 0 || media.AudioTrackIndex < 0 ||
            EditingMath.Round(media.DurationSeconds * Prepared.OutputPlan.SampleRate) != Prepared.OutputPlan.TotalSourceSamples ||
            snapshot.Plan.SampleRate != Prepared.OutputPlan.SampleRate ||
            snapshot.Plan.TotalSamples != Prepared.OutputPlan.TotalSourceSamples ||
            snapshot.Output.Size.Width <= 0 || snapshot.Output.Size.Height <= 0 ||
            !double.IsFinite(snapshot.Output.FrameRate) || snapshot.Output.FrameRate <= 0)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
        var captions = snapshot.Captions;
        if (captions is not null)
        {
            VerifyCaptions(captions, snapshot.Output.Size);
            try
            {
                captions = JsonSerializer.Deserialize(JsonSerializer.Serialize(captions, ProjectJsonContext.Default.CaptionTrack),
                    ProjectJsonContext.Default.CaptionTrack)
                    ?? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
            }
            catch (JsonException)
            { throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract); }
            VerifyCaptions(captions, snapshot.Output.Size);
        }
        var plan = snapshot.Plan with
        {
            Cuts = Array.AsReadOnly(snapshot.Plan.Cuts.ToArray()),
            Kept = Array.AsReadOnly(snapshot.Plan.Kept.ToArray())
        };
        return snapshot with { Plan = plan, Captions = captions };
    }

    private void VerifyCaptions(CaptionTrack captions, PixelSize size)
    {
        var plan = Prepared.OutputPlan;
        if (!double.IsFinite(captions.Duration) || Math.Abs(captions.Duration - plan.Duration) > 1 / plan.SampleRate ||
            captions.Frame.Width <= 0 || captions.Frame.Height <= 0 ||
            Math.Abs(captions.Frame.Width * (double)size.Height - captions.Frame.Height * (double)size.Width) >
                Math.Max(captions.Frame.Width, captions.Frame.Height) ||
            captions.Words.Count + captions.Dropped.Count != plan.Captions.Count)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
        var covered = new bool[plan.Captions.Count];
        foreach (var word in captions.Words)
        {
            if (word.SourceIndex < 0 || word.SourceIndex >= plan.Captions.Count || covered[word.SourceIndex])
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
            var expected = plan.Captions[word.SourceIndex];
            if (word.Id != expected.Id || word.Raw != expected.Text || word.Start != expected.Start || word.End != expected.End)
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
            covered[word.SourceIndex] = true;
        }
        foreach (var (index, text, _) in captions.Dropped)
        {
            if (index < 0 || index >= plan.Captions.Count || covered[index] || plan.Captions[index].Text != text)
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
            covered[index] = true;
        }
        if (covered.Any(value => !value) || captions.Pages.Any(page => !double.IsFinite(page.Start) ||
            !double.IsFinite(page.End) || page.Start < 0 || page.End > plan.Duration ||
            page.End < page.Start || page.Words.Any(index => index < 0 || index >= captions.Words.Count)))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
    }
}
