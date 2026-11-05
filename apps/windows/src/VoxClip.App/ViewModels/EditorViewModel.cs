using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;

namespace VoxClip.App.ViewModels;

public sealed partial class EditorViewModel : ObservableObject
{
    private readonly Func<EditState, EditOperation, EditState> reduce;
    private readonly Func<EditState, EditSummary> summarize;
    private readonly Func<DateTimeOffset> now;
    private sealed record History(EditState? State, Project Project, bool IsDirty, string? ActionName = null);
    private readonly Stack<History> undo = new();
    private readonly Stack<History> redo = new();
    private Project project;
    private Project savedProject;
    private string savedJson;
    private readonly object voiceLabEdits = new();
    private bool applyingVoiceLab;
    private EditState? state;
    private string notice = "";
    private bool busy;
    private int selectionAnchor = -1;
    private int selectionEnd = -1;
    private double sourceTime;
    private bool isLeaving;
    private IReadOnlyList<ExportRecord> exportRecords = [];
    private VoxClip.Core.Domain.VoiceLab.VoiceLabLabelPosition voiceLabLabelPosition = VoiceLabSettingsState.LabelPosition(null);
    internal bool SetVoiceLabLabelPosition(VoxClip.Core.Domain.VoiceLab.VoiceLabLabelPosition position)
    {
        if (voiceLabLabelPosition == position) return false;
        voiceLabLabelPosition = position;
        RefreshExportRows();
        return true;
    }
    private readonly Dictionary<string, ExportRowState> exportActivity = new(StringComparer.Ordinal);
    internal event EventHandler? ExportStatesChanged;
    internal void SetExportRecords(IReadOnlyList<ExportRecord> records)
    {
        exportRecords = records;
        RefreshExportRows();
    }
    internal void SetExportActivity(ExportTarget target, ClipExportState state, double? progress = null)
    {
        var key = ExportFingerprint.TargetId(target);
        if (state == ClipExportState.None) exportActivity.Remove(key); else exportActivity[key] = new(state, progress);
        RefreshExportRows();
    }
    internal ExportRowState ExportStatus(string? clipId)
    {
        var key = clipId ?? "full";
        if (exportActivity.TryGetValue(key, out var live)) return live;
        var record = exportRecords.FirstOrDefault(record => record.ProjectId == project.Id && record.TargetId == key);
        if (record is null) return new(ClipExportState.None);
        ExportTarget target = clipId is null ? new ExportTarget.FullEdit() : new ExportTarget.Clip(clipId);
        return new(record.PlanFingerprint == ExportFingerprint.For(project, target, voiceLabLabelPosition) ? ClipExportState.Exported : ClipExportState.ChangedSinceExport);
    }
    private void RefreshExportRows()
    {
        for (var index = 0; index < Clips.Count; index++)
        {
            var status = ExportStatus(Clips[index].Id);
            Clips[index] = Clips[index] with { ExportState = status.State, ExportProgress = status.Progress };
        }
        ExportStatesChanged?.Invoke(this, EventArgs.Empty);
    }
    public bool IsReadOnly { get; private set; }
    public bool IsRelinking { get; private set; }

    public void SetMediaUnavailable(bool unavailable)
    {
        IsReadOnly = unavailable;
        OnPropertyChanged(nameof(IsReadOnly));
        OnPropertyChanged(nameof(CanExport));
    }

    public async Task<bool> RelinkAsync(IProjectStore store, string projectPath, Func<Task<string?>> choose,
        Func<string, Task<MediaInfo>> probe, Func<Task<bool>> confirm, CancellationToken ct)
    {
        if (Busy || isLeaving || IsRelinking) return false;
        IsRelinking = true;
        Busy = true;
        try
        {
            while (await choose() is { } selected)
            {
                var media = await probe(selected);
                var result = await store.RelinkAsync(project, selected, media, false, ct);
                if (result.Decision == RelinkDecision.NeedsConfirmation)
                {
                    if (!await confirm()) continue;
                    result = await store.RelinkAsync(project, selected, media, true, ct);
                }
                if (result.Project is not { } relinked)
                {
                    Notice = "This video's duration doesn't match. Your media and edits are unchanged.";
                    continue;
                }
                await store.SaveAsync(relinked, projectPath, ct);
                project = relinked;
                MarkSaved(relinked);
                SetMediaUnavailable(false);
                Notice = "";
                Refresh();
                return true;
            }
            return false;
        }
        finally { Busy = false; IsRelinking = false; }
    }

    public EditorViewModel(Project project, Func<EditState, EditOperation, EditState>? reduce = null,
        Func<EditState, EditSummary>? summarize = null, Func<DateTimeOffset>? now = null)
    {
        this.project = project;
        savedProject = project;
        savedJson = DirtyIdentity(project);
        this.reduce = reduce ?? EditingEngine.Reduce;
        this.summarize = summarize ?? EditingEngine.Summarize;
        this.now = now ?? (() => DateTimeOffset.UtcNow);
        LlmRuns.Changed += (_, _) => { OnPropertyChanged(nameof(Busy)); OnPropertyChanged(nameof(CanFindClips)); OnPropertyChanged(nameof(CanExport)); };
        InitializeState();
        Refresh();
    }

    private void InitializeState()
    {
        state = EditingEngine.FromProject(project);
    }

