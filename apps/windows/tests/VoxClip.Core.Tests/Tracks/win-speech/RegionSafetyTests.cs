using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Settings;
using VoxClip.Core.Services.Speech;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class RegionSafetyTests
{
    [Fact]
    public void AdaptersOwnDistinctCookieFreeNonRedirectingHandlers()
    {
        using var first = new ElevenLabsTranscriber(new TestKeys());
        using var second = new ElevenLabsTranscriber(new TestKeys());
        Assert.NotSame(first.OwnedHandler, second.OwnedHandler);
        foreach (var handler in new[] { first.OwnedHandler, second.OwnedHandler })
        {
            Assert.NotNull(handler);
            Assert.False(handler.AllowAutoRedirect);
            Assert.False(handler.UseCookies);
            Assert.True(handler.UseProxy);
            Assert.Equal(TimeSpan.FromSeconds(30), handler.ConnectTimeout);
        }
    }

    [Theory]
    [InlineData(ElevenLabsRegion.Default, "api.elevenlabs.io")]
    [InlineData(ElevenLabsRegion.Us, "api.us.elevenlabs.io")]
    [InlineData(ElevenLabsRegion.Eu, "api.eu.residency.elevenlabs.io")]
    [InlineData(ElevenLabsRegion.In, "api.in.residency.elevenlabs.io")]
    [InlineData(ElevenLabsRegion.Sg, "api.sg.residency.elevenlabs.io")]
    public async Task EachPublicRegionUploadsOnlyToItsFixedHost(ElevenLabsRegion region, string host) =>
        await UploadOverLoopbackTlsAsync(() => new(new TestKeys(), region), host, false);

    [Theory]
    [InlineData(ElevenLabsRegion.Default, "api.elevenlabs.io")]
    [InlineData(ElevenLabsRegion.Us, "api.us.elevenlabs.io")]
    [InlineData(ElevenLabsRegion.Eu, "api.eu.residency.elevenlabs.io")]
    [InlineData(ElevenLabsRegion.In, "api.in.residency.elevenlabs.io")]
    [InlineData(ElevenLabsRegion.Sg, "api.sg.residency.elevenlabs.io")]
    public async Task EachPublicRegionTestsKeysOnlyAtItsFixedHost(ElevenLabsRegion region, string host)
    {
        Assert.Equal(new Uri("https://" + host), region.BaseUri());
        await UploadOverLoopbackTlsAsync(() => new(new TestKeys(), region), host, false, keyTest: true);
    }

    [Fact]
    public async Task PublicConstructorDoesNotForwardKeysOn307() =>
        await UploadOverLoopbackTlsAsync(() => new(new TestKeys()), "api.elevenlabs.io", true);

    [Fact]
    public async Task PublicKeyTestDoesNotForwardKeysOnCrossHost307() =>
        await UploadOverLoopbackTlsAsync(() => new(new TestKeys()), "api.elevenlabs.io", true, keyTest: true);

    [Fact]
    public async Task SettingsFactoryUploadsToTheStoredRegion() =>
        await UploadOverLoopbackTlsAsync(() => ElevenLabsTranscriber.FromSettings(new TestKeys(), Settings("\"eu\"")),
            "api.eu.residency.elevenlabs.io", false);

    [Fact]
    public async Task SettingsFactoryTestsKeysAtTheStoredRegion() =>
        await UploadOverLoopbackTlsAsync(() => ElevenLabsTranscriber.FromSettings(new TestKeys(), Settings("\"sg\"")),
            "api.sg.residency.elevenlabs.io", false, keyTest: true);

    [Fact]
    public void DisplayOriginsRejectUnknownRegionValues() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => ((ElevenLabsRegion)int.MaxValue).BaseUri());

    [Theory]
    [InlineData("\"default\"", ElevenLabsRegion.Default)]
    [InlineData("\"us\"", ElevenLabsRegion.Us)]
    [InlineData("\"eu\"", ElevenLabsRegion.Eu)]
    [InlineData("\"in\"", ElevenLabsRegion.In)]
    [InlineData("\"sg\"", ElevenLabsRegion.Sg)]
    public void ResolvesKnownSettingsWithoutWarnings(string json, ElevenLabsRegion expected)
    {
        var log = new RegionLog();
        Assert.Equal(expected, ElevenLabsRegions.FromSettings(Settings(json), log));
        Assert.Empty(log.Warnings);
    }

    [Theory]
    [InlineData("\"https://untrusted.invalid/secret-value\"")]
    [InlineData("\"EU\"")]
    [InlineData("17")]
    [InlineData("null")]
    [InlineData("{}")]
    public void InvalidSettingsFallBackWithOneValueFreeWarning(string json)
    {
        var log = new RegionLog();
        Assert.Equal(ElevenLabsRegion.Default, ElevenLabsRegions.FromSettings(Settings(json), log));
        Assert.Equal("Unknown ElevenLabs region setting; using Default.", Assert.Single(log.Warnings));
    }

    [Fact]
    public void MissingSettingsAreQuietAndNoPublicApiAcceptsAHost()
    {
        var log = new RegionLog();
        Assert.Equal(ElevenLabsRegion.Default, ElevenLabsRegions.FromSettings(new("voxclip-settings/1"), log));
        Assert.Empty(log.Warnings);
        var parameters = typeof(ElevenLabsTranscriber).GetConstructors().SelectMany(constructor => constructor.GetParameters());
        Assert.DoesNotContain(parameters, parameter => parameter.ParameterType == typeof(Uri) || parameter.ParameterType == typeof(string));
        Assert.DoesNotContain(parameters, parameter => parameter.ParameterType == typeof(HttpClient) || parameter.ParameterType == typeof(HttpMessageHandler));
        Assert.Equal(2, typeof(ElevenLabsTranscriber).GetConstructors().Length);
    }

    [Fact]
    public void ProductionMediaCannotInjectAKeyBearingClientOrHost()
    {
        var transcriber = typeof(ElevenLabsTranscriber);
        var friends = transcriber.Assembly.GetCustomAttributes<InternalsVisibleToAttribute>().Select(attribute => attribute.AssemblyName).ToArray();
        Assert.Contains("VoxClip.Core.Tests", friends);
        Assert.DoesNotContain("VoxClip.Media", friends);
        var constructors = transcriber.GetConstructors(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        Assert.DoesNotContain(constructors.SelectMany(constructor => constructor.GetParameters()),
            parameter => parameter.ParameterType == typeof(Uri) || parameter.ParameterType == typeof(string));
        var injectable = Assert.Single(constructors, constructor => !constructor.IsPublic);
        Assert.True(injectable.IsPrivate);
        Assert.Contains(injectable.GetParameters(), parameter => parameter.ParameterType == typeof(ElevenLabsRegion));
        var factory = Assert.Single(transcriber.GetMethods(BindingFlags.Static | BindingFlags.NonPublic), method => method.Name == "ForTesting");
        Assert.True(factory.IsAssembly);
        Assert.Equal(new[] { typeof(Core.Services.LLM.IKeyProvider), typeof(HttpMessageHandler), typeof(ElevenLabsRegion), typeof(Core.Services.Models.ModelCatalog), typeof(ILog) },
            factory.GetParameters().Select(parameter => parameter.ParameterType));
        Assert.Throws<ArgumentNullException>(() => ElevenLabsTranscriber.ForTesting(new TestKeys(), null!, ElevenLabsRegion.Default));
    }

    private static AppSettings Settings(string json) => new("voxclip-settings/1")
    {
        Values = new() { ["transcription.elevenlabs.region"] = JsonDocument.Parse(json).RootElement.Clone() }
    };

    private static async Task UploadOverLoopbackTlsAsync(Func<ElevenLabsTranscriber> create, string host, bool redirect, bool keyTest = false)
    {
        using var files = new SpeechFiles();
        using var transcriber = create();
        var handler = Assert.IsType<SocketsHttpHandler>(transcriber.OwnedHandler);
        Assert.False(handler.AllowAutoRedirect);
        Assert.False(handler.UseCookies);
        Assert.True(handler.UseProxy);
        handler.UseProxy = false;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var certificate = LoopbackTls.CreateCertificate();
        var connections = new List<string>();
        handler.ConnectCallback = async (context, ct) =>
        {
            connections.Add(context.DnsEndPoint.Host);
            Assert.Equal(host, context.DnsEndPoint.Host);
            var socket = new Socket(SocketType.Stream, ProtocolType.Tcp);
            try { await socket.ConnectAsync(listener.LocalEndpoint, ct); }
            catch { socket.Dispose(); throw; }
            return new NetworkStream(socket, ownsSocket: true);
        };
        handler.SslOptions.RemoteCertificateValidationCallback = (_, _, _, _) => true;
        var serving = ServeAsync(listener, certificate, host, redirect, keyTest, deadline.Token);
        try
        {
            if (redirect)
            {
                var error = await Assert.ThrowsAsync<VoxClipException>(async () =>
                {
                    if (keyTest) await transcriber.TestKeyAsync(deadline.Token);
                    else await transcriber.TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), deadline.Token);
                });
                Assert.Equal(VoxClipErrorCode.ProviderError, error.Code);
                Assert.Contains("307", error.Message);
            }
            else if (keyTest)
            {
                var result = await transcriber.TestKeyAsync(deadline.Token);
                Assert.True(result.CanReadAccountDetails);
                Assert.Equal("Works.", result.Message);
            }
            else
            {
                var raw = await transcriber.TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), deadline.Token);
                Assert.Equal("et", raw.Language);
            }
            await serving;
            Assert.Equal(host, Assert.Single(connections));
        }
        finally
        {
            await deadline.CancelAsync();
            listener.Stop();
            try { await serving; }
            catch (OperationCanceledException) when (deadline.IsCancellationRequested) { }
        }
    }

    private static async Task ServeAsync(TcpListener listener, X509Certificate2 certificate, string host, bool redirect, bool keyTest, CancellationToken ct)
    {
        using var client = await listener.AcceptTcpClientAsync(ct);
        await using var stream = new SslStream(client.GetStream());
        await stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = certificate }, ct);
        var header = new StringBuilder();
        var single = new byte[1];
        while (!header.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal))
        {
            Assert.Equal(1, await stream.ReadAsync(single, ct));
            header.Append((char)single[0]);
            Assert.True(header.Length < 32_768);
        }
        var lines = header.ToString().Split("\r\n");
        Assert.Equal(keyTest ? "GET /v1/user/subscription HTTP/1.1" : "POST /v1/speech-to-text HTTP/1.1", lines[0]);
        Assert.Contains(lines, line => line.Equals("Host: " + host, StringComparison.OrdinalIgnoreCase));
        Assert.Contains(lines, line => line.StartsWith("xi-api-key:", StringComparison.OrdinalIgnoreCase));
        if (keyTest) Assert.DoesNotContain(lines, line => line.StartsWith("Content-", StringComparison.OrdinalIgnoreCase));
        else
        {
            var length = int.Parse(Assert.Single(lines, line => line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)).Split(':')[1],
                System.Globalization.CultureInfo.InvariantCulture);
            await stream.ReadExactlyAsync(new byte[length], ct);
        }
        var body = redirect ? "{}" : ElevenLabsTests.Response;
        var status = redirect ? "307 Temporary Redirect\r\nLocation: https://redirect.invalid/v1/speech-to-text" : "200 OK";
        await stream.WriteAsync(Encoding.UTF8.GetBytes($"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {Encoding.UTF8.GetByteCount(body)}\r\nConnection: close\r\n\r\n{body}"), ct);
    }

    private sealed class RegionLog : ILog
    {
        internal List<string> Warnings { get; } = [];
        public void RegisterSecret(string secret) { }
        public void Write(LogLevel level, string category, string message) { if (level == LogLevel.Warn) Warnings.Add(message); }
        public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
