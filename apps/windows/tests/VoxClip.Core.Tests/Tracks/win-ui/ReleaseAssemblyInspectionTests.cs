#if WIN_UI_TESTS
using System.Reflection.PortableExecutable;
using System.Text.RegularExpressions;
using VoxClip.Core.Services.Project;
using VoxClip.ReleaseBoundary;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>Mutation tests for the Release boundary checker that Windows CI runs on the shipping App of both RIDs.
/// Every fixture is a real Release compilation of tests/ReleaseBoundaryFixture (built before this project compiles);
/// each variant injects one kind of content that must never ship. Nothing is loaded or executed.</summary>
public sealed class ReleaseAssemblyInspectionTests
{
    private static string Root => Path.GetDirectoryName(SharedResources.ResolveRoot())!;
    private static string FixtureDirectory => Path.Combine(Root, "apps/windows/tests/ReleaseBoundaryFixture");
    private static string FixtureAllowlist => Path.Combine(FixtureDirectory, "allowlist/ReleaseBoundaryFixture.txt");
    private static string Fixture(string variant) => Path.Combine(FixtureDirectory, "bin", variant, "ReleaseBoundaryFixture.dll");

    private static AssemblyInventory Read(string variant)
    {
        var path = Fixture(variant);
        Assert.True(File.Exists(path), "BuildReleaseBoundaryFixtures builds every fixture variant before the UI tests compile: " + path);
        return AssemblyInspector.Read(path, Root);
    }

    private static CheckResult Check(string variant) => Read(variant).Check(Allowlist.Read(FixtureAllowlist));

    [Fact]
    public void CleanReleaseFixturePassesItsExactAllowlist()
    {
        var inventory = Read("Clean");
        var result = inventory.Check(Allowlist.Read(FixtureAllowlist));
        Assert.True(result.Passed, string.Join('\n', result.Forbidden.Concat(result.Unapproved)));
        Assert.Empty(result.Stale);
        Assert.Empty(AssemblyInspector.IdentityErrors(inventory, "ReleaseBoundaryFixture", Machine.Amd64, allowAnyCpu: true));
        Assert.Equal(File.ReadAllText(FixtureAllowlist), Allowlist.Render("ReleaseBoundaryFixture", inventory.AllowlistLines));
        Assert.Contains("type VoxClip.App.ViewModels.RewriteGeneration", inventory.AllowlistLines);
        Assert.Contains("member VoxClip.App.ViewModels.RewriteGeneration :: method public RunAsync(string,System.Threading.CancellationToken)", inventory.AllowlistLines);
        Assert.Contains("member VoxClip.App.Services.RewriteGenerationBackend :: field private sharedDirectory", inventory.AllowlistLines);
        Assert.Contains("literal \"VOXCLIP_SHARED_DIR\"", inventory.AllowlistLines);
        // Every literal is enumerated, including ordinary text inside async state machines that needs no approval.
        Assert.Contains(inventory.Entries, entry => entry is { Key: "literal \"running\"", Origin: EntryOrigin.Source, RequiresApproval: false });
    }

