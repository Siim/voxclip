#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Services.LLM;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class ConnectorPreflightTests
{
    [Theory]
    [InlineData(ConnectorId.Codex)]
    [InlineData(ConnectorId.OpenAI)]
    public async Task OpeningAnUngrantedConnectorNeverProbesButAGrantedOneProbesOnce(ConnectorId id)
    {
        var fake = new StatusConnector(id);
        var ct = TestContext.Current.CancellationToken;
        Assert.Null(await ConnectorPreflight.ProbeAsync(false, null, fake.GetStatusAsync, ct));
        Assert.Equal(0, fake.StatusCalls);
        Assert.IsType<ConnectorStatus.Ready>(await ConnectorPreflight.ProbeAsync(true, null, fake.GetStatusAsync, ct));
        Assert.Equal(1, fake.StatusCalls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RunAndRetryProbeOnlyAfterConsentCompletes(bool grant)
    {
        var fake = new StatusConnector(ConnectorId.Codex);
        var dialog = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = ConnectorPreflight.ProbeAsync(false, _ => dialog.Task, fake.GetStatusAsync, TestContext.Current.CancellationToken);
        Assert.Equal(0, fake.StatusCalls);
        dialog.SetResult(grant);
        Assert.Equal(grant, await pending is ConnectorStatus.Ready);
        Assert.Equal(grant ? 1 : 0, fake.StatusCalls);
    }

    [Fact]
    public async Task LocalPreflightKeepsItsUnpromptedStatusAndCancelledConsentNeverProbes()
    {
        var fake = new StatusConnector(ConnectorId.Ollama);
        var ct = TestContext.Current.CancellationToken;
        Assert.IsType<ConnectorStatus.Ready>(await ConnectorPreflight.ProbeAsync(true,
            _ => throw new InvalidOperationException("Local must not prompt"), fake.GetStatusAsync, ct));
        Assert.Equal(1, fake.StatusCalls);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var dialog = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = ConnectorPreflight.ProbeAsync(false, _ => dialog.Task, fake.GetStatusAsync, cancellation.Token);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        Assert.False(dialog.Task.IsCompleted);
        Assert.Equal(1, fake.StatusCalls);
    }

    [Fact]
    public void FindOpeningAndRetryUseTheConsentGuardAndSettingsKeepsItsOwnPrompt()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var find = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/FindClipsFlyout.cs"));
        Assert.Equal(2, find.Split("ConnectorPreflight.ProbeAsync").Length - 1);
        Assert.Contains("internal Task RetryAsync() => FindAsync()", find);
        Assert.Contains("await FindWithAsync(chosen)", find);
        var settings = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/SettingsWindow.xaml.cs"));
        Assert.Contains("ProviderCatalog.ConsentAsync", settings);
    }

    private sealed class StatusConnector(ConnectorId id) : ILlmConnector
    {
        public ConnectorId Id => id;
        internal int StatusCalls { get; private set; }
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) { StatusCalls++; return Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready()); }
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => throw new InvalidOperationException();
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => throw new InvalidOperationException();
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct) => throw new InvalidOperationException();
    }
}
#endif
