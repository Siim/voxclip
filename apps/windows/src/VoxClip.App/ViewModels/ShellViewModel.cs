using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;

namespace VoxClip.App.ViewModels;

public enum SidebarKind { Home, Separator, Project, FullTake, Clip, SuggestedHeader, Suggestion, Action, RecentHeader, Recent, Empty, Finding, Callout, NoneFound }

/// <summary>A callout under the sidebar actions (design §13): no connector, or a problem finding clips. See <see cref="ClipCallouts"/>.</summary>
public sealed record SidebarCallout(string Title, string Message, string Action);

/// <summary>One NavigationView row. Rows keep their instance by <see cref="Key"/> across rebuilds so selection and focus survive; design §3.4.</summary>
public sealed class SidebarRow(SidebarKind kind, string key) : ObservableObject
{
    private string title = "";
    private string detail = "";
    private string metaTime = "";
    private string metaStatus = "";
    private string action = "";
    private string number = "";
    private string accessibleName = "";
    private string toolTip = "";
    private bool isActive;
    private bool isEnabled = true;
    private MediaTile? media;
    private bool showsKeepAll;
    private bool showsCancel;
    private string cancelName = "";
    public SidebarKind Kind { get; } = kind;
    public string Key { get; } = key;
    /// <summary>The clip id of a clip or suggestion row.</summary>
    public string? ClipId { get; init; }
    /// <summary>The recent project shown by a Recent row.</summary>
    public RecentProject? Recent { get; init; }
    public string Title { get => title; set => SetProperty(ref title, value); }
    /// <summary>Second header line: the project's file name, or an action's shortcut.</summary>
    public string Detail { get => detail; set => SetProperty(ref detail, value); }
    /// <summary>The meta line (design §3.4 grammar): the m:ss duration in Cascadia Mono, then " · " and the status in the UI
    /// font. Either part may be empty: "Not transcribed" and "Transcribing · 42%" have no duration.</summary>
    public string Meta => metaTime + metaStatus;
    public string MetaTime { get => metaTime; set { if (SetProperty(ref metaTime, value)) OnPropertyChanged(nameof(Meta)); } }
    public string MetaStatus { get => metaStatus; set { if (SetProperty(ref metaStatus, value)) OnPropertyChanged(nameof(Meta)); } }
    /// <summary>A callout's one action: "Set up AI…", "Sign-in help" or "Retry"; empty for none.</summary>
    public string Action { get => action; set { if (SetProperty(ref action, value)) OnPropertyChanged(nameof(HasAction)); } }
    /// <summary>The Full take row offers Cancel while its video transcribes (design §3.4).</summary>
    public bool ShowsCancel { get => showsCancel; set => SetProperty(ref showsCancel, value); }
    public string CancelName { get => cancelName; set => SetProperty(ref cancelName, value); }
    /// <summary>Display number of a clip or suggestion; never stored (design §2).</summary>
    public string Number { get => number; set { if (SetProperty(ref number, value)) { OnPropertyChanged(nameof(KeepName)); OnPropertyChanged(nameof(DismissName)); } } }
    /// <summary>A suggestion's Keep and Dismiss buttons: "Keep suggested clip 5", "Dismiss suggested clip 5".</summary>
    public string KeepName => $"Keep suggested clip {Number}";
    public string DismissName => $"Dismiss suggested clip {Number}";
    public string AccessibleName { get => accessibleName; set => SetProperty(ref accessibleName, value); }
    public string ToolTip { get => toolTip; set => SetProperty(ref toolTip, value); }
    /// <summary>The row's clip is the active clip: its badge takes the accent fill.</summary>
    public bool IsActive { get => isActive; set { if (SetProperty(ref isActive, value)) OnPropertyChanged(nameof(IsNeutral)); } }
    public bool IsNeutral => !isActive;
    public bool IsEnabled { get => isEnabled; set => SetProperty(ref isEnabled, value); }
    /// <summary>The row's thumbnail: the take's or clip's frame, else its caption card (design §5.4).</summary>
    public MediaTile? Media { get => media; set => SetProperty(ref media, value); }
    /// <summary>The Suggested header offers Keep all from two suggestions up.</summary>
    public bool ShowsKeepAll { get => showsKeepAll; set => SetProperty(ref showsKeepAll, value); }
    public bool HasAction => Action.Length > 0;
    public override string ToString() => AccessibleName.Length > 0 ? AccessibleName : Title;
}

