using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

public sealed partial class VoiceLabTakeRunTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task InsufficientGeneratedSupportIsNotMeasuredSpeakerOrTranscriptFailure(bool vadInsufficient)
    {
        await using var fixture = new Fixture();
        if (vadInsufficient) fixture.InsufficientSpeech = true;
        else fixture.Remote.Duration = 2;
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        Assert.Equal(VoiceLabTakeRunEnd.Completed, result.End);
        Assert.Equal(3, result.Rows.Count); Assert.Null(result.Best);
        Assert.Equal(3, fixture.Remote.Seeds.Count); Assert.Equal(0, fixture.Remote.Qa);
        Assert.All(result.Rows, row =>
        {
            Assert.False(row.Selectable); Assert.False(row.Stopped); Assert.Null(row.Failure);
            Assert.NotNull(row.Receipt); Assert.NotNull(row.Generated); Assert.NotNull(row.Audio);
            var qa = row.Qa!;
            Assert.Equal(VoiceLabTakeQaFailure.InsufficientGeneratedSpeech, Assert.Single(qa.Failures));
            Assert.Null(qa.TranscriptMatch); Assert.Null(qa.SpeakerScore); Assert.Null(qa.LufsJumpLu); Assert.Null(qa.PeakDbfs);
            Assert.Null(row.QaReceipt);
            Assert.Equal(row.Receipt!.ActionId, Assert.Single(row.AcceptedRequestIds));
        });
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
        });
    }
}
