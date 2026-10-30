#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class RoundFiveTests(ITestOutputHelper output)
{
    [Fact]
    public void SidebarBadgesUseSixteenPixelGeometryAndKeepTheirPageRing()
    {
        var app = Path.Combine(Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!, "apps/windows/src/VoxClip.App");
        System.Xml.Linq.XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        var tokens = System.Xml.Linq.XDocument.Load(Path.Combine(app, "Themes/Workspace.xaml"));
        double Token(string key) => double.Parse(tokens.Descendants().Single(element => (string?)element.Attribute(xaml + "Key") == key).Value, System.Globalization.CultureInfo.InvariantCulture);
        var badges = System.Xml.Linq.XDocument.Load(Path.Combine(app, "MainWindow.xaml")).Descendants().Where(element => element.Name.LocalName == "Border" &&
            element.Descendants().Any(child => ((string?)child.Attribute("Text"))?.StartsWith("{x:Bind Number,", StringComparison.Ordinal) == true) && element.Attribute("CornerRadius")?.Value == "4" && element.Attribute("Height")?.Value == "16").ToArray();
        Assert.Equal(3, badges.Length);
        foreach (var badge in badges)
        {
            Assert.Equal("16", (string?)badge.Attribute("Width"));
            Assert.Equal("16", (string?)badge.Attribute("Height"));
            Assert.Equal("4", (string?)badge.Attribute("CornerRadius"));
            Assert.Equal("1,-4,0,0", (string?)badge.Attribute("Margin"));
            var left = double.Parse(badge.Attribute("Margin")!.Value.Split(',')[0], System.Globalization.CultureInfo.InvariantCulture);
            Assert.Equal(-4, left - (Token("VcLayoutRowThumbColumnWidth") - Token("VcLayoutClipThumbWidth")));
            Assert.Equal("1", (string?)badge.Attribute("BorderThickness"));
            Assert.Equal("{ThemeResource VcBgSurfaceBrush}", (string?)badge.Attribute("BorderBrush"));
        }
        Assert.Contains("new Grid { Width = 18, Height = 18, Visibility = Visibility.Collapsed }", File.ReadAllText(Path.Combine(app, "Controls/TimelineView.cs")));
    }
    [Theory]
    [InlineData(0, "No clips matched. Try another style or describe what you want.")]
    [InlineData(1, "Found 1 clip.")]
    [InlineData(3, "Found 3 clips.")]
    public void ClipsFoundUsesExactApprovedCopy(int count, string expected) => Assert.Equal(expected, ClipAnnouncements.Found(count));

    [Fact]
    public void ProgressSpeaksTheActualPercentageOnlyAtNewDeciles()
    {
        var announcements = new TranscriptionAnnouncements();
        Assert.Equal("Transcribing with ElevenLabs · 42%", announcements.Update(MediaTranscriptionStage.Transcribing, 0.42, true));
        Assert.Null(announcements.Update(MediaTranscriptionStage.Transcribing, 0.49, true));
        Assert.Equal("Transcribing with ElevenLabs · 53%", announcements.Update(MediaTranscriptionStage.Transcribing, 0.527, true));
        Assert.Equal("Transcribing with ElevenLabs · 68%", announcements.Update(MediaTranscriptionStage.Transcribing, 0.681, true));
    }

    [Fact]
    public void DiskFullUsesExactKnownAndUnknownSizeRecoveryCopy()
    {
        var exception = new IOException("full", unchecked((int)0x80070070));
        var mapped = VoxClip.Media.Pipeline.ExportErrors.Map(exception, "output.mp4", "2 GB");
        Assert.Equal($"There isn't enough free space on {Path.GetPathRoot(Path.GetFullPath("output.mp4"))}. Free up 2 GB and try again.", mapped.Message);
        Assert.Equal($"There isn't enough free space on {Path.GetPathRoot(Path.GetFullPath("output.mp4"))}. Free up space and try again.", VoxClip.Media.Pipeline.ExportErrors.Map(exception, "output.mp4").Message);
    }

    [Fact]
    public void XamlAndDynamicPlayIconsUseExactNamesAndSeparateSpaceHints()
    {
        Assert.Equal("Play", PlaybackPresentation.Name(false));
        Assert.Equal("Pause", PlaybackPresentation.Name(true));
        Assert.Equal("Play (Space)", PlaybackPresentation.Hint(false));
        Assert.Equal("Pause (Space)", PlaybackPresentation.Hint(true));
        var app = Path.Combine(Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!, "apps/windows/src/VoxClip.App");
        System.Xml.Linq.XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        var button = System.Xml.Linq.XDocument.Load(Path.Combine(app, "Pages/EditorPage.xaml")).Descendants().Single(element => (string?)element.Attribute(xaml + "Name") == "PreviewPlay");
        Assert.Equal("Play", (string?)button.Attribute("AutomationProperties.Name"));
        Assert.Equal("Space", (string?)button.Attribute("AutomationProperties.AcceleratorKey"));
        Assert.Equal("Play (Space)", (string?)button.Attribute("ToolTipService.ToolTip"));
        var dynamic = File.ReadAllText(Path.Combine(app, "Controls/TimelineView.cs"));
        Assert.Contains("AutomationProperties.SetName(play, \"Play\")", dynamic);
        Assert.Contains("AutomationProperties.SetName(play, PlaybackPresentation.Name(playing))", dynamic);
        Assert.Contains("AutomationProperties.SetAcceleratorKey(play, \"Space\")", dynamic);
        Assert.Contains("ToolTipService.SetToolTip(play, PlaybackPresentation.Hint(playing))", dynamic);
        var page = File.ReadAllText(Path.Combine(app, "Pages/EditorPage.xaml.cs"));
        Assert.Contains("AutomationProperties.SetName(PreviewPlay, PlaybackPresentation.Name(position.IsPlaying))", page);
    }
    [Fact]
    public void HighContrastStageMessageSitsOnAWindowPlateOverTheBlackStage()
    {
        var app = Path.Combine(Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!, "apps/windows/src/VoxClip.App");
        System.Xml.Linq.XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        var page = System.Xml.Linq.XDocument.Load(Path.Combine(app, "Pages/EditorPage.xaml"));
        System.Xml.Linq.XElement Named(string name) => page.Descendants().Single(element => (string?)element.Attribute(xaml + "Name") == name);
        var standIn = Named("PreviewStandIn");
        var themes = standIn.Parent!.Descendants().Where(element => element.Name.LocalName == "ResourceDictionary" && element.Attribute(xaml + "Key") is not null)
            .ToDictionary(element => (string)element.Attribute(xaml + "Key")!, element => element.Elements().ToDictionary(resource => (string)resource.Attribute(xaml + "Key")!));
        string Value(string theme, string key) => (string?)themes[theme][key].Attribute("Color") ?? themes[theme][key].Value;
        Assert.Equal("{ThemeResource SystemColorWindowColor}", Value("HighContrast", "StageMessagePlateBrush"));
        Assert.Equal("{ThemeResource SystemColorWindowTextColor}", Value("HighContrast", "StageMessageEdgeBrush"));
        Assert.Equal("1", Value("HighContrast", "StageMessageEdgeThickness"));
        Assert.Equal("1", Value("HighContrast", "StageMessageFileOpacity"));
        Assert.Equal("Transparent", Value("Default", "StageMessagePlateBrush"));
        Assert.Equal("0", Value("Default", "StageMessageEdgeThickness"));
        Assert.Equal("0.66", Value("Default", "StageMessageFileOpacity"));
        foreach (var (attribute, key) in new[] { ("Background", "StageMessagePlateBrush"), ("BorderBrush", "StageMessageEdgeBrush"), ("BorderThickness", "StageMessageEdgeThickness") })
            Assert.Equal("{ThemeResource " + key + "}", (string?)standIn.Attribute(attribute));
        Assert.Equal("{ThemeResource StageMessageFileOpacity}", (string?)Named("PreviewFile").Attribute("Opacity"));
        var contrast = System.Xml.Linq.XDocument.Load(Path.Combine(app, "Themes/Tokens.xaml")).Descendants().Single(element => (string?)element.Attribute(xaml + "Key") == "HighContrast");
        foreach (var (name, key) in new[] { ("PreviewEmpty", "VcChipMediaForegroundBrush"), ("PreviewFile", "VcChipMediaForegroundBrush"), ("PreviewStateGlyph", "VcChipWarningGlyphBrush") })
        {
            Assert.Equal("{ThemeResource " + key + "}", (string?)Named(name).Attribute("Foreground"));
            Assert.Equal("{ThemeResource SystemColorWindowTextColor}", contrast.Elements().Single(element => (string?)element.Attribute(xaml + "Key") == key).Attribute("Color")!.Value);
        }
    }
    [Fact]
    public async Task DialogRoutingMapsEveryControlChoiceAndFreezesTheSnapshot()
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        model.Select(0); model.Select(2, true); var first = model.MakeClip()!;
        model.Select(3); model.Select(5, true); model.MakeClip();
        var folder = Path.GetFullPath("routing-output");
        foreach (var selected in new string?[] { null, first })
        for (var scope = 0; scope < ExportDialogRouting.Scopes(selected).Count; scope++)
        for (var aspect = 0; aspect < EditorLayout.Frames.Count; aspect++)
        for (var quality = 0; quality < 2; quality++)
        {
            var route = new ExportDialogRouting(model, selected, scope, aspect, quality, true, folder, "{project}-{clip}-{aspect}");
            var kind = ExportDialogRouting.Scopes(selected)[scope];
            Assert.Equal(kind == ExportScopeKind.AllClips ? 2 : 1, route.Targets.Count);
            foreach (var target in route.Targets)
            {
                var called = false;
                var job = await route.JobAsync(target, (captured, state, _) =>
                {
                    called = true;
                    Assert.Equal(target is ExportTarget.Clip clip ? clip.Id : null, captured.Edits.ActiveClipId);
                    Assert.Equal(captured.Edits.ActiveClipId, state!.ActiveClipId);
                    Assert.Equal(EditorLayout.Frames[aspect], captured.Export.Aspect);
                    Assert.Equal((ExportQuality)quality, captured.Export.Quality);
                    Assert.Equal(folder, captured.Export.Folder);
                    var media = ExportRenderInput.Media(captured);
                    return Task.FromResult(new ComposeSnapshot(media, ExportRenderInput.Plan(media, state), null, ExportRenderInput.Output(media, captured.Export)));
                }, TestContext.Current.CancellationToken);
                Assert.True(called);
                Assert.Equal(EditorLayout.Frames[aspect], job.Aspect);
                Assert.Equal((ExportQuality)quality, job.Quality);
                Assert.Equal(folder, Path.GetDirectoryName(job.OutputPath));
                Assert.Equal(Path.ChangeExtension(job.OutputPath, ".srt"), job.SrtPath);
                Assert.Contains(ExportSelection.AspectSuffix(job.Aspect), job.OutputPath, StringComparison.Ordinal);
            }
        }
        var frozen = new ExportDialogRouting(model, first, 0, 0, 1, false, folder, "{clip}");
        var original = frozen.State(frozen.Targets[0]);
        model.Apply(new EditOperation.Correct(model.Words[0].Id, "later edit"));
        Assert.Same(original!.Corrections, frozen.State(frozen.Targets[0])!.Corrections);
        Assert.NotSame(model.State!.Corrections, original.Corrections);
    }
    [Fact]
    public void FingerprintUsesEffectiveQualityEncodingAndOnlyTheActiveAnchor()
    {
        var project = RoundThreeTests.Fixture();
        project = project with { Export = project.Export with { Aspect = ExportAspect.Portrait, Quality = ExportQuality.Standard } };
        var target = new ExportTarget.FullEdit();
        var fingerprint = ExportFingerprint.For(project, target);
        var high = project with { Export = project.Export with { Quality = ExportQuality.High } };
        Assert.NotEqual(fingerprint, ExportFingerprint.For(high, target));
        var output = ExportRenderInput.Output(ExportRenderInput.Media(project), project.Export);
        Assert.Equal(new OutputSpec(new(1080, 1920), 30, 8_000_000, 48000, 2, 160_000, "h264"), output);
        Assert.Equal(12_000_000, ExportRenderInput.Output(ExportRenderInput.Media(high), high.Export).VideoBitrate);
        foreach (var words in new[]
        {
            project.Transcript!.Words.Select(word => word with { Conf = 0.17 }).ToArray(),
            project.Transcript.Words.Select(word => word with { Speaker = "different speaker" }).ToArray()
        }) Assert.Equal(fingerprint, ExportFingerprint.For(project with { Transcript = project.Transcript with { Words = words } }, target));
        Assert.Equal(fingerprint, ExportFingerprint.For(project with { ModifiedAt = project.ModifiedAt.AddDays(1) }, target));
        var positions = project.Captions.PositionByAspect.ToDictionary();
        positions["1:1"] = new(0.2, 0.3);
        var changed = project with { Captions = project.Captions with { PositionByAspect = positions } };
        Assert.Equal(fingerprint, ExportFingerprint.For(changed, target));
        Assert.NotEqual(ExportFingerprint.For(project with { Export = project.Export with { Aspect = ExportAspect.Square } }, target),
            ExportFingerprint.For(changed with { Export = changed.Export with { Aspect = ExportAspect.Square } }, target));
        var model = new EditorViewModel(project);
        model.SetExportRecords([new(project.Id, "full", DateTimeOffset.UtcNow, fingerprint, project.Captions.StyleId, project.Export.Aspect, "out.mp4")]);
        model.SetExport(high.Export);
        Assert.Equal(ClipExportState.ChangedSinceExport, model.ExportStatus(null).State);
    }

    [Fact]
    public void CaptionOnlyInputsDoNotFingerprintWhileCaptionsAreOff()
    {
        var project = RoundThreeTests.Fixture();
        project = project with { Captions = project.Captions with { StyleId = "off" } };
        var target = new ExportTarget.FullEdit();
        var fingerprint = ExportFingerprint.For(project, target);
        var word = project.Transcript!.Words[0];
        foreach (var change in new Func<Project, Project>[]
        {
            value => value with { Edits = value.Edits with { Corrections = new Dictionary<string, string> { [word.Id] = "changed" } } },
            value => value with { Captions = value.Captions with { Overrides = System.Text.Json.JsonSerializer.SerializeToElement(new { layout = new { maxWords = 2 } }) } },
            value => value with { Captions = value.Captions with { Position = new(0.3, 0.7), PositionByAspect = new Dictionary<string, CaptionPosition>() } },
            value => value with { Transcript = value.Transcript! with { Language = "et" } }
        }) Assert.Equal(fingerprint, ExportFingerprint.For(change(project), target));
    }

    [Fact]
    public void CanonicalFingerprintRetainsAllRenderSensitivityProbes()
    {
        var project = RoundThreeTests.Fixture();
        var target = new ExportTarget.FullEdit();
        var original = ExportFingerprint.For(project, target);
        var word = project.Transcript!.Words[0];
        foreach (var change in new Func<Project, Project>[]
        {
            value => value with { Media = new(value.Media.Source with { ContentKey = "other-content" }) },
            value => value with { Media = new(value.Media.Source with { Video = value.Media.Source.Video! with { FrameRate = 60 } }) },
            value => value with { Media = new(value.Media.Source with { Audio = new(44100, 1) }) },
            value => value with { Captions = value.Captions with { StyleId = "off" } },
            value => value with { Captions = value.Captions with { Overrides = System.Text.Json.JsonSerializer.SerializeToElement(new { layout = new { maxWords = 2 } }) } },
            value => value with { Captions = value.Captions with { Position = new(0.3, 0.7), PositionByAspect = new Dictionary<string, CaptionPosition>() } },
            value => value with { Transcript = value.Transcript! with { Words = value.Transcript.Words.Select(item => item.Id == word.Id ? item with { Start = item.Start + 0.01 } : item).ToArray() } },
            value => value with { Edits = value.Edits with { CutWordIds = value.Edits.CutWordIds.Append(word.Id).ToArray() } },
            value => value with { Edits = value.Edits with { CutWordIds = [] } },
            value => value with { Edits = value.Edits with { CutPauseIds = [] } },
            value => value with { Edits = value.Edits with { PauseKeepSeconds = 0.4 } },
            value => value with { Edits = value.Edits with { Corrections = new Dictionary<string, string> { [word.Id] = "changed" } } }
        }) Assert.NotEqual(original, ExportFingerprint.For(change(project), target));
        Assert.Equal(original, ExportFingerprint.For(project with { Export = project.Export with { Folder = "/other-output" } }, target));
    }
    [Fact]
    public void IntervalQueryRetainsUnsortedIdentitiesAndSkipsEmptyAndTouchingSpans()
    {
        var word = RoundThreeTests.Fixture().Transcript!.Words[0];
        TimedWord[] words = [word with { Id = "later", Start = 7, End = 8 }, word with { Id = "match", Start = 5, End = 6 },
            word with { Id = "empty", Start = 5.5, End = 5.5 }, word with { Id = "tie", Start = 5, End = 6 },
            word with { Id = "touch-left", Start = 4, End = 5 }, word with { Id = "touch-right", Start = 6, End = 7 }];
        var index = new TimelineIntervalIndex(words);
        Assert.Equal(new[] { "touch-left", "match", "tie", "touch-right", "later" }, index.Words.Select(item => item.Id));
        var matches = new List<TimedWord>();
        index.Query(5, 6, matches.Add);
        Assert.Equal(new[] { words[1], words[3] }, matches);
        Assert.Same(words[1], matches[0]);
        var project = RoundFourTests.OverlappingProject();
        var model = new EditorViewModel(project with { Transcript = project.Transcript! with { Words = [words[0], words[1]] } });
        var scene = new TimelineScene();
        scene.Build(model, TimelineLayout.Plan(model), new(5, 6), [], 100, false);
        Assert.Single(scene.Layers[0]);
        model.SetTranscript(project.Transcript! with { Words = [words[2]] });
        scene.Build(model, TimelineLayout.Plan(model), new(5, 6), [], 100, false);
        Assert.Empty(scene.Layers[0]);
    }

    [Fact]
    public void NestedIntervalQueryIsOutputSensitiveForNineThousandWords()
    {
        var word = RoundThreeTests.Fixture().Transcript!.Words[0];
        var words = Enumerable.Range(0, 9000).Select(index => word with { Id = $"nested-{index}", Start = index, End = index == 0 ? 9000 : index + 1 }).ToArray();
        var index = new TimelineIntervalIndex(words);
        var matches = new List<TimedWord>();
        index.Query(8998, 8999, matches.Add);
        output.WriteLine($"Nested 9000: k={matches.Count}, visited={index.VisitedWords}, bound={matches.Count + 2 * (int)Math.Ceiling(Math.Log2(words.Length))}.");
        Assert.Equal(new[] { "nested-0", "nested-8998" }, matches.Select(item => item.Id).Order(StringComparer.Ordinal));
        Assert.InRange(index.VisitedWords, matches.Count, matches.Count + 2 * (int)Math.Ceiling(Math.Log2(words.Length)));
        var random = new Random(529);
        words = words.Select(item => item with { Start = random.Next(100), End = random.Next(100) }).ToArray();
        index = new(words);
        for (var start = 0; start < 100; start++)
        {
            matches.Clear();
            index.Query(start, start + 1, matches.Add);
            Assert.Equal(words.Where(item => item.Start < item.End && item.Start < start + 1 && item.End > start).Select(item => item.Id).Order(StringComparer.Ordinal), matches.Select(item => item.Id).Order(StringComparer.Ordinal));
        }
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void HistoryCancelsCaptionDragBeforeRestoringPosition(bool redo)
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        var original = model.Project.Captions;
        model.MoveCaptionAnchor(new(0.2, 0.3));
        if (redo) model.Undo();
        var beforeHistory = model.Project.Captions;
        var cancelled = false;
        model.CaptionDrag.Begin(model.Project.Export.Aspect);
        model.CaptionDrag.Cancelled += (_, _) =>
        {
            cancelled = true;
            Assert.Same(beforeHistory, model.Project.Captions);
        };
        if (redo) model.Redo(); else model.Undo();
        Assert.True(cancelled);
        Assert.False(model.CaptionDrag.IsActive);
        var restored = model.Project.Captions;
        var history = (model.CanUndo, model.CanRedo);
        model.CompleteCaptionDrag(new(0.4, 0.5));
        Assert.Same(restored, model.Project.Captions);
        Assert.Equal(history, (model.CanUndo, model.CanRedo));
        if (redo) Assert.Equal(new CaptionPosition(0.2, 0.3), CaptionFineTune.StoredPosition(model.Project));
        else Assert.Same(original, restored);
        if (redo) model.Undo(); else model.Redo();
        if (redo) Assert.Same(original, model.Project.Captions);
        else Assert.Equal(new CaptionPosition(0.2, 0.3), CaptionFineTune.StoredPosition(model.Project));
        Assert.Equal(redo, model.CanRedo);
    }

    [Fact]
    public async Task ReloadAndReopenBoundaryRejectsAStaleCaptionRelease()
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        model.MoveCaptionAnchor(new(0.2, 0.3));
        var saved = model.Project;
        model.CaptionDrag.Begin(saved.Export.Aspect);
        var boundary = new ProjectLeaveBoundary(model);
        await boundary.BeginAsync(() =>
        {
            Assert.False(model.CaptionDrag.IsActive);
            model.CompleteCaptionDrag(new(0.4, 0.5));
            Assert.Same(saved, model.Project);
            return Task.CompletedTask;
        });
        var reloaded = new EditorViewModel(saved);
        model.CompleteCaptionDrag(new(0.4, 0.5));
        Assert.Equal(new CaptionPosition(0.2, 0.3), CaptionFineTune.StoredPosition(reloaded.Project));
        Assert.False(reloaded.CanUndo);
        boundary.Resume();
        model.Undo();
        Assert.False(model.CanUndo);
    }

    [Fact]
    public void TranscriptAndCaptionReplacementCancelCaptionDrags()
    {
        var model = new EditorViewModel(RoundThreeTests.Fixture());
        foreach (var replace in new Action[]
        {
            () => model.Apply(new EditOperation.Correct(model.Words[0].Id, "corrected")),
            () => model.SetTranscript(model.Project.Transcript!),
            () => model.SetCaptions(model.Project.Captions),
            () => model.SetCaptionStyle("vox-highlight")
        })
        {
            model.CaptionDrag.Begin(model.Project.Export.Aspect);
            replace();
            Assert.False(model.CaptionDrag.IsActive);
            var current = model.Project;
            var history = (model.CanUndo, model.CanRedo);
            model.CompleteCaptionDrag(new(0.4, 0.5));
            Assert.Same(current, model.Project);
            Assert.Equal(history, (model.CanUndo, model.CanRedo));
        }
        output.WriteLine("History, reload/reopen, transcript and caption replacements reject stale releases.");
    }
}
#endif