    public Project Project => project;
    private static string DirtyIdentity(Project snapshot) => System.Text.Json.JsonSerializer.Serialize(
        snapshot with { Edits = snapshot.Edits with { ActiveClipId = null } }, ProjectJsonContext.Default.Project);
    public bool IsDirty => !ReferenceEquals(project, savedProject) && DirtyIdentity(project) != savedJson;
    internal void MarkSaved(Project snapshot)
    {
        savedProject = snapshot;
        savedJson = DirtyIdentity(snapshot);
        OnPropertyChanged(nameof(IsDirty));
    }
    private History CaptureHistory(string? actionName = null) => new(state, project, IsDirty, actionName);
    internal IReadOnlySet<string> VoiceLabAssetReferences(IEnumerable<Project>? otherDocuments = null)
        => new[] { project, savedProject }.Concat(undo.Select(entry => entry.Project)).Concat(redo.Select(entry => entry.Project))
            .Concat(otherDocuments ?? []).SelectMany(VoiceLabAssetRetention.References).ToHashSet(StringComparer.Ordinal);
    internal CaptionDragSession CaptionDrag { get; } = new();
    internal ProjectLlmRuns LlmRuns { get; } = new();
    public bool IsLeaving => isLeaving;
    internal void BeginLeaving()
    {
        CaptionDrag.Cancel();
        // Leaving takes the focus from an open correction: save its typed text before the project is saved (design §4.2).
        EndCorrection();
        isLeaving = true;
        OnPropertyChanged(nameof(CanFindClips));
        Notice = "Saving this project before leaving. Editing is paused.";
        OnPropertyChanged(nameof(CanExport));
    }
    internal void ResumeEditing()
    {
        isLeaving = false;
        OnPropertyChanged(nameof(CanFindClips));
        OnPropertyChanged(nameof(CanExport));
    }
    internal Project ScopedProject(EditState? renderState)
        => ExportRenderInput.ScopedProject(project, renderState);
    internal void RequireLegacyRendering(EditState? renderState)
    {
        var scoped = ScopedProject(renderState);
        VoiceLabProject.RequireLegacyRendering(scoped, scoped.Edits.ActiveClipId is { } id ? VoiceLabOutputScope.Clip(id) : VoiceLabOutputScope.Full);
    }
    public EditState? State => state;
    public string Title => project.Title ?? "Untitled take";
    public IReadOnlyList<TimedWord> Words => state?.Transcript.Words ?? [];
    public int RewriteStart { get; private set; } = -1;
    public int RewriteEnd { get; private set; } = -1;
    public void SetRewriteRange(int first, int last)
    {
        RewriteStart = first;
        RewriteEnd = last;
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }
    private Project? speechProject;
    private EditState? speechState;
    private IReadOnlyList<TranscriptSpeechWord> speechWords = [];
    internal TranscriptSpeechWord PresentedWord(int index)
    {
        if (!ReferenceEquals(speechProject, project) || !ReferenceEquals(speechState, state))
        {
            speechWords = TranscriptWordDecoration.Speech(project, Words, state?.Corrections);
            speechProject = project;
            speechState = state;
        }
        return index >= 0 && index < speechWords.Count ? speechWords[index] : new("", false, false, false, index);
    }
    internal bool ContainsAiSpeech(string? clipId = null) => VoiceLabDisclosure.Contains(() => ScopedProject(State), clipId, IsReadOnly, voiceLabLabelPosition);
    public ObservableCollection<TranscriptParagraph> Paragraphs { get; } = [];
    public ObservableCollection<ClipRow> Clips { get; } = [];
    public EditSummary Summary { get; private set; } = new(0, 0, 0, 0, false, false, false, true);
    /// <summary>Edited length of the whole take, whatever clip is active; the Full take row's duration.</summary>
    public double FullTakeDuration { get; private set; }
    public string Notice { get => notice; set => SetProperty(ref notice, value); }
    public bool Busy { get => busy || LlmRuns.IsBusy; set { if (SetProperty(ref busy, value)) { OnPropertyChanged(nameof(CanFindClips)); OnPropertyChanged(nameof(CanExport)); } } }
    public bool CanFindClips => HasTranscript && !Busy && !IsLeaving;
    public bool HasTranscript => state is not null;
    public bool CanExport => !Busy && !isLeaving && !IsReadOnly && Summary.CanExport;
    /// <summary>Why Export can't run for <paramref name="clipId"/>'s scope (null is Full take), or null when it can. The Export
    /// button, Ctrl+E and a clip row's Export clip… share it (delta §3.5).</summary>
    public string? ExportBlocked(bool demo, bool videoUnavailable, string? clipId) =>
        EditorLayout.ExportBlocked(demo, videoUnavailable || IsReadOnly, Busy || isLeaving, ScopeKeepsWords(clipId), Clips.FirstOrDefault(clip => clip.Id == clipId)?.IsSuggested == true);
    /// <summary>Whether <paramref name="clipId"/>'s scope keeps a word. A clip row's Export clip… names a clip that need not
    /// be active, so a scope other than the active one is summarised on its own. With no transcript there are no clips, and
    /// the Full take exports as it is (design §7.1, §13 "No audio track").</summary>
    private bool ScopeKeepsWords(string? clipId)
    {
        if (state is null) return clipId is null && Summary.CanExport;
        if (clipId == state.ActiveClipId) return Summary.CanExport;
        try { return summarize(state with { ActiveClipId = clipId }).CanExport; }
        catch (VoxClipException) { return false; }
    }
    public string? UndoActionName => undo.TryPeek(out var entry) ? entry.ActionName : null;
    public string? RedoActionName => redo.TryPeek(out var entry) ? entry.ActionName : null;
    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;
    public int SelectionStart => Math.Min(selectionAnchor, selectionEnd);
    public int SelectionEnd => Math.Max(selectionAnchor, selectionEnd);
    /// <summary>The selection's moving end: the word the last arrow key or drag reached, which Shift+arrows extend from.</summary>
    public int SelectionCaret => selectionEnd;
    public bool HasSelection => SelectionStart >= 0 && SelectionEnd < Words.Count;
    public double SourceTime { get => sourceTime; set { if (SetProperty(ref sourceTime, value)) OnPropertyChanged(nameof(TimeLabel)); } }
    public string TimeLabel => Timecode(SourceTime);
    public string FillerLabel => $"Cut fillers ({Summary.FillerCount})";
    /// <summary>The command row's second line for the selected row (delta §3.5): "2:26 after cuts · 11 cuts",
    /// "Clip 2 · 0:20 after cuts · 2 cuts" or "Clip 3 · 0:19 · No cuts yet".</summary>
    public string SummaryLine { get; private set; } = "";
    /// <summary>"{source} source · {w} words cut in {r} places · {p} pauses cut", for the same scope.</summary>
    public string SummaryTooltip { get; private set; } = "";
    /// <summary>Manual clips and kept AI clips, numbered 1…n; Export's "Selected clips" exports these (ADR-R29).</summary>
    public IReadOnlyList<ClipRow> KeptClips => Clips.Where(clip => !clip.IsSuggested).ToArray();
    /// <summary>AI clips not kept yet, numbered after the kept ones.</summary>
    public IReadOnlyList<ClipRow> SuggestedClips => Clips.Where(clip => clip.IsSuggested).ToArray();
    public string SelectionText => HasSelection ? string.Join(" ", Words.Skip(SelectionStart).Take(SelectionEnd - SelectionStart + 1).Select(DisplayText)) : "";
    public event EventHandler? Changed;
    public event EventHandler? SaveRequested;
    public event EventHandler? SelectionChanged;
    internal long RewriteSelectionRevision { get; private set; }
    internal void RewriteCaretChanged() => RewriteSelectionRevision++;
    public event EventHandler<string>? Announcement;