    [Fact]
    public void ToolchainOutputIsInventoriedButNeverNeedsApproval()
    {
        var inventory = Read("Clean");
        foreach (var key in new[]
                 {
                     "member VoxClip.App.ViewModels.RewriteGeneration :: method public InitializeComponent()",
                     "member VoxClip.App.ViewModels.RewriteGeneration :: field private RewriteButton",
                     "member VoxClip.App.ViewModels.RewriteGeneration :: field private _contentLoaded",
                     "member VoxClip.App.ViewModels.RewriteGeneration :: field private Bindings",
                     "type VoxClip.App.ViewModels.RewriteGeneration+IRewriteGeneration_Bindings",
                     "type VoxClip.App.ViewModels.RewriteGeneration+IRewriteGeneration_BindingsScopeConnector",
                     "type VoxClip.App.ViewModels.RewriteGeneration+RewriteGeneration_obj1_Bindings",
                     "type VoxClip.App.Controls.RewritePanel+IRewritePanel_BindingsScopeConnector",
                     "member VoxClip.App.Controls.RewritePanel :: method public InitializeComponent()",
                     "type VoxClip.App.ViewModels.RewriteGeneration+RewriteGeneration_obj1_Bindings+InvokeFunctionDelegate",
                     "type VoxClip.App.ReleaseBoundaryFixture_XamlTypeInfo.Activator",
                     "type Microsoft.Windows.Foundation.UndockedRegFreeWinRTCS.NativeMethods",
                     "type Microsoft.Windows.Foundation.UndockedRegFreeWinRTCS.AutoInitialize",
                     "literal \"MICROSOFT_WINDOWSAPPRUNTIME_BASE_DIRECTORY\"",
                 })
        {
            var entry = Assert.Single(inventory.Entries, candidate => candidate.Key == key);
            Assert.Equal(EntryOrigin.Generated, entry.Origin);
            Assert.False(entry.RequiresApproval);
            Assert.DoesNotContain(key, inventory.AllowlistLines);
        }
        Assert.DoesNotContain(inventory.AllowlistLines, line => line.Contains("Toolchain", StringComparison.Ordinal) ||
            line.Contains("Microsoft.Windows", StringComparison.Ordinal) || line.Contains("_Bindings", StringComparison.Ordinal));
    }

    [Fact]
    public void NonDebugNamedStandInClassFails()
    {
        var result = Check("StandIn");
        Assert.False(result.Passed);
        Assert.Empty(result.Forbidden);
        Assert.Equal(new[]
        {
            "member VoxClip.App.Services.RewriteBackendStandIn :: method public .ctor()",
            "member VoxClip.App.Services.RewriteBackendStandIn :: method public RenderAsync(string,System.Threading.CancellationToken)",
            "type VoxClip.App.Services.RewriteBackendStandIn",
        }, result.Unapproved);
    }

    [Fact]
    public void InternalTestHookOnAnApprovedTypeFails()
    {
        var result = Check("Hook");
        Assert.False(result.Passed);
        Assert.Equal(new[]
        {
            "member VoxClip.App.ViewModels.RewriteGeneration :: field internal ReplacementForTests",
            "member VoxClip.App.ViewModels.RewriteGeneration :: method internal UseBackend(VoxClip.App.Services.IRewriteBackend)",
        }, result.Unapproved);
        Assert.DoesNotContain(result.Unapproved, line => line.StartsWith("type ", StringComparison.Ordinal));
    }

    [Fact]
    public void DebugEnvironmentStringFailsAndCannotBeAllowlisted()
    {
        var inventory = Read("DebugLiteral");
        var result = inventory.Check(Allowlist.Read(FixtureAllowlist));
        Assert.Equal(new[] { "literal \"VOXCLIP_DEBUG_REWRITE_FIXTURE\"" }, result.Unapproved);
        Assert.Contains(result.Forbidden, line => line.StartsWith("Debug environment literal \"VOXCLIP_DEBUG_REWRITE_FIXTURE\"", StringComparison.Ordinal));
        var everything = inventory.Check(inventory.AllowlistLines);
        Assert.False(everything.Passed);
        Assert.Empty(everything.Unapproved);
        Assert.Contains(everything.Forbidden, line => line.StartsWith("Allowlist entry can never be approved: literal \"VOXCLIP_DEBUG_", StringComparison.Ordinal));
    }

