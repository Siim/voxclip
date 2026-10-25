using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class ReviewRegressionTests
{
    private const string ModelId = "whisper-base.en-q5_1";
    private const string OtherId = "silero-vad-v6.2.0";
    private static readonly byte[] Contents = Encoding.UTF8.GetBytes("review model contents");

    [Fact]
    public async Task CancelledProgressCompletionDoesNotFlush()
    {
        var captured = new CaptureProgress<int>();
        var progress = new SpeechProgress<int>(captured);
        progress.Report(0);
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => progress.CompleteAsync(100, cancel.Token));
        Assert.Equal(new[] { 0 }, captured.Values);
    }

    [Fact]
    public async Task PendingConsentHoldsNoModelOrDownloadLock()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents, dependencies: true);
        using var http = new HttpClient(new StubHttp((_, _) => Task.FromResult(StubHttp.Json("unused"))));
        var pending = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var store = new ModelStore(catalog, files.Root, http, (_, _, _) => { entered.SetResult(); return pending.Task; });
        var install = store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
            var otherStore = new ModelStore(catalog, files.Root, http);
            Assert.False(await otherStore.VerifyAsync(ModelId, null, TestContext.Current.CancellationToken).WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken));
            Assert.Empty(await otherStore.ListInstalledAsync(TestContext.Current.CancellationToken).WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken));
            await otherStore.RemoveAsync(OtherId, TestContext.Current.CancellationToken).WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
        }
        finally { pending.TrySetResult(false); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => install); }
    }

    [Fact]
    public async Task DownloadOfAnotherModelDoesNotBlockVerifyListOrRemove()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents, dependencies: true);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new StubHttp(async (request, ct) =>
        {
            if (request.RequestUri!.AbsolutePath.Contains("ggml-base.en", StringComparison.Ordinal))
            { entered.TrySetResult(); await release.Task.WaitAsync(ct); }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) };
        });
        using var http = new HttpClient(handler);
        var store = new ModelStore(catalog, files.Root, http, (_, _, _) => Task.FromResult(true));
        await store.InstallAsync(OtherId, null, TestContext.Current.CancellationToken);
        var install = store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
            var observer = new ModelStore(catalog, files.Root, http);
            Assert.True(await observer.VerifyAsync(OtherId, null, TestContext.Current.CancellationToken).WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken));
            Assert.Single(await observer.ListInstalledAsync(TestContext.Current.CancellationToken).WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken));
            await observer.RemoveAsync(OtherId, TestContext.Current.CancellationToken).WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
            Assert.Empty(await observer.ListInstalledAsync(TestContext.Current.CancellationToken));
        }
        finally { release.TrySetResult(); await install; }
    }

    [Fact]
    public async Task ConcurrentInstallsOfSameModelTransferOnlyOnce()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new StubHttp(async (_, ct) =>
        {
            entered.TrySetResult(); await release.Task.WaitAsync(ct);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) };
        });
        using var http = new HttpClient(handler);
        var confirmations = 0;
        Task<bool> Confirm(TranscriptionModel model, IReadOnlyList<TranscriptionModel> dependencies, CancellationToken ct)
        {
            Interlocked.Increment(ref confirmations);
            return Task.FromResult(true);
        }
        var first = new ModelStore(catalog, files.Root, http, Confirm);
        var second = new ModelStore(catalog, files.Root, http, Confirm);
        var firstInstall = first.InstallAsync(ModelId, null, TestContext.Current.CancellationToken);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
        var secondInstall = second.InstallAsync(ModelId, null, TestContext.Current.CancellationToken);
        try { Assert.False(secondInstall.IsCompleted); Assert.Equal(1, handler.Calls); Assert.Equal(1, confirmations); }
        finally { release.TrySetResult(); await Task.WhenAll(firstInstall, secondInstall); }
        Assert.Equal(1, handler.Calls);
        Assert.Equal(1, confirmations);
    }

    [Fact]
    public async Task InFlightConsentIsSharedAndCancelledWaiterDoesNotCancelOwner()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var handler = new StubHttp((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) }));
        using var http = new HttpClient(handler);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var consent = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var confirmations = 0;
        var owner = new ModelStore(catalog, files.Root, http, (_, _, _) => { confirmations++; entered.TrySetResult(); return consent.Task; });
        var waiter = new ModelStore(catalog, files.Root, http, (_, _, _) => throw new InvalidOperationException("Consent must be shared."));
        var install = owner.InstallAsync(ModelId, null, TestContext.Current.CancellationToken);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
            using var cancel = new CancellationTokenSource();
            var waiting = waiter.InstallAsync(ModelId, null, cancel.Token);
            cancel.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => waiting);
            Assert.False(install.IsCompleted);
            Assert.Equal(1, confirmations);
        }
        finally { consent.TrySetResult(true); await install; }
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task DeclinedInstallLeavesNoInFlightEntry()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var handler = new StubHttp((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) }));
        using var http = new HttpClient(handler);
        var confirmations = 0;
        var store = new ModelStore(catalog, files.Root, http, (_, _, _) => Task.FromResult(++confirmations > 1));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.True((await store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken)).Verified);
        Assert.Equal(2, confirmations);
        Assert.Equal(1, handler.Calls);
    }

    [Theory]
    [InlineData(false, "Update available")]
    [InlineData(true, "Broken")]
    public async Task KeepsStaleAndBrokenInstallsVisible(bool truncate, string expected)
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var http = new HttpClient(new StubHttp((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) })));
        var store = new ModelStore(catalog, files.Root, http, (_, _, _) => Task.FromResult(true));
        var installed = await store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken);
        if (truncate)
        {
            var model = (await catalog.GetModelAsync(ModelId, TestContext.Current.CancellationToken))!;
            await File.WriteAllBytesAsync(Path.Combine(installed.Directory, model.Files[0].Name), [], TestContext.Current.CancellationToken);
        }
        else
        {
            var path = Path.Combine(files.Root, "catalog.json");
            var data = JsonNode.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken))!;
            data["models"]!.AsArray().Single(model => model!["id"]!.GetValue<string>() == ModelId)!["files"]![0]!["sha256"] = new string('0', 64);
            await File.WriteAllTextAsync(path, data.ToJsonString(), TestContext.Current.CancellationToken);
            store = new ModelStore(ModelCatalog.FromFile(path), files.Root, http);
        }
        var invalid = Assert.Single(await store.ListInstalledAsync(TestContext.Current.CancellationToken));
        Assert.False(invalid.Verified);
        Assert.Equal(expected, invalid.Status);
        await store.RemoveAsync(ModelId, TestContext.Current.CancellationToken);
        Assert.False(Directory.Exists(installed.Directory));
    }

    [Theory]
    [InlineData("apple")]
    [InlineData("ask")]
    [InlineData("elevenlabs")]
    public async Task WindowsModesRetainTheirLocalRoute(string mode)
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        var router = new TranscriptionRouter(catalog, new ModelStore(catalog, files.Root));
        var decision = await router.RouteAsync(mode, new LanguageChoice.Forced("en"), 4L << 30, false, null, TestContext.Current.CancellationToken);
        var local = mode == "apple" ? decision : Assert.IsType<RoutingDecision>(decision.Alternative);
        Assert.Contains("whisper-small.en-q5_1", Assert.IsType<Readiness.NeedsModels>(local.Readiness).Ids);
        Assert.Null(decision.Plan);
        Assert.False(decision.OfferCloud);
        if (mode == "elevenlabs") Assert.IsType<Readiness.NeedsKey>(decision.Readiness);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RouterHonorsCatalogueDtwDefault(bool dtw)
    {
        using var files = new SpeechFiles();
        await files.CatalogueAsync(Contents, "whisper-small.en-q5_1");
        var path = Path.Combine(files.Root, "catalog.json");
        var data = JsonNode.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken))!;
        data["models"]!.AsArray().Single(model => model!["id"]!.GetValue<string>() == "whisper-small.en-q5_1")!["whisper"]!["dtwDefault"] = dtw;
        await File.WriteAllTextAsync(path, data.ToJsonString(), TestContext.Current.CancellationToken);
        var catalog = ModelCatalog.FromFile(path);
        using var http = new HttpClient(new StubHttp((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) })));
        var store = new ModelStore(catalog, files.Root, http, (_, _, _) => Task.FromResult(true));
        await store.InstallAsync("whisper-small.en-q5_1", null, TestContext.Current.CancellationToken);
        var decision = await new TranscriptionRouter(catalog, store).RouteAsync("local", new LanguageChoice.Forced("en"), 16L << 30,
            false, null, TestContext.Current.CancellationToken);
        Assert.Equal(dtw, decision.Plan!.Options.Dtw);
    }
}
