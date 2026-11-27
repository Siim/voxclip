using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class TakeMatchFixtureTests
{
    [Fact]
    public void SharedOpeningUsesOpaqueWordIds()
    {
        TimedWord[] primary = [new("left:opaque", "Opening.", WordKind.Word, 0, 1, null, null, null, null, TimingSource.Native)];
        TimedWord[] alternate = [new("r2.w14", "opening!", WordKind.Word, 2, 3, null, null, null, null, TimingSource.Native)];
        var result = TakeMatch.Build([("first", primary), ("second", alternate)]);
        Assert.Equal(["left:opaque", "r2.w14"], Assert.Single(result.Beats).Takes.Select(take => take.StartWordId));
    }
}
