using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;

namespace VoxClip.App.Controls;

internal sealed class OnboardingDialog : ContentDialog
{
    private readonly MainWindow owner;
    private readonly StackPanel body = Ui.Stack(16);
    private readonly InfoBar notice = Ui.Notice();
    private readonly CancellationTokenSource lifetime = new();
    private readonly ComboBox engine = Ui.Choice("How should VoxClip transcribe?", ["On this PC · private and free", "ElevenLabs Scribe · sends the audio track"]);
    private readonly TextBox language = new() { Header = "Language", PlaceholderText = "auto or a language code, such as en" };
    private readonly ComboBox models = Ui.Choice("Local model", []);
    private readonly TextBlock modelTerms = Ui.Text("Choose a model to see its licence and download size.", "HelperText");
    private readonly Expander modelDetails;
    private readonly CheckBox modelApproval = new() { Content = "I accept this model's licence and want to download it." };
    private readonly ComboBox connector = Ui.Choice("AI connector (optional)", []);
    private readonly CheckBox consent = new() { Content = "I understand what this connector sends and want to use it." };
    private IReadOnlyList<TranscriptionModel> catalogue = [];
    private System.Text.Json.JsonElement? catalogueRoot;
    private bool preselecting;
    private bool modelChosen;
    private int step;
    private int rendered = -1;
    private bool downloading;

