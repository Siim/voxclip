using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;

namespace VoxClip.App.ViewModels;

public enum SidebarKind { Home, Separator, Project, FullTake, Clip, SuggestedHeader, Suggestion, Action, RecentHeader, Recent }

/// <summary>One NavigationView row. Rows keep their instance by <see cref="Key"/> across rebuilds so selection and focus survive; design §3.4.</summary>
public sealed class SidebarRow(SidebarKind kind, string key) : ObservableObject
{
    private string title = "";
    private string detail = "";
    private string meta = "";
    private string number = "";
    private string accessibleName = "";
    private string toolTip = "";
    private bool isActive;
    private bool isEnabled = true;
    public SidebarKind Kind { get; } = kind;
    public string Key { get; } = key;
    /// <summary>The clip id of a clip or suggestion row.</summary>
    public string? ClipId { get; init; }
    /// <summary>The recent project shown by a Recent row.</summary>
    public RecentProject? Recent { get; init; }
    public string Title { get => title; set => SetProperty(ref title, value); }
    /// <summary>Second header line: the project's file name, or an action's shortcut.</summary>
    public string Detail { get => detail; set => SetProperty(ref detail, value); }
    public string Meta { get => meta; set => SetProperty(ref meta, value); }
    /// <summary>Display number of a clip or suggestion; never stored (design §2).</summary>
    public string Number { get => number; set => SetProperty(ref number, value); }
    public string AccessibleName { get => accessibleName; set => SetProperty(ref accessibleName, value); }
    public string ToolTip { get => toolTip; set => SetProperty(ref toolTip, value); }
    /// <summary>The row's clip is the active clip: its badge takes the accent fill.</summary>
    public bool IsActive { get => isActive; set { if (SetProperty(ref isActive, value)) OnPropertyChanged(nameof(IsNeutral)); } }
    public bool IsNeutral => !isActive;
    public bool IsEnabled { get => isEnabled; set => SetProperty(ref isEnabled, value); }
    public override string ToString() => AccessibleName.Length > 0 ? AccessibleName : Title;
}

/// <summary>Builds the window's sidebar: Home, the open project's section and, on Home, Recent; design §2 and §3.4.</summary>
public sealed class ShellViewModel
{
    public const int RecentLimit = 12;
    private readonly Dictionary<string, SidebarRow> known = new(StringComparer.Ordinal);
    public ObservableCollection<SidebarRow> Rows { get; } = [];
    public SidebarRow Home => Row(SidebarKind.Home, "home");

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
            full.Meta = EditorViewModel.Duration(editor.FullTakeDuration);
            full.AccessibleName = $"Full take, {Spoken(editor.FullTakeDuration)} after cuts";
            next.Add(full);
            var active = editor.State?.ActiveClipId;
            var kept = editor.Clips.Where(clip => !IsSuggestion(clip)).ToArray();
            var suggested = editor.Clips.Where(IsSuggestion).ToArray();
            var number = 0;
            foreach (var clip in kept.Concat(suggested))
            {
                number++;
                var suggestion = IsSuggestion(clip);
                var row = Row(suggestion ? SidebarKind.Suggestion : SidebarKind.Clip, (suggestion ? "suggested:" : "clip:") + clip.Id, clip.Id);
                row.Title = clip.Title;
                row.Number = number.ToString(System.Globalization.CultureInfo.InvariantCulture);
                row.Meta = EditorViewModel.Duration(clip.DurationSeconds) + (suggestion ? " · Suggested" : "");
                row.AccessibleName = suggestion
                    ? $"Suggested clip {number}, {clip.Title}, {Spoken(clip.DurationSeconds)}"
                    : $"Clip {number}, {clip.Title}, {Spoken(clip.DurationSeconds)}";
                row.ToolTip = clip.Reason;
                row.IsActive = clip.Id == active;
                if (suggestion && number == kept.Length + 1)
                {
                    var header = Row(SidebarKind.SuggestedHeader, "suggested");
                    header.Title = suggested.Length >= 2 ? $"Suggested ({suggested.Length})" : "Suggested";
                    header.AccessibleName = header.Title;
                    header.IsEnabled = suggested.Length >= 2;
                    next.Add(header);
                }
                next.Add(row);
            }
            if (!showingHome)
            {
                next.Add(Row(SidebarKind.Separator, "separator:actions"));
                var make = Row(SidebarKind.Action, "action:make");
                make.Title = "New clip from selection";
                make.Detail = "Ctrl+K";
                make.ToolTip = "Make a clip from the selected words (Ctrl+K)";
                make.AccessibleName = "New clip from selection";
                make.IsEnabled = editor.HasTranscript && editor.HasSelection && !editor.Busy && !editor.IsLeaving;
                next.Add(make);
                var find = Row(SidebarKind.Action, "action:find");
                find.Title = "Find clips with AI";
                find.Detail = "Ctrl+Shift+K";
                find.ToolTip = "Find clips with AI (Ctrl+Shift+K)";
                find.AccessibleName = "Find clips with AI";
                find.IsEnabled = editor.HasTranscript && !editor.Busy && !editor.IsLeaving;
                next.Add(find);
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
                    row.Title = item.Name;
                    row.AccessibleName = item.Name;
                    next.Add(row);
                }
            }
        }
        Reconcile(next);
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
