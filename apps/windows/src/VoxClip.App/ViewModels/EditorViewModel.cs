using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

public sealed class EditorViewModel : ObservableObject
{
    private readonly Func<EditState, EditOperation, EditState> reduce;
    private readonly Func<EditState, EditSummary> summarize;
    private readonly Stack<EditState> undo = new();
    private readonly Stack<EditState> redo = new();
    private Project project;
    private EditState? state;
    private string notice = "";
    private bool busy;
    private int selectionAnchor = -1;
    private int selectionEnd = -1;
    private double sourceTime;
    private bool isLeaving;

    public EditorViewModel(Project project, Func<EditState, EditOperation, EditState>? reduce = null,
        Func<EditState, EditSummary>? summarize = null)
    {
        this.project = project;
        this.reduce = reduce ?? EditingEngine.Reduce;
        this.summarize = summarize ?? EditingEngine.Summarize;
        InitializeState();
        Refresh();
    }

    private void InitializeState()
    {
        state = EditingEngine.FromProject(project);
    }

    public Project Project => project;
    public bool IsLeaving => isLeaving;
    internal void BeginLeaving()
    {
        isLeaving = true;
        Notice = "Saving this project before leaving. Editing is paused.";
        OnPropertyChanged(nameof(CanExport));
    }
    internal void ResumeEditing()
    {
        isLeaving = false;
        OnPropertyChanged(nameof(CanExport));
    }
    internal Project ScopedProject(EditState? renderState)
    {
        return renderState is null ? project : project with { Edits = project.Edits with
        {
            Clips = renderState.Clips.ToArray(), ActiveClipId = renderState.ActiveClipId,
            CutWordIds = renderState.CutWordIds.ToArray(), CutPauseIds = renderState.CutPauseIds.ToArray(),
            Corrections = new Dictionary<string, string>(renderState.Corrections),
            PauseThresholdSeconds = renderState.PauseThresholdSeconds, PauseKeepSeconds = renderState.PauseKeepSeconds
        } };
    }
    internal void RequireLegacyRendering(EditState? renderState)
    {
        var scoped = ScopedProject(renderState);
        VoiceLabProject.RequireLegacyRendering(scoped, scoped.Edits.ActiveClipId is { } id ? VoiceLabOutputScope.Clip(id) : VoiceLabOutputScope.Full);
    }
    public EditState? State => state;
    public string Title => project.Title ?? "Untitled take";
    public IReadOnlyList<TimedWord> Words => state?.Transcript.Words ?? [];
    public ObservableCollection<TranscriptParagraph> Paragraphs { get; } = [];
    public ObservableCollection<ClipRow> Clips { get; } = [];
    public EditSummary Summary { get; private set; } = new(0, 0, 0, 0, false, false, false, true);
    /// <summary>Edited length of the whole take, whatever clip is active; the Full take row's duration.</summary>
    public double FullTakeDuration { get; private set; }
    public string Notice { get => notice; set => SetProperty(ref notice, value); }
    public bool Busy { get => busy; set { if (SetProperty(ref busy, value)) OnPropertyChanged(nameof(CanExport)); } }
    public bool HasTranscript => state is not null;
    public bool CanExport => !Busy && !isLeaving && Summary.CanExport;
    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;
    public int SelectionStart => Math.Min(selectionAnchor, selectionEnd);
    public int SelectionEnd => Math.Max(selectionAnchor, selectionEnd);
    public bool HasSelection => SelectionStart >= 0 && SelectionEnd < Words.Count;
    public double SourceTime { get => sourceTime; set { if (SetProperty(ref sourceTime, value)) OnPropertyChanged(nameof(TimeLabel)); } }
    public string TimeLabel => Timecode(SourceTime);
    public string FillerLabel => $"Cut fillers ({Summary.FillerCount})";
    public string Status => !Summary.CanExport ? "Keep at least one word before exporting." : Summary.CutWordCount + Summary.CutPauseCount == 0
        ? "No cuts yet." : $"{Summary.CutWordCount} {Plural(Summary.CutWordCount, "word")} and {Summary.CutPauseCount} {Plural(Summary.CutPauseCount, "pause")} cut.";
    public int SelectedClipCount => Clips.Count(clip => clip.Selected);
    public string ClipExportLabel => SelectedClipCount == 0 ? "Choose clips to export" : $"Export {SelectedClipCount} {Plural(SelectedClipCount, "clip")}";
    public string SelectionText => HasSelection ? string.Join(" ", Words.Skip(SelectionStart).Take(SelectionEnd - SelectionStart + 1).Select(DisplayText)) : "";
    public event EventHandler? Changed;
    public event EventHandler? SaveRequested;
    public event EventHandler? SelectionChanged;
    public event EventHandler<string>? Announcement;

