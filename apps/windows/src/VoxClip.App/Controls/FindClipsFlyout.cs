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

/// <summary>Find clips (design §6.2): one flyout, anchored to the control that opened it, holding the connector line with
/// Change…, the preset, the instructions and the disclosure footnote. Finding closes the flyout; the sidebar then shows
/// "Finding clips…" under Suggested with Cancel, a run that finds nothing says so under Suggested, and a missing
/// connector or a failure shows as a callout under the sidebar actions with §13's copy. Results arrive as suggestions in
/// one undo step. Without a transcript Find clips is disabled (design §7.1).</summary>
internal sealed class FindClipsFlyout
{
    private const string NoResults = "No clips matched. Try another style or describe what you want.";
    private readonly EditorViewModel model;
    private readonly CancellationToken ct;
    private readonly Flyout flyout = new() { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
    private readonly TextBlock connector = Ui.Text("");
    private readonly HyperlinkButton change = new() { Content = "Change…", Padding = new(6, 0, 6, 0), Height = 32 };
    private readonly ComboBox preset = Ui.Choice("Preset", ["Best moments", "Hooks", "One per topic", "Quotes", "Custom"]);
    private readonly TextBox instructions = new() { Header = "Anything specific? (optional)", MaxLength = 500, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock footnote = Ui.Text("", "HelperText");
    private readonly TextBlock problem = Ui.Text("", "HelperText");
    private readonly Button find = new() { Content = "Find clips", HorizontalAlignment = HorizontalAlignment.Right };
    private ProviderEntry? entry;
    private CancellationTokenSource? search;
    /// <summary>A Find is past its first check: set before the awaited preflight, so a second click or Enter can't start
    /// another run.</summary>
    private bool starting;
    private FrameworkElement? anchor;

    internal FindClipsFlyout(EditorViewModel model, CancellationToken ct)
    {
        this.model = model; this.ct = ct;
        find.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        var title = Ui.Text("Find clips in this take", "BodyStrongTextBlockStyle");
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        connector.VerticalAlignment = VerticalAlignment.Center;
        line.Children.Add(connector);
        line.Children.Add(change);
        AutomationProperties.SetName(change, "Change connector");
        change.Click += (_, _) => { flyout.Hide(); App.OpenSettings("Providers & Keys"); };
        preset.SelectionChanged += (_, _) => instructions.Header = preset.SelectedIndex == 4 ? "Describe the clips you want" : "Anything specific? (optional)";
        instructions.KeyDown += (_, args) =>
        {
            if (args.Key != VirtualKey.Enter) return;
            args.Handled = true;
            _ = FindAsync();
        };
        problem.Foreground = Ui.ThemeBrush(problem, "VcStatusWarningBrush");
        problem.Visibility = Visibility.Collapsed;
        find.Click += (_, _) => _ = FindAsync();
        var body = Ui.Stack(12);
        body.Width = 340;
        foreach (var child in new UIElement[] { title, line, preset, instructions, footnote, problem, find }) body.Children.Add(child);
        flyout.Content = body;
        flyout.Opened += (_, _) => instructions.Focus(FocusState.Programmatic);
        flyout.Closed += (_, _) => anchor?.Focus(FocusState.Programmatic);
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

    /// <summary>Open the flyout at <paramref name="target"/>; with no connector chosen, the callout under the sidebar actions
    /// replaces it (design §6.2).</summary>
    internal async Task ShowAsync(FrameworkElement target)
    {
        if (Running is not null || model.Busy || model.IsLeaving || !model.HasTranscript) return;
        anchor = target;
        var selected = App.Services.Get("llm.connector", "");
        entry = selected.Length == 0 ? null : (await ProviderCatalog.ReadAsync(ct)).FirstOrDefault(item => item.WireId == selected);
        if (entry is null)
        {
            Show(ClipCallouts.NoConnector);
            return;
        }
        Set(null);
        connector.Text = $"{entry.ShortName} · checking…";
        footnote.Text = entry.Group == "local" ? "Runs on this PC. Nothing leaves it." : "Sends transcript text with word numbers. No audio or video.";
        problem.Visibility = Visibility.Collapsed;
        flyout.ShowAt(target);
        try { connector.Text = $"{entry.ShortName} · {ProviderCatalog.ShortStatus(await App.Services.Connector(entry.Id).GetStatusAsync(ct))}"; }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is not OutOfMemoryException) { connector.Text = $"{entry.ShortName} · {ProviderCatalog.ShortStatus(new ConnectorStatus.Unavailable(exception.GetType().Name))}"; }
    }

    /// <summary>Run the last search again from the callout's Retry.</summary>
    internal Task RetryAsync() => FindAsync();
    internal void Cancel() => search?.Cancel();
    internal void Dismiss() => Set(null);
#if DEBUG
    /// <summary>The shell probe shows the "Finding clips…" row without a connector.</summary>
    internal void DebugShowFinding(string? running) { Running = running; Changed?.Invoke(this, EventArgs.Empty); }
#endif

    private async Task FindAsync()
    {
        if (starting || Running is not null || model.Busy || model.IsLeaving || model.State is null || entry is not { } chosen) return;
        if (preset.SelectedIndex == 4 && string.IsNullOrWhiteSpace(instructions.Text))
        {
            Problem("Describe the clips you want.");
            instructions.Focus(FocusState.Programmatic);
            return;
        }
        starting = true;
        try { await FindWithAsync(chosen); }
        finally { starting = false; }
    }

    private async Task FindWithAsync(ProviderEntry chosen)
    {
        try
        {
            // The connector's preflight (AI spec §4): a connector that isn't ready explains itself under the actions.
            var status = await App.Services.Connector(chosen.Id).GetStatusAsync(ct);
            if (model.IsLeaving) return;
            if (status is not ConnectorStatus.Ready)
            {
                flyout.Hide();
                Show(ClipCallouts.NotReady(chosen.Id, chosen.Label, status, CliHint(chosen, "installHint"), CliHint(chosen, "signInHint")));
                return;
            }
            if (!await ProviderCatalog.ConsentAsync(chosen, anchor?.XamlRoot ?? flyout.XamlRoot, ct) || model.IsLeaving) return;
        }
        catch (OperationCanceledException) { return; }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            flyout.Hide();
            Fail(exception);
            return;
        }
        flyout.Hide();
        if (model.State is not { } state) return;
        search?.Dispose();
        search = CancellationTokenSource.CreateLinkedTokenSource(ct);
        model.Busy = true; App.Services.BusyOperations++;
        Running = $"{chosen.ShortName} · reading {EditorViewModel.Duration(model.Project.Media.Source.DurationSeconds)} of transcript";
        NoneFound = null;
        Set(null);
        Announcement?.Invoke(this, "Finding clips");
        try
        {
            var request = new ClipFinderRequest(state.Transcript.Words, state.Corrections, state.CutWordIds, (ClipPreset)Math.Max(0, preset.SelectedIndex),
                instructions.Text, state.Transcript.Language, chosen.Id, App.Services.Get("llm.model." + chosen.WireId, chosen.DefaultModel));
            var result = await App.Services.ClipFinder.FindClipsAsync(request, null, search.Token);
            if (model.IsLeaving) return;
            var added = model.AddAiResult(result);
            // None found reads the prompt file's message (design §13), under Suggested.
            if (result.Clips.Count == 0) NoneFound = await ProviderCatalog.ClipMessageAsync("noResults", ct) ?? NoResults;
            Announcement?.Invoke(this, result.Clips.Count == 0 ? NoneFound! : result.Clips.Count == 1 ? "Found 1 clip" : $"Found {result.Clips.Count} clips");
            if (added.Count > 0) Found?.Invoke(this, added[0]);
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is not OutOfMemoryException) { Fail(exception); }
        finally
        {
            model.Busy = false; App.Services.BusyOperations--;
            Running = null;
            Changed?.Invoke(this, EventArgs.Empty);
        }
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
