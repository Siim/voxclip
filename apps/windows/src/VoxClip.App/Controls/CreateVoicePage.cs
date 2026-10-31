using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using VoxClip.App.ViewModels;
using VoxClip.Media.Audio;

namespace VoxClip.App.Controls;

internal sealed class CreateVoicePage : UserControl, IAsyncDisposable
{
    private readonly SettingsWindow owner;
    private readonly CreateVoiceSession session;
    private readonly string language;
    private CancellationTokenSource lifetime = new();
    private readonly StackPanel body = Ui.Stack(14);
    private readonly StackPanel inputs = Ui.Stack(8);
    private readonly TextBox name = new() { Header = "Display name" };
    private readonly CheckBox ownVoice = new() { Content = "This is my own voice." };
    private readonly CheckBox adult = new() { Content = "I am 18 or older." };
    private readonly CheckBox ownVideos = new() { Content = "I will use it only on videos of myself." };
    private readonly TextBlock gate = Ui.Text("", "HelperText");
    private readonly TextBlock readHeading = Ui.Text("Read this aloud", "SubtitleTextBlockStyle");
    private readonly TextBox teleprompter = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock headphones = Ui.Text("If you use a screen reader, wear headphones so it isn't recorded.", "HelperText");
    private readonly RadioButtons source = new() { Header = VoiceLabCopy.TrainingAudio, MaxColumns = 1 };
    private readonly RadioButton projectChoice = new();
    private readonly TextBlock projectLine = Ui.Text("", "HelperText");
    private readonly RadioButton readAloudChoice = new() { Content = VoiceLabCopy.ReadAloudChoice };
    private readonly TextBlock sourceLine = Ui.Text("", "HelperText");
    private readonly InfoBar message = Ui.Notice();
    private readonly ProgressBar level = new() { Minimum = 0, Maximum = 1 };
    private readonly TextBlock seconds = Ui.Text("0.0 seconds");
    private readonly TextBlock device = Ui.Text("", "HelperText");
    private readonly Button record;
    private readonly Button stop;
    private readonly Button verify;
    private readonly Button cancel;
    private readonly Button openSettings;
    private readonly Button retryCleanup;
    private readonly Button training;
    private readonly Button switchToReadAloud;
    private readonly Button create;
    private readonly Button retrySave;
    private readonly Button removeUnsaved;
    private readonly ProgressRing working = new() { IsActive = false };
    private bool hadTraining;
    private bool completing;
    private string? stagedRecordId;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private bool wasRecording;
    private bool hadStatement;
    private bool choosing;
    internal bool DialogOpen { get; private set; }
    internal bool IsBusyForRestart => session.IsBusyForRestart || DialogOpen;

