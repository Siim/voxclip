using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Process;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
[Collection("WinAiDataIsolation")]
public sealed class RoundFourTransportTests
{
    [Theory]
    [InlineData(ConnectorId.Anthropic)]
    [InlineData(ConnectorId.OpenAI)]
    [InlineData(ConnectorId.Xai)]
    [InlineData(ConnectorId.Gemini)]
    public async Task PublicW7NeverFollowsTlsRedirectsWithStoredKeys(ConnectorId id)
    {
        foreach (var destination in new[] { "https://collector.example.test/collect", "https://{host}:8443/collect", "https://{host}/collect", "http://collector.example.test/collect" })
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
            deadline.CancelAfter(TimeSpan.FromSeconds(5));
            using var certificate = LoopbackTls.CreateCertificate();
            using var first = new TcpListener(IPAddress.Loopback, 0);
            using var collector = new TcpListener(IPAddress.Loopback, 0);
            first.Start();
            collector.Start();
            var catalog = Catalog();
            var host = new Uri(catalog.Provider(id)["baseUrl"]!.GetValue<string>()).Host;
            var location = destination.Replace("{host}", host, StringComparison.Ordinal);
            var initialRequest = ServeRedirectAsync(first, certificate, location, deadline.Token);
            var redirectedRequest = CaptureAsync(collector, certificate, deadline.Token);
            using var coreHandler = LlmRuntime.CreateHttpHandler();
            Assert.False(coreHandler.AllowAutoRedirect);
            Assert.False(coreHandler.UseCookies);
            Assert.True(coreHandler.UseProxy);
            coreHandler.UseProxy = false;
            var coreConnections = 0;
            coreHandler.ConnectCallback = async (_, cancellation) =>
            {
                var endpoint = Interlocked.Increment(ref coreConnections) == 1 ? first.LocalEndpoint : collector.LocalEndpoint;
                return await ConnectAsync((IPEndPoint)endpoint, cancellation);
            };
            coreHandler.SslOptions.RemoteCertificateValidationCallback = (_, remote, _, _) => remote?.GetCertHashString() == certificate.GetCertHashString();
            using var coreHttp = new HttpClient(coreHandler);
            var callerConnections = 0;
            using var callerHandler = new SocketsHttpHandler
            {
                UseProxy = false,
                ConnectCallback = async (_, cancellation) =>
                {
                    var endpoint = Interlocked.Increment(ref callerConnections) == 1 ? first.LocalEndpoint : collector.LocalEndpoint;
                    return await ConnectAsync((IPEndPoint)endpoint, cancellation);
                }
            };
            Assert.True(callerHandler.AllowAutoRedirect);
            callerHandler.SslOptions.RemoteCertificateValidationCallback = (_, remote, _, _) => remote?.GetCertHashString() == certificate.GetCertHashString();
            using var callerHttp = new HttpClient(callerHandler);
            var previous = LlmRuntime.ScopedKeyedHttp.Value;
            try
            {
                LlmRuntime.ScopedKeyedHttp.Value = coreHttp;
                var connector = new LlmConnector(id, new MemoryKeys(), new ProcessRunner(), catalog, callerHttp);
                var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(id), "chat", deadline.Token));
                Assert.Equal(LlmErrorKind.BadRequest, failure.Error.Kind);
                Assert.Equal(307, failure.Error.Status);
                var sent = await initialRequest;
                Assert.Contains("Host: " + host, sent, StringComparison.OrdinalIgnoreCase);
                Assert.Contains(catalog.Provider(id)["auth"]!["header"]!.GetValue<string>() + ": ", sent, StringComparison.OrdinalIgnoreCase);
                Assert.Equal(1, coreConnections);
                Assert.Equal(0, callerConnections);
            }
            finally
            {
                LlmRuntime.ScopedKeyedHttp.Value = previous;
                await deadline.CancelAsync();
                await initialRequest;
                var redirected = await redirectedRequest;
                foreach (var header in new[] { "x-api-key:", "x-goog-api-key:", "Authorization:" })
                    Assert.DoesNotContain(header, redirected ?? "", StringComparison.OrdinalIgnoreCase);
                Assert.Null(redirected);
            }
        }
    }

    [Theory]
    [InlineData(ConnectorId.Anthropic)]
    [InlineData(ConnectorId.OpenAI)]
    [InlineData(ConnectorId.Xai)]
    [InlineData(ConnectorId.Gemini)]
    public async Task KeyedResponsesRejectAChangedFinalOrigin(ConnectorId id)
    {
        foreach (var address in new[] { "https://collector.example.test/collect", "https://{host}:8443/collect", "http://{host}/collect" })
        {
            var catalog = Catalog();
            var host = new Uri(catalog.Provider(id)["baseUrl"]!.GetValue<string>()).Host;
            using var handler = new StubHttp((_, _, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(Completion(id)),
                RequestMessage = new HttpRequestMessage(HttpMethod.Post, address.Replace("{host}", host, StringComparison.Ordinal))
            }));
            using var http = new HttpClient(handler);
            var connector = new LlmConnector(id, catalog, http, new MemoryKeys(), new Redactor());
            var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(id), "chat", TestContext.Current.CancellationToken));
            Assert.Equal(LlmErrorKind.Unavailable, failure.Error.Kind);
            Assert.Equal("VoxClip is missing its AI configuration. Reinstall VoxClip. Your edits are saved.", failure.Error.UserMessage);
            Assert.Single(handler.Requests);
        }
    }

    private static async ValueTask<Stream> ConnectAsync(IPEndPoint endpoint, CancellationToken cancellation)
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            await socket.ConnectAsync(endpoint, cancellation);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    private static async Task<string> ServeRedirectAsync(TcpListener listener, X509Certificate2 certificate, string location, CancellationToken cancellation)
    {
        using var connection = await listener.AcceptTcpClientAsync(cancellation);
        await using var stream = new SslStream(connection.GetStream());
        await stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = certificate }, cancellation);
        var request = await ReadRequestAsync(stream, cancellation);
        await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 307 Temporary Redirect\r\nLocation: {location}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}"), cancellation);
        return request;
    }

    private static async Task<string?> CaptureAsync(TcpListener listener, X509Certificate2 certificate, CancellationToken cancellation)
    {
        try
        {
            using var connection = await listener.AcceptTcpClientAsync(cancellation);
            await using var stream = new SslStream(connection.GetStream());
            await stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = certificate }, cancellation);
            var request = await ReadRequestAsync(stream, cancellation);
            await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"), cancellation);
            return request;
        }
        catch (OperationCanceledException) { return null; }
    }

    private static async Task<string> ReadRequestAsync(Stream stream, CancellationToken cancellation)
    {
        var header = new StringBuilder();
        var buffer = new byte[1];
        while (header.Length < 16384)
        {
            await stream.ReadExactlyAsync(buffer, cancellation);
            header.Append((char)buffer[0]);
            if (header.Length >= 4 && header.ToString(header.Length - 4, 4) == "\r\n\r\n")
            {
                var contentLength = header.ToString().Split("\r\n").FirstOrDefault(line => line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase));
                if (contentLength is not null)
                {
                    var body = new byte[int.Parse(contentLength.Split(':')[1].Trim(), System.Globalization.CultureInfo.InvariantCulture)];
                    await stream.ReadExactlyAsync(body, cancellation);
                }
                return header.ToString();
            }
        }
        throw new InvalidDataException("Loopback request headers exceeded the test limit.");
    }
}
