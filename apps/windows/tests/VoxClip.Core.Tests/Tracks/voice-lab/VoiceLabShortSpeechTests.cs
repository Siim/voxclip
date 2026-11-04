using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>ADR-R37 take rules in Windows Core (Mac <c>VoiceLabTakeVoiceCheck</c>, <c>checkingVoice</c>): a waiting short take
/// can't be chosen; an unmeasured one carries no score and passes only as unmeasured; a pooled mismatch adds the speaker failure
/// beside a words failure; the evidence saves exactly its five fields.</summary>
public sealed class VoiceLabShortSpeechTests
{
    private static readonly VoiceLabShortSpeechEvidence Unmeasured = new(VoiceLabShortSpeechMode.Unmeasured, "record", VoiceConsentMethod.RecordedStatement, 20000, 1);
    private static readonly VoiceLabShortSpeechEvidence Pooled = new(VoiceLabShortSpeechMode.Pooled, "record", VoiceConsentMethod.ProjectAttestation, 52000, 3);
    private static VoiceLabTakeRow Waiting(params VoiceLabTakeQaFailure[] failures) =>
        new(Guid.NewGuid(), 0, 1, Qa: new(1, 0, -3, null, failures)) { VoiceCheck = VoiceLabTakeVoiceCheck.Waiting };

    [Fact]
    public void AWaitingTakeCantBeChosenAndReadsAsWaiting()
    {
        var row = Waiting();
        Assert.False(row.VoiceCheck.Complete);
        Assert.Equal(VoiceLabTakeQaVerdict.Failed, row.Qa!.Verdict);
        Assert.Equal("waiting for the voice check", row.ShortPhraseCopy);
        Assert.Null(new VoiceLabTakeRow(Guid.NewGuid(), 0, 1).ShortPhraseCopy);
    }

    [Fact]
    public void AnUnmeasuredTakePassesWithNoScoreAndNeverWithAnInventedOne()
    {
        var row = Waiting().CheckingVoice(VoiceLabTakeVoiceCheck.ShortSpeech(Unmeasured));
        Assert.True(row.VoiceCheck.Complete);
        Assert.Null(row.Qa!.SpeakerScore);
        Assert.True(row.Qa.SpeakerUnmeasured);
        Assert.Equal(VoiceLabTakeQaVerdict.Passed, row.Qa.Verdict);
        Assert.Equal(VoiceLabTakeQaVerdict.Failed, (row.Qa with { SpeakerScore = .9 }).Verdict);
        Assert.Equal("voice couldn't be measured (under 3 s of speech)", row.ShortPhraseCopy);
        Assert.Equal(VoiceLabTakeQaVerdict.Failed, Waiting().CheckingVoice(VoiceLabTakeVoiceCheck.ShortSpeech(Unmeasured), speakerFailed: true).Qa!.Verdict);
        // Pooled evidence with too few takes, or an unmeasured pool at a full window, is not usable.
        Assert.False(VoiceLabTakeVoiceCheck.ShortSpeech(Pooled with { TakeCount = 1 }).Complete);
        Assert.False(VoiceLabTakeVoiceCheck.ShortSpeech(Unmeasured with { VoicedFrames = 48000 }).Complete);
    }

    [Fact]
    public void APooledMismatchAddsTheSpeakerFailureBesideAWordsFailure()
    {
        var passed = Waiting().CheckingVoice(VoiceLabTakeVoiceCheck.ShortSpeech(Pooled), .8);
        Assert.Equal(VoiceLabTakeQaVerdict.Passed, passed.Qa!.Verdict);
        Assert.True(passed.VoiceCheck.Complete);
        var failed = Waiting(VoiceLabTakeQaFailure.Transcript).CheckingVoice(VoiceLabTakeVoiceCheck.ShortSpeech(Pooled), .1, speakerFailed: true);
        Assert.Equal([VoiceLabTakeQaFailure.Transcript, VoiceLabTakeQaFailure.Speaker], failed.Qa!.Failures);
        Assert.Equal(.1, failed.Qa.SpeakerScore);
        var consent = new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        Assert.Same(consent, Waiting().CheckingVoice(VoiceLabTakeVoiceCheck.PerTake, failure: consent).Failure);
    }

    [Fact]
    public void AShortTakesWordsAndAcousticsAreEvaluatedWithNoSpeakerScore()
    {
        var qa = VoiceLabTakeQuality.Evaluate("hello there", ["hello", "there"], Enumerable.Repeat(.1f, 2400).ToArray(), 24000, [], null, .45);
        Assert.Null(qa.SpeakerScore);
        Assert.Empty(qa.Failures);
        Assert.Contains(VoiceLabTakeQaFailure.Speaker, VoiceLabTakeQuality.Evaluate("hello there", ["hello", "there"], Enumerable.Repeat(.1f, 2400).ToArray(), 24000, [], .1, .45).Failures);
    }

    [Fact]
    public void TheEvidenceSavesExactlyItsFiveFields()
    {
        var json = JsonNode.Parse(JsonSerializer.Serialize(Unmeasured, new JsonSerializerOptions(JsonSerializerDefaults.Web)))!.AsObject();
        Assert.Equal(["mode", "recordId", "consentMethod", "voicedFrames", "takeCount"], json.Select(pair => pair.Key));
    }
}
