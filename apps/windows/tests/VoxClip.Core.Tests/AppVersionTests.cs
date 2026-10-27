using VoxClip.Core.Services;
using Xunit;

namespace VoxClip.Core.Tests;

public sealed class AppVersionTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(" \n")]
    [InlineData("\t\r\n")]
    [InlineData("+build")]
    [InlineData(" \t+build")]
    public void AbsentDisplayVersionIsUnknown(string? value)
    {
        Assert.Equal("unknown", AppVersion.Resolve(value));
        Assert.Equal("0.0.0", AppVersion.ResolveProjectWriter(AppVersion.Resolve(value)));
    }

    [Theory]
    [InlineData("9.8.7-beta.2", "9.8.7-beta.2")]
    [InlineData("9.8.7+build", "9.8.7")]
    public void ExplicitDisplayVersionDropsOnlyBuildMetadata(string value, string expected)
        => Assert.Equal(expected, AppVersion.Resolve(value));
}
