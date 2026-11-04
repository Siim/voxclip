using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>shared/fixtures/clip-style/caption-pick.json: the clip style contract (design §6.9) and the caption pick request (AI §15),
/// the twin of the Swift CaptionPickTests.</summary>
public sealed class CaptionPickTests
{
    private static JsonObject Fixture() => JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "clip-style", "caption-pick.json")))!.AsObject();
    private static string Root => FixtureLoader.SharedRoot;
    private static IReadOnlyList<VoxClip.Core.Domain.Captions.CaptionStyle> Library() => CaptionStyleLibrary.Load(Root).Styles;

    private static CaptionPickClip[] Clips(JsonNode? node) => node!.AsArray().Select(item => new CaptionPickClip(item!["id"]!.GetValue<string>(),
        item["title"]?.GetValue<string>(), item["seconds"]!.GetValue<double>(), item["text"]!.GetValue<string>())).ToArray();

    private static IReadOnlyDictionary<string, ClipCaptionPick> Picks(JsonNode? node) => node!.AsObject().ToDictionary(item => item.Key,
        item => new ClipCaptionPick(item.Value!["styleId"]!.GetValue<string>(), item.Value["reason"]!.GetValue<string>()), StringComparer.Ordinal);

    private static ClipStyle Style(JsonNode? node)
    {
        var value = node!.AsObject();
        return new(value["preset"]!.GetValue<string>(), value["captions"]!.GetValue<string>(), value["music"]!.GetValue<string>(), value["maxLengthSec"]!.GetValue<int>(),
            value["shapes"]!.AsArray().Select(shape => shape!.GetValue<string>()).ToArray(), value["rewording"]!.GetValue<string>(), Picks(value["captionPicks"]));
    }

    private static string Sha(string relative) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(Path.Combine(Root, relative))));

    [Fact]
    public void FixtureIsCurrentForThePromptThePresetsAndTheLibrary()
    {
        var fixture = Fixture();
        Assert.Equal("voxclip-caption-pick/1", fixture["fixture"]!.GetValue<string>());
        Assert.Equal(Sha("prompts/caption-pick.json"), fixture["promptSha256"]!.GetValue<string>());
        Assert.Equal(Sha("data/clip-styles.json"), fixture["clipStylesSha256"]!.GetValue<string>());
        Assert.Equal(fixture["libraryStyles"]!.AsArray().Select(id => id!.GetValue<string>()), Library().Select(style => style.Id));
        Assert.Equal((4, 4, 14), (fixture["requests"]!.AsArray().Count, fixture["replies"]!.AsArray().Count, fixture["clipStyles"]!.AsArray().Count));
    }

    [Fact]
    public void EveryRequestRendersByteForByteAtDecisionEffort()
    {
        var prompt = CaptionPickPrompt.Load(Root);
        var styles = ClipStyleCatalog.Load(Root);
        foreach (var item in Fixture()["requests"]!.AsArray())
        {
            var id = item!["id"]!.GetValue<string>();
            var expected = item["expected"]!;
            var preset = styles.Find(item["preset"]!.GetValue<string>());
            var candidates = styles.CaptionCandidates(Library(), preset.Style);
            Assert.Equal(expected["candidates"]!.AsArray().Select(value => value!.GetValue<string>()), candidates.Select(style => style.Id));
            var request = prompt.Request(Clips(item["clips"]), candidates, preset.Label, TimeSpan.FromSeconds(60), "en");
            Assert.Equal(LlmFeature.CaptionPick, request.Feature);
            Assert.Equal(expected["system"]!.GetValue<string>(), request.System);
            Assert.True(expected["instruction"]!.GetValue<string>() == request.Instruction, id + " instruction");
            Assert.Equal((expected["schemaName"]!.GetValue<string>(), expected["maxOutputTokens"]!.GetValue<int>()), (request.SchemaName, request.MaxOutputTokens));
            Assert.Equal(expected["effort"]!.GetValue<string>(), request.Effort!.Value.Wire());
            Assert.Equal(EffortLevel.Decision, request.Effort);
            Assert.Equal(expected["tag"]!.GetValue<string>(), request.Tag);
        }
    }

    [Fact]
    public void RepliesKeepOnlyKnownClipsCandidateStylesAndTrimmedReasons()
    {
        var prompt = CaptionPickPrompt.Load(Root);
        var clips = Clips(Fixture()["requests"]!.AsArray()[0]!["clips"]);
        foreach (var item in Fixture()["replies"]!.AsArray())
        {
            var id = item!["id"]!.GetValue<string>();
            Assert.Equal(item["clips"]!.AsArray().Select(value => value!.GetValue<string>()), clips.Select(clip => clip.Id));
            var parsed = prompt.Picks(item["reply"]!.AsObject(), clips, item["candidates"]!.AsArray().Select(value => value!.GetValue<string>()).ToHashSet(StringComparer.Ordinal));
            var expected = Picks(item["expected"]!["picks"]);
            Assert.True(expected.Count == parsed.Picks.Count && expected.All(pick => parsed.Picks.TryGetValue(pick.Key, out var actual) && actual == pick.Value), id + " picks");
            Assert.Equal(item["expected"]!["dropped"]!.GetValue<int>(), parsed.Dropped);
        }
    }

    [Fact]
    public void PresetsResolutionRecordingAndFixingFollowTheContract()
    {
        var styles = ClipStyleCatalog.Load(Root);
        foreach (var item in Fixture()["clipStyles"]!.AsArray())
        {
            var id = item!["id"]!.GetValue<string>();
            var expected = item["expected"]!;
            switch (item["op"]!.GetValue<string>())
            {
                case "preset":
                    var preset = styles.Find(item["preset"]!.GetValue<string>());
                    Assert.True(preset.Style.SameAs(Style(expected["style"])), id);
                    Assert.Equal(expected["summary"]!.GetValue<string>(), preset.Style.Summary(preset.Label));
                    break;
                case "resolve":
                    var style = Style(item["style"]);
                    foreach (var (clip, want) in expected["resolved"]!.AsObject())
                        Assert.True(style.CaptionStyleFor(clip.Length == 0 ? null : clip) == want?.GetValue<string>(), $"{id} {clip}");
                    break;
                case "record":
                    Assert.True(Style(item["style"]).Recording(Picks(item["picks"])).SameAs(Style(expected["style"])), id);
                    break;
                case "fix":
                    Assert.True(Style(item["style"]).FixingCaptions(item["choice"]!.GetValue<string>()).SameAs(Style(expected["style"])), id);
                    break;
                default: Assert.Fail("Unknown op in " + id); break;
            }
        }
    }

    [Fact]
    public async Task AutoRecordsAStubReplysPicksAndAFixedStyleSendsNothing()
    {
        var catalog = AiTestSupport.Catalog();
        var styles = ClipStyleCatalog.Load(Root);
        var picker = new CaptionPicker(new LlmRunner(new MemoryKeys(null), catalog, new Redactor()), CaptionPickPrompt.Load(Root), catalog);
        CaptionPickClip[] clips = [new("clip-a", "Hook", 20, "Stop doing this."), new("clip-b", "Story", 40, "When I was a kid.")];
        const string reply = "{\"picks\":[{\"clip\":\"C1\",\"style\":\"punch-in\",\"reason\":\"Punchy hook.\"},{\"clip\":\"C2\",\"style\":\"minimal\",\"reason\":\"Quiet story.\"}]}";
        var connector = new PickConnector(reply);
        var auto = styles.Find("auto").Style.Recording(new Dictionary<string, ClipCaptionPick> { ["gone"] = new("glow", "A deleted clip.") });
        var picked = await picker.PickAsync(auto, clips, Library(), styles, connector, "m", "en", TestContext.Current.CancellationToken);
        Assert.Equal(["clip-a", "clip-b"], picked.Style.CaptionPicks.Keys.Order(StringComparer.Ordinal));
        Assert.Equal(new ClipCaptionPick("punch-in", "Punchy hook."), picked.Style.CaptionPicks["clip-a"]);
        Assert.Equal("minimal", picked.Style.CaptionStyleFor("clip-b"));
        Assert.Equal(0, picked.Dropped);
        Assert.Single(connector.Sent);
        Assert.Equal(Effort.XHigh, connector.Sent[0].Effort);

        var fixedStyle = picked.Style.FixingCaptions("marker");
        var silent = new PickConnector(reply);
        var unchanged = await picker.PickAsync(fixedStyle, clips, Library(), styles, silent, "m", "en", TestContext.Current.CancellationToken);
        Assert.True(unchanged.Style.SameAs(fixedStyle));
        Assert.Equal("marker", unchanged.Style.CaptionStyleFor("clip-b"));
        Assert.Empty(silent.Sent);
        Assert.True(fixedStyle.Recording(new Dictionary<string, ClipCaptionPick> { ["clip-a"] = new("glow", "Later.") }).SameAs(fixedStyle));
    }

    [Fact]
    public void AProjectsClipStyleRoundTripsIsOptionalAndRejectsInvalidValues()
    {
        var json = File.ReadAllText(Path.Combine(Root, "fixtures", "projects", "interview-take.voxclip"));
        var project = ProjectSerialization.Deserialize(json);
        Assert.Null(project.ClipStyle);
        Assert.DoesNotContain("clipStyle", ProjectSerialization.Serialize(project), StringComparison.Ordinal);
        var styles = ClipStyleCatalog.Load(Root);
        var chosen = styles.Find("calm").Style.FixingCaptions("glow");
        var saved = ProjectSerialization.Serialize(project with { ClipStyle = chosen });
        var reopened = ProjectSerialization.Deserialize(saved);
        Assert.True(chosen.SameAs(reopened.ClipStyle));

        string Patched(Action<JsonObject> change)
        {
            var root = JsonNode.Parse(saved)!.AsObject();
            change(root["clipStyle"]!.AsObject());
            return root.ToJsonString();
        }
        Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(Patched(style => style["maxLengthSec"] = 2)));
        Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(Patched(style => style["tone"] = "warm")));
        Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(Patched(style => style.Remove("captionPicks"))));
        Assert.True(styles.Initial(null).SameAs(styles.Find("auto").Style));
        Assert.True(styles.Initial(chosen).SameAs(chosen.SettingsDefault));
        Assert.Equal("glow", styles.StyleFor("mine", chosen).Captions);
    }

    [Fact]
    public void SettingsAcceptTheClipStyleDefaultWithoutPicks()
    {
        using var good = JsonDocument.Parse("{\"preset\":\"mine\",\"captions\":\"glow\",\"music\":\"auto\",\"maxLengthSec\":90,\"shapes\":[\"16:9\"],\"rewording\":\"fix-only\"}");
        using var picks = JsonDocument.Parse("{\"preset\":\"mine\",\"captions\":\"glow\",\"music\":\"auto\",\"maxLengthSec\":90,\"shapes\":[\"16:9\"],\"rewording\":\"fix-only\",\"captionPicks\":{}}");
        using var shapes = JsonDocument.Parse("{\"preset\":\"mine\",\"captions\":\"glow\",\"music\":\"auto\",\"maxLengthSec\":90,\"shapes\":[],\"rewording\":\"fix-only\"}");
        Assert.True(SettingsValidation.KnownKey("clipStyle.default"));
        SettingsValidation.Validate(new AppSettings("voxclip-settings/1") { Values = new() { ["clipStyle.default"] = good.RootElement.Clone() } });
        Assert.ThrowsAny<JsonException>(() => SettingsValidation.Validate(new AppSettings("voxclip-settings/1") { Values = new() { ["clipStyle.default"] = picks.RootElement.Clone() } }));
        Assert.ThrowsAny<JsonException>(() => SettingsValidation.Validate(new AppSettings("voxclip-settings/1") { Values = new() { ["clipStyle.default"] = shapes.RootElement.Clone() } }));
    }

    [Fact]
    public void TheCardShowsOnceAChoiceAppliesAFixedStyleAndAPickNeverOverridesIt()
    {
        var styles = ClipStyleCatalog.Load(Root);
        var library = Library().Select(style => style.Id).ToHashSet(StringComparer.Ordinal);
        var json = File.ReadAllText(Path.Combine(Root, "fixtures", "projects", "interview-take.voxclip"));
        var bare = ProjectSerialization.Deserialize(json) with { Captions = ProjectSerialization.Deserialize(json).Captions with { StyleId = "box-highlight" } };
        Assert.False(ClipStyleCard.Shows(bare, false, true));
        ClipRange[] clips = [new("clip-a", bare.Transcript!.Words[0].Id, bare.Transcript.Words[1].Id, "Hook", VoxClip.Core.Domain.Editing.ClipOrigin.Manual, null, null, true),
                             new("clip-b", bare.Transcript.Words[2].Id, bare.Transcript.Words[3].Id, "Story", VoxClip.Core.Domain.Editing.ClipOrigin.Manual, null, null, true)];
        var project = bare with { Edits = bare.Edits with { Clips = clips, ActiveClipId = "clip-b" } };
        Assert.True(ClipStyleCard.Shows(project, false, true));
        Assert.False(ClipStyleCard.Shows(project, false, false));
        Assert.Null(ClipStyleCard.StatusText(project, styles));
        Assert.Equal("auto", ClipStyleCard.Showing(project, styles, null).Preset);

        var auto = ClipStyleCard.Choose(project, styles.Find("auto").Style, library);
        Assert.False(ClipStyleCard.Shows(auto, false, true));
        Assert.True(ClipStyleCard.Shows(auto, true, true));
        Assert.Equal("Style: Auto · ≤60 s · 16:9+9:16", ClipStyleCard.StatusText(auto, styles));
        Assert.Equal("box-highlight", auto.Captions.StyleId);
        var punchy = ClipStyleCard.Choose(auto, styles.Find("punchy").Style, library);
        Assert.Equal(("punch-in", "Style: Punchy talking head · ≤45 s · 9:16"), (punchy.Captions.StyleId, ClipStyleCard.StatusText(punchy, styles)));

        var picked = auto with { ClipStyle = auto.ClipStyle!.Recording(new Dictionary<string, ClipCaptionPick> { ["clip-b"] = new("minimal", "Quiet story.") }) };
        var applied = ClipStyleCard.ApplyPick(picked, library);
        Assert.Equal("minimal", applied?.Captions.StyleId);
        Assert.Null(ClipStyleCard.ApplyPick(applied!, library));
        var chosen = ClipStyleCard.ChooseCaptionStyle(applied!, "marker");
        Assert.Equal(("marker", "marker", "mine"), (chosen.Captions.StyleId, chosen.ClipStyle!.Captions, chosen.ClipStyle.Preset));
        var injected = chosen with { ClipStyle = chosen.ClipStyle with { CaptionPicks = new Dictionary<string, ClipCaptionPick> { ["clip-b"] = new("glow", "Injected.") } } };
        Assert.Null(ClipStyleCard.ApplyPick(injected, library));
        Assert.Throws<VoxClipException>(() => ClipStyleCard.Choose(project, styles.Find("auto").Style with { Shapes = [] }, library));
    }

    private sealed class PickConnector(string reply) : ILlmConnector
    {
        internal List<LlmRequest> Sent { get; } = [];
        public ConnectorId Id => ConnectorId.ClaudeCode;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => Task.FromResult<IReadOnlyList<LlmModel>>([]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(200_000);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            Sent.Add(request);
            return Task.FromResult(new RawCompletion(reply, null, model, new StopKind.Complete(), null, null));
        }
    }
}
