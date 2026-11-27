using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCoreNative;

public sealed class HarnessChatToolsTests
{
    [Fact]
    public async Task OffersQuoteTheSameLocalPricesAsProposals()
    {
        var ct = TestContext.Current.CancellationToken;
        using var fixture = FixtureLoader.ReadJson("fixtures/agent-chat/tool-cases.json");
        var vector = fixture.RootElement;
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText(vector.GetProperty("project").GetString()!));
        var proposal = await HarnessTools.Call(HarnessTool.ProposeTimeline,
            vector.GetProperty("savedCalls").GetProperty("propose_timeline"), project, FixtureLoader.SharedRoot, ct: ct);
        var prices = Wire(proposal).GetProperty("pricedActions");
        var ids = new HashSet<Guid>();
        var index = 0;
        foreach (var offer in vector.GetProperty("offers").EnumerateArray())
        {
            var result = await HarnessTools.Call(HarnessTool.Offer, offer.GetProperty("arguments"), project, FixtureLoader.SharedRoot, ct: ct);
            var fields = Wire(result);
            Assert.Equal(offer.GetProperty("quote").GetString(), fields.GetProperty("quote").GetString());
            Assert.Equal(prices[index++].GetProperty("price").GetString(), fields.GetProperty("quote").GetString());
            Assert.True(ids.Add(fields.GetProperty("offerId").GetGuid()));
            Assert.Null(result.Proposal);
        }
        await Assert.ThrowsAsync<HarnessException>(() => HarnessTools.Call(HarnessTool.Offer,
            JsonElement.Parse("""{"kind":"generateMusic","target":"clip-2f1c","approved":true}"""), project, FixtureLoader.SharedRoot, ct: ct));
    }

    [Fact]
    public async Task LiveProposalReturnsRevisionAndLabelAndLinkDoesNotEdit()
    {
        var ct = TestContext.Current.CancellationToken;
        using var fixture = FixtureLoader.ReadJson("fixtures/agent-chat/tool-cases.json");
        var vector = fixture.RootElement;
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText(vector.GetProperty("project").GetString()!));
        var timeline = vector.GetProperty("savedCalls").GetProperty("propose_timeline");
        var revision = vector.GetProperty("revision");
        var labelled = JsonObject.Create(timeline)!;
        labelled["label"] = revision.GetProperty("label").GetString();
        var input = new JsonObject { ["timelines"] = new JsonArray(labelled), ["revises"] = revision.GetProperty("revises").GetString() };
        var proposal = await HarnessTools.Call(HarnessTool.ProposeTimeline, JsonElement.Parse(input.ToJsonString()), project, FixtureLoader.SharedRoot, ct: ct);
        var fields = Wire(proposal);
        Assert.Equal(revision.GetProperty("revises").GetString(), fields.GetProperty("revises").GetString());
        Assert.Equal(revision.GetProperty("label").GetString(), Assert.Single(fields.GetProperty("labels").EnumerateArray()).GetString());
        Assert.True(JsonElement.DeepEquals(timeline, Assert.Single(fields.GetProperty("proposal").GetProperty("timelines").EnumerateArray())));
        var point = vector.GetProperty("pointTo");
        var link = await HarnessTools.Call(HarnessTool.PointTo, point.GetProperty("arguments"), project, FixtureLoader.SharedRoot, ct: ct);
        Assert.Equal(point.GetProperty("label").GetString(), Wire(link).GetProperty("label").GetString());
        Assert.Null(link.Proposal);
    }

    [Fact]
    public async Task FolderSearchReturnsAnOpaqueIdUsableInATimeline()
    {
        var ct = TestContext.Current.CancellationToken;
        using var fixture = FixtureLoader.ReadJson("fixtures/agent-chat/tool-cases.json");
        var original = ProjectSerialization.Deserialize(FixtureLoader.ReadText(fixture.RootElement.GetProperty("project").GetString()!));
        var existing = new ProjectMusic("existing", null, new($"{original.Id}/music-existing.wav", new('b', 64), 15),
            MusicSource.File, "Existing", null, MusicLicense.Own, null, null, null, -18, true, 0, 0, 0);
        var project = MusicProject.Setting(existing, null, original);
        var directory = Directory.CreateTempSubdirectory("voxclip-harness-music-");
        try
        {
            await File.WriteAllBytesAsync(Path.Combine(directory.FullName, "Calm Piano.wav"), Array.Empty<byte>(), ct);
            var music = new HarnessMusicLibrary(folder: directory.FullName, materialize: (candidate, projectId, _) =>
                Task.FromResult(new ProjectMusic(candidate.Id, null, new($"{projectId}/music-calm.wav", new('a', 64), 15),
                    candidate.Source, candidate.Title, null, candidate.License, null, null, null, -18, true, 0, 0, 0)));
            var search = await HarnessTools.Call(HarnessTool.FindMusic, JsonElement.Parse("""{"mood":"calm piano","lengthSeconds":10}"""),
                project, FixtureLoader.SharedRoot, musicLibrary: music, ct: ct);
            var track = Assert.Single(Wire(search).GetProperty("tracks").EnumerateArray());
            var id = track.GetProperty("id").GetString()!;
            Assert.Equal("Calm Piano", track.GetProperty("title").GetString());
            Assert.DoesNotContain(directory.FullName, id);
            var input = JsonSerializer.SerializeToElement(new { clipId = "clip-2f1c", reason = "Use the free track.", music = new { trackId = id } });
            var proposal = await HarnessTools.Call(HarnessTool.ProposeTimeline, input, project, FixtureLoader.SharedRoot, musicLibrary: music, ct: ct);
            Assert.Equal(id, Assert.Single(proposal.PreparedMusic!).Id);
            Assert.Empty(Wire(proposal).GetProperty("pricedActions").EnumerateArray());
            var review = HarnessProposal.Read(Wire(proposal).GetProperty("proposal"))
                .Review(project, FixtureLoader.SharedRoot, preparedMusic: proposal.PreparedMusic);
            Assert.Equal(existing, MusicProject.Entry(null, review.Project));
            Assert.Equal(id, MusicProject.Entry("clip-2f1c", review.Project)?.Id);
        }
        finally { directory.Delete(recursive: true); }
    }

    private static JsonElement Wire(HarnessResult result) => JsonSerializer.SerializeToElement(result.Fields, JsonSerializerOptions.Web);
}
