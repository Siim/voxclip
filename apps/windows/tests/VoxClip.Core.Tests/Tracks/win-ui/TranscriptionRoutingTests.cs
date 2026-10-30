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
        var run = dialog[dialog.IndexOf("private async Task RunTranscriptionAsync", StringComparison.Ordinal)..];
        Assert.True(run.IndexOf("await RouteAsync(null)", StringComparison.Ordinal) < run.IndexOf("ExtractAudioAsync", StringComparison.Ordinal));
        Assert.True(run.IndexOf("ExtractAudioAsync", StringComparison.Ordinal) < run.IndexOf("App.Services.DetectLanguageAsync", StringComparison.Ordinal));
        var settings = System.Xml.Linq.XDocument.Load(Path.Combine(AppRoot, "SettingsWindow.xaml"));
        Assert.Contains(settings.Descendants().Select(element => (string?)element.Attribute("Tag")), tag => tag == SettingsSections.LocalModels);
    }

    [Fact]
    public void LocalModelsFollowsAFinishedDownloadWithoutReopening()
    {
        var row = new LocalModelRowState(false);
        Assert.Equal(("Not installed.", "Download"), (row.Status, row.Action));
        Assert.Equal("Model installed and verified.", row.Finish());
        Assert.Equal(("Installed and verified.", "Remove"), (row.Status, row.Action));
        Assert.Equal("Removing whisper-small.en-q5_1", row.ProgressName(SmallEn));
        Assert.Equal("Model removed.", row.Finish());
        Assert.False(row.Installed);
        var settings = AppFile("SettingsWindow.xaml.cs");
        Assert.DoesNotContain("Reopen Local Models", settings);
        Assert.Contains("status.Text = row.Status; action!.Content = row.Action;", settings);
        Assert.Contains("App.Services.NotifyModelsChanged()", settings);
    }

    private static string AppRoot => Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App");
    private static string AppFile(string file) => File.ReadAllText(Path.Combine(AppRoot, file));
}
#endif
