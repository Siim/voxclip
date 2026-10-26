using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.App.Controls;

internal sealed class TranscriptionDialog : ContentDialog
{
    private readonly EditorViewModel model;
    private readonly ComboBox engine = Ui.Choice("Engine", ["Local Whisper · on this computer", "ElevenLabs · sends the audio track"]);
    private readonly ComboBox models = Ui.Choice("Local model", []);
    private readonly TextBox language = new() { Header = "Language", PlaceholderText = "Auto-detect (or a language code, such as en)" };
    private readonly InfoBar notice = Ui.Notice();
    private readonly TextBlock flow = Ui.Text("Audio stays on this computer. No key or account is needed.", "HelperText");
    private readonly ProgressBar progress = new() { Visibility = Visibility.Collapsed };
    private readonly CheckBox cloudConsent = new() { Content = "I understand and want to send this audio to ElevenLabs.", Visibility = Visibility.Collapsed };
    private readonly StackPanel cloudKeyRow = Ui.Stack(8);
    private readonly TextBlock cloudKeyStatus = Ui.Text("Checking ElevenLabs key…", "HelperText");
    private readonly PasswordBox cloudKey = new() { Header = "ElevenLabs API key", PasswordRevealMode = PasswordRevealMode.Hidden, PlaceholderText = "Paste a key to save for your Windows account" };
    private readonly CancellationTokenSource lifetime = new();
    private bool running;