    public void Select(int index, bool extend = false)
    {
        if (Words.Count == 0) return;
        var previousSelection = (SelectionStart, SelectionEnd);
        index = Math.Clamp(index, 0, Words.Count - 1);
        if (!extend || selectionAnchor < 0) selectionAnchor = index;
        selectionEnd = index;
        RewriteSelectionRevision++;
        SourceTime = Words[index].Start;
        // Changing the selection ends an open inline correction, as a click elsewhere ends an inline rename (design §4.2).
        if (CorrectionWordId is not null && previousSelection != (SelectionStart, SelectionEnd)) EndCorrection();
        OnPropertyChanged(nameof(HasSelection));
        OnPropertyChanged(nameof(SelectionText));
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    internal void ClearSelection()
    {
        if (!HasSelection) return;
        selectionAnchor = -1;
        selectionEnd = -1;
        RewriteSelectionRevision++;
        if (CorrectionWordId is not null) EndCorrection();
        OnPropertyChanged(nameof(HasSelection));
        OnPropertyChanged(nameof(SelectionText));
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }
    /// <summary>← / → move the caret one word; with Shift they extend the selection from its moving end (design §11.2). With
    /// nothing selected, the first arrow selects the first word.</summary>
    public void Step(int delta, bool extend = false) => Select(HasSelection ? selectionEnd + delta : 0, extend);

    public bool Apply(EditOperation operation)
    {
        if (operation is EditOperation.SetActiveClip scope) return !IsReadOnly && SetScope(scope.Id);
        if (!ApplyBatch([operation])) return false;
        Announcement?.Invoke(this, operation is EditOperation.RestoreCuts ? "Restored all cuts, corrections kept" : SummaryLine);
        return true;
    }

    internal bool IsScopeChange { get; private set; }
    public bool SetScope(string? clipId)
    {
        if (isLeaving || state is null || state.ActiveClipId == clipId || clipId is not null && !state.Clips.Any(clip => clip.Id == clipId)) return false;
        CaptionDrag.Cancel();
        state = state with { ActiveClipId = clipId };
        project = project with { Edits = project.Edits with { ActiveClipId = clipId } };
        IsScopeChange = true;
        try { Refresh(); }
        finally { IsScopeChange = false; }
        return true;
    }

    /// <summary>Reduce the operations one after another from the current state as one undo step, then sync and refresh once.</summary>
    public bool ApplyBatch(IEnumerable<EditOperation> operations)
    {
        if (isLeaving || IsReadOnly || state is null) return false;
        try
        {
            var next = state;
            foreach (var operation in operations) next = reduce(next, operation);
            if (next == state) return false;
            CaptionDrag.Cancel();
            undo.Push(CaptureHistory());
            redo.Clear();
            state = next;
            SyncProject();
            Refresh();
            return true;
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Notice = UiError.Message(exception, "Editing");
            return false;
        }
    }

    internal Project ProjectWithLocalOperations(Project snapshot, IReadOnlyList<EditOperation> operations)
    {
        var local = EditingEngine.FromProject(snapshot) ?? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
        foreach (var operation in operations) local = reduce(local, operation);
        return EditingEngine.ApplyToProject(snapshot, local);
    }
    public bool ApplyVoiceLab(IReadOnlyList<VoiceLabSegment> segments, IReadOnlyList<VoiceLabAsset> assets, VoiceLabVoiceReference? voice,
        VoiceLabOutputScope scope, string actionName, Project? expectedProject = null, IReadOnlyList<EditOperation>? localOperations = null,
        IReadOnlyDictionary<string, IReadOnlyList<VoiceLabRateSample>>? speakingRateSamples = null)
        => ApplyVoiceLabCore(new VoiceLabEditCommand.AcceptAll(segments, assets, voice), expectedProject, localOperations, scope, actionName, speakingRateSamples);
    public bool ApplyVoiceLab(VoiceLabEditCommand command, Project? expectedProject = null, IReadOnlyList<EditOperation>? localOperations = null)
    {
        if (command is VoiceLabEditCommand.AcceptAll) return false;
        return ApplyVoiceLabCore(command, expectedProject, localOperations, project.Edits.ActiveClipId is { } clipId ? VoiceLabOutputScope.Clip(clipId) : VoiceLabOutputScope.Full, null);
    }
    private bool ApplyVoiceLabCore(VoiceLabEditCommand command, Project? expectedProject, IReadOnlyList<EditOperation>? localOperations,
        VoiceLabOutputScope scope, string? actionName, IReadOnlyDictionary<string, IReadOnlyList<VoiceLabRateSample>>? speakingRateSamples = null)
    {
        if (!Monitor.TryEnter(voiceLabEdits)) return false;
        try
        {
            if (applyingVoiceLab || isLeaving || IsReadOnly || Busy || state is null) return false;
            if (localOperations is { Count: > 0 } && command is not (VoiceLabEditCommand.Accept or VoiceLabEditCommand.AcceptAll)) return false;
            var snapshot = expectedProject ?? project;
            if (!ReferenceEquals(snapshot, project)) return false;
            applyingVoiceLab = true;
            try
            {
                var acceptedAssets = command switch { VoiceLabEditCommand.Accept accept => accept.Assets, VoiceLabEditCommand.AcceptAll accept => accept.Assets, _ => [] };
                foreach (var asset in acceptedAssets)
                        if (undo.Concat(redo).SelectMany(entry => entry.Project.VoiceLab.Assets ?? [])
                            .Any(retained => retained.Id == asset.Id && retained != asset))
                            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidAsset);
                var modifiedAt = now();
                if (modifiedAt <= snapshot.ModifiedAt) modifiedAt = snapshot.ModifiedAt.AddTicks(1);
                var nextState = state;
                foreach (var operation in localOperations ?? []) nextState = reduce(nextState, operation);
                var combined = nextState == state ? snapshot : EditingEngine.ApplyToProject(snapshot, nextState);
                // Speaking-rate calibration measured while reviewing takes is saved with the accepted takes.
                if (speakingRateSamples is not null && command is VoiceLabEditCommand.AcceptAll)
                    combined = combined with { VoiceLab = combined.VoiceLab with { SpeakingRateSamples = speakingRateSamples } };
                var history = new VoiceLabEditHistory(combined, IsDirty);
                var change = command is VoiceLabEditCommand.AcceptAll all
                    ? history.Apply(all.Segments, all.Assets, all.Voice, scope, actionName!, modifiedAt)
                    : history.Apply(command, modifiedAt, scope);
                if (ReferenceEquals(change.Present, combined) && nextState == state) return false;
                CaptionDrag.Cancel();
                if (!ReferenceEquals(project, snapshot) || isLeaving || IsReadOnly || Busy) return false;
                undo.Push(CaptureHistory(actionName ?? command.ActionName));
                redo.Clear();
                state = nextState;
                project = change.Present;
                Refresh();
                Announcement?.Invoke(this, actionName ?? command.ActionName);
                return true;
            }
            finally { applyingVoiceLab = false; }
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Notice = UiError.Message(exception, "Voice Lab");
            return false;
        }
        finally { Monitor.Exit(voiceLabEdits); }
    }

