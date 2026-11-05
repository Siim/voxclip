using System.Text.Json;
using Microsoft.UI.Xaml;
using VoxClip.App.Controls;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Services.Settings;

namespace VoxClip.App;

/// <summary>The clip style card above the clip list and the status bar's "Style: …" item that reopens it (design §6.6).</summary>
public sealed partial class MainWindow
{
    private ClipStyleCatalog? clipStyles;
    private IReadOnlyList<CaptionStyle> clipStyleLibrary = [];
    private ClipStyleCardPanel? clipStyleCard;
    private ClaudeModeCard? claudeModeCard;
    private RewriteToneCatalog? rewriteTones;

    private bool LoadClipStyles()
    {
        if (clipStyles is not null) return true;
        if (App.Services.SharedRoot is not { } root) return false;
        try { clipStyles = ClipStyleCatalog.Load(root); clipStyleLibrary = CaptionStyleLibrary.Load(root).Styles; rewriteTones = RewriteToneCatalog.Load(root); }
        catch (Exception) { clipStyles = null; return false; }
        return true;
    }

    /// <summary>Settings' default clip style (clipStyle.default), if the user ever chose one.</summary>
    private static ClipStyle? SavedClipStyle()
    {
        if (!App.Services.Settings.Values.TryGetValue("clipStyle.default", out var value) || value.ValueKind != JsonValueKind.Object) return null;
        try
        {
            var style = new ClipStyle(value.GetProperty("preset").GetString()!, value.GetProperty("captions").GetString()!, value.GetProperty("music").GetString()!,
                value.GetProperty("maxLengthSec").GetInt32(), value.GetProperty("shapes").EnumerateArray().Select(shape => shape.GetString()!).ToArray(),
                value.GetProperty("rewording").GetString()!, new Dictionary<string, ClipCaptionPick>());
            style.Validate();
            return style;
        }
        catch (Exception) { return null; }
    }

    /// <summary>Called with every shell update: shows or folds the card and the status item. Each clip's caption pick applies
    /// where it renders (ClipCaptionStyles), never by rewriting the project's style.</summary>
    private void RefreshClipStyle()
    {
        var model = !ShowingHome ? editor?.ViewModel : null;
        if (model is null || !LoadClipStyles())
        {
            ClipStyleHost.Visibility = Visibility.Collapsed; ClipStyleStatus.Visibility = Visibility.Collapsed; ClaudeModeHost.Visibility = Visibility.Collapsed;
            return;
        }
        RefreshClaudeModeCard(model);
        // Claude mode's item ("✦ Claude does it all · top 3 · ≤$2", or "Choose how clips are made") takes the style item's place.
        var status = model.ClaudeModeStatus ?? ClipStyleCard.StatusText(model.Project, clipStyles!);
        ClipStyleStatus.Content = status;
        ClipStyleStatus.IsEnabled = !model.IsReadOnly;
        ClipStyleStatus.Visibility = status is null ? Visibility.Collapsed : Visibility.Visible;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(ClipStyleStatus, status is null ? "Clip style" : "Clip style, " + status.Replace(" · ", ", ").Replace("≤", "up to "));
        if (!model.ShowsClipStyleCard || !Nav.IsPaneOpen) { ClipStyleHost.Visibility = Visibility.Collapsed; return; }
        if (clipStyleCard is null)
        {
            clipStyleCard = new ClipStyleCardPanel();
            clipStyleCard.Chosen += ClipStyleChosen;
            clipStyleCard.ModeChosen += mode => _ = ClaudeModeChangedAsync(model => model.ChooseClipsModeAsync(mode));
            clipStyleCard.CountChosen += count => _ = ClaudeModeChangedAsync(model => model.SetClaudeClipCountAsync(count));
            clipStyleCard.CapChosen += cap => _ = ClaudeModeChangedAsync(model => model.SetClaudeSpendCapAsync(cap));
            ClipStyleHost.Content = clipStyleCard;
        }
        clipStyleCard.Show(ClipStyleCard.Showing(model.Project, clipStyles!, SavedClipStyle()), clipStyles!, clipStyleLibrary, SavedClipStyle(),
            App.Services.Settings.GetClipsAutopilot(), rewriteTones is null ? null : rewriteTones.Tones.Concat(SavedRewriteTones()).ToArray());
        ClipStyleHost.Visibility = Visibility.Visible;
    }

    private async void ClipStyleChosen(ClipStyle style, bool collapse)
    {
        if (editor?.ViewModel is not { } model) return;
        model.ChooseClipStyle(style, clipStyleLibrary.Select(caption => caption.Id).ToHashSet(StringComparer.Ordinal), collapse);
        // Settings keeps the style without its picks (settings schema clipStyle.default).
        var saved = style.SettingsDefault;
        var buffer = new System.Buffers.ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("preset", saved.Preset); writer.WriteString("captions", saved.Captions); writer.WriteString("music", saved.Music);
            writer.WriteNumber("maxLengthSec", saved.MaxLengthSec);
            writer.WriteStartArray("shapes"); foreach (var shape in saved.Shapes) writer.WriteStringValue(shape); writer.WriteEndArray();
            writer.WriteString("rewording", saved.Rewording);
            writer.WriteEndObject();
        }
        using var value = JsonDocument.Parse(buffer.WrittenMemory);
        try { await App.Services.SetAsync("clipStyle.default", value.RootElement.Clone()); } catch (Exception) { }
        RefreshClipStyle();
    }

    /// <summary>Claude mode's card above the clip style card: A, the blocked card, C or D.</summary>
    private void RefreshClaudeModeCard(VoxClip.App.ViewModels.EditorViewModel model)
    {
        if (!ClaudeModeCard.Shows(model) || !Nav.IsPaneOpen) { ClaudeModeHost.Visibility = Visibility.Collapsed; return; }
        claudeModeCard ??= new ClaudeModeCard();
        if (!ReferenceEquals(ClaudeModeHost.Content, claudeModeCard)) ClaudeModeHost.Content = claudeModeCard;
        claudeModeCard.Show(model);
        ClaudeModeHost.Visibility = Visibility.Visible;
    }

    private async Task ClaudeModeChangedAsync(Func<VoxClip.App.ViewModels.EditorViewModel, Task> change)
    {
        if (editor?.ViewModel is not { } model) return;
        try { await change(model); }
        catch (Exception exception) { ShowError(exception, "Settings"); }
        UpdateShell();
    }

    /// <summary>The creator's saved tones (Settings rewrite.myTones).</summary>
    internal static IReadOnlyList<RewriteTone> SavedRewriteTones() =>
        MyRewriteTones.Decode(App.Services.Settings.Values.TryGetValue(RewriteToneCatalog.SettingsKey, out var saved) ? saved : null);

    private void ReopenClipStyleCard()
    {
        if (editor?.ViewModel is not { IsReadOnly: false } model) return;
        if (!Nav.IsPaneOpen) Nav.IsPaneOpen = true;
        model.ClipStyleReopened = true;
        RefreshClipStyle();
    }
}
