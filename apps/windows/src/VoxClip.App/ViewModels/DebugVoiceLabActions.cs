#if DEBUG
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record DebugVoiceLabAction(string Id, string Label, VoiceLabEditCommand Command, bool Selected = false);

internal sealed class DebugVoiceLabActions(Project snapshot, IReadOnlyList<DebugVoiceLabAction> actions)
{
    internal IReadOnlyList<DebugVoiceLabAction> Actions => actions;
    internal bool Apply(EditorViewModel editor, DebugVoiceLabAction action, bool enabled) => enabled && actions.Contains(action) && editor.ApplyVoiceLab(action.Command, snapshot);
    internal static DebugVoiceLabActions For(EditorViewModel editor, bool enabled)
    {
        var snapshot = editor.Project;
        if (!enabled || editor.IsReadOnly || editor.IsLeaving || editor.Busy || !editor.HasSelection) return new(snapshot, []);
        // A selected word meets the range on the source sample grid, as the Core validates it (voice-lab §10.1).
        var rate = (double)(snapshot.Media.Source.Audio?.SampleRate ?? 48_000);
        var segment = snapshot.VoiceLab.Segments.FirstOrDefault(segment => editor.Words
            .Skip(editor.SelectionStart).Take(editor.SelectionEnd - editor.SelectionStart + 1)
            .Any(word => segment.Replace.Covers(word.Start, word.End, rate)));
        if (segment is null) return new(snapshot, []);
        var actions = new List<DebugVoiceLabAction>
        {
            new(segment.Enabled ? "VoiceLab.Off" : "VoiceLab.On", segment.Enabled ? "Turn off" : "Turn on",
                new VoiceLabEditCommand.SetEnabled(segment.Id, !segment.Enabled)),
            new("VoiceLab.Delete", "Delete AI passage", new VoiceLabEditCommand.Delete(segment.Id))
        };
        for (var index = 0; index < segment.Candidates.Count; index++)
            if (segment.Candidates[index].Rejected is null)
                actions.Add(new($"VoiceLab.Candidate.{index + 1}", $"Choose take {index + 1}",
                    new VoiceLabEditCommand.ChooseCandidate(segment.Id, index), index == segment.SelectedCandidateIndex));
        return new(snapshot, actions);
    }
}
#endif
