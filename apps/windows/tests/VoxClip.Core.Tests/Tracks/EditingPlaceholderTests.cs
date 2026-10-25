using Xunit;
namespace VoxClip.Core.Tests.Tracks;

public sealed class EditingPlaceholderTests
{
    [Fact]
    public void TrackConformance()
        => Assert.NotEmpty(WinEditing.EditingFixtureTests.Fixtures());
}
