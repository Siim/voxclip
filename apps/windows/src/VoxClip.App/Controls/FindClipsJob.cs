using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Services.LLM;
using Windows.System;

namespace VoxClip.App.Controls;

internal sealed class FindClipsJob
{
    private readonly EditorViewModel model;
    private readonly CancellationToken ct;
    private readonly StackPanel body = Ui.Stack(12);
    private readonly StackPanel confirmation = Ui.Stack(8);
    private InlineFindJob? host;
    private InlineApproval? approval;
    private bool retired;
    private long inputRevision;
    private long presentationRevision;
    private readonly TextBlock connector = Ui.Text("");
    private readonly HyperlinkButton change = new() { Content = "Change…", Padding = new(6, 0, 6, 0), Height = 32 };
    private readonly ComboBox preset = Ui.Choice("Preset", ["Best moments", "Hooks", "One per topic", "Quotes", "Custom"]);
    private readonly TextBox instructions = new() { Header = "Anything specific? (optional)", MaxLength = 500, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock footnote = Ui.Text("", "HelperText");
    private readonly TextBlock problem = Ui.Text("", "HelperText");
    private readonly Button find = new() { Content = "Find clips", HorizontalAlignment = HorizontalAlignment.Right };
    private readonly ProgressRing busy = new() { Width = 16, Height = 16, Visibility = Visibility.Collapsed };
    private ProviderEntry? entry;
    private CancellationTokenSource? search;
    /// <summary>A Find is past its first check: set before the awaited preflight, so a second click or Enter can't start
    /// another run.</summary>
    private bool starting;
    private FrameworkElement? anchor;

    internal FindClipsJob(EditorViewModel model, CancellationToken ct)
    {
        this.model = model; this.ct = ct;
        model.PropertyChanged += BusyChanged;
        find.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        var title = Ui.Text("Find clips in this take", "BodyStrongTextBlockStyle");
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        connector.VerticalAlignment = VerticalAlignment.Center;
        line.Children.Add(connector);
        line.Children.Add(change);
        AutomationProperties.SetName(change, "Change connector");
        AutomationProperties.SetName(busy, "AI request in progress");
        change.Click += (_, _) => { host?.RequestClose(); App.OpenSettings("Providers & Keys"); };
        preset.SelectionChanged += (_, _) =>
        {
            instructions.Header = preset.SelectedIndex == 4 ? "Describe the clips you want" : "Anything specific? (optional)";
            InputsChanged();
        };
        instructions.TextChanged += (_, _) => InputsChanged();
        instructions.KeyDown += (_, args) =>
        {
            if (host?.OwnsComposition == true || args.Handled || args.KeyStatus.WasKeyDown) return;
            if (args.Key != VirtualKey.Enter) return;
            args.Handled = true;
            _ = Start();
        };
        problem.Foreground = Ui.ThemeBrush(problem, "VcStatusWarningBrush");
        problem.Visibility = Visibility.Collapsed;
        find.Click += (_, _) => _ = Start();
        foreach (var child in new UIElement[] { title, line, preset, instructions, footnote, problem, busy, find, confirmation }) body.Children.Add(child);
    }

    /// <summary>The connector line while a search runs: "{connector} · reading {m:ss} of transcript"; null otherwise.</summary>
    internal string? Running { get; private set; }
    /// <summary>The callout under the sidebar actions, or null.</summary>
    internal SidebarCallout? Callout { get; private set; }
    /// <summary>The last run found nothing: the prompt file's message for the row under Suggested; null otherwise.</summary>
    internal string? NoneFound { get; private set; }
    internal event EventHandler? Changed;
    internal event EventHandler<string>? Announcement;
    /// <summary>Results arrived: the first new suggestion's clip id, which takes focus without being selected.</summary>
    internal event EventHandler<string>? Found;
    /// <summary>A Find clips action ended in a callout; the window makes it visible from the control that asked.</summary>
    internal event EventHandler<FrameworkElement?>? CalloutShown;

    /// <summary>Mount the inline job requested by <paramref name="target"/>. Missing connectors use the existing sidebar callout.</summary>
    internal async Task ShowAsync(FrameworkElement target, bool hooks = false)
    {
        if (Running is not null || model.Busy || model.IsLeaving || !model.HasTranscript) return;
        anchor = target;
        if (hooks) preset.SelectedIndex = 1;
        host?.RequestClose();
        host?.ReleaseBody();
        var presentation = ++presentationRevision;
        host = new(model, body, Cancel);
        await host.ShowAsync();
        if (presentation != presentationRevision) return;
        entry = await ChosenAsync();
        if (presentation != presentationRevision) return;
        if (entry is not { } chosen)
        {
            Show(ClipCallouts.NoConnector);
            return;
        }
        Set(null);
        connector.Text = $"{chosen.ShortName} · checking…";
        var address = App.Services.Get("llm.baseUrl." + chosen.WireId, "");
        footnote.Text = chosen.Group == "local" && Uri.TryCreate(address, UriKind.Absolute, out var server) && !server.IsLoopback
            ? $"Sends transcript text with word numbers to {server.Authority}. No audio or video."
            : chosen.Group == "local" ? "Runs on this PC. Nothing leaves it." : "Sends transcript text with word numbers. No audio or video.";
        problem.Visibility = Visibility.Collapsed;
        instructions.Focus(FocusState.Programmatic);
        try
        {
            var status = await ProviderCatalog.ProbeAsync(chosen, App.Services.Connector(chosen.Id), ct);
            if (presentation != presentationRevision || App.Services.Get("llm.connector", "") != chosen.WireId) return;
            connector.Text = $"{chosen.ShortName} · {ProviderCatalog.ShortStatus(status)}";
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (presentation == presentationRevision) connector.Text = $"{chosen.ShortName} · {ProviderCatalog.ShortStatus(new ConnectorStatus.Unavailable(exception.GetType().Name))}";
        }
    }

    /// <summary>Run the last search again from the callout's Retry.</summary>
    internal Task RetryAsync() => Start();
    /// <summary>A find began: Claude mode goes on once this task has ended (design §6.7), never inside it.</summary>
    internal event EventHandler<Task>? Started;
    private Task Start()
    {
        var task = FindAsync();
        Started?.Invoke(this, task);
        return task;
    }

    /// <summary>What the last find said when it failed; null otherwise.</summary>
    internal string? FailureText => Callout?.Title;

    /// <summary>Claude mode: starts a find with the job's defaults when the chosen AI needs no approval (a local server, or a CLI or
    /// key already allowed and not billed per send), and returns null; otherwise what blocks it, with its one fix.</summary>
    internal async Task<VoxClip.App.ViewModels.ClaudeModeBlocker?> FindIfFreeAsync()
    {
        if (Running is not null || starting) return null;
        ProviderEntry? chosen;
        try { chosen = await ChosenAsync(); }
        catch (Exception exception) when (exception is not OutOfMemoryException) { return new VoxClip.App.ViewModels.ClaudeModeBlocker.SetUp(UiError.Message(exception, "Find clips")); }
        if (chosen is null)
            return new VoxClip.App.ViewModels.ClaudeModeBlocker.SetUp("Claude isn't set up yet. Choose Claude Code in Settings › Providers & Keys, then Claude starts on its own.");
        var connector = App.Services.Connector(chosen.Id);
        ConnectorStatus status;
        try { status = await ProviderCatalog.ProbeAsync(chosen, connector, ct); }
        catch (Exception exception) when (exception is not OutOfMemoryException) { return new VoxClip.App.ViewModels.ClaudeModeBlocker.SetUp(UiError.Message(exception, "Find clips")); }
        if (status is not ConnectorStatus.Ready)
            return new VoxClip.App.ViewModels.ClaudeModeBlocker.SetUp($"{chosen.ShortName} isn't installed or signed in. Set it up in Settings › Providers & Keys.");
        var (firstUse, paid) = SendNeeds(chosen, connector);
        if (paid) return new VoxClip.App.ViewModels.ClaudeModeBlocker.ApproveSend($"{chosen.ShortName} bills each send to your key, so Claude waits for your OK to find clips.");
        if (firstUse) return new VoxClip.App.ViewModels.ClaudeModeBlocker.ApproveSend("Claude waits for your OK to read the transcript and find clips.");
        _ = Start();
        return null;
    }

    /// <summary>Whether a send to <paramref name="chosen"/> asks first: a first use of a cloud or CLI connector (or a remote server), or
    /// a send billed to a key.</summary>
    private static (bool FirstUse, bool Paid) SendNeeds(ProviderEntry chosen, LlmConnector selected)
    {
        var signIn = RewriteSession.SignIn(selected.CliDetection);
        var address = App.Services.Get("llm.baseUrl." + chosen.WireId, "");
        var remote = chosen.Group == "local" && Uri.TryCreate(address, UriKind.Absolute, out var server) && !server.IsLoopback;
        var firstUse = remote || (chosen.Cloud || chosen.Cli) && !App.Services.Get("llm.cloudConsent." + chosen.WireId, false) || chosen.Cli && signIn is null;
        var billing = VoxClip.Core.Domain.VoiceLab.VoiceLabCostPresentation.KindForLlmSend(chosen.Id, signIn,
            chosen.Cli ? chosen.Id == ConnectorId.ClaudeCode ? "Anthropic" : "OpenAI" : chosen.ShortName);
        return (firstUse, billing.Kind == VoxClip.Core.Domain.VoiceLab.VoiceLabCostPresentationKind.Confirm);
    }
    private void InputsChanged() { inputRevision++; approval?.Cancel(); search?.Cancel(); }
    internal void Cancel() { presentationRevision++; approval?.Cancel(); search?.Cancel(); }
    internal void Close() { retired = true; model.PropertyChanged -= BusyChanged; host?.RequestClose(); Cancel(); }
    private void BusyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        find.IsEnabled = !model.Busy && !model.IsLeaving;
        if (approval is { IsPending: false } stale) stale.Cancel();
        busy.IsActive = model.LlmRuns.IsBusy;
        busy.Visibility = busy.IsActive ? Visibility.Visible : Visibility.Collapsed;
    }
    internal void Dismiss() => Set(null);
#if DEBUG
    /// <summary>The shell probe shows the "Finding clips…" row without a connector.</summary>
    internal void DebugShowFinding(string? running) { Running = running; Changed?.Invoke(this, EventArgs.Empty); }
#endif

