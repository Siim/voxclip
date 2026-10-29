#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Captions;
using System.Xml.Linq;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class RoundFourTests(ITestOutputHelper output)
{
    [Fact]
    public void NativeAllocationGateMeasuresPositionAndGuardsAllPropertyEvents()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var control = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/TimelineRangeControl.cs"));
        Assert.Contains("AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged) && FrameworkElementAutomationPeer.FromElement(this)", control);
        Assert.DoesNotContain("AutomationProperties.SetHelpText", control);
        Assert.Contains("GetHelpTextCore() => owner.Read().Text", control);
        var timeline = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/TimelineView.cs"));
        var position = timeline[timeline.IndexOf("public void Position", StringComparison.Ordinal)..timeline.IndexOf("private TimelineRange ReadPlayhead", StringComparison.Ordinal)];
        Assert.Contains("ComputePlayhead", position);
        Assert.DoesNotContain("UpdateViewport", position);
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Services/TimelineNativeProbe.cs"));
        Assert.Contains("longTimeline.Position(1200 + index * 0.02)", probe);
        Assert.Contains("playheadBytes == 0", probe);
        Assert.Contains("No actual property-changed listener attached", probe);
    }

    [Fact]
    public void NativeCaptureScriptsCoverCurrentRoutesAndKeepVisualGatesExplicit()
    {
        var shared = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR");
        Assert.False(string.IsNullOrEmpty(shared));
        var track = Path.Combine(Path.GetDirectoryName(shared)!, "apps", "windows", "tests", "VoxClip.Core.Tests", "Tracks", "win-ui");
        foreach (var script in new[] { "capture-windows", "run-screenshots", "launch-windows", "native-accessibility-walk", "run-native-flow" })
        {
            var bytes = File.ReadAllBytes(Path.Combine(track, script + ".ps1"));
            Assert.All(bytes, value => Assert.InRange(value, (byte)0, (byte)127));
            var text = System.Text.Encoding.ASCII.GetString(bytes);
            Assert.Contains("win-x64", text); Assert.Contains("win-arm64", text);
            Assert.DoesNotContain("Selected clips (1)", text); Assert.DoesNotContain("Export kept clips", text);
        }
        var captures = File.ReadAllText(Path.Combine(track, "run-screenshots.ps1"));
        foreach (var state in new[] { "home", "home-empty", "home-dragover", "editor-light", "editor-dark", "editor-1280-light", "editor-compact-light", "finding", "suggested", "exported", "export-edited", "exporting", "export-failed", "transcribing", "focus", "opaque-flyout", "splitter", "high-contrast-black", "high-contrast-white" }) Assert.Contains("'" + state + "'", captures);
        Assert.Contains("mockupToleranceEpx=4", captures);
        Assert.Contains("'home' { '1280x800' }", captures);
        Assert.Contains("'editor-compact-light' { '1024x700' }", captures);
        Assert.Contains("default { '1440x900' }", captures);
        var walk = File.ReadAllText(Path.Combine(track, "native-accessibility-walk.ps1"));
        Assert.Contains("f6-visual-evidence.json", walk);
        Assert.Contains("pending pixel review", walk); Assert.Contains("narrator='not observed'", walk);
    }
    [Theory]
    [InlineData(false, false, false, true)]
    [InlineData(false, false, true, true)]
    [InlineData(false, true, false, false)]
    [InlineData(false, true, true, true)]
    [InlineData(true, false, false, true)]
    [InlineData(true, false, true, true)]
    [InlineData(true, true, false, false)]
    [InlineData(true, true, true, true)]
    public void MotionTransparencyAndContrastHaveIndependentPaths(bool animations, bool effects, bool contrast, bool opaque)
    {
        var policy = new AccessibilityEffects(animations, effects, contrast);
        Assert.Equal(animations, policy.Animations);
        Assert.Equal(opaque, policy.OpaqueTransientSurfaces);
    }

    [Fact]
    public void TranscriptionAnnouncesEveryTenPercentWithoutRepeatingTicks()
    {
        var announcements = new TranscriptionAnnouncements();
        Assert.Equal("Reading video…", announcements.Update(MediaTranscriptionStage.ReadingVideo, null, false));
        Assert.Null(announcements.Update(MediaTranscriptionStage.ReadingVideo, null, false));
        Assert.Equal("Extracting audio…", announcements.Update(MediaTranscriptionStage.ExtractingAudio, null, false));
        var messages = new List<string>();
        for (var percent = 0; percent <= 100; percent++)
            if (announcements.Update(MediaTranscriptionStage.Transcribing, percent / 100.0, false) is { } message) messages.Add(message);
        Assert.Equal(Enumerable.Range(0, 11).Select(bucket => $"Transcribing on this PC · {bucket * 10}%"), messages);
        Assert.Null(announcements.Update(MediaTranscriptionStage.Transcribing, double.NaN, false));
        Assert.Null(announcements.Update(MediaTranscriptionStage.Transcribing, 0.4, false));
        Assert.Equal("Aligning words…", announcements.Update(MediaTranscriptionStage.Aligning, null, false));
        Assert.Equal("Transcribing with ElevenLabs · 42%", announcements.Update(MediaTranscriptionStage.Transcribing, 0.42, true));
    }

    [Fact]
    public void HighContrastUsesSystemStrikesBadgesAndSelectionAndNamesEveryIcon()
    {
        var shared = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR");
        Assert.False(string.IsNullOrEmpty(shared));
        var app = Path.Combine(Path.GetDirectoryName(shared)!, "apps", "windows", "src", "VoxClip.App");
        XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        var tokens = XDocument.Load(Path.Combine(app, "Themes", "Tokens.xaml"));
        var contrast = tokens.Descendants().Single(element => (string?)element.Attribute(xaml + "Key") == "HighContrast");
        foreach (var (key, color) in new[] { ("VcCutStrokeBrush", "SystemColorGrayTextColor"), ("VcWordCutBrush", "SystemColorGrayTextColor"), ("VcSelectionTranscriptBrush", "SystemColorHighlightColor"),
            ("VcWordPlayingBackgroundBrush", "SystemColorWindowTextColor"), ("VcWordPlayingForegroundBrush", "SystemColorWindowColor"), ("VcClipBadgeBackgroundBrush", "SystemColorWindowColor"), ("VcTextSecondaryBrush", "SystemColorWindowTextColor") })
            Assert.Equal("{ThemeResource " + color + "}", contrast.Elements().Single(element => (string?)element.Attribute(xaml + "Key") == key).Attribute("Color")!.Value);
        foreach (var file in new[] { "MainWindow.xaml", "Pages/EditorPage.xaml" })
        foreach (var element in XDocument.Load(Path.Combine(app, file)).Descendants().Where(element => element.Name.LocalName is "Button" or "ToggleButton" or "AppBarButton" or "AppBarToggleButton"))
        {
            var textual = element.Attribute("Content")?.Value ?? element.Attribute("Label")?.Value;
            if (string.IsNullOrEmpty(textual)) Assert.False(string.IsNullOrWhiteSpace(element.Attribute("AutomationProperties.Name")?.Value), element.ToString());
        }
        Assert.Contains("\"VcCutStrokeBrush\"", File.ReadAllText(Path.Combine(app, "Controls", "TranscriptOverlay.cs")));
    }

    [Fact]
    public void ExportFailuresUseTheExactReassuranceAndPreserveSpecialCases()
    {
        Assert.Equal("Export stopped: file is locked. Your edits are saved.", UiError.ExportMessage(new IOException("file is locked."), "output.mp4"));
        Assert.Equal("Export stopped: unexpected failure. Your edits are saved.", UiError.ExportMessage(new InvalidOperationException("unexpected failure"), "output.mp4"));
        var mapped = new VoxClipException(VoxClipErrorCode.ExportFailed, "Export stopped: test. Your edits are saved.");
        Assert.Equal(mapped.Message, UiError.ExportMessage(mapped, "output.mp4"));
        foreach (var code in new[] { VoxClipErrorCode.EncoderUnavailable, VoxClipErrorCode.MediaMissing, VoxClipErrorCode.DiskFull, VoxClipErrorCode.EverythingCut })
        {
            var special = new VoxClipException(code, "specific message");
            Assert.Equal(UiError.Message(special, "Export"), UiError.ExportMessage(special, "output.mp4"));
        }
        Assert.Equal($"There isn't enough free space on {Path.GetPathRoot(Path.GetFullPath("output.mp4"))}. Free up space and try again.", UiError.ExportMessage(new IOException("full", unchecked((int)0x80070070)), "output.mp4"));
        Assert.Equal("", UiError.ExportMessage(new OperationCanceledException(), "output.mp4"));
        Assert.Equal("⚠ Export failed", new ExportRowState(ClipExportState.Failed).Label);
    }

    [Fact]
    public void ZoomTicksAndTrimMovesHaveAFixedSmallAllocationBound()
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        model.Select(0); model.Select(5, true); model.MakeClip();
        var viewport = new TimelineViewportState();
        viewport.Reset(model);
        var plan = TimelineLayout.Plan(model);
        viewport.Prepare(plan);
        var scene = new TimelineScene();
        var rendered = new TimelineWindow(0, 7);
        scene.Build(model, plan, rendered, [], 960, false);
        var frame = new TimelineFrame();
        var name = viewport.EndName;
        double checksum = 0;
        void Tick(int index)
        {
            var window = new TimelineWindow(index % 64 * 0.01, 7 - index % 32 * 0.01);
            frame.Compute(viewport, scene, plan, rendered, window, 960, index % 420 * 0.016, index % 2 == 0,
                true, index % 3 == 0, viewport.ActiveClip!.Id, index % 2, 3 + index % 3, true, index % 960);
            checksum += frame.Playhead.Value + frame.PlayheadLeft + frame.HeadLeft + frame.Scale + frame.Translation;
            checksum += frame.Start.Value + frame.End.Value + frame.StartLeft + frame.EndLeft + frame.PointerWord;
            checksum += frame.BracketScale + frame.BracketTranslation + frame.LeftDim + frame.RightDim;
            for (var badge = 0; badge < frame.BadgeCount; badge++) checksum += frame.Badges[badge].Left;
        }
        for (var index = 0; index < 512; index++) Tick(index);
        var before = GC.GetAllocatedBytesForCurrentThread();
        for (var index = 0; index < 4096; index++) Tick(index);
        var allocated = GC.GetAllocatedBytesForCurrentThread() - before;
        output.WriteLine($"4096 production TimelineFrame.Compute zoom/playhead/trim/pointer ticks: {allocated} allocated bytes; bound 1024 bytes.");
        Assert.InRange(allocated, 0, 1024);
        Assert.True(checksum > 0);
        Assert.Same(name, viewport.EndName);
        var prior = viewport.Playhead(plan, new(0, 10), 1.2, false).Text;
        Assert.NotEqual(prior, viewport.Playhead(plan, new(0, 10), 2.2, false).Text);
        Assert.Same(viewport.Trim(false, 0, 5).Text, viewport.Trim(false, 1, 5).Text);
    }

    [Fact]
    public void AspectChangeSynchronouslyCancelsDragAndRejectsItsRelease()
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        var original = model.Project.Captions;
        var starting = model.Project.Export.Aspect;
        var next = starting == ExportAspect.Portrait ? ExportAspect.Square : ExportAspect.Portrait;
        var cancelled = false;
        model.CaptionDrag.Cancelled += (_, _) => { cancelled = true; Assert.Equal(starting, model.Project.Export.Aspect); };
        model.CaptionDrag.Begin(starting);
        model.SetExport(model.Project.Export with { Aspect = next });
        Assert.True(cancelled);
        Assert.False(model.CaptionDrag.IsActive);
        model.CompleteCaptionDrag(new(0.2, 0.3));
        Assert.Same(original, model.Project.Captions);
        model.SetExport(model.Project.Export with { Aspect = starting });
        model.CompleteCaptionDrag(new(0.2, 0.3));
        Assert.Same(original, model.Project.Captions);
        model.CaptionDrag.Begin(next);
        model.CompleteCaptionDrag(new(0.2, 0.3));
        Assert.Same(original, model.Project.Captions);
        model.CaptionDrag.Begin(starting);
        model.CompleteCaptionDrag(new(0.2, 0.3));
        Assert.Equal(new CaptionPosition(0.2, 0.3), CaptionFineTune.StoredPosition(model.Project));
        model.Undo();
        Assert.Same(original, model.Project.Captions);
    }

    internal static Project OverlappingProject(bool cut = false, bool filler = false)
    {
        var project = RoundThreeTests.Fixture();
        var word = project.Transcript!.Words[0];
        return project with
        {
            Transcript = project.Transcript with { Words = [word with { Id = "long", Text = filler ? "um" : "word", Start = 0, End = 10 }, word with { Id = "short", Text = "word", Start = 1, End = 2 }], DurationSeconds = 12 },
            Media = new(project.Media.Source with { DurationSeconds = 12 }),
            Edits = project.Edits with { Clips = [], ActiveClipId = null, CutWordIds = cut ? ["long"] : [], CutPauseIds = [], Corrections = new Dictionary<string, string>() }
        };
    }

    [Theory]
    [InlineData(false, false, 5, 6, 0)]
    [InlineData(false, true, 5, 6, 2)]
    [InlineData(true, false, 5, 6, 3)]
    [InlineData(false, false, 9, 11, 0)]
    [InlineData(false, true, 9, 11, 2)]
    [InlineData(true, false, 9, 11, 3)]
    public void TimelineRetainsOverlappingKeptCutAndFillerEdges(bool cut, bool filler, double start, double end, int layer)
    {
        var model = new EditorViewModel(OverlappingProject(cut, filler));
        var scene = new TimelineScene();
        scene.Build(model, TimelineLayout.Plan(model), new(start, end), [], 100, false);
        var mark = Assert.Single(scene.Layers[layer]);
        Assert.Equal(0, mark.X);
        Assert.Equal(end <= 10 ? 100 : 50, mark.Width);
        scene.Build(model, TimelineLayout.Plan(model), new(10, 11), [], 100, false);
        Assert.Empty(scene.Layers[layer]);
    }

    [Fact]
    public void ClipFingerprintIncludesTheActualScopedPlanFromOverlappingWords()
    {
        var model = new EditorViewModel(OverlappingProject());
        model.Select(0);
        var target = new ExportTarget.Clip(model.MakeClip()!);
        var before = model.Project;
        var words = before.Transcript!.Words.ToArray();
        words[1] = words[1] with { Start = 3, End = 4 };
        var after = before with { Transcript = before.Transcript with { Words = words } };
        EditPlan Plan(Project project)
        {
            var state = ExportSelection.Scope(EditingEngine.FromProject(project), target)!;
            return EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, 12), 12, 48000, state.PauseKeepSeconds);
        }
        Assert.NotEqual(Plan(before).Cuts, Plan(after).Cuts);
        Assert.NotEqual(ExportFingerprint.For(before, target), ExportFingerprint.For(after, target));
    }
}
#endif
