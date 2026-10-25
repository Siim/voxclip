using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class SharedPolicyTests
{
    [Fact]
    public void PromptLimitsDriveFinalizationWithoutChangingThePublicContract()
    {
        var prompts = new ClipPrompts(Catalog());
        var settings = prompts.Clips["limits"]!;
        settings["titleMaxLength"] = 4;
        settings["reasonMaxLength"] = 5;
        settings["scoreMin"] = 3;
        settings["scoreMax"] = 7;
        settings["mostlyCutFraction"] = 0.1;
        settings["nearDuplicateOverlap"] = 0.95;
        settings["snapRadiusWords"] = 0;
        settings["minLengthFactor"] = 0.3;
        var limits = prompts.ValidationLimits;
        var words = Words(100);
        var request = new FinalizeClipsRequest(new[] { new RawClip("abcdef", "ghijkl", 10, 0, 20) }, words, prompts.Rules(ClipPreset.Best), [], new HashSet<string>(), 2, false);
        var clip = Assert.Single(ClipValidation.FinalizeClips(request, limits).Clips);
        Assert.Equal("abcd", clip.Title);
        Assert.Equal("ghijk", clip.Reason);
        Assert.Equal(7, clip.Score);
        Assert.Empty(ClipValidation.FinalizeClips(request with { CutSet = words.Take(3).Select(word => word.Id).ToHashSet() }, limits).Clips);
        var overlapping = request with { Candidates = new[] { new RawClip("first", "reason", 9, 0, 20), new RawClip("second", "reason", 8, 1, 21) } };
        Assert.Equal(2, ClipValidation.FinalizeClips(overlapping, limits).Clips.Count);
        Assert.Single(ClipValidation.FinalizeClips(overlapping).Clips);
        var shortClip = Assert.Single(ClipValidation.FinalizeClips(request with { Candidates = new[] { new RawClip("short", "reason", 0, 0, 8) } }, limits).Clips);
        Assert.Equal(3, shortClip.Score);
        var snapped = Assert.Single(ClipValidation.FinalizeClips(request with { Candidates = new[] { new RawClip("range", "reason", 8, 2, 18) }, Lines = new[] { new TranscriptLine(0, 20, 0, 20.8, "line") }, Snap = true }, limits).Clips);
        Assert.Equal(2, snapped.Start);
        Assert.Equal(18, snapped.End);
    }

    [Fact]
    public void CatalogTokenPolicyDrivesPlanningAndLineCosts()
    {
        var catalog = Catalog();
        catalog.Data["policy"]!["tokenEstimate"]!["utf8BytesPerToken"] = 10.0;
        catalog.Data["policy"]!["tokenEstimate"]!["contextSafetyFactor"] = 0.5;
        Assert.Equal(2, catalog.Estimate("😀😀😀"));
        var lines = ClipText.Lines(ClipText.Entries(Words(100), new Dictionary<string, string>()));
        var plan = new ClipPrompts(catalog).Plan(lines, "best", "", 100, 8192, 1500);
        Assert.Equal((int)Math.Floor((8192 - plan.Overhead - plan.OutputReserve) * 0.5), plan.Budget);
        Assert.All(plan.Windows, window => Assert.Equal(window.Lines.Sum(line => catalog.Estimate(line.Line.Text + "\n") + (line.PauseAfter is null ? 0 : catalog.Estimate(line.PauseAfter + "\n"))), window.EstimatedTokens));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CatalogRetryPolicyDrivesBackoffAndWaitHintLimit(bool longHint)
    {
        var catalog = Catalog();
        catalog.Data["policy"]!["retry"]!["backoffSeconds"] = new JsonArray(0.125, 0.25);
        catalog.Data["policy"]!["retry"]!["maxRetryAfterSeconds"] = 2.0;
        var delays = new List<TimeSpan>();
        using var handler = new StubHttp((_, number, _) =>
        {
            var response = Response(number < 3 ? 503 : 200, number < 3 ? "{}" : Completion(ConnectorId.OpenAI));
            if (longHint) response.Headers.TryAddWithoutValidation("retry-after", "3");
            return Task.FromResult(response);
        });
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.OpenAI, catalog, client, new MemoryKeys(), new Redactor(), (duration, _) => { delays.Add(duration); return Task.CompletedTask; });
        if (longHint)
        {
            var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Request(ConnectorId.OpenAI), "model", TestContext.Current.CancellationToken));
            Assert.Equal(LlmErrorKind.RateLimited, failure.Error.Kind);
            Assert.Single(handler.Requests);
            Assert.Empty(delays);
        }
        else
        {
            await connector.SendAsync(Request(ConnectorId.OpenAI), "model", TestContext.Current.CancellationToken);
            Assert.Equal(new[] { TimeSpan.FromSeconds(0.125), TimeSpan.FromSeconds(0.25) }, delays);
        }
    }
}
