using System.Text.Json;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;

namespace VoxClip.App.ViewModels;

internal sealed record HarnessReviewDetails(string ClipTitle, string Reason, IReadOnlyList<string> Changes, string? MusicPrompt,
    string? MusicEstimate, string? Blocked);

internal sealed record HarnessMusicAction(string ClipId, string SourceKey, string Prompt, ClipPlanMusicShape? TimelineShape = null);

public sealed partial class EditorViewModel
{
    internal HarnessProposal? ReadHarnessProposal(string projectPath) => HarnessInbox.Read(projectPath);

    internal string? HarnessKeepBlocked => IsReadOnly || state is null
        ? "Open a writable project with its source video to keep this timeline."
        : IsLeaving || Busy || undoGroup is { OwnsEdits: true } || Music.Phase is MusicPanelPhase.Searching or MusicPanelPhase.Using
            ? "Finish the current action before keeping this timeline." : null;

    internal HarnessReviewDetails DescribeHarnessProposal(HarnessProposal proposal, string? sharedRoot, int index = 0)
    {
        var timeline = proposal.TimelineAt(index);
        var intent = proposal.Timelines[index];
        var clipId = proposal.ClipIdAt(index);
        var clipTitle = intent.Target.New?.Title ?? project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId)?.Title ?? "Clip";
        var changes = new List<string>();
        var recordingKey = proposal.Timelines[index].RecordingKey;
        if (recordingKey is not null && project.Media.AdditionalSources?.FirstOrDefault(source => source.ContentKey == recordingKey) is { } recording)
            changes.Add($"Add recording {Core.Domain.Editing.ProjectClock.Label(recording)} with local transcription");
        if (intent.Parts is { } parts) changes.Add("Parts: " + string.Join(" → ", parts.Select(part => $"{part.StartWord}–{part.EndWord}")));
        if (timeline.TryGetProperty("title", out var title)) changes.Add($"Title: {title.GetString()}");
        if (timeline.TryGetProperty("captionStyle", out var caption)) changes.Add($"Captions: {caption.GetString()}");
        if (intent.Music?.TrackId is { } trackId)
        {
            changes.Add($"Reuse music: {project.Music.FirstOrDefault(item => item.Id == trackId)?.Title ?? trackId}");
        }
        if (timeline.TryGetProperty("cuts", out var cuts))
            changes.AddRange(cuts.EnumerateArray().Select(change => DescribeCut(change)));
        if (timeline.TryGetProperty("effects", out var effects))
            changes.AddRange(effects.EnumerateArray().Select(effect => $"{EffectLabel(effect)}: {effect.GetProperty("reason").GetString()}"));
        if (timeline.TryGetProperty("edits", out var edits))
            changes.Add(edits.GetArrayLength() == 1 ? "1 timeline edit" : $"{edits.GetArrayLength()} timeline edits");
        var prompt = intent.Music?.Brief;
        string? estimate = null;
        string? blocked = null;
        if (sharedRoot is null) blocked = "VoxClip can't read its timeline resources.";
        else
        {
            try
            {
                var transcript = recordingKey is null ? null : HarnessRecording.CachedTranscript(recordingKey, App.Services.Data.Cache);
                var review = proposal.Review(project, sharedRoot, index, transcript, preview: true);
                estimate = proposal.EstimatedMusicPrice(review.Project, sharedRoot, index);
                foreach (var operation in review.Operations.Where(operation =>
                    operation.Decision is not (ClipAutopilotDecision.Clip or ClipAutopilotDecision.Title or ClipAutopilotDecision.Cut or
                        ClipAutopilotDecision.Music or ClipAutopilotDecision.Zoom or ClipAutopilotDecision.Overlay) &&
                    (operation.Decision != ClipAutopilotDecision.Captions || intent.CaptionStyle is null ||
                        intent.Font is not null || intent.WordsPerCaption is not null || intent.TextCase is not null)))
                    changes.Add(string.IsNullOrEmpty(operation.Reason) ? $"{operation.Decision}" : $"{operation.Decision}: {operation.Reason}");
            }
            catch (HarnessException exception) { blocked = exception.Message; }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or VoxClipException)
            { blocked = "VoxClip can't validate this timeline. Your project is unchanged."; }
        }
        return new(clipTitle, timeline.GetProperty("reason").GetString()!, changes, prompt, estimate, blocked);
    }

    internal HarnessMusicAction? KeepHarnessProposal(HarnessProposal proposal, string projectPath, string sharedRoot)
        => KeepHarnessProposal(proposal, projectPath, sharedRoot, out _);

    internal HarnessMusicAction? KeepHarnessProposal(HarnessProposal proposal, string projectPath, string sharedRoot,
        out IReadOnlyList<ClipAutopilotAction.Asset> assets)
        => KeepHarnessTimeline(proposal, projectPath, sharedRoot, 0, out assets, out _);

    internal HarnessMusicAction? KeepHarnessTimeline(HarnessProposal proposal, string projectPath, string sharedRoot, int index,
        out IReadOnlyList<ClipAutopilotAction.Asset> assets, out IReadOnlyList<ClipAutopilotOperation> rewrites, Transcript? recordingTranscript = null)
    {
        if (HarnessKeepBlocked is { } blocked) throw new HarnessException(blocked);
        var (next, _, pending) = proposal.Review(project, sharedRoot, index, recordingTranscript);
        HarnessInbox.Resolve(proposal, proposal.Remaining(index, next), projectPath);
        if (!ReferenceEquals(next, project)) ReplaceProject(next, "Keep timeline proposal");
        assets = pending.Select(operation => operation.Action).OfType<ClipAutopilotAction.Asset>().ToArray();
        rewrites = pending.Where(operation => operation.Action is ClipAutopilotAction.Rewrite).ToArray();
        return pending.Select(operation => operation.Action).OfType<ClipAutopilotAction.Music>().FirstOrDefault() is { } music
            ? new(music.Cue.ClipId, next.Media.Source.ContentKey, music.Cue.Picked.Prompt, music.Cue.Picked.TimelineShape) : null;
    }

    internal async Task<Transcript?> PrepareHarnessRecordingAsync(HarnessProposal proposal, string projectPath, int index, CancellationToken ct)
    {
        if (proposal.Timelines[index].RecordingKey is not { } key) return null;
        var snapshot = project;
        var source = HarnessRecording.Source(key, snapshot);
        if (HarnessRecording.CachedTranscript(key, App.Services.Data.Cache) is { } cached) return cached;
        var engine = snapshot.Transcript!.Engine;
        if (engine.ModelId is null) throw HarnessRecording.Refusal(source);
        var path = await App.Services.Projects.ResolveMediaAsync(source, projectPath, ct) ?? throw HarnessRecording.Refusal(source);
        if (await App.Services.Projects.ComputeContentKeyAsync(path, null, ct) != key) throw HarnessRecording.Refusal(source);
        var media = await App.Services.Probe.ProbeAsync(path, ct);
        var audio = await App.Services.Cache.ExtractAudioAsync(App.Services.Audio, media, key, null, ct);
        LanguageChoice language = snapshot.Transcript.Language is { } code ? new LanguageChoice.Forced(code) : new LanguageChoice.Auto();
        var plan = new TranscriptionPlan(TranscriptEngine.Whispercpp, engine.ModelId, language, new());
        var transcript = await App.Services.Transcription.TranscribeAsync(new(plan, audio.Audio, key), audio.Envelope, null, ct);
        ct.ThrowIfCancellationRequested();
        if (!ReferenceEquals(project, snapshot)) throw new HarnessException("The project changed. Ask for a new timeline proposal.");
        HarnessRecording.CacheTranscript(key, App.Services.Data.Cache, transcript);
        return transcript;
    }

    internal async Task<bool> ApplyHarnessAssetAsync(ClipAutopilotAction.Asset asset, Project snapshot, decimal? price, CancellationToken ct)
    {
        bool Current() => !ct.IsCancellationRequested && ReferenceEquals(snapshot, project) && HarnessKeepBlocked is null;
        if (!Current() || AskClaudeServices?.Assets is not { } service) return false;
        var effect = await service.CollectAsync(asset, snapshot.Id, quoted => quoted == price && Current(), ct);
        return effect is { } value && Current() && ReplaceProject(ClipEffects.Adding([value], project), "Place timeline asset");
    }

    internal void DismissHarnessProposal(HarnessProposal proposal, string projectPath, int index = 0)
    {
        if (IsLeaving) throw new HarnessException("The pending timeline changed. Review it again.");
        HarnessInbox.Resolve(proposal, proposal.Discarding(index), projectPath);
    }

    private string DescribeCut(JsonElement change)
    {
        var start = change.GetProperty("startWord").GetDouble();
        var end = change.GetProperty("endWord").GetDouble();
        var label = $"Cut words {start}–{end}";
        if (start <= end && end < Words.Count)
        {
            var words = Words.Skip((int)start).Take((int)(end - start + 1)).Where(word => word.Kind == WordKind.Word).Take(13).ToArray();
            if (words.Length > 0) label = $"Cut “{string.Join(" ", words.Take(12).Select(DisplayText))}{(words.Length > 12 ? "…" : "")}”";
        }
        return $"{label}: {change.GetProperty("reason").GetString()}";
    }

    private static string EffectLabel(JsonElement effect)
    {
        var label = effect.GetProperty("kind").GetString() switch
        {
            "zoom" => "Zoom", "punchIn" => "Punch in", "motionTitle" => "Animated title",
            "lowerThird" => "Lower third", "emojiPop" => "Emoji pop", "soundEffect" => "Sound effect",
            "illustration" => "Illustration", "colourLook" => "Colour look", "speedForPart" => "Speed change",
            "bRoll" => "B-roll", "screenshot" => "Screenshot", "videoStack" => "Video stack", _ => "Motion template"
        };
        if (effect.TryGetProperty("template", out var template))
        {
            label = template.GetProperty("name").GetString() switch
            {
                "titleCard" => "Title card", "kineticCaption" => "Kinetic caption", "logoSting" => "Logo sting", _ => "Counter"
            };
            if (template.TryGetProperty("text", out var text)) return $"{label} “{text.GetString()}”";
            return $"{label} {template.GetProperty("from")} to {template.GetProperty("to")}";
        }
        return effect.TryGetProperty("text", out var value) ? $"{label} “{value.GetString()}”" : label;
    }
}
