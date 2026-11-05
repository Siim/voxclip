using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;
using VoxClip.App.Services;
using VoxClip.Core.Domain.VoiceLab;
using Windows.System;

namespace VoxClip.App.Controls;

internal sealed partial class RewritePanel : Grid
{
    private readonly RewriteSession session;
    private readonly DirectorTask task;
    private readonly TextBlock taskStatus = Ui.Text("");
    private readonly TextBlock monthlySpend = Ui.Text("", "HelperText");
    private readonly TextBlock takeSend = Ui.Text("");
    private readonly Func<bool> correctionOpen;
    private readonly TextBox instruction = new() { Header = "What should change?", AcceptsReturn = false, MaxLength = 1000 };
    private readonly TextBox words = new() { AcceptsReturn = false, TextWrapping = TextWrapping.Wrap };
    private readonly Button propose = new() { Content = "Rewrite", HorizontalAlignment = HorizontalAlignment.Right };
    private readonly ProgressRing busy = new() { Width = 16, Height = 16, Visibility = Visibility.Collapsed };
    private readonly TextBlock estimate = Ui.Text("");
    private readonly TextBlock problem = Ui.Text("");
    private readonly StackPanel confirmation = Ui.Stack(8);
    private InlineApproval? approval;
    private ShellTextFocus? textFocus;
    private bool requestingApproval;
    private readonly string localServerAddress;
    private readonly Uri? localServer;
    private bool remoteLocalAllowed;
    private bool RemoteLocal => session.Connector?.Group == "local" && localServer is { IsLoopback: false };
    private string SendLine => RemoteLocal ? $"Sends these {session.Source.Count(word => word.Kind == VoxClip.Core.Domain.Shared.WordKind.Word)} words to {localServer!.Authority}. No audio or video." : session.SendLine;
    private readonly StackPanel review = Ui.Stack(6);
    private readonly TextBlock changeSummary = Ui.Text("");
    private readonly Button apply = new() { HorizontalAlignment = HorizontalAlignment.Right };
    private readonly TextBlock acceptBlocker = Ui.Text("");
    private readonly RewriteAnnouncements announcements = new();
    private readonly List<(DependencyObject Target, DependencyProperty Property, string Key)> brushes = [];
    private bool updating;
    private readonly StackPanel generationBody = Ui.Stack(12);
    private readonly ComboBox voice = new() { Header = "Voice", HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "Label", SelectedValuePath = "Id" };
    /// <summary>New Rewrite phrases always use Eleven v4: a fixed label, not a choice.</summary>
    internal const string SpeechModelLabel = "Eleven v4 · audio tags";
    private readonly TextBlock speechModel = Ui.Text(SpeechModelLabel);
    private readonly TextBlock voiceText = Ui.Text("");
    private readonly Button discover = new() { Content = "Choose Voice…" };
    private readonly StackPanel noVoice = Ui.Stack(6);
    private readonly StackPanel languageUnavailable = Ui.Stack(6);
    private readonly Button generate = new() { Content = "Generate Takes", HorizontalAlignment = HorizontalAlignment.Left };
    private readonly TextBlock generationProgress = Ui.Text("");
    private readonly ProgressRing generationBusy = new() { Width = 16, Height = 16 };
    private readonly Button cancelGeneration = new() { Content = "Cancel" };
    private readonly InfoBar generationError = new() { Severity = InfoBarSeverity.Error, IsClosable = false };
    private readonly TextBlock nonePassed = Ui.Text(RewriteGeneration.NonePassed);
    private string generationAnnouncement = "";
    internal Control FocusTarget => instruction;
    internal bool IsSessionOpen => session.IsOpen;
    internal void CloseForHost() => Close();
    internal bool ReturnFocusOnClose { get; private set; }
    internal event EventHandler? Closed;

    /// <summary>The session this panel shows.</summary>
    internal RewriteSession Session => session;

    /// <summary>A tone chip (design §6.3.1): sends the instruction the field holds at once, through the panel's own inline approval when
    /// the send asks first.</summary>
    internal async Task SendNowAsync()
    {
        if (session.Prepared is not { } action) return;
        session.MarkEstimateShown(action);
        await SendProposalAsync();
    }

