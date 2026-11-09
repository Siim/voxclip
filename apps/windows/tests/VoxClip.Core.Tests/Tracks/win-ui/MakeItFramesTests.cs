#if WIN_UI_TESTS
using System.Buffers.Binary;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Frames;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>"Claude sees the picture" in Make it postable on Windows (ADR-R48, design.md §6.7.1), twin of the Mac
/// <c>MakeItFramesTests</c>: the four picture rows, the send line and the request's frames, on the passage fixture. The face source, the
/// text lines and the decoder are stubs (no model, no OCR, no FFmpeg); the planner is a stub that asks for each clip's frames as the live
/// one does, and nothing is sent.</summary>
public sealed class MakeItFramesTests : IDisposable
{
    private readonly string root = Directory.CreateTempSubdirectory("voxclip-w6-frames-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(root, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    /// <summary>Words: 0 So · 1 um, · 2 today · (pause) · 3 we · 4 ship · 5 uh · 6 the · 7 clipper. · 8 Thanks. The plan tightens the clip to
    /// "we … clipper." (3…7), whose first word starts at 2.6 s after a pause.</summary>
    internal static ClipAutopilotPlan Plan(bool blur = true, string cover = "C1") => new()
    {
        StartWord = 3, EndWord = 7, Title = "Ship day", Hook = "", PostText = "We ship.", Score = 7, Verdict = ClipAutopilotVerdict.Post,
        CaptionChoice = new("vox-bold", new("Roboto", 900), ClipAutopilotCaptionCase.Upper, 3),
        Frames = new([new("B1", blur, "It shows calendar entries with names")], new(cover, "Eyes open, face centred"))
    };

    /// <summary>The frame's source millisecond, written into its first pixel by <see cref="TimedFrames"/>.</summary>
    internal static double TimeOf(PixelBuffer frame) => BinaryPrimitives.ReadInt32LittleEndian(frame.Pixels.Span) / 1000.0;

    /// <summary>Grey frames at any time asked for, each carrying its time: the analyzer's decode, without a file.</summary>
    internal sealed class TimedFrames : IFrameDecoding
    {
        internal bool Failing { get; init; }
        public IFrameReader Open(string source, int maximumEdge, double tolerance, CancellationToken ct) => new Reader(Failing);

        private sealed class Reader(bool failing) : IFrameReader
        {
            public DecodedFrame Read(double time, CancellationToken ct)
            {
                if (failing) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "stub");
                var pixels = new byte[320 * 180 * 4];
                for (var index = 0; index < pixels.Length; index += 4) (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]) = (128, 128, 128, 255);
                BinaryPrimitives.WriteInt32LittleEndian(pixels, (int)Math.Round(time * 1000));
                return new(new PixelBuffer(pixels, 320, 180, 320 * 4), time);
            }

            public void Dispose() { }
        }
    }

    /// <summary>A face left of centre, eyes shut in the first frame (around 2.6 s) and open elsewhere, or none at all.</summary>
    internal sealed class TimedFaces(bool face = true) : IFrameFaces
    {
        public Task<FrameFaceFindings> FacesAsync(PixelBuffer frame, CancellationToken ct)
        {
            if (!face) return Task.FromResult(new FrameFaceFindings(0, null));
            var time = TimeOf(frame);
            var shut = time > 2.5 && time < 2.75;
            return Task.FromResult(new FrameFaceFindings(1, new FrameFace(new ClipEffectRect(0.3, 0.2, 0.2, 0.36), 0.6, shut ? 0.1 : 0.3, shut ? 0.1 : 0.3, 0, 0)));
        }
    }

    /// <summary>A phone's eight lines of text near the sentence frame (2.95 s): a dense text cluster, taller than wide.</summary>
    internal sealed class PhoneText : IFrameTextLines
    {
        public Task<IReadOnlyList<ClipEffectRect>> LinesAsync(PixelBuffer frame, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<ClipEffectRect>>(Math.Abs(TimeOf(frame) - 2.95) < 0.3
                ? Enumerable.Range(0, 8).Select(line => new ClipEffectRect(0.62, 0.3 + line * 0.05, 0.12, 0.03)).ToArray() : []);
    }

    internal sealed record Fixture(EditorViewModel Editor, MakeItPostableTests.Stub Stub, List<string> Lines);

    /// <summary>The passage project in an editor with Make it postable's stub services and a frame pass on stub faces; without
    /// <paramref name="faces"/> the services have no frame pass, as on a PC without the face models.</summary>
    internal Fixture Make(MakeItFrameAi? ai = null, ClipAutopilotPlan? plan = null, bool faces = true, bool face = true, bool failing = false)
    {
        var shared = SharedResources.ResolveRoot();
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(shared, "fixtures", "voice-lab", "passage-render-v3.voxclip")));
        var editor = new EditorViewModel(project, now: () => new DateTimeOffset(2026, 11, 9, 0, 0, 0, TimeSpan.Zero));
        var chosen = plan ?? Plan();
        var stub = new MakeItPostableTests.Stub { Series = _ => new([chosen], [], []), Ai = ai ?? new("Claude", true, new MakeItFrameBilling.Plan("Claude")) };
        var lines = new List<string>();
        var cache = new FrameAnalysisCache(Path.Combine(root, "cache-" + Guid.NewGuid().ToString("N")));
        var services = stub.Services();
        editor.MakeIt.Services = !faces ? services : services with
        {
            FramePass = shown => shown.Transcript is { } transcript
                ? new VideoFramePass(new FrameAnalyzer(new TimedFaces(face), FrameAnalyzer.ScreensWith(new PhoneText()), new TimedFrames { Failing = failing }, cache),
                    "passage.mp4", shown.Media.Source.ContentKey, transcript.Words, line => { lock (lines) lines.Add(line); })
                : null
        };
        return new(editor, stub, lines);
    }

    internal static async Task<MakeItRun> RunAsync(EditorViewModel editor)
    {
        Assert.True(editor.MakeItPostable("clip-main"));
        var run = editor.MakeIt.Run("clip-main")!;
        await run.Task!;
        return run;
    }

    private static string Saved(Project project) => ProjectSerialization.Serialize(project with { ModifiedAt = DateTimeOffset.UnixEpoch });

    [Fact]
    public async Task TheFourRowsApplyInTheMacsOrderAndTheSendLineSaysWhatWent()
    {
        var (editor, stub, _) = Make();
        var run = await RunAsync(editor);
        Assert.Equal(MakeItPhase.Ready, run.Phase);
        // The request carried the clip's frames: the image, the summary and the candidates.
        var sent = Assert.Single(stub.Sent);
        Assert.NotNull(sent);
        Assert.True(sent.Images.Count >= 1 && sent.Images.Count == sent.Frames.Count);
        Assert.Contains("eyes open", sent.Summary, StringComparison.Ordinal);
        Assert.Equal(["B1"], sent.Blur.Select(candidate => candidate.Id));
        Assert.Equal("C1", sent.Cover[0].Id);
        Assert.Equal([ClipPicture.OpeningRowId, ClipPicture.CropRowId, ClipPicture.BlurRowId("B1"), ClipPicture.CoverRowId], run.Rows.Take(4).Select(row => row.Id));
        var opening = run.Rows[0];
        Assert.Equal("Opens on a clear look at you", opening.Text);
        Assert.Equal("Your eyes were shut on the first frame, so the clip starts in the pause 0.5 s earlier", opening.Detail);
        Assert.True(opening.Undoable && opening.Play is not null);
        var clip = editor.Project.Edits.Clips.Single(item => item.Id == "clip-main");
        Assert.Equal((0.6, "w4"), (clip.LeadInSeconds, clip.StartWordId));
        var controls = ClipControlsProject.Controls("clip-main", editor.Project)!;
        Assert.Equal(new ReframeSettings(ReframeSettings.FaceMode, 1, 0.4, 0.5), controls.Reframe);
        Assert.Equal("9:16 follows your face", run.Rows[1].Text);
        Assert.Equal(sent.Cover[0].Time, controls.CoverSeconds);
        var blur = Assert.Single(editor.Project.ClipEffects, effect => effect.GetProperty("kind").GetString() == "blur");
        Assert.Equal(ClipPicture.BlurEffectId("clip-main", "B1"), blur.GetProperty("id").GetString());
        Assert.Equal(("clip-main", "none"), (blur.GetProperty("clipId").GetString(), blur.GetProperty("tracking").GetString()));
        Assert.Equal((0.62, 0.3, 0.12), (blur.GetProperty("rect").GetProperty("x").GetDouble(), blur.GetProperty("rect").GetProperty("y").GetDouble(), blur.GetProperty("rect").GetProperty("width").GetDouble()));
        Assert.StartsWith("Blurred the phone screen at ", run.Rows[2].Text, StringComparison.Ordinal);
        Assert.Equal(("It shows calendar entries with names", true), (run.Rows[2].Detail, run.Rows[2].Undoable));
        Assert.Equal(("Cover frame chosen", "Eyes open, face centred · saved next to the export as a cover image"), (run.Rows[3].Text, run.Rows[3].Detail));
        var line = editor.MakeItSendLine(run)!.Value;
        Assert.Equal($"Claude read the clip's words and {sent.Frames.Count} small {(sent.Frames.Count == 1 ? "frame" : "frames")} (one per sentence, 320 px) on your Claude plan. Faces were measured on this PC.",
            line.Lead + line.Emphasis + line.Tail);
        Assert.Equal("Make it postable", editor.UndoActionName);
        editor.Undo();
        Assert.False(editor.CanUndo, "the picture rows are in the run's one step");
        Assert.Null(editor.Project.Edits.Clips.Single().LeadInSeconds);
        Assert.Empty(editor.Project.ClipEffects);
    }

    [Theory]
    [InlineData(ClipPicture.OpeningRowId)]
    [InlineData(ClipPicture.CropRowId)]
    [InlineData("frames-blur-B1")]
    [InlineData(ClipPicture.CoverRowId)]
    public async Task EachRowUndoesOnItsOwnAndTheProjectSavesIt(string rowId)
    {
        var (editor, _, _) = Make();
        var run = await RunAsync(editor);
        // Saved and read back, every picture decision is in the project.
        var reloaded = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(editor.Project));
        Assert.Equal(0.6, reloaded.Edits.Clips.Single().LeadInSeconds);
        Assert.NotNull(reloaded.ClipControls.Single().Reframe);
        Assert.NotNull(reloaded.ClipControls.Single().CoverSeconds);
        Assert.Contains(reloaded.ClipEffects, effect => effect.GetProperty("kind").GetString() == "blur");
        var before = editor.Project;
        var controls = before.ClipControls.Single();
        var expected = rowId switch
        {
            ClipPicture.OpeningRowId => before with { Edits = before.Edits with { Clips = [before.Edits.Clips.Single() with { LeadInSeconds = null }] } },
            ClipPicture.CropRowId => before with { ClipControls = [controls with { Reframe = null }] },
            ClipPicture.CoverRowId => before with { ClipControls = [controls with { CoverSeconds = null }] },
            _ => before with { ClipEffects = before.ClipEffects.Where(effect => effect.GetProperty("kind").GetString() != "blur").ToArray() }
        };
        Assert.True(editor.MakeItUndo(rowId, run));
        Assert.Equal(Saved(expected), Saved(editor.Project));
        Assert.True(run.Rows.Single(row => row.Id == rowId).Undone);
        editor.Undo();
        Assert.Equal(Saved(before), Saved(editor.Project));
        Assert.Equal("Make it postable", editor.UndoActionName);
    }

    [Fact]
    public async Task ATextOnlyAiGetsTheSummaryNothingIsBlurredAndTheRowOffersBlur()
    {
        var (editor, stub, _) = Make(new MakeItFrameAi("Ollama", false, new MakeItFrameBilling.Free()));
        var run = await RunAsync(editor);
        var sent = Assert.Single(stub.Sent)!;
        Assert.Empty(sent.Images);
        Assert.Equal(0, sent.EstimatedImageTokens);
        Assert.Contains("dense text with 8 text boxes", sent.Summary, StringComparison.Ordinal);
        Assert.DoesNotContain(editor.Project.ClipEffects, effect => effect.GetProperty("kind").GetString() == "blur");
        var row = run.Rows.Single(item => item.Id == ClipPicture.BlurRowId("B1"));
        Assert.StartsWith("Phone screen at ", row.Text, StringComparison.Ordinal);
        Assert.EndsWith(" left sharp", row.Text, StringComparison.Ordinal);
        Assert.Equal(("Blur", false, "Ollama takes text only, so it couldn't see this screen."), (row.Action, row.Undoable, row.Detail));
        var line = editor.MakeItSendLine(run)!.Value;
        Assert.Equal($"Ollama read the clip's words and a text summary of {sent.Frames.Count} {(sent.Frames.Count == 1 ? "frame" : "frames")}. Faces were measured on this PC.",
            line.Lead + line.Emphasis + line.Tail);
        // The row's Blur is its own step.
        Assert.True(editor.MakeItRowAction(row.Id, run));
        Assert.Contains(editor.Project.ClipEffects, effect => effect.GetProperty("kind").GetString() == "blur");
        Assert.Equal("Blur screen", editor.UndoActionName);
        Assert.StartsWith("Blurred the phone screen", run.Rows.Single(item => item.Id == row.Id).Text, StringComparison.Ordinal);
        editor.Undo();
        Assert.DoesNotContain(editor.Project.ClipEffects, effect => effect.GetProperty("kind").GetString() == "blur");
        Assert.Equal("Make it postable", editor.UndoActionName);
    }

    [Fact]
    public async Task AnApiKeyGetsTheSummaryOnlyBecauseThisPcHasNoImagePrices()
    {
        var (editor, stub, _) = Make(new MakeItFrameAi("Claude", true, new MakeItFrameBilling.Key()));
        var run = await RunAsync(editor);
        var sent = Assert.Single(stub.Sent)!;
        Assert.Empty(sent.Images);
        Assert.NotEmpty(sent.Frames);
        Assert.Equal("a text summary of " + (sent.Frames.Count == 1 ? "1 frame" : $"{sent.Frames.Count} frames"), editor.MakeItSendLine(run)!.Value.Emphasis);
        Assert.Equal(0m, run.Spent);
    }

    [Fact]
    public async Task WithoutFacesNoPassStartsNoRowsAndThePlanGoesAsBefore()
    {
        var (editor, stub, _) = Make(faces: false);
        editor.ClaudeModeFindStarted(Task.CompletedTask);
        Assert.Null(editor.FramePass);
        var run = await RunAsync(editor);
        Assert.Equal(MakeItPhase.Ready, run.Phase);
        Assert.Equal([null], stub.FrameSources);
        Assert.Empty(stub.Sent);
        Assert.Null(run.Frames);
        Assert.Null(editor.FramePass);
        Assert.DoesNotContain(run.Rows, row => row.Id.StartsWith("frames-", StringComparison.Ordinal));
        Assert.Null(editor.MakeItSendLine(run));
        Assert.Null(editor.Project.Edits.Clips.Single().LeadInSeconds);
        Assert.Empty(editor.Project.ClipEffects);
        Assert.True(ClipControlsProject.Controls("clip-main", editor.Project) is { Reframe: null, CoverSeconds: null });
        // The same plan with faces adds exactly the four picture rows in front.
        var (framed, _, _) = Make();
        var withFrames = await RunAsync(framed);
        Assert.Equal(run.Rows.Select(row => row.Id), withFrames.Rows.Skip(4).Select(row => row.Id));
    }

    [Fact]
    public async Task WithoutAFaceTheCropStaysAndAnUnreadableVideoGoesOnAsTextOnly()
    {
        var (editor, _, _) = Make(face: false);
        var run = await RunAsync(editor);
        Assert.DoesNotContain(run.Rows, row => row.Id is ClipPicture.CropRowId or ClipPicture.CoverRowId);
        Assert.Null(ClipControlsProject.Controls("clip-main", editor.Project)!.Reframe);
        var (failing, stub, lines) = Make(failing: true);
        var unread = await RunAsync(failing);
        Assert.Equal(MakeItPhase.Ready, unread.Phase);
        Assert.Equal([null], stub.Sent);
        Assert.DoesNotContain(unread.Rows, row => row.Id.StartsWith("frames-", StringComparison.Ordinal));
        Assert.Null(failing.MakeItSendLine(unread));
        Assert.Single(lines, line => line.StartsWith("frames: ", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ThePassStartsBesideFindClipsKeepsItsKeyAndTimesItsStage()
    {
        var (editor, _, _) = Make();
        editor.ArmClaudeMode();
        editor.ClaudeModeFindStarted(Task.CompletedTask);
        var pass = editor.FramePass;
        Assert.NotNull(pass);
        Assert.True(await pass.FinishAsync(TestContext.Current.CancellationToken));
        Assert.Equal(pass.FrameCount, pass.Analyzed);
        Assert.Same(pass, editor.StartFramePass());
        Assert.Contains(editor.ClaudeMode.Clock!.Timings, timing => timing.Stage == ClaudeModeStage.Frames && timing.Clip is null);
    }

    [Fact]
    public async Task TheCoverChangeOffersTheOtherCandidatesAndAPickIsOneStep()
    {
        var (editor, _, _) = Make(plan: Plan(cover: "C9"));
        var run = await RunAsync(editor);
        var row = run.Rows.Single(item => item.Id == ClipPicture.CoverRowId);
        Assert.StartsWith("Eyes open, the clearest look measured on this PC", row.Detail, StringComparison.Ordinal);
        editor.MakeItChangeRow(row.Id, run);
        Assert.Equal(row.Id, run.OpenChoice);
        var time = run.Frames!.Sent.Cover[0].Time;
        Assert.True(editor.MakeItChooseCover(time, run));
        Assert.Equal(time, ClipControlsProject.Controls("clip-main", editor.Project)!.CoverSeconds);
        Assert.StartsWith("You chose the frame at ", run.Rows.Single(item => item.Id == row.Id).Detail, StringComparison.Ordinal);
        Assert.Null(run.OpenChoice);
    }
}
#endif
