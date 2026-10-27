#pragma warning disable CS1591
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

public static class VoiceLabRenderValidation
{
    internal static bool ContentMatchesDuration(VoiceLabAudio audio, double outDuration, int assetSampleRate) =>
        Math.Abs((audio.TrimEnd - audio.TrimStart) * audio.Stretch - outDuration) <= 1.0 / assetSampleRate;

    static void Require(bool condition, VoiceLabProjectErrorCode code) { if (!condition) throw new VoiceLabProjectException(code); }
    static bool Id(string? value) => value is not null && VoiceLabProject.Matches(value, "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}");
    static long Samples(double seconds, double rate) => (long)EditingMath.Round(seconds * rate);
    public static void Validate(Project project)
    {
        var clean = project.VoiceLab.CleanAudio;
        var voices = project.VoiceLab.Voices;
        var videoAssets = project.VoiceLab.VideoAssets;
        Require(clean is not null && voices is not null && videoAssets is not null, VoiceLabProjectErrorCode.MissingRenderPolicy);
        Require(Enum.IsDefined(clean!.Mode), VoiceLabProjectErrorCode.InvalidSegment);
        Require(clean!.Mode == VoiceLabCleanAudioMode.Off ? clean.AssetId is null && clean.Mix is null :
            clean.AssetId is not null && clean.Mix is { } mix && double.IsFinite(mix) && mix is >= 0 and <= 1, VoiceLabProjectErrorCode.MissingRenderPolicy);
        var assets = project.VoiceLab.Assets!;
        if (clean.AssetId is { } cleanAsset) Require(assets.Any(a => a.Id == cleanAsset), VoiceLabProjectErrorCode.DanglingAsset);
        Require(voices!.Select(v => v.Id).Distinct(StringComparer.Ordinal).Count() == voices!.Count, VoiceLabProjectErrorCode.ConsentUnverified);
        foreach (var voice in voices!)
            Require(Enum.IsDefined(voice.Status) && Id(voice.Id) && Id(voice.ConsentRecordId) && voice.Provider.Length > 0 && voice.VoiceId.Length > 0 && voice.DisplayName.Length > 0, VoiceLabProjectErrorCode.ConsentUnverified);
        Require(videoAssets!.Select(v => v.Id).Distinct(StringComparer.Ordinal).Count() == videoAssets!.Count, VoiceLabProjectErrorCode.InvalidAsset);
        foreach (var video in videoAssets!)
            Require(VoiceLabAssetNaming.SafeVideoFile(project.Id, video.Id) == video.File &&
                VoiceLabProject.Matches(video.Sha256, "[0-9a-f]{64}") &&
                double.IsFinite(video.DurationSeconds) && video.DurationSeconds > 0 && double.IsFinite(video.FrameRate) &&
                video.FrameRate > 0 && video.DurationSeconds*video.FrameRate < long.MaxValue && video.Width > 0 && video.Height > 0, VoiceLabProjectErrorCode.InvalidAsset);
        var rate = (double)(project.Media.Source.Audio?.SampleRate ?? 48000);
        var total = Samples(project.Media.Source.DurationSeconds, rate);
        foreach (var segment in project.VoiceLab.Segments)
        {
            Require(Enum.IsDefined(segment.Kind), VoiceLabProjectErrorCode.InvalidSegment);
            // A v3 segment must record its scope (§10.5); only a scope outside the enum is malformed.
            Require(segment.Scope is not null, VoiceLabProjectErrorCode.MissingRenderPolicy);
            Require(segment.Scope is { } scopeValue && Enum.IsDefined(scopeValue), VoiceLabProjectErrorCode.InvalidSegment);
            Require(segment.Scope == VoiceLabSegmentScope.Passage && segment.GroupId is null ||
                segment.Scope == VoiceLabSegmentScope.FullTake && Id(segment.GroupId), VoiceLabProjectErrorCode.MissingRenderPolicy);
            foreach (var candidate in segment.Candidates)
            {
                if (candidate.Rejected is null)
                {
                    var recipe = candidate.Recipe ?? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.MissingRenderPolicy);
                    ValidateRecipe(recipe, segment, project, rate, total);
                    Require(candidate.AssetId == recipe.Audio.AssetId, VoiceLabProjectErrorCode.InvalidCandidate);
                }
                if (candidate.Recipe is { } stored) ValidateShape(stored);
            }
            var chosen = segment.Candidates[segment.SelectedCandidateIndex].Recipe;
            Require(chosen is not null && segment.Audio == chosen.Audio && segment.OutDuration == chosen.OutDuration &&
                (segment.Words is null ? chosen.Words is null : chosen.Words is not null && segment.Words.SequenceEqual(chosen.Words)) &&
                segment.Provenance == chosen.Provenance && segment.Qa == new VoiceLabQa(chosen.Qa.TranscriptMatch, chosen.Qa.LufsJumpLu,
                chosen.Qa.PeakDbfs, chosen.Qa.SpeakerScore), VoiceLabProjectErrorCode.InvalidCandidate);
        }
        foreach (var group in project.VoiceLab.Segments.Where(s => s.GroupId is not null).GroupBy(s => s.GroupId))
        {
            long cursor = 0;
            foreach (var segment in group.OrderBy(s => s.Replace.Start))
            {
                Require(segment.Scope == VoiceLabSegmentScope.FullTake && Samples(segment.Replace.Start, rate) == cursor, VoiceLabProjectErrorCode.InvalidRange);
                cursor = Samples(segment.Replace.End, rate);
            }
            Require(cursor == total, VoiceLabProjectErrorCode.InvalidRange);
        }
    }
    static void ValidateRecipe(VoiceLabRenderRecipe recipe, VoiceLabSegment segment, Project project, double rate, long total)
    {
        var assets = project.VoiceLab.Assets!;
        var asset = assets.FirstOrDefault(a => a.Id == recipe.Audio.AssetId);
        Require(asset is not null, VoiceLabProjectErrorCode.DanglingAsset);
        var start = Samples(segment.Replace.Start, rate); var end = Samples(segment.Replace.End, rate);
        Require(double.IsFinite(recipe.OutDuration) && recipe.OutDuration > 0 && recipe.OutDuration*rate < long.MaxValue &&
            asset!.DurationSeconds*asset.SampleRate < long.MaxValue, VoiceLabProjectErrorCode.InvalidRange);
        var output = Samples(recipe.OutDuration, rate);
        var audio = recipe.Audio;
        Require(output > 0 &&
            double.IsFinite(audio.TrimStart) && double.IsFinite(audio.TrimEnd) && double.IsFinite(audio.GainDb) &&
            audio.TrimStart >= 0 && audio.TrimEnd <= asset!.DurationSeconds && audio.TrimEnd > audio.TrimStart &&
            double.IsFinite(audio.Stretch) && (audio.Stretch == 1 || Math.Abs(audio.Stretch - recipe.OutDuration / (audio.TrimEnd-audio.TrimStart)) <= 1e-6) &&
            (audio.Stretch == 1 || (audio.TrimEnd-audio.TrimStart)/recipe.OutDuration is >= 0.92 and <= 1.08), VoiceLabProjectErrorCode.InvalidRange);
        if (audio.Stretch == 1)
        {
            double assetRate = asset!.SampleRate;
            var contentFrames = Samples(audio.TrimEnd, assetRate) - Samples(audio.TrimStart, assetRate);
            var windowFrames = EditingMath.Round((end - start) * assetRate / rate);
            bool Fits(double windowDuration)
            {
                var residualFrames = EditingMath.Round((recipe.OutDuration - windowDuration) * assetRate);
                var duration = windowDuration + residualFrames / assetRate;
                var tolerance = 4 * Math.Max(Math.BitIncrement(recipe.OutDuration) - recipe.OutDuration,
                    Math.BitIncrement(windowDuration) - windowDuration);
                return contentFrames > 0 && contentFrames == windowFrames + residualFrames &&
                    Math.Abs(recipe.OutDuration - duration) <= tolerance;
            }
            Require(Fits(segment.Replace.End - segment.Replace.Start) ||
                (recipe.OutDuration == output / rate && Fits((end - start) / rate)), VoiceLabProjectErrorCode.InvalidRange);
            Require(ContentMatchesDuration(audio, recipe.OutDuration, asset.SampleRate), VoiceLabProjectErrorCode.InvalidSegment);
        }
        Require(Id(recipe.Cost.QuoteId) && (recipe.Cost.Usd is null || recipe.Cost.Usd is { } usd && double.IsFinite(usd) && usd >= 0) &&
            recipe.Provenance.Region?.Length > 0 &&
            Id(recipe.Provenance.RequestId) && recipe.Provenance.Seed == recipe.Seed, VoiceLabProjectErrorCode.MissingRenderPolicy);
        // Selection copies this provenance into the segment, whose rule refuses an endpoint URL with the same code.
        Require(recipe.Provenance.Endpoint is null || !recipe.Provenance.Endpoint.Contains("://", StringComparison.Ordinal), VoiceLabProjectErrorCode.InvalidSegment);
        Require(recipe.Chunks.Count > 0, VoiceLabProjectErrorCode.MissingRenderPolicy);
        var cursor = start; var assembled = Samples(audio.TrimStart, asset!.SampleRate);
        foreach (var chunk in recipe.Chunks)
        {
            var chunkAsset = assets.FirstOrDefault(a => a.Id == chunk.AssetId);
            Require(chunk.SourceStartSample == cursor && chunk.SourceEndSample > cursor &&
                chunk.AssembledStartFrame == assembled && chunk.AssembledEndFrame > assembled &&
                Id(chunk.RequestId) && chunkAsset is not null && chunk.AssetSha256 == chunkAsset.Sha256, VoiceLabProjectErrorCode.InvalidRange);
            cursor = chunk.SourceEndSample; assembled = chunk.AssembledEndFrame;
        }
        Require(cursor == end && assembled == Samples(audio.TrimEnd, asset.SampleRate), VoiceLabProjectErrorCode.InvalidRange);
        if (recipe.RoomTone is { } tone)
        {
            Require(tone.SourceStartSample >= 0 && tone.SourceEndSample <= total &&
                tone.SourceEndSample-tone.SourceStartSample == Samples(0.5,rate) && double.IsFinite(tone.GainDb), VoiceLabProjectErrorCode.MissingRenderPolicy);
            Require(project.Transcript?.Words.Any(w => Samples(w.Start,rate) < tone.SourceEndSample && Samples(w.End,rate) > tone.SourceStartSample) != true, VoiceLabProjectErrorCode.MissingRenderPolicy);
        }
        if (project.VoiceLab.CleanAudio!.Mode == VoiceLabCleanAudioMode.On) Require(recipe.RoomTone is null, VoiceLabProjectErrorCode.MissingRenderPolicy);
        if (segment.Kind == VoiceLabSegmentKind.Tts && segment.Scope == VoiceLabSegmentScope.Passage && project.VoiceLab.CleanAudio.Mode == VoiceLabCleanAudioMode.Off)
            Require(recipe.RoomTone is not null, VoiceLabProjectErrorCode.MissingRenderPolicy);
        Require(Enum.IsDefined(recipe.Video.Mode) && Enum.IsDefined(recipe.VoiceSource) &&
            Enum.IsDefined(recipe.Seams.In.Kind) && Enum.IsDefined(recipe.Seams.Out.Kind), VoiceLabProjectErrorCode.InvalidSegment);
        ValidateSeam(recipe.Seams.In, start == 0, end-start, asset, audio.TrimStart, audio.Stretch, rate, true);
        ValidateSeam(recipe.Seams.Out, end == total, end-start, asset, audio.TrimEnd, audio.Stretch, rate, false);
        if (recipe.Seams.In.FadeSamples - recipe.Seams.In.FadeSamples/2 + recipe.Seams.Out.FadeSamples/2 > output)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.OverlappingFades);
        var video = recipe.Video;
        Require(video.SourceStartSample == start && video.SourceEndSample == end && video.OutputSamples == output, VoiceLabProjectErrorCode.InvalidRange);
        switch (video.Mode)
        {
            case VoiceLabVideoMode.Source:
                Require(video.RetimeFactor is null && video.Zoom is null && video.FaceX is null && video.FaceY is null &&
                    video.AssetId is null && video.Provider is null && video.Model is null && video.RequestId is null &&
                    video.WindowStartSample is null && video.WindowEndSample is null && video.SyncMode is null, VoiceLabProjectErrorCode.InvalidSegment);
                break;
            case VoiceLabVideoMode.Retimed:
            case VoiceLabVideoMode.ZoomCover:
                Require(video.RetimeFactor is { } factor && double.IsFinite(factor) && factor is >= 0.8 and <= 1.25 &&
                    Math.Abs(factor-(double)(end-start)/output) <= 1e-6, VoiceLabProjectErrorCode.InvalidRange);
                if (video.Mode == VoiceLabVideoMode.ZoomCover)
                    Require(video.Zoom is { } zoom && double.IsFinite(zoom) && zoom is >= 1 and <= 2 &&
                        video.FaceX is { } x && double.IsFinite(x) && x is >= 0 and <= 1 &&
                        video.FaceY is { } y && double.IsFinite(y) && y is >= 0 and <= 1, VoiceLabProjectErrorCode.InvalidRange);
                Require(video.AssetId is null && video.Provider is null && video.Model is null && video.RequestId is null &&
                    video.WindowStartSample is null && video.WindowEndSample is null && video.SyncMode is null &&
                    (video.Mode == VoiceLabVideoMode.ZoomCover || video.Zoom is null && video.FaceX is null && video.FaceY is null), VoiceLabProjectErrorCode.InvalidSegment);
                break;
            case VoiceLabVideoMode.Lipsync:
                Require(video.AssetId is { } id && project.VoiceLab.VideoAssets!.Any(a => a.Id == id && a.DurationSeconds*rate >= output) && video.Provider?.Length > 0 && video.Model?.Length > 0 &&
                    Id(video.RequestId) && video.WindowStartSample is { } first && first >= 0 && first <= start &&
                    video.WindowEndSample is { } last && last >= end && last > first && last <= total && video.SyncMode == "remap" &&
                    video.RetimeFactor is null && video.Zoom is null && video.FaceX is null && video.FaceY is null, VoiceLabProjectErrorCode.MissingRenderPolicy);
                break;
            default: throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidSegment);
        }
        var qa = recipe.Qa;
        Require(double.IsFinite(qa.LufsJumpLu) && Math.Abs(qa.LufsJumpLu) <= 2 && double.IsFinite(qa.PeakDbfs) && qa.PeakDbfs < 0, VoiceLabProjectErrorCode.QaRejected);
        if (segment.Kind == VoiceLabSegmentKind.Tts)
        {
            Require(recipe.VoiceSource == VoiceLabVoiceSource.Own, VoiceLabProjectErrorCode.ConsentUnverified);
            Require(recipe.Words is { Count: > 0 }, VoiceLabProjectErrorCode.AlignmentUnavailable);
            double wordCursor = 0;
            foreach (var word in recipe.Words!)
            {
                Require(!string.IsNullOrEmpty(word.Text) && word.Synthetic && double.IsFinite(word.Start) && double.IsFinite(word.End) &&
                    word.Start >= wordCursor && word.End > word.Start && word.End <= recipe.OutDuration &&
                    Samples(word.End, rate) > Samples(word.Start, rate) && Samples(word.End, rate) <= output, VoiceLabProjectErrorCode.AlignmentUnavailable);
                wordCursor = word.End;
            }
            Require(qa.TranscriptTokens is { } count && count > 0 && qa.TranscriptMatch is { } match && double.IsFinite(match) && match is >= 0 and <= 1 &&
                (count <= 5 ? qa.TranscriptExact == true : match >= 0.9), VoiceLabProjectErrorCode.QaRejected);
        }
        else Require(recipe.Words is null, VoiceLabProjectErrorCode.InvalidWords);
        if (recipe.VoiceSource == VoiceLabVoiceSource.Own)
        {
            var voice = project.VoiceLab.Voices!.FirstOrDefault(v => v.Id == recipe.VoiceRefId);
            Require(voice is not null && recipe.Provenance.ConsentRecordId == voice.ConsentRecordId &&
                recipe.Provenance.VoiceId == voice.VoiceId && recipe.Provenance.Provider == voice.Provider &&
                recipe.ConsentVerifiedAt is { } verified && verified <= recipe.Provenance.CreatedAt, VoiceLabProjectErrorCode.ConsentUnverified);
            if (segment.Kind == VoiceLabSegmentKind.Tts)
                Require(qa.SpeakerScore is { } score && qa.SpeakerThreshold is { } threshold &&
                    double.IsFinite(score) && double.IsFinite(threshold) && score is >= 0 and <= 1 && threshold is >= 0 and <= 1 &&
                    qa.SpeakerModel?.Length > 0 && qa.SpeakerPassed == true && score >= threshold, VoiceLabProjectErrorCode.QaRejected);
        }
        else Require(recipe.VoiceRefId is null && recipe.ConsentVerifiedAt is null && recipe.Provenance.ConsentRecordId is null, VoiceLabProjectErrorCode.InvalidSegment);
    }
    /// <summary>The project.schema.json shape of every stored recipe, rejected or not, whatever its kind or voice source.
    /// Render policy runs first for unrejected candidates, so this only reports what policy leaves unchecked.</summary>
    static void ValidateShape(VoiceLabRenderRecipe recipe)
    {
        static bool Unit(double? value) => value is not { } number || double.IsFinite(number) && number is >= 0 and <= 1;
        static bool Finite(double? value) => value is not { } number || double.IsFinite(number);
        var audio = recipe.Audio; var video = recipe.Video; var qa = recipe.Qa; var provenance = recipe.Provenance;
        Require(Id(audio.AssetId) && double.IsFinite(audio.TrimStart) && audio.TrimStart >= 0 && double.IsFinite(audio.TrimEnd) && audio.TrimEnd >= 0 &&
            double.IsFinite(audio.Stretch) && audio.Stretch > 0 && double.IsFinite(audio.GainDb) && double.IsFinite(recipe.OutDuration) && recipe.OutDuration > 0 &&
            (recipe.RoomTone is not { } tone || tone.SourceStartSample >= 0 && tone.SourceEndSample >= 0 && double.IsFinite(tone.GainDb)), VoiceLabProjectErrorCode.InvalidSegment);
        Require(recipe.Words is null || recipe.Words.Count > 0 && recipe.Words.All(word => !string.IsNullOrEmpty(word.Text) &&
            double.IsFinite(word.Start) && word.Start >= 0 && double.IsFinite(word.End) && word.End >= 0), VoiceLabProjectErrorCode.InvalidSegment);
        Require(recipe.Chunks is { Count: > 0 } && recipe.Chunks.All(chunk => chunk.SourceStartSample >= 0 && chunk.SourceEndSample >= 0 &&
            Id(chunk.RequestId) && Id(chunk.AssetId) && chunk.AssetSha256 is not null && VoiceLabProject.Matches(chunk.AssetSha256, "[0-9a-f]{64}") &&
            chunk.AssembledStartFrame >= 0 && chunk.AssembledEndFrame >= 0), VoiceLabProjectErrorCode.InvalidSegment);
        Require(new[] { recipe.Seams.In, recipe.Seams.Out }.All(seam => Enum.IsDefined(seam.Kind) && seam.FadeSamples >= 0 &&
            seam.SourceHandleSamples >= 0 && seam.AssetHandleFrames >= 0), VoiceLabProjectErrorCode.InvalidSegment);
        Require(Enum.IsDefined(video.Mode) && video.SourceStartSample >= 0 && video.SourceEndSample >= 0 && video.OutputSamples >= 0 &&
            Finite(video.RetimeFactor) && Finite(video.Zoom) && Unit(video.FaceX) && Unit(video.FaceY) && (video.AssetId is null || Id(video.AssetId)) &&
            video.Provider is null or { Length: > 0 } && video.Model is null or { Length: > 0 } && (video.RequestId is null || Id(video.RequestId)) &&
            video.WindowStartSample is null or >= 0 && video.WindowEndSample is null or >= 0 && video.SyncMode is null or "remap", VoiceLabProjectErrorCode.InvalidSegment);
        Require(qa.TranscriptTokens is null or >= 0 && Unit(qa.TranscriptMatch) && double.IsFinite(qa.LufsJumpLu) && double.IsFinite(qa.PeakDbfs) &&
            Unit(qa.SpeakerScore) && Unit(qa.SpeakerThreshold) && qa.SpeakerModel is null or { Length: > 0 }, VoiceLabProjectErrorCode.InvalidSegment);
        Require(provenance.Provider is not null && VoiceLabProject.Matches(provenance.Provider, "[a-z0-9-]+") &&
            !string.IsNullOrEmpty(provenance.Endpoint) && !string.IsNullOrEmpty(provenance.Model) && !string.IsNullOrEmpty(provenance.VoiceId) &&
            (provenance.ConsentRecordId is null || Id(provenance.ConsentRecordId)) && (provenance.RequestId is null || Id(provenance.RequestId)) &&
            provenance.Region is { Length: > 0 } && Id(recipe.Cost.QuoteId) && (recipe.Cost.Usd is not { } usd || double.IsFinite(usd) && usd >= 0) &&
            Enum.IsDefined(recipe.VoiceSource) && (recipe.VoiceRefId is null || Id(recipe.VoiceRefId)), VoiceLabProjectErrorCode.InvalidSegment);
    }
    static void ValidateSeam(VoiceLabSeam seam, bool edge, long sourceAvailable, VoiceLabAsset asset, double trim, double stretch, double rate, bool incoming)
    {
        if (edge)
        {
            Require(seam.Kind == VoiceLabSeamKind.None && seam.FadeSamples == 0 && seam.SourceHandleSamples == 0 && seam.AssetHandleFrames == 0, VoiceLabProjectErrorCode.InvalidFadeHandles);
            return;
        }
        Require(seam.Kind is VoiceLabSeamKind.Gap or VoiceLabSeamKind.Hard or VoiceLabSeamKind.SynthToSynth, VoiceLabProjectErrorCode.MissingRenderPolicy);
        var expected = Samples(seam.Kind == VoiceLabSeamKind.Hard ? .012 : .020, rate);
        Require(seam.FadeSamples == expected && seam.FadeSamples >= 2, VoiceLabProjectErrorCode.InvalidFadeHandles);
        var needed = incoming ? seam.FadeSamples/2 : seam.FadeSamples-seam.FadeSamples/2;
        var rawFrames = needed*asset.SampleRate/(rate*stretch);
        var nearest = Math.Round(rawFrames);
        // Persisted stretch ratios can put an integral frame one ULP above its exact value.
        var neededAsset = (long)(Math.Abs(rawFrames-nearest) <= 4*(Math.BitIncrement(rawFrames)-rawFrames) ? nearest : Math.Ceiling(rawFrames));
        var available = incoming ? Samples(trim, asset.SampleRate) : Samples(asset.DurationSeconds-trim, asset.SampleRate);
        Require(seam.AssetHandleFrames >= neededAsset && seam.AssetHandleFrames <= available, VoiceLabProjectErrorCode.InvalidFadeHandles);
        if (seam.Kind == VoiceLabSeamKind.SynthToSynth) Require(seam.SourceHandleSamples == 0, VoiceLabProjectErrorCode.InvalidFadeHandles);
        else Require(seam.SourceHandleSamples >= seam.FadeSamples-needed && seam.SourceHandleSamples <= sourceAvailable, VoiceLabProjectErrorCode.InvalidFadeHandles);
    }
}