    internal RewritePanel(RewriteSession session, Func<bool>? correctionOpen = null, MainWindow? window = null)
    {
        this.session = session;
        session.VoiceConsent = AuthorizeVoiceAsync;
        task = new(session);
        this.correctionOpen = correctionOpen ?? (() => false);
        var connectorWire = session.Connector is { } selected ? ProviderWireId(selected.Connector.Id) : null;
        localServerAddress = connectorWire is null ? "" : App.Services.Get("llm.baseUrl." + connectorWire, "");
        localServer = Uri.TryCreate(localServerAddress, UriKind.Absolute, out var server) ? server : null;
        session.ConfigureInlineConsent(token => Task.FromResult(InlinePrivacyGranted()),
            () => connectorWire is null || App.Services.Get("llm.baseUrl." + connectorWire, "") == localServerAddress, RemoteLocal);
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
        var title = Ui.Text(session.Header, "BodyStrongTextBlockStyle");
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
        body.Children.Add(taskStatus);
        SetName(instruction, "What should change?"); SetName(words, "New words"); SetName(propose, "Rewrite");
        instruction.TextChanged += async (_, _) => { if (!updating) await session.SetInstructionAsync(instruction.Text); };
        // TextChanged also echoes programmatic updates; only a real edit (which cancels fit rounds) reaches the session.
        words.TextChanged += (_, _) => { if (!updating && words.Text != session.NewWords) session.Edit(words.Text); };
        propose.Click += async (_, _) => await SendProposalAsync();
        body.Children.Add(instruction); body.Children.Add(busy); body.Children.Add(propose);
        body.Children.Add(Small(SendLine)); body.Children.Add(estimate);
        body.Children.Add(confirmation);
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
        BuildWordingFit();
        BuildNextSteps();
        body.Children.Add(words); body.Children.Add(wordingFit); body.Children.Add(review); body.Children.Add(paidReviewChange); body.Children.Add(sentenceReview); body.Children.Add(problem);
        body.Children.Add(nextSteps);
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
        disclosureText = Small(RewriteSession.AiDisclosureLine);
        AutomationProperties.SetAutomationId(disclosureText, "Rewrite.Disclosure");
        Grid.SetColumn(disclosureText, 1); disclosure.Children.Add(disclosureText);
        footerContent.Children.Add(disclosure);
        acceptBlocker.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetAutomationId(acceptBlocker, "Rewrite.AcceptBlocker");
        footerContent.Children.Add(acceptBlocker);
        footerContent.Children.Add(apply);
        apply.Click += async (_, _) => await ApplyFooterAsync();
        var footer = Themed(new Border { Padding = new(16, 12, 16, 12), BorderThickness = new(0, 1, 0, 0),
            Child = footerContent }, Border.BorderBrushProperty, "VcLineDefaultBrush");
        Grid.SetRow(footer, 1); Children.Add(footer);
        session.Changed += Changed;
        Loaded += (_, _) =>
        {
            textFocus ??= new(this);
            session.Changed -= Changed; session.Changed += Changed;
            Ui.EffectsChanged += EffectsChanged;
            WorkflowSpendCache.Changed -= SpendChanged; WorkflowSpendCache.Changed += SpendChanged;
            RefreshBrushes();
            instruction.Focus(FocusState.Programmatic);
        };
        ActualThemeChanged += (_, _) => RefreshBrushes();
        Unloaded += (_, _) =>
        {
            textFocus?.Dispose(); textFocus = null;
            approval?.Cancel();
            _ = Ui.RunAsync(generationError, session.StopCandidatesAsync, "Audition");
            session.Changed -= Changed; Ui.EffectsChanged -= EffectsChanged; WorkflowSpendCache.Changed -= SpendChanged;
        };
        PreviewKeyDown += Escape;
        Render();
    }
    private void SpendChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() => { if (IsLoaded) RenderGeneration(); });

    private bool InlinePrivacyGranted()
    {
        if (session.Connector is not { } connector) return false;
        if (connector.Group == "local") return !RemoteLocal || remoteLocalAllowed;
        var entry = ProviderWireId(connector.Connector.Id);
        return entry is not null && App.Services.Get("llm.cloudConsent." + entry, false);
    }

    private static string? ProviderWireId(VoxClip.Core.Services.LLM.ConnectorId id) => id switch
    {
        VoxClip.Core.Services.LLM.ConnectorId.Anthropic => "anthropic",
        VoxClip.Core.Services.LLM.ConnectorId.OpenAI => "openai",
        VoxClip.Core.Services.LLM.ConnectorId.Xai => "xai",
        VoxClip.Core.Services.LLM.ConnectorId.Gemini => "gemini",
        VoxClip.Core.Services.LLM.ConnectorId.ClaudeCode => "claude-code",
        VoxClip.Core.Services.LLM.ConnectorId.Codex => "codex",
        VoxClip.Core.Services.LLM.ConnectorId.Ollama => "ollama",
        VoxClip.Core.Services.LLM.ConnectorId.LmStudio => "lmstudio",
        _ => null
    };

    private async Task<bool> ApproveProposalAsync(VoiceLabPreparedAction action)
    {
        if (session.Connector is not { } connector) return false;
        var firstUse = !InlinePrivacyGranted();
        var billed = session.Estimate?.Kind == VoiceLabCostPresentationKind.Confirm;
        if (!firstUse && !billed) return true;
        var privacy = RemoteLocal ? "Allow these words to be sent to this server for this Rewrite session. No audio or video." : firstUse ? ConnectorConsent.Text(ConnectorConsentAction.Rewrite, connector.Connector.Id,
            connector.Name, session.Source.Count(word => word.Kind == VoxClip.Core.Domain.Shared.WordKind.Word),
            (connector.Connector as VoxClip.Core.Services.LLM.LlmConnector)?.CliDetection) : null;
        if (firstUse && privacy is null) return false;
        return await session.ConfirmCostAsync(action, async token =>
        {
            var status = await connector.Connector.GetStatusAsync(token);
            if (!session.CanPropose || !ReferenceEquals(session.Prepared, action))
            {
                if (session.IsOpen) await session.SetInstructionAsync(session.Instruction);
                return false;
            }
            var keyAccount = connector.Group == "apiKey" && status is VoxClip.Core.Services.LLM.ConnectorStatus.NeedsKey
                ? ProviderWireId(connector.Connector.Id) is { } provider ? "llm-api-key-" + provider : null : null;
            if (status is not VoxClip.Core.Services.LLM.ConnectorStatus.Ready && keyAccount is null) return false;
            using var pending = new InlineApproval(new(Guid.NewGuid(), action, firstUse ? "Allow this connector" : "Send this Rewrite?",
                SendLine, string.Join("\n", new[] { privacy, "No audio or video. " + connector.Model + "." + (billed ? " Asks before each send." : ""), session.EstimateCopy }
                    .Where(text => !string.IsNullOrWhiteSpace(text))), firstUse ? billed ? "Allow and Send" : "Allow and Rewrite" : "Send", billed, PricingPage(connector.Connector.Id)),
                () => session.CanPropose && ReferenceEquals(session.Prepared, action), token, Environment.TickCount);
            approval = pending;
            using var row = new InlineConfirmation(pending, () => RightColumn.RequestSourcePlayback(session.Editor), keyAccount is null ? null : async secret =>
            {
                if (!pending.IsPending) return false;
                await App.Services.Keys.SaveAsync(keyAccount!, secret, token);
                return pending.IsPending;
            });
            confirmation.Children.Clear(); confirmation.Children.Add(row);
            task.SetApproval(true); taskStatus.Text = task.Snapshot.Status;
            row.FocusTarget.Focus(FocusState.Programmatic);
            try
            {
                if (!await pending.Completion || !session.CanPropose || !ReferenceEquals(session.Prepared, action)) return false;
                if (RemoteLocal) remoteLocalAllowed = true;
                else if (firstUse && ProviderWireId(connector.Connector.Id) is { } wire)
                    await App.Services.SetAsync("llm.cloudConsent." + wire, true, token);
                return InlinePrivacyGranted();
            }
            finally
            {
                if (session.IsOpen && IsLoaded) instruction.Focus(FocusState.Programmatic);
                if (ReferenceEquals(approval, pending)) { approval = null; confirmation.Children.Clear(); }
                task.SetApproval(false);
            }
        });
    }
    private static Uri? PricingPage(VoxClip.Core.Services.LLM.ConnectorId id) => id switch
    {
        VoxClip.Core.Services.LLM.ConnectorId.Anthropic or VoxClip.Core.Services.LLM.ConnectorId.ClaudeCode => new("https://www.anthropic.com/pricing"),
        VoxClip.Core.Services.LLM.ConnectorId.OpenAI or VoxClip.Core.Services.LLM.ConnectorId.Codex => new("https://openai.com/api/pricing/"),
        VoxClip.Core.Services.LLM.ConnectorId.Gemini => new("https://ai.google.dev/gemini-api/docs/pricing"),
        VoxClip.Core.Services.LLM.ConnectorId.Xai => new("https://x.ai/api"),
        _ => null
    };

    private static void SetName(DependencyObject target, string name) => AutomationProperties.SetName(target, name);