/// <summary>Builds the window's sidebar: Home, the open project's section and, on Home, Recent; design §2 and §3.4.</summary>
public sealed class ShellViewModel
{
    public const int RecentLimit = 12;
    private readonly Dictionary<string, SidebarRow> known = new(StringComparer.Ordinal);
    public ObservableCollection<SidebarRow> Rows { get; } = [];
    public SidebarRow Home => Row(SidebarKind.Home, "home");
    /// <summary>The open take's thumbnail for the Full take row; the window sets it as the frame and card arrive.</summary>
    public MediaTile? TakeMedia { get; set; }
    /// <summary>Clip and suggestion thumbnails by clip id, set by the window as frames and cards arrive.</summary>
    public IReadOnlyDictionary<string, MediaTile> ClipMedia { get; set; } = new Dictionary<string, MediaTile>();
    /// <summary>While Find clips runs: the connector line for the "Finding clips…" row; null otherwise.</summary>
    public string? Finding { get; set; }
    /// <summary>The callout under the sidebar actions, or null.</summary>
    public SidebarCallout? Callout { get; set; }
    /// <summary>The last Find clips run found nothing: the prompt file's message, shown under Suggested with Find clips…
    /// (design §13 "Clips: none found"); null otherwise.</summary>
    public string? NoneFound { get; set; }
    /// <summary>The disabled actions' tooltip and help text while the take has no transcript (design §7.1).</summary>
    public const string TranscribeFirst = "Transcribe the video to select words.";

    /// <summary>The row that shows the editor's current scope: the active clip's row, or Full take.</summary>
    public SidebarRow? ScopeRow(string? activeClipId)
    {
        if (activeClipId is not null)
            foreach (var row in Rows)
                if (row.ClipId == activeClipId) return row;
        return Rows.FirstOrDefault(row => row.Kind == SidebarKind.FullTake);
    }

    /// <summary>Rebuild the rows for this window. Existing rows are updated in place; only added or removed rows change the collection.</summary>
    public void Update(EditorViewModel? editor, bool showingHome, IEnumerable<RecentProject> recent, string? openPath)
    {
        var next = new List<SidebarRow>();
        var home = Home;
        home.Title = "Home";
        home.AccessibleName = "Home";
        next.Add(home);
        if (editor is not null)
        {
            next.Add(Row(SidebarKind.Separator, "separator:project"));
            var project = Row(SidebarKind.Project, "project");
            var media = editor.Project.Media.Source;
            project.Title = editor.Title;
            project.Detail = media.AbsolutePath[(media.AbsolutePath.LastIndexOfAny(['\\', '/']) + 1)..];
            project.ToolTip = $"{project.Detail} · {EditorViewModel.Duration(media.DurationSeconds)} source";
            project.AccessibleName = editor.Title;
            next.Add(project);
            var full = Row(SidebarKind.FullTake, "full");
            full.Title = "Full take";
            // "Transcribing · 42%" with Cancel while transcribing; "Not transcribed" without a transcript; else the edited length.
            var transcribing = TakeMedia?.Transcription;
            full.MetaTime = transcribing is null && editor.HasTranscript ? EditorViewModel.Duration(editor.FullTakeDuration) : "";
            full.MetaStatus = transcribing is { } status ? status.Label + status.Percent : editor.HasTranscript ? "" : "Not transcribed";
            full.ShowsCancel = transcribing is not null;
            full.CancelName = $"Cancel transcribing {editor.Title}";
            var state = TakeMedia?.Spoken is { Length: > 0 } spoken ? $", {spoken}" : "";
            full.AccessibleName = editor.HasTranscript ? $"Full take, {Spoken(editor.FullTakeDuration)} after cuts{state}"
                : "Full take" + (state.Length > 0 ? state : ", not transcribed");
            full.Media = TakeMedia;
            next.Add(full);
            var active = editor.State?.ActiveClipId;
            var kept = editor.Clips.Where(clip => !IsSuggestion(clip)).ToArray();
            var suggested = editor.Clips.Where(IsSuggestion).ToArray();
            if (editor.HasTranscript && editor.Clips.Count == 0 && Finding is null)
            {
                var empty = Row(SidebarKind.Empty, "empty");
                empty.Title = "No clips yet. Select words and press Ctrl+K.";
                empty.AccessibleName = empty.Title;
                next.Add(empty);
            }
            var number = 0;
            foreach (var clip in kept.Concat(suggested))
            {
                number++;
                var suggestion = IsSuggestion(clip);
                var row = Row(suggestion ? SidebarKind.Suggestion : SidebarKind.Clip, (suggestion ? "suggested:" : "clip:") + clip.Id, clip.Id);
                row.Title = clip.Title;
                row.Number = number.ToString(System.Globalization.CultureInfo.InvariantCulture);
                row.MetaTime = EditorViewModel.Duration(clip.DurationSeconds);
                row.MetaStatus = suggestion ? " · Suggested" : "";
                row.AccessibleName = suggestion
                    ? $"Suggested clip {number}, {clip.Title}, {Spoken(clip.DurationSeconds)}"
                    : $"Clip {number}, {clip.Title}, {Spoken(clip.DurationSeconds)}";
                row.ToolTip = clip.ToolTip;
                row.IsActive = clip.Id == active;
                row.Media = ClipMedia.GetValueOrDefault(clip.Id);
                if (suggestion && number == kept.Length + 1) next.Add(SuggestedHeader(suggested.Length));
                next.Add(row);
            }
            if (Finding is { } connector)
            {
                if (suggested.Length == 0) next.Add(SuggestedHeader(0));
                var finding = Row(SidebarKind.Finding, "finding");
                finding.Title = "Finding clips…";
                finding.Detail = connector;
                finding.AccessibleName = $"Finding clips, {connector}";
                next.Add(finding);
            }
            else if (NoneFound is { } message)
            {
                if (suggested.Length == 0) next.Add(SuggestedHeader(0));
                var none = Row(SidebarKind.NoneFound, "nonefound");
                none.Title = message;
                none.AccessibleName = message;
                next.Add(none);
            }
            if (!showingHome)
            {
                next.Add(Row(SidebarKind.Separator, "separator:actions"));
                var make = Row(SidebarKind.Action, "action:make");
                make.Title = "New clip from selection";
                make.Detail = "Ctrl+K";
                make.ToolTip = editor.HasTranscript ? "Make a clip from the selected words (Ctrl+K)" : TranscribeFirst;
                make.AccessibleName = "New clip from selection";
                make.IsEnabled = editor.HasTranscript && editor.HasSelection && !editor.Busy && !editor.IsLeaving;
                next.Add(make);
                var find = Row(SidebarKind.Action, "action:find");
                find.Title = "Find clips with AI";
                find.Detail = "Ctrl+Shift+K";
                find.ToolTip = editor.HasTranscript ? "Find clips with AI (Ctrl+Shift+K)" : TranscribeFirst;
                find.AccessibleName = "Find clips with AI";
                find.IsEnabled = editor.HasTranscript && !editor.Busy && !editor.IsLeaving;
                next.Add(find);
                if (Callout is { } callout)
                {
                    var row = Row(SidebarKind.Callout, "callout");
                    row.Title = callout.Title;
                    row.Detail = callout.Message;
                    row.Action = callout.Action;
                    row.AccessibleName = $"{callout.Title} {callout.Message}".Trim();
                    next.Add(row);
                }
            }
        }
        if (showingHome)
        {
            var others = recent.Where(item => openPath is null || !item.Path.Equals(openPath, StringComparison.OrdinalIgnoreCase)).Take(RecentLimit).ToArray();
            if (others.Length > 0)
            {
                next.Add(Row(SidebarKind.Separator, "separator:recent"));
                var header = Row(SidebarKind.RecentHeader, "recent");
                header.Title = "Recent";
                header.AccessibleName = "Recent";
                next.Add(header);
                foreach (var item in others)
                {
                    var row = Row(SidebarKind.Recent, "recent:" + item.Path.ToUpperInvariant(), recent: item);
                    // The row template reads the card's title, meta and missing state directly, so they follow its lazy load.
                    row.Title = item.Title;
                    row.AccessibleName = item.AccessibleName;
                    next.Add(row);
                }
            }
        }
        Reconcile(next);
    }

