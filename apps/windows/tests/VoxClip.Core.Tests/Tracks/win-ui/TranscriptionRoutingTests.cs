#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The Transcribe dialog's local routing (transcription §11.2–11.3), the welcome tour's preselected model and the
/// dialog's progress copy, without a window, a model file or native code.</summary>
public sealed class TranscriptionRoutingTests
{
    private const string TalTech = "taltech-et-verbatim-2604-q8_0";
    private const string TalTechLow = "taltech-et-verbatim-2604-q4_0";
    private const string Turbo = "whisper-large-v3-turbo-q5_0";
    private const string SmallEn = "whisper-small.en-q5_1";
    private const string Vad = "silero-vad-v6.2.0";
    private const long Plenty = 16L << 30;
    private const long Low = 4L << 30;

    private sealed class Installed(params string[] ids) : IModelDownloader
    {
        public Task<IReadOnlyList<InstalledModel>> ListInstalledAsync(CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<InstalledModel>>(ids.Select(id => new InstalledModel(id, "unused", true, null)).ToArray());
        public Task<InstalledModel> InstallAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct) => throw new InvalidOperationException("Routing never downloads.");
        public Task<bool> VerifyAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct) => throw new InvalidOperationException();
        public Task RemoveAsync(string id, CancellationToken ct) => throw new InvalidOperationException();
    }

    private sealed class Detector((string Language, double Probability) result)
    {
        internal List<string> Models { get; } = [];
        internal Task<(string Language, double Probability)> DetectAsync(string model, CancellationToken ct)
        {
            Models.Add(model);
            return Task.FromResult(result);
        }
    }

    private static Task<LocalTranscriptionRoute> Route(IModelDownloader installed, string language, Detector? detector = null,
        string? model = null, long ram = Plenty, bool key = false) =>
        TranscriptionRouting.RouteAsync(new ModelCatalog(), installed, model, language, ram, key, detector is null ? null : detector.DetectAsync,
            TestContext.Current.CancellationToken);

    [Fact]
    public async Task AutoWithTalTechAndTurboDetectsWithTurboAndRoutesEstonianToTalTech()
    {
        var installed = new Installed(TalTech, Turbo, Vad);
        // Before the audio exists, Auto names the multilingual model that detects; it never preselects TalTech.
        var first = await Route(installed, "");
        Assert.Null(first.Plan);
        Assert.Equal(Turbo, first.Detector);
        var estonian = new Detector(("et", 0.97));
        var route = await Route(installed, "", estonian);
        Assert.Equal([Turbo], estonian.Models);
        Assert.Equal(TalTech, route.Plan!.Model);
        Assert.Equal(new LanguageChoice.Forced("et"), route.Plan.Language);
        var english = await Route(installed, "auto", new Detector(("en", 0.9)));
        Assert.Equal(Turbo, english.Plan!.Model);
        Assert.Equal(new LanguageChoice.Forced("en"), english.Plan.Language);
    }

    [Theory]
    [InlineData(Plenty, TalTech, "Estonian · TalTech verbatim (Q8_0)")]
    [InlineData(Low, TalTechLow, "Estonian · TalTech verbatim (Q4_0, low memory)")]
    public async Task DetectedEstonianWithOnlyTurboOffersTheTalTechDownloadInsteadOfFailing(long ram, string expected, string name)
    {
        var route = await Route(new Installed(Turbo, Vad), "", new Detector(("et", 0.95)), ram: ram, key: true);
        Assert.Null(route.Plan);
        Assert.Equal(expected, route.Download!.Id);
        Assert.StartsWith($"Download the {name} model (", route.Message);
        Assert.EndsWith(") to transcribe on this PC.", route.Message);
        Assert.DoesNotContain("can't transcribe", route.Message);
        Assert.True(route.OfferCloud);
        Assert.False(route.AskLanguage);
    }

    [Fact]
    public async Task AutoWithoutAMultilingualModelAsksForTheLanguageAndOffersTurboWithoutDetecting()
    {
        var detector = new Detector(("en", 0.99));
        foreach (var installed in new[] { new Installed(TalTech, Vad), new Installed() })
        {
            var route = await Route(installed, "", detector);
            Assert.Null(route.Plan);
            Assert.True(route.AskLanguage);
            Assert.StartsWith("Which language is spoken?", route.Message);
            Assert.Equal(Turbo, route.Download!.Id);
            Assert.Contains("download the Multilingual · Whisper large-v3-turbo (Q5_0) model (", route.Message);
        }
        Assert.Empty(detector.Models);
    }

    [Fact]
    public async Task UnsureDetectionAsksForTheLanguage()
    {
        var route = await Route(new Installed(Turbo, Vad), "", new Detector(("en", 0.3)));
        Assert.Null(route.Plan);
        Assert.True(route.AskLanguage);
        Assert.Equal(TranscriptionRouting.ChooseLanguage, route.Message);
        Assert.Null(route.Download);
    }

    [Theory]
    [InlineData("en", Plenty, Turbo)]
    [InlineData("en", Low, SmallEn)]
    [InlineData("fi", Low, Turbo)]
    public async Task TypedLanguageWithOnlyTalTechOffersItsRecommendedDownload(string language, long ram, string expected)
    {
        var route = await Route(new Installed(TalTech, Vad), language, ram: ram);
        Assert.Null(route.Plan);
        Assert.Equal(expected, route.Download!.Id);
        Assert.EndsWith(") to transcribe on this PC.", route.Message);
        Assert.False(route.OfferCloud);
    }

    [Fact]
    public async Task TypedLanguageRoutesToItsFirstInstalledModel()
    {
        var installed = new Installed(TalTech, Turbo, Vad);
        Assert.Equal(TalTech, (await Route(installed, "ET")).Plan!.Model);
        Assert.Equal(Turbo, (await Route(installed, "en")).Plan!.Model);
        Assert.Equal(Turbo, (await Route(installed, "de")).Plan!.Model);
        // A language-specific model the user installed wins for its language (§11.2).
        Assert.Equal(SmallEn, (await Route(new Installed(TalTech, Turbo, SmallEn, Vad), "en")).Plan!.Model);
    }

    [Fact]
    public async Task AChosenModelIsUsedAsChosenAndStillCheckedAgainstTheLanguage()
    {
        var installed = new Installed(TalTech, Turbo, Vad);
        var detector = new Detector(("et", 0.9));
        var taltech = await Route(installed, "", detector, TalTech);
        Assert.Equal(new LanguageChoice.Forced("et"), taltech.Plan!.Language);
        Assert.Empty(detector.Models);
        var turbo = await Route(installed, "", detector, Turbo);
        Assert.Equal(Turbo, turbo.Plan!.Model);
        Assert.Equal(new LanguageChoice.Forced("et"), turbo.Plan.Language);
        Assert.Equal([Turbo], detector.Models);
        var refused = await Route(installed, "en", model: TalTech);
        Assert.Null(refused.Plan);
        Assert.Equal("Whisper can't transcribe en.", refused.Message);
    }

    [Fact]
    public async Task TheWelcomeTourRecommendsTurboForAutoAndTalTechOnlyForEstonian()
    {
        var root = await new ModelCatalog().RootAsync(TestContext.Current.CancellationToken);
        Assert.Equal(Turbo, TranscriptionRouting.RecommendedDownload(root, "auto", Plenty));
        Assert.Equal(Turbo, TranscriptionRouting.RecommendedDownload(root, "", Low));
        Assert.Equal(Turbo, TranscriptionRouting.RecommendedDownload(root, "en", Plenty));
        Assert.Equal(SmallEn, TranscriptionRouting.RecommendedDownload(root, "en", Low));
        Assert.Equal(TalTech, TranscriptionRouting.RecommendedDownload(root, "et", Plenty));
        Assert.Equal(TalTechLow, TranscriptionRouting.RecommendedDownload(root, "et-EE", Low));
        Assert.Equal(Turbo, TranscriptionRouting.RecommendedDownload(root, "lv", Plenty));
        var tour = AppFile("Controls/OnboardingDialog.cs");
        Assert.DoesNotContain("models.SelectedIndex = 0", tour);
        Assert.Contains("TranscriptionRouting.RecommendedDownload(root, language.Text", tour);
        Assert.Contains("ModelDownloadCopy.DisplayName(model)", tour);
    }

    [Fact]
    public void ProgressUsesTheMacSheetCopyNotABareStageWord()
    {
        Assert.Equal("Preparing the speech model…", TranscriptionProgressCopy.Label(TranscriptionStage.Preparing, 0, false));
        Assert.Equal("Transcribing on this PC · 42%", TranscriptionProgressCopy.Label(TranscriptionStage.Transcribing, 0.429, false));
        Assert.Equal("Transcribing on this PC…", TranscriptionProgressCopy.Label(TranscriptionStage.Transcribing, null, false));
        Assert.Equal("Transcribing with ElevenLabs · 50%", TranscriptionProgressCopy.Label(TranscriptionStage.Transcribing, 0.5, true));
        Assert.Equal("Transcribing with ElevenLabs · 10%", TranscriptionProgressCopy.Label(TranscriptionStage.Uploading, 0.1, true));
        Assert.Equal("Aligning words…", TranscriptionProgressCopy.Label(TranscriptionStage.Aligning, 1, false));
        var dialog = AppFile("Controls/TranscriptionDialog.cs");
        Assert.DoesNotContain("value.Stage.ToString()", dialog);
        Assert.Contains("TranscriptionProgressCopy.Label(value.Stage, value.Fraction, cloud)", dialog);
    }

    [Fact]
    public void TheDialogRoutesOpensLocalModelsAndFollowsDownloads()
    {
        var dialog = AppFile("Controls/TranscriptionDialog.cs");
        Assert.DoesNotContain("Languages.Contains(\"*\")", dialog);
        Assert.Contains("TranscriptionRouting.RouteAsync(", dialog);
        Assert.Contains("App.OpenSettings(SettingsSections.LocalModels)", dialog);
        Assert.Contains("App.Services.ModelsChanged += ModelsChanged", dialog);
        Assert.Contains("App.Services.ModelsChanged -= ModelsChanged", dialog);
        // Routing runs before any audio work; detection only after the audio is extracted.
        var start = dialog.IndexOf("private async Task RunTranscriptionAsync", StringComparison.Ordinal);
        Assert.True(start >= 0);
        var run = dialog[start..];
        Ordered(run, "var route = local ? await RouteAsync(null) : null;", "if (route is { Plan: null, Detector: null }) { ShowRoute(route); return; }",
            "if (!local)", "ExtractAudioAsync", "App.Services.DetectLanguageAsync", "App.Services.Transcription.TranscribeAsync");
        // The local engine runs only its routed plan and never falls through to ElevenLabs.
        Ordered(run, "var plan = local ? route?.Plan ?? throw new InvalidOperationException(", ": new TranscriptionPlan(TranscriptEngine.Elevenlabs,",
            "TranscribeAsync(new(plan,");
        Assert.DoesNotContain("route?.Plan ?? new TranscriptionPlan(TranscriptEngine.Elevenlabs", run);
        var settings = System.Xml.Linq.XDocument.Load(Path.Combine(AppRoot, "SettingsWindow.xaml"));
        Assert.Contains(settings.Descendants().Select(element => (string?)element.Attribute("Tag")), tag => tag == SettingsSections.LocalModels);
    }

    [Fact]
    public void LocalModelsFollowsAFinishedDownloadWithoutReopening()
    {
        var row = new LocalModelRowState(false);
        Assert.Equal(("Not installed.", "Download"), (row.Status, row.Action));
        Assert.Equal("Model installed and verified.", row.Finish(removed: false));
        Assert.Equal(("Installed and verified.", "Remove"), (row.Status, row.Action));
        Assert.Equal("Removing whisper-small.en-q5_1", row.ProgressName(SmallEn));
        Assert.Equal("Model removed.", row.Finish(removed: true));
        Assert.False(row.Installed);
        var settings = AppFile("SettingsWindow.xaml.cs");
        Assert.DoesNotContain("Reopen Local Models", settings);
        Assert.Contains("Ui.Show(notice, row.Finish(removed: available));", settings);
        Assert.Contains("status.Text = row.Status; action!.Content = row.Action;", settings);
        Assert.Contains("App.Services.NotifyModelsChanged()", settings);
    }

    [Fact]
    public void AnOpenLocalModelsPageFollowsDownloadsMadeElsewhere()
    {
        // A model installed from the Transcribe dialog turns its open row into "Installed and verified." / Remove, and back.
        var row = new LocalModelRowState(false);
        Assert.False(row.Follow([new InstalledModel(Turbo, "unused", false, null)], Turbo));
        Assert.False(row.Follow([new InstalledModel(TalTech, "unused", true, null)], Turbo));
        Assert.True(row.Follow([new InstalledModel(Turbo, "unused", true, null)], Turbo));
        Assert.Equal(("Installed and verified.", "Remove"), (row.Status, row.Action));
        Assert.False(row.Follow([new InstalledModel(Turbo, "unused", true, null)], Turbo));
        // The row's own download finishing after a change elsewhere still ends installed.
        Assert.Equal("Model installed and verified.", row.Finish(removed: false));
        Assert.True(row.Installed);
        Assert.True(row.Follow([], Turbo));
        Assert.Equal(("Not installed.", "Download"), (row.Status, row.Action));
        var settings = AppFile("SettingsWindow.xaml.cs");
        Assert.Contains("App.Services.ModelsChanged += ModelsChanged;", settings);
        Assert.Contains("App.Services.ModelsChanged -= ModelsChanged;", settings);
        Ordered(settings, "voiceLabPane = null; followModels = null;", "case \"Local Models\": await ModelsAsync(); break;");
        Ordered(settings, "private async Task ModelsAsync()", "rows.Add(list => { if (row.Follow(list, model.Id)) Redraw(); });", "followModels = async () =>",
            "await App.Services.Downloads.ListInstalledAsync(lifetime.Token);", "if (page != pageGeneration || refresh != modelRefreshes", "foreach (var follow in rows) follow(now);");
    }

    [Fact]
    public void CancellingADownloadInTheDialogStopsOnlyTheDownloadAndReturnsToTheSetup()
    {
        var dialog = AppFile("Controls/TranscriptionDialog.cs");
        // Cancel or Esc during a download cancels its own source, not the dialog's lifetime.
        Ordered(dialog, "Closing += (_, args) =>", "if (!running) return;", "if (downloading is { } download) download.Cancel(); else lifetime.Cancel();",
            "args.Cancel = true;");
        var download = dialog[dialog.IndexOf("private async Task DownloadAsync", StringComparison.Ordinal)..];
        Ordered(download, "CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);", "downloading = cancellation;",
            "ReferenceEquals(downloading, cancellation)) Ui.Show(consentNotice", "}), cancellation.Token);",
            "catch (OperationCanceledException) when (cancellation.IsCancellationRequested && !lifetime.IsCancellationRequested) { cancelled = true; }",
            "finally { running = false; downloading = null; }", "ShowSetup();", "if (cancelled) { consentNotice.IsOpen = false; return; }");
        // The licence and consent pages share one notice; it leaves the old page first, so Download works again after Cancel.
        Assert.Equal(2, System.Text.RegularExpressions.Regex.Matches(dialog, @"page\.Children\.Add\(DetachedConsentNotice\(\)\)").Count);
        Assert.DoesNotContain("page.Children.Add(consentNotice)", dialog);
        Assert.Contains("if (consentNotice.Parent is Panel previous) previous.Children.Remove(consentNotice);", dialog);
    }

    [Fact]
    public async Task AnEightGigabytePcIsNotLowMemory()
    {
        var root = await new ModelCatalog().RootAsync(TestContext.Current.CancellationToken);
        var threshold = root.GetProperty("defaults").GetProperty("lowMemoryThresholdBytes").GetInt64();
        Assert.Equal(8L << 30, threshold);
        // "8.00 GB (7.8 GB usable)": Windows' installed figure wins; without it the usable figure is rounded up to a whole GiB.
        var usable = (long)(7.8 * (1L << 30));
        var installed = TranscriptionRouting.InstalledMemory(8L << 20, usable);
        Assert.Equal(8L << 30, installed);
        Assert.Equal(8L << 30, TranscriptionRouting.InstalledMemory(null, usable));
        Assert.Equal(8L << 30, TranscriptionRouting.InstalledMemory(0, usable));
        Assert.Equal(16L << 30, TranscriptionRouting.InstalledMemory(16L << 20, usable));
        Assert.Equal(4L << 30, TranscriptionRouting.InstalledMemory(null, (long)(3.6 * (1L << 30))));
        Assert.Equal(0, TranscriptionRouting.InstalledMemory(null, 0));
        Assert.True(TranscriptionRouting.InstalledMemoryBytes > 0);
        // An 8 GB PC gets the regular downloads; only less than 8 GB gets the low-memory ones (§11.2).
        Assert.Equal(Turbo, TranscriptionRouting.RecommendedDownload(root, "en", installed));
        Assert.Equal(TalTech, TranscriptionRouting.RecommendedDownload(root, "et", installed));
        Assert.Equal(Turbo, (await Route(new Installed(TalTech, Vad), "en", ram: installed)).Download!.Id);
        Assert.Equal(SmallEn, (await Route(new Installed(TalTech, Vad), "en", ram: TranscriptionRouting.InstalledMemory(6L << 20, usable))).Download!.Id);
        Assert.Contains("TranscriptionRouting.InstalledMemoryBytes", AppFile("Controls/TranscriptionDialog.cs"));
        Assert.Contains("TranscriptionRouting.InstalledMemoryBytes", AppFile("Controls/OnboardingDialog.cs"));
        Assert.Contains("GetPhysicallyInstalledSystemMemory(out var kilobytes)", AppFile("ViewModels/TranscriptionRouting.cs"));
    }

    private static void Ordered(string text, params string[] markers)
    {
        var at = 0;
        foreach (var marker in markers)
        {
            var next = text.IndexOf(marker, at, StringComparison.Ordinal);
            Assert.True(next >= 0, "Missing or out of order: " + marker);
            at = next + marker.Length;
        }
    }

    private static string AppRoot => Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App");
    private static string AppFile(string file) => File.ReadAllText(Path.Combine(AppRoot, file));
}
#endif
