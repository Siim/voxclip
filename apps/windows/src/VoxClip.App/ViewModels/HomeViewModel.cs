using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using VoxClip.App.Services;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
namespace VoxClip.App.ViewModels;

/// <summary>How Home orders the Recent projects grid.</summary>
public enum RecentSort { LastOpened, Name }

/// <summary>The Home AI callout: a bold first sentence, the rest of the line and its one action.</summary>
public sealed record AiCallout(string Title, string Message, string Action);

/// <summary>UI-thread recent-project mirror and the Home grid's search and sort; design §7 (ADR-R29).</summary>
public sealed class HomeViewModel : ObservableObject
{
    /// <summary>Every recent project, newest first; the sidebar's Recent rows read this list.</summary>
    public ObservableCollection<RecentProject> RecentProjects { get; } = [];
    /// <summary>The grid: <see cref="RecentProjects"/> filtered by <see cref="Query"/> and ordered by <see cref="Sort"/>.</summary>
    public ObservableCollection<RecentProject> Shown { get; } = [];
    private string query = "";
    public string Query { get => query; set { if (SetProperty(ref query, value ?? "")) Filter(); } }
    private RecentSort sort;
    public RecentSort Sort { get => sort; set { if (SetProperty(ref sort, value)) { OnPropertyChanged(nameof(SortLabel)); Filter(); } } }
    public string SortLabel => Sort == RecentSort.Name ? "Name" : "Last opened";
    /// <summary>No project yet: Home shows the first-run hero instead of the drop bar and grid.</summary>
    public bool IsFirstRun => RecentProjects.Count == 0;
    public bool HasProjects => RecentProjects.Count > 0;
    /// <summary>"No projects match “{query}”." while a search hides every card.</summary>
    public string NoMatch => HasProjects && Shown.Count == 0 && Query.Trim().Length > 0 ? $"No projects match “{Query.Trim()}”." : "";
    public bool HasNoMatch => NoMatch.Length > 0;

    public HomeViewModel() => RecentProjects.CollectionChanged += (_, _) => Filter();

    /// <summary>Rebuild <see cref="Shown"/> with minimal moves, so focus and the GridView's containers survive typing.</summary>
    public void Filter()
    {
        var needle = Query.Trim();
        IEnumerable<RecentProject> matching = RecentProjects.Where(project => needle.Length == 0 || project.Title.Contains(needle, StringComparison.CurrentCultureIgnoreCase));
        if (Sort == RecentSort.Name) matching = matching.OrderBy(project => project.Title, StringComparer.CurrentCultureIgnoreCase);
        var wanted = matching.ToList();
        for (var index = Shown.Count - 1; index >= 0; index--)
            if (!wanted.Contains(Shown[index])) Shown.RemoveAt(index);
        for (var index = 0; index < wanted.Count; index++)
        {
            var current = Shown.IndexOf(wanted[index]);
            if (current < 0) Shown.Insert(index, wanted[index]);
            else if (current != index) Shown.Move(current, index);
        }
        OnPropertyChanged(nameof(IsFirstRun));
        OnPropertyChanged(nameof(HasProjects));
        OnPropertyChanged(nameof(NoMatch));
        OnPropertyChanged(nameof(HasNoMatch));
    }

    /// <summary>The settings Home's AI callout reads: the chosen connector and its base URL, CLI path and consent, as
    /// <paramref name="raw"/> gives them. A settings change that leaves these alone doesn't look at the connector again.</summary>
    public static string ConnectorSettings(string connector, Func<string, string?> raw) =>
        string.Join('\n', new[] { "llm.connector", "llm.baseUrl." + connector, "llm.cliPath." + connector, "llm.cloudConsent." + connector }.Select(key => key + "=" + raw(key)));

    /// <summary>Whether Home looks at the connector again as it is shown: when a check is owed (its settings changed, or the
    /// last check was cancelled) or a minute after the last one, and never while one is running.</summary>
    public static bool ConnectorCheckDue(bool owed, bool running, DateTime checkedAt, DateTime now) =>
        !running && (owed || now - checkedAt > TimeSpan.FromMinutes(1));

