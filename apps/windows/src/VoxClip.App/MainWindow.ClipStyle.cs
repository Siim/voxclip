using System.Text.Json;
using Microsoft.UI.Xaml;
using VoxClip.App.Controls;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Services.Settings;

namespace VoxClip.App;

/// <summary>The clip style card above the clip list and the status bar's "Style: …" item that reopens it (design §6.9).</summary>
public sealed partial class MainWindow
{
    private ClipStyleCatalog? clipStyles;
    private IReadOnlyList<CaptionStyle> clipStyleLibrary = [];
    private ClipStyleCardPanel? clipStyleCard;

    private bool LoadClipStyles()
    {
        if (clipStyles is not null) return true;
        if (App.Services.SharedRoot is not { } root) return false;
        try { clipStyles = ClipStyleCatalog.Load(root); clipStyleLibrary = CaptionStyleLibrary.Load(root).Styles; }
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

    /// <summary>Called with every shell update: shows or folds the card, the status item, and applies Claude's pick for
    /// the active clip while the clip style's captions are Auto.</summary>
    private void RefreshClipStyle()
    {
        var model = !ShowingHome ? editor?.ViewModel : null;
        if (model is null || !LoadClipStyles())
        {
            ClipStyleHost.Visibility = Visibility.Collapsed; ClipStyleStatus.Visibility = Visibility.Collapsed;
            return;
        }
        var library = clipStyleLibrary.Select(style => style.Id).ToHashSet(StringComparer.Ordinal);
        model.ApplyCaptionPick(library);
        var status = ClipStyleCard.StatusText(model.Project, clipStyles!);
        ClipStyleStatus.Content = status;
        ClipStyleStatus.IsEnabled = !model.IsReadOnly;
        ClipStyleStatus.Visibility = status is null ? Visibility.Collapsed : Visibility.Visible;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(ClipStyleStatus, status is null ? "Clip style" : "Clip style, " + status.Replace(" · ", ", ").Replace("≤", "up to "));
        if (!model.ShowsClipStyleCard || !Nav.IsPaneOpen) { ClipStyleHost.Visibility = Visibility.Collapsed; return; }
        if (clipStyleCard is null)
        {
            clipStyleCard = new ClipStyleCardPanel();
            clipStyleCard.Chosen += ClipStyleChosen;
            ClipStyleHost.Content = clipStyleCard;
        }
        clipStyleCard.Show(ClipStyleCard.Showing(model.Project, clipStyles!, SavedClipStyle()), clipStyles!, clipStyleLibrary, SavedClipStyle());
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

    private void ReopenClipStyleCard()
    {
        if (editor?.ViewModel is not { IsReadOnly: false } model) return;
        if (!Nav.IsPaneOpen) Nav.IsPaneOpen = true;
        model.ClipStyleReopened = true;
        RefreshClipStyle();
    }
}
