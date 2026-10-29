using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class LocalRuntimeGuardTests
{
    [Theory]
    [InlineData("14.30.30704.0", "14.42.34438.0", false)]
    [InlineData("14.42.34438.0", "14.39.33519.0", false)]
    [InlineData("14.40.0.0", "14.40.0.0", true)]
    [InlineData("14.42.34438.0", "14.42.34438.0", true)]
    [InlineData("14.44.35211.0", "14.44.35211.0", true)]
    [InlineData(null, "14.42.34438.0", false)]
    [InlineData("14.42.34438.0", null, false)]
    public void RequiresBothRuntimeFilesAtAbiFloor(string? standardLibrary, string? runtime, bool expected) =>
        Assert.Equal(expected, LocalRuntimeGuard.Supports(standardLibrary is null ? null : Version.Parse(standardLibrary), runtime is null ? null : Version.Parse(runtime)));

    [Theory]
    [InlineData("14.30", false)]
    [InlineData("14.42", true)]
    public void DecisionIsHeldForTheSession(string version, bool expected)
    {
        var reads = new List<string>();
        var guard = new LocalRuntimeGuard(name => { reads.Add(name); return Version.Parse(version); });
        Assert.Empty(reads);
        Assert.Equal(expected, guard.IsSupported);
        Assert.Equal(expected, guard.IsSupported);
        Assert.Equal(new[] { "msvcp140.dll", "vcruntime140.dll" }, reads);
    }
}
