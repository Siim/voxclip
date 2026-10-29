#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class StartupCheckTests
{
    [Fact]
    public void RightColumnHasABoundedSingleSurfaceWithoutInactivePeerSubtrees()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/RightColumn.cs"));
        Assert.Equal(2, source.Split("Children.Add(", StringSplitOptions.None).Length - 1);
        Assert.DoesNotContain("Children.Insert(", source);
        Assert.DoesNotContain("Visibility.Collapsed", source);
        Assert.Contains("surface.Child = panel", source);
        Assert.Equal(2, source.Split("surface.Child = captions", StringSplitOptions.None).Length - 1);
    }

    [Fact]
    public async Task TranscriptionChoicesExcludeVerifiedVadDependencies()
    {
        var catalogue = await new VoxClip.Core.Services.Models.ModelCatalog().GetModelsAsync(TestContext.Current.CancellationToken);
        var installed = catalogue.Select(model => new VoxClip.Core.Services.Models.InstalledModel(model.Id, "unused", true, null)).ToArray();
        var choices = VoxClip.App.ViewModels.TranscriptionModelChoices.InstalledLocal(catalogue, installed);
        Assert.Contains(choices, model => model.Id == "whisper-small.en-q5_1");
        Assert.DoesNotContain(choices, model => model.Id == "silero-vad-v6.2.0");
        Assert.All(choices, model => Assert.Equal("asr", model.Kind));
        Assert.Empty(VoxClip.App.ViewModels.TranscriptionModelChoices.InstalledLocal(catalogue,
            installed.Select(model => model with { Verified = false }).ToArray()));
    }

    [Fact]
    public void FirstLaunchTourWaitsForTheWindowRootAndCleansUpItsSubscription()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/MainWindow.xaml.cs"));
        var start = source.IndexOf("internal async Task ShowOnboardingAsync()", StringComparison.Ordinal);
        var end = source.IndexOf("internal async Task CheckUpdatesAsync", start, StringComparison.Ordinal);
        var method = source[start..end];
        Assert.Contains("Root.Loaded += Ready", method);
        Assert.Contains("Root.Loaded -= Ready", method);
        Assert.Contains("await loaded.Task.WaitAsync(lifetime.Token)", method);
        Assert.True(method.IndexOf("await loaded.Task", StringComparison.Ordinal) < method.IndexOf("new OnboardingDialog", StringComparison.Ordinal));
    }

    [Fact]
    public void FlyoutEscapeWaitsForClosedAndReceivesHandledKeys()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/SelectionFlyout.cs"));
        Assert.Contains("flyout.Closed +=", source);
        Assert.Contains("bar.AddHandler(UIElement.KeyDownEvent, escape, true)", source);
        Assert.Contains("owner.DispatcherQueue.TryEnqueue", source);
        Assert.Contains("restoreFocus |= focus", source);
        Assert.Contains("flyout.Closing +=", source);
        Assert.Contains("restoreFocus |= InputState.Down(VirtualKey.Escape)", source);
    }

    [Fact]
    public void ParagraphPreparationAndLayoutRedrawOnlyTheAffectedParagraph()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/TranscriptView.cs"));
        var prepared = source[source.IndexOf("private void Prepared(", StringComparison.Ordinal)..source.IndexOf("private FrameworkElement ClipBadge", StringComparison.Ordinal)];
        Assert.DoesNotContain("RefreshVisuals()", prepared);
        Assert.Contains("RefreshParagraph(realized[grid])", prepared);
        var layout = source[source.IndexOf("private void ParagraphSizeChanged", StringComparison.Ordinal)..source.IndexOf("public void RefreshVisuals()", StringComparison.Ordinal)];
        Assert.DoesNotContain("foreach (var visual in realized.Values)", layout);
        Assert.Contains("RefreshParagraph(changed)", layout);
        Assert.Contains("visual.LayoutHandler = (_, _) => ParagraphLayoutUpdated(visual)", prepared);
        Assert.Contains("Text.LayoutUpdated -= LayoutHandler", source);
        var paragraph = source[source.IndexOf("private void RefreshParagraph(", StringComparison.Ordinal)..source.IndexOf("private int Hit(", StringComparison.Ordinal)];
        Assert.DoesNotContain("TryEnqueue(RefreshVisuals)", paragraph);
        Assert.Contains("visual.Released", paragraph);
    }
    [Fact]
    public void RouteRepetitionsUseFreshProcessesAndAllFourRealRoutes()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Services/ShellRouteProbe.cs"));
        var script = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/run-route-repetitions.ps1"));
        Assert.Contains("window.OpenPathAsync(first, ShellPath.Launch)", source);
        Assert.Contains("window.DebugInvokeAsync(recent)", source);
        Assert.Contains("window.OpenDroppedAsync(dropped)", source);
        Assert.Contains("prior.DebugCaptionGateAsync", source);
        Assert.Contains("StartupCheck.HasContent(pixels)", source);
        Assert.Contains("$iteration -le 5", script);
        Assert.Contains("iteration-$iteration", script);
        Assert.Contains("$env:VOXCLIP_DATA_DIR = $data", script);
        Assert.Contains("$_.ProcessId -eq $app.Id", script);
        Assert.Contains("'first-open','recent','drop','caption-file-replacement'", script);
        Assert.Contains("$observed.SourceSha -ne $SourceSha", script);
        Assert.Contains("Assert-Lease", script);
        Assert.All(script, character => Assert.InRange((int)character, 0, 127));
    }

    [Fact]
    public void RewriteProbeRestoresItsStateEvenWhenReadinessFails()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.NativeProbe.cs"));
        var gate = source[source.IndexOf("internal async Task DebugRewriteGateAsync", StringComparison.Ordinal)..source.IndexOf("internal async Task DebugBusyGateAsync", StringComparison.Ordinal)];
        var cleanup = gate[gate.LastIndexOf("finally", StringComparison.Ordinal)..];
        Assert.Contains("rewrite?.Dispose(); rightContent?.CloseRewrite();", cleanup);
        Assert.Contains("ViewModel.SetTranscript(originalTranscript)", cleanup);
        Assert.Contains("ViewModel.SetMediaUnavailable(originalReadOnly)", cleanup);
        Assert.Contains("candidate.IsLoaded && candidate.ActualWidth > 0", gate);
        Assert.Contains("candidate.FocusTarget", gate);
        Assert.DoesNotContain("Task.Delay(250)", gate);
        Assert.DoesNotContain("Task.Delay(150)", gate);
    }

    [Fact]
    public void ScreenshotDriverReresolvesOnlyTransientPeersWithoutDroppingAssertions()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var script = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/capture-windows.ps1"));
        Assert.Contains("$attempt -lt 40", script);
        Assert.Contains("$attempt -lt 4", script);
        Assert.Contains("Find-Visible $locator.Window $locator.Name $locator.Prefix", script);
        Assert.Contains("-not (Test-TransientPeerFailure $_)", script);
        Assert.Contains("$pattern.Current.ToggleState -ne $toggleTarget", script);
        Assert.Contains("$scroll.ScrollIntoView()", script);
        Assert.All(script, character => Assert.InRange((int)character, 0, 127));
    }

    [Fact]
    public void FrameSummaryUsesRenderingIntervalsAndTheSixtyHertzDropBudget()
    {
        var summary = FrameTimeSummary.From([10, 16.7, 20, 33, 34, 50]);
        Assert.Equal(6, summary.Frames);
        Assert.Equal(20, summary.P50Milliseconds);
        Assert.Equal(50, summary.P95Milliseconds);
        Assert.Equal(50, summary.MaxMilliseconds);
        Assert.Equal(4.0 / 6, summary.ShareOver16Point7);
        Assert.Equal(2.0 / 6, summary.ShareOver33);
        Assert.Equal(4, summary.EstimatedDroppedFrames);
        Assert.Throws<ArgumentException>(() => FrameTimeSummary.From([]));
        Assert.Throws<ArgumentOutOfRangeException>(() => FrameTimeSummary.From([double.NaN]));
        Assert.Throws<ArgumentOutOfRangeException>(() => FrameTimeSummary.From([0]));
    }

    [Fact]
    public void ScrollFrameProbeRunsOutsideDebugAndUsesRenderingNotUpdateLayoutTiming()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var app = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/App.xaml.cs"));
        var route = app.IndexOf("--transcript-frame-probe", StringComparison.Ordinal);
        Assert.True(route >= 0);
        Assert.True(app.LastIndexOf("#if DEBUG", route, StringComparison.Ordinal) < app.LastIndexOf("#endif", route, StringComparison.Ordinal));
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Services/TranscriptFrameProbe.cs"));
        Assert.Contains("CompositionTarget.Rendering += Rendering", probe);
        Assert.Contains("CompositionTarget.Rendering -= Rendering", probe);
        Assert.Contains("((RenderingEventArgs)args).RenderingTime", probe);
        Assert.Contains("scroll.ChangeView", probe);
        Assert.Contains("Enumerable.Range(0, 9000)", probe);
        Assert.Contains("intervals.Count >= 120", probe);
        Assert.Contains("summary.P95Milliseconds <= 20", probe);
        Assert.DoesNotContain("Task.Delay(16)", probe);
        var script = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/run-transcript-frames.ps1"));
        Assert.Contains("\\Release\\", script);
        var sampling = script[(script.IndexOf("[IO.File]::WriteAllText($start", StringComparison.Ordinal))..];
        Assert.DoesNotContain("FindFirst", sampling);
        Assert.DoesNotContain("FromHandle", sampling);
        Assert.Contains("transcript-frame-ready.txt", probe);
        Assert.Contains("transcript-frame-start.txt", probe);
        Assert.True(probe.IndexOf("transcript-frame-start.txt", StringComparison.Ordinal) < probe.IndexOf("CompositionTarget.Rendering +=", StringComparison.Ordinal));
        Assert.All(script, character => Assert.InRange((int)character, 0, 127));
    }

    [Fact]
    public void HostedDemoAndOrdinarySmokeCannotSucceedWithoutRenderedReports()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, ".github"))) root = root.Parent;
        Assert.NotNull(root);
        var script = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/launch-smoke.ps1"));
        var workflow = File.ReadAllText(Path.Combine(root.FullName, ".github/workflows/ci.yml"));
        var noDesktop = script[script.IndexOf("if ($desktop -eq", StringComparison.Ordinal)..script.IndexOf("$env:VOXCLIP_DATA_DIR", StringComparison.Ordinal)];
        Assert.Contains("throw $observed.reason", noDesktop);
        Assert.DoesNotContain("return", noDesktop);
        Assert.DoesNotContain("if (-not $Hosted)", script);
        Assert.Contains("$count = if ($OrdinaryOpen) { 5 } else { 1 }", script);
        Assert.Contains("Copy-Item -LiteralPath $fixture -Destination $project", script);
        Assert.Contains("$arguments = \"`\"$project`\" --self-check", script);
        Assert.Contains("$check.processId -ne $app.Id", script);
        Assert.Contains("ordinary/observed-self-check.json", workflow);
        Assert.Contains("$observed.status -ne 'ok' -or -not $observed.rootLoaded -or -not $observed.rendered", workflow);
        Assert.Contains("throw \"Editor launch smoke did not pass", workflow);
        // A report claiming ok with fewer than five rendered ordinary opens still fails the step.
        Assert.Contains("$_.status -eq 'ok' -and $_.rootLoaded -and $_.rendered -and $_.transcriptVisible", workflow);
        Assert.Contains("$ordinary.mode -ne 'ordinary-open' -or $passed.Count -lt 5", workflow);
    }

    [Theory]
    [InlineData(ExportAspect.Landscape)]
    [InlineData(ExportAspect.Portrait)]
    [InlineData(ExportAspect.Square)]
    [InlineData(ExportAspect.Source)]
    public async Task InitialAspectWaitsForTheSelectorsLoadedBoundary(ExportAspect aspect)
    {
        var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var selected = -1;
        var ready = false;
        var initial = EditorInitialSelection.ApplyAsync(aspect, loaded.Task, index =>
        {
            Assert.False(ready);
            Assert.True(loaded.Task.IsCompletedSuccessfully);
            selected = index;
        }, CancellationToken.None);
        Assert.Equal(-1, selected);
        Assert.False(initial.IsCompleted);
        loaded.SetResult();
        await initial;
        ready = true;
        Assert.Equal(aspect, EditorLayout.Frames[selected]);
    }

    [Fact]
    public async Task CancelledOpenNeverAppliesItsInitialSelection()
    {
        var loaded = new TaskCompletionSource();
        using var cancellation = new CancellationTokenSource();
        var initial = EditorInitialSelection.ApplyAsync(ExportAspect.Portrait, loaded.Task,
            _ => Assert.Fail("A cancelled page must not select an aspect."), cancellation.Token);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => initial);
        loaded.SetResult();
    }

    [Fact]
    public void NativeProjectOpenFailuresRetainTheExceptionWithoutAReleaseField()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, ".github"))) root = root.Parent;
        Assert.NotNull(root);
        var window = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/src/VoxClip.App/MainWindow.xaml.cs"));
        var probe = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/src/VoxClip.App/Services/ShellNativeProbe.cs"));
        var field = window.IndexOf("internal Exception? DebugOpenError", StringComparison.Ordinal);
        Assert.True(field >= 0);
        Assert.True(window.LastIndexOf("#if DEBUG", field, StringComparison.Ordinal) > window.LastIndexOf("#endif", field, StringComparison.Ordinal));
        Assert.Contains("#if DEBUG\n        DebugOpenError = null;", window);
        Assert.Contains("#if DEBUG\n            DebugOpenError = exception;", window);
        Assert.Contains("window.DebugOpenError is { } openError", probe);
    }

    [Fact]
    public void NativeKeyboardWalkRecognizesTheObservedNamedApplicationBarPeer()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, ".github"))) root = root.Parent;
        Assert.NotNull(root);
        var script = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/native-accessibility-walk.ps1"));
        Assert.Contains("ClassName -eq 'ApplicationBar' -and $p.Current.AutomationId -eq 'Commands'", script);
        Assert.Contains("$e.Current.IsOffscreen", script);
        Assert.Contains("$bounds.IsEmpty", script);
    }

    [Fact]
    public void ScreenshotExerciseChecksTheUnprefixedScopeClockForExactEndTime()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, ".github"))) root = root.Parent;
        Assert.NotNull(root);
        var script = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/capture-windows.ps1"));
        Assert.Contains("'^([0-9:.]+) / \\1$'", script);
        Assert.DoesNotContain("'^Clip ([0-9:.]+)", script);
    }

    [Fact]
    public void CalloutTipMeasuresTheNewSidebarRowBeforeResolvingItsContainer()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, ".github"))) root = root.Parent;
        Assert.NotNull(root);
        var window = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/src/VoxClip.App/MainWindow.xaml.cs"));
        var callout = window[window.IndexOf("private void CalloutShown", StringComparison.Ordinal)..];
        Assert.True(callout.IndexOf("Nav.UpdateLayout();", StringComparison.Ordinal) < callout.IndexOf("Nav.ContainerFromMenuItem(row)", StringComparison.Ordinal));
        Assert.Contains("CalloutTip.IsOpen = true;", callout);
    }

    [Fact]
    public void NativeBuildSpaceUsesTheDocumentedVmFloorAndRunReserve()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, ".github"))) root = root.Parent;
        Assert.NotNull(root);
        var script = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/run-native-flow.ps1"));
        Assert.Contains("if ($FreeBytes -lt (6GB + 1536MB))", script);
        Assert.Contains("1.5 GiB headroom above the 6 GiB floor", script);
        Assert.Contains("keep owned scratch below 2 GiB", script);
        Assert.DoesNotContain("15GB", script);
        Assert.All(script, character => Assert.InRange((int)character, 0, 127));
    }

    [Fact]
    public void ScreenshotTasksKeepArgumentsSeparateAndOwnTheirNames()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, ".github"))) root = root.Parent;
        Assert.NotNull(root);
        var script = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/run-screenshots.ps1"));
        Assert.DoesNotContain("schtasks", script);
        Assert.Contains("New-ScheduledTaskAction -Execute 'powershell.exe' -Argument", script);
        Assert.Contains("-LogonType Interactive", script);
        Assert.Contains("$appTask = 'VoxClipUiWinUi-' + $taskToken", script);
        Assert.Contains("Unregister-ScheduledTask -TaskName $appTask", script);
        Assert.Contains("Unregister-ScheduledTask -TaskName $shotTask", script);
        Assert.All(script, character => Assert.InRange((int)character, 0, 127));
    }

    [Fact]
    public void LaunchSmokeRequiresFreshOwnedRenderedEditorAndVisibleTranscript()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, ".github", "workflows", "ci.yml"))) root = root.Parent;
        Assert.NotNull(root);
        var script = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/launch-smoke.ps1"));
        Assert.Contains("stale reports are not accepted", script);
        Assert.Contains("$check.status -ne 'ready'", script);
        Assert.Contains("-not $check.rootLoaded -or -not $check.rendered", script);
        Assert.Contains("$check.processId -ne $app.Id", script);
        Assert.Contains("IsWindowVisible($windowHandle)", script);
        Assert.Contains("$transcript.Current.IsOffscreen", script);
        Assert.Contains("$observed.status = 'ok'", script);
        Assert.Contains("$observed.status -ne 'ok'", script);
        Assert.Contains("OpenInputDesktop", script);
        Assert.Contains("New-ScheduledTaskAction", script);
        Assert.DoesNotContain("schtasks", script);
        Assert.All(script, character => Assert.InRange((int)character, 0, 127));
    }

    [Fact]
    public void EmptyTransparentAndUniformFramesFail()
    {
        Assert.False(StartupCheck.HasContent([]));
        Assert.False(StartupCheck.HasContent(new byte[400]));
        Assert.False(StartupCheck.HasContent(Enumerable.Repeat((byte)255, 400).ToArray()));
        Assert.False(StartupCheck.HasContent([255, 255, 255]));
    }

    [Fact]
    public void TransparentBorderDoesNotCountAsRenderedContent()
    {
        var pixels = new byte[400];
        Array.Fill(pixels, (byte)255, 40, 360);
        Assert.False(StartupCheck.HasContent(pixels));
    }

    [Fact]
    public void ContrastingContentPasses()
    {
        var pixels = Enumerable.Repeat((byte)255, 400).ToArray();
        for (var offset = 80; offset < 120; offset += 4) { pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0; }
        Assert.True(StartupCheck.HasContent(pixels));
    }

    [Fact]
    public void ProbeReportIncludesOnlyReadinessMetadata()
    {
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-startup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "check.json");
            new StartupCheck("starting", "home", false, false, 0, 0).Save(path);
            new StartupCheck("ready", "editor", true, true, 640, 400) { WindowHandle = 0x100000001, RasterizationScale = 1.5 }.Save(path);
            using var report = JsonDocument.Parse(File.ReadAllText(path));
            Assert.Equal(Environment.ProcessId, report.RootElement.GetProperty("processId").GetInt32());
            Assert.Equal("ready", report.RootElement.GetProperty("status").GetString());
            Assert.True(report.RootElement.GetProperty("rootLoaded").GetBoolean());
            Assert.True(report.RootElement.GetProperty("rendered").GetBoolean());
            Assert.Equal(0x100000001, report.RootElement.GetProperty("windowHandle").GetInt64());
            Assert.Equal(1.5, report.RootElement.GetProperty("rasterizationScale").GetDouble());
            Assert.Single(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }
}
#endif