#if DEBUG
    internal IReadOnlyList<string> DebugFitRequiredIds() => [.. ColumnBoundsGate.Rewrite,
        .. session.LocalAction is null ? Array.Empty<string>() : ["Rewrite.Apply"],
        .. session.Connector is null ? new[] { "Rewrite.Settings" } : Array.Empty<string>(),
        .. generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.Generate" } : Array.Empty<string>(),
        .. discover.Visibility == Visibility.Visible && generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.ChooseVoice" } : Array.Empty<string>(),
        .. noVoice.Visibility == Visibility.Visible && generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.CreateVoice" } : Array.Empty<string>(),
        .. languageUnavailable.Visibility == Visibility.Visible && generationBody.Visibility == Visibility.Visible ? new[] { "Rewrite.LanguageUnavailable" } : Array.Empty<string>(),
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
            approval?.Cancel(); task.Dispose();
            if (applyingTake) return;
            Closed?.Invoke(this, EventArgs.Empty); return;
        }
        Render();
    }
    private void Render()
    {
        if (approval is { IsPending: false } stale) stale.Cancel();
        taskStatus.Text = task.Snapshot.Status;
        updating = true;
        if (words.Text != session.NewWords) words.Text = session.NewWords;
        updating = false;
        propose.Content = session.ProposalButton;
        SetName(propose, session.ProposalButton);
        propose.IsEnabled = session.CanPropose;
        busy.IsActive = session.Editor.LlmRuns.IsBusy;
        busy.Visibility = busy.IsActive ? Visibility.Visible : Visibility.Collapsed;
        estimate.Text = session.EstimateCopy;
        estimate.FontSize = 11;
        problem.Text = session.Problem;
        problem.Visibility = session.Problem.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        RenderWordingFit();
        RenderChangeReview();
        if (session.Prepared is { } action) DispatcherQueue.TryEnqueue(() => session.MarkEstimateShown(action));
        RenderGeneration();
        RenderNextSteps();
        RenderFooter();
        if (IsLoaded)
            foreach (var message in announcements.Next(session.IsProposing, session.ProposalRevision, session.Problem, session.Review?.ChangeSummary ?? ""))
                Ui.Announce(this, message, "rewrite", AutomationNotificationProcessing.All);
    }
    private void BuildGeneration()
    {
        BuildWindowPicker();
        AutomationProperties.SetAutomationId(voice, "Rewrite.Voice");
        AutomationProperties.SetAutomationId(speechModel, "Rewrite.SpeechModel");
        SetName(speechModel, "Speech model: " + SpeechModelLabel);
        AutomationProperties.SetAutomationId(generate, "Rewrite.Generate");
        AutomationProperties.SetAutomationId(discover, "Rewrite.ChooseVoice");
        AutomationProperties.SetAutomationId(generationProgress, "Rewrite.GenerationProgress");
        AutomationProperties.SetAutomationId(generationError, "Rewrite.GenerationError");
        AutomationProperties.SetAutomationId(cancelGeneration, "Rewrite.GenerationCancel");
        var create = Ui.Button("Create Your Voice…", () =>
        {
            problem.Text = VoiceLabCopy.SpeakerUnavailable;
        });
        AutomationProperties.SetAutomationId(create, "Rewrite.CreateVoice");
        create.IsEnabled = VoxClip.Core.Services.VoiceLab.VoiceSpeakerCheck.WindowsNativeParityVerified;
        discover.IsEnabled = VoxClip.Core.Services.VoiceLab.VoiceSpeakerCheck.WindowsNativeParityVerified;
        noVoice.Children.Add(Small("No voice yet")); noVoice.Children.Add(create);
        noVoice.Children.Add(Small("Creating your voice isn't available on Windows yet."));
        // A voice made from here would be bound to English and never listed for this project (voice-lab.md §6.5.2).
        var unavailable = Small(VoiceLabCopy.LanguageUnavailable);
        AutomationProperties.SetAutomationId(unavailable, "Rewrite.LanguageUnavailable");
        SetName(unavailable, VoiceLabCopy.LanguageUnavailable);
        languageUnavailable.Children.Add(unavailable);
        discover.Click += async (_, _) => await session.DiscoverWindowsAsync();
        voice.SelectionChanged += async (_, _) =>
        { if (!updating) await session.ChooseVoiceForWindowsAsync(voice.SelectedValue as string); };
        generate.Click += async (_, _) =>
        {
            if (!VoxClip.Core.Services.VoiceLab.VoiceSpeakerCheck.WindowsNativeParityVerified) return;
            App.Services.BusyOperations++;
            try { await session.GenerateWindowsAsync(ConfirmVoiceActionAsync, ReadVoiceCapAsync); }
            finally { App.Services.BusyOperations--; }
        };
        cancelGeneration.Click += async (_, _) => await session.CancelWindowsAsync();
        var settings = Ui.Button("Open Settings", () => App.OpenSettings("Providers & Keys"));
        AutomationProperties.SetAutomationId(settings, "Rewrite.GenerationSettings");
        var retry = new Button { Content = "Retry" };
        AutomationProperties.SetAutomationId(retry, "Rewrite.GenerationRetry");
        retry.Click += async (_, _) =>
        {
            await session.DiscoverWindowsAsync();
        };
        generationError.ActionButton = settings; generationError.Content = retry;
        AutomationProperties.SetAutomationId(voiceText, "Rewrite.VoiceText");
        generationBody.Children.Add(discover); generationBody.Children.Add(voice); generationBody.Children.Add(voiceText); generationBody.Children.Add(speechModel);
        var prerequisite = new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Message = VoiceLabCopy.SpeakerUnavailable };
        AutomationProperties.SetAutomationId(prerequisite, "Rewrite.WindowsPrerequisite");
        generationBody.Children.Add(prerequisite); generationBody.Children.Add(monthlySpend);
        if (session.Generation is { } configured) configured.ConfigureSpendObserver(() => WorkflowSpendCache.RefreshAsync(App.Services.Data));
        generationBody.Children.Add(noVoice); generationBody.Children.Add(languageUnavailable);
        generationBody.Children.Add(Ui.Text("Takes", "BodyStrongTextBlockStyle"));
        BuildTakes();
        generationBody.Children.Add(generate); generationBody.Children.Add(autoFixAllowance); generationBody.Children.Add(takeSend);
        generationBody.Children.Add(generationBusy); generationBody.Children.Add(generationProgress);
        generationBody.Children.Add(cancelGeneration); generationBody.Children.Add(generationError); generationBody.Children.Add(nonePassed);
    }
    private void RenderGeneration()
    {
        RenderSentenceReview();
        RenderPaidReviewChange();
        takeSend.Text = session.TakeSendLine;
        monthlySpend.Text = WorkflowSpendCache.Monthly is { } total
            ? "ElevenLabs $" + total.Usd.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture) + " estimated this month" +
                (total.UnknownCount > 0 ? " · some charges unpriced" : "") : "ElevenLabs monthly spend unavailable";
        var generation = session.Generation;
        generationBody.Visibility = generation is not null && session.LocalAction is null ? Visibility.Visible : Visibility.Collapsed;
        if (generation is null) return;
        updating = true;
        windowPicker.Visibility = session.GenerationWindows.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (windowPicker.Items.Count != session.GenerationWindows.Count)
        {
            windowPicker.Items.Clear();
            for (var index = 0; index < session.GenerationWindows.Count; index++) windowPicker.Items.Add($"Passage {index + 1}");
        }
        windowPicker.SelectedIndex = session.ActiveWindow;
        windowPicker.IsEnabled = !session.IsGeneratingBatch;
        voice.IsEnabled = !session.IsGeneratingBatch;
        if (!ReferenceEquals(voice.ItemsSource, generation.Voices)) voice.ItemsSource = generation.Voices;
        voice.SelectedValue = generation.VoiceId;
        updating = false;
        // A voice that can't change is text, not a picker with one entry.
        voice.Visibility = generation.Voices.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        voiceText.Text = generation.Voices.Count == 1 ? "Voice: " + generation.Voices[0].Label : "";
        voiceText.Visibility = generation.Voices.Count == 1 ? Visibility.Visible : Visibility.Collapsed;
        speechModel.Visibility = generation.Voices.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        discover.Content = session.GetPriceTitle;
        discover.IsEnabled = VoxClip.Core.Services.VoiceLab.VoiceSpeakerCheck.WindowsNativeParityVerified && !session.IsGeneratingBatch && !generation.IsPreparing &&
            !session.WordingIsLocked;
        var unavailable = generation.Voices.Count == 0 && session.VoicesUnavailable;
        discover.Visibility = unavailable || session.PricedVoiceHunks.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        noVoice.Visibility = !unavailable && generation.HasDiscovered && generation.Voices.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        languageUnavailable.Visibility = unavailable ? Visibility.Visible : Visibility.Collapsed;
        var batch = session.PreparedBatch;
        var actionTitle = session.GenerationWindows.All(window => window.Rows.Count == 0) ? "Make take" : "Try another";
        var title = batch is null ? actionTitle : VoiceLabCostPresentation.ButtonTitle(actionTitle, null, batch.Kind());
        generate.Content = title;
        generate.Visibility = session.PricedVoiceHunks.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        generate.IsEnabled = VoxClip.Core.Services.VoiceLab.VoiceSpeakerCheck.WindowsNativeParityVerified && session.CanGenerateAll;
        SetName(generate, title); ToolTipService.SetToolTip(generate, title);
        var running = session.GenerationWindows.FirstOrDefault(window => window.IsRunning);
        var generating = running is not null;
        generationProgress.Text = generating ? running!.ProgressCopy : generation.IsPreparing ? "Preparing takes…" : "";
        generationBusy.IsActive = generating || generation.IsPreparing;
        generationBusy.Visibility = generationBusy.IsActive ? Visibility.Visible : Visibility.Collapsed;
        generationProgress.Visibility = generationBusy.Visibility;
        cancelGeneration.Visibility = session.IsGeneratingBatch ? Visibility.Visible : Visibility.Collapsed;
        generationError.Message = generation.Problem;
        generationError.IsOpen = generation.Problem.Length > 0;
        nonePassed.Visibility = generation.Phase == RewriteGenerationPhase.NonePassed ? Visibility.Visible : Visibility.Collapsed;
        RenderTakes(generation);
        RenderAutoFix();
        if (batch is not null) DispatcherQueue.TryEnqueue(() => session.MarkBatchEstimateShown(batch));
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
                    (request, _) => Task.FromResult(RewriteSourceFixture.Silent(request)), ct),
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
        if (args.Handled || textFocus?.OwnsComposition == true) return;
        if (args.Key == VirtualKey.Enter && !InputState.Down(VirtualKey.Control) && !InputState.Down(VirtualKey.Menu) &&
            !InputState.Down(VirtualKey.Shift) && apply.IsEnabled && apply.Visibility == Visibility.Visible &&
            session.FooterStep.Action is RewriteFooterAction.ApplyLocal or RewriteFooterAction.UseTakes or RewriteFooterAction.ApplyTextFixes or RewriteFooterAction.Done &&
            ShortcutPolicy.EditorMayHandle(
                InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot)), correctionOpen(), false, false, true) &&
            !NativeReturnTarget(FocusManager.GetFocusedElement(XamlRoot) as DependencyObject))
        {
            args.Handled = true;
            await ApplyFooterAsync();
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
    private void Close() { session.Dispose(); }
}
