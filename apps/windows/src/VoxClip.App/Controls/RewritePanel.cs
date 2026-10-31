using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using Windows.System;

namespace VoxClip.App.Controls;

internal sealed partial class RewritePanel : Grid
{
    private readonly RewriteSession session;
    private readonly Func<bool> correctionOpen;
    private readonly MainWindow? window;
    private readonly TextBox instruction = new() { Header = "What should change?", AcceptsReturn = false, MaxLength = 1000 };
    private readonly TextBox words = new() { AcceptsReturn = false, TextWrapping = TextWrapping.Wrap };
    private readonly Button propose = new() { Content = "Rewrite", HorizontalAlignment = HorizontalAlignment.Right };
    private readonly ProgressRing busy = new() { Width = 16, Height = 16, Visibility = Visibility.Collapsed };
    private readonly TextBlock estimate = Ui.Text("");
    private readonly TextBlock problem = Ui.Text("");
    private readonly StackPanel review = Ui.Stack(6);
    private readonly TextBlock changeSummary = Ui.Text("");
    private readonly Button apply = new() { HorizontalAlignment = HorizontalAlignment.Right };
    private readonly RewriteAnnouncements announcements = new();
    private readonly List<(DependencyObject Target, DependencyProperty Property, string Key)> brushes = [];
    private bool updating;
    private readonly StackPanel generationBody = Ui.Stack(12);
    private readonly ComboBox voice = new() { Header = "Voice", HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "Label", SelectedValuePath = "Id" };
    private readonly ComboBox speechModel = new() { Header = "Speech model", HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "Name", SelectedValuePath = "Id" };
    private readonly Button discover = new() { Content = "Choose Voice…" };
    private readonly StackPanel noVoice = Ui.Stack(6);
    private readonly Button generate = new() { Content = "Generate Takes", HorizontalAlignment = HorizontalAlignment.Left };
    private readonly TextBlock generationProgress = Ui.Text("");
    private readonly ProgressRing generationBusy = new() { Width = 16, Height = 16 };
    private readonly Button cancelGeneration = new() { Content = "Cancel" };
    private readonly InfoBar generationError = new() { Severity = InfoBarSeverity.Error, IsClosable = false };
    private readonly TextBlock nonePassed = Ui.Text(RewriteGeneration.NonePassed);
    private string generationAnnouncement = "";
    internal Control FocusTarget => instruction;
    internal bool ReturnFocusOnClose { get; private set; }
    internal event EventHandler? Closed;

