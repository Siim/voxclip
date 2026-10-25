using System.Net;
using System.Net.Sockets;
using System.Text;
using Xunit;

namespace VoxClip.Tests.Support;

public sealed class NetworkGuardTests
{
    [Fact]
    public async Task DefaultClientsCannotConnectToNonLoopbackHosts()
    {
        if (!NetworkGuard.Enabled) return;
        using var client = new HttpClient();
        var host = $"{Guid.NewGuid():N}.invalid";
        await Assert.ThrowsAsync<HttpRequestException>(() => client.GetAsync($"https://{host}/", TestContext.Current.CancellationToken));
        Assert.True(NetworkGuard.BlockedRequests(host) > 0);
        Assert.Equal(new Uri("http://127.0.0.1:9"), HttpClient.DefaultProxy.GetProxy(new Uri($"https://{host}/")));
    }

    [Fact]
    public async Task LoopbackHttpRemainsAvailable()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        var server = RespondAsync(listener, deadline.Token);
        try
        {
            using var client = new HttpClient();
            var endpoint = (IPEndPoint)listener.LocalEndpoint;
            Assert.Equal("ok", await client.GetStringAsync($"http://127.0.0.1:{endpoint.Port}/", deadline.Token));
        }
        finally
        {
            await deadline.CancelAsync();
            await server;
        }
    }

    private static async Task RespondAsync(TcpListener listener, CancellationToken cancellation)
    {
        using var connection = await listener.AcceptTcpClientAsync(cancellation);
        await using var stream = connection.GetStream();
        using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
        while (await reader.ReadLineAsync(cancellation) is { Length: > 0 }) { }
        await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"), cancellation);
    }
}
