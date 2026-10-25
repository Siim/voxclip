using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Media.Captions;

namespace VoxClip.App.Controls;

internal sealed class InspectorView : UserControl
{
    private readonly EditorViewModel model;
    private readonly CancellationToken ct;
    private readonly StackPanel body = Ui.Stack(16);
    private readonly InfoBar notice = Ui.Notice();
    private readonly SelectorBar tabs = new();
    private readonly SelectorBarItem captions = new() { Text = "Captions" };
    private readonly SelectorBarItem clips = new() { Text = "Clips" };
    private IReadOnlyList<ProviderEntry> providers = [];
    private ComboBox? provider;
    private TextBox? modelId;
    private ComboBox? preset;
    private TextBox? instructions;
    private StackPanel? results;
    private TextBlock? connectorStatus;
    private StackPanel? inlineKey;
    private ProgressRing? finding;
    private TextBlock? findingLabel;
    private Button? cancelFinding;
    private CancellationTokenSource? search;
    private ImageSource? still;
    private readonly SemaphoreSlim tileJobs = new(1, 1);
    internal IReadOnlyList<CaptionStyle> Styles { get; private set; } = [];
    internal bool ClipsActive => tabs.SelectedItem == clips;
    internal event EventHandler? TabChanged;

    internal InspectorView(EditorViewModel model, Func<EditState?, Task<ComposeSnapshot>> snapshot, CancellationToken ct)
    {
        this.model = model; this.ct = ct;
        IsTabStop = true;
        tabs.Items.Add(captions); tabs.Items.Add(clips); tabs.Items.Add(new SelectorBarItem { Text = "AI", IsEnabled = false });
        tabs.SelectedItem = captions;
        var layout = new Grid { Padding = new Thickness(16), RowSpacing = 16 };
        layout.RowDefinitions.Add(new() { Height = GridLength.Auto }); layout.RowDefinitions.Add(new());
        layout.Children.Add(tabs);
        var scroll = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetRow(scroll, 1); layout.Children.Add(scroll); Content = layout;
        tabs.SelectionChanged += (_, _) => { Render(); TabChanged?.Invoke(this, EventArgs.Empty); };
        model.Changed += ModelChanged;
    }
    internal async Task InitializeAsync()
    {
        await Ui.RunAsync(notice, async () => { Styles = await App.Services.ReadStylesAsync(ct); providers = await ProviderCatalog.ReadAsync(ct); }, "Inspector");
        Render();
    }
    internal void SelectTab(bool showClips) => tabs.SelectedItem = showClips ? clips : captions;
    internal void UpdateStill(PixelBuffer frame)
    {
        if (still is not null || frame.Width <= 0 || frame.Height <= 0) return;
        const int width = 128, height = 80;
        var image = new WriteableBitmap(width, height);
        using (var target = image.PixelBuffer.AsStream())
        {
            var row = new byte[width * 4];
            for (var y = 0; y < height; y++)
            {
                var sourceY = y * frame.Height / height;
                for (var x = 0; x < width; x++)
                {
                    var sourceX = x * frame.Width / width;
                    var offset = sourceY * frame.Stride + sourceX * 4;
                    for (var channel = 0; channel < 3; channel++) row[x * 4 + channel] = (byte)(frame.Pixels.Span[offset + channel] * 0.85);
                    row[x * 4 + 3] = 255;
                }
                target.Write(row);
            }
        }
        image.Invalidate(); still = image;
        if (tabs.SelectedItem == captions) RenderCaptions();
    }
    private void Render()
    {
        body.Children.Clear(); body.Children.Add(notice);
        if (ClipsActive) RenderClips(); else RenderCaptions();
    }
    private void RenderCaptions()
    {
        while (body.Children.Count > 1) body.Children.RemoveAt(1);
        body.Children.Add(Ui.Text("Caption style", "SubtitleTextBlockStyle"));
        body.Children.Add(Ui.Text("Burned into the video at export. Your source stays untouched.", "HelperText"));
        var gallery = new RadioButtons { MaxColumns = 2 };
        AutomationProperties.SetName(gallery, "Caption style");
        void AddStyle(string id, string name, CaptionStyle? style)
        {
            var tile = Ui.Stack(4);
            var preview = new Grid { Width = 128, Height = 80, Background = Ui.ThemeBrush(this, "VcBgMutedBrush") };
            if (still is not null) preview.Children.Add(new Image { Source = still, Stretch = Stretch.UniformToFill });
            if (style is not null) _ = RenderTileAsync(style, preview);
            tile.Children.Add(preview);
            tile.Children.Add(new TextBlock { Text = id == "off" ? "Off · Just the video" : name, TextWrapping = TextWrapping.Wrap, MaxWidth = 128 });
            var item = new RadioButton { Content = tile, Tag = id, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(item, id == "off" ? "Off, just the video" : name);
            gallery.Items.Add(item);
        }
        AddStyle("off", "Off", null);
        foreach (var style in Styles) AddStyle(style.Id, style.Name, style);
        gallery.SelectedItem = gallery.Items.OfType<RadioButton>().FirstOrDefault(item => (string)item.Tag == model.Project.Captions.StyleId);
        gallery.SelectionChanged += (_, _) => { if (gallery.SelectedItem is RadioButton item) model.SetCaptionStyle((string)item.Tag); };
        body.Children.Add(gallery);
        if (Styles.Count == 0) Ui.Show(notice, "Caption styles aren't available. Your media and edits are still here.", InfoBarSeverity.Warning);
    }
    private async Task RenderTileAsync(CaptionStyle style, Grid tile)
    {
        try
        {
            if (App.Services.SharedRoot is not { } root) return;
            var words = style.Preview.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Select((word, index) => new CaptionWord($"preview-{index}", word, index * 0.4, index * 0.4 + 0.35)).ToArray();
            var sampleTime = style.Preview.ActiveWord * 0.4 + Math.Min(style.Preview.Progress, 0.98) * 0.35;
            await tileJobs.WaitAsync(ct);
            PixelBuffer overlay;
            try
            {
                overlay = await Task.Run(async () =>
                {
                    var tileCaptions = new ProjectCaptions(style.Id, System.Text.Json.JsonSerializer.SerializeToElement(new Dictionary<string, object>()), null, new Dictionary<string, CaptionPosition>());
                    var track = await CaptionEngine.BuildAsync(new(style, tileCaptions, new(1280, 800), words,
                        "en", words.Length * 0.4 + 0.5), new HarfBuzzGlyphShaper(root), null, ct);
                    return await new SkiaCaptionRasterizer(root).RenderAsync(new(track, sampleTime, ReduceMotion: true, Scale: 0.1), ct);
                }, ct);
            }
            finally { tileJobs.Release(); }
            if (overlay.Width != 128 || overlay.Height != 80) throw new InvalidDataException("Caption tile size is invalid.");
            var image = new WriteableBitmap(128, 80);
            using (var stream = image.PixelBuffer.AsStream()) stream.Write(overlay.Pixels.Span);
            image.Invalidate();
            tile.Children.Add(new Image { Source = image, Stretch = Stretch.Fill });
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { Ui.Show(notice, UiError.Message(exception, "Caption preview"), InfoBarSeverity.Warning); }
    }
    private void RenderClips()
    {
        body.Children.Add(Ui.Text("Find clips in this take", "SubtitleTextBlockStyle"));
        body.Children.Add(Ui.Text("You can also select words and press Ctrl+K to make a clip yourself.", "HelperText"));
        body.Children.Add(Ui.Button("Make clip from selection", () => model.MakeClip()));
        provider = new ComboBox { Header = "Connector", HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(provider, "Connector");
        provider.Items.Add(new ComboBoxItem { Content = "Choose a connector…" });
        foreach (var group in new[] { ("apiKey", "Your API key"), ("local", "On this computer"), ("cli", "Installed CLI (your own sign-in)") })
        {
            if (!providers.Any(entry => entry.Group == group.Item1)) continue;
            provider.Items.Add(new ComboBoxItem { Content = group.Item2, IsEnabled = false });
            foreach (var entry in providers.Where(entry => entry.Group == group.Item1)) provider.Items.Add(new ComboBoxItem { Content = entry.Label, Tag = entry });
        }
        var selected = App.Services.Get("llm.connector", "");
        provider.SelectedItem = provider.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag is ProviderEntry entry && entry.WireId == selected) ?? provider.Items[0];
        modelId = new TextBox { Header = "Model ID", Text = selected.Length == 0 ? "" : App.Services.Get("llm.model." + selected, providers.FirstOrDefault(entry => entry.WireId == selected)?.DefaultModel ?? ""), PlaceholderText = "Choose a connector first" };
        const string noConnector = "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI.";
        var flow = Ui.Text(noConnector, "HelperText");
        connectorStatus = Ui.Text("", "HelperText");
        inlineKey = Ui.Stack(8);
        provider.SelectionChanged += async (_, _) =>
        {
            var entry = SelectedProvider();
            modelId.Text = entry is null ? "" : App.Services.Get("llm.model." + entry.WireId, entry.DefaultModel);
            flow.Text = entry is null ? noConnector : entry.Group == "local"
                ? "Runs on this PC. Nothing leaves it." : "Sends transcript text with word numbers. No audio or video.";
            if (entry is not null) await Ui.RunAsync(notice, () => App.Services.SetAsync("llm.connector", entry.WireId, ct), "Connector");
            await RefreshConnectorAsync();
        };
        preset = Ui.Choice("Find", ["Best moments", "Hooks", "One per topic", "Quotes", "Custom"]);
        instructions = new TextBox { Header = "Anything specific? (optional)", AcceptsReturn = true, MaxLength = 500, TextWrapping = TextWrapping.Wrap };
        preset.SelectionChanged += (_, _) => instructions.Header = preset.SelectedIndex == 4 ? "Describe the clips you want" : "Anything specific? (optional)";
        finding = new ProgressRing { Width = 24, Height = 24, IsActive = false, Visibility = Visibility.Collapsed };
        AutomationProperties.SetName(finding, "Finding clips…");
        findingLabel = Ui.Text("Finding clips…", "HelperText"); findingLabel.Visibility = Visibility.Collapsed;
        cancelFinding = Ui.Button("Cancel", () => search?.Cancel()); cancelFinding.Visibility = Visibility.Collapsed;
        body.Children.Add(provider); body.Children.Add(connectorStatus); body.Children.Add(flow); body.Children.Add(inlineKey); body.Children.Add(modelId); body.Children.Add(preset); body.Children.Add(instructions);
        body.Children.Add(Ui.Button("Find clips", () => _ = Ui.RunAsync(notice, FindAsync, "Find clips"), true));
        body.Children.Add(finding); body.Children.Add(findingLabel); body.Children.Add(cancelFinding);
        body.Children.Add(Ui.Button("Providers & Keys…", App.OpenSettings));
        results = Ui.Stack(16); body.Children.Add(results); RenderResults();
        _ = RefreshConnectorAsync();
    }
    private ProviderEntry? SelectedProvider() => (provider?.SelectedItem as ComboBoxItem)?.Tag as ProviderEntry;
    private async Task RefreshConnectorAsync()
    {
        if (connectorStatus is null || inlineKey is null) return;
        var entry = SelectedProvider();
        inlineKey.Children.Clear();
        if (entry is null) { connectorStatus.Text = ""; return; }
        connectorStatus.Text = "Checking status…";
        try
        {
            var status = await App.Services.Connector(entry.Id).GetStatusAsync(ct);
            if (SelectedProvider()?.WireId != entry.WireId) return;
            connectorStatus.Text = ProviderCatalog.ShortStatus(status);
            if (status is ConnectorStatus.NeedsKey && entry.Account is { } account)
            {
                var key = new PasswordBox { Header = entry.Label + " API key", PasswordRevealMode = PasswordRevealMode.Hidden };
                var save = Ui.Button("Save key", () => _ = Ui.RunAsync(notice, async () =>
                {
                    var secret = key.Password; key.Password = "";
                    if (string.IsNullOrWhiteSpace(secret)) return;
                    await App.Services.Keys.SaveAsync(account, secret, ct);
                    await RefreshConnectorAsync();
                }, "Save key"));
                save.IsEnabled = false; key.PasswordChanged += (_, _) => save.IsEnabled = !string.IsNullOrWhiteSpace(key.Password);
                inlineKey.Children.Add(key); inlineKey.Children.Add(save);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { connectorStatus.Text = UiError.Message(exception, "Connector"); }
    }
    private async Task FindAsync()
    {
        if (model.Busy || model.State is null) return;
        if (preset?.SelectedIndex == 4 && string.IsNullOrWhiteSpace(instructions?.Text)) { Ui.Show(notice, "Describe the clips you want."); instructions?.Focus(FocusState.Programmatic); return; }
        if (SelectedProvider() is not { } entry) { Ui.Show(notice, "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI. Manual clips work without one."); return; }
        var status = await App.Services.Connector(entry.Id).GetStatusAsync(ct);
        if (status is not ConnectorStatus.Ready) { Ui.Show(notice, ProviderCatalog.Status(status), InfoBarSeverity.Warning); return; }
        if (!await ProviderCatalog.ConsentAsync(entry, XamlRoot, ct)) return;
        search?.Dispose(); search = CancellationTokenSource.CreateLinkedTokenSource(ct);
        model.Busy = true; App.Services.BusyOperations++;
        if (finding is not null) { finding.IsActive = true; finding.Visibility = Visibility.Visible; }
        if (findingLabel is not null) findingLabel.Visibility = Visibility.Visible;
        if (cancelFinding is not null) cancelFinding.Visibility = Visibility.Visible;
        try
        {
            var state = model.State;
            var request = new ClipFinderRequest(state.Transcript.Words, state.Corrections, state.CutWordIds, (ClipPreset)(preset?.SelectedIndex ?? 0), instructions?.Text,
                state.Transcript.Language, entry.Id, modelId?.Text.Trim() ?? entry.DefaultModel);
            var result = await App.Services.ClipFinder.FindClipsAsync(request, new Progress<ClipFinderProgress>(value => Ui.Show(notice, value.Stage)), search.Token);
            model.AddAiResult(result); Ui.Show(notice, result.Clips.Count == 0 ? "No clips matched. Try another style or describe what you want." : $"Found {result.Clips.Count} clips. Your cuts are unchanged.");
        }
        finally
        {
            model.Busy = false; App.Services.BusyOperations--;
            if (finding is not null) { finding.IsActive = false; finding.Visibility = Visibility.Collapsed; }
            if (findingLabel is not null) findingLabel.Visibility = Visibility.Collapsed;
            if (cancelFinding is not null) cancelFinding.Visibility = Visibility.Collapsed;
        }
    }
    private void RenderResults()
    {
        if (results is null) return;
        results.Children.Clear();
        if (model.Clips.Count == 0) results.Children.Add(Ui.Text("No clips yet. Select words to make your first clip.", "HelperText"));
        foreach (var row in model.Clips)
        {
            var card = Ui.Stack(8);
            var selected = new CheckBox { Content = row.Title, IsChecked = row.Selected };
            selected.Click += (_, _) => model.Apply(new EditOperation.SetClipSelected(row.Id, selected.IsChecked == true));
            card.Children.Add(selected); card.Children.Add(Ui.Text(row.Detail, "HelperText")); card.Children.Add(Ui.Text(row.Excerpt));
            if (row.Reason.Length > 0) card.Children.Add(Ui.Text(row.Reason, "HelperText"));
            var name = new TextBox { Header = "Clip title", Text = row.Title };
            name.LostFocus += (_, _) => { if (name.Text != row.Title) model.Apply(new EditOperation.RenameClip(row.Id, name.Text.Trim())); };
            card.Children.Add(name);
            var nudges = Ui.Stack(4); nudges.Orientation = Orientation.Horizontal;
            nudges.Children.Add(Ui.Button("Start −", () => model.Nudge(row, true, -1))); nudges.Children.Add(Ui.Button("Start +", () => model.Nudge(row, true, 1)));
            nudges.Children.Add(Ui.Button("End −", () => model.Nudge(row, false, -1))); nudges.Children.Add(Ui.Button("End +", () => model.Nudge(row, false, 1)));
            card.Children.Add(nudges); card.Children.Add(Ui.Button("Preview clip", () => model.Apply(new EditOperation.SetActiveClip(row.Id))));
            card.Children.Add(Ui.Button("Copy transcript", () => ShareHelpers.Copy(row.Excerpt)));
            card.Children.Add(Ui.Button("Remove clip", () => model.Apply(new EditOperation.RemoveClip(row.Id))));
            results.Children.Add(card);
        }
        if (model.Clips.Count > 0) results.Children.Add(Ui.Button("Back to full take", () => model.Apply(new EditOperation.SetActiveClip(null))));
    }
    private void ModelChanged(object? sender, EventArgs args) { if (ClipsActive) RenderResults(); }
    internal void Detach() { model.Changed -= ModelChanged; search?.Cancel(); search?.Dispose(); }
}
