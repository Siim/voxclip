#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Music;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The Music section on Windows (doc/spec/music.md §6) and Make it postable's "Picking music…" step (design §6.7 step 4), the
/// twin of the Mac's MusicPanelTests and its music smoke rows. Sources are stubs: nothing is downloaded, composed or paid.</summary>
public sealed class MusicPanelTests : IDisposable
{
    private readonly string data = Directory.CreateTempSubdirectory("voxclip-music-panel-").FullName;
    private readonly string folder;

    public MusicPanelTests()
    {
        folder = Directory.CreateDirectory(Path.Combine(data, "My music")).FullName;
    }

    public void Dispose() => Directory.Delete(data, true);

    private sealed class Audition : IMusicAudition
    {
        internal List<string> Played { get; } = [];
        internal int Stops { get; private set; }
        public void Play(string source) => Played.Add(source);
        public void Stop() => Stops++;
    }

    private sealed class Sources
    {
        internal List<MusicBrief> Briefs { get; } = [];
        internal List<MusicCandidate> Fetched { get; } = [];
        internal Func<MusicBrief, MusicSuggestionResult> Result { get; set; } = _ => MusicSuggestionResult.Empty;
        internal Func<MusicCandidate, byte[]> Bytes { get; set; } = _ => [1, 2, 3, 4];
    }

    private static readonly MusicCandidate Library = new("openverse-5", MusicSource.Library, "Calm piano", MusicLicense.By, "mp3")
    { Creator = "Someone", Attribution = "“Calm piano” by Someone, CC BY 4.0", SourceUrl = "https://www.jamendo.com/track/5", Audio = "https://cdn.example/5.mp3", DurationSeconds = 95, Reason = "calm" };

    private static MusicCandidate Generated(decimal usd) => new("eleven-1", MusicSource.Generated, "Calm", MusicLicense.Generated, "mp3")
    {
        Prompt = "Instrumental calm piano", DurationSeconds = 42, Reason = "Made to the clip's length",
        Estimate = new("elevenlabs", "musicCompose", 42, "second", usd, null, "catalog")
    };

    private (EditorViewModel Editor, Sources Sources, Audition Audition) Open(string? withFolder = "", bool suggested = false)
    {
        var editor = MakeItPostableTests.Editor(suggested, score: suggested ? 9 : null);
        var sources = new Sources();
        var audition = new Audition();
        editor.Music.Services = new MusicPanelServices(
            (brief, _, _) => { sources.Briefs.Add(brief); return Task.FromResult(sources.Result(brief)); },
            (candidate, _) => { sources.Fetched.Add(candidate); return Task.FromResult(sources.Bytes(candidate)); },
            () => withFolder == "" ? folder : withFolder,
            (_, _) => Task.FromResult(95.0),
            data);
        editor.Music.Audition = audition;
        Assert.True(editor.SetScope("c1"));
        return (editor, sources, audition);
    }

    [Fact]
    public async Task TheSectionNeverOpensEmptyAndItsFooterNamesTheNextStep()
    {
        var (bare, _, _) = Open(withFolder: null);
        bare.Music.LoadFolder();
        Assert.Empty(bare.Music.Rows);
        Assert.Equal(("Search for music, or add a file of your own.", "Next: search, or add a file."), (bare.Music.EmptyText, bare.Music.Footer));
        foreach (var name in new[] { "Upbeat.wav", "Calm morning.mp3", "Drums.m4a", "Late.aiff", "readme.txt" }) File.WriteAllBytes(Path.Combine(folder, name), [1]);
        var (editor, sources, _) = Open();
        editor.Music.LoadFolder();
        Assert.Equal(["Calm morning", "Drums", "Late"], editor.Music.Rows.Select(row => row.Title));
        Assert.Equal(("Yours", "Next: ▶ to listen, then Use."), (MusicPanelModel.Badge(editor.Music.Rows[0]), editor.Music.Footer));
        // Claude's three replace the folder rows; a source's note shows beside them.
        sources.Result = _ => new([Library, Generated(0.105m)], new Dictionary<MusicSource, string> { [MusicSource.File] = "x" });
        await editor.Music.SuggestAsync(new("calm", "calm piano"));
        Assert.Equal(["Calm piano", "Calm"], editor.Music.Rows.Select(row => row.Title));
        Assert.Equal(["CC BY", "Eleven"], editor.Music.Rows.Select(MusicPanelModel.Badge));
        Assert.Equal(("Make · $0.11", "Sends this prompt to ElevenLabs for a 42 s instrumental: Instrumental calm piano"),
            (MusicPanelModel.MakeLabel(editor.Music.Rows[1]), MusicPanelModel.SendsLine(editor.Music.Rows[1])));
        Assert.Null(MusicPanelModel.MakeLabel(Library));
        Assert.Equal("Someone · calm · 1:35", MusicPanelModel.Detail(Library));
        Assert.Equal(["x"], editor.Music.Notes);
        // The search field's words are both the query and the mood.
        editor.Music.Query = " lofi beats ";
        await editor.Music.SearchAsync();
        Assert.Equal(new MusicBrief("lofi beats", "lofi beats"), sources.Briefs[^1]);
    }

