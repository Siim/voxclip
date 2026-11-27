using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    private bool auditioningRecording;

    internal void PlayRecordingVersion(string id, ViewModels.RecordingVersion version) => _ = RunAsync(async () =>
    {
        if (!ShellEditable || ViewModel.ClipParts.FirstOrDefault(part => part.Id == id) is not { } part ||
            ViewModel.RecordingVersionPreview(id, version) is not { } candidate || EditingEngine.FromProject(candidate) is not { } state) return;
        await playback.EndCorrectionAsync(ViewModel);
        var original = ViewModel.Project;
        var snapshot = await SnapshotAsync(lifetime.Token, state, candidate);
        await previewChanges.WaitAsync(lifetime.Token);
        try
        {
            await SourceTransportAsync(async token =>
            {
                if (preview is null || !ReferenceEquals(original, ViewModel.Project)) return;
                var seams = new TimelinePieces(snapshot.Timeline).Pieces.Select((piece, index) => (piece, index)).ToArray();
                var pieces = new TimelinePieces(snapshot.Timeline);
                var boundaries = seams.Where(entry => pieces.IsPartSeam(entry.index)).Select(entry => entry.piece.Edited.Start)
                    .Prepend(0).Append(snapshot.Timeline.Duration).ToArray();
                var index = part.Number - 1;
                if (index + 1 >= boundaries.Length) return;
                var start = index == 0 ? 0 : Math.Max(boundaries[index - 1], boundaries[index] - 1);
                auditioningRecording = true;
                await preview.UpdateSnapshotAsync(snapshot, token);
                presenter?.Attach(snapshot);
                await preview.SeekAsync(start, true, token);
                previewStop = (Math.Min(snapshot.Timeline.Duration, boundaries[index + 1] + 1), true);
                await preview.PlayAsync(token);
            });
        }
        finally { previewChanges.Release(); }
    }, "Preview");

    private async Task StopRecordingAuditionAsync()
    {
        if (!auditioningRecording) return;
        auditioningRecording = false;
        await SourceTransportAsync(token => preview?.PauseAsync(token) ?? Task.CompletedTask);
        await UpdatePreviewAsync();
    }

    internal void PlayStoryPart(string id) => _ = RunAsync(async () =>
    {
        if (!ShellEditable || !ViewModel.IsStoryClip || !ViewModel.SelectPart(id) || ViewModel.SelectedPart is not { } part) return;
        Transcript.RevealWord(part.First);
        await playback.EndCorrectionAsync(ViewModel);
        await SourceTransportAsync(async token =>
        {
            if (preview is null || ViewModel.SelectedPart?.Id != id) return;
            var snapshot = await SnapshotAsync(token);
            var pieces = new TimelinePieces(snapshot.Timeline).Pieces.Where(piece => piece.Source.Start < part.End && piece.Source.End > part.Start).ToArray();
            if (pieces.Length == 0) return;
            await preview.SeekAsync(pieces[0].Edited.Start, true, token);
            previewStop = (pieces[^1].Edited.End, true);
            await preview.PlayAsync(token);
        });
    }, "Preview");

    private void RememberStoryEnd(RenderTimeline timeline)
    {
        previewStoryEnd = !ViewModel.IsStoryClip ? null : new TimelinePieces(timeline).Pieces.LastOrDefault().Source.End;
    }
}
