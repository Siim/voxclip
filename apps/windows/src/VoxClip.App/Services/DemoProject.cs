#if DEBUG || WIN_UI_TESTS
using System.Diagnostics;
using System.Runtime.CompilerServices;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;

namespace VoxClip.App.Services;

internal static class DemoProject
{
    internal static EditState Reduce(EditState state, EditOperation operation)
    {
        var words = state.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var pauses = state.CutPauseIds.ToHashSet(StringComparer.Ordinal);
        var corrections = new Dictionary<string, string>(state.Corrections);
        var clips = state.Clips.ToList();
        switch (operation)
        {
            case EditOperation.Toggle toggle:
                var toggled = state.Pauses.Any(pause => pause.Id == toggle.Id) ? pauses : words;
                if (!toggled.Remove(toggle.Id)) toggled.Add(toggle.Id);
                break;
            case EditOperation.SetWordCuts selected:
                if (selected.Cut) words.UnionWith(selected.Ids); else words.ExceptWith(selected.Ids);
                break;
            case EditOperation.SetPauseCuts selected:
                if (selected.Cut) pauses.UnionWith(selected.Ids); else pauses.ExceptWith(selected.Ids);
                break;
            case EditOperation.SetPauseKeep keep: return state with { PauseKeepSeconds = keep.Seconds };
            case EditOperation.CutSelection selection:
                var restore = selection.Ids.All(id => words.Contains(id) || pauses.Contains(id));
                foreach (var id in selection.Ids)
                {
                    var target = state.Pauses.Any(pause => pause.Id == id) ? pauses : words;
                    if (restore) target.Remove(id); else target.Add(id);
                }
                break;
            case EditOperation.RestoreSelection selection:
                words.ExceptWith(selection.Ids); pauses.ExceptWith(selection.Ids); break;
            case EditOperation.CutFillers:
                words.UnionWith(state.Transcript.Words.Where(word => IsFiller(corrections.GetValueOrDefault(word.Id) ?? word.Text)).Select(word => word.Id)); break;
            case EditOperation.TightenPauses: pauses.UnionWith(state.Pauses.Select(pause => pause.Id)); break;
            case EditOperation.RestoreCuts: words.Clear(); pauses.Clear(); break;
            case EditOperation.Correct correct: corrections[correct.Id] = correct.Text; break;
            case EditOperation.AddClip add: clips.Add(add.Clip); break;
            case EditOperation.RemoveClip remove: clips.RemoveAll(clip => clip.Id == remove.Id); break;
            case EditOperation.SetClipSelected selected:
                clips = clips.Select(clip => clip.Id == selected.Id ? clip with { Selected = selected.Selected } : clip).ToList(); break;
            case EditOperation.RenameClip rename:
                clips = clips.Select(clip => clip.Id == rename.Id ? clip with { Title = rename.Title } : clip).ToList(); break;
            case EditOperation.UpdateClip update:
                clips = clips.Select(clip => clip.Id == update.Id ? clip with { StartWordId = state.Transcript.Words[update.StartIndex].Id, EndWordId = state.Transcript.Words[update.EndIndex].Id } : clip).ToList(); break;
            case EditOperation.SetActiveClip active: return state with { ActiveClipId = active.Id };
            default: return state;
        }
        return state with { CutWordIds = words, CutPauseIds = pauses, Corrections = corrections, Clips = clips };
    }

    internal static EditSummary Summarize(EditState state)
    {
        var fillers = state.Transcript.Words.Count(word => !state.CutWordIds.Contains(word.Id) && IsFiller(state.Corrections.GetValueOrDefault(word.Id) ?? word.Text));
        return new(fillers, state.CutWordIds.Count, state.Pauses.Count, state.CutPauseIds.Count, fillers > 0,
            state.Pauses.Any(pause => !state.CutPauseIds.Contains(pause.Id)), state.CutWordIds.Count + state.CutPauseIds.Count > 0,
            state.Transcript.Words.Any(word => !state.CutWordIds.Contains(word.Id)));
    }
    private static bool IsFiller(string text) => System.Text.RegularExpressions.Regex.IsMatch(text, @"^(um+|uh+|erm+|hmm+)[,.!?]?$|^…$", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);
}

