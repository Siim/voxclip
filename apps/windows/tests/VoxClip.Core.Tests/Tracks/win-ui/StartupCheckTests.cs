#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.Services;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class StartupCheckTests
{
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
    public void NativeBuildSpaceUsesTheDocumentedVmFloor()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, ".github"))) root = root.Parent;
        Assert.NotNull(root);
        var script = File.ReadAllText(Path.Combine(root.FullName, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/run-native-flow.ps1"));
        Assert.Contains("if ($FreeBytes -lt 6GB)", script);
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
