#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Services.LLM;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class ConnectorPreflightTests
{
    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task RealFindAndTestPipelinesNeverSendUntilContinue(bool test, bool grant)
    {
        var ct = TestContext.Current.CancellationToken;
        var fake = new RecordingConnector();
        var consent = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var catalog = LlmCatalog.Load(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!);
        var keys = new NoKeys();
        var runner = new LlmRunner(keys, catalog, new VoxClip.Core.Domain.Shared.Redactor());
        Task pending;
        if (test) pending = ConnectorPreflight.TestAsync(runner, fake, "default", _ => consent.Task, ct);
        else
        {
            var project = VoxClip.Core.Domain.Shared.ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!, "fixtures/projects/interview-take.voxclip")));
            var finder = new ClipFinder(catalog, keys, new VoxClip.Core.Domain.Shared.Redactor(), _ => fake);
            var request = new ClipFinderRequest(project.Transcript!.Words, new Dictionary<string, string>(), new HashSet<string>(), VoxClip.Core.Domain.Clips.ClipPreset.Best, null, "en", fake.Id, "default");
            pending = ConnectorPreflight.FindAsync(finder, request, _ => consent.Task, ct);
        }
        Assert.False(pending.IsCompleted);
        Assert.Equal(0, fake.Sends);
        consent.SetResult(grant);
        await pending;
        Assert.Equal(grant ? 1 : 0, fake.Sends);
    }

    private sealed class NoKeys : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => Task.FromResult<string?>(null);
    }
    private sealed class RecordingConnector : ILlmConnector
    {
        internal int Sends { get; private set; }
        public ConnectorId Id => ConnectorId.Codex;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => Task.FromResult<IReadOnlyList<LlmModel>>([]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(32768);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            Sends++;
            var body = request.Feature == LlmFeature.Test
                ? new System.Text.Json.Nodes.JsonObject { ["ok"] = true, ["echo"] = "voxclip" }
                : new System.Text.Json.Nodes.JsonObject { ["clips"] = new System.Text.Json.Nodes.JsonArray() };
            return Task.FromResult(new RawCompletion(null, body, model, new StopKind.Complete(), null, "recording"));
        }
    }

    [Fact]
    public async Task NotReadyNeverPromptsAndCancelledConsentNeverAuthorizes()
    {
        var ct = TestContext.Current.CancellationToken;
        Assert.False(await ConnectorPreflight.AuthorizeAsync(new ConnectorStatus.CliSignedOut(), false,
            _ => throw new InvalidOperationException("An unready connector must not prompt"), ct));
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var dialog = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = ConnectorPreflight.AuthorizeAsync(new ConnectorStatus.Ready(), false, _ => dialog.Task, cancellation.Token);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        Assert.False(dialog.Task.IsCompleted);
        Assert.True(await ConnectorPreflight.AuthorizeAsync(new ConnectorStatus.Ready(), true,
            _ => throw new InvalidOperationException("A recorded answer must not prompt again"), ct));
    }

    public static IEnumerable<object[]> Sentences()
    {
        foreach (var provider in new[] { (ConnectorId.OpenAI, "OpenAI"), (ConnectorId.Anthropic, "Anthropic"), (ConnectorId.Xai, "xAI"), (ConnectorId.Gemini, "Gemini") })
        {
            yield return new object[] { "FindClips", provider.Item1, provider.Item2, "", false, $"Find clips sends this project's transcript (17 words, no audio or video) to {provider.Item2} using your API key." };
            yield return new object[] { "Rewrite", provider.Item1, provider.Item2, "", false, $"Rewrite sends these 17 words (no audio or video) to {provider.Item2} using your API key." };
            yield return new object[] { "Test", provider.Item1, provider.Item2, "", false, $"Test sends a short test request to {provider.Item2} using your API key. Nothing from your projects is sent." };
        }
        yield return new object[] { "FindClips", ConnectorId.ClaudeCode, "Claude Code", "oauth", false, "VoxClip will run your installed Claude Code with your own sign-in. The transcript is sent to Anthropic and counts toward your Claude plan's usage." };
        yield return new object[] { "Rewrite", ConnectorId.ClaudeCode, "Claude Code", "oauth", false, "VoxClip will run your installed Claude Code with your own sign-in. These words are sent to Anthropic and count toward your Claude plan's usage." };
        yield return new object[] { "Test", ConnectorId.ClaudeCode, "Claude Code", "oauth", false, "VoxClip will run your installed Claude Code with your own sign-in. A short test request is sent to Anthropic and counts toward your Claude plan's usage." };
        yield return new object[] { "FindClips", ConnectorId.ClaudeCode, "Claude Code", "api_key", true, "VoxClip will run your installed Claude Code with your own sign-in. The transcript is sent to Anthropic and billed to the API key Claude Code is signed in with." };
        yield return new object[] { "Rewrite", ConnectorId.ClaudeCode, "Claude Code", "api_key", true, "VoxClip will run your installed Claude Code with your own sign-in. These words are sent to Anthropic and billed to the API key Claude Code is signed in with." };
        yield return new object[] { "Test", ConnectorId.ClaudeCode, "Claude Code", "api_key", true, "VoxClip will run your installed Claude Code with your own sign-in. A short test request is sent to Anthropic and billed to the API key Claude Code is signed in with." };
        yield return new object[] { "FindClips", ConnectorId.Codex, "Codex", "chatgpt", false, "VoxClip will run your installed Codex with your own sign-in. The transcript is sent to OpenAI and counts toward your ChatGPT plan's usage." };
        yield return new object[] { "Rewrite", ConnectorId.Codex, "Codex", "chatgpt", false, "VoxClip will run your installed Codex with your own sign-in. These words are sent to OpenAI and count toward your ChatGPT plan's usage." };
        yield return new object[] { "Test", ConnectorId.Codex, "Codex", "chatgpt", false, "VoxClip will run your installed Codex with your own sign-in. A short test request is sent to OpenAI and counts toward your ChatGPT plan's usage." };
        yield return new object[] { "FindClips", ConnectorId.Codex, "Codex", "apiKey", true, "VoxClip will run your installed Codex with your own sign-in. The transcript is sent to OpenAI and billed to the API key Codex is signed in with." };
        yield return new object[] { "Rewrite", ConnectorId.Codex, "Codex", "apiKey", true, "VoxClip will run your installed Codex with your own sign-in. These words are sent to OpenAI and billed to the API key Codex is signed in with." };
        yield return new object[] { "Test", ConnectorId.Codex, "Codex", "apiKey", true, "VoxClip will run your installed Codex with your own sign-in. A short test request is sent to OpenAI and billed to the API key Codex is signed in with." };
    }

    [Theory]
    [MemberData(nameof(Sentences))]
    public void EveryActionAndBillingMethodUsesTheSpecSentence(string action, ConnectorId id, string label, string method, bool key, string expected)
    {
        var detection = method.Length == 0 ? null : new CliDetectionInfo("fake", "1.0", method, key);
        Assert.Equal(expected, ConnectorConsent.Text(Enum.Parse<ConnectorConsentAction>(action), id, label, 17, detection));
    }

    [Theory]
    [InlineData("claude.ai", true, false)]
    [InlineData("oauth_token", true, false)]
    [InlineData("OAuth-Token", true, false)]
    [InlineData("api_key", true, true)]
    [InlineData("api_key_helper", true, true)]
    [InlineData("none", false, false)]
    [InlineData("third_party", false, false)]
    public void ClaudeDocumentedMethodsUseKnownBillingOnly(string method, bool known, bool key)
    {
        foreach (var action in Enum.GetValues<ConnectorConsentAction>())
        {
            var text = ConnectorConsent.Text(action, ConnectorId.ClaudeCode, "Claude Code", 17, new("fake", "1", method, key));
            if (!known) Assert.Null(text);
            else Assert.Contains(key ? "billed to the API key" : "toward your Claude plan's usage", text);
        }
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public void UnknownCliSignInCannotProduceAnyConsentSheet(ConnectorId id)
    {
        foreach (var action in Enum.GetValues<ConnectorConsentAction>())
        {
            Assert.Null(ConnectorConsent.Text(action, id, "CLI", 17, null));
            Assert.Null(ConnectorConsent.Text(action, id, "CLI", 17, new("fake", "1", "unknown", false)));
        }
    }

    [Fact]
    public void OpeningRetryAndAllThreeRequestsUseExplicitDetectionAndConsentRoutes()
    {
        var root = Path.Combine(Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!, "apps/windows/src/VoxClip.App");
        var find = File.ReadAllText(Path.Combine(root, "Controls/FindClipsFlyout.cs"));
        Assert.Equal(2, find.Split("ProviderCatalog.ProbeAsync").Length - 1);
        Assert.Contains("internal Task RetryAsync() => FindAsync()", find);
        Assert.Contains("ConnectorConsentAction.FindClips", find);
        Assert.Contains("Snap: App.Services.Get(\"llm.clips.snapToLines\", true)", find);
        var rewrite = File.ReadAllText(Path.Combine(root, "Pages/EditorPage.xaml.cs"));
        Assert.Contains("ConnectorConsentAction.Rewrite", rewrite);
        Assert.Contains("if (entry is not null) await ProviderCatalog.ProbeAsync", rewrite);
        Assert.Contains("selectedConnector!, await ProviderCatalog.ProbeAsync(entry, selectedConnector!, token), token)", rewrite);
        var settings = File.ReadAllText(Path.Combine(root, "SettingsWindow.xaml.cs"));
        Assert.Contains("ConnectorConsentAction.Test", settings);
        Assert.Contains("Snap clip edges to sentence boundaries", settings);
        Assert.Contains("var connectorStatus = await ProviderCatalog.ProbeAsync(entry, selectedConnector, lifetime.Token)", settings);
        Assert.Contains("var status = await ProviderCatalog.ProbeAsync(chosen, selectedConnector, ct)", find);
        var home = File.ReadAllText(Path.Combine(root, "Pages/HomePage.xaml.cs"));
        Assert.DoesNotContain("GetStatusAsync", home);
        Assert.Contains("detect ? await ProviderCatalog.ProbeAsync", home);
        Assert.Contains("ProviderCatalog.LastStatus(entry)", home);
        var catalog = File.ReadAllText(Path.Combine(root, "Services/ProviderCatalog.cs"));
        Assert.DoesNotContain("Timer", catalog);
        Assert.DoesNotContain("Task.Run", catalog);
        Assert.DoesNotContain("Task.Delay", catalog);
        Assert.Equal(1, home.Split("RefreshAiAsync(true)").Length - 1);
        Assert.Contains("if (callout?.Action == \"Check again\") await RefreshAiAsync(true)", home);
        var callers = Directory.EnumerateFiles(root, "*.cs", SearchOption.AllDirectories)
            .Where(path => !path.Contains(Path.DirectorySeparatorChar + "obj" + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            .Where(path => File.ReadAllText(path).Contains("ProviderCatalog.ProbeAsync", StringComparison.Ordinal))
            .Select(path => Path.GetRelativePath(root, path).Replace('\\', '/')).Order().ToArray();
        Assert.Equal(new[] { "Controls/FindClipsFlyout.cs", "Pages/EditorPage.xaml.cs", "Pages/HomePage.xaml.cs", "SettingsWindow.xaml.cs" }, callers);
    }
}
#endif
