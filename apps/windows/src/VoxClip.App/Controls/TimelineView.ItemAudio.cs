using System.Security.Cryptography;
using System.Text;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Controls;

public sealed partial class TimelineView
{
    private Project? audioProject;
    private CancellationTokenSource? itemWaveformRequest;
    private Dictionary<string, string> soundFiles = new(StringComparer.Ordinal);
    private string? musicFile;
    private readonly Dictionary<string, TimelineWaveform?> itemWaveforms = new(StringComparer.OrdinalIgnoreCase);

    private void RefreshItemAudio()
    {
        if (model is null || model.IsReadOnly || !IsLoaded || ReferenceEquals(audioProject, model.Project)) return;
        audioProject = model.Project;
        if (itemLayout?.Items.Any(TimelineItemEditing.Audio) != true) { ResetItemAudio(); return; }
        var services = App.Services;
        var root = services.Data.Root;
        var shared = services.SharedRoot;
        var clipId = model.Project.Edits.ActiveClipId;
        soundFiles = shared is not null && ClipEffectsRenderInput.Resolve(model.Project, clipId, root, shared) is { } input
            ? new(input.SoundPaths, StringComparer.Ordinal) : new(StringComparer.Ordinal);
        musicFile = MusicRenderInput.Resolve(model.Project, clipId, root)?.AssetPath;
        var files = soundFiles.Values.Append(musicFile).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        foreach (var obsolete in itemWaveforms.Keys.Except(files, StringComparer.OrdinalIgnoreCase).ToArray()) itemWaveforms.Remove(obsolete);
        itemWaveformRequest?.Cancel();
        var missing = files.Where(file => !itemWaveforms.ContainsKey(file)).ToArray();
        if (missing.Length == 0) return;
        var request = itemWaveformRequest = new();
        _ = LoadItemWaveformsAsync(missing, request);
    }

    private async Task LoadItemWaveformsAsync(string[] files, CancellationTokenSource request)
    {
        var token = request.Token;
        try
        {
            foreach (var file in files)
            {
                token.ThrowIfCancellationRequested();
                var waveform = await Task.Run(async () =>
                {
                    try
                    {
                        var info = new FileInfo(file);
                        if (!info.Exists || info.LinkTarget is not null) return null;
                        var identity = $"timeline-asset:{file}:{info.Length}:{info.LastWriteTimeUtc.Ticks}";
                        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity))).ToLowerInvariant();
                        var media = await App.Services.Probe.ProbeAsync(file, token).ConfigureAwait(false);
                        var audio = await App.Services.Waveform.GetEnvelopeAsync(media, key, token).ConfigureAwait(false);
                        return audio is null ? null : TimelineWaveform.Create(audio.Rms, audio.FrameSeconds, token);
                    }
                    catch (Exception exception) when (!token.IsCancellationRequested && exception is not OutOfMemoryException) { return null; }
                }, token);
                if (token.IsCancellationRequested || !ReferenceEquals(itemWaveformRequest, request)) return;
                itemWaveforms[file] = waveform;
                if (waveform is not null) RedrawItems();
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        finally
        {
            if (ReferenceEquals(itemWaveformRequest, request)) itemWaveformRequest = null;
            request.Dispose();
        }
    }

    private void ResetItemAudio()
    {
        audioProject = null; itemWaveformRequest?.Cancel(); itemWaveformRequest = null;
        itemWaveforms.Clear(); soundFiles.Clear(); musicFile = null;
    }

    private void DrawItemWaveform(ItemHit hit, Brush brush)
    {
        var file = hit.Item.Id.Type == TimelineItemType.Music ? musicFile : soundFiles.GetValueOrDefault(hit.Item.Id.Value);
        if (file is null || itemWaveforms.GetValueOrDefault(file) is not { } waveform) return;
        var geometry = new PathGeometry();
        var box = hit.Rect;
        var middle = box.Top + box.Height * .6;
        var columns = Math.Clamp((int)(box.Width / 3), 1, 250);
        for (var column = 0; column < columns; column++)
        {
            var x = box.Left + column * box.Width / columns;
            var from = hit.Details.Offset + Math.Max(0, LocalTime(hit, x));
            var to = hit.Details.Offset + Math.Max(0, LocalTime(hit, x + box.Width / columns));
            if (hit.Details.Loop && hit.Details.Available > 0) { var wrap = Math.Floor(from / hit.Details.Available) * hit.Details.Available; from -= wrap; to -= wrap; }
            var peak = waveform.Query(from, to).Peak;
            var amount = Math.Clamp(peak * 2.5, 0, 1) * box.Height * .3;
            if (amount < .4) continue;
            var figure = new PathFigure { StartPoint = new(x, middle - amount) };
            figure.Segments.Add(new LineSegment { Point = new(x, middle + amount) });
            geometry.Figures.Add(figure);
        }
        if (geometry.Figures.Count > 0) itemDrawing.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = brush, Opacity = .25 });
    }
}
