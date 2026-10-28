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
