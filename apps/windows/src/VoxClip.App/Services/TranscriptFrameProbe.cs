using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Services;

internal static class TranscriptFrameProbe
{
    internal static async Task RunAsync(MainWindow window, string output)
    {
        Directory.CreateDirectory(output);
        var reportPath = Path.Combine(output, "transcript-frame-time.json");
        if (File.Exists(reportPath)) throw new InvalidOperationException("Use a fresh frame-time evidence directory.");
        var host = (Panel)window.Content;
        var transcript = new TranscriptView { Width = 780, Height = 600, HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top, Background = Ui.ThemeBrush(host, "VcBgSurfaceBrush") };
        var prepared = new List<double>();
        transcript.FrameProbePrepared = prepared.Add;
        var intervals = new List<double>(1024);
        var compositionIntervals = new List<double>(1024);
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var maximumParagraphs = 0;
        var offsetsChanged = 0;
        var previousOffset = -1.0;
        var started = Stopwatch.GetTimestamp();
        long previous = 0;
        TimeSpan? previousComposition = null;
        void Rendering(object? sender, object args)
        {
            try
            {
                var now = Stopwatch.GetTimestamp();
                var seconds = Stopwatch.GetElapsedTime(started, now).TotalSeconds;
                var composition = ((RenderingEventArgs)args).RenderingTime;
                if (seconds >= 1)
                {
                    if (previous != 0) intervals.Add(Stopwatch.GetElapsedTime(previous, now).TotalMilliseconds);
                    if (previousComposition is { } last && composition > last) compositionIntervals.Add((composition - last).TotalMilliseconds);
                    previous = now;
                    previousComposition = composition;
                    var scroll = transcript.FrameProbeScrollHost;
                    if (scroll.VerticalOffset != previousOffset) offsetsChanged++;
                    previousOffset = scroll.VerticalOffset;
                    maximumParagraphs = Math.Max(maximumParagraphs, transcript.FrameProbeRealizedParagraphs);
                    if (seconds >= 9) { completed.TrySetResult(); return; }
                    scroll.ChangeView(null, scroll.ScrollableHeight * Math.Clamp((seconds - 1) / 8, 0, 1), null, true);
                }
            }
            catch (Exception exception) { completed.TrySetException(exception); }
        }
        try
        {
            var shared = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR") ?? throw new InvalidOperationException("Set VOXCLIP_SHARED_DIR for the frame probe.");
            var project = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(Path.Combine(shared, "fixtures", "projects", "interview-take.voxclip")));
            var words = Enumerable.Range(0, 9000).Select(index => project.Transcript!.Words[0] with
                { Id = "frame-" + index, Text = "word", Start = index * 0.4, End = index * 0.4 + 0.3 }).ToArray();
            var model = new EditorViewModel(project with
            {
                Transcript = project.Transcript! with { Words = words, DurationSeconds = 3600 },
                Media = new(project.Media.Source with { DurationSeconds = 3600 }),
                Edits = project.Edits with { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() }
            });
            host.Children.Add(transcript);
            transcript.Attach(model);
            host.UpdateLayout();
            started = Stopwatch.GetTimestamp();
            CompositionTarget.Rendering += Rendering;
            try { await completed.Task.WaitAsync(TimeSpan.FromSeconds(45)); }
            finally { CompositionTarget.Rendering -= Rendering; }
            var summary = FrameTimeSummary.From(intervals);
            var release = true;
#if DEBUG
            release = false;
#endif
            var valid = release && intervals.Count >= 120 && offsetsChanged >= 100 && maximumParagraphs < model.Paragraphs.Count;
            var passes = valid && summary.P95Milliseconds <= 20;
            await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(new
            {
                Status = passes ? "ok" : "failed", Release = release, Architecture = RuntimeInformation.ProcessArchitecture.ToString(),
                Words = words.Length, Paragraphs = model.Paragraphs.Count, MaximumRealizedParagraphs = maximumParagraphs,
                ChangedOffsets = offsetsChanged, SampleSeconds = 8, WarmupSeconds = 1, EstimatedDropBudgetHz = 60,
                Summary = summary, FrameIntervalsMilliseconds = intervals, CompositionIntervalsMilliseconds = compositionIntervals,
                ParagraphPreparationMilliseconds = prepared,
                Failure = !valid ? "Requires Release, at least 120 rendered intervals, 100 changed offsets and bounded realization."
                    : !passes ? "p95 exceeds 20 ms; inspect frame intervals and paragraph realization profile before acceptance." : null
            }, new JsonSerializerOptions { WriteIndented = true }));
            if (!passes) throw new InvalidOperationException("Release transcript frame-time gate failed; see " + reportPath);
        }
        catch (Exception exception)
        {
            await File.WriteAllTextAsync(Path.Combine(output, "transcript-frame-error.txt"), exception.ToString());
            throw;
        }
        finally
        {
            transcript.FrameProbePrepared = null;
            transcript.Detach();
            host.Children.Remove(transcript);
        }
    }
}