    [Fact]
    public async Task PlayStopsOthersAndAGenerationNotYetMadeHasNothingToPlay()
    {
        var (editor, sources, audition) = Open();
        sources.Result = _ => new([Library, Generated(0.105m)], new Dictionary<MusicSource, string>());
        await editor.Music.SuggestAsync(new("calm"));
        editor.Music.ToggleAudition(Library);
        Assert.Equal(["https://cdn.example/5.mp3"], audition.Played);
        Assert.Equal("openverse-5", editor.Music.Playing);
        editor.Music.ToggleAudition(Library);
        Assert.Equal((1, (string?)null), (audition.Stops, editor.Music.Playing));
        editor.Music.ToggleAudition(Generated(0.1m));
        Assert.Single(audition.Played);
        Assert.Null(editor.Music.Playing);
    }

    [Fact]
    public async Task UseStoresTheTrackUnderTheClipAsOneStepWithItsCreditAndVolumeAndRemoveUndo()
    {
        var (editor, sources, audition) = Open();
        sources.Result = _ => new([Library], new Dictionary<MusicSource, string>());
        await editor.Music.SuggestAsync(new("calm"));
        editor.Music.ToggleAudition(Library);
        await editor.Music.UseAsync(Library);
        Assert.Equal([Library], sources.Fetched);
        Assert.Equal(1, audition.Stops);
        var entry = Assert.Single(editor.Project.Music);
        Assert.Equal(("c1", MusicSource.Library, -20.0, true, 95.0), (entry.ClipId, entry.Source, entry.GainDb, entry.Ducking, entry.Asset.DurationSeconds));
        Assert.True(File.Exists(MusicRenderInput.PathFor(entry.Asset, data)));
        Assert.Equal(4, editor.Project.SchemaVersion);
        ProjectSerialization.Validate(editor.Project);
        Assert.Equal("Add music", editor.UndoActionName);
        Assert.Equal(("Using", "It dips while you talk and fades out at the end. Next: Export. The credit goes in the post text."),
            (editor.Music.Rows[0].Id == MusicPanelModel.UsingRowId(entry) ? "Using" : "", editor.Music.Footer));
        // The suggestion that made it is not listed twice.
        Assert.Single(editor.Music.Rows);
        // ▶ on the track in use plays the stored file.
        Assert.Equal(MusicRenderInput.PathFor(entry.Asset, data), editor.Music.AuditionSource(editor.Music.Rows[0]));
        Assert.Equal("Sleep first.\n\nMusic: “Calm piano” by Someone, CC BY 4.0", MusicCredits.PostText("Sleep first.", editor.Music.Current));
        editor.Music.SetGain(-12.3);
        Assert.Equal((-12.5, "Change music volume"), (editor.Music.Current!.GainDb, editor.UndoActionName));
        editor.Music.SetGain(-80);
        Assert.Equal(-40, editor.Music.Current!.GainDb);
        editor.Music.Remove();
        Assert.Empty(editor.Project.Music);
        editor.Undo(); editor.Undo(); editor.Undo();
        Assert.Equal(-20, editor.Music.Current!.GainDb);
        editor.Undo();
        Assert.Empty(editor.Project.Music);
        // The full video has its own track.
        Assert.True(editor.SetScope(null));
        Assert.Null(editor.Music.Current);
    }

