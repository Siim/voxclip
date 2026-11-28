using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Where a selected cut's edges sit and what its one action writes, by the later word's clock id: each edge's word edge
/// (Use word edge) or the quiet point found (Use quiet point). Mac <c>CutEdgeChoice</c>.</summary>
public sealed record CutEdgeChoice(bool Quiet, IReadOnlyDictionary<string, double> Writes, string? Reason)
{
    /// <summary>The row's line.</summary>
    public string Status => Quiet ? "Cut edge: quiet point" : "Cut edge: word edge";
    /// <summary>The row's action, and its undo name.</summary>
    public string Action => Quiet ? "Use word edge" : "Use quiet point";
}

/// <summary>The timeline's cut edge row (design §6.8): its line and, when it has one, its inline action and why that is disabled.</summary>
public sealed record CutEdgeBarRow(string Text, string? Action = null, string? Reason = null);

/// <summary>Cut edges seated in the quiet on Windows (editing §5.10, design §6.8 "Cut edges"), twin of the Mac
/// <c>EditorModel+CutEdges</c>: the levels and freeze the seat reads, the commit hook every edit runs, the timeline's offer and
/// per-cut rows, and the ClipBar's Fix cut edges. The page hands in each recording's levels as its waveform loads; nothing here
/// reads App services.</summary>
public sealed partial class EditorViewModel
{
    private readonly Dictionary<string, AudioEnvelope> cutEdgeLevels = new(StringComparer.Ordinal);
    /// <summary>Recordings whose video is missing or unreadable, so their levels can't load until it is found again.</summary>
    private readonly HashSet<string> cutEdgeUnreachable = new(StringComparer.Ordinal);
    /// <summary>The open Rewrites, whose scopes keep their edges (editing §5.10 "Frozen boundaries").</summary>
    private readonly List<RewriteSession> openRewrites = [];
    private string? cutEdgePaidRoot;
    private int cutEdgeRevision;
    private (Project Project, int Revision, CutEdges.OfferSummary Offer)? cutEdgeOfferMemo;
    private (Project Project, int Revision, int First, int Last, CutEdgeChoice? Choice)? cutEdgeChoiceMemo;
    private (Project Project, IReadOnlyList<string> Scopes)? savedPaidScopesMemo;
    private (ProjectEdits Edits, string Text)? cutEdgeResult;

    /// <summary>The levels, the open Rewrites or the result line changed: the timeline row and the ClipBar command read again.</summary>
    internal event EventHandler? CutEdgesChanged;

    private void CutEdgeInputsChanged()
    {
        cutEdgeRevision++;
        CutEdgesChanged?.Invoke(this, EventArgs.Empty);
    }

    // MARK: What the seat reads

    /// <summary>A recording's 10 ms levels as the page's waveform load reads them, by its key (the source's content key, or a spoken
    /// recording's source key); null when its video is missing or unreadable. The frame length comes from the levels' own rate.</summary>
    internal void SetCutEdgeLevels(string key, AudioEnvelope? levels)
    {
        if (levels is null) { cutEdgeLevels.Remove(key); cutEdgeUnreachable.Add(key); }
        else { cutEdgeLevels[key] = levels; cutEdgeUnreachable.Remove(key); }
        CutEdgeInputsChanged();
    }

    /// <summary>A new waveform load starts (the media changed): levels read so far are dropped until it reads them again.</summary>
    internal void ClearCutEdgeLevels()
    {
        if (cutEdgeLevels.Count == 0 && cutEdgeUnreachable.Count == 0) return;
        cutEdgeLevels.Clear();
        cutEdgeUnreachable.Clear();
        CutEdgeInputsChanged();
    }

    /// <summary>The Voice Lab folder paid Rewrite proposals are saved in, beside each project (<see cref="SavedRewriteProposalStore"/>).</summary>
    internal void SetCutEdgePaidRoot(string? paidRoot)
    {
        if (cutEdgePaidRoot == paidRoot) return;
        cutEdgePaidRoot = paidRoot;
        savedPaidScopesMemo = null;
        CutEdgeInputsChanged();
    }

    /// <summary>A Rewrite opened or closed on this editor (<see cref="RewriteSession"/> registers itself).</summary>
    internal void RewriteOpened(RewriteSession session)
    {
        if (openRewrites.Contains(session)) return;
        openRewrites.Add(session);
        CutEdgeInputsChanged();
    }

    internal void RewriteClosed(RewriteSession session)
    {
        if (openRewrites.Remove(session)) CutEdgeInputsChanged();
    }

