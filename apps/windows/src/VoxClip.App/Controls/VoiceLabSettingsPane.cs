using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Services.Settings;
using Microsoft.UI.Text;

namespace VoxClip.App.Controls;

internal sealed class VoiceLabSettingsPane : UserControl
{
    private readonly SettingsWindow owner;
    private readonly CancellationTokenSource lifetime;
    private readonly CancellationToken token;
    private readonly StackPanel body = Ui.Stack(20);
    private readonly StackPanel enabledContent = Ui.Stack(20);
    private readonly InfoBar message = Ui.Notice();
    private readonly ToggleSwitch enabled = new() { Header = "Show Voice Lab (beta)" };
    private readonly TextBlock beta = Ui.Text("Beta");
    private readonly Border betaTag = new() { BorderThickness = new Thickness(1), Padding = new Thickness(6, 2, 6, 2), VerticalAlignment = VerticalAlignment.Center };
    private bool updating;
    private bool keysLoaded;

    internal VoiceLabSettingsPane(SettingsWindow owner, CancellationToken ct)
    {
        this.owner = owner;
        lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        token = lifetime.Token;
        Content = body;
        var title = Ui.Stack(8); title.Orientation = Orientation.Horizontal;
        var heading = Ui.Text("Voice Lab", "TitleTextBlockStyle");
        AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level1);
        title.Children.Add(heading);
        beta.FontSize = 11; betaTag.Child = beta; title.Children.Add(betaTag); body.Children.Add(title);
        AutomationProperties.SetAutomationId(message, "voice-lab-message");
        message.RegisterPropertyChangedCallback(InfoBar.MessageProperty, (_, _) =>
        {
            Ui.Announce(message, message.Message, "voice-lab-message");
            DispatcherQueue.TryEnqueue(() => { if (message.IsLoaded && message.IsOpen) message.StartBringIntoView(); });
        });
        body.Children.Add(message);
        AutomationProperties.SetName(enabled, "Show Voice Lab (beta)");
        AutomationProperties.SetHelpText(enabled, VoiceLabCopy.ToggleCaption);
        body.Children.Add(enabled); body.Children.Add(Ui.Text(VoiceLabCopy.ToggleCaption, "HelperText"));
        body.Children.Add(enabledContent);
        enabled.Toggled += (_, _) =>
        {
            if (updating) return;
            var turnOn = enabled.IsOn;
            owner.RunSensitive(async () =>
            {
                enabled.IsEnabled = false;
                try
                {
                    await Ui.RunAsync(message, async () =>
                    {
                        if (turnOn) await VoiceLabDialogs.TurnOnAsync(XamlRoot, token);
                        else await App.Services.SetAsync("voiceLab.enabled", false, token);
                    }, "Voice Lab");
                }
                finally { Refresh(); enabled.IsEnabled = true; }
            }, "Voice Lab");
        };
        AddExports(); AddStorage();
        Loaded += (_, _) => { RefreshTheme(); Refresh(); };
        ActualThemeChanged += (_, _) => RefreshTheme();
        Ui.EffectsChanged += EffectsChanged;
        Unloaded += (_, _) => { Ui.EffectsChanged -= EffectsChanged; lifetime.Cancel(); lifetime.Dispose(); };
        Refresh();
    }

    internal void Refresh()
    {
        updating = true;
        try { enabled.IsOn = App.Services.Settings.GetBool("voiceLab.enabled") == true; }
        finally { updating = false; }
        enabledContent.Visibility = enabled.IsOn ? Visibility.Visible : Visibility.Collapsed;
        if (!enabled.IsOn || keysLoaded) return;
        keysLoaded = true;
        _ = Ui.RunAsync(message, AddKeysAsync, "Voice Lab keys");
    }
    private void EffectsChanged(object? sender, EventArgs args) => RefreshTheme();
    private void RefreshTheme()
    {
        beta.Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush");
        betaTag.BorderBrush = Ui.ThemeBrush(this, "VcLineStrongBrush");
    }
    private static SettingsExpander Section(string name)
    {
        var heading = Ui.Text(name); heading.FontWeight = FontWeights.SemiBold;
        AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level2);
        var section = new SettingsExpander { Header = heading, IsExpanded = true, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(section, name);
        return section;
    }
    private static void AddCard(SettingsExpander section, FrameworkElement content) =>
        section.Items.Add(new SettingsCard { Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch });
    private static TextBlock Selectable(string text)
    {
        var block = Ui.Text(text, "HelperText"); block.IsTextSelectionEnabled = true; return block;
    }
    private async Task AddKeysAsync()
    {
        var section = Section("Your API keys");
        enabledContent.Children.Insert(0, section);
        foreach (var provider in new[] { ("ElevenLabs", "elevenlabs-api-key"), ("fal.ai", "fal-api-key"), ("sync.so", "syncso-api-key") })
        {
            var panel = Ui.Stack();
            var hasKey = false;
            var unreadable = false;
            try { hasKey = await App.Services.Keys.GetKeyAsync(provider.Item2, token) is not null; }
            catch (Exception exception) when (exception is not OperationCanceledException) { hasKey = true; unreadable = true; }
            token.ThrowIfCancellationRequested();
            var status = Ui.Text(unreadable ? "This saved key can't be read. Forget it, then save a new key. Your media and edits are still here." : hasKey ? "Key saved securely." : "No key saved.", "HelperText");
            var key = new PasswordBox { Header = provider.Item1 + " API key", PasswordRevealMode = PasswordRevealMode.Hidden,
                PlaceholderText = hasKey ? "Saved for your Windows account; paste to replace" : "API key" };
            AutomationProperties.SetName(key, provider.Item1 + " API key");
            panel.Children.Add(key);
            var buttons = Ui.Stack(8); buttons.Orientation = Orientation.Horizontal;
            Button? forget = null;
            var save = Ui.Button("Save key", () => owner.RunSensitive(async () =>
            {
                await Ui.RunAsync(message, async () =>
                {
                    var secret = key.Password; key.Password = "";
                    if (string.IsNullOrWhiteSpace(secret)) return;
                    await owner.SaveKeyAsync(provider.Item2, secret, token);
                    status.Text = "Key saved securely.";
                    key.PlaceholderText = "Saved for your Windows account; paste to replace";
                    if (forget is not null) forget.Visibility = Visibility.Visible;
                    Ui.Announce(status, status.Text, "voice-lab-key");
                }, "Save key");
            }, "Save key"));
            AutomationProperties.SetName(save, "Save " + provider.Item1 + " key");
            save.IsEnabled = false;
            key.PasswordChanged += (_, _) => save.IsEnabled = !string.IsNullOrWhiteSpace(key.Password);
            forget = Ui.Button("Forget key", () => owner.RunSensitive(async () =>
            {
                await Ui.RunAsync(message, async () =>
                {
                    await owner.SaveKeyAsync(provider.Item2, "", token);
                    key.Password = ""; key.PlaceholderText = "API key"; status.Text = "Key forgotten.";
                    key.Focus(FocusState.Programmatic);
                    if (forget is not null) forget.Visibility = Visibility.Collapsed;
                    Ui.Announce(status, status.Text, "voice-lab-key");
                }, "Forget key");
            }, "Forget key"));
            AutomationProperties.SetName(forget, "Forget " + provider.Item1 + " key");
            forget.Visibility = hasKey ? Visibility.Visible : Visibility.Collapsed;
            buttons.Children.Add(save); buttons.Children.Add(forget);
            panel.Children.Add(buttons); panel.Children.Add(status); panel.Children.Add(Ui.Text(VoiceLabCopy.KeyFootnote, "HelperText"));
            AddCard(section, panel);
        }
        var guidance = Ui.Stack(); guidance.Children.Add(Selectable(VoiceLabCopy.KeyGuidance)); guidance.Children.Add(Selectable(VoiceLabCopy.KeyPermissions));
        AddCard(section, guidance);
    }
    private void AddExports()
    {
        var section = Section("Exports and spending"); enabledContent.Children.Add(section);
        foreach (var provider in new[] { ("elevenlabs", "ElevenLabs"), ("fal", "fal.ai"), ("syncso", "sync.so") })
        {
            var header = "Warn me above this amount a month · " + provider.Item2;
            var field = new TextBox { Header = header, PlaceholderText = "No limit",
                Text = App.Services.Settings.GetString("voiceLab.monthlyCapUsd." + provider.Item1) ?? "",
                InputScope = new Microsoft.UI.Xaml.Input.InputScope { Names = { new Microsoft.UI.Xaml.Input.InputScopeName { NameValue = Microsoft.UI.Xaml.Input.InputScopeNameValue.Number } } } };
            AutomationProperties.SetName(field, header);
            owner.TrackTextField(field, () =>
            {
                var parsed = VoiceLabSettingsState.MonthlyCap(field.Text);
                if (parsed.Error is { } error) { Ui.Show(message, error, InfoBarSeverity.Warning); return false; }
                var settings = new AppSettings("voxclip-settings/1");
                settings.SetVoiceLabMonthlyCap(provider.Item1, parsed.Amount);
                _ = Ui.RunAsync(message, () => App.Services.SetAsync("voiceLab.monthlyCapUsd." + provider.Item1,
                    settings.GetString("voiceLab.monthlyCapUsd." + provider.Item1), token), "Save spending cap");
                return true;
            });
            AddCard(section, field);
        }
        var positions = VoiceLabSettingsState.LabelChoices;
        var position = Ui.Choice("Label position", positions.Select(choice => choice.Label),
            Math.Max(0, positions.ToList().FindIndex(choice => choice.Key == App.Services.Settings.GetString("voiceLab.labelPosition"))));
        AutomationProperties.SetName(position, "Label position");
        position.SelectionChanged += (_, _) => owner.RunSensitive(() => Ui.RunAsync(message,
            () => App.Services.SetAsync("voiceLab.labelPosition", positions[position.SelectedIndex].Key, token), "Save label position"), "Save label position");
        var label = Ui.Stack(); label.Children.Add(position); label.Children.Add(Ui.Text(VoiceLabCopy.LabelHelper, "HelperText")); AddCard(section, label);
        var c2pa = new ToggleSwitch { Header = "Add Content Credentials (C2PA) to exports", IsOn = App.Services.Settings.GetBool("voiceLab.c2pa") ?? true };
        AutomationProperties.SetName(c2pa, "Add Content Credentials (C2PA) to exports");
        AutomationProperties.SetHelpText(c2pa, VoiceLabCopy.C2paHelper);
        c2pa.Toggled += (_, _) => owner.RunSensitive(() => Ui.RunAsync(message,
            () => App.Services.SetAsync("voiceLab.c2pa", c2pa.IsOn, token), "Save Content Credentials preference"), "Save Content Credentials preference");
        var credentials = Ui.Stack(); credentials.Children.Add(c2pa); credentials.Children.Add(Ui.Text(VoiceLabCopy.C2paHelper, "HelperText")); AddCard(section, credentials);
    }
    private void AddStorage()
    {
        var section = Section("Storage"); enabledContent.Children.Add(section);
        var panel = Ui.Stack(); panel.Children.Add(Ui.Text(VoiceLabCopy.Storage, "HelperText"));
        var path = Path.Combine(App.Services.Data.Root, "VoiceLab"); panel.Children.Add(Selectable(path));
        var reveal = Ui.Button("Show in File Explorer", () => ShareHelpers.Reveal(path));
        AutomationProperties.SetName(reveal, "Show in File Explorer");
        reveal.IsEnabled = Directory.Exists(path);
        if (!reveal.IsEnabled) AutomationProperties.SetHelpText(reveal, VoiceLabCopy.EmptyStorage);
        panel.Children.Add(reveal); AddCard(section, panel);
    }
}