    [Fact]
    public async Task AFailureShowsInlineOnceAndChangesNothing()
    {
        var (editor, sources, _) = Open();
        sources.Bytes = _ => throw new VoxClipException(VoxClipErrorCode.ProviderError, "The track's host replied 404.");
        await editor.Music.UseAsync(Library);
        Assert.Single(sources.Fetched);
        Assert.Empty(editor.Project.Music);
        Assert.Equal(MusicPanelPhase.Failed, editor.Music.Phase);
        Assert.EndsWith("Nothing was changed.", editor.Music.Failure);
        Assert.Equal("Nothing was changed. Try another track, or try this one again.", editor.Music.Footer);
        Assert.False(editor.CanUndo);
        editor.Music.DismissFailure();
        Assert.Equal(MusicPanelPhase.Idle, editor.Music.Phase);
    }

    [Fact]
    public async Task MakeItPicksAFreeTrackUnderTheVoiceWithUndoAndChange()
    {
        var (editor, sources, _) = Open();
        sources.Result = _ => new([Generated(0.105m), Library], new Dictionary<MusicSource, string>());
        var stub = new MakeItPostableTests.Stub();
        var run = await MakeItPostableTests.RunAsync(editor, stub);
        Assert.Contains("Picking music…", run.Lines);
        Assert.Equal(new MusicBrief("calm", "Morning calm", "soft piano", "calm"), sources.Briefs.Single());
        // The free track comes first; the plan's 18 dB under the voice is its level; nothing is charged.
        var entry = Assert.Single(editor.Project.Music);
        Assert.Equal(("Calm piano", -18.0), (entry.Title, entry.GainDb));
        Assert.Equal([Library], sources.Fetched);
        Assert.Equal(0, run.Spent);
        var row = run.Rows.Single(item => item.Id == "music");
        Assert.Equal(("Claude chose music “Calm piano”", "calm · 18 dB under your voice", MakeItChange.Music, true),
            (row.Text, row.Detail, row.Change, row.Undoable));
        Assert.NotNull(row.Play);
        Assert.EndsWith("Music: “Calm piano” by Someone, CC BY 4.0", editor.MakeItPost(run));
        // The whole run is one step; the row's Undo takes back the music only.
        editor.MakeItUndo("music", run);
        Assert.Empty(editor.Project.Music);
        Assert.Equal("Sleep wins", editor.State!.Clips.Single().Title);
    }

    [Fact]
    public async Task MakeItMakesATrackOnlyWithinTheCapAndOffAddsNone()
    {
        // Claude mode's $2 pool (Make top runs on suggestions) covers it: the track is made and charged once.
        var (editor, sources, _) = Open(suggested: true);
        sources.Result = _ => new([Generated(0.105m)], new Dictionary<MusicSource, string>());
        editor.ChooseClipStyle(MakeItPostableTests.Style() with { Rewording = "off" }, MakeItPostableTests.Library, collapse: true);
        editor.MakeIt.Services = new MakeItPostableTests.Stub().Services();
        Assert.True(editor.MakeTopPostable(1, new MakeItBudget(2)));
        await editor.MakeIt.WaitForSeriesAsync();
        var run = editor.MakeIt.Run("c1")!;
        Assert.Equal((MusicSource.Generated, 0.105m), (editor.Project.Music.Single().Source, run.Spent));
        Assert.Single(sources.Fetched);
        Assert.EndsWith("(generated)", run.Rows.Single(item => item.Id == "music").Text);
        // A $0 pool makes nothing.
        var (free, freeSources, _) = Open(suggested: true);
        freeSources.Result = _ => new([Generated(0.105m)], new Dictionary<MusicSource, string>());
        free.ChooseClipStyle(MakeItPostableTests.Style() with { Rewording = "off" }, MakeItPostableTests.Library, collapse: true);
        free.MakeIt.Services = new MakeItPostableTests.Stub().Services();
        Assert.True(free.MakeTopPostable(1, new MakeItBudget(0)));
        await free.MakeIt.WaitForSeriesAsync();
        Assert.Empty(free.Project.Music);
        Assert.Empty(freeSources.Fetched);
        Assert.Equal("No free track fit “calm”", free.MakeIt.Run("c1")!.Rows.Single(item => item.Id == "music").Text);
        // Music Off adds no music step at all.
        var (off, offSources, _) = Open();
        off.ChooseClipStyle(MakeItPostableTests.Style() with { Music = "off" }, MakeItPostableTests.Library, collapse: true);
        var offRun = await MakeItPostableTests.RunAsync(off, new MakeItPostableTests.Stub());
        Assert.Empty(offSources.Briefs);
        Assert.DoesNotContain(offRun.Rows, item => item.Id == "music");
    }
}
#endif
