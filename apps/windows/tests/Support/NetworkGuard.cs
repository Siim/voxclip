using System.Collections.Concurrent;
using System.Net;
using System.Runtime.CompilerServices;

namespace VoxClip.Tests.Support;

internal static class NetworkGuard
{
    private static readonly ConcurrentDictionary<string, int> BlockedHosts = new(StringComparer.OrdinalIgnoreCase);
    internal static bool Enabled { get; private set; }

    [ModuleInitializer]
    internal static void Initialize()
    {
        var live = Environment.GetEnvironmentVariable("VOXCLIP_LIVE_TESTS") == "1";
        var hasKey = new[] { "ELEVENLABS", "ANTHROPIC", "OPENAI", "XAI", "GEMINI" }
            .Any(provider => !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable($"VOXCLIP_{provider}_API_KEY")));
        Enabled = !live || !hasKey;
        if (Enabled) HttpClient.DefaultProxy = new LoopbackOnlyProxy();
    }

    internal static int BlockedRequests(string host) => BlockedHosts.GetValueOrDefault(host);

    private sealed class LoopbackOnlyProxy : IWebProxy
    {
        private static readonly Uri RefusingProxy = new("http://127.0.0.1:9");
        public ICredentials? Credentials { get; set; }
        public bool IsBypassed(Uri destination) => destination.IsLoopback;
        public Uri GetProxy(Uri destination)
        {
            BlockedHosts.AddOrUpdate(destination.Host, 1, (_, count) => count + 1);
            return RefusingProxy;
        }
    }
}