    /// <param name="window">The editor's window, whose project Create Your Voice offers as training audio (voice-lab.md §6.5.2).</param>
    internal RewritePanel(RewriteSession session, Func<bool>? correctionOpen = null, MainWindow? window = null)
    {
        this.session = session;
        this.correctionOpen = correctionOpen ?? (() => false);
        this.window = window;
        AutomationProperties.SetAutomationId(instruction, "Rewrite.Instruction");
        AutomationProperties.SetAutomationId(words, "Rewrite.Words");
        AutomationProperties.SetAutomationId(propose, "Rewrite.Propose");
        AutomationProperties.SetAutomationId(apply, "Rewrite.Apply");
        AutomationProperties.SetName(this, "Rewrite");
        AutomationProperties.SetName(busy, "AI request in progress");
        RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        var body = Ui.Stack(12);
        body.Margin = new(16, 12, 16, 12);
        var header = new Grid { ColumnSpacing = 6 };
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        var waveform = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        foreach (var height in new[] { 4.0, 10.0, 14.0, 8.0, 4.0 })
            waveform.Children.Add(Themed(new Border { Width = 1.5, Height = height, VerticalAlignment = VerticalAlignment.Center },
                Border.BackgroundProperty, "VcTextPrimaryBrush"));
        heading.Children.Add(waveform);
        var title = Ui.Text("Rewrite", "BodyStrongTextBlockStyle");
        AutomationProperties.SetAutomationId(title, "Rewrite.Header");
        title.FontSize = 13;
        heading.Children.Add(title);
        header.Children.Add(heading);
        var beta = Themed(new Border { BorderThickness = new(1),
            CornerRadius = new(4), Padding = new(4, 0, 4, 0), Child = Small("Beta") }, Border.BorderBrushProperty, "VcLineStrongBrush");
        Grid.SetColumn(beta, 1); header.Children.Add(beta);
        var selection = Small(session.Header); Grid.SetColumn(selection, 2); header.Children.Add(selection);
        selection.MinWidth = 0;
        var close = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 12 }, Width = 32, Height = 32, Padding = new(0) };
        SetName(close, "Close Rewrite");
        AutomationProperties.SetAutomationId(close, "Rewrite.Close");
        ToolTipService.SetToolTip(close, "Close Rewrite (Esc)");
        AutomationProperties.SetAcceleratorKey(close, "Esc");
        close.Click += (_, _) => Close();
        Grid.SetColumn(close, 3); header.Children.Add(close);
        body.Children.Add(header);
        SetName(instruction, "What should change?"); SetName(words, "New words"); SetName(propose, "Rewrite");
        instruction.TextChanged += async (_, _) => { if (!updating) await session.SetInstructionAsync(instruction.Text); };
        words.TextChanged += (_, _) => { if (!updating) session.Edit(words.Text); };
        propose.Click += async (_, _) =>
        {
            if (session.Prepared is not { } action || !session.CanPropose) return;
            var approved = true;
            if (session.Estimate is { Kind: VoiceLabCostPresentationKind.Confirm } confirmation)
                approved = await session.ConfirmCostAsync(action, token => Ui.ConfirmAsync(XamlRoot, "Rewrite", confirmation.Text, "Continue", token));
            if (!approved || !session.IsOpen) return;
            App.Services.BusyOperations++;
            try { await session.ProposeAsync(action, approved); }
            finally { App.Services.BusyOperations--; }
        };
        body.Children.Add(instruction); body.Children.Add(busy); body.Children.Add(propose);
        body.Children.Add(Small(session.SendLine)); body.Children.Add(estimate);
        if (session.Connector is null)
        {
            var settings = Ui.Button("Open Settings", () => App.OpenSettings("Providers & Keys"));
            AutomationProperties.SetAutomationId(settings, "Rewrite.Settings");
            body.Children.Add(settings);
        }
        var newHeader = new Grid();
        newHeader.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        newHeader.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        newHeader.Children.Add(Ui.Text("New words", "BodyStrongTextBlockStyle"));
        changeSummary.HorizontalAlignment = HorizontalAlignment.Right;
        changeSummary.FontSize = 11;
        changeSummary.TextTrimming = TextTrimming.CharacterEllipsis;
        changeSummary.TextWrapping = TextWrapping.NoWrap;
        Grid.SetColumn(changeSummary, 1);
        newHeader.Children.Add(changeSummary);
        body.Children.Add(newHeader);
        body.Children.Add(words); body.Children.Add(review); body.Children.Add(problem);
        BuildGeneration();
        body.Children.Add(generationBody);
        var scroll = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        AutomationProperties.SetAutomationId(scroll, "Rewrite.Scroll");
        Children.Add(scroll);
        var footerContent = Ui.Stack(12);
        var disclosure = new Grid { ColumnSpacing = 6 };
        disclosure.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        disclosure.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        disclosure.Children.Add(Themed(new FontIcon { Glyph = "\uE946", FontSize = 12, VerticalAlignment = VerticalAlignment.Top },
            IconElement.ForegroundProperty, "VcTextSecondaryBrush"));
        var disclosureText = Small("Exports show AI MODIFIED on the video and in the post.");
        Grid.SetColumn(disclosureText, 1); disclosure.Children.Add(disclosureText);
        footerContent.Children.Add(disclosure);
        footerContent.Children.Add(apply);
        apply.Click += async (_, _) => await ApplyDefaultAsync();
        var footer = Themed(new Border { Padding = new(16, 12, 16, 12), BorderThickness = new(0, 1, 0, 0),
            Child = footerContent }, Border.BorderBrushProperty, "VcLineDefaultBrush");
        Grid.SetRow(footer, 1); Children.Add(footer);
        session.Changed += Changed;
        Loaded += (_, _) =>
        {
            session.Changed -= Changed; session.Changed += Changed;
            Ui.EffectsChanged += EffectsChanged;
            RefreshBrushes();
            instruction.Focus(FocusState.Programmatic);
        };
        ActualThemeChanged += (_, _) => RefreshBrushes();
        Unloaded += (_, _) => { session.Changed -= Changed; Ui.EffectsChanged -= EffectsChanged; };
        PreviewKeyDown += Escape;
        Render();
    }

    private static void SetName(DependencyObject target, string name) => AutomationProperties.SetName(target, name);
