using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Voice Lab §3.1 for LLM sends, as amended by the user's decision of 2026-10-31: replays
/// shared/fixtures/voice-lab/llm-send-cost-cases.json (rules in llm-send-cost-README.md).</summary>
[Trait("Track", "voice-lab")]
public sealed class VoiceLabLlmSendCostTests
{
    private static JsonObject[] Cases()
    {
        var document = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/llm-send-cost-cases.json"))!.AsObject();
        Assert.Equal("voxclip-voice-lab-llm-send-cost-cases/1", document["schema"]!.GetValue<string>());
        var cases = document["cases"]!.AsArray().Select(row => row!.AsObject()).ToArray();
        Assert.NotEmpty(cases);
        return cases;
    }

    private static ConnectorId Connector(JsonNode? node) => Enum.GetValues<ConnectorId>().Single(id => LlmCatalog.WireId(id) == node!.GetValue<string>());

    private static CliSignIn? SignIn(JsonNode? node) => node?.GetValue<string>() switch
    {
        null => null,
        "plan" => CliSignIn.Plan,
        "apiKey" => CliSignIn.ApiKey,
        var other => throw new InvalidDataException("sign-in " + other)
    };

    [Fact]
    public void EveryConnectorAndSignInReplays()
    {
        foreach (var row in Cases())
        {
            var id = row["id"]!.GetValue<string>();
            var expected = row["expected"]!;
            var kind = VoiceLabCostPresentation.KindForLlmSend(Connector(row["connector"]), SignIn(row["signIn"]), row["providerName"]!.GetValue<string>());
            Assert.True(new VoiceLabCostPresentationResult(expected["kind"]!.GetValue<string>() == "inline" ? VoiceLabCostPresentationKind.Inline : VoiceLabCostPresentationKind.Confirm,
                expected["text"]!.GetValue<string>()) == kind, id);
            Assert.Equal("Rewrite", VoiceLabCostPresentation.ButtonTitle("Rewrite", null, kind));
        }
    }

    [Fact]
    public void TheTableCoversEveryConnectorWithEverySignInState()
    {
        var cases = Cases();
        var covered = cases.Select(row => row["connector"]!.GetValue<string>() + "|" + (row["signIn"]?.GetValue<string>() ?? "unknown")).ToHashSet(StringComparer.Ordinal);
        var required = Enum.GetValues<ConnectorId>().SelectMany(id => new[] { "plan", "apiKey", "unknown" }.Select(signIn => LlmCatalog.WireId(id) + "|" + signIn))
            .ToHashSet(StringComparer.Ordinal);
        Assert.True(required.SetEquals(covered), string.Join(", ", required.Except(covered).Concat(covered.Except(required))));
        Assert.Equal(required.Count, cases.Length);
    }

    /// <summary>The plan's risk: a CLI on an API-key sign-in must never pass as "no extra cost".</summary>
    [Fact]
    public void OnlyAPlanSignInLetsACliSendWithoutAsking()
    {
        foreach (var connector in new[] { ConnectorId.ClaudeCode, ConnectorId.Codex })
        {
            Assert.Equal(new VoiceLabCostPresentationResult(VoiceLabCostPresentationKind.Inline, ""), VoiceLabCostPresentation.KindForLlmSend(connector, CliSignIn.Plan, "Anthropic"));
            foreach (var signIn in new CliSignIn?[] { CliSignIn.ApiKey, null })
                Assert.Equal(new VoiceLabCostPresentationResult(VoiceLabCostPresentationKind.Confirm, "VoxClip can't tell what this costs. Check Anthropic's pricing."),
                    VoiceLabCostPresentation.KindForLlmSend(connector, signIn, "Anthropic"));
        }
        Assert.Equal(VoiceLabCostPresentationKind.Confirm, VoiceLabCostPresentation.KindForLlmSend((ConnectorId)999, CliSignIn.Plan, "Fixture").Kind);
    }
}
