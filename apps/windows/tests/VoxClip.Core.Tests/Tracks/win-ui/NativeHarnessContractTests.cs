#if WIN_UI_TESTS
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class NativeHarnessContractTests
{
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