#if DEBUG
    internal IReadOnlyList<string> DebugFitRequiredIds() => [.. ColumnBoundsGate.Rewrite,
        .. session.LocalAction is null ? Array.Empty<string>() : ["Rewrite.Apply"],
        .. session.Connector is null ? new[] { "Rewrite.Settings" } : Array.Empty<string>(),
        .. generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.Generate", "Rewrite.ChooseVoice" } : Array.Empty<string>(),
        .. noVoice.Visibility == Visibility.Visible && generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.CreateVoice" } : Array.Empty<string>(),
        .. voice.Visibility == Visibility.Visible && generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.Voice", "Rewrite.SpeechModel" } : Array.Empty<string>(),
        .. generationError.IsOpen && generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.GenerationError", "Rewrite.GenerationSettings", "Rewrite.GenerationRetry" } : Array.Empty<string>(),
        .. cancelGeneration.Visibility == Visibility.Visible && generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.GenerationCancel", "Rewrite.GenerationProgress" } : Array.Empty<string>(),
        .. renderedRows.Count > 0 && generationBody.Visibility == Visibility.Visible
            ? new[] { "Rewrite.Takes", "Rewrite.UseTake" }.Concat(renderedRows.Select(row => "Rewrite.Take" + (row.Index + 1))).ToArray() : [],
        .. lengthBody.Visibility == Visibility.Visible && generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.VideoChoice" } : []];
#endif
    private T Themed<T>(T target, DependencyProperty property, string key) where T : DependencyObject
    {
        brushes.Add((target, property, key));
        target.SetValue(property, Ui.ThemeBrush(this, key));
        return target;
    }
    private void EffectsChanged(object? sender, EventArgs args) => RefreshBrushes();
    private void RefreshBrushes()
    {
        foreach (var (target, property, key) in brushes) target.SetValue(property, Ui.ThemeBrush(this, key));
        Render();
    }
    private TextBlock Small(string text)
    {
        var label = Ui.Text(text); label.FontSize = 11;
        return Themed(label, TextBlock.ForegroundProperty, "VcTextSecondaryBrush");
    }
    private void Changed(object? sender, EventArgs args)
    {
        if (!session.IsOpen)
        {
            if (applyingTake) return;
            Closed?.Invoke(this, EventArgs.Empty); return;
        }
        Render();
    }
    private void Render()
    {
        updating = true;
        if (words.Text != session.NewWords) words.Text = session.NewWords;
        updating = false;
        propose.Content = session.ProposalButton;
        SetName(propose, session.ProposalButton);
        propose.IsEnabled = session.CanPropose;
        busy.IsActive = session.Editor.LlmRuns.IsBusy;
        busy.Visibility = busy.IsActive ? Visibility.Visible : Visibility.Collapsed;
        apply.Content = session.LocalAction ?? "";
        apply.Visibility = session.LocalAction is null ? Visibility.Collapsed : Visibility.Visible;
        apply.IsEnabled = session.LocalAction is not null && !session.Editor.Busy && !session.Editor.IsReadOnly && !session.Editor.IsLeaving;
        SetName(apply, session.LocalAction ?? "Apply changes");
        estimate.Text = session.EstimateCopy;
        estimate.FontSize = 11;
        problem.Text = session.Problem;
        problem.Visibility = session.Problem.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        brushes.RemoveAll(binding => binding.Target is TextBlock label && review.Children.Contains(label));
        review.Children.Clear();
        changeSummary.Text = session.Review?.ChangeSummary ?? "";
        if (session.Review is { } current)
        {
            review.Children.Add(new RewriteDiffLine(current));
            foreach (var hunk in current.VoiceHunks) review.Children.Add(Small(hunk.Meter?.Copy ?? hunk.Refusal ?? ""));
            if (current.Summary is { } summary) review.Children.Add(Small(summary.Copy));
            if (current.Budget.Copy is { } budget) review.Children.Add(Small(budget));
        }
        if (session.Prepared is { } action) DispatcherQueue.TryEnqueue(() => session.MarkEstimateShown(action));
        RenderGeneration();
        if (IsLoaded)
            foreach (var message in announcements.Next(session.IsProposing, session.ProposalRevision, session.Problem, session.Review?.ChangeSummary ?? ""))
                Ui.Announce(this, message, "rewrite", AutomationNotificationProcessing.All);
    }
    private void BuildGeneration()
    {
        AutomationProperties.SetAutomationId(voice, "Rewrite.Voice");
        AutomationProperties.SetAutomationId(speechModel, "Rewrite.SpeechModel");
        AutomationProperties.SetAutomationId(generate, "Rewrite.Generate");
        AutomationProperties.SetAutomationId(discover, "Rewrite.ChooseVoice");
        AutomationProperties.SetAutomationId(generationProgress, "Rewrite.GenerationProgress");
        AutomationProperties.SetAutomationId(generationError, "Rewrite.GenerationError");
        AutomationProperties.SetAutomationId(cancelGeneration, "Rewrite.GenerationCancel");
        var create = Ui.Button("Create Your Voice…", () =>
        {
            App.OpenSettings("Voice Lab");
            App.Settings?.ShowCreateVoice(window);
        });
        AutomationProperties.SetAutomationId(create, "Rewrite.CreateVoice");
        noVoice.Children.Add(Small("No voice yet")); noVoice.Children.Add(create);
        discover.Click += async (_, _) => { if (session.Generation is { } generation) await generation.DiscoverAsync(); };
        voice.SelectionChanged += async (_, _) =>
        { if (!updating && session.Generation is { } generation) await generation.ChooseVoiceAsync(voice.SelectedValue as string); };
        speechModel.SelectionChanged += async (_, _) =>
        { if (!updating && session.Generation is { } generation) await generation.ChooseModelAsync(speechModel.SelectedValue as string); };
        generate.Click += async (_, _) =>
        {
            if (session.Generation is not { } generation) return;
            App.Services.BusyOperations++;
            try { await generation.GenerateAsync((copy, token) => Ui.ConfirmAsync(XamlRoot, "Generate Takes", copy, "Continue", token)); }
            finally { App.Services.BusyOperations--; }
        };
        cancelGeneration.Click += async (_, _) => { if (session.Generation is { } generation) await generation.CancelAsync(); };
        var settings = Ui.Button("Open Settings", () => App.OpenSettings("Providers & Keys"));
        AutomationProperties.SetAutomationId(settings, "Rewrite.GenerationSettings");
        var retry = new Button { Content = "Retry" };
        AutomationProperties.SetAutomationId(retry, "Rewrite.GenerationRetry");
        retry.Click += async (_, _) =>
        {
            if (session.Generation is not { } generation) return;
            await generation.DiscoverAsync();
        };
        generationError.ActionButton = settings; generationError.Content = retry;
        generationBody.Children.Add(discover); generationBody.Children.Add(voice); generationBody.Children.Add(speechModel);
        generationBody.Children.Add(noVoice); generationBody.Children.Add(Ui.Text("Takes", "BodyStrongTextBlockStyle"));
        BuildTakes();
        generationBody.Children.Add(generate); generationBody.Children.Add(Small(RewriteGeneration.SendLine));
        generationBody.Children.Add(generationBusy); generationBody.Children.Add(generationProgress);
        generationBody.Children.Add(cancelGeneration); generationBody.Children.Add(generationError); generationBody.Children.Add(nonePassed);
    }
    private void RenderGeneration()
    {
        var generation = session.Generation;
        generationBody.Visibility = generation is not null && session.LocalAction is null ? Visibility.Visible : Visibility.Collapsed;
        if (generation is null) return;
        updating = true;
        if (!ReferenceEquals(voice.ItemsSource, generation.Voices)) voice.ItemsSource = generation.Voices;
        if (!ReferenceEquals(speechModel.ItemsSource, generation.Models)) speechModel.ItemsSource = generation.Models;
        voice.SelectedValue = generation.VoiceId; speechModel.SelectedValue = generation.ModelId;
        updating = false;
        voice.Visibility = generation.Voices.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        speechModel.Visibility = generation.Voices.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        discover.Content = generation.HasDiscovered ? "Refresh voices" : "Choose Voice…";
        discover.IsEnabled = !generation.IsRunning && !generation.IsPreparing;
        noVoice.Visibility = generation.HasDiscovered && generation.Voices.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        generate.Content = generation.ButtonTitle;
        generate.IsEnabled = generation.CanExecute;
        SetName(generate, generation.ButtonName); ToolTipService.SetToolTip(generate, generation.ButtonName);
        var generating = generation.Phase == RewriteGenerationPhase.Generating;
        generationProgress.Text = generating ? generation.ProgressCopy : generation.IsPreparing ? "Preparing takes…" : "";
        generationBusy.IsActive = generating || generation.IsPreparing;
        generationBusy.Visibility = generationBusy.IsActive ? Visibility.Visible : Visibility.Collapsed;
        generationProgress.Visibility = generationBusy.Visibility;
        cancelGeneration.Visibility = generation.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        generationError.Message = generation.Problem;
        generationError.IsOpen = generation.Problem.Length > 0;
        nonePassed.Visibility = generation.Phase == RewriteGenerationPhase.NonePassed ? Visibility.Visible : Visibility.Collapsed;
        RenderTakes(generation);
        if (generation.Quote is { } quote) DispatcherQueue.TryEnqueue(() => generation.MarkEstimateShown(quote));
        if (IsLoaded && generation.Announcement.Length > 0 && generation.Announcement != generationAnnouncement)
        {
            generationAnnouncement = generation.Announcement;
            Ui.Announce(this, generationAnnouncement, "rewrite", AutomationNotificationProcessing.All);
        }
        if (generation.Announcement.Length == 0) generationAnnouncement = "";
    }
#if DEBUG
    internal async Task DebugFitStatesAsync(Func<string, Task> inspect)
    {
        foreach (var state in new[] { "no-voice", "generating", "provider-error", "none-passed", "ready", "three-ready", "mixed", "length-changed", "cancelled", "fatal" })
        {
            var fake = new DebugRewriteTakeRunner(Path.Combine(VoxClip.Core.Services.Project.SharedResources.ResolveRoot(), "fixtures", "voice-lab", "take-run-cases.json")) { State = state };
            var generation = new RewriteGeneration(fake, fake.DiscoverAsync,
                (voiceId, modelId, seed, ct) => session.GenerationInputAsync(voiceId, modelId, seed, true,
                    _ => Task.FromResult(new float[checked((int)Math.Floor(session.Project.Media.Source.DurationSeconds *
                        (session.Project.Media.Source.Audio?.SampleRate ?? 48_000) + 0.5))]), ct),
                _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => session.GenerationIsCurrent);
            session.ConfigureGeneration(generation);
            await generation.DiscoverAsync();
            if (generation.Quote is { } quote) generation.MarkEstimateShown(quote);
            Task? running = null;
            if (state != "no-voice") running = generation.GenerateAsync((_, _) => Task.FromResult(true));
            if (state != "generating" && running is not null) await running;
            RenderGeneration();
            try { await inspect(state); }
            finally
            {
                await generation.CancelAsync();
                if (running is not null) await running;
                generation.Dispose(); await generation.Cleanup;
            }
            if (fake.HttpCalls != 0) throw new InvalidOperationException("Rewrite fixture made an HTTP request.");
        }
    }
#endif
    private async void Escape(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Enter && !InputState.Down(VirtualKey.Control) && !InputState.Down(VirtualKey.Menu) &&
            !InputState.Down(VirtualKey.Shift) && apply.IsEnabled && ShortcutPolicy.EditorMayHandle(
                InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot)), correctionOpen(), false, false, true) &&
            !NativeReturnTarget(FocusManager.GetFocusedElement(XamlRoot) as DependencyObject))
        {
            args.Handled = true;
            await ApplyDefaultAsync();
            return;
        }
        if (args.Key != VirtualKey.Escape) return;
        Close(); args.Handled = true;
    }
    private bool NativeReturnTarget(DependencyObject? target)
    {
        while (target is not null && !ReferenceEquals(target, this))
        {
            if (target is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase or ComboBox) return true;
            target = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(target);
        }
        return false;
    }
    private async Task ApplyDefaultAsync()
    {
        if (session.LocalAction is null)
        {
            if (session.Generation?.ReadyToAccept != true) return;
            applyingTake = true;
            try { ReturnFocusOnClose = await session.ApplyTakeAsync(); }
            finally { applyingTake = false; }
            if (ReturnFocusOnClose || !session.IsOpen) Closed?.Invoke(this, EventArgs.Empty);
            return;
        }
        ReturnFocusOnClose = true;
        if (!session.ApplyLocalChanges()) ReturnFocusOnClose = false;
        await Task.CompletedTask;
    }
    private void Close() { session.Dispose(); }
}
