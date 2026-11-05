#pragma warning disable CS1591
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabLabelPosition>))]
public enum VoiceLabLabelPosition { [JsonStringEnumMemberName("topLeft")] TopLeft, [JsonStringEnumMemberName("topRight")] TopRight,
    [JsonStringEnumMemberName("bottomLeft")] BottomLeft, [JsonStringEnumMemberName("bottomRight")] BottomRight }
public sealed record VoiceLabLabelInterval(double Start, double End);
public sealed record VoiceLabDisclosurePlan(bool Required, IReadOnlyList<string> Kinds, double OutputAiSeconds, bool Persistent,
    IReadOnlyList<VoiceLabLabelInterval> Intervals, double FadeSeconds, VoiceLabLabelPosition Position, string? PostText);
public sealed record VoiceLabSelectedRecipe(string SegmentId, VoiceLabOutputPiece Piece, VoiceLabRenderRecipe Recipe);
public sealed class VoiceLabPreparedRender
{
    private readonly string projectSnapshot;
    private VoiceLabPreparedRender(VoiceLabOutputPlan outputPlan, IReadOnlyList<VoiceLabSelectedRecipe> selectedSegmentRecipes,
        VoiceLabDisclosurePlan disclosure, string projectSnapshot)
    {
        OutputPlan = outputPlan; SelectedSegmentRecipes = selectedSegmentRecipes;
        Disclosure = disclosure; this.projectSnapshot = projectSnapshot;
    }
    public VoiceLabOutputPlan OutputPlan { get; }
    public IReadOnlyList<VoiceLabSelectedRecipe> SelectedSegmentRecipes { get; }
    public VoiceLabDisclosurePlan Disclosure { get; }
    internal static VoiceLabPreparedRender Create(VoiceLabOutputPlan plan, IReadOnlyList<VoiceLabSelectedRecipe> selected,
        VoiceLabDisclosurePlan disclosure, string snapshot)
    {
        var frozenPlan = plan with { Pieces = Array.AsReadOnly(plan.Pieces.ToArray()), Captions = Array.AsReadOnly(plan.Captions.ToArray()) };
        var frozenRecipes = selected.Select(item => item with { Recipe = item.Recipe with {
            Chunks = Array.AsReadOnly(item.Recipe.Chunks.ToArray()),
            Words = item.Recipe.Words is null ? null : Array.AsReadOnly(item.Recipe.Words.ToArray()) } }).ToArray();
        var frozenDisclosure = disclosure with { Kinds = Array.AsReadOnly(disclosure.Kinds.ToArray()),
            Intervals = Array.AsReadOnly(disclosure.Intervals.ToArray()) };
        return new(frozenPlan, Array.AsReadOnly(frozenRecipes), frozenDisclosure, snapshot);
    }
    public void Verify(Project project, VoiceLabOutputScope scope, VoiceLabLabelPosition position)
    {
        if (scope != OutputPlan.Scope || position != Disclosure.Position)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
        try
        {
            if (ProjectSerialization.Serialize(project) != projectSnapshot)
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
            var rebuilt = VoiceLabOutputPlanner.Build(project, scope);
            if (rebuilt.OutputSamples != OutputPlan.OutputSamples || rebuilt.SampleRate != OutputPlan.SampleRate ||
                !rebuilt.Pieces.SequenceEqual(OutputPlan.Pieces) || !rebuilt.Captions.SequenceEqual(OutputPlan.Captions))
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
        }
        catch (Exception exception) when (exception is VoiceLabProjectException or VoxClipException)
        {
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.StaleRenderContract);
        }
    }
}
public static class VoiceLabRenderContract
{
    public static VoiceLabPreparedRender Prepare(Project project, VoiceLabOutputScope scope, VoiceLabLabelPosition labelPosition)
    {
        if (!Enum.IsDefined(labelPosition))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidSegment);
        var plan = VoiceLabOutputPlanner.Build(project, scope);
        if (project.SchemaVersion < 3 && plan.RequiresSyntheticRendering)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.NeedsVoiceLabUpgrade);
        if (project.SchemaVersion >= 3 && project.VoiceLab.CleanAudio?.Mode == VoiceLabCleanAudioMode.On)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.CleanAudioUnsupported);
        var selected = SelectedRecipes(project, plan);
        ValidateSelectedSeams(plan, selected.Select(item => new SeamPiece(item.SegmentId, item.Piece, item.Recipe.Seams)).ToArray());
        var disclosure = DeriveDisclosure(project, plan, selected, labelPosition);
        return VoiceLabPreparedRender.Create(plan, selected, disclosure, ProjectSerialization.Serialize(project));
    }
    /// <summary>Geometry-only acceptance preflight before a paid takes quote.</summary>
    public static void ValidatePlacement(Project project, VoiceLabOutputScope scope, VoiceLabWindow window)
    {
        var pendingId = "pending-rewrite";
        while (project.VoiceLab.Segments.Any(item => item.Id == pendingId)) pendingId += "-";
        var plan = VoiceLabOutputPlanner.Build(project, scope, window, pendingId);
        if (project.VoiceLab.CleanAudio?.Mode == VoiceLabCleanAudioMode.On) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.CleanAudioUnsupported);
        var selected = SelectedRecipes(project, plan, pendingId).Select(item => new SeamPiece(item.SegmentId, item.Piece, item.Recipe.Seams)).ToList();
        var piece = plan.Pieces.FirstOrDefault(item => item.SegmentId == pendingId) ?? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
        VoiceLabSeam Seam(VoiceLabSeamPlacement edge) => edge.FadeSamples < 0 ? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidFadeHandles)
            : new(edge.Kind, edge.FadeSamples, 0, 0);
        selected.Add(new(pendingId, piece, new(Seam(window.LeftSeam), Seam(window.RightSeam))));
        ValidateSelectedSeams(plan, selected);
    }
    static List<VoiceLabSelectedRecipe> SelectedRecipes(Project project, VoiceLabOutputPlan plan, string? excluding = null)
    {
        var selected = new List<VoiceLabSelectedRecipe>();
        for (var index = 0; index < plan.Pieces.Count; index++)
        {
            var piece = plan.Pieces[index];
            if (piece.Kind != VoiceLabOutputPieceKind.Synth || piece.SegmentId == excluding) continue;
            var segment = project.VoiceLab.Segments.First(s => s.Id == piece.SegmentId);
            var recipe = segment.Candidates[segment.SelectedCandidateIndex].Recipe ?? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.MissingRenderPolicy);
            var provenance = recipe.Provenance;
            var timestampedSpeech = provenance.Endpoint.StartsWith("v1/text-to-speech/", StringComparison.Ordinal) &&
                provenance.Endpoint.EndsWith("/with-timestamps", StringComparison.Ordinal) && provenance.Model != "eleven_v4";
            var timestampedDialogue = provenance.Endpoint == "v1/text-to-dialogue/with-timestamps" && provenance.Model == "eleven_v4";
            if (segment.Kind == VoiceLabSegmentKind.Tts && !timestampedSpeech && !timestampedDialogue)
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.EndpointUnsupported);
            if (segment.Kind == VoiceLabSegmentKind.Recorded && !VoiceLabRecordedTake.IsRecorded(provenance))
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.EndpointUnsupported);
            var sourceSamples = piece.SourceEndSample - piece.SourceStartSample;
            var outputSamples = piece.OutputEndSample - piece.OutputStartSample;
            var video = recipe.Video;
            if (video.Mode == VoiceLabVideoMode.Retimed || (video.Mode == VoiceLabVideoMode.Source && sourceSamples != outputSamples) ||
                (video.Mode == VoiceLabVideoMode.Cut && (recipe.Audio.Stretch != 1 || !VoiceLabNaturalPacing.ValidCuts(video, plan.SampleRate))) ||
                (video.Mode == VoiceLabVideoMode.ZoomCover && (sourceSamples <= 0 || outputSamples <= 0 || recipe.Audio.Stretch != 1 ||
                    video.SourceStartSample != piece.SourceStartSample || video.SourceEndSample != piece.SourceEndSample ||
                    video.OutputSamples != outputSamples || video.RetimeFactor is not { } factor || !double.IsFinite(factor) ||
                    factor is not (>= VoiceLabVideoDurationOptions.MinimumRetime and <= VoiceLabVideoDurationOptions.MaximumRetime) ||
                    Math.Abs(factor - (double)sourceSamples / outputSamples) > 1e-6)))
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.VideoModeUnsupported);
            var asset = project.VoiceLab.Assets!.First(a => a.Id == recipe.Audio.AssetId);
            if (asset.File.EndsWith(".flac", StringComparison.Ordinal)) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.UnsupportedAssetFormat);
            selected.Add(new(segment.Id, piece, recipe));
        }
        return selected;
    }
    private sealed record SeamPiece(string SegmentId, VoiceLabOutputPiece Piece, VoiceLabSeams Seams);
    static void ValidateSelectedSeams(VoiceLabOutputPlan plan, IReadOnlyList<SeamPiece> selected)
    {
        var windows = new List<(long start, long end)>();
        static void Fail(VoiceLabProjectErrorCode code) => throw new VoiceLabProjectException(code);
        foreach (var item in selected)
        {
            var index = -1;
            for (var i = 0; i < plan.Pieces.Count; i++) if (plan.Pieces[i].SegmentId == item.SegmentId) { index = i; break; }
            if (index < 0) Fail(VoiceLabProjectErrorCode.StaleRenderContract);
            var piece = item.Piece;
            var before = index > 0 ? plan.Pieces[index-1] : null;
            var after = index+1 < plan.Pieces.Count ? plan.Pieces[index+1] : null;
            var incoming = item.Seams.In; var outgoing = item.Seams.Out;
            if (before is null)
            {
                if (incoming.Kind != VoiceLabSeamKind.None) Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
            }
            else if (before.Kind == VoiceLabOutputPieceKind.Synth)
            {
                var prior = selected.FirstOrDefault(s => s.SegmentId == before.SegmentId)?.Seams;
                if (before.SourceEndSample != piece.SourceStartSample || incoming.Kind != VoiceLabSeamKind.SynthToSynth ||
                    prior?.Out.Kind != VoiceLabSeamKind.SynthToSynth || prior.Out.FadeSamples != incoming.FadeSamples)
                    Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
            }
            else if (incoming.Kind is VoiceLabSeamKind.None or VoiceLabSeamKind.SynthToSynth) Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
            if (after is null)
            {
                if (outgoing.Kind != VoiceLabSeamKind.None) Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
            }
            else if (after.Kind == VoiceLabOutputPieceKind.Synth)
            {
                var next = selected.FirstOrDefault(s => s.SegmentId == after.SegmentId)?.Seams;
                if (piece.SourceEndSample != after.SourceStartSample || outgoing.Kind != VoiceLabSeamKind.SynthToSynth ||
                    next?.In.Kind != VoiceLabSeamKind.SynthToSynth || next.In.FadeSamples != outgoing.FadeSamples)
                    Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
            }
            else if (outgoing.Kind is VoiceLabSeamKind.None or VoiceLabSeamKind.SynthToSynth) Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
            void Add(VoiceLabSeam seam, long center, bool isIncoming)
            {
                if (seam.Kind == VoiceLabSeamKind.None) return;
                var source = isIncoming ? before : after;
                var available = source is null ? (long?)null : source.OutputEndSample - source.OutputStartSample;
                var (left, right) = VoiceLabHardJoin.FadeExtent(seam, isIncoming, plan.SampleRate, available);
                if (seam.MicroPause is not null && left + right < (long)Math.Ceiling(0.002 * plan.SampleRate)) Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
                if (center < left || right > plan.OutputSamples-center) Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
                windows.Add((center-left,center+right));
            }
            Add(incoming,piece.OutputStartSample, true);
            if (after?.Kind != VoiceLabOutputPieceKind.Synth) Add(outgoing,piece.OutputEndSample, false);
        }
        windows.Sort((a,b) => a.start.CompareTo(b.start));
        for (var i = 1; i < windows.Count; i++)
            if (windows[i].start < windows[i-1].end) Fail(VoiceLabProjectErrorCode.OverlappingFades);
        foreach (var item in selected)
        {
            var index = -1;
            for (var i = 0; i < plan.Pieces.Count; i++) if (plan.Pieces[i].SegmentId == item.SegmentId) { index = i; break; }
            var piece = item.Piece;
            var before = index > 0 ? plan.Pieces[index-1] : null;
            var after = index+1 < plan.Pieces.Count ? plan.Pieces[index+1] : null;
            var incoming = item.Seams.In; var outgoing = item.Seams.Out;
            if (incoming.Kind != VoiceLabSeamKind.None)
            {
                var (left, right) = VoiceLabHardJoin.FadeExtent(incoming, true, plan.SampleRate, before!.OutputEndSample - before.OutputStartSample);
                if (before!.OutputEndSample-before.OutputStartSample < left || piece.OutputEndSample-piece.OutputStartSample < right)
                    Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
            }
            if (outgoing.Kind != VoiceLabSeamKind.None)
            {
                var (left, right) = VoiceLabHardJoin.FadeExtent(outgoing, false, plan.SampleRate, after!.OutputEndSample - after.OutputStartSample);
                if (piece.OutputEndSample-piece.OutputStartSample < left || after!.OutputEndSample-after.OutputStartSample < right)
                    Fail(VoiceLabProjectErrorCode.InvalidFadeHandles);
            }
        }
    }
    static VoiceLabDisclosurePlan DeriveDisclosure(Project project, VoiceLabOutputPlan plan, IReadOnlyList<VoiceLabSelectedRecipe> all, VoiceLabLabelPosition position)
    {
        // The user's own microphone take is real speech, not AI: only its lip sync, if any, is disclosed (Mac deriveDisclosure).
        var selected = all.Where(item => item.Recipe.Video.Mode == VoiceLabVideoMode.Lipsync ||
            project.VoiceLab.Segments.First(s => s.Id == item.SegmentId).Kind != VoiceLabSegmentKind.Recorded).ToArray();
        var required = selected.Length > 0;
        var kinds = selected.SelectMany(item =>
        {
            var kind = project.VoiceLab.Segments.First(s => s.Id == item.SegmentId).Kind;
            if (kind == VoiceLabSegmentKind.Recorded) return new[] { "lipsync" };
            var wire = VoiceLabRecordedTake.WireKind(kind);
            return item.Recipe.Video.Mode == VoiceLabVideoMode.Lipsync ? new[] { wire, "lipsync" } : new[] { wire };
        }).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
        var aiSeconds = selected.Sum(item => item.Piece.OutputEndSample-item.Piece.OutputStartSample) / plan.SampleRate;
        var voiceSeconds = selected.Where(item => project.VoiceLab.Segments.First(s => s.Id == item.SegmentId).Kind == VoiceLabSegmentKind.VoiceChanger)
            .Sum(item => item.Piece.OutputEndSample-item.Piece.OutputStartSample) / plan.SampleRate;
        var persistent = required && (voiceSeconds >= plan.Duration * .5 || aiSeconds > plan.Duration * .3);
        var intervals = new List<VoiceLabLabelInterval>();
        if (required)
        {
            if (persistent) intervals.Add(new(0, plan.Duration));
            else
            {
                intervals.Add(new(0, Math.Min(3, plan.Duration)));
                intervals.AddRange(selected.Select(item => new VoiceLabLabelInterval(Math.Max(0,item.Piece.OutputStartSample/plan.SampleRate-.5),
                    Math.Min(plan.Duration,item.Piece.OutputEndSample/plan.SampleRate+.5))));
                var merged = new List<VoiceLabLabelInterval>();
                foreach (var interval in intervals.OrderBy(i => i.Start))
                {
                    if (merged.Count > 0 && interval.Start-merged[^1].End < 1)
                        merged[^1] = merged[^1] with { End = Math.Max(merged[^1].End, interval.End) };
                    else merged.Add(interval);
                }
                intervals = merged;
            }
        }
        var et = string.Equals(project.Transcript?.Language?.Split('-')[0], "et", StringComparison.OrdinalIgnoreCase);
        var lines = new List<string>();
        if (kinds.Contains("tts")) lines.Add(et ? "Mõned sõnad selles videos on loetud minu enda hääle tehisintellekti-koopiaga." : "Some words in this video were re-voiced with an AI copy of my own voice.");
        if (kinds.Contains("voiceChanger"))
        {
            var own = selected.Any(item => item.Recipe.VoiceSource == VoiceLabVoiceSource.Own &&
                project.VoiceLab.Segments.First(s => s.Id == item.SegmentId).Kind == VoiceLabSegmentKind.VoiceChanger);
            lines.Add(et ? own ? "Selle video hääl on tehisintellektiga muudetud minu enda hääle koopiaks." : "Selle video häält on muudetud tehisintellektiga." :
                own ? "The voice in this video was converted with AI into a copy of my own voice." : "The voice in this video was changed with AI.");
        }
        if (kinds.Contains("lipsync")) lines.Add(et ? "Osa huulte liikumisest on loodud tehisintellektiga." : "Lip movements in parts of it were generated with AI.");
        return new(required, kinds, aiSeconds, persistent, intervals, .15, position, lines.Count == 0 ? null : string.Join(" ", lines));
    }
}