    private async Task FindAsync()
    {
        if (starting || Running is not null || model.Busy || model.IsLeaving || model.State is null) return;
        if (preset.SelectedIndex == 4 && string.IsNullOrWhiteSpace(instructions.Text))
        {
            Problem("Describe the clips you want.");
            instructions.Focus(FocusState.Programmatic);
            return;
        }
        using var run = model.LlmRuns.TryAcquire();
        if (run is null) return;
        starting = true;
        try
        {
            // Find and the callout's Retry run with the connector chosen now, not when the job last opened: Settings may
            // have changed or cleared it since (AI spec §11 gate 4).
            try { entry = await ChosenAsync(); }
            catch (OperationCanceledException) { return; }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            {
                Fail(exception);
                return;
            }
            if (entry is not { } chosen)
            {
                Show(ClipCallouts.NoConnector);
                return;
            }
            await FindWithAsync(chosen);
        }
        finally { starting = false; }
    }

    /// <summary>The connector llm.connector names now, or null for none.</summary>
    private async Task<ProviderEntry?> ChosenAsync()
    {
        var selected = App.Services.Get("llm.connector", "");
        return selected.Length == 0 ? null : ClipCallouts.Chosen(selected, await ProviderCatalog.ReadAsync(ct), item => item.WireId);
    }

