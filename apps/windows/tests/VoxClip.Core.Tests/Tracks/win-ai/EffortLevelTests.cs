using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>AI §2.1: every AI decision asks for extra high; a connector sends the highest level it supports at or below it.</summary>
[Trait("Track", "win-ai")]
public sealed class EffortLevelTests
{
    [Fact]
    public void DecisionFeaturesAskForExtraHigh()
    {
        Assert.Equal(Effort.XHigh, EffortLevel.Decision);
        Assert.Equal(new[] { "low", "medium", "high", "xhigh", "max" }, Enum.GetValues<Effort>().Select(effort => effort.Wire()));
        Assert.Equal(new[] { "low", "medium", "high", "extra high", "max" }, Enum.GetValues<Effort>().Select(effort => effort.Label()));
    }

    [Fact]
    public void ResolvesToTheHighestSupportedLevelAtOrBelowTheRequest()
    {
        Assert.Equal(Effort.XHigh, EffortLevel.Resolve(Effort.XHigh, ["low", "medium", "high", "xhigh", "max"]));
        Assert.Equal(Effort.High, EffortLevel.Resolve(Effort.XHigh, ["LOW", "MEDIUM", "HIGH"]));
        Assert.Equal(Effort.XHigh, EffortLevel.Resolve(Effort.Max, ["medium", "xhigh"]));
        Assert.Equal(Effort.Low, EffortLevel.Resolve(Effort.XHigh, ["minimal", "low"]));
        Assert.Null(EffortLevel.Resolve(Effort.Low, ["high"]));
        Assert.Null(EffortLevel.Resolve(Effort.XHigh, []));
        Assert.Null(EffortLevel.Resolve(null, ["high"]));
    }

    [Fact]
    public void CatalogDecisionEffortPerConnectorAndRaisedTimeouts()
    {
        var catalog = Catalog();
        var expected = new Dictionary<ConnectorId, Effort?>
        {
            [ConnectorId.Anthropic] = Effort.XHigh, [ConnectorId.OpenAI] = Effort.High, [ConnectorId.Gemini] = Effort.High,
            [ConnectorId.Xai] = null, [ConnectorId.Ollama] = null, [ConnectorId.LmStudio] = null, [ConnectorId.AppleFoundation] = null,
            [ConnectorId.ClaudeCode] = Effort.XHigh, [ConnectorId.Codex] = Effort.High,
        };
        foreach (var (id, effort) in expected) Assert.Equal(effort, catalog.DecisionEffort(id));
        Assert.Equal(TimeSpan.FromSeconds(360), catalog.Timeout("cloud"));
        Assert.Equal(TimeSpan.FromSeconds(600), catalog.Timeout("cli"));
        Assert.Equal(TimeSpan.FromSeconds(30), catalog.Timeout("test"));
        Assert.Equal(TimeSpan.FromSeconds(120), catalog.Timeout("cliTest"));
    }
}