    [Fact]
    public void DifferentlyNamedSeamsFriendAssembliesAndDebugConditionalMembersFail()
    {
        var inventory = Read("Seams");
        var result = inventory.Check(Allowlist.Read(FixtureAllowlist));
        Assert.False(result.Passed);
        foreach (var line in new[]
                 {
                     "member VoxClip.App.ViewModels.RewriteGeneration :: method internal .ctor()",
                     "literal \"VOXCLIP_REWRITE_STAND_IN\"",
                     "literal \"--rewrite-stand-in\"",
                     "attribute assembly @ System.Runtime.CompilerServices.InternalsVisibleToAttribute(\"RewriteHarness\")",
                     "attribute VoxClip.App.ViewModels.RewriteGeneration :: method internal Trace(string) @ System.Diagnostics.ConditionalAttribute(\"DEBUG\")",
                 })
            Assert.Contains(line, result.Unapproved);
        Assert.Contains("DEBUG-only member ships in Release: VoxClip.App.ViewModels.RewriteGeneration :: method internal Trace(string) carries [Conditional(\"DEBUG\")]", result.Forbidden);
        Assert.NotEmpty(inventory.Check(inventory.AllowlistLines).Forbidden);
    }

    [Fact]
    public void DebugBuildFailsIdentityAndInventory()
    {
        var inventory = Read("DebugBuild");
        var identity = AssemblyInspector.IdentityErrors(inventory, "ReleaseBoundaryFixture", null, true).ToArray();
        Assert.Contains(identity, line => line.Contains("expected Release configuration, found 'Debug'", StringComparison.Ordinal));
        Assert.Contains(identity, line => line.Contains("not optimized", StringComparison.Ordinal));
        var result = inventory.Check(Allowlist.Read(FixtureAllowlist));
        Assert.Contains("type VoxClip.App.Services.DebugRewriteRunner", result.Unapproved);
        Assert.Contains(result.Forbidden, line => line.StartsWith("Debug environment literal \"VOXCLIP_DEBUG_REWRITE\"", StringComparison.Ordinal));
    }

