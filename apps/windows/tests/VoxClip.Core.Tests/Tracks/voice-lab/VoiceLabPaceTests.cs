using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabPaceTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;
    private static readonly VoiceLabVoiceChoice Voice = VoiceLabVoiceChoice.Stock("voice123");
    private static JsonNode Document() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/pace-cases.json"))!;
    public static IEnumerable<object[]> Cases() => Document()["cases"]!.AsArray().Select(row => new object[] { row!["case"]!.GetValue<string>() });
    private sealed class Handler : HttpMessageHandler
    {
        internal readonly List<(Uri Uri, string Body)> Requests = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var discovery = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/dialogue-cases.json"))!;
            JsonNode reply;
            if (request.Method == HttpMethod.Get)
                reply = discovery["discovery"]![request.RequestUri!.AbsolutePath == "/v1/models" ? "models" : "voices"]!;
            else
            {
                Requests.Add((request.RequestUri!, await request.Content!.ReadAsStringAsync(ct)));
                reply = discovery["responses"]![0]!["response"]!;
            }
            return new(HttpStatusCode.OK) { RequestMessage = request, Content = new StringContent(reply.ToJsonString(), Encoding.UTF8, "application/json") };
        }
    }
    private static async Task<ElevenLabsVoiceLab> Client(Handler handler)
    {
        var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys("synthetic-key"), handler, ElevenLabsRegion.Default);
        await client.DiscoverModelsAsync(Ct); await client.DiscoverVoicesAsync(Ct);
        return client;
    }
    private static VoiceLabPreparedAction Prepare(ElevenLabsVoiceLab client, string model, VoiceLabSpeechOptions options, Guid id) =>
        client.PrepareSynthesis("Hi", model, Voice, "en", options, id);
    private static Task<VoiceLabAudioResult> Send(ElevenLabsVoiceLab client, string model, VoiceLabSpeechOptions options, Guid id, VoiceLabAuthorization approval) =>
        client.SynthesizeAsync("Hi", model, Voice, "en", options, approval, Ct, id);

    [Theory, MemberData(nameof(Cases))]
    public async Task SharedRequestsAndRefusals(string name)
    {
        var root = Document();
        Assert.Equal("voxclip-voice-lab-pace-cases/1", root["schema"]!.GetValue<string>());
        Assert.Equal(15, root["caseCount"]!.GetValue<int>());
        Assert.Equal(15, root["cases"]!.AsArray().Count);
        var row = root["cases"]!.AsArray().Single(value => value!["case"]!.GetValue<string>() == name)!;
        var handler = new Handler(); var client = await Client(handler); var id = Guid.NewGuid();
        var options = new VoiceLabSpeechOptions(7, Pace: row["pace"]?.GetValue<double>());
        var model = row["modelId"]!.GetValue<string>();
        if (row["expected"]!.GetValue<string>() == "invalidInput")
        {
            Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => Prepare(client, model, options, id)).Kind);
            var approved = client.Approve(Prepare(client, model, new(7), id), true);
            Assert.Equal(VoiceLabErrorKind.InvalidInput, (await Assert.ThrowsAsync<VoiceLabException>(() => Send(client, model, options, id, approved))).Kind);
            Assert.Empty(handler.Requests);
            return;
        }
        var quote = Prepare(client, model, options, id);
        var result = await Send(client, model, options, id, client.Approve(quote, true));
        var request = Assert.Single(handler.Requests);
        Assert.Equal(row["path"]!.GetValue<string>(), request.Uri.AbsolutePath);
        Assert.Equal("?output_format=pcm_24000", request.Uri.Query);
        var expected = row["canonicalJSON"]!.GetValue<string>();
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(expected), JsonNode.Parse(request.Body)));
        if (row["exactBytes"]!.GetValue<bool>()) Assert.Equal(expected, request.Body);
        Assert.Equal(options.Pace ?? 1, quote.Review.Pace);
        Assert.Equal(row["receiptPace"]!.GetValue<double>(), result.Receipt.Pace);
        Assert.Equal(Prepare(client, model, new(7), Guid.NewGuid()).Estimate, quote.Estimate);
    }

    [Theory]
    [InlineData(0.8, 0.9)]
    [InlineData(0.8, 1.0)]
    [InlineData(1.0, 0.8)]
    [InlineData(0.801, 0.802)]
    public async Task ApprovalCannotChangePace(double approvedPace, double changedPace)
    {
        var handler = new Handler(); var client = await Client(handler); var id = Guid.NewGuid();
        var approved = client.Approve(Prepare(client, "eleven_multilingual_v2", new(7, Pace: approvedPace), id), true);
        var error = await Assert.ThrowsAsync<VoiceLabException>(() => Send(client, "eleven_multilingual_v2", new(7, Pace: changedPace), id, approved));
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, error.Kind);
        Assert.Empty(handler.Requests);
    }

    [Theory]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    [InlineData(double.NegativeInfinity)]
    public async Task NonfinitePaceNeverQuotesOrSends(double pace)
    {
        var handler = new Handler(); var client = await Client(handler); var id = Guid.NewGuid();
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => Prepare(client, "eleven_multilingual_v2", new(7, Pace: pace), id)).Kind);
        var approved = client.Approve(Prepare(client, "eleven_multilingual_v2", new(7), id), true);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, (await Assert.ThrowsAsync<VoiceLabException>(() => Send(client, "eleven_multilingual_v2", new(7, Pace: pace), id, approved))).Kind);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task NilAndDefaultShareApprovalWithoutAddingSettings()
    {
        var handler = new Handler(); var client = await Client(handler); var id = Guid.NewGuid();
        var approved = client.Approve(Prepare(client, "eleven_multilingual_v2", new(7), id), true);
        await Send(client, "eleven_multilingual_v2", new(7, Pace: 1), id, approved);
        Assert.Null(JsonNode.Parse(Assert.Single(handler.Requests).Body)!["voice_settings"]!["speed"]);
    }

    [Fact]
    public void ClampIsPureAndOldProjectsKeepOptionalProvenance()
    {
        Assert.Equal(0.7, VoiceLabPace.Clamp(0.5)); Assert.Equal(1.2, VoiceLabPace.Clamp(2));
        Assert.Equal(1, VoiceLabPace.Clamp(double.NaN)); Assert.Equal(0.8, VoiceLabPace.Clamp(0.8));
        Assert.Equal(1.2, VoiceLabPace.Clamp(double.PositiveInfinity)); Assert.Equal(0.7, VoiceLabPace.Clamp(double.NegativeInfinity));
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        var old = project.VoiceLab.Segments[0].Candidates[0].Recipe!;
        Assert.Null(old.Provenance.Pace);
        var provenance = old.Provenance with { Pace = 0.8 };
        var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
        Assert.Equal(0.8, JsonSerializer.Deserialize<VoiceLabProvenance>(JsonSerializer.Serialize(provenance, options), options)!.Pace);
        Assert.DoesNotContain("\"pace\"", JsonSerializer.Serialize(old.Provenance, options));
        var json = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"))!;
        var segment = json["voiceLab"]!["segments"]![0]!;
        segment["provenance"]!["pace"] = 0.8;
        segment["candidates"]![0]!["recipe"]!["provenance"]!["pace"] = 0.8;
        var decoded = ProjectSerialization.Deserialize(json.ToJsonString());
        var roundTrip = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(decoded));
        Assert.Equal(0.8, roundTrip.VoiceLab.Segments[0].Provenance.Pace);
        Assert.Equal(0.8, roundTrip.VoiceLab.Segments[0].Candidates[0].Recipe!.Provenance.Pace);
    }

    [Theory]
    [InlineData("0.5")]
    [InlineData("1.3")]
    [InlineData("null")]
    [InlineData("\"0.8\"")]
    public void ProjectRefusesInvalidPaceInSegmentAndRecipe(string value)
    {
        foreach (var recipe in new[] { false, true })
        {
            var json = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"))!;
            var segment = json["voiceLab"]!["segments"]![0]!;
            var provenance = recipe ? segment["candidates"]![0]!["recipe"]!["provenance"]! : segment["provenance"]!;
            provenance["pace"] = JsonNode.Parse(value);
            Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(json.ToJsonString()));
        }
    }
}