    /// <summary>The AI callout for the chosen connector (delta §7); null when Find clips with AI can run. The label is the
    /// connector's name in copy (<see cref="ClipCallouts.ConnectorName"/>).</summary>
    public static AiCallout? Callout(string? connectorLabel, string? group, ConnectorStatus? status)
    {
        const string byHand = "You can still make clips by hand.";
        if (string.IsNullOrEmpty(connectorLabel)) return new("Find clips with AI isn't set up yet.", byHand, "Set up AI…");
        return status switch
        {
            ConnectorStatus.Ready or null => null,
            ConnectorStatus.CliSignedOut => new($"{connectorLabel} isn't signed in, so Find clips with AI can't run.", byHand, "Sign-in help"),
            ConnectorStatus.NeedsKey => new($"Add your {connectorLabel} key to use Find clips with AI.", byHand, "Set up AI…"),
            ConnectorStatus.NotRunning when group == "local" => new($"{connectorLabel} isn't running, so Find clips with AI can't run.", "", "Check again"),
            _ => new("Find clips with AI isn't set up yet.", byHand, "Set up AI…")
        };
    }
}

/// <summary>One recent project: the Home tile and the sidebar's Recent row; design §7 and §5.4.</summary>
public sealed class RecentProject(string path, string name) : ObservableObject
{
    public string Path { get; } = path;
    /// <summary>The file name without its extension, shown until the project's own title loads.</summary>
    public string Name { get; } = name;
    /// <summary>The GridView and NavigationView items read their accessible name from here.</summary>
    public override string ToString() => AccessibleName;
    private string title = name;
    public string Title { get => title; private set { if (SetProperty(ref title, value)) Changed(); } }
    private bool loaded;
    private bool stalled;
    private bool unavailable;
    private bool missing;
    private bool unreadable;
    private bool audioOnly;
    private double durationSeconds;
    private DateTimeOffset modifiedAt;
    private DateTimeOffset now = DateTimeOffset.Now;
    private int clipCount;
    private CaptionCard? card;
    private bool isOpen;
    public bool IsOpen { get => isOpen; set { if (SetProperty(ref isOpen, value)) Changed(); } }
    /// <summary>The project file was still unread 300 ms after Home asked for it: the tile sweeps its sheen and the meta
    /// reads "Loading…" (design §5.4.5). Before that the tile holds stage black with no text.</summary>
    public bool IsStalled { get => stalled; set { if (SetProperty(ref stalled, value)) Changed(); } }
    public bool IsLoaded => loaded;
    private TranscriptionStatus? transcription;
    /// <summary>The transcription any window runs for this project; null otherwise.</summary>
    public TranscriptionStatus? Transcription { get => transcription; set { if (SetProperty(ref transcription, value)) Changed(); } }
    public bool Transcribing => Transcription is not null;
    private string? framePath;
    /// <summary>The cached poster frame; null until it is made, or when every candidate frame is black.</summary>
    public string? FramePath { get => framePath; set { if (SetProperty(ref framePath, value)) Changed(); } }
    /// <summary>The video is there but VoxClip's decoder can't read it (design §5.4.4 f).</summary>
    public bool Unreadable { get => unreadable; set { if (SetProperty(ref unreadable, value)) Changed(); } }
    public bool Missing => missing;
    public int ClipCount => clipCount;
    public string Duration => loaded ? EditorViewModel.Duration(durationSeconds) : "";

    /// <summary>The tile's Core media state (design §5.4.4), checked in order: unread, missing, unreadable, transcribing,
    /// then audio only.</summary>
    public MediaStatus Status => !loaded ? (stalled && !unavailable ? new MediaStatus.Loading() : new MediaStatus.None())
        : missing ? new MediaStatus.Missing() : unreadable ? new MediaStatus.Unreadable() : Transcription is { } running ? running.Status
        : audioOnly ? new MediaStatus.AudioOnly() : new MediaStatus.None();
    /// <summary>The Home tile and sidebar thumbnail; Core picks the frame, the caption card or stage black.</summary>
    public MediaTile Media => new(Path, FramePath, card, Status);