    [Fact]
    public void ShippingIdentityRejectsSurrogatesWrongArchitectureAndMissingPdb()
    {
        var clean = Read("Clean");
        Assert.Contains(AssemblyInspector.IdentityErrors(clean, "VoxClip", null, true), line => line.Contains("found ReleaseBoundaryFixture", StringComparison.Ordinal));
        Assert.Contains(AssemblyInspector.IdentityErrors(clean, "ReleaseBoundaryFixture", Machine.Amd64, allowAnyCpu: false),
            line => line.Contains("expected Amd64 code, found I386", StringComparison.Ordinal));
        Assert.Empty(AssemblyInspector.IdentityErrors(clean, "ReleaseBoundaryFixture", Machine.Arm64, allowAnyCpu: true));
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-release-boundary-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var lonely = Path.Combine(directory, "ReleaseBoundaryFixture.dll");
            File.Copy(Fixture("Clean"), lonely);
            var withoutPdb = AssemblyInspector.Read(lonely, Root);
            Assert.Null(withoutPdb.Identity.PdbPath);
            Assert.Contains(AssemblyInspector.IdentityErrors(withoutPdb, "ReleaseBoundaryFixture", null, true), line => line.Contains("no matching portable PDB", StringComparison.Ordinal));
            // Without a PDB nothing can be shown to be toolchain output, so it all needs approval: the check fails closed.
            Assert.Contains("type Microsoft.Windows.Foundation.UndockedRegFreeWinRTCS.NativeMethods", withoutPdb.Check(Allowlist.Read(FixtureAllowlist)).Unapproved);
            var surrogate = Path.Combine(directory, "VoxClip.WinCheck.dll");
            File.Copy(Fixture("Clean"), surrogate);
            var error = new StringWriter();
            Assert.Equal(1, ReleaseCheck.Shipping("win-x64", surrogate, Path.Combine(Root, ReleaseCheck.AllowlistDirectory), Root, null, TextWriter.Null, error));
            Assert.Contains("never a surrogate", error.ToString());
            Assert.Equal(2, ReleaseCheck.Shipping("win-x86", Path.Combine(directory, "VoxClip.dll"), directory, Root, null, TextWriter.Null, TextWriter.Null));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void FailureNamesTheEntryItsSourceTheAllowlistAndHowToUpdateIt()
    {
        var evidence = Path.Combine(Path.GetTempPath(), "voxclip-release-boundary-" + Guid.NewGuid().ToString("N"));
        try
        {
            var output = new StringWriter();
            var error = new StringWriter();
            var targets = new[] { new CheckTarget("ReleaseBoundaryFixture", Fixture("StandIn"), FixtureAllowlist) };
            Assert.Equal(1, ReleaseCheck.Run("Release boundary fixture", targets, strictStale: true, Root, evidence, output, error));
            var text = error.ToString();
            Assert.Contains("UNAPPROVED type VoxClip.App.Services.RewriteBackendStandIn    [apps/windows/tests/ReleaseBoundaryFixture/Fixture.cs]", text);
            Assert.Contains("FAILED: 0 identity, 0 forbidden, 3 unapproved, 0 stale -> apps/windows/tests/ReleaseBoundaryFixture/allowlist/ReleaseBoundaryFixture.txt", text);
            Assert.Contains("move it under #if DEBUG or into a test project", text);
            Assert.Contains("dotnet run --project apps/windows/build/ReleaseBoundary -c Release -- update <Release assembly> apps/windows/build/ReleaseBoundary/allowlist/<Name>.txt", text);
            Assert.Contains("-- update " + ReleaseCheck.SurrogatePath + " apps/windows/build/ReleaseBoundary/allowlist/VoxClip.txt", text);
            Assert.Contains("type VoxClip.App.Services.RewriteBackendStandIn", File.ReadAllText(Path.Combine(evidence, "ReleaseBoundaryFixture.allowlist.txt")));
            Assert.Contains("Generated\trecord\ttype Microsoft.Windows.Foundation.UndockedRegFreeWinRTCS.NativeMethods", File.ReadAllText(Path.Combine(evidence, "ReleaseBoundaryFixture.inventory.tsv")));
            Assert.Contains("\"passed\": false", File.ReadAllText(Path.Combine(evidence, "summary.json")));
            var clean = new[] { new CheckTarget("ReleaseBoundaryFixture", Fixture("Clean"), FixtureAllowlist) };
            output = new StringWriter();
            Assert.Equal(0, ReleaseCheck.Run("Release boundary fixture", clean, strictStale: true, Root, null, output, TextWriter.Null));
            Assert.Contains("Release boundary fixture: 1 assemblies passed.", output.ToString());
        }
        finally
        {
            if (Directory.Exists(evidence)) Directory.Delete(evidence, recursive: true);
        }
    }

    [Fact]
    public void StaleLinesWarnOnShippingAndFailTheExactPrecheck()
    {
        var clean = Read("Clean");
        var stale = clean.AllowlistLines.Append("type VoxClip.App.Services.RemovedProductType").ToArray();
        var result = clean.Check(stale);
        Assert.True(result.Passed);
        Assert.Equal(new[] { "type VoxClip.App.Services.RemovedProductType" }, result.Stale);
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-release-boundary-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var allowlist = Path.Combine(directory, "ReleaseBoundaryFixture.txt");
            File.WriteAllText(allowlist, Allowlist.Render("ReleaseBoundaryFixture", stale));
            var targets = new[] { new CheckTarget("ReleaseBoundaryFixture", Fixture("Clean"), allowlist) };
            Assert.Equal(0, ReleaseCheck.Run("shipping", targets, strictStale: false, Root, null, TextWriter.Null, TextWriter.Null));
            var error = new StringWriter();
            Assert.Equal(1, ReleaseCheck.Run("precheck", targets, strictStale: true, Root, null, TextWriter.Null, error));
            Assert.Contains("STALE type VoxClip.App.Services.RemovedProductType", error.ToString());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void CheckedInReleaseAllowlistsAreCanonicalAndNeverApproveDebugContent()
    {
        foreach (var name in ReleaseCheck.ShippingAssemblies)
        {
            var path = Path.Combine(Root, ReleaseCheck.AllowlistDirectory, name + ".txt");
            var lines = Allowlist.Read(path);
            Assert.NotEmpty(lines);
            Assert.Equal(lines.Order(StringComparer.Ordinal).Distinct(StringComparer.Ordinal), lines);
            Assert.Equal(File.ReadAllText(path), Allowlist.Render(name, lines));
            Assert.All(lines, line => Assert.Matches("^(type|member|attribute|literal) ", line));
            Assert.All(lines, line => Assert.DoesNotContain(Rules.DebugEnvironmentMarker, line));
            Assert.All(lines, line => Assert.DoesNotContain("ConditionalAttribute(\"DEBUG\")", line));
            Assert.DoesNotContain(File.ReadAllBytes(path), value => value > 126 || (value < 32 && value != 10));
        }
        // DEBUG-only App harnesses compile only in DEBUG, so the shipping App allowlist can never name them.
        var app = Allowlist.Read(Path.Combine(Root, ReleaseCheck.AllowlistDirectory, "VoxClip.txt"));
        var appSource = Path.Combine(Root, "apps/windows/src/VoxClip.App");
        var debugOnly = Directory.EnumerateFiles(appSource, "Debug*.cs", SearchOption.AllDirectories)
            .Where(path => !path.Contains("/obj/", StringComparison.Ordinal) && !path.Contains("/bin/", StringComparison.Ordinal))
            .Select(Path.GetFileNameWithoutExtension).ToArray();
        Assert.NotEmpty(debugOnly);
        foreach (var type in debugOnly)
            Assert.DoesNotContain(app, line => Regex.IsMatch(line, @"^type VoxClip\.App\.[\w.]+\." + Regex.Escape(type!) + "$"));
    }

    [Fact]
    public void BothRealReleaseBuildsImmediatelyRunTheMandatoryInspection()
    {
        var workflow = File.ReadAllText(Path.Combine(Root, ".github/workflows/ci.yml"));
        foreach (var rid in new[] { "win-x64", "win-arm64" })
        {
            var build = workflow.IndexOf("- name: Build WinUI app (" + rid + ")", StringComparison.Ordinal);
            Assert.True(build >= 0, rid);
            var next = workflow.IndexOf("- name:", build + 8, StringComparison.Ordinal);
            Assert.StartsWith("- name: Inspect shipping Release assemblies (" + rid + ")", workflow[next..]);
            var following = workflow.IndexOf("- name:", next + 8, StringComparison.Ordinal);
            var step = workflow[next..following];
            Assert.Contains("run: build/Test-ReleaseBoundary.ps1 -RuntimeIdentifier " + rid, step);
            Assert.Contains("working-directory: apps/windows", step);
            Assert.DoesNotContain("continue-on-error", step);
        }
        var upload = workflow[workflow.IndexOf("- name: Upload shipping Release inspection inventories", StringComparison.Ordinal)..];
        Assert.Contains("name: windows-release-boundary-inventories", upload[..upload.IndexOf("- name:", 8, StringComparison.Ordinal)]);
        var script = File.ReadAllText(Path.Combine(Root, "apps/windows/build/Test-ReleaseBoundary.ps1"));
        Assert.Contains("-getProperty:TargetPath", script);
        Assert.Contains("'-p:Configuration=Release'", script);
        Assert.Contains("check $RuntimeIdentifier $target", script);
        Assert.Contains("if ($LASTEXITCODE -ne 0)", script);
        Assert.DoesNotContain("TypeCheck", script);
        Assert.DoesNotContain("WinCheck", script);
        Assert.DoesNotContain(File.ReadAllBytes(Path.Combine(Root, "apps/windows/build/Test-ReleaseBoundary.ps1")), value => value > 126);
    }
}
#endif
