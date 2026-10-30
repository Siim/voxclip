#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Services.LLM;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class ConnectorPreflightTests
{
    [Theory]
    [InlineData("FindClips", false)]
    [InlineData("FindClips", true)]
    [InlineData("Rewrite", false)]
    [InlineData("Rewrite", true)]
    [InlineData("Test", false)]
    [InlineData("Test", true)]
    public async Task EveryActionDetectsBeforeConsentButNeverSendsUntilContinue(string action, bool grant)
    {
        Assert.True(Enum.TryParse<ConnectorConsentAction>(action, out _));
        var statusCalls = 0; var requests = 0;
        Task<ConnectorStatus> Detect(CancellationToken token) { token.ThrowIfCancellationRequested(); statusCalls++; return Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready()); }
        var ct = TestContext.Current.CancellationToken;
        await ConnectorPreflight.ProbeAsync(Detect, ct);
        var status = await ConnectorPreflight.ProbeAsync(Detect, ct);
        Assert.Equal(2, statusCalls);
        var dialog = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = ConnectorPreflight.AuthorizeAsync(status, false, _ => dialog.Task, ct);
        Assert.Equal(0, requests);
        dialog.SetResult(grant);
        if (await pending) requests++;
        Assert.Equal(grant ? 1 : 0, requests);
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
        var rewrite = File.ReadAllText(Path.Combine(root, "Pages/EditorPage.xaml.cs"));
        Assert.Contains("ConnectorConsentAction.Rewrite", rewrite);
        Assert.Contains("if (entry is not null) await ProviderCatalog.ProbeAsync", rewrite);
        Assert.Contains("selectedConnector!, await ProviderCatalog.ProbeAsync(entry, selectedConnector!, token), token)", rewrite);
        var settings = File.ReadAllText(Path.Combine(root, "SettingsWindow.xaml.cs"));
        Assert.Contains("ConnectorConsentAction.Test", settings);
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