    internal TranscriptionDialog(MainWindow owner, EditorViewModel model)
    {
        this.model = model; Title = model.HasTranscript ? "Transcribe again" : "Transcribe video";
        PrimaryButtonText = "Transcribe"; CloseButtonText = "Not now";
        engine.SelectedIndex = App.Services.Get("transcription.engineMode", "local") == "elevenlabs" ? 1 : 0;
        var savedLanguage = App.Services.Get("transcription.language", "auto");
        language.Text = savedLanguage == "auto" ? "" : savedLanguage;
        var body = Ui.Stack(16); body.MinWidth = 400;
        body.Children.Add(Ui.Text("Choose how to transcribe. There is no automatic cloud fallback."));
        body.Children.Add(engine); body.Children.Add(flow); body.Children.Add(models); body.Children.Add(language);
        cloudKeyRow.Children.Add(cloudKeyStatus); cloudKeyRow.Children.Add(cloudKey);
        var saveCloudKey = Ui.Button("Save key", () => _ = Ui.RunAsync(notice, SaveCloudKeyAsync, "Save key"));
        saveCloudKey.IsEnabled = false;
        cloudKey.PasswordChanged += (_, _) => saveCloudKey.IsEnabled = !string.IsNullOrWhiteSpace(cloudKey.Password);
        cloudKeyRow.Children.Add(saveCloudKey); body.Children.Add(cloudKeyRow);
        body.Children.Add(cloudConsent);
        body.Children.Add(Ui.Button("Manage local models…", App.OpenSettings)); body.Children.Add(progress); body.Children.Add(notice);
        Content = new ScrollViewer { Content = body, MaxHeight = 600 };
        cloudConsent.IsChecked = false;
        engine.SelectionChanged += (_, _) => UpdateEngine();
        UpdateEngine();
        Opened += async (_, _) => await Ui.RunAsync(notice, async () =>
        {
            await RefreshCloudKeyAsync();
            var catalogue = await App.Services.Models.GetModelsAsync(lifetime.Token);
            var installed = await App.Services.Downloads.ListInstalledAsync(lifetime.Token);
            var requestedLanguage = language.Text.Trim().ToLowerInvariant();
            var available = catalogue.Where(entry => entry.Engine == TranscriptEngine.Whispercpp && installed.Any(item => item.Id == entry.Id && item.Verified)).ToArray();
            foreach (var entry in available) models.Items.Add(entry.Id);
            if (available.Length > 0)
            {
                var routed = requestedLanguage.Length == 0
                    ? available.FirstOrDefault(entry => entry.Languages.Contains("*"))
                    : available.FirstOrDefault(entry => entry.ForcedLanguage == requestedLanguage)
                        ?? available.FirstOrDefault(entry => entry.Languages.Contains(requestedLanguage) || entry.Languages.Contains("*"));
                models.SelectedIndex = Math.Max(0, Array.FindIndex(available, entry => entry.Id == routed?.Id));
                if (requestedLanguage.Length > 0 && routed is null && engine.SelectedIndex == 0)
                    Ui.Show(notice, "No installed local model supports this language. Choose another model or download one in Settings → Local Models.", InfoBarSeverity.Warning);
            }
            else if (engine.SelectedIndex == 0) Ui.Show(notice, "No local model installed. Download one in Settings → Local Models.");
        }, "Local models");
        PrimaryButtonClick += Transcribe;
        Closing += (_, args) => { if (running) { lifetime.Cancel(); args.Cancel = true; } };
        Closed += (_, _) => lifetime.Dispose();
    }
    private void UpdateEngine()
    {
        var cloud = engine.SelectedIndex == 1;
        models.Visibility = cloud ? Visibility.Collapsed : Visibility.Visible;
        cloudKeyRow.Visibility = cloud ? Visibility.Visible : Visibility.Collapsed;
        cloudConsent.Visibility = cloud ? Visibility.Visible : Visibility.Collapsed;
        flow.Text = cloud
            ? "ElevenLabs Scribe uploads this take's audio track with your key. ElevenLabs stores it under its terms and may use it to improve its services unless you opt out in your ElevenLabs account. No video is sent."
            : "Audio stays on this computer. No key or account is needed.";
    }
    private async Task RefreshCloudKeyAsync()
    {
        var saved = await App.Services.Keys.GetKeyAsync("elevenlabs-api-key", lifetime.Token) is not null;
        cloudKeyStatus.Text = saved ? "Key saved for your Windows account. Confirm this take's upload to continue." : "Add an ElevenLabs key here before uploading this take.";
        cloudKey.PlaceholderText = saved ? "Saved for your Windows account; paste to replace" : "Paste an API key";
    }
    private async Task SaveCloudKeyAsync()
    {
        var secret = cloudKey.Password;
        cloudKey.Password = "";
        if (string.IsNullOrWhiteSpace(secret)) return;
        await App.Services.Keys.SaveAsync("elevenlabs-api-key", secret, lifetime.Token);
        await RefreshCloudKeyAsync();
        Ui.Show(notice, "Key saved securely. Audio is sent only after you confirm and choose Transcribe.");
    }
    private async void Transcribe(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        await RunTranscriptionAsync();
    }
    private async Task RunTranscriptionAsync()
    {
        if (running || model.IsLeaving) return;
        await Ui.RunAsync(notice, async () =>
        {
            if (engine.SelectedIndex == 0 && models.SelectedItem is null) { Ui.Show(notice, "Download a local model first. Your video is still here."); return; }
            if (engine.SelectedIndex == 1)
            {
                if (await App.Services.Keys.GetKeyAsync("elevenlabs-api-key", lifetime.Token) is null) { Ui.Show(notice, "Add an ElevenLabs key here before uploading this take."); cloudKey.Focus(FocusState.Programmatic); return; }
                if (cloudConsent.IsChecked != true) { Ui.Show(notice, "Confirm the audio upload before continuing."); return; }
            }
            if (model.IsLeaving) return;
            running = true; model.Busy = true; App.Services.BusyOperations++; IsPrimaryButtonEnabled = false; progress.Visibility = Visibility.Visible;
            try
            {
                var source = model.Project.Media.Source;
                var media = await App.Services.Probe.ProbeAsync(source.AbsolutePath, lifetime.Token);
                var audio = await App.Services.Audio.ExtractAsync(new(media, source.ContentKey, App.Services.Data.Cache), null, lifetime.Token);
                var requestedLanguage = language.Text.Trim().ToLowerInvariant();
                var plan = new TranscriptionPlan(engine.SelectedIndex == 0 ? TranscriptEngine.Whispercpp : TranscriptEngine.Elevenlabs,
                    models.SelectedItem as string, requestedLanguage.Length == 0 || requestedLanguage == "auto" ? new LanguageChoice.Auto() : new LanguageChoice.Forced(requestedLanguage), new());
                var transcript = await App.Services.Transcription.TranscribeAsync(new(plan, audio.Audio, source.ContentKey), new Progress<TranscriptionProgress>(value =>
                { progress.IsIndeterminate = value.Fraction is null; progress.Value = (value.Fraction ?? 0) * 100; Ui.Show(notice, value.Stage.ToString()); }), lifetime.Token);
                if (model.IsLeaving) return;
                model.SetTranscript(transcript);
            }
            finally { running = false; model.Busy = false; App.Services.BusyOperations--; IsPrimaryButtonEnabled = !lifetime.IsCancellationRequested; progress.Visibility = Visibility.Collapsed; }
            Hide();
        }, "Transcription");
    }
}
