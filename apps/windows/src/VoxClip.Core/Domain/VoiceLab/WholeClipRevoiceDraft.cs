using System.Security.Cryptography;
using System.Text;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public sealed record WholeClipLipSync(LipsyncRenderWindow Window, VoiceLabVideoAsset Asset, string RequestId);
public sealed record WholeClipRevoicePlan(WholeClipScript Script, IReadOnlyList<PlacedOrRefused.Placed> Parts, IReadOnlyList<LipsyncWindow> Windows,
    VoiceLabOutputPlan Original)
{
    public static WholeClipRevoicePlan Create(Project project, string clipId, AudioEnvelope envelope, IReadOnlyList<VoiceLabDiffHunk> changes)
    {
        var transcript = project.Transcript?.Words ?? throw LipsyncWindow.Invalid();
        var scope = WholeClipRevoice.OutputScope(clipId);
        var first = 0;
        var last = transcript.Count - 1;
        if (scope.ClipId is { } id)
        {
            var clip = project.Edits.Clips.Single(item => item.Id == id);
            first = transcript.ToList().FindIndex(word => word.Id == clip.StartWordId);
            last = transcript.ToList().FindIndex(word => word.Id == clip.EndWordId);
        }
        if (first < 0 || last < first) throw LipsyncWindow.Invalid();
        var words = transcript.Skip(first).Take(last - first + 1).Select(word => word with
            { Text = project.Edits.Corrections.GetValueOrDefault(word.Id, word.Text) }).ToArray();
        var cuts = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var script = WholeClipScript.Assemble(words, cuts, changes) ?? throw LipsyncWindow.Invalid();
        var clean = WithoutPrevious(project, clipId);
        var original = VoiceLabOutputPlanner.Build(clean, scope);
        var placement = VoiceLabWindowPlanner.PlaceAll(clean, scope, envelope,
            script.Hunks(words, cuts, project.Edits.CutPauseIds.ToHashSet(StringComparer.Ordinal)));
        if (placement.Count is < 1 or > VoiceLabTakeBatch.MaximumRunPhrases || placement.Any(part => part is not PlacedOrRefused.Placed) ||
            script.Characters > WholeClipRevoice.MaximumScriptScalars) throw LipsyncWindow.Invalid();
        var parts = placement.Cast<PlacedOrRefused.Placed>().ToArray();
        var rate = checked((int)original.SampleRate);
        var windows = LipsyncWindow.Merge(parts.Select((part, index) => LipsyncRenderWindow.Project(LipsyncWindow.Make(part.Window.StartSample,
            part.Window.EndSample, original.TotalSourceSamples, rate, index), original).Source), rate);
        return new(script, parts, windows, original);
    }

    public static Project WithoutPrevious(Project project, string clipId)
    {
        var previous = project.VoiceLab.WholeClipRevoices?.Where(record => record.ClipId == clipId).SelectMany(record => record.SegmentIds)
            .ToHashSet(StringComparer.Ordinal);
        if (previous is not { Count: > 0 }) return project;
        var kept = project.VoiceLab.WholeClipRevoices!.Where(record => record.ClipId != clipId).ToArray();
        return project with { VoiceLab = project.VoiceLab with {
            Segments = project.VoiceLab.Segments.Where(segment => !previous.Contains(segment.Id)).ToArray(),
            WholeClipRevoices = kept.Length == 0 ? null : kept,
        } };
    }

    public string Identity(string recordId, string contentKey, string modelId, double pauseThreshold)
    {
        var source = FormattableString.Invariant($"whole-clip/1\n{contentKey}\n{recordId}\n{modelId}\n{Original.Scope.ClipId}\n{Original.SampleRate:R}\n{pauseThreshold:R}\n{Script.Text}\n");
        var geometry = string.Join(';', Original.Pieces.Select(piece => FormattableString.Invariant(
            $"{piece.SourceStartSample},{piece.SourceEndSample},{piece.OutputStartSample},{piece.OutputEndSample},{piece.Audio?.AssetId}")));
        var parts = string.Join(';', Parts.Select(part => FormattableString.Invariant(
            $"{part.Window.StartSample},{part.Window.EndSample},{part.Window.LeftSeam.Kind},{part.Window.LeftSeam.FadeSamples},{part.Window.RightSeam.Kind},{part.Window.RightSeam.FadeSamples}")));
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(source + geometry + "\n" + parts)));
    }
}

public static class WholeClipRevoiceDraft
{
    public static Project Voice(Project current, string clipId, VoiceLabEditCommand.AcceptAll voice) =>
        voice.ApplyingTo(WholeClipRevoicePlan.WithoutPrevious(current, clipId), WholeClipRevoice.OutputScope(clipId));

    public static VoiceLabEditCommand.AcceptWholeClip WithPicture(VoiceLabEditCommand.AcceptAll voice, WholeClipRevoiceRecord record,
        IReadOnlyList<VoiceLabSelectedRecipe> recipes, IReadOnlyList<WholeClipLipSync> results)
    {
        if (recipes.Count != voice.Segments.Count || results.SelectMany(result => result.Window.Source.PhraseIds).Order().SequenceEqual(
            Enumerable.Range(0, recipes.Count)) == false) throw LipsyncWindow.Invalid();
        var updated = voice.Segments.ToDictionary(segment => segment.Id, StringComparer.Ordinal);
        foreach (var result in results)
        foreach (var index in result.Window.Source.PhraseIds)
        {
            var selected = recipes[index];
            var segment = updated[selected.SegmentId];
            var picture = selected.Recipe.Video with { Mode = VoiceLabVideoMode.Lipsync, AssetId = result.Asset.Id, Provider = "fal",
                Model = record.LipsyncModel, RequestId = result.RequestId, WindowStartSample = result.Window.Source.StartSample,
                WindowEndSample = result.Window.Source.EndSample, SyncMode = result.Window.Mode == SyncMode.Remap ? "remap" : "cut_off" };
            var candidate = segment.Candidates[segment.SelectedCandidateIndex] with { Recipe = selected.Recipe with { Video = picture } };
            updated[segment.Id] = segment with { Candidates = [.. segment.Candidates, candidate], SelectedCandidateIndex = segment.Candidates.Count };
        }
        return new(voice with { Segments = voice.Segments.Select(segment => updated[segment.Id]).ToArray() }, results.Select(result => result.Asset).ToArray(), record);
    }
}
