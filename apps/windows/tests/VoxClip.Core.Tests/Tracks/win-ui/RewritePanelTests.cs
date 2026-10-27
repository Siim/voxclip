using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class RewritePanelTests
{
    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public void EveryEntryRespectsTheReleaseGate(int entryIndex)
    {
        var entry = (RewriteEntry)entryIndex;
        Assert.Equal(RewriteEntryAction.Unavailable, RewriteEntryPolicy.Resolve(entry, true, true, true, true, false));
        Assert.Equal(entry == RewriteEntry.InsertWords ? RewriteEntryAction.OpenInsertion : RewriteEntryAction.OpenPassage,
            RewriteEntryPolicy.Resolve(entry, true, true, true, true, true));
        Assert.Equal(RewriteEntryAction.Unavailable, RewriteEntryPolicy.Resolve(entry, true, false, true, true, true));
    }

    [Fact]
    public void DisabledVoiceLabOnlyOffersTheOneTimeOverflowFlow()
    {
        foreach (var entry in Enum.GetValues<RewriteEntry>())
            Assert.Equal(entry == RewriteEntry.Overflow ? RewriteEntryAction.TurnOnVoiceLab : RewriteEntryAction.Unavailable,
                RewriteEntryPolicy.Resolve(entry, false, true, true, true, true));
        Assert.Equal(RewriteEntryAction.Unavailable, RewriteEntryPolicy.Resolve(RewriteEntry.InsertWords, true, true, true, false, true));
#if !DEBUG
        Assert.False(RewriteEntryPolicy.BuildEnabled);
#endif
    }
}
