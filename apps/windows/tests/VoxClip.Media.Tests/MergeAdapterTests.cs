using VoxClip.Cli;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class MergeAdapterTests
{
    [Theory]
    [InlineData("5")]
    [InlineData("a:b")]
    [InlineData("-1:3")]
    [InlineData("9:2")]
    [InlineData("0:5")]
    [InlineData("2147483648:3")]
    [InlineData("0:1:2")]
    public void RangeBoundsAlwaysBecomeUsageErrors(string range)
        => Assert.Throws<CliUsageException>(() => CliOperations.ParseRange(range, 5));

    [Fact]
    public void RangeEndpointsAreInclusiveAndValidatedAgainstWordCount()
        => Assert.Equal((0, 4), CliOperations.ParseRange("0:4", 5));

    [Theory]
    [InlineData("NoWords", "noWords", "There are no words to clip.", 3)]
    [InlineData("NeedInstructions", "needInstructions", "Describe the clips you want.", 2)]
    public void FeatureGatesKeepTheirCodeMessageAndInputOrUsageExit(string kind, string code, string message, int exit)
        => Assert.Equal((code, message, exit), AiMergeAdapter.Gate(kind, message));

    [Fact]
    public void ConstructorBridgeInjectsTheEnvironmentProviderInsteadOfDefaults()
    {
        var keys = new EnvironmentKeyProvider();
        var result = MergeApi.Construct<ConstructorBoundary>([keys, new ITranscriber[0], null]);
        Assert.Same(keys, result.Keys);
        Assert.Empty(result.Engines);
        Assert.Throws<VoxClipException>(() => MergeApi.Construct<ConstructorBoundary>([]));
    }

    [Fact]
    public void NativeSiblingExceptionsAreNotHiddenByReflection()
    {
        var failure = Assert.Throws<IOException>(() => MergeApi.Construct<FailingBoundary>(["input"]));
        Assert.Equal("original service failure", failure.Message);
        Assert.Throws<VoxClipException>(() => MergeApi.Invoke<object>(null, null, []));
    }

    public sealed class ConstructorBoundary(IKeyProvider keys, IEnumerable<ITranscriber> engines, object? optional)
    {
        public IKeyProvider Keys { get; } = keys;
        public IEnumerable<ITranscriber> Engines { get; } = engines;
        public object? Optional { get; } = optional;
    }

    public sealed class FailingBoundary
    {
        public FailingBoundary(string input) => throw new IOException("original service failure");
    }

}
