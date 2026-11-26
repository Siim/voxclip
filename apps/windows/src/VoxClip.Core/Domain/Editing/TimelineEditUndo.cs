using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Domain.Editing;

/// <summary>Reverse only the placements changed by an Ask Claude timeline row.</summary>
public sealed class TimelineEditUndo(Project before, Project after)
{
    /// <summary>Restore changed items without overwriting other rows or newer manual changes.</summary>
    public Project Restore(Project project)
    {
        var footage = Restore(before.Media.Footage ?? [], after.Media.Footage ?? [], project.Media.Footage ?? [], value => value.Id);
        var result = project with
        {
            ClipEffects = Restore(before.ClipEffects, after.ClipEffects, project.ClipEffects, value => value.GetProperty("id").GetString()!, JsonElement.DeepEquals),
            Media = project.Media with { Footage = footage.Count == 0 ? null : footage },
            MotionCues = Restore(before.MotionCues, after.MotionCues, project.MotionCues, value => value.Id),
            Music = Restore(before.Music, after.Music, project.Music, value => value.Id),
            Edits = project.Edits with {
                Clips = Restore(before.Edits.Clips, after.Edits.Clips, project.Edits.Clips, value => value.Id),
                ActiveClipId = before.Edits.ActiveClipId != after.Edits.ActiveClipId && project.Edits.ActiveClipId == after.Edits.ActiveClipId
                    ? before.Edits.ActiveClipId : project.Edits.ActiveClipId },
        };
        _ = ProjectSerialization.Serialize(result);
        return result;
    }

    private static IReadOnlyList<T> Restore<T>(IReadOnlyList<T> before, IReadOnlyList<T> after, IReadOnlyList<T> current,
        Func<T, string> id, Func<T, T, bool>? equal = null)
    {
        if (ReferenceEquals(before, after)) return current;
        equal ??= EqualityComparer<T>.Default.Equals;
        static HarnessTimelineEditException Changed() => new("This item has changed since Ask Claude edited it.");
        var originals = before.ToDictionary(id, StringComparer.Ordinal);
        var result = current.ToList();
        foreach (var value in after)
        {
            var found = originals.TryGetValue(id(value), out var original);
            if (found && equal(original!, value)) continue;
            var index = result.FindIndex(item => id(item) == id(value));
            if (index == -1 || !equal(result[index], value)) throw Changed();
            if (found) result[index] = original!;
            else result.RemoveAt(index);
        }
        var keptIds = after.Select(id).ToHashSet(StringComparer.Ordinal);
        for (var index = 0; index < before.Count; index++)
        {
            var value = before[index];
            if (keptIds.Contains(id(value))) continue;
            if (result.Any(item => id(item) == id(value))) throw Changed();
            result.Insert(Math.Min(index, result.Count), value);
        }
        return result;
    }
}
