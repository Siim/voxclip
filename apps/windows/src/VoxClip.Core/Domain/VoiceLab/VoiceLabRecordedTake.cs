using VoxClip.Core.Domain.Editing;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>A word the user said in their own microphone take, timed from the start of the recording (on-device recognition).</summary>
public sealed record VoiceLabSpokenWord(string Text, double Start, double End);

/// <summary>The user's own microphone take of a Rewrite phrase (voice-lab.md §8.13; Mac <c>VoiceLabRecordedTake</c>). It is
/// real speech in the user's own live voice, so it needs no clone and no voice consent: its recipe names no voice reference
/// and no consent record, its provenance says it was recorded on this device, and it costs nothing. Its words are what
/// on-device recognition heard, never synthetic. It is stored as a <c>recorded</c> segment and rendered like any other
/// accepted take; only its lip sync, if the user chose one, is disclosed as AI.</summary>
public static class VoiceLabRecordedTake
{
    public const string Provider = "microphone";
    public const string Endpoint = "local";
    public const string VoiceId = "own-microphone";
    public const string Region = "local";

    public static bool IsRecorded(VoiceLabProvenance provenance) => provenance.Provider == Provider && provenance.Endpoint == Endpoint &&
        provenance.VoiceId == VoiceId && provenance.ConsentRecordId is null && provenance.Region == Region && provenance.Pace is null;

    /// <summary>The segment kind as the project and the provenance sidecar write it.</summary>
    public static string WireKind(VoiceLabSegmentKind kind) => kind switch
    {
        VoiceLabSegmentKind.Tts => "tts",
        VoiceLabSegmentKind.VoiceChanger => "voiceChanger",
        VoiceLabSegmentKind.Recorded => "recorded",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };

    /// <summary>The recognized words as the character timing a provider's alignment has: each word's characters share its
    /// span evenly and one space joins two words, so the fit planner reads a recording as it reads a generated take.</summary>
    public static IReadOnlyList<VoiceLabCharacterTiming> Alignment(IReadOnlyList<VoiceLabSpokenWord> words)
    {
        var timing = new List<VoiceLabCharacterTiming>();
        for (var index = 0; index < words.Count; index++)
        {
            var word = words[index];
            // Swift Characters are grapheme clusters, so one timing per text element, as Mac Array(word.text).
            var characters = new List<string>();
            var elements = System.Globalization.StringInfo.GetTextElementEnumerator(word.Text);
            while (elements.MoveNext()) characters.Add(elements.GetTextElement());
            if (characters.Count == 0 || !(word.End > word.Start)) continue;
            if (index > 0 && timing.Count > 0)
            {
                var last = timing[^1];
                timing.Add(new(" ", last.End, Math.Max(last.End, word.Start)));
            }
            var step = (word.End - word.Start) / characters.Count;
            for (var offset = 0; offset < characters.Count; offset++)
                timing.Add(new(characters[offset], word.Start + step * offset,
                    offset == characters.Count - 1 ? word.End : word.Start + step * (offset + 1)));
        }
        return timing.AsReadOnly();
    }

