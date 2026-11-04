using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

public sealed partial class VoiceLabTakeRunTests
{
    /// <summary>ADR-R37: a take under three seconds of voiced speech is no longer refused. Its words and acoustics are checked
    /// (Scribe is sent), it waits for the run's pooled voice check, and a pool still short is recorded as unmeasured with no
    /// invented score; an own clone's unmeasured take can be chosen, and its run needs no further candidate.</summary>
    [Fact]
    public async Task AShortTakeIsWordCheckedThenRecordedAsUnmeasuredWithNoScore()
    {
        await using var fixture = new Fixture(input => input with { ContentKey = new string('a', 64) }) { VoicedFrames = 16000 };
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        Assert.Equal(VoiceLabTakeRunEnd.EarlyStop, result.End);
        var row = Assert.Single(result.Rows);
        Assert.Equal(1, fixture.Remote.Qa);
        Assert.Empty(fixture.Embedded);
        var evidence = Assert.IsType<VoiceLabTakeVoiceCheck.ShortSpeechCheck>(row.VoiceCheck).Pool;
        Assert.Equal(new VoiceLabShortSpeechEvidence(VoiceLabShortSpeechMode.Unmeasured, fixture.Record.RecordId, fixture.Record.ConsentMethod, 16000, 1), evidence);
        Assert.Null(row.Qa!.SpeakerScore);
        Assert.True(row.Qa.SpeakerUnmeasured);
        Assert.NotNull(row.Qa.TranscriptMatch); Assert.NotNull(row.QaReceipt);
        Assert.True(row.Selectable, row.Failure?.ToString());
        Assert.Equal("voice couldn't be measured (under 3 s of speech)", row.ShortPhraseCopy);

        // Acceptance carries the evidence: no score, speakerPassed false, and the render contract accepts it.
        var acceptedAt = DateTimeOffset.UtcNow;
        var (publication, consent) = await fixture.Run.PublishForAcceptanceAsync(row.Id, acceptedAt, Token);
        var published = new VoiceLabPublishedTake(publication.Assets, publication.Audio, publication.OutDuration, publication.Words, publication.Chunks);
        var candidate = VoiceLabRecipeBuilder.Candidate(row, fixture.Input, published, consent, acceptedAt);
        Assert.Null(candidate.Recipe!.Qa.SpeakerScore);
        Assert.False(candidate.Recipe.Qa.SpeakerPassed);
        Assert.Equal(evidence, candidate.Recipe.Qa.ShortSpeech);
        // An invented score on an unmeasured take, or another record's evidence, is refused.
        Assert.Throws<VoiceLabProjectException>(() => VoiceLabRecipeBuilder.Candidate(row with { Qa = row.Qa with { SpeakerScore = .9 } }, fixture.Input, published, consent, acceptedAt));
        Assert.Throws<VoiceLabProjectException>(() => VoiceLabRecipeBuilder.Candidate(
            row with { VoiceCheck = VoiceLabTakeVoiceCheck.ShortSpeech(evidence with { RecordId = Guid.NewGuid().ToString("D") }) }, fixture.Input, published, consent, acceptedAt));
        var segment = VoiceLabRecipeBuilder.Segment("short-take", [candidate], 0, fixture.Input, row.Audio!.Fit.Plan);
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        project = project with
        {
            Id = publication.Assets[0].File.Split('/')[0], SchemaVersion = 1, VoiceLab = new([]),
            Media = new(project.Media.Source with { DurationSeconds = 8, ContentKey = fixture.Input.ContentKey, Audio = new(24000, 1) }),
            Transcript = project.Transcript! with { Words = fixture.Input.Items },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null },
            Share = new(new Dictionary<string, string>())
        };
        var voice = new VoiceLabVoiceReference(consent.RecordId, consent.Provider, consent.VoiceId, consent.RecordId, consent.VoiceName, VoiceLabVoiceStatus.Active);
        project = new VoiceLabEditCommand.Accept(segment, publication.Assets, voice).ApplyingTo(project);
        var roundTrip = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project));
        var prepared = VoiceLabRenderContract.Prepare(roundTrip, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Assert.Equal(evidence, Assert.Single(prepared.SelectedSegmentRecipes).Recipe.Qa.ShortSpeech);
    }

    /// <summary>ADR-R37: two approved runs sharing one pool are checked together after the last: their voiced speech reaches a
    /// calibrated window, so the pooled verdict is measured and both takes carry it.</summary>
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ShortTakesOfOnePoolAreMeasuredTogetherAfterTheLastRun(bool mismatch)
    {
        await using var fixture = new Fixture { VoicedFrames = 30000, SpeakerFailure = mismatch };
        var pool = new VoiceLabShortTakePool(fixture.Run.VoiceChecks);
        fixture.Run.ShortTakePool = pool;
        var first = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        var second = await fixture.Run.ExecuteAsync(await fixture.Run.PrepareAsync(fixture.Input with { Seed = 9 }, Token), true, ct: Token);
        var waiting = first.Rows.Concat(second.Rows).ToArray();
        Assert.Equal(2, waiting.Length);
        Assert.All(waiting, row => { Assert.IsType<VoiceLabTakeVoiceCheck.WaitingCheck>(row.VoiceCheck); Assert.False(row.Selectable); });
        Assert.Empty(fixture.Embedded);
        var checkedRows = await pool.FinishAsync();
        Assert.Equal([60000], fixture.Embedded);
        fixture.Run.ApplyVoiceChecks(checkedRows);
        Assert.All(waiting, take =>
        {
            var row = checkedRows[take.Id];
            Assert.Equal(new VoiceLabShortSpeechEvidence(VoiceLabShortSpeechMode.Pooled, fixture.Record.RecordId, fixture.Record.ConsentMethod, 60000, 2), row.VoiceCheck.Evidence);
            Assert.Equal(mismatch ? 0 : 1, row.Qa!.SpeakerScore);
            Assert.Equal(!mismatch, row.Selectable);
            Assert.Equal(mismatch, row.Qa.Failures.Contains(VoiceLabTakeQaFailure.Speaker));
            Assert.Equal(mismatch ? null : "Short phrase · words checked · voice checked across 2 takes", row.ShortPhraseCopy);
        });
        // Acceptance publishes the checked row: a mismatch is refused, a pass is published.
        if (mismatch) await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.PublishForAcceptanceAsync(waiting[1].Id, DateTimeOffset.UtcNow, Token));
        else await fixture.Run.PublishForAcceptanceAsync(waiting[1].Id, DateTimeOffset.UtcNow, Token);
    }

    [Fact]
    public async Task MeasuredLowSpeakerScoreRemainsASpeakerFailureWithRealQa()
    {
        await using var fixture = new Fixture { SpeakerFailure = true };
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        Assert.Equal(3, fixture.Remote.Qa); Assert.Null(result.Best);
        Assert.All(result.Rows, row =>
        {
            Assert.Equal(VoiceLabTakeQaFailure.Speaker, Assert.Single(row.Qa!.Failures));
            Assert.Equal(0, row.Qa.SpeakerScore); Assert.NotNull(row.Qa.TranscriptMatch);
            Assert.NotNull(row.Qa.LufsJumpLu); Assert.NotNull(row.Qa.PeakDbfs); Assert.NotNull(row.QaReceipt);
            Assert.False(row.Selectable);
            Assert.IsType<VoiceLabTakeVoiceCheck.PerTakeCheck>(row.VoiceCheck);
        });
    }
}
