#if WIN_UI_TESTS
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class NativeHarnessContractTests
{
    [Fact]
    public void NativeFlowUsesItsPrivateArchitectureMatchedHostAndDiskReserve()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var flow = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/run-native-flow.ps1"));
        Assert.Contains("-p:SelfContained=true -p:UseAppHost=true", flow);
        Assert.Contains("& $companion -noLogo", flow);
        Assert.Contains("VOXCLIP_UI_NATIVE_RUNTIME = $RuntimeIdentifier", flow);
        Assert.Contains("6GB + 1536MB", flow);
    }

    [Fact]
    public void SmokeRetriesForegroundAcquisitionWithoutRelaxingOwnership()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var smoke = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/launch-smoke.ps1"));
        Assert.Contains("[SmokeDesktop]::UnlockForeground()", smoke);
        Assert.Contains("if ([SmokeDesktop]::GetForegroundWindow() -ne $windowHandle) { throw", smoke);
        Assert.Contains("if ($foregroundProcess -ne $app.Id) { throw", smoke);
    }

    [Fact]
    public void TimelinePreservesTokenOpacityAndExactHatchPixelAssertionsInHighContrast()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var timeline = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/TimelineView.cs"));
        Assert.Contains("IsHitTestVisible = false, HighContrastAdjustment = ElementHighContrastAdjustment.None", timeline);
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Services/TimelineNativeProbe.cs"));
        Assert.Contains("HighContrastAdjustment = ElementHighContrastAdjustment.None", probe);
        Assert.Contains("Difference(pixels, 15, 6) <= 2 && Difference(pixels, 15, 9) > 10", probe);
        Assert.Contains("Difference(pixels, 47, 9) <= 2 && Difference(pixels, 47, 6) > 10", probe);
    }

    [Fact]
    public void SidebarProbeWaitsForTheNamedHeaderControl()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Services/ShellNativeProbe.cs"));
        Assert.Contains("window.Content.UpdateLayout()", probe);
        Assert.Contains("return control is { ActualWidth: > 0, Visibility: Visibility.Visible }", probe);
        Assert.Contains("control!.IsEnabled && peer.IsEnabled() && peer.IsControlElement()", probe);
    }

    [Fact]
    public void RecentWalkUsesTheStoredProjectTitle()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var walk = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/native-accessibility-walk.ps1"));
        Assert.Contains("(ReadCheck $NormalProject).title", walk);
        Assert.Contains("Current.Name -eq $projectName", walk);
    }

    [Fact]
    public void ScreenshotExerciseChecksTheSpecifiedSwitchAndGroupedGallery()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var capture = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/capture-windows.ps1"));
        Assert.DoesNotContain("Off, just the video", capture);
        Assert.Contains("Find-Control $window 'Show captions'", capture);
        Assert.Contains("SelectionItemPattern", capture);
        Assert.Contains("ToggleState]::Off", capture);
        Assert.Contains("Show captions did not restore the selected style", capture);
    }

    [Fact]
    public void DecorativeChecksAreRawAndScrollbarsMeasureTheirOwnedViewport()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var captions = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/CaptionsPanel.cs"));
        Assert.Contains("Text='&#xE73E;'", captions);
        Assert.Contains("AutomationProperties.AccessibilityView='Raw'", captions);
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.FitProbe.cs"));
        Assert.Contains("GetAccessibilityView(owner) != AccessibilityView.Raw", probe);
        Assert.Contains("peer.IsControlElement() || peer.IsContentElement()", probe);
        Assert.Contains("owner is ScrollBar && ScrollOwner(owner) is { } scrollOwner", probe);
        Assert.Contains("owner = scrollOwner", probe);
    }

    [Fact]
    public void ClipExportHasAStableAccessibleTarget()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/ExportDialog.cs"));
        Assert.Contains("SetAutomationId(currentClip, \"Export.ThisClip\")", source);
        Assert.Contains("SetName(currentClip, $\"This clip, Clip", source);
        var launcher = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/launch-windows.ps1"));
        var runner = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/run-screenshots.ps1"));
        Assert.Contains("if ($OrdinaryEditor)", launcher);
        Assert.Contains("& $exe $ordinaryProject --self-check", launcher);
        Assert.Contains("$Exercise -and $capture -eq 'editor'", runner);
        Assert.Contains("' -OrdinaryEditor'", runner);
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.NativeProbe.cs"));
        Assert.Contains("var originalPaneOpen = window.DebugNavigationPaneOpen", probe);
        Assert.Contains("window.DebugNavigationPaneOpen = originalPaneOpen", probe);
    }

    [Fact]
    public void ActualListenerUsesMtaAndTheOwnedPlayheadAndRequiresDelivery()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/listen-timeline.ps1"));
        Assert.Contains("-Mta", source);
        Assert.Contains("NativeProbe.Playhead", source);
        Assert.Contains("$playhead.Current.ProcessId -ne $appId", source);
        Assert.Contains("[System.Windows.Automation.TreeScope]::Element", source);
        Assert.Contains("[TimelinePropertyListener]::Events -eq 0", source);
        Assert.Contains("timeline-listener-stopped.txt", source);
        Assert.Contains("[Environment]::Exit(0)", source);
        var capture = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/capture-windows.ps1"));
        Assert.Contains("$accessibleName = [string]$element.Current.Name", capture);
        Assert.Contains("$accessibleName.StartsWith($Name)", capture);
    }
}
#endif