    internal OnboardingDialog(MainWindow owner)
    {
        this.owner = owner;
        modelDetails = new Expander { Header = "Model licence and attribution", Content = modelTerms };
        Title = "Welcome to VoxClip";
        CloseButtonText = "Skip";
        connector.PlaceholderText = "Choose a connector…";
        language.Text = App.Services.Get("transcription.language", "auto");
        engine.SelectedIndex = App.Services.Get("transcription.engineMode", "local") == "elevenlabs" ? 1 : 0;
        engine.SelectionChanged += (_, _) => Render();
        models.SelectionChanged += (_, _) =>
        {
            modelChosen |= !preselecting;
            modelApproval.IsChecked = false;
            if ((models.SelectedItem as ComboBoxItem)?.Tag is TranscriptionModel model)
            {
                var dependencies = ModelDownloadCopy.Dependencies(model, catalogue);
                modelTerms.Text = $"{ModelDownloadCopy.Title(model)}\n{ModelDownloadCopy.Body(model, dependencies)}\n{model.LicenseUrl}";
                modelApproval.Content = $"I accept the {model.License} licence for {ModelDownloadCopy.DisplayName(model)} and want to download it ({ModelDownloadCopy.Size(model, dependencies)}).";
            }
        };
        connector.SelectionChanged += (_, _) => { consent.IsChecked = false; Render(); };
        language.TextChanged += (_, _) => { if (!modelChosen) PreselectRecommended(); };
        Content = new ScrollViewer { Content = body, MinWidth = 480, MaxHeight = 480 };
        Opened += async (_, _) => await Ui.RunAsync(notice, LoadChoicesAsync, "Welcome tour");
        PrimaryButtonClick += Continue;
        SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (step == 1) { step = 2; Render(); }
            else if (step == 2) { await CompleteAsync(); Hide(); await Task.Delay(100); await owner.ChooseAsync(false); }
        };
        CloseButtonClick += async (_, _) => await CompleteAsync();
        Closed += (_, _) => { lifetime.Cancel(); lifetime.Dispose(); };
        Render();
    }

    private async Task LoadChoicesAsync()
    {
        catalogue = await App.Services.Models.GetModelsAsync(lifetime.Token);
        var installed = await App.Services.Downloads.ListInstalledAsync(lifetime.Token);
        catalogueRoot = await (App.Services.Models as ModelCatalog ?? new ModelCatalog()).RootAsync(lifetime.Token);
        foreach (var model in catalogue.Where(item => item.Listed && item.Engine == TranscriptEngine.Whispercpp))
            models.Items.Add(new ComboBoxItem { Content = $"{ModelDownloadCopy.DisplayName(model)} · {model.TotalBytes / 1_000_000d:0} MB" + (installed.Any(item => item.Id == model.Id && item.Verified) ? " · installed" : ""), Tag = model });
        PreselectRecommended();
        var providers = await ProviderCatalog.ReadAsync(lifetime.Token);
        foreach (var group in new[] { ("apiKey", "Your API key"), ("local", "On this computer"), ("cli", "Installed CLI (your own sign-in)") })
        {
            if (!providers.Any(item => item.Group == group.Item1)) continue;
            connector.Items.Add(new ComboBoxItem { Content = group.Item2, IsEnabled = false });
            foreach (var entry in providers.Where(item => item.Group == group.Item1)) connector.Items.Add(new ComboBoxItem { Content = entry.Label, Tag = entry });
        }
        Render();
    }

    /// <summary>Preselect the model transcription §11.2 recommends for the tour's language (Whisper large-v3-turbo for auto and
    /// English, TalTech only for Estonian; the low-memory download under 8 GB), until the user picks one.</summary>
    private void PreselectRecommended()
    {
        if (catalogueRoot is not { } root || models.Items.Count == 0) return;
        var id = TranscriptionRouting.RecommendedDownload(root, language.Text, TranscriptionRouting.InstalledMemoryBytes);
        preselecting = true;
        try { models.SelectedItem = models.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (item.Tag as TranscriptionModel)?.Id == id) ?? models.Items[0]; }
        finally { preselecting = false; }
    }

    private void Render()
    {
        var lead = step switch { 0 => engine, 1 => connector, _ => (ComboBox?)null };
        var keep = rendered == step && lead is not null && body.Children.Count > 2 && body.Children[2] == lead ? 3 : 0;
        rendered = step;
        while (body.Children.Count > keep) body.Children.RemoveAt(body.Children.Count - 1);
        if (keep == 0)
        {
            body.Children.Add(Ui.Text($"Step {step + 1} of 3", "HelperText"));
            body.Children.Add(Ui.Text(step switch { 0 => "Cut video by its words.", 1 => "Find clips with AI (optional)", _ => "Five keys to know" }, "SubtitleTextBlockStyle"));
            if (lead is not null) body.Children.Add(lead);
        }
        if (step == 0)
        {
            body.Children.Add(Ui.Text(engine.SelectedIndex == 1
                ? "ElevenLabs keeps the audio under its terms. No upload happens until you confirm for a take."
                : "Audio stays on this PC. A local model is downloaded only when you choose to download it.", "HelperText"));
            body.Children.Add(language);
            if (engine.SelectedIndex == 0)
            {
                body.Children.Add(models);
                body.Children.Add(modelDetails);
                body.Children.Add(modelApproval);
                body.Children.Add(Ui.Button("Download selected model now", () => _ = Ui.RunAsync(notice, DownloadAsync, "Model download")));
                body.Children.Add(Ui.Text("You can also download a model later in Settings → Local Models.", "HelperText"));
            }
            else
            {
                AddKeyRow("elevenlabs-api-key", "ElevenLabs");
                body.Children.Add(Ui.Button("Test ElevenLabs key", () => _ = Ui.RunAsync(notice, async () =>
                {
                    using var transcriber = VoxClip.Core.Services.Speech.ElevenLabsTranscriber.FromSettings(App.Services.Keys, App.Services.Settings, App.Services.Log);
                    var result = await transcriber.TestKeyAsync(lifetime.Token);
                    Ui.Show(notice, result.Message, result.CanReadAccountDetails ? InfoBarSeverity.Success : InfoBarSeverity.Warning);
                }, "Connection test")));
            }
        }
        else if (step == 1)
        {
            if ((connector.SelectedItem as ComboBoxItem)?.Tag is ProviderEntry entry)
            {
                body.Children.Add(Ui.Text(entry.DataFlow, "HelperText"));
                if (entry.Account is { } account) AddKeyRow(account, entry.Label);
                if (entry.Cloud || entry.Cli) body.Children.Add(consent);
                body.Children.Add(Ui.Button("Check status", () => _ = Ui.RunAsync(notice, async () =>
                    Ui.Show(notice, ProviderCatalog.Status(await App.Services.Connector(entry.Id).GetStatusAsync(lifetime.Token))), "Connector status")));
                body.Children.Add(Ui.Button("Test connector in Settings…", () =>
                {
                    Hide();
                    App.OpenSettings("Providers & Keys");
                }));
            }
            else body.Children.Add(Ui.Text("Sends transcript text only when you choose an external connector. No audio or video. You can always make clips yourself: select words, press Ctrl+K.", "HelperText"));
        }
        else
        {
            body.Children.Add(Ui.Text("Space  Play or pause\nDelete  Cut selected words\nCtrl+Z  Undo\nJ K L  Shuttle\nCtrl+E  Export"));
            body.Children.Add(Ui.Text("Local first. No account required. No telemetry.", "HelperText"));
        }
        body.Children.Add(notice);
        PrimaryButtonText = step == 2 ? "Done" : "Continue";
        IsPrimaryButtonEnabled = step != 1 || (connector.SelectedItem as ComboBoxItem)?.Tag is ProviderEntry;
        SecondaryButtonText = step == 1 ? "Not now" : step == 2 ? "Open a video…" : "";
        DefaultButton = step == 1 ? ContentDialogButton.Secondary : ContentDialogButton.Primary;
    }

    private void AddKeyRow(string account, string label)
    {
        var key = new PasswordBox { Header = label + " API key", PasswordRevealMode = PasswordRevealMode.Hidden, PlaceholderText = "Paste a key to save for your Windows account" };
        body.Children.Add(key);
        var save = Ui.Button("Save key", () => _ = Ui.RunAsync(notice, async () =>
        {
            var secret = key.Password;
            key.Password = "";
            if (string.IsNullOrWhiteSpace(secret)) return;
            await App.Services.Keys.SaveAsync(account, secret, lifetime.Token);
            Ui.Show(notice, "Key saved securely.", InfoBarSeverity.Success);
        }, "Save key"));
        save.IsEnabled = false;
        key.PasswordChanged += (_, _) => save.IsEnabled = !string.IsNullOrWhiteSpace(key.Password);
        body.Children.Add(save);
    }

    private async Task DownloadAsync()
    {
        if (downloading || (models.SelectedItem as ComboBoxItem)?.Tag is not TranscriptionModel model) return;
        if (modelApproval.IsChecked != true) { Ui.Show(notice, "Accept the displayed model licence before downloading.", InfoBarSeverity.Warning); return; }
        var approved = ModelDownloadCopy.Body(model, ModelDownloadCopy.Dependencies(model, catalogue));
        Task<bool> Confirm(TranscriptionModel candidate, IReadOnlyList<TranscriptionModel> dependencies, CancellationToken _) =>
            candidate.Id == model.Id && ModelDownloadCopy.Body(candidate, dependencies) == approved ? Task.FromResult(true)
                : throw new InvalidOperationException("The model download no longer matches the licence shown.");
        downloading = true;
        try
        {
            await App.Services.Installer(Confirm).InstallAsync(model.Id, new Progress<ModelDownloadProgress>(value => Ui.Show(notice, ModelDownloadCopy.Progress(model, value))), lifetime.Token);
            Ui.Show(notice, "Model installed and verified.", InfoBarSeverity.Success);
        }
        finally { downloading = false; }
    }

    private async void Continue(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        if (downloading) return;
        await Ui.RunAsync(notice, async () =>
        {
            if (step == 0)
            {
                var code = language.Text.Trim().ToLowerInvariant();
                if (code.Length == 0) code = "auto";
                if (code != "auto" && (code.Length is < 2 or > 3 || !code.All(char.IsAsciiLetterLower)))
                { Ui.Show(notice, "Enter auto or a two or three letter language code.", InfoBarSeverity.Warning); language.Focus(FocusState.Programmatic); return; }
                await App.Services.SetAsync("transcription.engineMode", engine.SelectedIndex == 1 ? "elevenlabs" : "local", lifetime.Token);
                await App.Services.SetAsync("transcription.language", code, lifetime.Token);
            }
            if (step == 1 && (connector.SelectedItem as ComboBoxItem)?.Tag is ProviderEntry entry)
            {
                if ((entry.Cloud || entry.Cli) && consent.IsChecked != true)
                { Ui.Show(notice, "Confirm the connector's data flow before continuing.", InfoBarSeverity.Warning); consent.Focus(FocusState.Programmatic); return; }
                await App.Services.SetAsync("llm.connector", entry.WireId, lifetime.Token);
            }
            else if (step == 1) return;
            if (step == 2) { await CompleteAsync(); Hide(); }
            else { step++; Render(); }
        }, "Welcome tour");
    }

    private async Task CompleteAsync()
    {
        try { await App.Services.SetAsync("onboarding.completed", true, lifetime.Token); }
        catch (Exception exception) { owner.ShowError(exception, "Settings"); }
    }
}