    /// <summary>What keeps a boundary at today's padding (editing §5.10 "Frozen boundaries"), by recording key:
    /// - every Voice Lab segment's replace range, enabled or not, in its recording's local seconds;
    /// - the word ranges of paid or open work (<see cref="PaidCutEdgeScopes"/>) in the first recording, the one Rewrite voices;
    /// - while any of those is held, every later recording: its words have no position in Rewrite's scoped inputs, so its cuts and
    ///   edges count in every scope (<see cref="ProjectVoiceTakeIdentity.RewriteInputs"/>).</summary>
    internal IReadOnlyDictionary<string, CutEdges.Freeze> CutEdgeFreeze(Project project)
    {
        var recordings = CutEdges.Recordings(project);
        var result = new Dictionary<string, CutEdges.Freeze>(StringComparer.Ordinal);
        if (recordings.Count == 0) return result;
        var voice = new Dictionary<string, List<TimeRange>>(StringComparer.Ordinal);
        var paid = new Dictionary<string, List<ClipWordRange>>(StringComparer.Ordinal);
        var clock = ProjectClock.Build(project);
        double rate = clock.SampleRate;
        foreach (var segment in project.VoiceLab.Segments)
        {
            if ((clock.RegionOf(segment.Replace.FirstWordId) ?? clock.Regions.FirstOrDefault()) is not { } region) continue;
            var offset = region.OffsetSamples / rate;
            Add(voice, region.Key, new TimeRange(segment.Replace.Start - offset, segment.Replace.End - offset));
        }
        var primary = recordings[0];
        var scopes = PaidCutEdgeScopes(project);
        foreach (var scope in scopes)
            if (scope is { } range && range.Upper < primary.Words.Count)
                Add(paid, primary.Key, new ClipWordRange(primary.Words[range.Lower].Id, primary.Words[range.Upper].Id));
        if (scopes.Count > 0)
            foreach (var recording in recordings.Skip(1)) Add(voice, recording.Key, new TimeRange(-double.MaxValue, double.MaxValue));
        foreach (var key in voice.Keys.Union(paid.Keys))
            result[key] = new(voice.GetValueOrDefault(key) ?? [], paid.GetValueOrDefault(key) ?? []);
        return result;

        static void Add<T>(Dictionary<string, List<T>> lists, string key, T item)
        {
            if (!lists.TryGetValue(key, out var list)) lists[key] = list = [];
            list.Add(item);
        }
    }

