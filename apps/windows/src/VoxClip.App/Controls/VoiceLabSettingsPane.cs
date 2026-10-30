using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Services.Settings;
using Microsoft.UI.Text;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

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
    private readonly VoiceLabKeyInventory keyInventory;
    private SettingsExpander? keySection;
    private readonly VoiceLabSession session = App.Services.VoiceLab;
    private readonly SettingsExpander ownVoice = Section("Own-voice check · on this PC");
    private readonly SettingsExpander voices = Section("My voices");
    private Button? accountCheck;
    private readonly Dictionary<Guid, TextBlock> operationStates = [];
    private string? focusRecordId;
    private bool initialLoadComplete;

    internal VoiceLabSettingsPane(SettingsWindow owner, CancellationToken ct, string? focusRecordId = null)
    {
        this.owner = owner;
        this.focusRecordId = focusRecordId;
        lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        token = lifetime.Token;
        keyInventory = new(App.Services.Keys, () => App.Services.VoiceLabEnabled, token);
        keyInventory.Changed += (_, _) => RenderKeys();
        Content = body;
        var title = Ui.Stack(8); title.Orientation = Orientation.Horizontal;
        var heading = Ui.Text("Voice Lab", "TitleTextBlockStyle");
        AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level1);
        title.Children.Add(heading);
        beta.FontSize = 11; betaTag.Child = beta; title.Children.Add(betaTag); body.Children.Add(title);
        AutomationProperties.SetAutomationId(message, "voice-lab-message");
        message.RegisterPropertyChangedCallback(InfoBar.MessageProperty, (_, _) =>
        {
            if (message.Message != VoiceLabCopy.CapError) Ui.Announce(message, message.Message, "voice-lab-message");
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
        enabledContent.Children.Add(ownVoice); enabledContent.Children.Add(voices);
        AddExports(); AddStorage();
        Loaded += async (_, _) =>
        {
            session.Changed += SessionChanged;
            RefreshTheme(); Refresh(); RenderSession();
            await session.RefreshEnabledStateAsync();
            initialLoadComplete = true; RenderSession();
        };
        ActualThemeChanged += (_, _) => RefreshTheme();
        Ui.EffectsChanged += EffectsChanged;
        Unloaded += (_, _) => { session.Changed -= SessionChanged; Ui.EffectsChanged -= EffectsChanged; keyInventory.Dispose(); lifetime.Cancel(); lifetime.Dispose(); };
        Refresh();
    }

    internal void Refresh()
    {
        updating = true;
        try { enabled.IsOn = App.Services.VoiceLabEnabled; }
        finally { updating = false; }
        enabledContent.Visibility = App.Services.VoiceLabEnabled ? Visibility.Visible : Visibility.Collapsed;
        _ = Ui.RunAsync(message, () => keyInventory.RefreshAsync(), "Voice Lab keys");
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
    private void RenderKeys()
    {
        if (keySection is not null) enabledContent.Children.Remove(keySection);
        keySection = null;
        accountCheck = null;
        if (!App.Services.VoiceLabEnabled || keyInventory.Rows.Count == 0) return;
        var section = Section("Your API keys");
        keySection = section;
        enabledContent.Children.Insert(0, section);
        foreach (var entry in keyInventory.Rows)
        {
            var provider = (entry.Provider, entry.Account);
            var panel = Ui.Stack();
            var hasKey = entry.Saved;
            var unreadable = entry.Unreadable;
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
                    if (!App.Services.VoiceLabEnabled) return;
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
                    if (!App.Services.VoiceLabEnabled) return;
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
        accountCheck = SessionButton("Check ElevenLabs account", "Check ElevenLabs account",
            () => ConfirmAsync(new(VoiceLabRequestKind.Subscription)));
        AddCard(section, accountCheck);
    }
    private void SessionChanged(object? sender, EventArgs args) => RenderSession();
    private Button SessionButton(string text, string name, Func<Task> action)
    {
        var button = Ui.Button(text, () => owner.RunSensitive(() => Ui.RunAsync(message, action, text), text));
        AutomationProperties.SetName(button, name);
        button.IsEnabled = session.Enabled && !session.Busy;
        return button;
    }
    private async Task ConfirmAsync(VoiceLabRequest request)
    {
        session.Request(request);
        if (session.Confirmation != request) return;
        var title = request.Kind switch
        {
            VoiceLabRequestKind.Subscription => "Check ElevenLabs account",
            VoiceLabRequestKind.Delete => "Delete voice",
            VoiceLabRequestKind.StopLooking => VoiceLabCopy.StopLooking,
            _ => "Remove from VoxClip only"
        };
        var explanation = request.Kind switch
        {
            VoiceLabRequestKind.Subscription => VoiceLabCopy.ProviderConsent + "\n\n" + VoiceLabCopy.AccountCheck,
            VoiceLabRequestKind.Delete => VoiceLabCopy.DeleteExplanation,
            VoiceLabRequestKind.StopLooking => VoiceLabCopy.StopLookingExplanation,
            _ => VoiceLabCopy.RemoveLocalExplanation
        };
        var approved = false;
        try { approved = await Ui.ConfirmAsync(XamlRoot, title, explanation, request.Kind == VoiceLabRequestKind.Subscription ? "Continue" : title, token); }
        finally { await session.ApproveAsync(approved); }
    }
    private void RenderSession()
    {
        if (accountCheck is not null) accountCheck.IsEnabled = session.Enabled && !session.Busy;
        foreach (var operation in session.Operations.Where(operation => !operation.Finished))
            if (operationStates.TryGetValue(operation.Id, out var previous) && previous.Text != operation.DisplayState)
            {
                previous.Text = operation.DisplayState;
                Ui.Announce(previous, operation.DisplayState, "voice-operation-" + operation.Id);
            }
        operationStates.Clear();
        ownVoice.Items.Clear(); voices.Items.Clear();
        var model = Ui.Stack();
        model.Children.Add(Ui.Text(VoiceLabCopy.SpeakerUnavailable, "HelperText"));
        if (session.SpeakerInstalled)
        {
            model.Children.Add(Ui.Text("Installed", "HelperText"));
            model.Children.Add(SessionButton("Remove", "Remove own-voice check model", session.RemoveSpeakerAsync));
        }
        else
        {
            var download = Ui.Button("Download", () => { }); download.IsEnabled = false;
            AutomationProperties.SetName(download, "Download own-voice check model");
            AutomationProperties.SetHelpText(download, VoiceLabCopy.SpeakerUnavailable);
            model.Children.Add(download);
        }
        AddCard(ownVoice, model);
        if (session.Subscription?.IsNonCommercial == true) AddCard(voices, Ui.Text(VoiceLabCopy.NonCommercial, "HelperText"));
        if (session.PlanMessage is { } plan) AddCard(voices, Ui.Text(plan, "HelperText"));
        if (session.VisibleRecords.Count == 0) AddCard(voices, Ui.Text("No voice yet", "HelperText"));
        foreach (var record in session.VisibleRecords)
        {
            var card = Ui.Stack();
            var name = Ui.Text(record.VoiceName);
            AutomationProperties.SetName(name, VoiceLabSession.CardName(record));
            AutomationProperties.SetAutomationId(name, "voice-record-" + record.RecordId);
            card.Children.Add(name);
            var date = VoiceLabSession.CardName(record)[(record.VoiceName.Length + ", created ".Length)..];
            card.Children.Add(Selectable("Created " + date + " · " + record.VoiceId));
            if (record.Status == VoiceConsentStatus.VerificationRequired) card.Children.Add(Ui.Text(VoiceLabCopy.VerificationRequired, "HelperText"));
            var deleting = session.Deleting.Contains(record.RecordId);
            if (deleting) card.Children.Add(Ui.Text(session.Busy ? "Deleting…" : "Couldn't finish deleting", "HelperText"));
            var delete = SessionButton(deleting ? "Retry deletion…" : "Delete voice", VoiceLabActionNames.ForRecord("Delete voice", record, session.VisibleRecords),
                () => ConfirmAsync(new(VoiceLabRequestKind.Delete, record.RecordId)));
            AutomationProperties.SetAutomationId(delete, "delete-voice-" + record.RecordId);
            card.Children.Add(delete);
            var removeLocal = SessionButton("Remove from VoxClip only", VoiceLabActionNames.ForRecord("Remove from VoxClip only", record, session.VisibleRecords),
                () => ConfirmAsync(new(VoiceLabRequestKind.RemoveLocal, record.RecordId)));
            AutomationProperties.SetAutomationId(removeLocal, "remove-local-voice-" + record.RecordId);
            card.Children.Add(removeLocal);
            AddVoiceCard(card, record.RecordId, VoiceLabSession.CardName(record));
        }
        if (session.UnsavedRecord is { } unsaved)
        {
            var row = Ui.Stack();
            var retrySave = SessionButton("Retry saving consent record", VoiceLabActionNames.ForRecord("Retry saving consent record", unsaved, session.Records.Append(unsaved).DistinctBy(record => record.RecordId).ToArray()), session.RetryUnsavedAsync);
            AutomationProperties.SetAutomationId(retrySave, "retry-save-voice-" + unsaved.RecordId);
            row.Children.Add(retrySave);
            var removeUnsaved = SessionButton("Remove This Voice", VoiceLabActionNames.ForRecord("Remove This Voice", unsaved, session.Records.Append(unsaved).DistinctBy(record => record.RecordId).ToArray()), () => session.WithdrawOperationAsync(unsaved.RecordId));
            AutomationProperties.SetAutomationId(removeUnsaved, "remove-unsaved-voice-" + unsaved.RecordId);
            row.Children.Add(removeUnsaved);
            AddVoiceCard(row, unsaved.RecordId, VoiceLabSession.CardName(unsaved));
        }
        foreach (var operation in session.Operations.Where(operation => !operation.Finished))
        {
            var row = Ui.Stack();
            row.Children.Add(Ui.Text(operation.Kind == VoiceOperationKind.Create ? "Voice creation" : "Voice removal"));
            var state = Ui.Text(operation.DisplayState, "HelperText");
            operationStates[operation.Id] = state;
            AutomationProperties.SetAutomationId(state, "voice-operation-" + operation.Id);
            AutomationProperties.SetLiveSetting(state, AutomationLiveSetting.Polite);
            row.Children.Add(state);
            var retry = SessionButton("Retry", VoiceLabActionNames.ForOperation(operation.Kind == VoiceOperationKind.Create ? "Retry voice creation" : "Retry voice removal", operation, session.Operations, session.Records), () => session.LoadAsync(force: true));
            AutomationProperties.SetAutomationId(retry, "retry-voice-" + operation.Id);
            row.Children.Add(retry);
            if (operation.Kind == VoiceOperationKind.Create)
            {
                var remove = SessionButton("Remove unfinished voice", VoiceLabActionNames.ForOperation("Remove unfinished voice", operation, session.Operations, session.Records), () => session.WithdrawOperationAsync(operation.RecordId));
                AutomationProperties.SetAutomationId(remove, "remove-unfinished-" + operation.Id);
                row.Children.Add(remove);
            }
            if (VoiceLabSession.CanStopLooking(operation))
            {
                var stopLooking = SessionButton(VoiceLabCopy.StopLooking, VoiceLabActionNames.ForOperation(VoiceLabCopy.StopLooking, operation, session.Operations, session.Records),
                    () => ConfirmAsync(new(VoiceLabRequestKind.StopLooking, OperationId: operation.Id)));
                AutomationProperties.SetAutomationId(stopLooking, "stop-looking-voice-" + operation.Id);
                row.Children.Add(stopLooking);
            }
            AddVoiceCard(row, operation.RecordId, VoiceLabActionNames.Created(operation.ExpectedVoiceName ?? "Voice creation", operation.StartedAt));
        }
        var create = Ui.Button("Create Your Voice…", owner.ShowCreateVoice); create.IsEnabled = session.Enabled && !session.Busy;
        AutomationProperties.SetName(create, "Create Your Voice…");
        AutomationProperties.SetHelpText(create, session.CreateBlockedReason);
        AutomationProperties.SetAutomationId(create, "voice-create-open");
        AddCard(voices, create); AddCard(voices, Ui.Text(session.SpeakerMessage, "HelperText"));
        if (session.Message is { } text) Ui.Show(message, text,
            text == VoiceLabCopy.RecoveryFailed || text == VoiceLabCopy.ReadFailed || text == "Couldn't finish — Retry" ? InfoBarSeverity.Warning : InfoBarSeverity.Informational);
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
            owner.TrackTextField(field, async () =>
            {
                if (!App.Services.VoiceLabEnabled) return true;
                var parsed = VoiceLabSettingsState.MonthlyCap(field.Text);
                if (parsed.Error is { } error)
                {
                    Ui.Show(message, error, InfoBarSeverity.Warning);
                    Ui.Announce(message, error, "voice-lab-message");
                    return false;
                }
                var settings = new AppSettings("voxclip-settings/1");
                settings.SetVoiceLabMonthlyCap(provider.Item1, parsed.Amount);
                await App.Services.SetAsync("voiceLab.monthlyCapUsd." + provider.Item1,
                    settings.GetString("voiceLab.monthlyCapUsd." + provider.Item1));
                return true;
            });
            AddCard(section, field);
        }
        var positions = VoiceLabSettingsState.LabelChoices;
        var position = Ui.Choice("Label position", positions.Select(choice => choice.Label),
            Math.Max(0, positions.ToList().FindIndex(choice => choice.Key == App.Services.Settings.GetString("voiceLab.labelPosition"))));
        AutomationProperties.SetName(position, "Label position");
        position.SelectionChanged += (_, _) => owner.RunSensitive(() => Ui.RunAsync(message,
            () => App.Services.VoiceLabEnabled ? App.Services.SetAsync("voiceLab.labelPosition", positions[position.SelectedIndex].Key, token) : Task.CompletedTask, "Save label position"), "Save label position");
        var label = Ui.Stack(); label.Children.Add(position); label.Children.Add(Ui.Text(VoiceLabCopy.LabelHelper, "HelperText")); AddCard(section, label);
        var c2pa = new ToggleSwitch { Header = "Add Content Credentials (C2PA) to exports", IsOn = App.Services.Settings.GetBool("voiceLab.c2pa") ?? true };
        AutomationProperties.SetName(c2pa, "Add Content Credentials (C2PA) to exports");
        AutomationProperties.SetHelpText(c2pa, VoiceLabCopy.C2paHelper);
        c2pa.Toggled += (_, _) => owner.RunSensitive(() => Ui.RunAsync(message,
            () => App.Services.VoiceLabEnabled ? App.Services.SetAsync("voiceLab.c2pa", c2pa.IsOn, token) : Task.CompletedTask, "Save Content Credentials preference"), "Save Content Credentials preference");
        var credentials = Ui.Stack(); credentials.Children.Add(c2pa); credentials.Children.Add(Ui.Text(VoiceLabCopy.C2paHelper, "HelperText")); AddCard(section, credentials);
    }
    private void AddVoiceCard(UIElement content, string recordId, string label)
    {
        var card = new ContentControl { Content = content, IsTabStop = true, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(card, label); AutomationProperties.SetAutomationId(card, "voice-card-" + recordId);
        if (focusRecordId == recordId)
        {
            voices.IsExpanded = true;
            card.Loaded += (_, _) => { if (initialLoadComplete && focusRecordId == recordId) { card.Focus(FocusState.Programmatic); card.StartBringIntoView(); focusRecordId = null; } };
        }
        AddCard(voices, card);
    }
    private void AddStorage()
    {
        var section = Section("Storage"); enabledContent.Children.Add(section);
        var panel = Ui.Stack(); panel.Children.Add(Ui.Text(VoiceLabCopy.Storage, "HelperText"));
        var path = Path.Combine(App.Services.Data.Root, "VoiceLab"); panel.Children.Add(Selectable(path));
        var reveal = Ui.Button("Show in File Explorer", () => { if (App.Services.VoiceLabEnabled) ShareHelpers.Reveal(path); });
        AutomationProperties.SetName(reveal, "Show in File Explorer");
        reveal.IsEnabled = Directory.Exists(path);
        if (!reveal.IsEnabled) AutomationProperties.SetHelpText(reveal, VoiceLabCopy.EmptyStorage);
        panel.Children.Add(reveal); AddCard(section, panel);
    }
}
