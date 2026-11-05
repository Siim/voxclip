using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Music;

namespace VoxClip.App.ViewModels;

/// <summary>Plays one candidate in the Music section; stopping it never touches the editor's preview.</summary>
public interface IMusicAudition
{
    /// <summary>Plays a local file or an https stream; the editor's preview pauses first.</summary>
    void Play(string source);
    /// <summary>Stops what plays.</summary>
    void Stop();
}

/// <summary>What the Music section asks of the outside world; tests pass stubs, the page builds them from its own services.</summary>
/// <param name="Suggest">Claude's best three for a brief under a clip of the given rendered length.</param>
/// <param name="Fetch">The bytes behind a library candidate (downloaded) or a generated one (composed, paid; its button is the approval).</param>
/// <param name="Folder">The user's Music folder, or null.</param>
/// <param name="Duration">A stored file's length in seconds.</param>
/// <param name="DataRoot">The data folder whose Music folder holds used tracks.</param>
public sealed record MusicPanelServices(
    Func<MusicBrief, double, CancellationToken, Task<MusicSuggestionResult>> Suggest,
    Func<MusicCandidate, CancellationToken, Task<byte[]>> Fetch,
    Func<string?> Folder,
    Func<string, CancellationToken, Task<double>> Duration,
    string DataRoot);

/// <summary>What the Music section is doing.</summary>
public enum MusicPanelPhase { Idle, Searching, Using, Failed }

/// <summary>The Music section's state (doc/spec/music.md §6, the twin of Mac MusicPanel): Claude's best three, the user's folder, search,
/// the track in use and the one candidate playing. Every change to the project goes through the editor's undoable replace.</summary>
public sealed class MusicPanelModel(EditorViewModel editor)
{
    private CancellationTokenSource? work;
    private Task current = Task.CompletedTask;
    private string? loadedFolder;

    /// <summary>The page's sources; null shows the section without sources ("Search for music, or add a file of your own.").</summary>
    public MusicPanelServices? Services { get; set; }
    /// <summary>The audition player.</summary>
    public IMusicAudition? Audition { get; set; }
    /// <summary>Claude's (or the search's) candidates.</summary>
    public IReadOnlyList<MusicCandidate> Candidates { get; private set; } = [];
    /// <summary>Why a source has nothing to offer.</summary>
    public IReadOnlyList<string> Notes { get; private set; } = [];
    /// <summary>The Music folder's files.</summary>
    public IReadOnlyList<MusicCandidate> FolderFiles { get; private set; } = [];
    /// <summary>What runs.</summary>
    public MusicPanelPhase Phase { get; private set; }
    /// <summary>The candidate a Use is making or storing.</summary>
    public string? UsingId { get; private set; }
    /// <summary>The inline failure ("… Nothing was changed. Try another track, or try this one again.").</summary>
    public string? Failure { get; private set; }
    /// <summary>The candidate playing.</summary>
    public string? Playing { get; private set; }
    /// <summary>The last brief.</summary>
    public MusicBrief? Brief { get; private set; }
    /// <summary>The search field's text.</summary>
    public string Query { get; set; } = "";
    /// <summary>Raised whenever anything the section shows changes.</summary>
    public event EventHandler? Changed;

    /// <summary>The track under the open clip, or under the full video in Full take.</summary>
    public ProjectMusic? Current => MusicProject.Entry(editor.Project.Edits.ActiveClipId, editor.Project);

    /// <summary>The rendered length of the open scope: the clip's edited length divided by its speed, or the full take.</summary>
    public double ScopeSeconds => editor.Project.Edits.ActiveClipId is { } clip ? editor.MakeItRenderedSeconds(clip) : editor.FullTakeDuration;

    /// <summary>Lists the folder's files once per folder, so the section never opens empty.</summary>
    public void LoadFolder()
    {
        var folder = Services?.Folder();
        if (folder == loadedFolder && FolderFiles.Count > 0) return;
        loadedFolder = folder;
        FolderFiles = MusicLibraryFolder.Files(folder);
        Notify();
    }

