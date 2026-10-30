#if WIN_UI_TESTS
using System.Text.Json;
using System.Diagnostics;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Settings;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class VoiceLabSettingsTests
{
    [Fact]
    public void RestartPreparationLocksSettingsContentUntilResume()
    {
        var window = AppSource("SettingsWindow.xaml.cs");
        Assert.Contains("SettingsContent.IsEnabled = enabled", window);
        Assert.Contains("<ScrollViewer x:Name=\"SettingsContent\"", AppSource("SettingsWindow.xaml"));
        Assert.Contains("Navigation.IsEnabled = enabled", window);
        Assert.Contains("await restartPreparation.PrepareAsync(textCommits)", window);
        Assert.Contains("restartPreparation.Resume()", window);
        Assert.DoesNotContain("Func<bool> save", window);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task EditsDuringRestartPreparationAreBlockedAndFailuresResumeEditing(bool accepted)
    {
        var editing = true;
        var first = "20"; var second = "30";
        var savedFirst = first; var savedSecond = second;
        var release = new TaskCompletionSource<bool>();
        var firstCommit = new SettingsTextCommit(() => first, () => { savedFirst = first; return Task.FromResult(true); }, _ => { });
        var secondCommit = new SettingsTextCommit(() => second, async () =>
        {
            if (!await release.Task) return false;
            savedSecond = second;
            return true;
        }, _ => { });
        var state = new SettingsRestartState(enabled => editing = enabled);
        first = "12.50"; second = "40";
        var preparation = state.PrepareAsync([firstCommit, secondCommit]);
        Assert.False(preparation.IsCompleted);
        Assert.True(state.IsPreparing);
        Assert.False(editing);
        if (editing) { first = "99"; second = "100"; }
        Assert.Equal("12.50", savedFirst);
        Assert.Equal("12.50", first);
        Assert.Equal("40", second);
        release.SetResult(accepted);
        Assert.Equal(accepted, await preparation);
        Assert.Equal(accepted, state.IsPreparing);
        Assert.Equal(!accepted, editing);
        if (accepted)
        {
            if (editing) first = "99";
            Assert.Equal(savedFirst, first);
            Assert.Equal(savedSecond, second);
        }
        state.Resume();
        Assert.True(editing);
        Assert.False(state.IsPreparing);
        release = new TaskCompletionSource<bool>();
        release.SetResult(true);
        first = "50";
        Assert.True(await state.PrepareAsync([firstCommit, secondCommit]));
        Assert.Equal(first, savedFirst);
        state.Resume();
    }

    [Fact]
    public async Task FailedSettingsCommitRestoresEditingAndRemainsRetryable()
    {
        var editing = true; var text = "20"; var fail = true; var failures = 0;
        var commit = new SettingsTextCommit(() => text, () => fail ? throw new IOException("save failed") : Task.FromResult(true), _ => failures++);
        var state = new SettingsRestartState(enabled => editing = enabled);
        text = "12.50";
        Assert.False(await state.PrepareAsync([commit]));
        Assert.Equal(1, failures);
        Assert.True(editing);
        Assert.False(state.IsPreparing);
        fail = false;
        Assert.True(await state.PrepareAsync([commit]));
        Assert.False(editing);
        state.Resume();
        Assert.True(editing);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LaterRestartVetoOrDispatchFailureResumesSettings(bool dispatchFails)
    {
        var editing = true; var text = "20";
        var commit = new SettingsTextCommit(() => text, () => Task.FromResult(true), _ => { });
        var state = new SettingsRestartState(enabled => editing = enabled);
        var drain = new TaskCompletionSource();
        var settings = new PreparedSettings(state, commit, drain.Task);
        var coordinator = new UpdateRestartCoordinator(() => [new VetoWindow(!dispatchFails)]);
        text = "12.50";
        var restart = coordinator.RunAsync(settings, _ => throw new IOException("dispatch failed"), TestContext.Current.CancellationToken);
        Assert.False(restart.IsCompleted);
        Assert.False(editing);
        if (editing) text = "99";
        Assert.Equal("12.50", text);
        drain.SetResult();
        Assert.Equal(dispatchFails ? RestartResult.UpdateFailed : RestartResult.SaveFailed, await restart);
        Assert.True(editing);
        Assert.False(state.IsPreparing);
    }

    private sealed class PreparedSettings(SettingsRestartState state, SettingsTextCommit commit, Task drain) : IUpdateRestartSettings
    {
        public async Task<RestartPreparation> PrepareAsync() => await state.PrepareAsync([commit]) ? RestartPreparation.Ready : RestartPreparation.SaveFailed;
        public RestartPreparation Freeze() => RestartPreparation.Ready;
        public Task DrainAsync(CancellationToken ct) => drain.WaitAsync(ct);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public void Resume() => state.Resume();
    }

    private sealed class VetoWindow(bool veto) : IUpdateRestartWindow
    {
        public bool IsBusyForRestart => false;
        public Task<RestartPreparation> PrepareForRestartAsync() => Task.FromResult(veto ? RestartPreparation.SaveFailed : RestartPreparation.Ready);
        public void ResumeAfterRestart() { }
    }

    [Fact]
    public async Task SynchronouslyRejectedTextCommitCanBeRetried()
    {
        var text = "20"; var accepted = false; var attempts = 0;
        var commit = new SettingsTextCommit(() => text, () => { attempts++; return Task.FromResult(accepted); }, _ => { });
        text = "12.50";
        Assert.False(await commit.CommitAsync());
        accepted = true;
        Assert.True(await commit.CommitAsync());
        Assert.Equal(2, attempts);
    }

    [Fact]
    public void MicrophoneCopyAndNativeSafetyFollowLeadDecisions()
    {
        Assert.Equal("No microphone found. Connect one and try again.", VoiceLabCopy.MicrophoneFailure(VoxClip.Media.Audio.MicrophoneError.NoDevice));
        Assert.Equal("Waiting for the microphone…", VoiceLabCopy.MicrophoneWaiting);
        Assert.Equal("Microphone: Input", VoiceLabCopy.MicrophoneDeviceLine("Input"));
        Assert.Equal("ms-settings:privacy-microphone", VoiceLabCopy.MicrophoneSettingsUri);
        Assert.Equal("Open Settings", VoiceLabCopy.MicrophoneOpenSettings);
        foreach (var error in Enum.GetValues<VoxClip.Media.Audio.MicrophoneError>()) Assert.NotEmpty(VoiceLabCopy.MicrophoneFailure(error));
        var root = Path.GetDirectoryName(Shared)!;
        var endpoint = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.Media/Audio/MicrophoneDevices.cs"));
        Assert.Contains("DataFlow.Capture, Role.Console", endpoint);
        Assert.Contains(".WithSharedMode().WithEventSync()", endpoint);
        Assert.DoesNotContain("WithFormat", endpoint); Assert.DoesNotContain("WithDefaultDeviceStreamRouting", endpoint);
        Assert.Contains("CreateNotificationClient", endpoint); Assert.Contains("args.DeviceId == boundId", endpoint);
        Assert.DoesNotContain("notifications.DefaultDeviceChanged +=", endpoint);
        var script = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/microphone-native.ps1"));
        Assert.Contains("$HostBackupSha256", script); Assert.Contains("} finally {", script);
        Assert.Contains("registry restoration is unverified", script); Assert.Contains("$inventory.Result.CaptureCount", script);
        Assert.All(script, character => Assert.True(character < 128));
    }

    [Fact]
    public void EachInvalidCapSubmissionExplicitlyAnnouncesEvenUnchangedCopy()
    {
        var pane = AppSource("Controls/VoiceLabSettingsPane.cs");
        var validation = pane[pane.IndexOf("if (parsed.Error is", StringComparison.Ordinal)..];
        Assert.Contains("Ui.Show(message, error, InfoBarSeverity.Warning);\n                    Ui.Announce(message, error, \"voice-lab-message\");", validation);
        Assert.Contains("if (message.Message != VoiceLabCopy.CapError)", pane);
    }

    [Fact]
    public async Task FailedNavigationSaveRemainsUncommittedAndRetryable()
    {
        var text = "20";
        var attempts = 0;
        var errors = 0;
        var commit = new SettingsTextCommit(() => text, () =>
        {
            attempts++;
            return attempts == 1 ? Task.FromException<bool>(new IOException("Save failed")) : Task.FromResult(true);
        }, _ => errors++);
        text = "12.50";
        Assert.False(await commit.CommitAsync());
        Assert.True(await commit.CommitAsync());
        Assert.True(await commit.CommitAsync());
        Assert.Equal(2, attempts);
        Assert.Equal(1, errors);
        var pane = AppSource("Controls/VoiceLabSettingsPane.cs");
        Assert.Contains("settings.GetString(\"voiceLab.monthlyCapUsd.\" + provider.Item1));", pane);
        var window = AppSource("SettingsWindow.xaml.cs");
        Assert.Contains("Navigation.SelectedItem = currentSection; return;", window);
        Assert.True(window.IndexOf("await commit.CommitAsync()", StringComparison.Ordinal)
            < window.IndexOf("textCommits.Clear()", StringComparison.Ordinal));
    }

    [Fact]
    public async Task RestartAwaitsTextCommitBeforeFreezingAndInvalidEditsVetoIt()
    {
        var text = "20";
        var release = new TaskCompletionSource<bool>();
        var commit = new SettingsTextCommit(() => text, () => release.Task, _ => { });
        text = "12.50";
        var pending = commit.CommitAsync();
        Assert.False(pending.IsCompleted);
        release.SetResult(false);
        Assert.False(await pending);
        var coordinator = AppSource("Services/UpdateRestartCoordinator.cs");
        Assert.True(coordinator.IndexOf("await settings.PrepareAsync()", StringComparison.Ordinal)
            < coordinator.IndexOf("settings.Freeze()", StringComparison.Ordinal));
        Assert.Contains("await commit.CommitAsync()", AppSource("SettingsWindow.xaml.cs"));
        Assert.Contains("await App.Services.SetAsync(\"voiceLab.monthlyCapUsd.", AppSource("Controls/VoiceLabSettingsPane.cs"));
    }

    private static string Shared => Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
    private static string AppSource(string file) => File.ReadAllText(Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "src", "VoxClip.App", file));

    [Fact]
    public void PaneIsVisibleForShippingOptInEvenWhenDisabled() =>
        Assert.True(VoiceLabSettingsState.PaneVisible);

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task TurnOnQueuesAcceptanceBeforeEnablement(bool accepted)
    {
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-voice-lab-settings-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "settings.json");
        var store = new SettingsStore(path);
        var queue = new SettingsWriteQueue(store);
        var ct = TestContext.Current.CancellationToken;
        try
        {
            queue.Initialize(await store.LoadAsync(ct));
            if (accepted) await queue.SetAsync("voiceLab.betaNoticeAccepted", true, ct);
            var writes = new List<string>();
            queue.Changed += key =>
            {
                writes.Add(key);
                if (key == "voiceLab.enabled") Assert.True(queue.Current.GetBool("voiceLab.betaNoticeAccepted"));
                else Assert.False(queue.Current.GetBool("voiceLab.enabled"));
            };
            var turnOn = VoiceLabSettingsState.TurnOn(accepted);
            Assert.Equal(!accepted, turnOn.ShowNotice);
            foreach (var write in turnOn.WritesAfterNotice(true)) await queue.SetAsync(write.Key, write.Value, ct);
            Assert.Equal(new[] { "voiceLab.betaNoticeAccepted", "voiceLab.enabled" }, writes);
            await queue.FlushAsync(ct);
            var saved = await new SettingsStore(path).LoadAsync(ct);
            Assert.True(saved.GetBool("voiceLab.betaNoticeAccepted")); Assert.True(saved.GetBool("voiceLab.enabled"));
        }
        finally { await queue.FlushAsync(ct); if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task DevelopmentBuildsReadUnsetVoiceLabAsOnWithoutWritingItAndKeepAnExplicitOff()
    {
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-voice-lab-development-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "settings.json");
        // The App's own store (AppServices) passes exactly this overlay.
        var overlay = VoiceLabBeta.DevelopmentDefaults(RewriteEntryPolicy.InternalBuild);
        var store = new SettingsStore(path) { UnsetDefaults = overlay };
        var queue = new SettingsWriteQueue(store);
        var ct = TestContext.Current.CancellationToken;
        try
        {
            queue.Initialize(await store.LoadAsync(ct));
            var development = RewriteEntryPolicy.InternalBuild;
#if VOXCLIP_DEVELOPMENT
            Assert.True(development);
#else
            Assert.False(development);
            Assert.Empty(overlay);
#endif
            Assert.Equal(development, queue.Current.GetBool("voiceLab.enabled"));
            Assert.Equal(development, queue.Current.GetBool("voiceLab.betaNoticeAccepted"));
            Assert.Equal(development, RewriteEntryPolicy.Available(queue.Current.GetBool("voiceLab.enabled") == true, queue.Current.GetBool("voiceLab.betaNoticeAccepted") == true));
            await queue.SetAsync("general.appearance", "dark", ct);
            await queue.FlushAsync(ct);
            Assert.Equal(development, queue.Current.GetBool("voiceLab.enabled"));
            Assert.Equal(new[] { "general.appearance", "schema" }, Written(path));
            await queue.SetAsync("voiceLab.enabled", false, ct);
            await queue.FlushAsync(ct);
            Assert.Equal(new[] { "general.appearance", "schema", "voiceLab.enabled" }, Written(path));
            var reopened = await new SettingsStore(path) { UnsetDefaults = overlay }.LoadAsync(ct);
            Assert.False(reopened.GetBool("voiceLab.enabled"));
            Assert.Equal(development, reopened.GetBool("voiceLab.betaNoticeAccepted"));
            Assert.False(RewriteEntryPolicy.Available(reopened.GetBool("voiceLab.enabled") == true, reopened.GetBool("voiceLab.betaNoticeAccepted") == true));
        }
        finally { await queue.FlushAsync(ct); if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task StoresWithoutTheOverlayKeepTheShippedOffDefault()
    {
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-voice-lab-shipped-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "settings.json");
        var store = new SettingsStore(path);
        var queue = new SettingsWriteQueue(store);
        var ct = TestContext.Current.CancellationToken;
        try
        {
            Assert.Empty(store.UnsetDefaults);
            Assert.Empty(VoiceLabBeta.DevelopmentDefaults(false));
            queue.Initialize(await store.LoadAsync(ct));
            Assert.False(queue.Current.GetBool("voiceLab.enabled"));
            Assert.False(queue.Current.GetBool("voiceLab.betaNoticeAccepted"));
            Assert.False(RewriteEntryPolicy.Available(queue.Current.GetBool("voiceLab.enabled") == true, queue.Current.GetBool("voiceLab.betaNoticeAccepted") == true));
            await queue.SetAsync("general.appearance", "dark", ct);
            await queue.FlushAsync(ct);
            Assert.Equal(new[] { "general.appearance", "schema" }, Written(path));
        }
        finally { await queue.FlushAsync(ct); if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    [Fact]
    public void AppServicesPassesTheDevelopmentOverlayOnlyToTheUsersStore()
    {
        var services = AppSource("Services/AppServices.cs");
        Assert.Contains("new SettingsStore { UnsetDefaults = VoiceLabBeta.DevelopmentDefaults(RewriteEntryPolicy.InternalBuild) }", services);
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(services, "UnsetDefaults ="));
        Assert.Contains("var next = Current.With(key, JsonSerializer.SerializeToElement(value));", AppSource("Services/SettingsWriteQueue.cs"));
    }

    private static string[] Written(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        return document.RootElement.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal).ToArray();
    }

    [Fact]
    public void CancelWritesNothing() => Assert.Empty(VoiceLabSettingsState.TurnOn(false).WritesAfterNotice(false));

    [Fact]
    public void LabelChoicesRoundTripInMacOrder()
    {
        Assert.Equal(new[] { "Top right", "Top left", "Bottom right", "Bottom left" }, VoiceLabSettingsState.LabelChoices.Select(choice => choice.Label));
        var expected = new[] { VoiceLabLabelPosition.TopRight, VoiceLabLabelPosition.TopLeft, VoiceLabLabelPosition.BottomRight, VoiceLabLabelPosition.BottomLeft };
        var settings = new AppSettings("voxclip-settings/1");
        foreach (var (choice, index) in VoiceLabSettingsState.LabelChoices.Select((choice, index) => (choice, index)))
        {
            settings.Set("voiceLab.labelPosition", JsonSerializer.SerializeToElement(choice.Key));
            Assert.Equal(expected[index], VoiceLabSettingsState.LabelPosition(settings.GetString("voiceLab.labelPosition")));
        }
        Assert.Equal(VoiceLabLabelPosition.TopRight, VoiceLabSettingsState.LabelPosition(null));
        Assert.Equal(VoiceLabLabelPosition.TopRight, VoiceLabSettingsState.LabelPosition("unknown"));
    }

    [Theory]
    [InlineData("20", "20")]
    [InlineData("12.50", "12.5")]
    [InlineData("", null)]
    public void CapInputUsesTheCoreCanonicalStorage(string text, string? canonical)
    {
        var parsed = VoiceLabSettingsState.MonthlyCap(text);
        Assert.Null(parsed.Error); Assert.Equal(canonical, parsed.Canonical);
        var settings = new AppSettings("voxclip-settings/1");
        settings.SetVoiceLabMonthlyCap("fal", parsed.Amount);
        Assert.Equal(canonical, settings.GetString("voiceLab.monthlyCapUsd.fal"));
        Assert.Equal(text.Length == 0 ? null : decimal.Parse(text, System.Globalization.CultureInfo.InvariantCulture), parsed.Amount);
    }

    [Theory]
    [InlineData("-1")]
    [InlineData("1.234")]
    [InlineData("1000000000")]
    [InlineData("abc")]
    [InlineData(" 20 ")]
    public void InvalidCapKeepsTheOldValueAndReportsTheExactError(string text)
    {
        var settings = new AppSettings("voxclip-settings/1"); settings.SetVoiceLabMonthlyCap("fal", 20);
        var parsed = VoiceLabSettingsState.MonthlyCap(text);
        Assert.Equal(VoiceLabCopy.CapError, parsed.Error);
        if (parsed.Error is null) settings.SetVoiceLabMonthlyCap("fal", parsed.Amount);
        Assert.Equal(20m, settings.GetVoiceLabMonthlyCap("fal"));
    }

    [Fact]
    public void CopyMatchesTheBindingSpecAndMacKeyGuidance()
    {
        Assert.Equal("Voice Lab can clone your own voice, change your voice and re-voice a few words. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key and, for lip sync, your fal.ai or sync.so key.", VoiceLabCopy.BetaNotice);
        var root = Path.GetDirectoryName(Shared)!;
        Assert.Contains(VoiceLabCopy.BetaNotice, File.ReadAllText(Path.Combine(root, "doc", "spec", "voice-lab.md")));
        var mac = File.ReadAllText(Path.Combine(root, "apps", "macos", "Sources", "VoxClip", "VoiceLabSettings.swift"));
        Assert.Contains(VoiceLabCopy.KeyGuidance, mac); Assert.Contains(VoiceLabCopy.KeyPermissions, mac);
        Assert.Contains("Ctrl+R  Rewrite", KeyboardHelp.Text(true, true));
        Assert.DoesNotContain("Ctrl+R", KeyboardHelp.Text(false, false));
    }

    [Fact]
    public void PaneHasAccessibleNamesHeadingsAndThemeOnlyWarnings()
    {
        var pane = AppSource(Path.Combine("Controls", "VoiceLabSettingsPane.cs"));
        foreach (var name in new[] { "Show Voice Lab (beta)", "Your API keys", "ElevenLabs", "fal.ai", "sync.so", " API key", "Save ", " key", "Forget ",
            "Warn me above this amount a month · ", "Label position", "Add Content Credentials (C2PA) to exports", "Storage", "Show in File Explorer" }) Assert.Contains(name, pane);
        Assert.Contains("AutomationHeadingLevel.Level1", pane); Assert.Contains("AutomationHeadingLevel.Level2", pane);
        Assert.Contains("SetAutomationId(message, \"voice-lab-message\")", pane);
        Assert.Contains("SetName(key, provider.Item1 + \" API key\")", pane);
        Assert.Contains("SetName(save, \"Save \" + provider.Item1 + \" key\")", pane);
        Assert.Contains("SetName(forget, \"Forget \" + provider.Item1 + \" key\")", pane);
        Assert.Contains("InfoBarSeverity.Warning", pane); Assert.Contains("Ui.Announce", pane);
        Assert.Contains("TrackTextField", pane); Assert.Contains("SetVoiceLabMonthlyCap", pane);
        Assert.Contains("key.Focus(FocusState.Programmatic)", pane);
        Assert.DoesNotContain("Colors.Red", pane); Assert.DoesNotContain("SolidColorBrush", pane);
        Assert.Contains("keyWrites++", AppSource("SettingsWindow.xaml.cs"));
    }

    [Fact]
    public void EntryAndAllRenderSitesUseTheSharedPolicy()
    {
        var editor = AppSource(Path.Combine("Pages", "EditorPage.xaml.cs"));
        Assert.DoesNotContain("VoiceLabDialogs.TurnOnAsync", editor);
        Assert.Contains("if (!App.Services.VoiceLabEnabled)", editor);
        Assert.DoesNotContain("Title = \"Turn on Voice Lab\"", editor);
        Assert.DoesNotContain("EnablementCopy", AppSource(Path.Combine("ViewModels", "RewriteEntryPolicy.cs")));
        var app = Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "src", "VoxClip.App");
        var hardCoded = Directory.EnumerateFiles(app, "*.cs", SearchOption.AllDirectories)
            .Where(path => !path.Split(Path.DirectorySeparatorChar).Any(part => part is "obj" or "bin"))
            .Where(path => File.ReadAllText(path).Contains("VoiceLabLabelPosition.TopRight", StringComparison.Ordinal)).ToArray();
        Assert.EndsWith("VoiceLabSettingsState.cs", Assert.Single(hardCoded));
        var secrets = AppSource(Path.Combine("Services", "SecretStore.cs"));
        Assert.Contains("\"fal-api-key\"", secrets); Assert.Contains("\"syncso-api-key\"", secrets);
        var dialogs = AppSource(Path.Combine("Controls", "VoiceLabDialogs.cs"));
        Assert.Contains("Ui.ConfirmAsync(root, \"Turn on Voice Lab?\", VoiceLabCopy.BetaNotice, \"Turn on\", ct)", dialogs);
        Assert.Contains("ContentDialogButton.Close", AppSource(Path.Combine("Controls", "Ui.cs")));
        Assert.Contains("if (ct.IsCancellationRequested) dialog.Hide()", AppSource(Path.Combine("Controls", "Ui.cs")));
    }

    [Fact]
    public void LabelPreferenceChangesTheV3ExportFingerprintAndLedgerStatus()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Shared, "fixtures", "voice-lab", "passage-render-v3.voxclip")));
        var target = new ExportTarget.FullEdit();
        var right = ExportFingerprint.For(project, target, VoiceLabLabelPosition.TopRight);
        var left = ExportFingerprint.For(project, target, VoiceLabLabelPosition.BottomLeft);
        Assert.NotEqual(right, left);
        var editor = new EditorViewModel(project);
        editor.SetExportRecords([new(project.Id, "full", DateTimeOffset.UtcNow, right, project.Captions.StyleId, project.Export.Aspect, "unused.mp4")]);
        Assert.Equal(ClipExportState.Exported, editor.ExportStatus(null).State);
        editor.SetVoiceLabLabelPosition(VoiceLabLabelPosition.BottomLeft);
        Assert.Equal(ClipExportState.ChangedSinceExport, editor.ExportStatus(null).State);
    }

    [Fact]
    public void NativeHarnessRecordsIdleAndOwnsThemeRestoration()
    {
        var directory = Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "tests", "VoxClip.Core.Tests", "Tracks", "win-ui");
        var gate = File.ReadAllText(Path.Combine(directory, "verify-windows.sh"));
        foreach (var contract in new[] { "ioreg -c IOHIDSystem", "idle_pause() { sleep 30; }", "-lt 300", "+ 1800", "void-user-input", "owed-idle-timeout", "idleBefore", "idleAfter", "run_input_step \"$step\"", "failed-theme-restore" }) Assert.Contains(contract, gate);
        var native = File.ReadAllText(Path.Combine(directory, "native-voicelab-walk.ps1"));
        foreach (var contract in new[] { "6GB + 1536MB", "finally {", "themeRestored=$themeRestored", "Get-FileHash -LiteralPath $file.path", "Never ship fixtures", "tabOrder=@($tabOrder)", "Assert-Flags $false $false", "Assert-Flags $true $true" }) Assert.Contains(contract, native);
        Assert.DoesNotContain("Restart-Computer", native);
        foreach (var name in new[] { "native-voicelab-walk.ps1", "native-accessibility-walk.ps1", "capture-windows.ps1", "launch-windows.ps1", "run-screenshots.ps1", "build-windows.ps1" })
            Assert.All(File.ReadAllBytes(Path.Combine(directory, name)), value => Assert.True(value < 128, name));
    }

    [Theory]
    [InlineData("wait")]
    [InlineData("drop")]
    [InlineData("timeout")]
    [InlineData("failure")]
    [InlineData("restore")]
    public async Task HostIdleGateWaitsVoidsRetriesAndTimesOutWithoutVmAccess(string scenario)
    {
        if (OperatingSystem.IsWindows()) Assert.Skip("Mac/Linux shell gate unit test; no VM is used.");
        var directory = Directory.CreateTempSubdirectory("voxclip-idle-gate-").FullName;
        try
        {
            var gate = Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "tests", "VoxClip.Core.Tests", "Tracks", "win-ui", "verify-windows.sh");
            var start = new ProcessStartInfo("/bin/bash") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            start.ArgumentList.Add("-c");
            start.ArgumentList.Add("""
                source "$1"
                STAGING=$2
                scenario=$3
                printf 0 > "$STAGING/clock"
                printf 0 > "$STAGING/reads"
                printf 0 > "$STAGING/runs"
                idle_clock() { cat "$STAGING/clock"; }
                idle_pause() { printf 1801 > "$STAGING/clock"; }
                host_idle_seconds() {
                    local count=$(( $(cat "$STAGING/reads") + 1 ))
                    printf '%s' "$count" > "$STAGING/reads"
                    if [ "$scenario" = timeout ]; then echo 0
                    elif [ "$scenario" = wait ] && [ "$count" = 1 ]; then echo 299
                    elif [ "$scenario" = drop ] && [ "$count" = 2 ]; then echo 1
                    else echo 300; fi
                }
                if [ "$scenario" = wait ]; then idle_pause() { printf 30 > "$STAGING/clock"; }; fi
                action() {
                    printf '%s' "$(( $(cat "$STAGING/runs") + 1 ))" > "$STAGING/runs"
                    if [ "$scenario" = failure ]; then return 7; fi
                    if [ "$scenario" = restore ]; then return 86; fi
                }
                status=0
                run_input_step test Debug win-arm64 action || status=$?
                case "$scenario" in
                    wait) [ "$status" = 0 ] && [ "$(cat "$STAGING/runs")" = 1 ] ;;
                    drop) [ "$status" = 0 ] && [ "$(cat "$STAGING/runs")" = 2 ] && grep -q void-user-input "$STAGING/idle-gate.jsonl" ;;
                    timeout) [ "$status" = 75 ] && [ "$(cat "$STAGING/runs")" = 0 ] && grep -q owed-idle-timeout "$STAGING/idle-gate.jsonl" ;;
                    failure) [ "$status" = 7 ] && grep -q failed "$STAGING/idle-gate.jsonl" ;;
                    restore) [ "$status" = 86 ] && [ "$(cat "$STAGING/runs")" = 1 ] && grep -q failed-theme-restore "$STAGING/idle-gate.jsonl" ;;
                esac
                """);
            start.ArgumentList.Add("idle-gate-test"); start.ArgumentList.Add(gate); start.ArgumentList.Add(directory); start.ArgumentList.Add(scenario);
            using var process = Process.Start(start)!;
            var ct = TestContext.Current.CancellationToken;
            var output = process.StandardOutput.ReadToEndAsync(ct); var error = process.StandardError.ReadToEndAsync(ct);
            try { await process.WaitForExitAsync(ct).WaitAsync(TimeSpan.FromSeconds(10), ct); }
            finally { if (!process.HasExited) process.Kill(true); }
            Assert.True(process.ExitCode == 0, await output + await error);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task NativePowerShellIsParsedByTheWindows51Parser()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("PowerShell 5.1 parser is a Windows CI gate; no native input runs here.");
        var directory = Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "tests", "VoxClip.Core.Tests", "Tracks", "win-ui");
        var start = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add("-NoProfile"); start.ArgumentList.Add("-NonInteractive"); start.ArgumentList.Add("-Command");
        start.ArgumentList.Add("$failed=$false; Get-ChildItem -LiteralPath '" + directory.Replace("'", "''", StringComparison.Ordinal) + "' -Filter '*.ps1' | ForEach-Object { $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$errors); if($errors){$errors | Out-String | Write-Output; $failed=$true} }; if($failed){exit 1}");
        using var process = Process.Start(start)!;
        var ct = TestContext.Current.CancellationToken;
        var output = process.StandardOutput.ReadToEndAsync(ct); var error = process.StandardError.ReadToEndAsync(ct);
        try { await process.WaitForExitAsync(ct).WaitAsync(TimeSpan.FromSeconds(30), ct); }
        finally { if (!process.HasExited) process.Kill(true); }
        Assert.True(process.ExitCode == 0, await output + await error);
    }
}
#endif