    public void CutSelection(bool restore = false)
    {
        if (!HasSelection) return;
        var ids = Words.Skip(SelectionStart).Take(SelectionEnd - SelectionStart + 1).Select(word => word.Id).ToList();
        ids.AddRange(state!.Pauses.Where(pause => pause.AfterIndex >= SelectionStart && pause.AfterIndex < SelectionEnd).Select(pause => pause.Id));
        Apply(restore ? new EditOperation.RestoreSelection(ids) : new EditOperation.CutSelection(ids));
    }

    /// <summary>The word whose inline correction field is open (design §4.2), or null.</summary>
    public string? CorrectionWordId { get; private set; }
    /// <summary>The text typed into the open correction field. The field reports every change, so a correction that ends
    /// in the model (a selection change, a transport action, leaving) saves what the user typed.</summary>
    public string CorrectionText { get; set; } = "";
    /// <summary>The inline correction opened or ended.</summary>
    public event EventHandler? CorrectionChanged;

    /// <summary>Open the inline correction on the first selected word, ending any other one first, with the word's text.</summary>
    public bool BeginCorrection()
    {
        EndCorrection();
        if (!HasSelection || isLeaving || IsReadOnly || state is null) return false;
        var word = Words[SelectionStart];
        CorrectionWordId = word.Id;
        CorrectionText = DisplayText(word);
        CorrectionChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>Return saves valid text; Tab also opens the next word. Invalid drafts stay open, with their text.</summary>
    public bool SaveCorrection(bool advance = false)
    {
        if (CorrectionWordId is null || SavableCorrection(CorrectionText) is null) return false;
        var previous = SelectionEnd;
        EndCorrection();
        if (advance)
        {
            Select(previous + 1);
            if (SelectionEnd != previous) BeginCorrection();
        }
        return true;
    }

    /// <summary>End the inline correction the way an inline rename ends (design §4.2). Focus leaving the field, a
    /// click elsewhere, a selection change and any transport action keep the typed text when it can be saved; Esc
    /// (<paramref name="keep"/> false), or text that can't be saved, keeps the word's text. Returns whether one was open.</summary>
    public bool EndCorrection(bool keep = true)
    {
        if (CorrectionWordId is not { } id) return false;
        // Cleared first: closing the field moves focus, and the end that focus loss reports must find nothing open.
        CorrectionWordId = null;
        var text = CorrectionText;
        CorrectionText = "";
        CorrectionChanged?.Invoke(this, EventArgs.Empty);
        if (keep && SavableCorrection(text) is not null) Apply(new EditOperation.Correct(id, text));
        return true;
    }

    /// <summary>The trimmed correction, or null when it can't be saved: empty, with a line break, or longer than
    /// <see cref="EditingLimits.MaxCorrectionCodePoints"/> (project.schema.json).</summary>
    internal static string? SavableCorrection(string text)
    {
        var value = EditingAlgorithms.JsTrim(text);
        return value.Length == 0 || text.Any(character => character is '\r' or '\n' or (char)0x2028 or (char)0x2029) ||
            value.EnumerateRunes().Count() > EditingLimits.MaxCorrectionCodePoints ? null : value;
    }

    /// <summary>Make a manual clip from the selection and return its id (design §6.2). The clip is titled with the first seven
    /// words of the selection and becomes the scope in the same undo step, so revealing its row adds no second step and the
    /// announcement is "Clip N made.". When a clip already covers exactly these words, that clip becomes the scope, with no
    /// summary announcement, and the announcement says so instead of adding a duplicate.</summary>
    public string? MakeClip()
    {
        if (!HasSelection) { Notice = "Select words to make a clip. No key or account is needed."; return null; }
        if (isLeaving || IsReadOnly || Busy) return null;
        var start = Words[SelectionStart].Id;
        var end = Words[SelectionEnd].Id;
        if (Clips.FirstOrDefault(clip => clip.Clip.StartWordId == start && clip.Clip.EndWordId == end) is { } existing)
        {
            Notice = "";
            SetScope(existing.Id);
            Announcement?.Invoke(this, $"Clip {Number(existing.Id)} already covers these words.");
            return existing.Id;
        }
        var id = Guid.NewGuid().ToString("N");
        var title = EditingAlgorithms.ClipTitle(Words.Skip(SelectionStart).Take(SelectionEnd - SelectionStart + 1).Select(DisplayText));
        return Announce(ApplyBatch([new EditOperation.AddClip(new(id, start, end, title, ClipOrigin.Manual, null, null, true)), new EditOperation.SetActiveClip(id)]),
            () => $"Clip {Number(id)} made.") ? id : null;
    }
    /// <summary>Keep a suggestion: it becomes the next numbered clip.</summary>
    public bool Keep(string id) => Announce(ApplyBatch([new EditOperation.SetClipSelected(id, true)]), () => $"Clip {Number(id)} kept.");
    /// <summary>A row's Rewrite or Export (design §3.4): a suggestion is kept first, as one undo step with no prompt, so the
    /// action opens on it exactly as on a kept clip. True when the clip is kept now; false for an unknown clip or a
    /// suggestion this project cannot keep.</summary>
    public bool KeepForRowAction(string id) => Clips.FirstOrDefault(clip => clip.Id == id) is { } row && (!row.IsSuggested || !IsReadOnly && Keep(id));
    /// <summary>Keep every suggestion as one undo step.</summary>
    public bool KeepAll()
    {
        var count = SuggestedClips.Count;
        return Announce(ApplyBatch(SuggestedClips.Select(clip => (EditOperation)new EditOperation.SetClipSelected(clip.Id, true)).ToArray()), () => count == 1 ? "1 clip kept." : $"{count} clips kept.");
    }
    /// <summary>Dismiss a suggestion; its AI result stays cached in the project.</summary>
    public bool Dismiss(string id) => Announce(ApplyBatch([new EditOperation.RemoveClip(id)]), () => "Suggestion dismissed.");
    public bool Remove(string id)
    {
        var number = Number(id);
        return Announce(ApplyBatch([new EditOperation.RemoveClip(id)]), () => $"Clip {number} removed.");
    }
    public bool Rename(string id, string? title) => ApplyBatch([new EditOperation.RenameClip(id, string.IsNullOrWhiteSpace(title) ? null : title.Trim())]);
    /// <summary>Why <see cref="Rename"/> can't take this title, or null: a title is at most 120 code points once trimmed
    /// (project.schema.json), and the reducer would drop a longer one. The rename dialog shows it inline.</summary>
    public static string? ClipTitleProblem(string? title) =>
        title is not null && title.Trim().EnumerateRunes().Count() > EditingLimits.MaxClipTitleCodePoints
            ? $"Use {EditingLimits.MaxClipTitleCodePoints} characters or fewer." : null;
    /// <summary>The clip's display number, never stored (design §2).</summary>
    private string Number(string id) => Clips.FirstOrDefault(clip => clip.Id == id)?.Number.ToString(CultureInfo.InvariantCulture) ?? "";
    /// <summary>Clip commands announce what they did (design §13) instead of the edit summary.</summary>
    private bool Announce(bool applied, Func<string> text)
    {
        if (applied) Announcement?.Invoke(this, text());
        return applied;
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
    /// <summary>[ and ] walk the kept clips; suggestions are skipped until kept.</summary>
    public void CycleClip(int delta)
    {
        var kept = KeptClips;
        if (kept.Count == 0) return;
        var active = kept.ToList().FindIndex(clip => clip.Id == state?.ActiveClipId);
        var next = Math.Clamp(active + delta, 0, kept.Count - 1);
        SetScope(kept[next].Id); Select(Index(kept[next].Clip.StartWordId));
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
    private void MoveHistory(Stack<History> from, Stack<History> to)
    {
        if (isLeaving || from.Count == 0 || IsReadOnly && (!ReferenceEquals(from.Peek().State, state) ||
            !ReferenceEquals(from.Peek().Project.VoiceLab, project.VoiceLab))) return;
        CaptionDrag.Cancel();
        var next = from.Pop();
        to.Push(CaptureHistory(next.ActionName));
        state = next.State;
        var sameSource = next.Project.Media.Source.ContentKey == project.Media.Source.ContentKey &&
            next.Project.Media.Source.SizeBytes == project.Media.Source.SizeBytes;
        project = project with { Edits = next.Project.Edits, Captions = next.Project.Captions, ClipStyle = next.Project.ClipStyle, VoiceLab = next.Project.VoiceLab,
            ContextDemo = sameSource ? next.Project.ContextDemo : null, MotionCues = sameSource ? next.Project.MotionCues : [],
            Music = next.Project.Music, ClipEffects = next.Project.ClipEffects, SchemaVersion = next.Project.SchemaVersion, ModifiedAt = next.Project.ModifiedAt };
        Refresh();
    }

    public void SetCaptionStyle(string id)
    {
        if (isLeaving || IsReadOnly || Busy) return;
        // A style the user chooses fixes the clip style's captions, so no AI pick overrides it (design §6.6).
        if (project.ClipStyle is not null) { RecordClipStyle(ClipStyleCard.ChooseCaptionStyle(project, id)); return; }
        RecordCaptions(project.Captions with { StyleId = id });
    }

    public void SetExport(ProjectExport value)
    {
        if (isLeaving || IsReadOnly || Busy) return;
        if (project.Export.Aspect != value.Aspect) CaptionDrag.Cancel();
        project = project with { Export = value, ModifiedAt = DateTimeOffset.UtcNow };
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void SetCaptionOverrides(System.Text.Json.JsonElement value)
    {
        if (isLeaving || IsReadOnly || Busy) return;
        RecordCaptions(project.Captions with { Overrides = value.Clone() });
    }

    public void SetCaptions(ProjectCaptions value)
    {
        if (isLeaving || IsReadOnly || Busy) return;
        RecordCaptions(value);
    }

    /// <summary>A caption style, Fine tune or reset change is its own undo step, as on the Mac ("Change caption style", "Fine tune
    /// captions"). Undo then restores only what each step changed: undoing an earlier cut can no longer bring back the captions
    /// that step saw. Choosing what is already set records nothing.</summary>
    private void RecordCaptions(ProjectCaptions captions)
    {
        CaptionDrag.Cancel();
        if (SameCaptions(project.Captions, captions)) return;
        undo.Push(CaptureHistory()); redo.Clear();
        project = project with { Captions = captions, ModifiedAt = DateTimeOffset.UtcNow };
        foreach (var name in new[] { nameof(IsDirty), nameof(CanUndo), nameof(CanRedo), nameof(UndoActionName), nameof(RedoActionName) }) OnPropertyChanged(name);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static bool SameCaptions(ProjectCaptions a, ProjectCaptions b) =>
        a.StyleId == b.StyleId && a.Position == b.Position &&
        (a.Overrides.ValueKind == System.Text.Json.JsonValueKind.Undefined || b.Overrides.ValueKind == System.Text.Json.JsonValueKind.Undefined
            ? a.Overrides.ValueKind == b.Overrides.ValueKind : System.Text.Json.JsonElement.DeepEquals(a.Overrides, b.Overrides)) &&
        a.PositionByAspect.Count == b.PositionByAspect.Count &&
        a.PositionByAspect.All(pair => b.PositionByAspect.TryGetValue(pair.Key, out var other) && other == pair.Value);

    internal void MoveCaptionAnchor(CaptionPosition anchor)
        => MoveCaptionSettings(CaptionFineTune.Anchor(project, anchor));
    internal void CompleteCaptionDrag(CaptionPosition anchor)
    {
        if (CaptionDrag.Complete(project.Export.Aspect)) MoveCaptionAnchor(anchor);
    }
    internal void MoveCaptionPosition(int choice)
        => MoveCaptionSettings(CaptionFineTune.Position(project, choice));
    private void MoveCaptionSettings(ProjectCaptions captions)
    {
        if (isLeaving || Busy) return;
        CaptionDrag.Cancel();
        if (CaptionFineTune.StoredPosition(project) == CaptionFineTune.StoredPosition(project with { Captions = captions })) return;
        undo.Push(CaptureHistory()); redo.Clear();
        project = project with { Captions = captions, ModifiedAt = DateTimeOffset.UtcNow };
        Refresh();
    }

    public void SetTranscript(Core.Domain.Transcript.Transcript value)
    {
        if (isLeaving) return;
        CaptionDrag.Cancel();
        // A new transcript replaces the word an open correction was typed for, so its draft is dropped.
        EndCorrection(keep: false);
        if (state is not null)
        {
            state = EditingEngine.Reduce(state, new EditOperation.ReplaceTranscript(value));
            project = EditingEngine.ApplyToProject(project, state);
        }
        else project = ProjectStore.ReplaceTranscript(project, value);
        undo.Clear(); redo.Clear(); selectionAnchor = -1; selectionEnd = -1;
        InitializeState(); Refresh();
    }

    /// <summary>Cache the run, then add its clips as suggestions (not kept) in one undo step; delta §6.2.</summary>
    /// <summary>Add a Find clips result as suggestions in one undo step and return the new suggestions' ids.</summary>
    public IReadOnlyList<string> AddAiResult(AiResult result)
    {
        if (isLeaving || state is null) return [];
        var previous = project.Ai;
        project = project with { Ai = new(project.Ai.Results.Append(result).ToArray()) };
        var add = new EditOperation.AddAiClips(result.Id, result.Clips);
        var before = state.Clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
        string[] added;
        try { added = reduce(state, add).Clips.Select(clip => clip.Id).Where(id => !before.Contains(id)).ToArray(); }
        catch (Exception exception) when (exception is not OutOfMemoryException) { added = []; }
        if (ApplyBatch([add, .. added.Select(id => new EditOperation.SetClipSelected(id, false))])) return added;
        project = project with { Ai = previous };
        return [];
    }

    public string DisplayText(TimedWord word) => state?.Corrections.GetValueOrDefault(word.Id) ?? word.Text;
    public int Index(string id)
    {
        for (var index = 0; index < Words.Count; index++) if (Words[index].Id == id) return index;
        return -1;
    }
    public string AccessibleWord(int index, bool showLowConfidence = false)
    {
        if (index < 0 || index >= Words.Count) return "Transcript";
        return WordStates(index, showLowConfidence) + (HasSelection && index >= SelectionStart && index <= SelectionEnd ? ", selected" : "");
    }
    /// <summary>What Narrator says after a keyboard move (design §15): the caret word with its states, then "selected" or the
    /// selection's size, as in "shipped, corrected, heard as: ship, 3 words selected"; "All 9 words selected" after Select All;
    /// empty with nothing selected.</summary>
    public string SelectionAnnouncement(bool showLowConfidence = false)
    {
        if (!HasSelection) return "";
        var count = SelectionEnd - SelectionStart + 1;
        if (count > 1 && count == Words.Count) return $"All {count} words selected";
        return WordStates(selectionEnd, showLowConfidence) + (count == 1 ? ", selected" : $", {count} words selected");
    }
    private string WordStates(int index, bool showLowConfidence)
    {
        var word = Words[index];
        var speech = PresentedWord(index);
        if (!speech.Visible)
            for (var first = index - 1; first >= 0; first--)
                if (PresentedWord(first) is { Visible: true, AiModified: true } replacement && replacement.LastSourceIndex >= index)
                { speech = replacement; break; }
        return speech.Text + (!speech.AiModified && state?.CutWordIds.Contains(word.Id) == true ? ", cut" : "")
            + (!speech.AiModified && EditingAlgorithms.IsFillerText(DisplayText(word)) ? ", filler" : "")
            + (!speech.AiModified && showLowConfidence && word.Conf is < 0.6 ? ", low confidence" : "")
            + (!speech.AiModified && state?.Corrections.ContainsKey(word.Id) == true ? ", corrected, heard as: " + word.Text : "")
            + (speech.AiModified && SourceTime >= Words[IndexOfSpeechStart(index)].Start && SourceTime < Words[speech.LastSourceIndex].End ? ", playing" : "")
            + (speech.AiModified ? ", AI modified" : "");
    }
    private int IndexOfSpeechStart(int index)
    {
        while (index > 0 && !PresentedWord(index).Visible) index--;
        return index;
    }
    public bool CanPreviewCut => HasSelection && CanExport;
    internal TimeRange? PreviewCutRange() => CanPreviewCut
        ? new TimeRange(Math.Max(0, Words[SelectionStart].Start - 2), Math.Min(project.Media.Source.DurationSeconds, Words[SelectionEnd].End + 2)) : null;
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

    /// <summary>Count cuts in the selected row's scope: maximal runs of consecutive cut words plus cut pauses (delta §3.5).</summary>
    private void UpdateSummaryLine(double sourceSeconds)
    {
        var active = state?.ActiveClipId is { } id ? Clips.FirstOrDefault(clip => clip.Id == id) : null;
        var first = active is null ? 0 : Index(active.Clip.StartWordId);
        var last = active is null ? Words.Count - 1 : Index(active.Clip.EndWordId);
        int cutWords = 0, runs = 0;
        var inRun = false;
        for (var index = Math.Max(0, first); index <= last; index++)
        {
            var cut = state!.CutWordIds.Contains(Words[index].Id);
            if (cut) { cutWords++; if (!inRun) runs++; }
            inRun = cut;
        }
        var cutPauses = state!.Pauses.Count(pause => state.CutPauseIds.Contains(pause.Id) && (active is null || pause.AfterIndex >= first && pause.AfterIndex < last));
        var cuts = runs + cutPauses;
        var edited = Duration(active?.DurationSeconds ?? FullTakeDuration);
        var prefix = active is null ? "" : $"Clip {active.Number} · ";
        SummaryLine = !Summary.CanExport ? "Keep at least one word before exporting."
            : cuts == 0 ? $"{prefix}{edited} · No cuts yet" : $"{prefix}{edited} after cuts · {cuts} {Plural(cuts, "cut")}";
        SummaryTooltip = $"{Duration(sourceSeconds)} source · {cutWords} {Plural(cutWords, "word")} cut in {runs} {Plural(runs, "place")} · {cutPauses} {Plural(cutPauses, "pause")} cut";
    }

    private void SyncProject()
    {
        if (state is null) return;
        var clipIds = state.Clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
        project = project with { ModifiedAt = now(), Edits = new(state.PauseThresholdSeconds, state.PauseKeepSeconds,
            state.CutWordIds.ToArray(), state.CutPauseIds.ToArray(), new Dictionary<string, string>(state.Corrections), state.Clips.ToArray(), state.ActiveClipId),
            MotionCues = project.MotionCues.Where(cue => clipIds.Contains(cue.ClipID)).ToArray(),
            Music = VoxClip.Core.Domain.Music.MusicProject.Pruned(project.Music, clipIds),
            ClipEffects = VoxClip.Core.Domain.Effects.ClipEffects.Pruned(project.ClipEffects, clipIds) };
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
            foreach (var range in TranscriptParagraphs.Split(Words))
            {
                var end = range.End.Value;
                // Keep the existing presentation rule: a hidden next word cannot start a row.
                if (end < Words.Count && !PresentedWord(end).Visible) continue;
                Paragraphs.Add(new(start, end - start, Timecode(Words[start].Start), Words[start].Speaker));
                start = end;
            }
            var source = project.Media.Source;
            var sampleRate = source.Audio?.SampleRate is > 0 ? source.Audio.SampleRate : 48000;
            double EditedLength(EditState scoped) => EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(scoped, source.DurationSeconds),
                source.DurationSeconds, sampleRate, scoped.PauseKeepSeconds).Duration;
            try { FullTakeDuration = EditedLength(state with { ActiveClipId = null }); }
            catch (VoxClipException) { FullTakeDuration = 0; }
            // Kept clips by start word, then creation order, numbered 1…n; then suggestions n+1… (design §2). Numbers are never stored.
            var ranges = state.Clips.Select((clip, order) => (Clip: clip, First: Index(clip.StartWordId), Last: Index(clip.EndWordId), Order: order))
                .Where(range => range.First >= 0 && range.Last >= range.First).ToArray();
            static bool Suggested(ClipRange clip) => clip.Origin == ClipOrigin.Ai && !clip.Selected;
            var number = 0;
            foreach (var range in ranges.Where(range => !Suggested(range.Clip)).OrderBy(range => range.First).ThenBy(range => range.Order)
                .Concat(ranges.Where(range => Suggested(range.Clip)).OrderBy(range => range.First).ThenBy(range => range.Order)))
            {
                var clip = range.Clip;
                var suggestion = project.Ai.Results.FirstOrDefault(result => result.Id == clip.AiResultId)?.Clips.ElementAtOrDefault(clip.AiClipIndex ?? -1);
                number++;
                Clips.Add(new(clip, number, clip.Title ?? suggestion?.Title ?? $"Clip {number}",
                    string.Join(" ", Words.Skip(range.First).Take(range.Last - range.First + 1).Select(DisplayText)),
                    suggestion?.Reason ?? "", suggestion?.Score, EditedLength(state with { ActiveClipId = clip.Id })));
            }
            UpdateSummaryLine(source.DurationSeconds);
        }
        else { FullTakeDuration = project.Media.Source.DurationSeconds; SummaryLine = ""; SummaryTooltip = ""; }
        RefreshExportRows();
        foreach (var name in new[] { nameof(Project), nameof(State), nameof(IsDirty), nameof(Summary), nameof(SummaryLine), nameof(SummaryTooltip), nameof(KeptClips), nameof(SuggestedClips), nameof(FillerLabel), nameof(CanExport), nameof(CanFindClips), nameof(CanUndo), nameof(CanRedo), nameof(UndoActionName), nameof(RedoActionName), nameof(HasTranscript), nameof(FullTakeDuration) }) OnPropertyChanged(name);
        Changed?.Invoke(this, EventArgs.Empty);
    }
}

public sealed record TranscriptParagraph(int StartIndex, int Count, string Timecode, string? Speaker);

/// <summary>What the export ledger knows about a clip; the ledger arrives with the export dialog's redesign (round 2).</summary>
public enum ClipExportState { None, Exported, ChangedSinceExport, Exporting, Failed }

/// <summary>One clip in the pane (design §6.2). <see cref="Number"/> is its display number: kept clips 1…n, then suggestions.</summary>
public sealed record ClipRow(ClipRange Clip, int Number, string Title, string Excerpt, string Reason, int? Score, double DurationSeconds)
{
    public string Id => Clip.Id;
    public bool Selected => Clip.Selected;
    /// <summary>An AI clip that is not kept yet (design §2); manual clips are always kept.</summary>
    public bool IsSuggested => Clip.Origin == ClipOrigin.Ai && !Clip.Selected;
    /// <summary>Edited length as <c>m:ss</c>, from the same plan as preview and export.</summary>
    public string Duration => EditorViewModel.Duration(DurationSeconds);
    /// <summary>The clip's poster frame once cached; null shows the bare stage tile.</summary>
    public string? Thumbnail { get; init; }
    public ClipExportState ExportState { get; init; }
    public double? ExportProgress { get; init; }
    /// <summary>Hover text: the AI reason with its score; empty for manual clips.</summary>
    public string ToolTip => Score is { } score ? (Reason.Length == 0 ? $"{score}/10" : $"{score}/10 · {Reason}") : Reason;
}

internal static class StringExtensions
{
    internal static bool EndsWithAny(this string text, string endings) => text.Length > 0 && endings.Contains(text[^1], StringComparison.Ordinal);
}
