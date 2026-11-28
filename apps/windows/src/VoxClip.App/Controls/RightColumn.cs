using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Runtime.CompilerServices;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

internal sealed class RightColumn : Grid
{
    private static readonly ConditionalWeakTable<EditorViewModel, RightColumn> hosts = new();
    private readonly Border fade = new() { Height = 12, VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false };
    private readonly Border surface = new();
    private readonly CaptionsPanel captions;
    private RewritePanel? rewrite;
    private InlineEditorJob? job;
    private readonly TextBlock heading = Ui.Text("Captions", "BodyStrongTextBlockStyle");
    private readonly TextBlock context = Ui.Text("");
    private readonly Button rewriteTab;
    private readonly Button voiceTab;
    private readonly Button captionsTab;
    private readonly Button pictureTab;
    private PicturePanel? picture;
    /// <summary>Picture's Compare in the header, while the panel is too short to pin its own (looks spec §3.1, §3.8).</summary>
    private readonly Border titleAccessory = new() { VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
    private readonly DirectorPanel director = new();
    internal event EventHandler? SourcePlaybackRequested;
    internal static void RequestSourcePlayback(EditorViewModel editor)
    {
        if (hosts.TryGetValue(editor, out var host)) host.SourcePlaybackRequested?.Invoke(host, EventArgs.Empty);
    }
    internal Control FocusTarget => job?.FocusTarget ?? (ReferenceEquals(surface.Child, director) ? director.FocusTarget : null)
        ?? (picture is not null && ReferenceEquals(surface.Child, picture) ? picture.FocusTarget : null) ?? captions.FocusTarget;
    /// <summary>The Picture tab's panel, made on first use; the page gives it the preview's stills.</summary>
    internal PicturePanel Picture => picture ??= NewPicture();
    private PicturePanel NewPicture()
    {
        var panel = new PicturePanel(captions.Editor);
        // In a short column the Look row and Compare scroll with the body, so the header carries the look and Compare (mockup frame 5).
        titleAccessory.Child = panel.TitleCompare;
        panel.TitleChanged += (_, _) => RefreshHeader();
        return panel;
    }
    /// <summary>The Picture tab is the column's surface.</summary>
    internal bool ShowsPicture => picture is not null && ReferenceEquals(surface.Child, picture);
    internal RightColumn(CaptionsPanel captions)
    {
        this.captions = captions;
        hosts.Remove(captions.Editor); hosts.Add(captions.Editor, this);
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        var header = new Grid { Padding = new(16, 4, 8, 4), ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.Children.Add(heading); Grid.SetColumn(context, 1); header.Children.Add(context);
        Grid.SetColumn(titleAccessory, 2); header.Children.Add(titleAccessory);
        context.TextTrimming = TextTrimming.CharacterEllipsis; context.TextWrapping = TextWrapping.NoWrap; context.FontSize = 12;
        var tabs = Ui.Stack(4); tabs.Orientation = Orientation.Horizontal;
        captionsTab = Ui.Button("Captions", ShowCaptions);
        Compact(captionsTab, "Captions", "\uE8A1"); tabs.Children.Add(captionsTab);
        rewriteTab = Ui.Button("Rewrite", () => { if (rewrite is not null && CloseJob()) ShowDirector(); });
        voiceTab = Ui.Button("Voice", ShowVoice);
        Compact(rewriteTab, "Rewrite", "\uE70F"); Compact(voiceTab, "Voice", "\uE720");
        // Picture (looks spec §3.7), the fourth tab: the clip's looks, Amount and Fine-tune, shown only for a source with a picture.
        pictureTab = Ui.Button("Picture", () => ShowPicture());
        Compact(pictureTab, "Picture", "\uE790");
        tabs.Children.Add(rewriteTab); tabs.Children.Add(voiceTab); tabs.Children.Add(pictureTab); Grid.SetColumn(tabs, 3); header.Children.Add(tabs);
        Children.Add(header);
        surface.Child = captions;
        Grid.SetRow(surface, 1); Grid.SetRow(fade, 1);
        Children.Add(surface);
        surface.SizeChanged += (_, _) => { if (ReferenceEquals(surface.Child, captions)) captions.ConstrainHeight(surface.ActualHeight); };
        Children.Add(fade);
        Loaded += (_, _) =>
        {
            captions.Editor.Changed -= EditorChanged; captions.Editor.Changed += EditorChanged;
            App.Services.SettingsChanged -= EditorChanged; App.Services.SettingsChanged += EditorChanged;
            RefreshHeader();
        };
        Unloaded += (_, _) =>
        {
            captions.Editor.Changed -= EditorChanged; App.Services.SettingsChanged -= EditorChanged;
            job?.RequestClose();
        };
        ActualThemeChanged += (_, _) => UpdateFade();
        UpdateFade();
    }
    private static void Compact(Button button, string label, string glyph)
    {
        button.Content = new FontIcon { Glyph = glyph, FontSize = 12 };
        button.Width = 32; button.Height = 32; button.Padding = new(0);
        ToolTipService.SetToolTip(button, label);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(button, "Panel." + label);
    }
    internal void ShowRewrite(RewritePanel panel)
    {
        if (!CloseJob()) { panel.CloseForHost(); return; }
        rewrite = panel;
        ShowDirector();
    }
    /// <summary>Brings the open Rewrite's own panel forward so it can ask its question (another Rewrite asked for over its paid
    /// takes). A job open in its place closes first when it may; one that stays keeps the column, and the Rewrite and its takes are
    /// never closed for it (unlike <see cref="ShowRewrite"/>, whose refused panel is a new one). False when it can't come forward.</summary>
    internal bool RevealRewrite(RewritePanel panel)
    {
        if (!ReferenceEquals(rewrite, panel) || !CloseJob()) return false;
        ShowDirector();
        return true;
    }
    /// <summary>The label of the job that holds the column ("Export", "Find clips"), which the user finishes or closes to see Rewrite
    /// again; null when none is open.</summary>
    internal string? HeldJobLabel => job?.JobLabel;
    internal void CloseRewrite()
    {
        rewrite = null;
        director.Show(null);
        if (job is null) { surface.Child = captions; heading.Text = "Captions"; }
        RefreshHeader();
    }
    private void ShowDirector()
    {
        director.Show(rewrite); surface.Child = director; heading.Text = "Rewrite"; RefreshHeader();
    }
    private bool CloseJob() => job is null || job.RequestClose();
    private void ShowCaptions()
    {
        if (!CloseJob()) return;
        surface.Child = captions; heading.Text = "Captions"; RefreshHeader();
    }
    private void ShowVoice()
    {
        if ((!App.Services.VoiceLabEnabled && !captions.Editor.IsStoryClip) || !CloseJob()) return;
        director.Show(new DirectorVoiceSteps(captions.Editor)); surface.Child = director; heading.Text = "Voice"; RefreshHeader();
    }
    /// <summary>Shows the Picture tab (its tab button, the palette's "Open Picture", Make it's "All looks in Picture ›"); false when the
    /// source has no picture or the job open in the column stays.</summary>
    internal bool ShowPicture()
    {
        if (!captions.Editor.Picture.IsAvailable || !CloseJob()) return false;
        surface.Child = Picture; heading.Text = "Picture"; RefreshHeader();
        return true;
    }
    private void EditorChanged(object? sender, EventArgs args)
    {
        if (ShowsPicture && !captions.Editor.Picture.IsAvailable) ShowCaptions();
        if (heading.Text == "Voice")
        {
            if (!App.Services.VoiceLabEnabled && !captions.Editor.IsStoryClip) ShowCaptions();
            else if (director.Content is DirectorVoiceSteps voice && voice.ShowsStory != captions.Editor.IsStoryClip) ShowVoice();
        }
        RefreshHeader();
    }
    private void RefreshHeader()
    {
        rewriteTab.IsEnabled = rewrite?.IsSessionOpen == true;
        voiceTab.Visibility = App.Services.VoiceLabEnabled || captions.Editor.IsStoryClip ? Visibility.Visible : Visibility.Collapsed;
        pictureTab.Visibility = captions.Editor.Picture.IsAvailable ? Visibility.Visible : Visibility.Collapsed;
        // "Clip 2 · Warm Print, edited · 70%" while Picture's header scrolls with its body.
        var look = ShowsPicture ? picture!.TitleLook : null;
        titleAccessory.Visibility = look is null ? Visibility.Collapsed : Visibility.Visible;
        context.Text = captions.Editor.Project.Edits.ActiveClipId is { } id
            ? "Clip " + captions.Editor.Clips.FirstOrDefault(clip => clip.Id == id)?.Number + (look is null ? "" : " · " + look) : "Full Take";
    }
    internal static bool TryShow(EditorViewModel editor, InlineEditorJob next)
    {
        if (!hosts.TryGetValue(editor, out var host) || !host.CloseJob()) return false;
        host.job = next;
        next.Dismissed += host.JobDismissed;
        host.surface.Child = next; host.heading.Text = next.JobLabel;
        return true;
    }
    private void JobDismissed(object? sender, EventArgs args)
    {
        if (sender is not InlineEditorJob previous) return;
        previous.Dismissed -= JobDismissed;
        if (!ReferenceEquals(job, previous)) return;
        captionsTab.Focus(FocusState.Programmatic);
        job = null; surface.Child = captions; heading.Text = "Captions"; RefreshHeader();
        captions.FocusTarget.Focus(FocusState.Programmatic);
    }
    private void UpdateFade()
    {
        var color = ((SolidColorBrush)Ui.ThemeBrush(this, "VcBgSurfaceBrush")).Color;
        var clear = color; clear.A = 0;
        fade.Background = new LinearGradientBrush { StartPoint = new(0, 0), EndPoint = new(0, 1), GradientStops = { new() { Color = clear, Offset = 0 }, new() { Color = color, Offset = 1 } } };
    }
}
