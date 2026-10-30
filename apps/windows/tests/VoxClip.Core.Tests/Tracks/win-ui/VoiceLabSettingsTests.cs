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

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, true, true)]
    [InlineData(true, false, true)]
    [InlineData(true, true, true)]
    public void PaneVisibilityMatchesStaging(bool enabled, bool internalBuild, bool visible) =>
        Assert.Equal(visible, VoiceLabSettingsState.PaneVisible(enabled, internalBuild));

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
#if DEBUG
        Assert.True(RewriteEntryPolicy.BuildEnabled);
        Assert.Contains("Ctrl+R  Rewrite", KeyboardHelp.Text);
#else
        Assert.False(RewriteEntryPolicy.BuildEnabled);
        Assert.DoesNotContain("Ctrl+R", KeyboardHelp.Text);
#endif
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
        Assert.Contains("VoiceLabDialogs.TurnOnAsync", editor);
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
