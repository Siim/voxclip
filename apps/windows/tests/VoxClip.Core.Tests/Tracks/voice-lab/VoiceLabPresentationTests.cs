using System.Globalization;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabPresentationTests
{
    [Theory]
    [InlineData("en-US")]
    [InlineData("et-EE")]
    [InlineData("ar-EG")]
    public void PauseFitNotesReplaySharedPrintfVectors(string culture)
    {
        var previous = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(culture);
            using var fixture = JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/pause-fit-note-cases.json"));
            Assert.Equal("voxclip-voice-lab-pause-fit-note/1", fixture.RootElement.GetProperty("schema").GetString());
            var cases = fixture.RootElement.GetProperty("cases");
            Assert.Equal(18, cases.GetArrayLength());
            foreach (var row in cases.EnumerateArray())
                Assert.Equal(row.GetProperty("expected").GetString(), VoiceLabPauseFitNote.Format(row.GetProperty("seconds").GetDouble()));
        }
        finally { CultureInfo.CurrentCulture = previous; }
    }

    [Theory]
    [InlineData(double.NaN, "pauses −nan s")]
    [InlineData(double.PositiveInfinity, "pauses +inf s")]
    [InlineData(double.NegativeInfinity, "pauses −inf s")]
    public void NonfinitePauseNotesAlsoMatchFoundationPrintf(double seconds, string expected) => Assert.Equal(expected, VoiceLabPauseFitNote.Format(seconds));

    [Fact]
    public void BetaPredicateNeverBypassesEnabledOrReleaseConsent()
    {
        foreach (var enabled in new[] { false, true })
        foreach (var accepted in new[] { false, true })
        foreach (var internalBuild in new[] { false, true })
        {
#if DEBUG
            var expected = enabled && (accepted || internalBuild);
#else
            var expected = enabled && accepted;
#endif
            Assert.Equal(expected, VoiceLabBeta.IsAvailable(enabled, accepted, internalBuild));
        }
    }
}
