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

#if BOUNDARY_MAPPED
        /// <summary>Hand-written code #line-mapped to a non-C# file in a type without obj/ XAML output.</summary>
#line 1 "Toolchain.generated.txt"
        internal static string Template(string passage) => passage.Trim();
#line default
#endif

#if BOUNDARY_GENERATEDTAG
        /// <summary>A XAML compiler tag on a type that has no obj/ XAML output proves nothing.</summary>
        [System.CodeDom.Compiler.GeneratedCode("Microsoft.UI.Xaml.Markup.Compiler", "1")]
        internal static Func<string, string>? XamlNamedOverride = null;
#endif

        public async Task<string> RenderAsync(string passage, CancellationToken ct)
        {
            await Task.Yield();
            ct.ThrowIfCancellationRequested();
#if BOUNDARY_DEBUGLITERAL
            if (Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_REWRITE_FIXTURE") is { Length: > 0 } canned) return canned;
#endif
#if BOUNDARY_GENERATEDTAG
            if (XamlNamedOverride is { } replace) return replace(passage);
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

#if BOUNDARY_FILELOCAL
    /// <summary>A fake backend declared with the C# file modifier: Roslyn names it &lt;Fixture&gt;F&lt;sha256&gt;__RewriteBackendStandIn
    /// without [CompilerGenerated], so it must be inventoried like any other hand-written type.</summary>
    file sealed class RewriteBackendStandIn : IRewriteBackend
    {
        internal static string? CannedForTests = null;

        public Task<string> RenderAsync(string passage, CancellationToken ct) => Task.FromResult(CannedForTests ?? passage);
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

#if BOUNDARY_OBSERVABLE
    public sealed partial class RewriteGeneration : CommunityToolkit.Mvvm.ComponentModel.ObservableObject
#else
    public sealed partial class RewriteGeneration
#endif
    {
        private readonly IRewriteBackend backend;

        public RewriteGeneration(IRewriteBackend backend)
        {
#if BOUNDARY_FILELOCAL
            // Wired into an approved member: only the file type itself is new.
            this.backend = backend is RewriteGenerationBackend ? backend : new RewriteBackendStandIn();
#else
            this.backend = backend;
#endif
        }

#if BOUNDARY_HOOK
        /// <summary>An internal test hook on an already approved type.</summary>
        internal static Func<IRewriteBackend>? ReplacementForTests = null;

        internal void UseBackend(IRewriteBackend replacement) => ReplacementForTests = () => replacement;
#endif

#if BOUNDARY_OBSERVABLE
        /// <summary>A test hook declared with CommunityToolkit.Mvvm's hand-written [ObservableProperty]: the generator writes the
        /// DiscoverOverrideForTests accessors into this approved type.</summary>
        [CommunityToolkit.Mvvm.ComponentModel.ObservableProperty]
        private Func<IRewriteBackend>? discoverOverrideForTests;
#endif

#if BOUNDARY_GENERATEDTAG
        /// <summary>Hand-written hooks that merely claim to be generated.</summary>
        [System.CodeDom.Compiler.GeneratedCode("hand", "1")]
        internal static Func<IRewriteBackend>? ReplacementForTests = null;
#endif

#if BOUNDARY_SEAMS
        /// <summary>A constructor-overload seam that selects a backend for tests.</summary>
        internal RewriteGeneration() : this(new RewriteGenerationBackend()) { }
#endif

#if BOUNDARY_NESTEDOBSERVABLE
        /// <summary>A hook bag nested in this approved type. CommunityToolkit.Mvvm writes every body it has, and Roslyn records
        /// no declaration document for a nested type, so only being nested in a hand-written type shows that it is hand-written.</summary>
        internal sealed partial class HookBag : CommunityToolkit.Mvvm.ComponentModel.ObservableObject
        {
            internal static HookBag? Current = null;

            [CommunityToolkit.Mvvm.ComponentModel.ObservableProperty]
            private Func<IRewriteBackend>? standInForTests;
        }
#endif

#if BOUNDARY_NESTEDLIBRARYIMPORT
        /// <summary>Native and pattern hooks nested in this approved type: the LibraryImport and Regex generators write every body.</summary>
        internal static partial class Natives
        {
            [System.Runtime.InteropServices.LibraryImport("rewritestandin", StringMarshalling = System.Runtime.InteropServices.StringMarshalling.Utf16)]
            internal static partial int StandInRender(string passage);

            [System.Text.RegularExpressions.GeneratedRegex("stand-?in", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
            internal static partial System.Text.RegularExpressions.Regex StandInPattern();
        }
#endif

        public string Status { get; private set; } = "idle";

        public async Task<string> RunAsync(string passage, CancellationToken ct)
        {
            Status = "running";
            var chosen = backend;
#if BOUNDARY_OBSERVABLE
            chosen = DiscoverOverrideForTests?.Invoke() ?? chosen;
#endif
#if BOUNDARY_GENERATEDTAG
            chosen = ReplacementForTests?.Invoke() ?? chosen;
#endif
#if BOUNDARY_NESTEDOBSERVABLE
            chosen = HookBag.Current?.StandInForTests?.Invoke() ?? chosen;
#endif
#if BOUNDARY_GENERATEDOUTER
            if (RewriteHooks.Marker.Active()) chosen = RewriteHooks.Current?.StandIn?.Invoke() ?? chosen;
#endif
            var result = await chosen.RenderAsync(passage, ct);
#if BOUNDARY_NESTEDLIBRARYIMPORT
            if (Natives.StandInPattern().IsMatch(passage) && Natives.StandInRender(passage) == 1) result = passage;
#endif
#if BOUNDARY_SEAMS
            if (Environment.GetEnvironmentVariable("VOXCLIP_REWRITE_STAND_IN") == "1" ||
                Environment.GetCommandLineArgs().Contains("--rewrite-stand-in")) result = passage;
            Trace("run");
#endif
#if BOUNDARY_LOWERCASE
            // Windows environment names are case-insensitive: these read VOXCLIP_DEBUG_* and stand-in switches.
            if (Environment.GetEnvironmentVariable("voxclip_debug_rewrite_stand_in") == "1" ||
                Environment.GetEnvironmentVariable("VoxClip_Debug_Rewrite") is { Length: > 0 } ||
                Environment.GetEnvironmentVariable("rewrite_stand_in") == "1" ||
                Environment.GetEnvironmentVariable("RewriteStandIn", EnvironmentVariableTarget.User) == "1" ||
                Environment.GetCommandLineArgs().Contains("/rewrite-stand-in")) result = passage;
#endif
            Status = "done";
            return result;
        }

#if BOUNDARY_SEAMS
        [Conditional("DEBUG")]
        internal static void Trace(string phase) => Console.Error.WriteLine(phase);
#endif
    }

#if BOUNDARY_GENERATEDOUTER
    /// <summary>A top-level hook type whose own bodies CommunityToolkit.Mvvm writes. Roslyn leaves this file out of its
    /// TypeDefinitionDocuments because the nested Marker's method already covers it, so only Marker shows it is hand-written.</summary>
    internal sealed partial class RewriteHooks : CommunityToolkit.Mvvm.ComponentModel.ObservableObject
    {
        internal static RewriteHooks? Current = null;

        [CommunityToolkit.Mvvm.ComponentModel.ObservableProperty]
        private Func<IRewriteBackend>? standIn;

        internal static class Marker
        {
            internal static bool Active() => Current is not null;
        }
    }
#endif
}