    private async Task FindWithAsync(ProviderEntry chosen)
    {
        Func<CancellationToken, Task<bool>> authorize;
        if (model.State is not { } state || model.IsReadOnly) return;
        var captured = model.Project;
        var inputs = inputRevision;
        var presentation = presentationRevision;
        var chosenModel = App.Services.Get("llm.model." + chosen.WireId, chosen.DefaultModel);
        var address = App.Services.Get("llm.baseUrl." + chosen.WireId, "");
        var snap = App.Services.Get("llm.clips.snapToLines", true);
        var selectedPreset = (ClipPreset)Math.Max(0, preset.SelectedIndex);
        var instruction = instructions.Text;
        LlmConnector? requestConnector = null;
        CliSignIn? requestSignIn = null;
        bool Current() => !retired && !model.IsLeaving && !model.IsReadOnly && ReferenceEquals(captured, model.Project) &&
            inputs == inputRevision && presentation == presentationRevision && App.Services.Get("llm.connector", "") == chosen.WireId &&
            App.Services.Get("llm.model." + chosen.WireId, chosen.DefaultModel) == chosenModel &&
            App.Services.Get("llm.baseUrl." + chosen.WireId, "") == address && App.Services.Get("llm.clips.snapToLines", true) == snap &&
            (!chosen.Cli || requestConnector is not null && RewriteSession.SignIn(requestConnector.CliDetection) == requestSignIn);
        try
        {
            var selectedConnector = App.Services.Connector(chosen.Id);
            requestConnector = selectedConnector;
            var status = await ProviderCatalog.ProbeAsync(chosen, selectedConnector, ct);
            requestSignIn = RewriteSession.SignIn(selectedConnector.CliDetection);
            if (!Current()) return;
            if (status is not ConnectorStatus.Ready)
            {
                Show(ClipCallouts.NotReady(chosen.Id, chosen.Label, status, CliHint(chosen, "installHint"), CliHint(chosen, "signInHint")));
                return;
            }
            authorize = token => ApproveSendAsync(chosen, selectedConnector, captured, Current, token);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Fail(exception);
            return;
        }
        if (!Current()) return;
        search?.Dispose();
        search = CancellationTokenSource.CreateLinkedTokenSource(ct);
        App.Services.BusyOperations++;
        Running = $"{chosen.ShortName} · reading {EditorViewModel.Duration(model.Project.Media.Source.DurationSeconds)} of transcript";
        NoneFound = null;
        Set(null);
        Announcement?.Invoke(this, "Finding clips");
        try
        {
            var request = new ClipFinderRequest(state.Transcript.Words, state.Corrections, state.CutWordIds, selectedPreset,
                instruction, state.Transcript.Language, chosen.Id, chosenModel, Snap: snap);
            var result = await ConnectorPreflight.FindAsync(App.Services.ClipFinder, request, authorize, search.Token);
            if (result is null || !Current()) return;
            // None found reads the prompt file's message (design §13), under Suggested.
            var noneFound = result.Clips.Count == 0 ? await ProviderCatalog.ClipMessageAsync("noResults", search.Token) ?? ClipAnnouncements.NoResults : null;
            if (!Current()) return;
            var added = model.AddAiResult(result);
            NoneFound = noneFound;
            Announcement?.Invoke(this, ClipAnnouncements.Found(result.Clips.Count, NoneFound));
            if (added.Count > 0) Found?.Invoke(this, added[0]);
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is not OutOfMemoryException) { if (Current()) Fail(exception); }
        finally
        {
            App.Services.BusyOperations--;
            Running = null;
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    private async Task<bool> ApproveSendAsync(ProviderEntry chosen, LlmConnector selected, object snapshot, Func<bool> current, CancellationToken token)
    {
        if (!current()) return false;
        var signIn = RewriteSession.SignIn(selected.CliDetection);
        if (chosen.Cli && signIn is null) { Problem("Check the connector's sign-in method before sending."); return false; }
        var privacy = chosen.Cloud || chosen.Cli;
        var address = App.Services.Get("llm.baseUrl." + chosen.WireId, "");
        var remote = chosen.Group == "local" && Uri.TryCreate(address, UriKind.Absolute, out var server) && !server.IsLoopback ? server : null;
        var firstUse = remote is not null || privacy && !App.Services.Get("llm.cloudConsent." + chosen.WireId, false);
        var billing = VoxClip.Core.Domain.VoiceLab.VoiceLabCostPresentation.KindForLlmSend(chosen.Id, signIn,
            chosen.Cli ? chosen.Id == ConnectorId.ClaudeCode ? "Anthropic" : "OpenAI" : chosen.ShortName);
        var paid = billing.Kind == VoxClip.Core.Domain.VoiceLab.VoiceLabCostPresentationKind.Confirm;
        if (!firstUse && !paid) return current();
        var disclosure = ConnectorConsent.Text(ConnectorConsentAction.FindClips, chosen.Id, chosen.Label,
            model.Words.Count(word => word.Kind == VoxClip.Core.Domain.Shared.WordKind.Word), selected.CliDetection);
        if (privacy && disclosure is null) return false;
        using var pending = new InlineApproval(new(Guid.NewGuid(), snapshot, "Find clips with this connector?",
            remote is not null ? $"Sends transcript text with word numbers to {remote.Authority}. No audio or video." : disclosure ?? "Runs on this PC. Nothing leaves it.",
            billing.Text, firstUse ? "Allow and Find" : "Send", paid), current, token, Environment.TickCount);
        approval = pending;
        using var row = new InlineConfirmation(pending, () => RightColumn.RequestSourcePlayback(model));
        confirmation.Children.Clear(); confirmation.Children.Add(row); row.FocusTarget.Focus(FocusState.Programmatic);
        try
        {
            if (!await pending.Completion || !current() || signIn != RewriteSession.SignIn(selected.CliDetection)) return false;
            if (firstUse && remote is null) await App.Services.SetAsync("llm.cloudConsent." + chosen.WireId, true, token);
            return current();
        }
        finally { if (ReferenceEquals(approval, pending)) { approval = null; confirmation.Children.Clear(); } }
    }

    private sealed class InlineFindJob : InlineEditorJob
    {
        internal InlineFindJob(EditorViewModel model, StackPanel content, Action cancel) : base(model)
        {
            JobLabel = "Find clips"; Title = "Find clips in this take";
            Content = new ScrollViewer { Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
            PrimaryButtonVisible = false; CloseButtonText = "Close";
            CloseButtonClick += (_, _) => cancel();
            Abandoned += (_, _) => cancel();
        }
        internal void ReleaseBody() { if (Content is ScrollViewer scroll) scroll.Content = null; Content = null; }
    }

    private static string? CliHint(ProviderEntry chosen, string key) =>
        chosen.Metadata.TryGetProperty("cli", out var cli) && cli.TryGetProperty(key, out var hint) ? hint.GetString() : null;

    /// <summary>Any other failure (design §13). A cancelled run has no message and shows nothing.</summary>
    private void Fail(Exception exception)
    {
        if (UiError.Message(exception, "Find clips") is { Length: > 0 } message) Show(ClipCallouts.Failed(message));
    }

    /// <summary>Show a callout and say it: the window brings it into view and points at it from the control that asked.</summary>
    private void Show(SidebarCallout callout)
    {
        Set(callout);
        Announcement?.Invoke(this, $"{callout.Title} {callout.Message}".Trim());
        CalloutShown?.Invoke(this, anchor);
    }

    private void Problem(string text)
    {
        problem.Text = text;
        problem.Visibility = Visibility.Visible;
    }

    private void Set(SidebarCallout? callout)
    {
        Callout = callout;
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
