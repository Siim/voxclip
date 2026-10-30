#if WIN_UI_TESTS
using System.Text;
using VoxClip.ReleaseBoundary;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class VoiceLabReleaseBoundaryTests
{
    private static string Root => Path.GetDirectoryName(SharedResources.ResolveRoot())!;
    private static string AppDirectory => Path.Combine(Root, "apps/windows/src/VoxClip.App");
    private static string Source(string path) => File.ReadAllText(Path.Combine(AppDirectory, path));
    public static IEnumerable<object[]> Flags()
    {
        foreach (var enabled in new[] { false, true })
            foreach (var accepted in new[] { false, true })
                foreach (var internalBuild in new[] { false, true })
                    yield return [enabled, accepted, internalBuild];
    }
    private static bool Expected(bool enabled, bool accepted, bool internalBuild) =>
#if DEBUG
        enabled && (accepted || internalBuild);
#else
        enabled && accepted;
#endif

    [Theory]
    [MemberData(nameof(Flags))]
    public void EveryEntryUsesBothFlagsAndTheCorePredicate(bool enabled, bool accepted, bool internalBuild)
    {
        var available = Expected(enabled, accepted, internalBuild);
        Assert.Equal(available, VoiceLabBeta.IsAvailable(enabled, accepted, internalBuild));
        Assert.True(VoiceLabSettingsState.PaneVisible);
        foreach (var entry in Enum.GetValues<RewriteEntry>())
            foreach (var editable in new[] { false, true })
                foreach (var selected in new[] { false, true })
                    Assert.Equal(available && editable && selected && entry != RewriteEntry.InsertWords
                            ? RewriteEntryAction.OpenPassage : RewriteEntryAction.Unavailable,
                        RewriteEntryPolicy.Resolve(entry, enabled, accepted, editable, selected, true, internalBuild));
        Assert.Equal(Expected(enabled, accepted, RewriteEntryPolicy.InternalBuild), RewriteEntryPolicy.Available(enabled, accepted));
        Assert.Equal(RewriteEntryPolicy.Available(enabled, accepted), KeyboardHelp.Text(enabled, accepted).Contains("Ctrl+R  Rewrite", StringComparison.Ordinal));
    }

    [Theory]
    [MemberData(nameof(Flags))]
    public async Task PaneKeyInventoryReadsOnlyWithTheGateOpenAndClearsOnClose(bool enabled, bool accepted, bool internalBuild)
    {
        var open = VoiceLabBeta.IsAvailable(enabled, accepted, internalBuild);
        var keys = new MemoryKeys();
        using var inventory = new VoiceLabKeyInventory(keys, () => open, CancellationToken.None);
        await inventory.RefreshAsync();
        var expectedReads = Expected(enabled, accepted, internalBuild) ? 3 : 0;
        Assert.Equal(expectedReads, keys.Reads);
        Assert.Equal(expectedReads, inventory.Rows.Count);
        open = false;
        await inventory.RefreshAsync();
        Assert.Empty(inventory.Rows);
        Assert.Equal(expectedReads, keys.Reads);
    }

    [Theory]
    [MemberData(nameof(Flags))]
    public async Task BetaNeverBypassesA8OrReadsAKeyDuringBlockedDiscovery(bool enabled, bool accepted, bool internalBuild)
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-release-boundary-" + Guid.NewGuid().ToString("N"));
        var data = new DataLocations(root, Path.Combine(root, "settings.json"), Path.Combine(root, "models"),
            Path.Combine(root, "cache"), Path.Combine(root, "autosave"), Path.Combine(root, "keys"), Path.Combine(root, "logs"));
        var keys = new ForbiddenKeys();
        await using var log = new SilentLog();
        using var backend = new RewriteGenerationBackend(data, keys, log, VoiceLabPrices.Load(), ElevenLabsRegion.Default,
            "isolated-test", () => VoiceLabBeta.IsAvailable(enabled, accepted, internalBuild), action => { action(); return Task.CompletedTask; });
        Assert.False(VoiceSpeakerCheck.WindowsNativeParityVerified);
        Assert.False(VoiceSpeakerCheck.Unavailable.Available);
        if (Expected(enabled, accepted, internalBuild))
        {
            var error = await Assert.ThrowsAsync<VoiceConsentException>(() => backend.DiscoverAsync("en", CancellationToken.None));
            Assert.Equal(VoiceConsentError.SpeakerUnavailable, error.Kind);
        }
        else
        {
            var error = await Assert.ThrowsAsync<VoiceLabException>(() => backend.DiscoverAsync("en", CancellationToken.None));
            Assert.Equal(VoiceLabErrorKind.ConsentRequired, error.Kind);
        }
        Assert.Equal(0, keys.Reads);
        Assert.False(Directory.Exists(root));
    }

    [Fact]
    public void ShippingToggleIsOffByDefaultAndUsesMacCopyWithCancelDefault()
    {
        var settings = new VoxClip.Core.Services.Settings.AppSettings("voxclip-settings/1");
        Assert.NotEqual(true, settings.GetBool("voiceLab.enabled"));
        Assert.NotEqual(true, settings.GetBool("voiceLab.betaNoticeAccepted"));
        Assert.False(RewriteEntryPolicy.Available(settings.GetBool("voiceLab.enabled") == true, settings.GetBool("voiceLab.betaNoticeAccepted") == true));
        var pane = Source("Controls/VoiceLabSettingsPane.cs");
        Assert.Contains("Show Voice Lab (beta)", pane);
        Assert.Contains("enabled.IsOn = App.Services.VoiceLabEnabled", pane);
        Assert.Contains("enabledContent.Visibility = App.Services.VoiceLabEnabled", pane);
        Assert.Contains("() => App.Services.VoiceLabEnabled", pane);
        Assert.Equal("Voice Lab is optional. Import, cut, captions, clips and export work without it.", VoiceLabCopy.ToggleCaption);
        Assert.Contains("Ui.ConfirmAsync(root, \"Turn on Voice Lab?\"", Source("Controls/VoiceLabDialogs.cs"));
        Assert.Contains("CloseButtonText = \"Cancel\", DefaultButton = ContentDialogButton.Close", Source("Controls/Ui.cs"));
        Assert.Empty(VoiceLabSettingsState.TurnOn(false).WritesAfterNotice(false));
    }

    [Fact]
    public void RealEntriesAndPanelCheckTheGateBeforeAnyProviderOrKeyAccess()
    {
        var page = ReleaseSource(Source("Pages/EditorPage.xaml.cs"));
        Assert.Contains("RewriteCommand.Visibility = App.Services.VoiceLabEnabled", page);
        Assert.Contains("RewriteCommand.IsEnabled = App.Services.VoiceLabEnabled && Transcript.CanRewrite", page);
        Assert.Contains("rewrite?.SettingsChanged(App.Services.VoiceLabEnabled)", page);
        Assert.Contains("connectorIsCurrent: () => App.Services.VoiceLabEnabled", page);
        var opening = page[page.IndexOf("private async Task OpenRewriteAsync", StringComparison.Ordinal)..page.IndexOf("private static async Task RediscoverRewriteAsync", StringComparison.Ordinal)];
        Assert.True(opening.IndexOf("if (!App.Services.VoiceLabEnabled", StringComparison.Ordinal) < opening.IndexOf("ProviderCatalog.ReadAsync", StringComparison.Ordinal));
        Assert.Equal(3, opening.Split("if (!CurrentOpening()) return;", StringSplitOptions.None).Length - 1);
        Assert.Contains("ConfigureRewriteGeneration(rewrite)", opening);
        Assert.DoesNotContain("TurnOnAsync", opening);
        var transcript = ReleaseSource(Source("Controls/TranscriptView.cs"));
        Assert.Contains("if (!App.Services.VoiceLabEnabled || model is null) return", transcript);
        Assert.Contains("cut, App.Services.VoiceLabEnabled, CanRewrite", transcript);
        Assert.Contains("if (App.Services.VoiceLabEnabled)", transcript);
        Assert.Contains("App.Services.Get(\"voiceLab.betaNoticeAccepted\", false)", transcript);
        Assert.Contains("KeyboardHelp.Text(", Source("MainWindow.xaml.cs"));
        Assert.Contains("RewriteEntryPolicy.Available", Source("Services/AppServices.cs"));
        var backend = ReleaseSource(Source("Services/RewriteGenerationBackend.cs"));
        Assert.True(backend.IndexOf("RequireCurrent(ct);", StringComparison.Ordinal) < backend.IndexOf("client.DiscoverModelsAsync", StringComparison.Ordinal));
        Assert.Contains("store.ActiveVoices()", backend);
        Assert.Contains("VoiceSpeakerCheck.Unavailable.ValidateAvailability()", backend);
        Assert.Contains("VoiceLabCopy.SpeakerUnavailable", Source("ViewModels/VoiceLabSession.cs"));
        Assert.Contains("speakerAvailable ?? (() => VoiceSpeakerCheck.Unavailable.Available)", Source("Services/VoiceStatementBackend.cs"));
    }

    [Fact]
    public void NativeReleaseHandoffCoversAllFlagPairsOnBothArchitectures()
    {
        var directory = Path.Combine(Root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui");
        var walk = File.ReadAllText(Path.Combine(directory, "native-voicelab-walk.ps1"));
        var driver = File.ReadAllText(Path.Combine(directory, "verify-windows.sh"));
        Assert.DoesNotContain("Release exposes Voice Lab while disabled", walk);
        Assert.Contains("A closed Release gate exposes a pane action", walk);
        Assert.Contains("A closed Release gate must display the opt-in switch as off", walk);
        Assert.Contains("Release:win-arm64 Release:win-x64", driver);
        Assert.Contains("steps=\"release-off release-enabled-no-notice release-notice-only release-on release-smoke\"", driver);
        Assert.DoesNotContain("elif [ \"$rid\" = win-arm64 ]", driver);
        Assert.All(walk, character => Assert.InRange((int)character, 0, 127));
    }

    [Fact]
    public void ReleaseSourceContainsProductGenerationButNoDebugVoiceLabHarness()
    {
        // A fast name-marker scan of the Release-compiled App source. The guarantee is inventory-based: Windows CI inspects
        // the real shipping App for both RIDs (ReleaseAssemblyInspectionTests covers the checker itself).
        foreach (var relative in new[] { "ViewModels/RewriteGeneration.cs", "ViewModels/RewriteGeneration.Takes.cs", "Services/RewriteGenerationBackend.cs", "Controls/RewritePanel.Takes.cs" })
            Assert.Contains("namespace VoxClip.App", ReleaseSource(Source(relative)));
        var forbidden = new[] { "VOXCLIP_DEBUG_", "DebugRewrite", "DebugConsent", "DebugAvailableSpeaker", "DebugVoice", "DebugFit", "DebugValidateTakeRows", "VoiceLabNativeProbe", "ShellNativeProbe", "TimelineNativeProbe", "TranscriptNativeProbe", "RestartNativeProbe" };
        foreach (var path in Directory.EnumerateFiles(AppDirectory, "*.cs", SearchOption.AllDirectories)
                     .Where(path => !Path.GetRelativePath(AppDirectory, path).Split(Path.DirectorySeparatorChar).Any(part => part is "bin" or "obj")))
        {
            var compiled = ReleaseSource(File.ReadAllText(path));
            Assert.DoesNotMatch(@"\bDebug[A-Z]\w*\b", compiled);
            foreach (var marker in forbidden) Assert.DoesNotContain(marker, compiled, StringComparison.Ordinal);
        }
    }

#if !DEBUG
    [Fact]
    public void ReleaseSurrogateMatchesTheShippingAllowlistsExactly()
    {
        // Fast macOS precheck only: the typecheck surrogate (VoxClip.WinCheck.dll, UseWinUI=false) must match the checked-in
        // Release allowlists exactly. The guarantee is the shipping inspection after each real Windows CI Release App build.
        var surrogate = Path.Combine(Root, ReleaseCheck.SurrogatePath);
        Assert.True(File.Exists(surrogate), "The fast surrogate precheck is a mandatory UI build prerequisite; Windows CI separately inspects both shipping RIDs.");
        var output = new StringWriter();
        var error = new StringWriter();
        var code = ReleaseCheck.Precheck(surrogate, Path.Combine(Root, ReleaseCheck.AllowlistDirectory), Root, null, output, error);
        Assert.True(code == 0, output + "\n" + error);
        var app = AssemblyInspector.Read(surrogate, Root);
        Assert.Equal("Release", app.Identity.Configuration);
        Assert.True(app.Identity.Optimized);
        foreach (var product in new[] { "VoxClip.App.ViewModels.RewriteGeneration", "VoxClip.App.Services.RewriteGenerationBackend", "VoxClip.App.Controls.RewritePanel", "VoxClip.App.ViewModels.RewriteSession", "VoxClip.App.ViewModels.RewriteTakeAccess" })
            Assert.Contains("type " + product, app.AllowlistLines);
        Assert.Empty(app.Forbidden);
        foreach (var marker in new[] { "VOXCLIP_DEBUG_", "rewrite-r11-", "--voice-lab-probe", "--native-editor-probe", "fixtures:" })
            Assert.DoesNotContain(app.Entries, entry => entry.Key.StartsWith("literal ", StringComparison.Ordinal) && entry.Key.Contains(marker, StringComparison.Ordinal));
    }
#endif

    private static string ReleaseSource(string source)
    {
        var active = true;
        var branches = new Stack<(bool Parent, bool Condition)>();
        var result = new StringBuilder();
        foreach (var line in source.Split('\n'))
        {
            var directive = line.Trim();
            if (directive.StartsWith("#if ", StringComparison.Ordinal))
            {
                var condition = directive[4..].Split("||", StringSplitOptions.TrimEntries).Any(term => term switch
                {
                    "DEBUG" or "WIN_UI_TESTS" => false,
                    "!DEBUG" or "DISABLE_XAML_GENERATED_MAIN" => true,
                    _ => throw new InvalidOperationException("Unrecognized Release condition: " + term)
                });
                branches.Push((active, condition)); active &= condition;
            }
            else if (directive == "#else") active = branches.Peek().Parent && !branches.Peek().Condition;
            else if (directive == "#endif") active = branches.Pop().Parent;
            else if (active) result.AppendLine(line);
        }
        Assert.Empty(branches);
        return result.ToString();
    }
    private sealed class ForbiddenKeys : IKeyProvider
    {
        internal int Reads;
        public Task<string?> GetKeyAsync(string account, CancellationToken ct)
        { Reads++; throw new InvalidOperationException("A blocked Voice Lab path must not read keys."); }
    }
    private sealed class MemoryKeys : IKeyProvider
    {
        internal int Reads;
        public Task<string?> GetKeyAsync(string account, CancellationToken ct)
        { Reads++; return Task.FromResult<string?>(null); }
    }
    private sealed class SilentLog : ILog
    {
        public void RegisterSecret(string secret) => throw new InvalidOperationException("No keys are used.");
        public void Write(LogLevel level, string category, string message) { }
        public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
#endif