    /// <summary>Claude's (or the plan's) suggestion: fetches the best three across sources.</summary>
    public Task SuggestAsync(MusicBrief brief)
    {
        if (Services is not { } services) return Task.CompletedTask;
        Brief = brief;
        Phase = MusicPanelPhase.Searching;
        Failure = null;
        Notify();
        var token = Restart();
        var seconds = ScopeSeconds;
        return current = Run(async () =>
        {
            var result = await services.Suggest(brief, seconds, token);
            if (token.IsCancellationRequested) return;
            Candidates = result.Candidates;
            Notes = new[] { MusicSource.Library, MusicSource.Generated, MusicSource.File }.Select(source => result.Notes.GetValueOrDefault(source)).OfType<string>().ToArray();
            if (Phase == MusicPanelPhase.Searching) Phase = MusicPanelPhase.Idle;
        });
    }

    /// <summary>The search field: its words become both the library query and the generation mood.</summary>
    public Task SearchAsync()
    {
        var text = Query.Trim();
        return text.Length == 0 ? Task.CompletedTask : SuggestAsync(new(text, text));
    }

    /// <summary>▶ stops the editor's playback and any other candidate; a second click stops this one.</summary>
    public void ToggleAudition(MusicCandidate candidate)
    {
        if (Playing == candidate.Id) { StopAudition(); return; }
        if (AuditionSource(candidate) is not { } source || Audition is not { } audition) return;
        audition.Play(source);
        Playing = candidate.Id;
        Notify();
    }

    /// <summary>Stops the audition.</summary>
    public void StopAudition()
    {
        if (Playing is null) return;
        Audition?.Stop();
        Playing = null;
        Notify();
    }

    /// <summary>Where ▶ plays from: the stored track when it is the one in use, else the candidate's own file or stream.</summary>
    public string? AuditionSource(MusicCandidate candidate)
    {
        if (Current is { } entry && candidate.Id == UsingRowId(entry) && Services is { } services) return MusicRenderInput.PathFor(entry.Asset, services.DataRoot);
        return candidate.NeedsGeneration ? null : candidate.Audio;
    }

    /// <summary>Use: stores the track in the project's music folder and sets it under the open clip (or the full video) as one undo
    /// step. A generated candidate is made first; its priced button is the approval and a failure is never retried.</summary>
    public Task UseAsync(MusicCandidate candidate, double? gainDb = null)
    {
        if (editor.IsReadOnly || Services is not { } services || (Phase == MusicPanelPhase.Using && UsingId == candidate.Id)) return Task.CompletedTask;
        StopAudition();
        Phase = MusicPanelPhase.Using; UsingId = candidate.Id; Failure = null;
        Notify();
        var token = Restart();
        var projectId = editor.Project.Id;
        var clipId = editor.Project.Edits.ActiveClipId;
        return current = Run(async () =>
        {
            var data = candidate.Source == MusicSource.File && candidate.Audio is { } path
                ? await File.ReadAllBytesAsync(path, token) : await services.Fetch(candidate, token);
            var stored = MusicAssetStore.Store(data, candidate.Title, candidate.FileExtension, projectId, services.DataRoot);
            var seconds = await services.Duration(stored.Path, token);
            var entry = MusicAssetStore.Entry(candidate, stored, seconds, clipId);
            if (gainDb is { } gain) entry = entry with { GainDb = Math.Round(Math.Clamp(gain, -40, 0) * 2) / 2 };
            token.ThrowIfCancellationRequested();
            editor.SetMusic(entry, clipId, "Add music");
            Phase = MusicPanelPhase.Idle; UsingId = null;
        });
    }

    /// <summary>Remove: the open scope plays without music again, as one undo step.</summary>
    public void Remove()
    {
        if (editor.IsReadOnly || Current is null) return;
        StopAudition();
        editor.SetMusic(null, editor.Project.Edits.ActiveClipId, "Remove music");
        Notify();
    }

    /// <summary>The one volume control: the bed's level under the voice, −40 to 0 dB in half-dB steps (−20 by default).</summary>
    public void SetGain(double gainDb)
    {
        if (editor.IsReadOnly || Current is not { } entry) return;
        var rounded = Math.Round(Math.Clamp(gainDb, -40, 0) * 2) / 2;
        if (rounded == entry.GainDb) return;
        editor.SetMusic(entry with { GainDb = rounded }, entry.ClipId, "Change music volume");
        Notify();
    }

    /// <summary>Dismisses the inline failure.</summary>
    public void DismissFailure()
    {
        if (Phase != MusicPanelPhase.Failed) return;
        Phase = MusicPanelPhase.Idle; Failure = null;
        Notify();
    }