internal sealed class DemoPreviewEngine : IPreviewEngine
{
    private readonly object sync = new();
    private readonly Stopwatch clock = new();
    private readonly PixelBuffer still = CreateStill();
    private double origin;
    private double duration;
    private long generation;
    private EditPlan? plan;
    public PreviewPosition Position
    {
        get
        {
            lock (sync)
            {
            var time = Math.Min(duration, origin + clock.Elapsed.TotalSeconds);
            if (time >= duration) clock.Stop();
            var sourcePoint = plan is null ? time : plan.SourceTime(Math.Min(time, Math.Max(0, duration - 1 / plan.SampleRate)));
            return new(time, sourcePoint, clock.IsRunning);
            }
        }
    }
    public Task LoadAsync(ComposeSnapshot snapshot, IProgress<MediaProgress>? progress, CancellationToken ct) { ct.ThrowIfCancellationRequested(); lock (sync) { plan = snapshot.Plan; duration = plan.Duration; origin = 0; clock.Reset(); } return Task.CompletedTask; }
    public Task PlayAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); lock (sync) { if (Position.EditedTime >= duration) origin = 0; clock.Restart(); } return Task.CompletedTask; }
    public Task PauseAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); lock (sync) { origin = Position.EditedTime; clock.Reset(); } return Task.CompletedTask; }
    public Task SeekAsync(double editedTime, bool exact, CancellationToken ct) { ct.ThrowIfCancellationRequested(); lock (sync) { origin = Math.Clamp(editedTime, 0, duration); if (clock.IsRunning) clock.Restart(); Interlocked.Increment(ref generation); } return Task.CompletedTask; }
    public Task UpdateSnapshotAsync(ComposeSnapshot snapshot, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        lock (sync)
        {
            var source = Position.SourceTime;
            var playing = clock.IsRunning;
            plan = snapshot.Plan;
            duration = plan.Duration;
            origin = plan.MapTime(source);
            if (playing && origin < duration) clock.Restart(); else clock.Reset();
            Interlocked.Increment(ref generation);
        }
        return Task.CompletedTask;
    }
    public Task UpdateCaptionsAsync(CaptionTrack? captions, CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.CompletedTask; }
    public async IAsyncEnumerable<PreviewFrame> ReadFramesAsync([EnumeratorCancellation] CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(33));
        do { var position = Position; yield return new(still, position.EditedTime, position.SourceTime, Interlocked.Read(ref generation)); }
        while (await timer.WaitForNextTickAsync(ct));
    }
    public ValueTask DisposeAsync() { lock (sync) clock.Stop(); return ValueTask.CompletedTask; }
    private static PixelBuffer CreateStill()
    {
        const int width = 640;
        const int height = 360;
        var pixels = new byte[width * height * 4];
        for (var vertical = 0; vertical < height; vertical++)
        for (var horizontal = 0; horizontal < width; horizontal++)
        {
            var color = (Red: (byte)46, Green: (byte)49, Blue: (byte)52);
            if (horizontal is > 44 and < 170 && vertical is > 28 and < 278) color = (63, 67, 68);
            if (horizontal is > 500 and < 580 && vertical is > 50 and < 300) color = (58, 66, 62);
            if (Math.Pow((horizontal - 330) / 158.0, 2) + Math.Pow((vertical - 405) / 180.0, 2) < 1) color = (91, 98, 107);
            if (horizontal is > 302 and < 358 && vertical is > 182 and < 248) color = (171, 144, 127);
            if (Math.Pow((horizontal - 330) / 64.0, 2) + Math.Pow((vertical - 141) / 83.0, 2) < 1) color = (190, 165, 146);
            if (Math.Pow((horizontal - 330) / 67.0, 2) + Math.Pow((vertical - 94) / 44.0, 2) < 1) color = (56, 53, 51);
            if (vertical is > 138 and < 142 && (horizontal is > 299 and < 314 || horizontal is > 344 and < 359)) color = (64, 59, 55);
            if (vertical is > 183 and < 186 && horizontal is > 317 and < 346) color = (119, 86, 77);
            var offset = (vertical * width + horizontal) * 4;
            pixels[offset] = color.Blue; pixels[offset + 1] = color.Green; pixels[offset + 2] = color.Red; pixels[offset + 3] = 255;
        }
        return new(pixels, width, height, width * 4);
    }
}
#endif
