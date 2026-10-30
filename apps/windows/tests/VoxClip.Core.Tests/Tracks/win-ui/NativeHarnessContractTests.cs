#if WIN_UI_TESTS
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class NativeHarnessContractTests
{
    [Fact]
    public void TranscriptDecorationGateRemovesGlyphInkAndRejectsMissingPaint()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Services/TranscriptNativeProbe.cs"));
        Assert.Contains("DebugHideGlyphs(retainDecorations: true)", probe);
        Assert.Contains("CheckStrikes(decorationPixels)", probe);
        Assert.Contains("CheckPlaying(decorationPixels)", probe);
        Assert.Contains("DebugRemovePaint(strikeMutation)", probe);
        Assert.Contains("Require(rejected,", probe);
        Assert.Contains("CheckStrikes(restored); CheckPlaying(restored)", probe);
        var transcript = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/TranscriptView.cs"));
        Assert.Contains("if (!retainDecorations) visual.Overlay.DebugClearAbove()", transcript);
    }

    [Fact]
    public void BoundsMatrixContinuesAfterAStateFailureButStillFailsClosed()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var captions = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/CaptionsPanel.cs"));
        Assert.Contains("await Inspect(\"fine-tune\")", captions);
        Assert.Contains("await Inspect(\"captions-off\")", captions);
        Assert.Contains("await Inspect(\"caption-error\")", captions);
        Assert.Contains("throw new AggregateException(\"Caption state bounds failed.\", failures)", captions);
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.NativeProbe.cs"));
        Assert.Contains("await Inspect(() => captions!.DebugFitStatesAsync", probe);
        Assert.Contains("throw new AggregateException(\"Right-column matrix bounds failed.\", failures)", probe);
        Assert.Contains("exception is not OutOfMemoryException", probe);
    }

    [Fact]
    public void FineTuneScrollsWithinItsAllocatedRowAndReservesOneGalleryTile()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var captions = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/CaptionsPanel.cs"));
        Assert.Contains("details.Children.Add(notice); details.Children.Add(fineTune)", captions);
        Assert.Contains("fineTuneViewport.Content = details", captions);
        Assert.Contains("fineTune.Content = controls", captions);
        Assert.Contains("body.RowDefinitions[1].Height = fineTune.IsExpanded || notice.IsOpen ? new(1, GridUnitType.Star) : GridLength.Auto", captions);
        Assert.Contains("content.Visibility = fineTune.IsExpanded ? Visibility.Visible : Visibility.Collapsed", captions);
        Assert.Contains("fineTune.Content = null", captions);
        Assert.Contains("chip.Visibility = chip.Source is null ? Visibility.Collapsed : Visibility.Visible", captions);
        Assert.Contains("args.ItemContainer.Visibility = Visibility.Collapsed", captions);
        Assert.Contains("args.ItemContainer.Visibility = Visibility.Visible", captions);
        Assert.Contains("body.RowDefinitions[2].MinHeight = minimum", captions);
        Assert.DoesNotContain("MaxHeight = 300", captions);
        var editor = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.xaml.cs"));
        Assert.Contains("captions.FitChanged += (_, _) => SizeStage()", editor);
        Assert.Contains("captions?.MinimumContentHeight ?? 160", editor);
    }

    [Fact]
    public void BoundsRealizeEveryGalleryChoiceAndDoNotAcceptParkingCoordinates()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.FitProbe.cs"));
        Assert.Contains("DebugFitAllGalleryIds()", probe);
        Assert.Contains("DebugFitRealizeChoice(id)", probe);
        Assert.Contains("containerBounds.Contains(measurement.Bounds)", probe);
        Assert.Contains("ReferenceEquals(ScrollOwner(clipped.Container), ScrollOwner(owner))", probe);
        Assert.Contains("ClippingAncestor = clippingAncestor", probe);
        Assert.Contains("required.Contains(parked.Id)", probe);
        Assert.Contains("ScrollProofs = scrollProofs", probe);
        Assert.Contains("scroll.Viewport.Contains(after.Bounds)", probe);
        Assert.Contains("required: true", probe);
        Assert.Contains("DebugSettleColumnAsync()", probe);
    }


    [Fact]
    public void NativeFlowUsesItsPrivateArchitectureMatchedHostAndDiskReserve()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var flow = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/run-native-flow.ps1"));
        Assert.Contains("-p:SelfContained=true -p:UseAppHost=true", flow);
        Assert.Contains("& $companion -noLogo", flow);
        Assert.Contains("VOXCLIP_UI_NATIVE_RUNTIME = $RuntimeIdentifier", flow);
        Assert.Contains("6GB + 1536MB", flow);
        Assert.Contains("[Diagnostics.Stopwatch]::StartNew()", flow);
        Assert.Contains("$elapsed.Elapsed.TotalSeconds -lt 900", flow);
        Assert.Contains("native-flow-result.json", flow);
        Assert.Contains("EnvironmentVariables.Remove('VOXCLIP_NATIVE_DIAGNOSTIC')", flow);
        Assert.Contains("$result.PSObject.Properties.Name -contains 'diagnostic'", flow);
        var shell = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Services/ShellNativeProbe.cs"));
        Assert.Contains("status = \"diagnostic\"", shell);
        Assert.Contains("FAILED native gate:", flow);
        Assert.DoesNotContain("$deadline=[DateTime]", flow);
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
