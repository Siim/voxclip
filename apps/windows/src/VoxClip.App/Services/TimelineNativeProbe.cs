#if DEBUG
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Services;

internal static class TimelineNativeProbe
{
    internal static async Task RunAsync(MainWindow window, Project project, List<string> checks)
    {
        var host = (Panel)window.Content;
        var pattern = new Canvas { Width = 128, Height = 96, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Background = Ui.ThemeBrush(host, "VcTimelineTrackBrush"), RequestedTheme = ElementTheme.Dark, HighContrastAdjustment = ElementHighContrastAdjustment.None };
        var timeline = new TimelineView { Width = 700, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom };
        var model = new EditorViewModel(project with { Edits = project.Edits with { Clips = [], ActiveClipId = null } });
        model.Select(2); model.Select(5, true); var id = model.MakeClip();
        Require(id is not null, "native trim fixture did not make a clip");
        timeline.Attach(model);
        host.Children.Add(pattern); host.Children.Add(timeline);
        try
        {
            var stroke = (SolidColorBrush)Ui.ThemeBrush(pattern, "VcCutStrokeBrush");
            foreach (var pause in new[] { false, true })
            {
                var cut = TimelineView.CutPattern(128, pause, stroke);
                Canvas.SetTop(cut, pause ? 32 : 0); pattern.Children.Add(cut);
            }
            var dimBrush = (SolidColorBrush)Ui.ThemeBrush(pattern, "VcTimelineScopeDimBrush");
            var dim = new Border { Width = 128, Height = 30, Background = dimBrush };
            Canvas.SetTop(dim, 64); pattern.Children.Add(dim);
            host.UpdateLayout();
            var nodes = timeline.DebugDrawingNodes.ToArray();
            Require(timeline.DebugDrawingElementCount <= TimelineRetainedPool<object>.ElementBound, "timeline custom drawing exceeds its fixed element bound");
            var generation = timeline.DebugBuildVersion;
            timeline.DebugMoveViewport(new(0, 4)); timeline.DebugMoveViewport(new(0.1, 3.9));
            Require(generation == timeline.DebugBuildVersion && nodes.SequenceEqual(timeline.DebugDrawingNodes), "zoom/drag viewport update recreated drawing elements");
            checks.Add("retained timeline viewport updates preserve drawing elements and scene generation");
            var bitmap = new RenderTargetBitmap();
            Phase("pattern raster");
            await bitmap.RenderAsync(pattern, 128, 96).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
            var pixels = (await bitmap.GetPixelsAsync()).ToArray();
            if (Environment.GetEnvironmentVariable("VOXCLIP_UI_EVIDENCE_DIR") is { Length: > 0 } patternEvidence)
                await File.WriteAllTextAsync(Path.Combine(patternEvidence, "timeline-hatch-pixels.json"), System.Text.Json.JsonSerializer.Serialize(new
                {
                    bitmap.PixelWidth, bitmap.PixelHeight, PixelsBgra = pixels,
                    WordSix = Difference(pixels, 15, 6), WordNine = Difference(pixels, 15, 9),
                    PauseNine = Difference(pixels, 47, 9), PauseSix = Difference(pixels, 47, 6)
                }));
            Require(bitmap.PixelWidth == 128 && bitmap.PixelHeight == 96, "timeline raster dimensions changed");
            Require(Difference(pixels, 15, 6) <= 2 && Difference(pixels, 15, 9) > 10, "word hatch is not periodic every six pixels");
            Require(Difference(pixels, 47, 9) <= 2 && Difference(pixels, 47, 6) > 10, "pause hatch is not periodic every nine pixels");
            var background = ((SolidColorBrush)pattern.Background).Color;
            var foreground = dimBrush.Color;
            var alpha = foreground.A / 255.0;
            var actual = (80 * 128 + 50) * 4;
            var baseChannels = new[] { background.B, background.G, background.R };
            var dimChannels = new[] { foreground.B, foreground.G, foreground.R };
            for (var channel = 0; channel < 3; channel++)
                Require(Math.Abs(pixels[actual + channel] - (dimChannels[channel] * alpha + baseChannels[channel] * (1 - alpha))) <= 2,
                    "scope dim raster does not use the token alpha");
            checks.Add("native timeline pixels: 6/9-pixel hatch periods and token scope-dim alpha");

            var handle = timeline.DebugEndHandle;
            var peer = FrameworkElementAutomationPeer.CreatePeerForElement(handle);
            Require(AutomationProperties.GetName(handle) == "Clip 1 end", "trim handle name changed");
            var range = (IRangeValueProvider)peer.GetPattern(PatternInterface.RangeValue);
            Require(range.SmallChange == 1, "trim SmallChange is not one word");
            var before = model.Clips.Single().Clip;
            range.SetValue(range.Value + range.SmallChange);
            Require(model.Clips.Single().Clip.EndWordId == model.Words[6].Id, "RangeValue increment did not update clip end by one word");
            model.Undo();
            Require(model.Clips.Single().Clip == before, "one Undo did not restore the trim");
            checks.Add("native trim RangeValue increment advances one word and undoes in one step");
        }
        finally { timeline.Detach(); host.Children.Remove(timeline); host.Children.Remove(pattern); }
        var words = Enumerable.Range(0, 9000).Select(index => project.Transcript!.Words[0] with
            { Id = "long-" + index, Text = "word", Start = index * 0.4, End = index * 0.4 + 0.3 }).ToArray();
        var longModel = new EditorViewModel(project with
        {
            Transcript = project.Transcript! with { Words = words, DurationSeconds = 3600 },
            Media = new(project.Media.Source with { DurationSeconds = 3600 }),
            Edits = project.Edits with { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() }
        });
        var longTimeline = new TimelineView { Width = 700, HorizontalAlignment = HorizontalAlignment.Left };
        Phase("long timeline");
        longModel.Select(3000); longModel.Select(3050, true); longModel.MakeClip();
        host.Children.Add(longTimeline); longTimeline.Attach(longModel); host.UpdateLayout();
        try
        {
            var nodes = longTimeline.DebugDrawingNodes.ToArray();
            foreach (var rms in new[] { false, true })
            {
                longTimeline.SetWaveform(rms ? Enumerable.Repeat(0.2f, 72000).ToArray() : []);
                Require(longTimeline.DebugDrawingElementCount <= TimelineRetainedPool<object>.ElementBound, "9,000-word timeline exceeds its element bound");
                var version = longTimeline.DebugBuildVersion;
                longTimeline.DebugMoveViewport(new(0, 1800)); longTimeline.DebugMoveViewport(new(900, 1200));
                Require(version == longTimeline.DebugBuildVersion && nodes.SequenceEqual(longTimeline.DebugDrawingNodes), "9,000-word zoom/drag update recreated elements");
            }
            checks.Add("9,000-word native timeline: <=256 custom elements with/without RMS and stable zoom/drag identities");
            longTimeline.DebugCreateRangePeers();
            if (Environment.GetEnvironmentVariable("VOXCLIP_TIMELINE_LISTENER_PROBE") == "1")
            {
                var evidence = Environment.GetEnvironmentVariable("VOXCLIP_UI_EVIDENCE_DIR") ?? throw new InvalidOperationException("Missing listener probe evidence directory.");
                await File.WriteAllTextAsync(Path.Combine(evidence, "timeline-listener-ready.txt"), Environment.ProcessId.ToString());
                var deadline = DateTime.UtcNow.AddSeconds(30);
                while (!AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged) && DateTime.UtcNow < deadline) await Task.Delay(50);
                Require(AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged), "No actual property-changed listener attached within 30 seconds");
            }
            var listener = AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged);
            for (var index = 0; index < 256; index++)
                longTimeline.DebugFrame(new(index % 900, 1800 + index % 900), index % 700, 1200 + index * 0.02, index % 2 == 0);
            var allocated = GC.GetAllocatedBytesForCurrentThread();
            var started = System.Diagnostics.Stopwatch.GetTimestamp();
            for (var index = 0; index < 4096; index++)
                longTimeline.DebugFrame(new(index % 900, 1800 + index % 900), index % 700, 1200 + index * 0.02, index % 2 == 0);
            var bytes = GC.GetAllocatedBytesForCurrentThread() - allocated;
            var milliseconds = System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds;
            checks.Add($"9,000-word full-control native timeline: {bytes / 4096.0:0.00} managed bytes/frame, {milliseconds / 4096:0.000} ms/frame over 4,096 changing viewport/playhead/trim ticks; property listener={listener}");
            for (var index = 0; index < 256; index++) longTimeline.Position(1200 + index * 0.02);
            allocated = GC.GetAllocatedBytesForCurrentThread();
            started = System.Diagnostics.Stopwatch.GetTimestamp();
            for (var index = 0; index < 4096; index++) longTimeline.Position(1200 + index * 0.02);
            var playheadBytes = GC.GetAllocatedBytesForCurrentThread() - allocated;
            var playheadMilliseconds = System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds;
            Require(listener == AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged), "UIA listener state changed during allocation sampling");
            checks.Add($"9,000-word actual TimelineView.Position: {playheadBytes / 4096.0:0.00} managed bytes/frame, {playheadMilliseconds / 4096:0.000} ms/frame; property listener={listener}");
            if (Environment.GetEnvironmentVariable("VOXCLIP_UI_EVIDENCE_DIR") is { Length: > 0 } allocationEvidence)
                await File.WriteAllTextAsync(Path.Combine(allocationEvidence, "timeline-allocations.json"), System.Text.Json.JsonSerializer.Serialize(new
                {
                    Runtime = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), PropertyListener = listener,
                    Frames = 4096, FullControlBytesPerFrame = bytes / 4096.0, PlayheadBytesPerFrame = playheadBytes / 4096.0,
                    FullControlMillisecondsPerFrame = milliseconds / 4096, PlayheadMillisecondsPerFrame = playheadMilliseconds / 4096
                }, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
            if (listener && Environment.GetEnvironmentVariable("VOXCLIP_UI_EVIDENCE_DIR") is { Length: > 0 } listenerEvidence)
            {
                var delivered = Path.Combine(listenerEvidence, "timeline-listener-events.txt");
                var stopped = Path.Combine(listenerEvidence, "timeline-listener-stopped.txt");
                var deadline = DateTime.UtcNow.AddSeconds(15);
                while (!File.Exists(stopped) && DateTime.UtcNow < deadline) await Task.Delay(50);
                Require(File.Exists(stopped) && File.Exists(delivered) && int.TryParse(await File.ReadAllTextAsync(delivered), out var events) && events > 0,
                    "The attached listener did not acknowledge delivered events and unsubscribe before the timeline was removed");
            }
            if (!listener) Require(playheadBytes == 0, "Playhead-only native control path allocated without a property listener");
        }
        finally { longTimeline.Detach(); host.Children.Remove(longTimeline); }
        var longTranscript = new TranscriptView { Width = 780, Height = 400, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        Phase("long transcript attach");
        host.Children.Add(longTranscript); longTranscript.Attach(longModel); host.UpdateLayout();
        try
        {
            var timings = new List<double>();
            var maximumParagraphs = 0;
            for (var index = 0; index < 24; index++)
            {
                var clock = System.Diagnostics.Stopwatch.StartNew();
                longTranscript.DebugScroll((index * 17 % 24) / 23.0);
                if (index % 8 == 0) longTranscript.Zoom(index % 16 == 0 ? 1 : -1);
                clock.Stop();
                if (index >= 4) timings.Add(clock.Elapsed.TotalMilliseconds);
                maximumParagraphs = Math.Max(maximumParagraphs, longTranscript.DebugRealizedParagraphs);
                await Task.Delay(16);
            }
            timings.Sort();
            Require(maximumParagraphs < longModel.Paragraphs.Count, "hour-long transcript realized every paragraph");
            checks.Add($"9,000-word/hour-long native scroll and zoom UI-thread ChangeView/UpdateLayout: p50 {timings[timings.Count / 2]:0.00} ms, p95 {timings[(int)(timings.Count * 0.95)]:0.00} ms; at most {maximumParagraphs}/{longModel.Paragraphs.Count} paragraphs realized, 24 input ticks 16 ms apart (Debug diagnostic, not compositor frame time)");
        }
        finally { longTranscript.Detach(); host.Children.Remove(longTranscript); }
    }
    private static void Phase(string text)
    {
        if (Environment.GetEnvironmentVariable("VOXCLIP_UI_EVIDENCE_DIR") is { Length: > 0 } output)
            File.AppendAllText(Path.Combine(output, "timeline-phases.txt"), text + Environment.NewLine);
    }
    private static double Difference(byte[] pixels, int row, int period)
    {
        double difference = 0;
        for (var column = 20; column < 90; column++)
            for (var channel = 0; channel < 3; channel++) difference += Math.Abs(pixels[(row * 128 + column) * 4 + channel] - pixels[(row * 128 + column + period) * 4 + channel]);
        return difference / (70 * 3);
    }
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
#endif