    /// <summary>The take's accepted candidate. <paramref name="model"/> names the on-device recognizer that heard its words.
    /// The take was never sent anywhere: it has no receipt, quote or generated reply, and no speaker score
    /// (<see cref="VoiceLabTakeQaResult.SpeakerUnmeasured"/>).</summary>
    public static VoiceLabCandidate Candidate(VoiceLabTakeRow row, VoiceLabTakeInput input, VoiceLabPublishedTake published,
        string model, DateTimeOffset createdAt, VoiceLabVideoMode? videoChoice = null, VoiceLabZoomCover? face = null)
    {
        var asset = published.Assets.FirstOrDefault(item => item.Id == published.Audio.AssetId);
        if (!row.Selectable || row.RequiresJoinAdvisoryAcceptance || row.Receipt is not null || row.Quote is not null || row.Generated is not null ||
            row.Audio is not { } take || row.Qa is not { Verdict: not VoiceLabTakeQaVerdict.Failed } qa ||
            qa.LufsJumpLu is not { } jump || qa.PeakDbfs is not { } peak || qa.TranscriptMatch is not { } match || qa.SpeakerScore is not null ||
            string.IsNullOrEmpty(model) || !published.Words.SequenceEqual(take.Fit.Plan.Words) || published.Audio.Stretch != 1 ||
            !double.IsFinite(published.OutDuration) || published.OutDuration <= 0 || asset is null)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.QaRejected);
        if (row.AcceptedJoinAdvisory is { } accepted && (!accepted.Seams.SequenceEqual(qa.JoinSeams) || !accepted.Validates(jump, createdAt)))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.QaRejected);
        var tokens = VoiceLabTakeQuality.Tokens(input.Text).Length;
        var checkedQa = new VoiceLabRenderQa(tokens, tokens <= 5 ? match == 1 : null, match, jump, peak, null, null, null, null,
            JoinAdvisory: row.AcceptedJoinAdvisory);
        var request = row.Id.ToString("D");
        var provenance = new VoiceLabProvenance(Provider, Endpoint, model, VoiceId, null, request, row.Seed, createdAt) { Region = Region };
        var words = published.Words.Select(word => word with { Synthetic = false }).ToArray();
        return VoiceLabRecipeBuilder.Assemble(row, take, input, published, asset, videoChoice, face, words, checkedQa, provenance,
            new(request, 0), null, null);
    }

    public static VoiceLabSegment Segment(string id, VoiceLabCandidate candidate, VoiceLabTakeInput input, VoiceLabFitPlan plan)
        => VoiceLabRecipeBuilder.Segment(id, [candidate], 0, input, plan, VoiceLabSegmentKind.Recorded);

    /// <summary>The v3 rules a recorded recipe keeps beyond every recipe's (<see cref="VoiceLabRenderValidation"/>): recorded
    /// provenance, no voice reference or consent, no speaker score, free, and recognized words that pass the word check.</summary>
    internal static void Validate(VoiceLabRenderRecipe recipe, double rate, long output)
    {
        var qa = recipe.Qa;
        if (!IsRecorded(recipe.Provenance) || recipe.VoiceSource != VoiceLabVoiceSource.Own || recipe.VoiceRefId is not null ||
            recipe.ConsentVerifiedAt is not null || qa.ShortSpeech is not null || qa.SpeakerScore is not null || qa.SpeakerPassed is not null ||
            recipe.Cost.Usd != 0)
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidSegment);
        if (recipe.Words is not { Count: > 0 } words) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.AlignmentUnavailable);
        long Samples(double seconds) => (long)EditingMath.Round(seconds * rate);
        var cursor = 0.0;
        foreach (var word in words)
        {
            if (string.IsNullOrEmpty(word.Text) || word.Synthetic || !double.IsFinite(word.Start) || !double.IsFinite(word.End) ||
                word.Start < cursor || !(word.End > word.Start) || word.End > recipe.OutDuration ||
                Samples(word.End) <= Samples(word.Start) || Samples(word.End) > output)
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.AlignmentUnavailable);
            cursor = word.End;
        }
        if (qa.TranscriptTokens is not { } count || count <= 0 || qa.TranscriptMatch is not { } match || !double.IsFinite(match) ||
            match is < 0 or > 1 || !(count <= 5 ? qa.TranscriptExact == true : match >= 0.9))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.QaRejected);
    }

    /// <summary>Its speech is generated: every segment but the user's own recorded take.</summary>
    public static bool HasAISpeech(this VoiceLabSegment segment) => segment.Kind != VoiceLabSegmentKind.Recorded;

    /// <summary>It changes the video with AI: generated speech, or lip sync on the user's own take (the export label's rule).</summary>
    public static bool IsAIModified(this VoiceLabSegment segment) => segment.HasAISpeech() ||
        segment.SelectedCandidateIndex >= 0 && segment.SelectedCandidateIndex < segment.Candidates.Count &&
        segment.Candidates[segment.SelectedCandidateIndex].Recipe?.Video.Mode == VoiceLabVideoMode.Lipsync;
}