    /// <summary>Waits for the current search or Use (the one-click run and tests wait on it).</summary>
    public Task SettledAsync() => current;

    /// <summary>The candidate id a stored entry answers to, so its row shows "Using".</summary>
    public static string UsingRowId(ProjectMusic entry) => "using-" + entry.Id;

    /// <summary>The rows: the track in use first, then the suggestions, else the folder's first three files.</summary>
    public IReadOnlyList<MusicCandidate> Rows
    {
        get
        {
            var rows = new List<MusicCandidate>();
            var entry = Current;
            if (entry is not null)
                rows.Add(new(UsingRowId(entry), entry.Source, entry.Title, entry.License, Path.GetExtension(entry.Asset.File).TrimStart('.'))
                {
                    Creator = entry.Creator, Attribution = entry.Attribution, SourceUrl = entry.SourceUrl, Prompt = entry.Prompt, DurationSeconds = entry.Asset.DurationSeconds
                });
            var suggestions = Candidates.Count == 0 ? FolderFiles.Take(3) : Candidates;
            rows.AddRange(suggestions.Where(candidate => entry is null || candidate.Title != entry.Title || candidate.Source != entry.Source));
            return rows;
        }
    }

    /// <summary>The source badge: CC BY, CC0, PD, Eleven or Yours.</summary>
    public static string Badge(MusicCandidate candidate) => candidate.License switch
    {
        MusicLicense.By => "CC BY", MusicLicense.Cc0 => "CC0", MusicLicense.Pdm => "PD", MusicLicense.Generated => "Eleven", _ => "Yours"
    };

    /// <summary>The row's second line: the creator, reason and length.</summary>
    public static string Detail(MusicCandidate candidate) => string.Join(" · ", new[]
    {
        candidate.Creator, candidate.Reason,
        candidate.DurationSeconds is { } seconds ? TimeSpan.FromSeconds(Math.Round(seconds)).ToString(seconds >= 3600 ? @"h\:mm\:ss" : @"m\:ss", System.Globalization.CultureInfo.InvariantCulture) : null
    }.OfType<string>().Where(text => text.Length > 0));

    /// <summary>A generation not yet made: "Make · $0.11", or null.</summary>
    public static string? MakeLabel(MusicCandidate candidate) =>
        candidate.NeedsGeneration && candidate.Estimate is { } estimate && MusicPricing.Label(estimate) is { } price ? "Make · " + price : null;

    /// <summary>What a generation sends, beside its priced button.</summary>
    public static string? SendsLine(MusicCandidate candidate) => candidate.NeedsGeneration
        ? $"Sends this prompt to ElevenLabs for a {Math.Round(candidate.DurationSeconds ?? 0)} s instrumental: {candidate.Prompt}" : null;

    /// <summary>The footer always names the next step.</summary>
    public string Footer => Phase switch
    {
        MusicPanelPhase.Searching => "Finding music…",
        MusicPanelPhase.Using => "Getting the track ready…",
        MusicPanelPhase.Failed => "Nothing was changed. Try another track, or try this one again.",
        _ when Current is not null => "It dips while you talk and fades out at the end. Next: Export. The credit goes in the post text.",
        _ when Rows.Count > 0 => "Next: ▶ to listen, then Use.",
        _ => "Next: search, or add a file."
    };

    /// <summary>With neither suggestions nor files.</summary>
    public string? EmptyText => Rows.Count == 0 && Phase != MusicPanelPhase.Searching ? "Search for music, or add a file of your own." : null;

    private CancellationToken Restart()
    {
        work?.Cancel();
        work = new();
        return work.Token;
    }

    private async Task Run(Func<Task> body)
    {
        try { await body(); }
        catch (OperationCanceledException) { if (Phase != MusicPanelPhase.Searching) { Phase = MusicPanelPhase.Idle; UsingId = null; } }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Phase = MusicPanelPhase.Failed; UsingId = null;
            var message = UiError.Message(exception, "Music");
            Failure = (message.Length == 0 ? "That didn't work." : message.TrimEnd('.') + ".") + " Nothing was changed.";
        }
        Notify();
    }

    private void Notify() => Changed?.Invoke(this, EventArgs.Empty);
}
