#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class AccessibilityMonitorTests
{
    [Fact]
    public void TimelineNarratorNamesItemAndUsesWordOrdinalsAtBothEdges()
    {
        TimedWord[] words = [Word(0, "the"), Word(1, "next"), Word(2, "word")];
        var item = new TimelineItem(new(TimelineItemType.Effect, "title"), "title", TimelineLane.T1, 0, null, .5,
            [new(.5, 1.4)], [new(.5, 1.4)], false, null, [], null);
        Assert.Equal("Title, The trick, 0:00.5 to 0:01.4, selected", TimelineItemEditing.Label(item, new("The trick"), .5, 1.4, true));
        Assert.Equal(1, TimelineItemEditing.WordStepValue(words, .5, TimelineEdge.Start));
        Assert.Equal(2, TimelineItemEditing.WordStepValue(words, 1.4, TimelineEdge.End));
        Assert.Equal("Split: B. Duplicate: Ctrl+D. Delete: Delete. Trim to playhead: Ctrl+Shift+[ or ].", TimelineItemEditing.Help);
        static TimedWord Word(int index, string text) => new($"word-{index}", text, WordKind.Word, index * .5, index * .5 + .4, null, null, null, null, TimingSource.Native);
    }

    [Fact]
    public void TimelineItemsAndEdgesExposeNativeSelectionAndRangePatterns()
    {
        var app = Path.Combine(Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!, "apps/windows/src/VoxClip.App/Controls");
        Assert.Contains("RangePeer(owner), ISelectionItemProvider", File.ReadAllText(Path.Combine(app, "TimelineItemControl.cs")));
        Assert.Contains("IRangeValueProvider", File.ReadAllText(Path.Combine(app, "TimelineRangeControl.cs")));
        var bar = File.ReadAllText(Path.Combine(app, "TimelineView.ItemBar.cs"));
        Assert.Contains("(start, TimelineEdge.Start), (end, TimelineEdge.End)", bar);
        Assert.Contains("TimelineItemEditing.Help", bar);
        Assert.Contains("new(0, Math.Max(0, model.Words.Count - 1), index, 1", bar);
    }
    [Fact]
    public void WindowNotificationsDispatchAndDisposeWithoutStaticSubscriptions()
    {
        var queued = new Queue<Action>();
        var current = AccessibilitySnapshot.Default;
        var published = new List<AccessibilitySnapshot>();
        Action? notification = null;
        var removed = 0;
        using var monitor = new AccessibilityMonitor(queued.Enqueue, () => current, published.Add, exception => throw exception);
        monitor.Start(changed => { notification = changed; return () => removed++; });
        Assert.Single(published);
        current = new(new(false, false, true), "High Contrast Black");
        notification!();
        Assert.Single(published);
        queued.Dequeue()();
        Assert.Equal(current, published[^1]);
        notification();
        monitor.Dispose();
        queued.Dequeue()();
        Assert.Equal(2, published.Count);
        Assert.Equal(1, removed);
        monitor.Dispose();
        Assert.Equal(1, removed);
    }

    [Fact]
    public void SubscriptionAndReadFailuresKeepTheLastSnapshotAndOtherSubscriptions()
    {
        var current = AccessibilitySnapshot.Default;
        var saved = current;
        var failures = new List<Exception>();
        var readFails = false;
        var removed = 0;
        Action? notification = null;
        using var monitor = new AccessibilityMonitor(action => action(),
            () => readFails ? throw new InvalidOperationException() : current, value => saved = value, failures.Add);
        monitor.Start(_ => throw new InvalidOperationException(), changed => { notification = changed; return () => removed++; });
        Assert.Single(failures);
        readFails = true;
        notification!();
        Assert.Equal(current, saved);
        Assert.Equal(2, failures.Count);
        readFails = false;
        current = new(new(true, true, true), "High Contrast White");
        notification();
        Assert.Equal(current, saved);
        monitor.Dispose();
        Assert.Equal(1, removed);
    }

    [Fact]
    public void ThemeSettingsAndEffectsAreOwnedByTheMainWindow()
    {
        var app = Path.Combine(Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!, "apps/windows/src/VoxClip.App");
        var ui = File.ReadAllText(Path.Combine(app, "Controls/Ui.cs"));
        Assert.DoesNotContain("static Ui()", ui);
        Assert.DoesNotContain("AccessibilitySettings", ui);
        Assert.Contains("theme = ThemeSettings.CreateForWindowId(window)", File.ReadAllText(Path.Combine(app, "Services/WindowEffects.cs")));
        var window = File.ReadAllText(Path.Combine(app, "MainWindow.xaml.cs"));
        Assert.Contains("effects = new WindowEffects(AppWindow.Id, DispatcherQueue)", window);
        Assert.Contains("effects.Dispose()", window);
    }
}
#endif
