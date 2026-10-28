#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class AccessibilityMonitorTests
{
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