    /// <summary>The word ranges (positions in <c>project.Transcript</c>, as <see cref="ProjectVoiceTakeIdentity.RewriteInputs"/> reads
    /// them) whose inputs paid or open work is made from; null is the full take. They are a clip with a whole-clip revoice or a lip
    /// sync, an open Rewrite (paid or not: an edge moving at its scope's edge would set its proposal aside), and a Rewrite's paid
    /// takes saved beside the project.</summary>
    internal IReadOnlyList<(int Lower, int Upper)?> PaidCutEdgeScopes(Project project)
    {
        IReadOnlyList<TimedWord> words = project.Transcript?.Words ?? [];
        var scopes = new List<(int Lower, int Upper)?>();
        if (words.Count == 0) return scopes;
        var positions = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < words.Count; index++) positions.TryAdd(words[index].Id, index);
        (int Lower, int Upper)? ClipBounds(string? id) =>
            id is not null && project.Edits.Clips.FirstOrDefault(clip => clip.Id == id) is { } clip &&
            positions.TryGetValue(clip.StartWordId, out var lower) && positions.TryGetValue(clip.EndWordId, out var upper) && lower <= upper
                ? (lower, upper) : null;
        // The scope's word range as rewriteInputs reads it: a selection takes in the clip it sits in. False when the clip is gone.
        bool Bounds(RewriteScope scope, string? clipId, out (int Lower, int Upper)? range)
        {
            range = null;
            if (scope.ClipId is { } id) { range = ClipBounds(id); return range is not null; }
            if (scope is not { First: int first, Last: int last }) return true;
            if (first < 0 || last < first || last >= words.Count) return false;
            range = ClipBounds(clipId) is { } enclosing ? (Math.Min(first, enclosing.Lower), Math.Max(last, enclosing.Upper)) : (first, last);
            return true;
        }
        foreach (var record in project.VoiceLab.WholeClipRevoices ?? [])
            if (record.ClipId == WholeClipRevoice.FullTakeId) scopes.Add(null);
            else if (ClipBounds(record.ClipId) is { } range) scopes.Add(range);
        var clipRanges = project.Edits.Clips.Select(clip => ClipBounds(clip.Id)).OfType<(int Lower, int Upper)>().ToArray();
        foreach (var segment in project.VoiceLab.Segments.Where(segment => segment.Candidates.Any(candidate => candidate.Recipe?.Video.Mode == VoiceLabVideoMode.Lipsync)))
        {
            if (!positions.TryGetValue(segment.Replace.FirstWordId, out var position)) continue;
            var holding = clipRanges.Where(range => range.Lower <= position && position <= range.Upper).ToArray();
            if (holding.Length == 0) scopes.Add(null);
            else foreach (var range in holding) scopes.Add(range);
        }
        foreach (var session in openRewrites.Where(session => session.IsOpen))
            if (Bounds(session.IdentityScope, session.IdentityClipId, out var range)) scopes.Add(range);
        foreach (var saved in SavedPaidRewriteScopes(project))
        {
            var parts = saved.Split(':', 3);
            RewriteScope? scope = null;
            string? clip = null;
            if (parts[0] == "full") scope = RewriteScope.FullTake;
            else if (parts[0] == "clip" && parts.Length >= 2) scope = RewriteScope.Clip(saved["clip:".Length..]);
            else if (parts[0] == "selection" && parts.Length == 3 && parts[1].Split('-') is [var low, var high] &&
                int.TryParse(low, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var first) &&
                int.TryParse(high, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var last) && first <= last)
            {
                scope = RewriteScope.Selection(first, last);
                clip = parts[2].Length > 0 ? parts[2] : null;
            }
            if (scope is not null && Bounds(scope, clip, out var range)) scopes.Add(range);
        }
        return scopes;
    }

    /// <summary>The scopes of the Rewrite proposals with paid takes saved beside this project, read without changing anything, once
    /// per project change.</summary>
    private IReadOnlyList<string> SavedPaidRewriteScopes(Project project)
    {
        if (cutEdgePaidRoot is not { } root) return [];
        if (savedPaidScopesMemo is { } memo && ReferenceEquals(memo.Project, project)) return memo.Scopes;
        var scopes = SavedRewriteProposalStore.PaidScopes(root, project.Id, now());
        savedPaidScopesMemo = (project, scopes);
        return scopes;
    }

    // MARK: The commit hook

    /// <summary>Every edit's step (editing §5.10 "When it runs"): the boundaries whose kept/cut state changed are seated with the loaded
    /// levels and the freeze, and keys no longer at a kept/cut boundary go, so a cut and its restore leave the edits as they were. A
    /// recording without loaded levels keeps today's padding there; Fix cut edges picks it up later. Undo and Redo restore
    /// snapshots and never come here.</summary>
    private Project CommittingCutEdges(Project before, Project after)
    {
        var cutsChanged = !new HashSet<string>(before.Edits.CutWordIds, StringComparer.Ordinal).SetEquals(after.Edits.CutWordIds);
        if (!cutsChanged && after.Edits.CutEdges is not { Count: > 0 } && before.Edits.CutEdges is not { Count: > 0 }) return after;
        IReadOnlyDictionary<string, AudioEnvelope> levels = cutsChanged ? cutEdgeLevels : new Dictionary<string, AudioEnvelope>();
        try { return CutEdges.Finalize(before, after, levels, levels.Count == 0 ? null : CutEdgeFreeze(after)); }
        catch (Exception exception) when (exception is not OutOfMemoryException) { return after; }
    }

    /// <summary><see cref="ApplyBatch(IEnumerable{EditOperation}, string?)"/>'s hook: the project synced from the reduced state is seated
    /// against <paramref name="before"/>, and the state takes the edges the plan reads.</summary>
    private void SeatCutEdges(Project before)
    {
        if (state is null) return;
        var seated = CommittingCutEdges(before, project);
        if (ReferenceEquals(seated, project)) return;
        project = seated;
        state = state with { CutEdges = seated.Edits.CutEdges ?? System.Collections.ObjectModel.ReadOnlyDictionary<string, double>.Empty };
    }

    // MARK: Old cuts: the offer and Fix cut edges

    /// <summary>What Fix cut edges would do now (editing §5.10 "Existing projects"): N edges that would move, K kept beside voice
    /// patches, and the recordings whose levels aren't loaded. Counted once per change of the project, the levels or the open
    /// Rewrites.</summary>
    internal CutEdges.OfferSummary CutEdgeOffer
    {
        get
        {
            if (cutEdgeOfferMemo is { } memo && ReferenceEquals(memo.Project, project) && memo.Revision == cutEdgeRevision) return memo.Offer;
            var offer = ReadCutEdgeOffer();
            cutEdgeOfferMemo = (project, cutEdgeRevision, offer);
            return offer;
        }
    }

    private CutEdges.OfferSummary ReadCutEdgeOffer()
    {
        // With no kept/cut boundary left without a key there is nothing to count, and no levels to analyse.
        var cut = new HashSet<string>(project.Edits.CutWordIds, StringComparer.Ordinal);
        var edges = project.Edits.CutEdges ?? new Dictionary<string, double>();
        var open = cut.Count > 0 && CutEdges.Recordings(project).Any(recording =>
            Enumerable.Range(1, Math.Max(0, recording.Words.Count - 1)).Any(index =>
                !edges.ContainsKey(recording.Words[index].Id) && CutEdges.Qualifies(recording.Words[index - 1], recording.Words[index], cut)));
        try
        {
            return open ? CutEdges.Offer(project, cutEdgeLevels, CutEdgeFreeze(project))
                : CutEdges.Offer(project, new Dictionary<string, AudioEnvelope>());
        }
        catch (Exception exception) when (exception is not OutOfMemoryException) { return new(0, 0, []); }
    }

    private bool CanEditCutEdges => !isLeaving && !IsReadOnly && state is not null;

    /// <summary>The ClipBar's Fix cut edges can run: old cuts could move into the quiet.</summary>
    public bool CanFixCutEdges => CanEditCutEdges && CutEdgeOffer.Count > 0;

    /// <summary>Why Fix cut edges is disabled (design §6.8), or null when it can run.</summary>
    public string? FixCutEdgesReason
    {
        get
        {
            var offer = CutEdgeOffer;
            if (offer.Count > 0) return null;
            return offer.Unloaded.FirstOrDefault() is { } key ? UnloadedLevelsReason(key) : "All cut edges are in the quiet";
        }
    }

    /// <summary>Why a recording's levels aren't there to seat on: its video is missing or unreadable, or they are still loading.</summary>
    private string UnloadedLevelsReason(string key) =>
        cutEdgeUnreachable.Contains(key) || key == project.Media.Source.ContentKey && IsReadOnly
            ? $"Reconnect {RecordingLabel(key)} to fix its cut edges" : "Waveform still loading";

    /// <summary>A recording's name as the timeline's recording lanes show it.</summary>
    private string RecordingLabel(string key)
    {
        try { if (ProjectClock.Build(project).Regions.FirstOrDefault(region => region.Key == key) is { } region) return region.Label; }
        catch (Exception exception) when (exception is not OutOfMemoryException) { }
        return ProjectClock.Label(project.Media.Source);
    }

    /// <summary>Fix cut edges: every old cut's edges that can move into the quiet, as one undo step "Fix cut edges", then the result
    /// line, which stays while its edits stand.</summary>
    public bool FixCutEdges()
    {
        if (!CanEditCutEdges) return false;
        Project fixedProject;
        CutEdges.OfferSummary offer;
        try { (fixedProject, offer) = CutEdges.Fix(project, cutEdgeLevels, CutEdgeFreeze(project)); }
        catch (Exception exception) when (exception is not OutOfMemoryException) { return false; }
        if (offer.Count == 0 || !ReplaceProject(fixedProject, "Fix cut edges")) return false;
        var moved = $"Moved {offer.Count} cut {(offer.Count == 1 ? "edge" : "edges")} into the quiet";
        var text = offer.Frozen > 0 ? $"{moved} · {offer.Frozen} kept beside voice patches" : moved;
        cutEdgeResult = (project.Edits, text);
        Announce(text);
        CutEdgesChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    // MARK: A selected cut

    /// <summary>The selected cut words' edges at a kept neighbour (design §6.8): on a quiet point the seat found, with Use word edge to
    /// pin each one at the word edge, or on the word edge, with Use quiet point to seat them again. Null when no selected cut word has
    /// such an edge. Read once per change of the selection, the project, the levels or the open Rewrites.</summary>
    public CutEdgeChoice? SelectedCutEdge
    {
        get
        {
            if (!HasSelection || state is null) return null;
            var (first, last) = (SelectionStart, SelectionEnd);
            if (cutEdgeChoiceMemo is { } memo && ReferenceEquals(memo.Project, project) && memo.Revision == cutEdgeRevision &&
                memo.First == first && memo.Last == last) return memo.Choice;
            var selected = Words.Skip(first).Take(last - first + 1).Select(word => word.Id).ToHashSet(StringComparer.Ordinal);
            CutEdgeChoice? choice = null;
            if (selected.Overlaps(project.Edits.CutWordIds))
            {
                try { choice = ReadCutEdgeChoice(selected); }
                catch (Exception exception) when (exception is not OutOfMemoryException) { choice = null; }
            }
            cutEdgeChoiceMemo = (project, cutEdgeRevision, first, last, choice);
            return choice;
        }
    }

    private CutEdgeChoice? ReadCutEdgeChoice(IReadOnlySet<string> selected)
    {
        var cut = new HashSet<string>(project.Edits.CutWordIds, StringComparer.Ordinal);
        var edges = project.Edits.CutEdges ?? new Dictionary<string, double>();
        double rate = Math.Max(1, project.Media.Source.Audio?.SampleRate ?? 48_000);
        var recordings = CutEdges.Recordings(project);
        var boundaries = new List<(CutEdges.Recording Recording, int Index)>();
        foreach (var recording in recordings)
        {
            var words = recording.Words;
            for (var index = 1; index < words.Count; index++)
            {
                if (!CutEdges.Qualifies(words[index - 1], words[index], cut)) continue;
                var removed = cut.Contains(words[index].Id) ? words[index] : words[index - 1];
                if (selected.Contains(removed.Id)) boundaries.Add((recording, index));
            }
        }
        if (boundaries.Count == 0) return null;
        var freeze = CutEdgeFreeze(project);
        CutEdges.Freeze FreezeOf(string key) => freeze.GetValueOrDefault(key) ?? CutEdges.Freeze.None;
        var open = boundaries.Where(item => !CutEdges.IsFrozen(item.Recording.Words, item.Index, cut, FreezeOf(item.Recording.Key))).ToArray();
        var quiet = boundaries.Any(item => edges.TryGetValue(item.Recording.Words[item.Index].Id, out var edge) &&
            edge != CutEdges.WordEdge(item.Recording.Words[item.Index - 1], item.Recording.Words[item.Index], rate));
        const string kept = "Kept beside a voice patch";
        var writes = new Dictionary<string, double>(StringComparer.Ordinal);
        if (quiet)
        {
            foreach (var (recording, index) in open)
            {
                var a = recording.Words[index - 1];
                var b = recording.Words[index];
                var pin = CutEdges.WordEdge(a, b, rate);
                if (pin > a.Start && pin < b.End && (!edges.TryGetValue(b.Id, out var edge) || edge != pin)) writes[b.Id] = pin;
            }
            return new(true, writes, writes.Count == 0 ? kept : null);
        }
        if (open.Length == 0) return new(false, writes, kept);
        var unloaded = new List<string>();
        foreach (var recording in recordings)
        {
            var ids = open.Where(item => item.Recording.Key == recording.Key).Select(item => item.Recording.Words[item.Index].Id).ToHashSet(StringComparer.Ordinal);
            if (ids.Count == 0) continue;
            if (!cutEdgeLevels.TryGetValue(recording.Key, out var levels)) { unloaded.Add(recording.Key); continue; }
            var others = edges.Where(pair => !ids.Contains(pair.Key)).ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
            var seated = CutEdges.Seat(recording.Words, cut, levels, rate, FreezeOf(recording.Key), others, ids);
            foreach (var (id, edge) in seated.Edges) writes[id] = edge;
        }
        if (writes.Count > 0) return new(false, writes, null);
        return new(false, writes, unloaded.Count > 0 ? UnloadedLevelsReason(unloaded[0]) : "No quiet point near this edge");
    }

    /// <summary>The selected cut's action, as one undo step named for it ("Use word edge", "Use quiet point").</summary>
    public bool UseSelectedCutEdge()
    {
        if (!CanEditCutEdges || SelectedCutEdge is not { Reason: null, Writes.Count: > 0 } choice) return false;
        var edges = new Dictionary<string, double>(project.Edits.CutEdges ?? new Dictionary<string, double>(), StringComparer.Ordinal);
        foreach (var (id, edge) in choice.Writes) edges[id] = edge;
        return ReplaceProject(project with { Edits = project.Edits with { CutEdges = edges } }, choice.Action);
    }

    /// <summary>The timeline row's action: the selected cut's, else Fix cut edges.</summary>
    public bool RunCutEdgeBarAction() => SelectedCutEdge is not null ? UseSelectedCutEdge() : FixCutEdges();

    /// <summary>The one cut edge row the timeline shows: a selected cut's edges, the result of Fix cut edges while its edits stand, or
    /// the offer while old cuts could move.</summary>
    public CutEdgeBarRow? CutEdgeBarRow
    {
        get
        {
            if (SelectedCutEdge is { } choice) return new(choice.Status, choice.Action, choice.Reason);
            if (cutEdgeResult is { } result && ReferenceEquals(result.Edits, project.Edits)) return new(result.Text);
            var count = CutEdgeOffer.Count;
            return count == 0 ? null : new($"{count} {(count == 1 ? "cut" : "cuts")} can land in the quiet", "Fix cut edges");
        }
    }
}
