// Release boundary checker fixture. Each variant is a real compilation of this file; a BOUNDARY_* symbol injects
// exactly one kind of content that must never ship in a Release assembly. Names are deliberately not Debug-prefixed.
using System.Diagnostics;
using System.Runtime.CompilerServices;
#if BOUNDARY_SEAMS
[assembly: InternalsVisibleTo("RewriteHarness")]
#endif

namespace VoxClip.App.Services
{
    public interface IRewriteBackend
    {
        Task<string> RenderAsync(string passage, CancellationToken ct);
    }

    /// <summary>The real backend. It reads one approved environment setting, like the shipping App.</summary>
    public sealed class RewriteGenerationBackend : IRewriteBackend
    {
        private readonly string sharedDirectory = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR") ?? "shared";

        public async Task<string> RenderAsync(string passage, CancellationToken ct)
        {
            await Task.Yield();
            ct.ThrowIfCancellationRequested();
#if BOUNDARY_DEBUGLITERAL
            if (Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_REWRITE_FIXTURE") is { Length: > 0 } canned) return canned;
#endif
            return passage.Length == 0 ? sharedDirectory : passage.Trim();
        }
    }

#if BOUNDARY_STANDIN
    /// <summary>A fake backend without a Debug name.</summary>
    internal sealed class RewriteBackendStandIn : IRewriteBackend
    {
        public Task<string> RenderAsync(string passage, CancellationToken ct) => Task.FromResult(passage);
    }
#endif

#if DEBUG
    /// <summary>DEBUG-only harness, present only in the Debug build of the fixture.</summary>
    internal static class DebugRewriteRunner
    {
        internal static string? Canned => Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_REWRITE");
    }
#endif
}

namespace VoxClip.App.Controls
{
    /// <summary>A hand-written XAML code-behind class; its InitializeComponent and binding interfaces are toolchain output.</summary>
    public sealed partial class RewritePanel
    {
        public RewritePanel() => InitializeComponent();
    }
}

namespace VoxClip.App.ViewModels
{
    using VoxClip.App.Services;

    public sealed partial class RewriteGeneration
    {
        private readonly IRewriteBackend backend;

        public RewriteGeneration(IRewriteBackend backend) => this.backend = backend;

#if BOUNDARY_HOOK
        /// <summary>An internal test hook on an already approved type.</summary>
        internal static Func<IRewriteBackend>? ReplacementForTests;

        internal void UseBackend(IRewriteBackend replacement) => ReplacementForTests = () => replacement;
#endif

#if BOUNDARY_SEAMS
        /// <summary>A constructor-overload seam that selects a backend for tests.</summary>
        internal RewriteGeneration() : this(new RewriteGenerationBackend()) { }
#endif

        public string Status { get; private set; } = "idle";

        public async Task<string> RunAsync(string passage, CancellationToken ct)
        {
            Status = "running";
            var result = await backend.RenderAsync(passage, ct);
#if BOUNDARY_SEAMS
            if (Environment.GetEnvironmentVariable("VOXCLIP_REWRITE_STAND_IN") == "1" ||
                Environment.GetCommandLineArgs().Contains("--rewrite-stand-in")) result = passage;
            Trace("run");
#endif
            Status = "done";
            return result;
        }

#if BOUNDARY_SEAMS
        [Conditional("DEBUG")]
        internal static void Trace(string phase) => Console.Error.WriteLine(phase);
#endif
    }
}
