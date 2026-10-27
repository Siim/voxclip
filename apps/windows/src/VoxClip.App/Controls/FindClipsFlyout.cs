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
/// "Finding clips…" under Suggested with Cancel, and a missing connector or a failure shows as a callout under the sidebar
/// actions. Results arrive as suggestions in one undo step.</summary>
internal sealed class FindClipsFlyout
{
    private const string NoConnector = "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI.";
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
    internal event EventHandler? Changed;
    internal event EventHandler<string>? Announcement;
    /// <summary>Results arrived: the first new suggestion's clip id, which takes focus without being selected.</summary>
    internal event EventHandler<string>? Found;

    /// <summary>Open the flyout at <paramref name="target"/>; with no connector chosen, show the no-connector callout instead.</summary>
    internal async Task ShowAsync(FrameworkElement target)
    {
        if (Running is not null || model.Busy || model.IsLeaving) return;
        if (!model.HasTranscript) { Set(new("Transcribe this video before finding clips.", "Your video is still here.", "")); return; }
        anchor = target;
        var selected = App.Services.Get("llm.connector", "");
        entry = selected.Length == 0 ? null : (await ProviderCatalog.ReadAsync(ct)).FirstOrDefault(item => item.WireId == selected);
        if (entry is null)
        {
            Set(new(NoConnector, "You can also select words and press Ctrl+K to make a clip yourself.", "Set up AI…"));
            return;
        }
        Set(null);
        connector.Text = $"{entry.Label} · checking…";
        footnote.Text = entry.Group == "local" ? "Runs on this PC. Nothing leaves it." : "Sends transcript text with word numbers. No audio or video.";
        problem.Visibility = Visibility.Collapsed;
        flyout.ShowAt(target);
        try { connector.Text = $"{entry.Label} · {ProviderCatalog.ShortStatus(await App.Services.Connector(entry.Id).GetStatusAsync(ct))}"; }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is not OutOfMemoryException) { connector.Text = $"{entry.Label} · {ProviderCatalog.ShortStatus(new ConnectorStatus.Unavailable(exception.GetType().Name))}"; }
    }

    /// <summary>Run the last search again from the callout's Retry.</summary>
    internal Task RetryAsync() => FindAsync();
    internal void Cancel() => search?.Cancel();
    internal void Dismiss() => Set(null);

    private async Task FindAsync()
    {
        if (Running is not null || model.Busy || model.IsLeaving || model.State is null || entry is not { } chosen) return;
        if (preset.SelectedIndex == 4 && string.IsNullOrWhiteSpace(instructions.Text))
        {
            Problem("Describe the clips you want.");
            instructions.Focus(FocusState.Programmatic);
            return;
        }
        try
        {
            var status = await App.Services.Connector(chosen.Id).GetStatusAsync(ct);
            if (model.IsLeaving) return;
            if (status is not ConnectorStatus.Ready) { flyout.Hide(); Set(new($"{chosen.Label} can't find clips right now.", ProviderCatalog.Status(status), "Retry")); return; }
            if (!await ProviderCatalog.ConsentAsync(chosen, anchor?.XamlRoot ?? flyout.XamlRoot, ct) || model.IsLeaving) return;
        }
        catch (OperationCanceledException) { return; }
        flyout.Hide();
        search?.Dispose();
        search = CancellationTokenSource.CreateLinkedTokenSource(ct);
        model.Busy = true; App.Services.BusyOperations++;
        var state = model.State;
        Running = $"{chosen.Label} · reading {EditorViewModel.Duration(model.Project.Media.Source.DurationSeconds)} of transcript";
        Set(null);
        Announcement?.Invoke(this, "Finding clips");
        try
        {
            var request = new ClipFinderRequest(state.Transcript.Words, state.Corrections, state.CutWordIds, (ClipPreset)Math.Max(0, preset.SelectedIndex),
                instructions.Text, state.Transcript.Language, chosen.Id, App.Services.Get("llm.model." + chosen.WireId, chosen.DefaultModel));
            var result = await App.Services.ClipFinder.FindClipsAsync(request, null, search.Token);
            if (model.IsLeaving) return;
            var added = model.AddAiResult(result);
            if (result.Clips.Count == 0) Set(new("No clips matched.", "Try another style or describe what you want.", "Find clips…"));
            Announcement?.Invoke(this, result.Clips.Count == 0 ? "No clips matched." : result.Clips.Count == 1 ? "Found 1 clip" : $"Found {result.Clips.Count} clips");
            if (added.Count > 0) Found?.Invoke(this, added[0]);
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Set(new("Couldn't find clips.", UiError.Message(exception, "Find clips"), "Retry"));
        }
        finally
        {
            model.Busy = false; App.Services.BusyOperations--;
            Running = null;
            Changed?.Invoke(this, EventArgs.Empty);
        }
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