    internal CreateVoicePage(SettingsWindow owner, CreateVoiceSession session, MainWindow? from = null)
    {
        this.owner = owner; this.session = session;
        // The window that opened the sheet (the Rewrite panel's) gives the project and statement language; from Settings, the first
        // window with an editor project.
        var window = (from is not null && App.Windows.Contains(from) ? from : null)
            ?? App.Windows.FirstOrDefault(window => window.VoiceTrainingProject is not null) ?? App.Windows.FirstOrDefault();
        language = window?.VoiceEnrollmentLanguage ?? "en";
        Content = body;
        var back = Ui.Button("Back to Voice Lab", () => owner.ReturnFromCreateVoice(VoiceCreationLeaveTrigger.Back));
        AutomationProperties.SetName(back, "Back to Voice Lab"); AutomationProperties.SetAutomationId(back, "voice-create-back");
        body.Children.Add(back);
        var title = Ui.Text("Create Your Voice", "TitleTextBlockStyle");
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1); body.Children.Add(title);
        AutomationProperties.SetAutomationId(gate, "voice-create-gate"); body.Children.Add(gate);
        body.Children.Add(Ui.Text("Your voice clone is created in your ElevenLabs account and stays there. ElevenLabs' terms let it use uploaded content, including your voice, to improve its services; you can opt out of training in your ElevenLabs account, but the opt-out is not retroactive. You can delete the voice at any time from VoxClip or ElevenLabs. ElevenLabs' Prohibited Use Policy applies, including its rules on political content."));
        AddLink("ElevenLabs terms", "https://elevenlabs.io/terms-of-use");
        AddLink("Prohibited Use Policy", "https://elevenlabs.io/use-policy");
        inputs.Children.Add(name); inputs.Children.Add(Ui.Text("1–60 Unicode scalars; no control characters.", "HelperText"));
        inputs.Children.Add(ownVoice); inputs.Children.Add(adult); inputs.Children.Add(ownVideos); body.Children.Add(inputs);
        AutomationProperties.SetAutomationId(name, "voice-display-name");
        AutomationProperties.SetAutomationId(ownVoice, "voice-attest-own"); AutomationProperties.SetAutomationId(adult, "voice-attest-adult"); AutomationProperties.SetAutomationId(ownVideos, "voice-attest-videos");
        name.TextChanged += (_, _) => InputsChanged();
        foreach (var check in new[] { ownVoice, adult, ownVideos }) { check.Checked += (_, _) => InputsChanged(); check.Unchecked += (_, _) => InputsChanged(); }
        body.Children.Add(readHeading);
        AutomationProperties.SetAutomationId(teleprompter, "voice-consent-teleprompter");
        AutomationProperties.SetName(teleprompter, "Read this aloud"); body.Children.Add(teleprompter);
        headphones.IsTextSelectionEnabled = true;
        AutomationProperties.SetAutomationId(headphones, "voice-consent-headphones"); body.Children.Add(headphones);
        record = Ui.Button("Record statement", () => owner.RunSensitive(session.RecordAsync, "Record statement"));
        AutomationProperties.SetAutomationId(record, "voice-record-statement"); body.Children.Add(record);
        AutomationProperties.SetName(level, "Microphone level"); AutomationProperties.SetAutomationId(level, "voice-microphone-level"); body.Children.Add(level);
        seconds.FontFamily = new FontFamily("Cascadia Mono"); AutomationProperties.SetAutomationId(seconds, "voice-microphone-seconds"); body.Children.Add(seconds); body.Children.Add(device);
        stop = Ui.Button("Stop recording", session.StopRecording); AutomationProperties.SetAutomationId(stop, "voice-stop-recording"); body.Children.Add(stop);
        cancel = Ui.Button("Cancel", () => owner.ReturnFromCreateVoice(VoiceCreationLeaveTrigger.Back));
        AutomationProperties.SetAutomationId(cancel, "voice-create-cancel"); body.Children.Add(cancel);
        verify = Ui.Button("Verify statement · < $0.01", () => owner.RunSensitive(VerifyAsync, "Verify statement"));
        AutomationProperties.SetAutomationId(verify, "voice-verify-statement"); body.Children.Add(verify);
        session.OpenProject(window?.VoiceTrainingProject);
        var projectText = Ui.Stack(2);
        projectText.Children.Add(Ui.Text(VoiceLabCopy.ProjectChoice)); projectText.Children.Add(projectLine);
        projectChoice.Content = projectText; AutomationProperties.SetName(projectChoice, VoiceLabCopy.ProjectChoice);
        AutomationProperties.SetAutomationId(projectChoice, "voice-training-project"); AutomationProperties.SetAutomationId(readAloudChoice, "voice-training-read-aloud");
        AutomationProperties.SetName(source, VoiceLabCopy.TrainingAudio); AutomationProperties.SetAutomationId(source, "voice-training-source");
        if (session.ProjectOffered) source.Items.Add(projectChoice);
        source.Items.Add(readAloudChoice);
        source.SelectionChanged += (_, _) =>
        {
            if (!choosing && source.SelectedIndex >= 0)
                session.SelectTrainingSource(ReferenceEquals(source.Items[source.SelectedIndex], projectChoice) ? VoiceTrainingSource.Project : VoiceTrainingSource.ReadAloud);
        };
        body.Children.Add(source);
        AutomationProperties.SetAutomationId(sourceLine, "voice-training-source-line"); body.Children.Add(sourceLine);
        training = Ui.Button("Record training read-aloud", () => owner.RunSensitive(session.RecordTrainingAsync, "Record training read-aloud"));
        AutomationProperties.SetAutomationId(training, "voice-record-training"); body.Children.Add(training);
        create = Ui.Button("Create voice…", () => owner.RunSensitive(CreateAsync, "Create voice"));
        create.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        AutomationProperties.SetAutomationId(create, "voice-create-submit"); body.Children.Add(create);
        removeUnsaved = Ui.Button("Remove This Voice", () => owner.RunSensitive(session.RemoveUnsavedVoiceAsync, "Remove This Voice"));
        AutomationProperties.SetAutomationId(removeUnsaved, "voice-create-remove-unsaved"); body.Children.Add(removeUnsaved);
        retrySave = Ui.Button("Retry saving consent record", () => owner.RunSensitive(session.RetrySavingRecordAsync, "Retry saving consent record"));
        AutomationProperties.SetAutomationId(retrySave, "voice-create-retry-save"); body.Children.Add(retrySave);
        AutomationProperties.SetName(working, "Working"); AutomationProperties.SetAutomationId(working, "voice-create-working"); body.Children.Add(working);
        AutomationProperties.SetAutomationId(message, "voice-create-message"); body.Children.Add(message);
        switchToReadAloud = Ui.Button(VoiceLabCopy.RecordReadAloud, () =>
        {
            session.SelectTrainingSource(VoiceTrainingSource.ReadAloud);
            DispatcherQueue.TryEnqueue(() => training.Focus(FocusState.Programmatic));
        });
        AutomationProperties.SetAutomationId(switchToReadAloud, "voice-training-switch-read-aloud"); body.Children.Add(switchToReadAloud);
        retryCleanup = Ui.Button("Try removing the recording again", () => owner.RunSensitive(session.RetryCleanupAsync, "Remove recording"));
        AutomationProperties.SetAutomationId(retryCleanup, "voice-retry-recording-cleanup"); body.Children.Add(retryCleanup);
        openSettings = Ui.Button(VoiceLabCopy.MicrophoneOpenSettings, () => owner.RunSensitive(OpenMicrophoneSettingsAsync, VoiceLabCopy.MicrophoneOpenSettings));
        AutomationProperties.SetAutomationId(openSettings, "voice-open-microphone-settings"); body.Children.Add(openSettings);
        session.Changed += SessionChanged;
        session.Announcement += Announce;
        Ui.EffectsChanged += EffectsChanged;
        ActualThemeChanged += ThemeChanged;
        timer.Tick += (_, _) => UpdateMeter();
        Loaded += (_, _) => { timer.Start(); back.Focus(FocusState.Programmatic); };
        Unloaded += (_, _) => timer.Stop();
        InputsChanged();
        Refresh();
    }
    private void AddLink(string title, string uri)
    {
        var text = Ui.Text(title); text.TextDecorations = Windows.UI.Text.TextDecorations.Underline;
        body.Children.Add(new HyperlinkButton { Content = text, NavigateUri = new Uri(uri) });
    }
    private void InputsChanged() => session.SetInputs(name.Text, language, ownVoice.IsChecked == true, adult.IsChecked == true, ownVideos.IsChecked == true);
    private void SessionChanged(object? sender, EventArgs args) => Refresh();
    private void EffectsChanged(object? sender, EventArgs args) => Refresh();
    private void ThemeChanged(FrameworkElement sender, object args) => Refresh();
    private void Announce(string text)
    {
        if (!session.Recording) Ui.Announce(message, text, "voice-statement");
    }
    private void Refresh()
    {
        body.Transitions = Ui.EffectPolicy.Animations ? new TransitionCollection { new EntranceThemeTransition() } : new TransitionCollection();
        foreach (var helper in new[] { gate, seconds, device, projectLine, sourceLine }) helper.Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush");
        gate.Text = string.Join("\n", session.GateMessages);
        gate.Visibility = session.BlockedReason is null ? Visibility.Collapsed : Visibility.Visible;
        foreach (var input in new Control[] { name, ownVoice, adult, ownVideos }) input.IsEnabled = session.InputsEditable && session.BlockedReason is null;
        var fromProject = session.Verified && session.TrainingSource == VoiceTrainingSource.Project;
        teleprompter.Text = fromProject ? "" : session.Verified ? session.TrainingScript : session.Statement?.Text ?? "";
        AutomationProperties.SetName(teleprompter, session.Verified ? "Training read-aloud · about 90 seconds" : "Read this aloud");
        foreach (var part in new FrameworkElement[] { readHeading, teleprompter, headphones }) part.Visibility = fromProject ? Visibility.Collapsed : Visibility.Visible;
        var picking = session.Verified && session.UnsavedRecord is null && !session.ReturnToPane;
        source.Visibility = picking && session.ProjectOffered ? Visibility.Visible : Visibility.Collapsed;
        projectLine.Text = session.ProjectLine; AutomationProperties.SetHelpText(projectChoice, session.ProjectLine);
        projectChoice.IsEnabled = session.CanSelectProject && session.CanChooseSource;
        readAloudChoice.IsEnabled = session.CanChooseSource;
        choosing = true;
        source.SelectedIndex = source.Items.IndexOf(session.TrainingSource == VoiceTrainingSource.Project && session.ProjectOffered ? projectChoice : readAloudChoice);
        choosing = false;
        sourceLine.Text = session.ProjectOffered ? "" : session.ProjectLine;
        sourceLine.Visibility = picking && !session.ProjectOffered ? Visibility.Visible : Visibility.Collapsed;
        switchToReadAloud.Visibility = session.ProjectMismatch && session.TrainingSource == VoiceTrainingSource.Project ? Visibility.Visible : Visibility.Collapsed;
        switchToReadAloud.IsEnabled = session.CanChooseSource;
        record.IsEnabled = session.CanRecord; record.Content = session.HasStatementRecording ? "Record statement again" : "Record statement";
        record.Visibility = session.Verified ? Visibility.Collapsed : Visibility.Visible;
        verify.IsEnabled = session.CanVerify;
        verify.Visibility = session.Verified ? Visibility.Collapsed : Visibility.Visible;
        training.IsEnabled = session.CanRecordTraining; training.Content = session.TrainingReady ? "Record training again" : "Record training read-aloud";
        training.Visibility = session.Verified && session.TrainingSource == VoiceTrainingSource.ReadAloud ? Visibility.Visible : Visibility.Collapsed;
        create.IsEnabled = session.CanCreate; create.Visibility = session.UnsavedRecord is null ? Visibility.Visible : Visibility.Collapsed;
        cancel.Visibility = session.UnsavedRecord is null ? Visibility.Visible : Visibility.Collapsed;
        removeUnsaved.Visibility = retrySave.Visibility = session.UnsavedRecord is null ? Visibility.Collapsed : Visibility.Visible;
        removeUnsaved.IsEnabled = retrySave.IsEnabled = !session.Busy;
        working.IsActive = session.Busy; working.Visibility = session.Busy ? Visibility.Visible : Visibility.Collapsed;
        if (session.UnsavedRecord is { } unsaved)
        {
            stagedRecordId = unsaved.RecordId; App.Services.VoiceLab.StageUnsaved(unsaved);
            var peers = App.Services.VoiceLab.Records.Append(unsaved).DistinctBy(record => record.RecordId).ToArray();
            AutomationProperties.SetName(removeUnsaved, VoiceLabActionNames.ForRecord("Remove This Voice", unsaved, peers));
            AutomationProperties.SetName(retrySave, VoiceLabActionNames.ForRecord("Retry saving consent record", unsaved, peers));
        }
        else if (stagedRecordId is { } staged) { App.Services.VoiceLab.ClearUnsaved(staged); stagedRecordId = null; }
        retryCleanup.Visibility = session.CanRetryCleanup ? Visibility.Visible : Visibility.Collapsed;
        stop.Visibility = session.Recording ? Visibility.Visible : Visibility.Collapsed;
        level.Visibility = session.Recording ? Visibility.Visible : Visibility.Collapsed;
        seconds.Visibility = session.Recording ? Visibility.Visible : Visibility.Collapsed;
        if (session.Message is { } text) Ui.Show(message, text, session.HasFailure ? InfoBarSeverity.Warning : InfoBarSeverity.Informational);
        else message.IsOpen = false;
        openSettings.Visibility = session.MicrophoneFailure is MicrophoneError.Permission or MicrophoneError.Silent ? Visibility.Visible : Visibility.Collapsed;
        if (!wasRecording && session.Recording) stop.Focus(FocusState.Programmatic);
        if (!hadStatement && session.HasStatementRecording) verify.Focus(FocusState.Programmatic);
        if (!hadTraining && session.TrainingReady && session.CanCreate) create.Focus(FocusState.Programmatic);
        hadTraining = session.TrainingReady;
        wasRecording = session.Recording; hadStatement = session.HasStatementRecording;
        UpdateMeter();
        if (session.ReturnToPane && !session.Busy && !completing)
        {
            completing = true;
            DispatcherQueue.TryEnqueue(() => owner.CompleteCreateVoice(session.FocusRecordId!, session.Message!));
        }
    }
    private void UpdateMeter()
    {
        var snapshot = session.Capture;
        level.Value = snapshot.Level;
        seconds.Text = snapshot.Seconds.ToString("0.0", CultureInfo.InvariantCulture) + " seconds";
        device.Text = snapshot.DeviceName is { } name ? VoiceLabCopy.MicrophoneDeviceLine(name) : "";
    }
    private async Task VerifyAsync()
    {
        if (!session.RequestVerification()) return;
        var approved = false;
        DialogOpen = true;
        try { approved = await VoiceLabDialogs.ConfirmCreationAsync(XamlRoot, VoiceCreationDialog.Verify(session.VerificationCost), lifetime.Token); }
        finally { DialogOpen = false; await session.ApproveVerificationAsync(approved); }
    }
    private async Task CreateAsync()
    {
        await session.PrepareCreationAsync();
        if (session.CreationConfirmation is not { } quote) return;
        var approved = false; DialogOpen = true;
        try { approved = await VoiceLabDialogs.ConfirmCreationAsync(XamlRoot, VoiceCreationDialog.Create(quote), lifetime.Token); }
        finally { DialogOpen = false; await session.ApproveCreationAsync(approved); }
    }
    internal Task<bool> TryLeaveAsync(VoiceCreationLeaveTrigger trigger) => session.TryLeaveAsync(trigger, async _ =>
    {
        if (DialogOpen) return false;
        DialogOpen = true;
        try { return await VoiceLabDialogs.ConfirmCreationAsync(XamlRoot, VoiceCreationDialog.Leave, lifetime.Token); }
        finally { DialogOpen = false; }
    });
    internal async Task GateChangedAsync()
    {
        if (!App.Services.VoiceLabEnabled)
        {
            var previous = lifetime; lifetime = new(); previous.Cancel(); previous.Dispose();
        }
        // Abandons when Voice Lab is off; otherwise starts the project analysis if the gate has opened.
        await session.GateChangedAsync();
        Refresh();
    }
    internal Task<bool> PrepareForRestartAsync() => DialogOpen ? Task.FromResult(true) : session.InterruptForRestartAsync();
    private static async Task OpenMicrophoneSettingsAsync()
    {
#if DEBUG
        if (Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_VOICELAB")?.StartsWith("fixtures:", StringComparison.Ordinal) == true)
        {
            App.Services.DebugMicrophoneSettingsUri = VoiceLabCopy.MicrophoneSettingsUri;
            Directory.CreateDirectory(App.Services.Data.Cache);
            await File.WriteAllTextAsync(Path.Combine(App.Services.Data.Cache, "microphone-settings-uri.txt"), VoiceLabCopy.MicrophoneSettingsUri);
            return;
        }
#endif
        await Windows.System.Launcher.LaunchUriAsync(new Uri(VoiceLabCopy.MicrophoneSettingsUri));
    }
    public async ValueTask DisposeAsync()
    {
        timer.Stop(); lifetime.Cancel();
        session.Changed -= SessionChanged; session.Announcement -= Announce;
        Ui.EffectsChanged -= EffectsChanged;
        ActualThemeChanged -= ThemeChanged;
        await session.DisposeAsync(); lifetime.Dispose();
    }
}