    /// <summary>Tile meta: "{duration} · {date} · {n} clips", with "Open now" and "No clips yet"; "Transcribing on this PC"
    /// beside Cancel; "Loading…" once the read stalls.</summary>
    public string Meta => unavailable ? "Project unavailable · Show in Explorer or remove from list" : !loaded ? (stalled ? "Loading…" : "")
        : Transcribing ? "Transcribing on this PC"
        : $"{Duration} · {(IsOpen ? "Open now" : When(modifiedAt, now))} · {(clipCount == 0 ? "No clips yet" : $"{clipCount} {(clipCount == 1 ? "clip" : "clips")}")}";
    /// <summary>The warning that replaces the meta beside Open: "⚠ Video not found." or "⚠ Can't read video."</summary>
    public string Warning => !loaded ? "" : missing ? "⚠ Video not found." : unreadable ? "⚠ Can't read video." : "";
    public bool ShowsWarning => Warning.Length > 0;
    public bool ShowsMeta => !ShowsWarning;
    /// <summary>Cancel sits on the meta line while this project transcribes (design §7 amendment).</summary>
    public bool ShowsCancel => loaded && Transcribing && !ShowsWarning;
    /// <summary>Sidebar Recent row's second line: "{duration} · {date}", the transcription stage, or a warning.</summary>
    public string Detail => unavailable ? "Project unavailable" : !loaded ? (stalled ? "Loading…" : "")
        : missing ? "⚠ Video not found" : unreadable ? "⚠ Can't read video"
        : Transcription is { } status ? status.Label + status.Percent
        : $"{Duration} · {When(modifiedAt, now)}";
    /// <summary><see cref="Detail"/> in the two runs the sidebar draws (design §3.4): the m:ss duration in Cascadia Mono, then
    /// " · {date}" in the UI font; the other states are all status.</summary>
    public string DetailTime => loaded && !missing && !unreadable && Transcription is null ? Duration : "";
    public string DetailStatus => DetailTime.Length > 0 ? Detail[DetailTime.Length..] : Detail;
    /// <summary>The sidebar draws <see cref="Detail"/> in the warning colour.</summary>
    public bool DetailIsWarning => loaded && (missing || unreadable);
    public bool DetailIsPlain => !DetailIsWarning;
    /// <summary>The Open link beside a missing or unreadable video. Design §7 calls it Locate…, but Windows has no relink flow
    /// yet, so it says what it does: open the project, whose editor names the file it can't find.</summary>
    public string OpenName => $"Open {Title}";
    public string CancelName => $"Cancel transcribing {Title}";
    /// <summary>"{title}, {state}" (design §5.4.9), with no "·".</summary>
    public string AccessibleName => unavailable ? $"{Title}, project unavailable" : Media.Name(Title);
    /// <summary>The tile's description: "{duration}, {n} clips, opened {date}".</summary>
    public string Description => !loaded ? "" : $"{Duration}, {clipCount} {(clipCount == 1 ? "clip" : "clips")}, opened {When(modifiedAt, now)}";

    /// <summary>Fill the tile from a project read off the UI thread. Kept clips are manual clips plus selected AI clips.</summary>
    public void Load(Project project, bool missingVideo, DateTimeOffset today, CaptionCard? captionCard = null)
    {
        loaded = true; unavailable = false; stalled = false; unreadable = false;
        durationSeconds = project.Media.Source.DurationSeconds;
        modifiedAt = project.ModifiedAt;
        now = today;
        clipCount = project.Edits.Clips.Count(clip => clip.Origin != ClipOrigin.Ai || clip.Selected);
        missing = missingVideo;
        audioOnly = project.Media.Source.Video is null;
        card = captionCard;
        title = string.IsNullOrWhiteSpace(project.Title) ? Name : project.Title.Trim();
        OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(IsLoaded));
        OnPropertyChanged(nameof(Unreadable));
        Changed();
    }

    /// <summary>The project file can't be read: keep the row so the user can show it in Explorer or remove it.</summary>
    public void Fail() { unavailable = true; loaded = false; stalled = false; Changed(); }

    /// <summary>"Today", "Yesterday", the weekday within a week, then "Oct 19", or "Oct 19, 2025" in another year.</summary>
    public static string When(DateTimeOffset modified, DateTimeOffset now)
    {
        var day = modified.ToLocalTime().Date;
        var days = (now.ToLocalTime().Date - day).TotalDays;
        return days switch
        {
            <= 0 => "Today",
            1 => "Yesterday",
            < 7 => day.ToString("ddd", CultureInfo.InvariantCulture),
            _ => day.Year == now.ToLocalTime().Year ? day.ToString("MMM d", CultureInfo.InvariantCulture) : day.ToString("MMM d, yyyy", CultureInfo.InvariantCulture)
        };
    }

    private void Changed()
    {
        foreach (var name in new[] { nameof(Meta), nameof(Detail), nameof(DetailTime), nameof(DetailStatus), nameof(Duration), nameof(ClipCount), nameof(Transcribing), nameof(Status), nameof(Media),
            nameof(Warning), nameof(ShowsWarning), nameof(ShowsMeta), nameof(ShowsCancel), nameof(DetailIsWarning), nameof(DetailIsPlain),
            nameof(OpenName), nameof(CancelName), nameof(AccessibleName), nameof(Description) }) OnPropertyChanged(name);
    }
}