    public void Select(int index, bool extend = false)
    {
        if (Words.Count == 0) return;
        index = Math.Clamp(index, 0, Words.Count - 1);
        if (!extend || selectionAnchor < 0) selectionAnchor = index;
        selectionEnd = index;
        SourceTime = Words[index].Start;
        OnPropertyChanged(nameof(HasSelection));
        OnPropertyChanged(nameof(SelectionText));
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public bool Apply(EditOperation operation)
    {
        if (isLeaving || state is null) return false;
        try
        {
            var next = reduce(state, operation);
            if (next == state) return false;
            undo.Push(state);
            redo.Clear();
            state = next;
            SyncProject();
            Refresh();
            Announcement?.Invoke(this, operation is EditOperation.RestoreCuts ? "Restored all cuts, corrections kept" : Status);
            return true;
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Notice = UiError.Message(exception, "Editing");
            return false;
        }
    }

    public void CutSelection(bool restore = false)
    {
        if (!HasSelection) return;
        var ids = Words.Skip(SelectionStart).Take(SelectionEnd - SelectionStart + 1).Select(word => word.Id).ToList();
        ids.AddRange(state!.Pauses.Where(pause => pause.AfterIndex >= SelectionStart && pause.AfterIndex < SelectionEnd).Select(pause => pause.Id));
        Apply(restore ? new EditOperation.RestoreSelection(ids) : new EditOperation.CutSelection(ids));
    }

    public void Correct(string value)
    {
        if (HasSelection && !string.IsNullOrWhiteSpace(value)) Apply(new EditOperation.Correct(Words[SelectionStart].Id, value.Trim().Normalize()));
    }

    public bool MakeClip()
    {
        if (!HasSelection) { Notice = "Select words to make a clip. No key or account is needed."; return false; }
        return Apply(new EditOperation.AddClip(new(Guid.NewGuid().ToString("N"), Words[SelectionStart].Id, Words[SelectionEnd].Id,
            null, ClipOrigin.Manual, null, null, true)));
    }

    public void Nudge(ClipRow clip, bool start, int delta)
    {
        var first = Index(clip.Clip.StartWordId);
        var last = Index(clip.Clip.EndWordId);
        if (start) first = Math.Clamp(first + delta, 0, last);
        else last = Math.Clamp(last + delta, first, Words.Count - 1);
        Apply(new EditOperation.UpdateClip(clip.Id, first, last));
    }

    public void SelectSentence(int index, bool extend = false)
    {
        if (Words.Count == 0) return;
        index = Math.Clamp(index, 0, Words.Count - 1);
        var first = index;
        while (first > 0 && !DisplayText(Words[first - 1]).EndsWithAny(".!?…")) first--;
        var last = index;
        while (last < Words.Count - 1 && !DisplayText(Words[last]).EndsWithAny(".!?…")) last++;
        Select(first, extend); Select(last, true);
    }
    public void MoveSentence(int delta)
    {
        if (Words.Count == 0) return;
        var index = HasSelection ? SelectionStart : 0;
        if (delta < 0)
        {
            index = Math.Max(0, index - 1);
            while (index > 0 && !DisplayText(Words[index - 1]).EndsWithAny(".!?…")) index--;
        }
        else
        {
            while (index < Words.Count - 1 && !DisplayText(Words[index]).EndsWithAny(".!?…")) index++;
            index = Math.Min(Words.Count - 1, index + 1);
        }
        Select(index);
    }
    public void SetClipEdgeAtCaret(bool start)
    {
        if (!HasSelection || state?.ActiveClipId is not { } active || Clips.FirstOrDefault(clip => clip.Id == active) is not { } row) return;
        var first = start ? SelectionStart : Index(row.Clip.StartWordId);
        var last = start ? Index(row.Clip.EndWordId) : SelectionEnd;
        if (first <= last) Apply(new EditOperation.UpdateClip(row.Id, first, last));
    }
    public void CycleClip(int delta)
    {
        if (Clips.Count == 0) return;
        var active = Clips.ToList().FindIndex(clip => clip.Id == state?.ActiveClipId);
        var next = Math.Clamp(active + delta, 0, Clips.Count - 1);
        Apply(new EditOperation.SetActiveClip(Clips[next].Id)); Select(Index(Clips[next].Clip.StartWordId));
    }
    public void SetShareCaption(string targetId, string text)
    {
        if (isLeaving) return;
        var captions = new Dictionary<string, string>(project.Share.Captions) { [targetId] = text };
        project = project with { Share = new(captions), ModifiedAt = DateTimeOffset.UtcNow };
        SaveRequested?.Invoke(this, EventArgs.Empty);
    }

    public void Undo() => MoveHistory(undo, redo);
    public void Redo() => MoveHistory(redo, undo);
    private void MoveHistory(Stack<EditState> from, Stack<EditState> to)
    {
        if (isLeaving || state is null || !from.TryPop(out var next)) return;
        to.Push(state);
        state = next;
        SyncProject();
        Refresh();
    }

    public void SetCaptionStyle(string id)
    {
        if (isLeaving) return;
        project = project with { Captions = project.Captions with { StyleId = id }, ModifiedAt = DateTimeOffset.UtcNow };
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void SetExport(ProjectExport value)
    {
        if (isLeaving) return;
        project = project with { Export = value, ModifiedAt = DateTimeOffset.UtcNow };
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void SetCaptionOverrides(System.Text.Json.JsonElement value)
    {
        if (isLeaving) return;
        project = project with { Captions = project.Captions with { Overrides = value.Clone() }, ModifiedAt = DateTimeOffset.UtcNow };
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void SetTranscript(Core.Domain.Transcript.Transcript value)
    {
        if (isLeaving) return;
        if (state is not null)
        {
            state = EditingEngine.Reduce(state, new EditOperation.ReplaceTranscript(value));
            project = EditingEngine.ApplyToProject(project, state);
        }
        else project = project with { Transcript = value, Ai = new([]) };
        undo.Clear(); redo.Clear(); selectionAnchor = -1; selectionEnd = -1;
        InitializeState(); Refresh();
    }

    public void AddAiResult(AiResult result)
    {
        if (isLeaving) return;
        var previous = project.Ai;
        project = project with { Ai = new(project.Ai.Results.Append(result).ToArray()) };
        if (!Apply(new EditOperation.AddAiClips(result.Id, result.Clips))) project = project with { Ai = previous };
    }

    public string DisplayText(TimedWord word) => state?.Corrections.GetValueOrDefault(word.Id) ?? word.Text;
    public int Index(string id)
    {
        for (var index = 0; index < Words.Count; index++) if (Words[index].Id == id) return index;
        return -1;
    }
    public string AccessibleWord(int index)
    {
        if (index < 0 || index >= Words.Count) return "Transcript";
        var word = Words[index];
        return DisplayText(word) + (state?.CutWordIds.Contains(word.Id) == true ? ", cut" : "") + (HasSelection && index >= SelectionStart && index <= SelectionEnd ? ", selected" : "");
    }
    /// <summary>Playhead and paragraph times as <c>m:ss.d</c>, or <c>h:mm:ss.d</c> past an hour; design §4.1 (C4).</summary>
    public static string Timecode(double seconds)
    {
        var tenths = (long)Math.Round(Clamp(seconds) * 10, MidpointRounding.AwayFromZero);
        var clock = string.Create(CultureInfo.InvariantCulture, $"{tenths / 10 % 60:00}.{tenths % 10}");
        return tenths >= 36_000
            ? string.Create(CultureInfo.InvariantCulture, $"{tenths / 36_000}:{tenths / 600 % 60:00}:{clock}")
            : string.Create(CultureInfo.InvariantCulture, $"{tenths / 600}:{clock}");
    }
    /// <summary>Edited lengths of clips, takes and projects as <c>m:ss</c>, rounded to the second; design §3.4.</summary>
    public static string Duration(double seconds)
    {
        var total = (long)Math.Round(Clamp(seconds), MidpointRounding.AwayFromZero);
        return string.Create(CultureInfo.InvariantCulture, $"{total / 60}:{total % 60:00}");
    }
    private static double Clamp(double seconds) => double.IsFinite(seconds) ? Math.Clamp(seconds, 0, long.MaxValue / 100) : 0;
    private static string Plural(int count, string value) => count == 1 ? value : value + "s";

    private void SyncProject()
    {
        if (state is null) return;
        project = project with { ModifiedAt = DateTimeOffset.UtcNow, Edits = new(state.PauseThresholdSeconds, state.PauseKeepSeconds,
            state.CutWordIds.ToArray(), state.CutPauseIds.ToArray(), new Dictionary<string, string>(state.Corrections), state.Clips.ToArray(), state.ActiveClipId) };
    }

    private void Refresh()
    {
        Paragraphs.Clear();
        Clips.Clear();
        if (state is not null)
        {
            try { Summary = summarize(state); }
            catch (VoxClipException exception) { Notice = UiError.Message(exception, "Editing"); Summary = new(0, state.CutWordIds.Count, state.Pauses.Count, state.CutPauseIds.Count, false, false, false, true); }
            var start = 0;
            for (var index = 1; index <= Words.Count; index++)
            {
                var split = index == Words.Count || (Words[index].Speaker != Words[index - 1].Speaker ||
                    Words[index].Start - Words[index - 1].End >= 1.5 && Words[index - 1].Text.EndsWithAny(".!?")) || index - start >= 100;
                if (!split) continue;
                Paragraphs.Add(new(start, index - start, Timecode(Words[start].Start), Words[start].Speaker));
                start = index;
            }
            var source = project.Media.Source;
            var sampleRate = source.Audio?.SampleRate is > 0 ? source.Audio.SampleRate : 48000;
            double EditedLength(EditState scoped) => EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(scoped, source.DurationSeconds),
                source.DurationSeconds, sampleRate, scoped.PauseKeepSeconds).Duration;
            try { FullTakeDuration = EditedLength(state with { ActiveClipId = null }); }
            catch (VoxClipException) { FullTakeDuration = 0; }
            foreach (var clip in state.Clips.OrderBy(clip => Index(clip.StartWordId)))
            {
                var first = Index(clip.StartWordId);
                var last = Index(clip.EndWordId);
                if (first < 0 || last < first) continue;
                var suggestion = project.Ai.Results.FirstOrDefault(result => result.Id == clip.AiResultId)?.Clips.ElementAtOrDefault(clip.AiClipIndex ?? -1);
                var duration = EditedLength(state with { ActiveClipId = clip.Id });
                Clips.Add(new(clip, clip.Title ?? suggestion?.Title ?? $"Clip {Clips.Count + 1}",
                    Timecode(duration) + (suggestion is null ? " · Manual" : $" · {suggestion.Score}/10"),
                    string.Join(" ", Words.Skip(first).Take(last - first + 1).Select(DisplayText)), suggestion?.Reason ?? "", duration));
            }
        }
        foreach (var name in new[] { nameof(Project), nameof(State), nameof(Summary), nameof(Status), nameof(FillerLabel), nameof(CanExport), nameof(CanUndo), nameof(CanRedo), nameof(SelectedClipCount), nameof(ClipExportLabel), nameof(HasTranscript), nameof(FullTakeDuration) }) OnPropertyChanged(name);
        Changed?.Invoke(this, EventArgs.Empty);
    }
}

public sealed record TranscriptParagraph(int StartIndex, int Count, string Timecode, string? Speaker);
public sealed record ClipRow(ClipRange Clip, string Title, string Detail, string Excerpt, string Reason, double DurationSeconds)
{
    public string Id => Clip.Id;
    public bool Selected => Clip.Selected;
}

internal static class StringExtensions
{
    internal static bool EndsWithAny(this string text, string endings) => text.Length > 0 && endings.Contains(text[^1], StringComparison.Ordinal);
}
