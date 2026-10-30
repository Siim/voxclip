using VoxClip.Cli;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Speech;
using VoxClip.Tests.Support;
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

    [Fact]
    public async Task ModelsInstallPrintsTheDownloadTermsAndTheCommandIsTheConsent()
    {
        var catalogue = await new ModelCatalog(FixtureLoader.SharedRoot).GetModelsAsync(TestContext.Current.CancellationToken);
        var model = catalogue.Single(entry => entry.Id == "whisper-small.en-q5_1");
        var dependencies = ModelDownloadCopy.Dependencies(model, catalogue);
        using var terms = new StringWriter();
        Assert.True(await ServicesMergeAdapter.CommandConfirmation(terms)(model, dependencies, TestContext.Current.CancellationToken));
        Assert.Equal(ModelDownloadCopy.Title(model) + Environment.NewLine + ModelDownloadCopy.Body(model, dependencies) + Environment.NewLine, terms.ToString());
        Assert.Contains("(190.98 MB)", terms.ToString());
        Assert.True(await ServicesMergeAdapter.CommandConfirmation(null)(model, dependencies, TestContext.Current.CancellationToken));
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ServicesMergeAdapter.CommandConfirmation(terms)(model, dependencies, cancel.Token));
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
