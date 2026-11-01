using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

public enum ShellJob { Rewrite, Hook, FindClips, Export }
public sealed record ShellJobRequest(ShellJob Job, Project Snapshot, string? ClipId, IReadOnlyList<string> WordIds, string Instruction);
public sealed record ShellJobBindings(Func<ShellJobRequest, bool> Available, Func<ShellJobRequest, Task> OpenAsync, Func<string?>? Status = null);
