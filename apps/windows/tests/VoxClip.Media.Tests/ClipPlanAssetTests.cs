using System.Text.Json;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Services.Music;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class ClipPlanAssetTests : IDisposable
{
    private const string Project = "57aab2ac-6116-4552-8d0e-4f569ced5d67";
    private readonly string root = Directory.CreateTempSubdirectory("voxclip-plan-assets-").FullName;
    private const string Openverse = "fixtures/clip-effects/openverse-sound.json";
    private const string Fal = "fixtures/clip-effects/fal-illustration.json";

    private sealed class FixtureHttp(Action? completed = null) : IMusicHttp
    {
        internal List<Uri> Requests { get; } = [];

        public Task<MusicHttpReply> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            var uri = request.RequestUri!;
            Requests.Add(uri);
            var (file, content) = (uri.Host, uri.AbsolutePath) switch
            {
                ("api.openverse.org", _) => (Openverse, "application/json"),
                ("audio.example.test", "/pop.wav") => ("data/sfx/pop.wav", "audio/wav"),
                ("fal.run", "/fal-ai/flux/schnell") => (Fal, "application/json"),
                _ => throw new InvalidOperationException("Unexpected fixture request: " + uri)
            };
            var reply = new MusicHttpReply(200, File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, file)), content);
            completed?.Invoke();
            return Task.FromResult(reply);
        }
    }

    [Fact]
    public void OpenverseSoundRequiresAnAllowedLicenseAndCreditsForBy()
    {
        var candidates = OpenverseMusicClient.Parse(File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, Openverse)), sound: true);
        Assert.Equal([MusicLicense.Cc0, MusicLicense.By, MusicLicense.Pdm], candidates.Select(candidate => candidate.License));
        Assert.Equal("Pop by Fixture creator (CC BY 4.0)", candidates.Single(candidate => candidate.License == MusicLicense.By).Attribution);
    }

    [Fact, Trait("Category", "RequiresFFmpeg")]
    public async Task FindsOnlyALicensedSoundThatFitsAndKeepsItsCredit()
    {
        await NativeTest.RequireAsync();
        var http = new FixtureHttp();
        var asset = new ClipAutopilotAction.Asset("sound", "soundEffect", "clip", 1, 2, "pop");
        var placed = await new ClipPlanAssets(http).SoundAsync(asset, Project, root, TestContext.Current.CancellationToken);
        var effect = ClipEffect.Parse(Assert.IsType<JsonElement>(placed));
        Assert.Equal("by", effect.Sound?.License);
        Assert.Equal("https://audio.example.test/credits/pop", effect.Sound?.SourceUrl);
        Assert.Equal(-15, effect.GainDb);
        Assert.Equal(2, http.Requests.Count);
        Assert.DoesNotContain("category=", http.Requests[0].Query);
        Assert.Equal("/pop.wav", http.Requests[1].AbsolutePath);
    }

    [Fact]
    public async Task SavesThePaidImageBeforePlacementAndReusesItWithoutARequest()
    {
        var http = new FixtureHttp();
        var client = new ClipPlanAssets(http);
        var quote = ClipIllustrationQuote.Load(FixtureLoader.SharedRoot);
        var asset = new ClipAutopilotAction.Asset("image", "illustration", "clip", 1, 2, "a paper boat");
        Assert.Null(client.SavedIllustration(asset, Project, root, quote));
        var placed = await client.IllustrationAsync(asset, Project, root, quote, "offline-fixture", TestContext.Current.CancellationToken);
        var file = Path.Combine(ClipEffectsRenderInput.ImageRoot(root), placed.GetProperty("imageFile").GetString()!);
        Assert.Equal(new byte[] { 137, 80, 78, 71 }, (await File.ReadAllBytesAsync(file, TestContext.Current.CancellationToken))[..4]);
        Assert.Equal(placed.GetRawText(), client.SavedIllustration(asset, Project, root, quote)?.GetRawText());
        Assert.Single(http.Requests);
    }

    public void Dispose() => Directory.Delete(root, true);

    [Fact]
    public async Task CancelledIllustrationDoesNotSendAPaidRequest()
    {
        var http = new FixtureHttp();
        var client = new ClipPlanAssets(http);
        var quote = ClipIllustrationQuote.Load(FixtureLoader.SharedRoot);
        var asset = new ClipAutopilotAction.Asset("image", "illustration", "clip", 1, 2, "a paper boat");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            client.IllustrationAsync(asset, Project, root, quote, "offline-fixture", new CancellationToken(true)));
        Assert.Empty(http.Requests);
        Assert.Null(client.SavedIllustration(asset, Project, root, quote));
    }

    [Fact]
    public async Task StoppingAsTheIllustrationArrivesStillKeepsThePaidImage()
    {
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var http = new FixtureHttp(stop.Cancel);
        var client = new ClipPlanAssets(http);
        var quote = ClipIllustrationQuote.Load(FixtureLoader.SharedRoot);
        var asset = new ClipAutopilotAction.Asset("image", "illustration", "clip", 1, 2, "a paper boat");
        var completed = await client.IllustrationAsync(asset, Project, root, quote, "offline-fixture", stop.Token);
        Assert.True(stop.IsCancellationRequested);
        Assert.Equal(completed.GetRawText(), client.SavedIllustration(asset, Project, root, quote)?.GetRawText());
        Assert.Single(http.Requests);
    }
}