    /// <summary>"Suggested", or "Suggested (N)" with Keep all from two suggestions up (design §3.4).</summary>
    private SidebarRow SuggestedHeader(int count)
    {
        var header = Row(SidebarKind.SuggestedHeader, "suggested");
        header.Title = count >= 2 ? $"Suggested ({count})" : "Suggested";
        header.AccessibleName = header.Title;
        header.ShowsKeepAll = count >= 2;
        return header;
    }

    /// <summary>Suggestions are AI clips that are not kept (design §2); manual clips are always kept.</summary>
    public static bool IsSuggestion(ClipRow clip) => clip.Clip.Origin == Core.Domain.Editing.ClipOrigin.Ai && !clip.Selected;

    /// <summary>Spoken length for accessible names: "20 seconds", "2 minutes 10 seconds".</summary>
    public static string Spoken(double seconds)
    {
        var total = (long)Math.Round(double.IsFinite(seconds) ? Math.Max(0, seconds) : 0, MidpointRounding.AwayFromZero);
        var minutes = total / 60;
        var rest = total % 60;
        var minutePart = minutes == 1 ? "1 minute" : $"{minutes} minutes";
        var secondPart = rest == 1 ? "1 second" : $"{rest} seconds";
        return minutes == 0 ? secondPart : rest == 0 ? minutePart : minutePart + " " + secondPart;
    }

    private SidebarRow Row(SidebarKind kind, string key, string? clipId = null, RecentProject? recent = null)
    {
        if (known.TryGetValue(key, out var row) && row.Kind == kind && ReferenceEquals(row.Recent, recent)) return row;
        row = new SidebarRow(kind, key) { ClipId = clipId, Recent = recent };
        known[key] = row;
        return row;
    }

    private void Reconcile(List<SidebarRow> next)
    {
        var wanted = next.ToHashSet();
        for (var index = Rows.Count - 1; index >= 0; index--)
            if (!wanted.Contains(Rows[index])) Rows.RemoveAt(index);
        for (var index = 0; index < next.Count; index++)
        {
            if (index < Rows.Count && ReferenceEquals(Rows[index], next[index])) continue;
            var current = Rows.IndexOf(next[index]);
            if (current >= 0) Rows.Move(current, index);
            else Rows.Insert(index, next[index]);
        }
        foreach (var key in known.Keys.Where(key => !wanted.Contains(known[key])).ToArray()) known.Remove(key);
    }
}
