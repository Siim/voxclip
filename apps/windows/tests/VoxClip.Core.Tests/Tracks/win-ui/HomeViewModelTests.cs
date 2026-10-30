#if WIN_UI_TESTS
using SkiaSharp;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Media.Pipeline;
using VoxClip.Media.Thumbnails;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Home tiles, their media states, search, the AI callout and poster frames: design §7 and §5.4 (ADR-R29).</summary>
public sealed class HomeViewModelTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 26, 18, 0, 0, TimeSpan.Zero);

    internal static Project Fixture(string name)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, "shared", "fixtures", "projects", name);
            if (File.Exists(path)) return ProjectSerialization.Deserialize(File.ReadAllText(path));
        }
        throw new FileNotFoundException("Shared project fixture not found.", name);
    }

    /// <summary>The interview take, titled, saved at <paramref name="modified"/>, with the given clips by origin and selection.</summary>
    private static Project Take(string title, DateTimeOffset modified, params (ClipOrigin Origin, bool Selected)[] clips)
    {
        var project = Fixture("interview-take.voxclip");
        var word = project.Transcript!.Words[0].Id;
        var ranges = clips.Select((clip, index) => new ClipRange($"clip-{index}", word, word, null, clip.Origin, null, null, clip.Selected)).ToArray();
        return project with { Title = title, ModifiedAt = modified, Edits = project.Edits with { Clips = ranges, ActiveClipId = null } };
    }

    private static RecentProject Tile(Project project, bool missing = false)
    {
        var tile = new RecentProject($@"C:\Projects\{project.Title}.voxclip", "file-name");
        tile.Load(project, missing, Now);
        return tile;
    }

    [Fact]
    public void ConsentLanguageFollowsLoadedTranscriptAndClearsOnFailure()
    {
        var project = Fixture("interview-take.voxclip");
        var tile = Tile(project with { Transcript = project.Transcript! with { Language = "et" } });
        Assert.Equal("et", tile.TranscriptLanguage);
        tile.Fail();
        Assert.Null(tile.TranscriptLanguage);
    }

    [Fact]
    public void TileMetaReadsDurationDateAndKeptClips()
    {
        var take = Take("First year at the café", Now.AddHours(-2), (ClipOrigin.Manual, true), (ClipOrigin.Ai, true), (ClipOrigin.Ai, false));
        var tile = Tile(take);
        var duration = EditorViewModel.Duration(take.Media.Source.DurationSeconds);
        Assert.Equal("First year at the café", tile.Title);
        Assert.Equal($"{duration} · Today · 2 clips", tile.Meta);
        Assert.Equal($"{duration} · Today", tile.Detail);
        // Design §3.4: only the duration is set in Cascadia Mono.
        Assert.Equal((duration, " · Today"), (tile.DetailTime, tile.DetailStatus));
        Assert.Equal($"{duration}, 2 clips, opened Today", tile.Description);
        Assert.Equal("First year at the café", tile.ToString());
        Assert.IsType<MediaStatus.None>(tile.Status);
        Assert.True(tile.ShowsMeta && !tile.ShowsWarning && !tile.ShowsCancel && tile.DetailIsPlain);

        tile.IsOpen = true;
        Assert.Equal($"{duration} · Open now · 2 clips", tile.Meta);
        Assert.Equal($"{duration} · Yesterday · 1 clip", Tile(Take("One", Now.AddDays(-1), (ClipOrigin.Manual, true))).Meta);
        Assert.Equal($"{duration} · Today · No clips yet", Tile(Take("None", Now, (ClipOrigin.Ai, false))).Meta);
        Assert.Equal("file-name", Tile(Take(" ", Now)).Title);
    }

    /// <summary>Design §7 and §5.4.4 a: the duration chip sits on a loaded tile in the normal state, after the hold; every other
    /// state shows its own chip instead.</summary>
    [Fact]
    public void TheDurationChipShowsOnlyOnANormalLoadedTile()
    {
        var take = Take("First year at the café", Now);
        var unloaded = new RecentProject(@"C:\Projects\cafe.voxclip", "cafe");
        Assert.Equal("", unloaded.Duration);
        Assert.False(unloaded.Media.ShowsDuration(unloaded.Duration, false));
        var tile = Tile(take);
        Assert.Equal(EditorViewModel.Duration(take.Media.Source.DurationSeconds), tile.Duration);
        Assert.True(tile.Media.ShowsDuration(tile.Duration, false));
        Assert.False(tile.Media.ShowsDuration(tile.Duration, true));
        Assert.False(Tile(take, missing: true).Media.ShowsDuration(tile.Duration, false));
        foreach (var status in new MediaStatus[] { new MediaStatus.Loading(), new MediaStatus.Unreadable(), new MediaStatus.Transcribing(0.42, MediaTranscriptionStage.Transcribing), new MediaStatus.Demo(), new MediaStatus.AudioOnly() })
            Assert.False((tile.Media with { Status = status }).ShowsDuration(tile.Duration, false), status.ToString());
    }

    [Fact]
    public void MissingVideoKeepsTheTitleAndOffersOpen()
    {
        var tile = Tile(Take("Latte art for beginners", Now.AddDays(-9)), missing: true);
        tile.FramePath = @"C:\stale.jpg";
        Assert.True(tile.Missing);
        Assert.IsType<MediaStatus.Missing>(tile.Media.Status);
        // Core's precedence never shows a frame for a missing video, even a stale cached one.
        Assert.IsNotType<MediaStandIn.Frame>(tile.Media.StandIn(true, false));
        Assert.Equal("⚠ Video not found.", tile.Warning);
        Assert.Equal("⚠ Video not found", tile.Detail);
        Assert.Equal(("", "⚠ Video not found"), (tile.DetailTime, tile.DetailStatus));
        Assert.True(tile.ShowsWarning && !tile.ShowsMeta && tile.DetailIsWarning);
        Assert.Equal("Latte art for beginners, video not found", tile.AccessibleName);
        Assert.Equal("Open Latte art for beginners", tile.OpenName);
    }

    [Fact]
    public void UnreadableVideoShowsTheWarningLine()
    {
        var tile = Tile(Take("Night shift notes", Now));
        tile.Unreadable = true;
        Assert.IsType<MediaStatus.Unreadable>(tile.Status);
        Assert.Equal("⚠ Can't read video.", tile.Warning);
        Assert.Equal("⚠ Can't read video", tile.Detail);
        Assert.Equal("Night shift notes, video can't be read", tile.AccessibleName);
        // Reading the project again clears it until the decoder fails again.
        tile.Load(Take("Night shift notes", Now), false, Now);
        Assert.IsType<MediaStatus.None>(tile.Status);
    }

    [Fact]
    public void TranscribingPutsCancelOnTheMetaLine()
    {
        var tile = Tile(Take("Grinder shootout", Now));
        tile.Transcription = new(MediaTranscriptionStage.Transcribing, 0.42);
        Assert.Equal(new MediaStatus.Transcribing(0.42, MediaTranscriptionStage.Transcribing), tile.Media.Status);
        Assert.Equal("Transcribing on this PC", tile.Meta);
        Assert.True(tile.ShowsCancel);
        Assert.Equal("Transcribing · 42%", tile.Detail);
        Assert.Equal(("", "Transcribing · 42%"), (tile.DetailTime, tile.DetailStatus));
        Assert.Equal("Grinder shootout, transcribing 42 percent", tile.AccessibleName);
        Assert.Equal("Cancel transcribing Grinder shootout", tile.CancelName);

        tile.Transcription = new(MediaTranscriptionStage.Transcribing, null);
        Assert.Equal("Transcribing", tile.Detail);
        Assert.Equal("Grinder shootout, transcribing", tile.AccessibleName);
        tile.Transcription = new(MediaTranscriptionStage.ExtractingAudio, null);
        Assert.Equal("Extracting audio…", tile.Detail);
        Assert.Equal("Grinder shootout, extracting audio", tile.AccessibleName);
        tile.Transcription = null;
        Assert.False(tile.Transcribing || tile.ShowsCancel);
    }

    [Fact]
    public void ChipCopyFollowsTheTranscriptionStage()
    {
        Assert.Equal(("Transcribing · ", "42%"), Chip(new(MediaTranscriptionStage.Transcribing, 0.4249)));
        Assert.Equal(("Transcribing · ", "100%"), Chip(new(MediaTranscriptionStage.Transcribing, 1.2)));
        Assert.Equal(("Transcribing", ""), Chip(new(MediaTranscriptionStage.Transcribing, null)));
        Assert.Equal(("Reading video…", ""), Chip(new(MediaTranscriptionStage.ReadingVideo, null)));
        Assert.Equal(("Extracting audio…", ""), Chip(new(MediaTranscriptionStage.ExtractingAudio, 0.5)));
        Assert.Equal(("Aligning words…", ""), Chip(new(MediaTranscriptionStage.Aligning, 0.5)));
        static (string, string) Chip(TranscriptionStatus status) => (status.Label, status.Percent);
    }

    [Fact]
    public void LoadingHoldsBlankThenSaysLoading()
    {
        var tile = new RecentProject(@"C:\Projects\Opening day recap.voxclip", "Opening day recap");
        Assert.IsType<MediaStatus.None>(tile.Status);
        Assert.Equal("", tile.Meta);
        Assert.Equal("", tile.Detail);
        Assert.Equal("Opening day recap", tile.AccessibleName);

        tile.IsStalled = true;
        Assert.IsType<MediaStatus.Loading>(tile.Media.Status);
        Assert.Equal("Loading…", tile.Meta);
        Assert.Equal("Loading…", tile.Detail);
        Assert.Equal("Opening day recap, loading", tile.AccessibleName);

        tile.Load(Take("Opening day recap", Now), false, Now);
        Assert.False(tile.IsStalled);
        Assert.IsType<MediaStatus.None>(tile.Status);

        var unavailable = new RecentProject(@"C:\Projects\Broken.voxclip", "Broken") { IsStalled = true };
        unavailable.Fail();
        Assert.IsType<MediaStatus.None>(unavailable.Status);
        Assert.Equal("Broken, project unavailable", unavailable.AccessibleName);
    }

    [Fact]
    public void AudioOnlyTakesNeverShowAFrame()
    {
        var take = Take("Morning pages", Now);
        var tile = Tile(take with { Media = take.Media with { Source = take.Media.Source with { Video = null } } });
        tile.FramePath = @"C:\poster.jpg";
        Assert.IsType<MediaStatus.AudioOnly>(tile.Status);
        Assert.IsNotType<MediaStandIn.Frame>(tile.Media.StandIn(true, false));
        Assert.Equal("Morning pages, audio only", tile.AccessibleName);
    }

    /// <summary>Tiles draw Core's MediaStandIn.Resolve (design §5.4.1); the shared cases are in cards.json.</summary>
    [Fact]
    public void MediaTilesDrawCoresStandIn()
    {
        var words = new CaptionCard("k", new(CaptionCardSource.Transcript, [new CaptionCardWord("w1", "Honestly", "HONESTLY", false)], 0, 1, false, 0), "vox-bold", "{}", "en");
        var none = new CaptionCard("n", CaptionCardText.None, "vox-bold", "{}", "en");
        var transcribing = new MediaStatus.Transcribing(null, MediaTranscriptionStage.Transcribing);
        // A decoded frame wins, even during the 300 ms hold; the hold is black; then the card.
        Assert.IsType<MediaStandIn.Frame>(new MediaTile("a", "frame.jpg", words, new MediaStatus.None()).StandIn(true, true));
        Assert.IsType<MediaStandIn.Black>(new MediaTile("a", "frame.jpg", words, new MediaStatus.None()).StandIn(false, true));
        Assert.Equal(new MediaStandIn.Card(words.Text, "vox-bold"), new MediaTile("a", "frame.jpg", words, new MediaStatus.None()).StandIn(false, false));
        // A frame still decoding, or no path at all, is no frame.
        Assert.IsType<MediaStandIn.Black>(new MediaTile("a", null, words, new MediaStatus.None()).StandIn(true, true));
        // No words: stage black, except the style's backdrop while transcribing.
        Assert.IsType<MediaStandIn.Black>(new MediaTile("a", null, none, new MediaStatus.None()).StandIn(false, false));
        Assert.Equal(new MediaStandIn.Card(none.Text, "vox-bold"), new MediaTile("a", null, none, transcribing).StandIn(false, false));
        Assert.Equal(new MediaStandIn.Card(words.Text, "vox-bold"), new MediaTile("a", "frame.jpg", words, new MediaStatus.Missing()).StandIn(true, true));
        Assert.Equal("Interview take 3, demo project, no video", new MediaTile("a", null, words, new MediaStatus.Demo()).Name("Interview take 3"));
        Assert.Equal("Take, transcribing", new MediaTile("a", null, none, transcribing).Name("Take"));
        Assert.Equal("Take", MediaTile.Empty("a").Name("Take"));
    }

    [Theory]
    [InlineData(0, "Today")]
    [InlineData(1, "Yesterday")]
    [InlineData(3, "Fri")]
    [InlineData(7, "Oct 19")]
    [InlineData(300, "Dec 30, 2025")]
    public void DatesReadLikeTheMockup(int daysAgo, string expected)
    {
        var now = new DateTimeOffset(2026, 10, 26, 12, 0, 0, TimeZoneInfo.Local.GetUtcOffset(new DateTime(2026, 10, 26, 12, 0, 0)));
        Assert.Equal(expected, RecentProject.When(now.AddDays(-daysAgo), now));
    }

    [Fact]
    public void SearchFiltersByTitleSortsByNameAndExplainsNoMatch()
    {
        var home = new HomeViewModel();
        Assert.True(home.IsFirstRun);
        foreach (var title in new[] { "Why we closed Mondays", "Pricing our beans", "Morning routine Q&A" }) home.RecentProjects.Add(Tile(Take(title, Now)));
        Assert.False(home.IsFirstRun);
        Assert.Equal(["Why we closed Mondays", "Pricing our beans", "Morning routine Q&A"], home.Shown.Select(tile => tile.Title));

        var kept = home.Shown[1];
        home.Query = "PRICING";
        Assert.Same(kept, Assert.Single(home.Shown));
        Assert.False(home.HasNoMatch);
        home.Query = "espresso";
        Assert.Empty(home.Shown);
        Assert.Equal("No projects match “espresso”.", home.NoMatch);

        home.Query = "";
        home.Sort = RecentSort.Name;
        Assert.Equal("Name", home.SortLabel);
        Assert.Equal(["Morning routine Q&A", "Pricing our beans", "Why we closed Mondays"], home.Shown.Select(tile => tile.Title));
        Assert.Same(kept, home.Shown[1]);
    }

    [Fact]
    public void AiCalloutFollowsConnectorReadiness()
    {
        Assert.Equal(new AiCallout("Find clips with AI isn't set up yet.", "You can still make clips by hand.", "Set up AI…"), HomeViewModel.Callout(null, null, null));
        Assert.Equal(new AiCallout("Claude Code isn't signed in, so Find clips with AI can't run.", "You can still make clips by hand.", "Sign-in help"),
            HomeViewModel.Callout("Claude Code", "cli", new ConnectorStatus.CliSignedOut()));
        Assert.Equal(new AiCallout("Add your OpenAI key to use Find clips with AI.", "You can still make clips by hand.", "Set up AI…"),
            HomeViewModel.Callout("OpenAI", "apiKey", new ConnectorStatus.NeedsKey()));
        Assert.Equal(new AiCallout("Ollama isn't running, so Find clips with AI can't run.", "", "Check again"),
            HomeViewModel.Callout("Ollama", "local", new ConnectorStatus.NotRunning("http://127.0.0.1:11434")));
        Assert.Null(HomeViewModel.Callout("Ollama", "local", new ConnectorStatus.Ready()));
    }

    /// <summary>Connector copy names a CLI by its short name, taken from the catalogue label the App reads (ProviderEntry.ShortName).</summary>
    [Fact]
    public void ConnectorCopyUsesTheCliShortName()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "shared", "catalog", "llm-providers.json"))) root = root.Parent;
        Assert.NotNull(root);
        using var catalog = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(root.FullName, "shared", "catalog", "llm-providers.json")));
        var names = catalog.RootElement.GetProperty("connectors").EnumerateArray()
            .ToDictionary(entry => entry.GetProperty("id").GetString()!, entry => ClipCallouts.ConnectorName(entry.GetProperty("label").GetString()!, entry.GetProperty("group").GetString()!));
        Assert.Equal("Claude Code", names["claude-code"]);
        Assert.Equal("Codex", names["codex"]);
        Assert.Equal("Google Gemini", names["gemini"]);
        Assert.Equal("LM Studio", names["lmstudio"]);
        Assert.Equal("Anthropic", names["anthropic"]);
        Assert.Equal("Claude Code isn't signed in, so Find clips with AI can't run.", HomeViewModel.Callout(names["claude-code"], "cli", new ConnectorStatus.CliSignedOut())!.Title);
        Assert.Equal("Codex isn't signed in. Open Terminal and run codex login. Your edits are saved.",
            ClipCallouts.NotReady(ConnectorId.Codex, "Codex (installed CLI)", new ConnectorStatus.CliSignedOut(), null, "Open Terminal and run codex login.").Message);
    }

    /// <summary>Home looks at the connector as it is shown at most once a minute, again at once when the connector's own settings
    /// change or a check was cancelled, and never while one runs.</summary>
    [Fact]
    public void HomeChecksTheConnectorOnlyWhenItMayHaveChanged()
    {
        var checkedAt = new DateTime(2026, 10, 27, 9, 0, 0, DateTimeKind.Utc);
        Assert.False(HomeViewModel.ConnectorCheckDue(false, false, checkedAt, checkedAt.AddSeconds(59)));
        Assert.True(HomeViewModel.ConnectorCheckDue(false, false, checkedAt, checkedAt.AddSeconds(61)));
        Assert.True(HomeViewModel.ConnectorCheckDue(true, false, checkedAt, checkedAt.AddSeconds(1)));
        Assert.False(HomeViewModel.ConnectorCheckDue(true, true, checkedAt, checkedAt.AddMinutes(5)));

        var settings = new Dictionary<string, string> { ["llm.connector"] = "\"ollama\"", ["llm.baseUrl.ollama"] = "\"http://127.0.0.1:11434\"", ["general.transcriptTextSize"] = "17" };
        string? Raw(string key) => settings.TryGetValue(key, out var value) ? value : null;
        var before = HomeViewModel.ConnectorSettings("ollama", Raw);
        settings["general.transcriptTextSize"] = "20";
        settings["captions.defaultStyleId"] = "\"vox-box\"";
        Assert.Equal(before, HomeViewModel.ConnectorSettings("ollama", Raw));
        settings["llm.baseUrl.ollama"] = "\"http://127.0.0.1:11500\"";
        Assert.NotEqual(before, HomeViewModel.ConnectorSettings("ollama", Raw));
        settings["llm.cloudConsent.claude-code"] = "true";
        Assert.NotEqual(HomeViewModel.ConnectorSettings("ollama", Raw), HomeViewModel.ConnectorSettings("claude-code", Raw));
    }

    // PosterFrames' own candidate, black-frame and FFmpeg decode tests live with it in tests/VoxClip.Media.Tests/Thumbnails.
    [Fact]
    public void PosterCandidatesStartAtTheScopesFirstKeptWord()
    {
        var take = Fixture("interview-take.voxclip");
        Assert.Equal(take.Transcript!.Words[0].Start, Thumbnails.Candidates(take, null)[0]);
        var cut = take with { Edits = take.Edits with { CutWordIds = [take.Transcript.Words[0].Id, take.Transcript.Words[1].Id] } };
        Assert.Equal(take.Transcript.Words[2].Start, Thumbnails.Candidates(cut, null)[0]);
        Assert.Equal(0, Thumbnails.Candidates(take with { Transcript = null }, null)[0]);

        var longTake = Fixture("clip-from-long-take.voxclip");
        var clip = longTake.Edits.Clips[0];
        var words = longTake.Transcript!.Words;
        var start = words.First(word => word.Id == clip.StartWordId).Start;
        var end = words.First(word => word.Id == clip.EndWordId).End;
        var candidates = Thumbnails.Candidates(longTake, clip.Id);
        Assert.Equal(start, candidates[0]);
        Assert.Equal(start + (end - start) * 0.1, candidates[^1], 6);
    }

    [Fact]
    public void PosterPathsLiveInTheContentKeyEntry()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-poster-keys");
        var cache = new Thumbnails(root);
        var key = new string('a', 60) + "0f9e";
        Assert.Equal(Path.Combine(root, key, "thumbs", "poster-1.2-480x270.jpg"), cache.PathFor(key, 1.24));
        Assert.Equal(Path.Combine(root, key, "thumbs", "poster-1.3-480x270.jpg"), cache.PathFor(key, 1.25));
        Assert.Equal(cache.PathFor(key, 1.2), cache.PathFor(key, 1.16));
        Assert.Equal(Path.Combine(root, key, "thumbs", "poster-0.0-480x270.jpg"), cache.PathFor(key, 0));
        Assert.Null(cache.PathFor(@"..\..\outside", 1));
        Assert.Null(cache.PathFor(key.ToUpperInvariant(), 1));
        Assert.Null(cache.PathFor(key[..63], 1));
    }

    [Fact]
    public async Task AllBlackPostersAreRememberedWithoutDecoding()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-posters-" + Guid.NewGuid().ToString("N"));
        try
        {
            var cache = new Thumbnails(root);
            var key = new string('b', 64);
            var marker = Path.ChangeExtension(cache.PathFor(key, 2)!, ".none");
            Directory.CreateDirectory(Path.GetDirectoryName(marker)!);
            await File.WriteAllBytesAsync(marker, [], TestContext.Current.CancellationToken);
            // The marker stands in for every candidate; the missing source file is never opened.
            Assert.Null(await cache.GetAsync(key, Path.Combine(root, "missing.mp4"), [2, 3, 5], 0, TestContext.Current.CancellationToken));
            Assert.Null(await cache.GetAsync("not-a-key", Path.Combine(root, "missing.mp4"), [2], 0, TestContext.Current.CancellationToken));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    /// <summary>A cache that can't be written (here a file stands where the cache folder belongs) is a logged cache miss: no
    /// frame, the caption card stands in, and nothing is reported as an unreadable video. The source is never decoded.</summary>
    [Fact]
    public async Task AnUnwritableCacheIsACacheMissNotAnUnreadableVideo()
    {
        var ct = TestContext.Current.CancellationToken;
        var root = Path.Combine(Path.GetTempPath(), "voxclip-posters-" + Guid.NewGuid().ToString("N"));
        await File.WriteAllBytesAsync(root, [], ct);
        try
        {
            var warnings = new List<string>();
            var cache = new Thumbnails(root, warnings.Add);
            var key = new string('d', 64);
            Assert.Null(await cache.GetAsync(key, Path.Combine(Path.GetTempPath(), "voxclip-missing-" + Guid.NewGuid().ToString("N") + ".mp4"), [2, 3], 0, ct));
            var warning = Assert.Single(warnings);
            Assert.StartsWith("action=Poster cache code=", warning);
            Assert.True(warning.EndsWith("IOException", StringComparison.Ordinal) || warning.EndsWith("DirectoryNotFoundException", StringComparison.Ordinal), warning);
            // A miss is tried again next time, so a cache that recovers gets its frame; nothing was remembered.
            Assert.False(File.Exists(Path.ChangeExtension(cache.PathFor(key, 2)!, ".none")));
        }
        finally { File.Delete(root); }
    }

    [Fact]
    [Trait("Category", "RequiresWindows")]
    public async Task PosterFrameComesFromFfmpegAndIsCached()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The shipped FFmpeg decodes poster frames on the ARM64 VM.");
        var source = Environment.GetEnvironmentVariable("VOXCLIP_UI_NATIVE_FIXTURE");
        if (string.IsNullOrWhiteSpace(source)) Assert.Skip("Set VOXCLIP_UI_NATIVE_FIXTURE to the committed synthetic bars video.");
        var ct = TestContext.Current.CancellationToken;
        var root = Path.Combine(Path.GetTempPath(), "voxclip-thumbnails-" + Guid.NewGuid().ToString("N"));
        try
        {
            var media = await new FfmpegMediaProbe().ProbeAsync(source, ct);
            var cache = new Thumbnails(root);
            var key = new string('c', 64);
            var candidates = PosterFrames.Candidates(0, 0, media.DurationSeconds, media.DurationSeconds);
            var frame = await cache.GetAsync(key, source, candidates, media.Video?.RotationDegrees ?? 0, ct);
            Assert.NotNull(frame);
            Assert.Equal(cache.PathFor(key, 0), frame);
            using (var bitmap = SKBitmap.Decode(frame))
            {
                Assert.Equal(Thumbnails.CoverWidth, bitmap.Width);
                Assert.Equal(Thumbnails.CoverHeight, bitmap.Height);
                var luma = 0L;
                for (var x = 8; x < bitmap.Width; x += 16) { var pixel = bitmap.GetPixel(x, bitmap.Height / 2); luma += (pixel.Red * 54 + pixel.Green * 183 + pixel.Blue * 18) >> 8; }
                Assert.True(luma / (bitmap.Width / 16) > 40, "The bars frame decoded as black.");
            }
            var written = File.GetLastWriteTimeUtc(frame);
            Assert.Equal(frame, await cache.GetAsync(key, source, candidates, 0, ct));
            Assert.Equal(written, File.GetLastWriteTimeUtc(frame));
            Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(frame)!, "*.tmp"));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
#endif
