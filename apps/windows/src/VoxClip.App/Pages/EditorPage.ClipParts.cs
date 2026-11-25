using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
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
