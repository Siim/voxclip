using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>An inclusive range of transcript item positions (ai.md §16): a clip span, a cut or a rewrite.</summary>
public readonly record struct WordSpan(int Start, int End)
{
    /// <summary>Whether <paramref name="index"/> lies inside the span.</summary>
    public bool Contains(int index) => index >= Start && index <= End;
    /// <summary>The number of positions, 0 when the span is reversed.</summary>
    public int Count => End >= Start ? End - Start + 1 : 0;
    /// <summary>Whether the two spans share a position.</summary>
    public bool Overlaps(WordSpan other) => Start <= other.End && other.Start <= End;
    /// <summary>The positions in order.</summary>
    public IEnumerable<int> Indices => Count == 0 ? [] : Enumerable.Range(Start, Count);
}

/// <summary>How a removed run of words is described (ai.md §16.2).</summary>
public enum ClipAutopilotCutKind
{
    /// <summary>"um", "uh".</summary>
    Filler,
    /// <summary>A stumble.</summary>
    Stumble,
    /// <summary>A repeated word.</summary>
    Repeat,
    /// <summary>A false start.</summary>
    FalseStart,
    /// <summary>A tangent.</summary>
    Tangent,
    /// <summary>Anything else.</summary>
    Other
}

/// <summary>The caption text case a plan picks; its wire names are the Mac's.</summary>
public enum ClipAutopilotCaptionCase
{
    /// <summary>UPPER CASE.</summary>
    Upper,
    /// <summary>lower case.</summary>
    Lower,
    /// <summary>As the words were said.</summary>
    AsSaid
}

/// <summary>A plan's verdict, best first.</summary>
public enum ClipAutopilotVerdict
{
    /// <summary>Post this clip first.</summary>
    PostFirst,
    /// <summary>Worth posting.</summary>
    Post,
    /// <summary>A casual post.</summary>
    CasualPost,
    /// <summary>Hold it back.</summary>
    HoldBack
}

/// <summary>Wire names of the planner's enums, shared by the request, the validator and the plan's JSON.</summary>
public static class ClipAutopilotWire
{
    /// <summary>"filler", "stumble", "repeat", "falseStart", "tangent" or "other".</summary>
    public static string Name(this ClipAutopilotCutKind kind) => kind switch
    {
        ClipAutopilotCutKind.Filler => "filler", ClipAutopilotCutKind.Stumble => "stumble", ClipAutopilotCutKind.Repeat => "repeat",
        ClipAutopilotCutKind.FalseStart => "falseStart", ClipAutopilotCutKind.Tangent => "tangent", _ => "other"
    };
    /// <summary>"upper", "lower" or "asSaid".</summary>
    public static string Name(this ClipAutopilotCaptionCase textCase) => textCase switch
    {
        ClipAutopilotCaptionCase.Upper => "upper", ClipAutopilotCaptionCase.Lower => "lower", _ => "asSaid"
    };
    /// <summary>The caption style's <c>text.transform</c> (captions.md §2.4).</summary>
    public static string Transform(this ClipAutopilotCaptionCase textCase) => textCase switch
    {
        ClipAutopilotCaptionCase.Upper => "uppercase", ClipAutopilotCaptionCase.Lower => "lowercase", _ => "none"
    };
    /// <summary>"postFirst", "post", "casualPost" or "holdBack".</summary>
    public static string Name(this ClipAutopilotVerdict verdict) => verdict switch
    {
        ClipAutopilotVerdict.PostFirst => "postFirst", ClipAutopilotVerdict.Post => "post", ClipAutopilotVerdict.CasualPost => "casualPost", _ => "holdBack"
    };
    /// <summary>"original", "muted", "warm" or "bw".</summary>
    public static string Name(this ClipLook look) => look switch
    {
        ClipLook.Muted => "muted", ClipLook.Warm => "warm", ClipLook.Bw => "bw", _ => "original"
    };
    /// <summary>The cut kind of an exact wire name.</summary>
    public static ClipAutopilotCutKind? CutKind(string? name) =>
        Enum.GetValues<ClipAutopilotCutKind>().Select(kind => (ClipAutopilotCutKind?)kind).FirstOrDefault(kind => kind!.Value.Name() == name);
    /// <summary>The case of an exact wire name.</summary>
    public static ClipAutopilotCaptionCase? CaptionCase(string? name) =>
        Enum.GetValues<ClipAutopilotCaptionCase>().Select(value => (ClipAutopilotCaptionCase?)value).FirstOrDefault(value => value!.Value.Name() == name);
    /// <summary>The verdict of an exact wire name.</summary>
    public static ClipAutopilotVerdict? Verdict(string? name) =>
        Enum.GetValues<ClipAutopilotVerdict>().Select(value => (ClipAutopilotVerdict?)value).FirstOrDefault(value => value!.Value.Name() == name);
    /// <summary>The look of an exact wire name.</summary>
    public static ClipLook? Look(string? name) =>
        Enum.GetValues<ClipLook>().Select(value => (ClipLook?)value).FirstOrDefault(value => value!.Value.Name() == name);
    /// <summary>The verdict a score implies, used when the reply's verdict is unreadable.</summary>
    public static ClipAutopilotVerdict Implied(int score) =>
        score >= 9 ? ClipAutopilotVerdict.PostFirst : score >= 7 ? ClipAutopilotVerdict.Post : score >= 5 ? ClipAutopilotVerdict.CasualPost : ClipAutopilotVerdict.HoldBack;
}

/// <summary>A bundled caption font, upright.</summary>
public readonly record struct ClipAutopilotFont(string Family, int Weight);

/// <summary>One clip's complete "Make it postable" plan (ai.md §16): every decision Claude made, already checked against the
/// transcript, the caption styles and the bundled fonts (<see cref="ClipAutopilotValidator"/>). Word indices are transcript
/// item positions; every range is inclusive. Twin of the Mac <c>ClipAutopilotPlan</c> (version 4, reads 1 to 4).</summary>
public sealed record ClipAutopilotPlan
{
    /// <summary>The contract version a plan is written in.</summary>
    public const int CurrentVersion = 4;

    /// <summary>Words to remove, <c>StartWord...EndWord</c>.</summary>
    public sealed record Cut(int StartWord, int EndWord, ClipAutopilotCutKind Kind, string Reason);
    /// <summary>A detected pause, after <c>AfterWord</c>, to tighten to the project's kept length.</summary>
    public sealed record PauseCut(int AfterWord, string Reason);
    /// <summary>A misheard word spelled right; the audio is unchanged.</summary>
    public sealed record Correction(int Word, string Heard, string Text, string Reason);
    /// <summary>New words for the range, re-voiced in the creator's voice; <c>Text</c> keeps the bridge words.</summary>
    public sealed record Rewrite(int StartWord, int EndWord, string Text, string Reason);
    /// <summary>The caption choices: a built-in style other than off, a font, a case and words per caption.</summary>
    public sealed record Captions(string StyleId, ClipAutopilotFont Font, ClipAutopilotCaptionCase TextCase, int WordsPerCaption, string Reason = "");
    /// <summary>The clip's colour look with its reason.</summary>
    public sealed record Look(ClipLook Id, string Reason = "")
    {
        /// <summary>The footage as filmed.</summary>
        public static readonly Look Original = new(ClipLook.Original);
    }
    /// <summary>The whole clip played at <c>Rate</c>, never 1.</summary>
    public sealed record Speed(double Rate, string Reason);
    /// <summary>A background track suggestion, instrumental.</summary>
    public sealed record Music(string Title, string Mood, string Prompt, string Reason, double UnderVoiceDb);
    /// <summary>A punch-in from <c>Word</c> to <c>UntilWord</c> at <c>Scale</c>.</summary>
    public sealed record Zoom(int Word, int UntilWord, double Scale, string Reason);
    /// <summary>Something Claude was unsure of, with the answer the plan follows.</summary>
    public sealed record Question(string Text, string Answer, IReadOnlyList<string> Options);
    /// <summary>What the validator changed or left out of the reply.</summary>
    public sealed record Repair(string Field, bool Dropped, string Detail)
    {
        /// <summary>"dropped" or "repaired".</summary>
        public string Action => Dropped ? "dropped" : "repaired";
    }
    /// <summary>The tone the words were written in (version 3).</summary>
    public sealed record Tone(string Id, string Title, string Summary = "");
    /// <summary>Something the review shows next to the plan: "longWithoutReason" or "overLength".</summary>
    public sealed record Flag(string Kind, string Detail);
    /// <summary>What the reply chose among the frames the request listed (version 4, ai.md §19.6): which detected screens to blur and
    /// which candidate is the cover. Ids name <see cref="ClipAutopilotFrames"/> candidates; the validator keeps only listed ones.</summary>
    public sealed record FrameChoices(IReadOnlyList<FrameChoices.Blur> BlurChoices, FrameChoices.Cover? CoverChoice)
    {
        /// <summary>A blur candidate's id (<c>B1</c>…); true blurs the screen, false leaves it sharp.</summary>
        public sealed record Blur(string Id, bool Blurred, string Reason);
        /// <summary>A cover candidate's id (<c>C1</c>…<c>C3</c>); <c>Fallback</c> when the reply named no listed candidate and the
        /// local best (<c>C1</c>) was taken.</summary>
        public sealed record Cover(string Id, string Reason, bool Fallback = false);
        /// <summary>Equal when the decisions are.</summary>
        public bool Equals(FrameChoices? other) => other is not null && BlurChoices.SequenceEqual(other.BlurChoices) && Equals(CoverChoice, other.CoverChoice);
        /// <inheritdoc />
        public override int GetHashCode() => HashCode.Combine(BlurChoices.Count, CoverChoice);
    }

    /// <summary>Always <see cref="CurrentVersion"/> once read.</summary>
    public int Version { get; init; } = CurrentVersion;
    /// <summary>First word of the clip.</summary>
    public required int StartWord { get; init; }
    /// <summary>Last word of the clip.</summary>
    public required int EndWord { get; init; }
    /// <summary>The clip's title.</summary>
    public required string Title { get; init; }
    /// <summary>On-screen text for the first 2 s.</summary>
    public required string Hook { get; init; }
    /// <summary>Removed words.</summary>
    public IReadOnlyList<Cut> Cuts { get; init; } = [];
    /// <summary>Tightened pauses.</summary>
    public IReadOnlyList<PauseCut> PauseCuts { get; init; } = [];
    /// <summary>Applied before every other edit.</summary>
    public IReadOnlyList<Correction> Corrections { get; init; } = [];
    /// <summary>Re-voiced phrases.</summary>
    public IReadOnlyList<Rewrite> Rewrites { get; init; } = [];
    /// <summary>Caption choices.</summary>
    public required Captions CaptionChoice { get; init; }
    /// <summary>The colour look.</summary>
    public Look ClipLookChoice { get; init; } = Look.Original;
    /// <summary>Null plays the clip at its own speed.</summary>
    public Speed? SpeedChoice { get; init; }
    /// <summary>Up to three track suggestions.</summary>
    public IReadOnlyList<Music> MusicChoices { get; init; } = [];
    /// <summary>Index into <see cref="MusicChoices"/>, null when there is none.</summary>
    public int? MusicPick { get; init; }
    /// <summary>Punch-ins.</summary>
    public IReadOnlyList<Zoom> Zooms { get; init; } = [];
    /// <summary>Short X/LinkedIn post text.</summary>
    public required string PostText { get; init; }
    /// <summary>1...10.</summary>
    public required int Score { get; init; }
    /// <summary>The verdict.</summary>
    public required ClipAutopilotVerdict Verdict { get; init; }
    /// <summary>Why the score.</summary>
    public string ScoreReason { get; init; } = "";
    /// <summary>Why the clip runs past the target length.</summary>
    public string LengthReason { get; init; } = "";
    /// <summary>The finished length once cuts, pause cuts and speed apply; 0 in a version 1 plan.</summary>
    public double Seconds { get; init; }
    /// <summary>Questions with the answers the plan follows.</summary>
    public IReadOnlyList<Question> Questions { get; init; } = [];
    /// <summary>Validator repairs.</summary>
    public IReadOnlyList<Repair> Repairs { get; init; } = [];
    /// <summary>Length flags.</summary>
    public IReadOnlyList<Flag> Flags { get; init; } = [];
    /// <summary>The tone the words were written in; null keeps the creator's own.</summary>
    public Tone? ToneChoice { get; init; }
    /// <summary>The frame choices (version 4); null when the request carried no frames.</summary>
    public FrameChoices? Frames { get; init; }

    /// <summary>The picked music, when there is one.</summary>
    public Music? PickedMusic => MusicPick is { } pick && pick >= 0 && pick < MusicChoices.Count ? MusicChoices[pick] : null;
    /// <summary>The clip's span.</summary>
    public WordSpan Span => new(StartWord, EndWord);

    /// <summary>The plan's JSON, in the Mac encoder's keys; null optionals are omitted.</summary>
    public JsonObject ToJson()
    {
        static JsonArray Array<T>(IEnumerable<T> items, Func<T, JsonNode> map) => new(items.Select(map).ToArray());
        var json = new JsonObject
        {
            ["version"] = Version, ["startWord"] = StartWord, ["endWord"] = EndWord, ["title"] = Title, ["hook"] = Hook,
            ["cuts"] = Array(Cuts, cut => new JsonObject { ["startWord"] = cut.StartWord, ["endWord"] = cut.EndWord, ["kind"] = cut.Kind.Name(), ["reason"] = cut.Reason }),
            ["pauseCuts"] = Array(PauseCuts, pause => new JsonObject { ["afterWord"] = pause.AfterWord, ["reason"] = pause.Reason }),
            ["corrections"] = Array(Corrections, item => new JsonObject { ["word"] = item.Word, ["heard"] = item.Heard, ["text"] = item.Text, ["reason"] = item.Reason }),
            ["rewrites"] = Array(Rewrites, item => new JsonObject { ["startWord"] = item.StartWord, ["endWord"] = item.EndWord, ["text"] = item.Text, ["reason"] = item.Reason }),
            ["captions"] = new JsonObject
            {
                ["styleId"] = CaptionChoice.StyleId, ["font"] = new JsonObject { ["family"] = CaptionChoice.Font.Family, ["weight"] = CaptionChoice.Font.Weight },
                ["case"] = CaptionChoice.TextCase.Name(), ["wordsPerCaption"] = CaptionChoice.WordsPerCaption, ["reason"] = CaptionChoice.Reason
            },
            ["look"] = new JsonObject { ["id"] = ClipLookChoice.Id.Name(), ["reason"] = ClipLookChoice.Reason },
            ["music"] = Array(MusicChoices, item => new JsonObject { ["title"] = item.Title, ["mood"] = item.Mood, ["prompt"] = item.Prompt, ["reason"] = item.Reason, ["underVoiceDb"] = item.UnderVoiceDb }),
            ["zooms"] = Array(Zooms, item => new JsonObject { ["word"] = item.Word, ["untilWord"] = item.UntilWord, ["scale"] = item.Scale, ["reason"] = item.Reason }),
            ["postText"] = PostText, ["score"] = Score, ["verdict"] = Verdict.Name(), ["scoreReason"] = ScoreReason, ["lengthReason"] = LengthReason, ["seconds"] = Seconds,
            ["questions"] = Array(Questions, item => new JsonObject { ["question"] = item.Text, ["answer"] = item.Answer, ["options"] = new JsonArray(item.Options.Select(option => (JsonNode)option!).ToArray()) }),
            ["repairs"] = Array(Repairs, item => new JsonObject { ["field"] = item.Field, ["action"] = item.Action, ["detail"] = item.Detail }),
            ["flags"] = Array(Flags, item => new JsonObject { ["kind"] = item.Kind, ["detail"] = item.Detail })
        };
        if (SpeedChoice is { } speed) json["speed"] = new JsonObject { ["rate"] = speed.Rate, ["reason"] = speed.Reason };
        if (MusicPick is { } pick) json["musicPick"] = pick;
        if (ToneChoice is { } tone) json["tone"] = new JsonObject { ["id"] = tone.Id, ["title"] = tone.Title, ["summary"] = tone.Summary };
        if (Frames is { } frames)
        {
            var choices = new JsonObject { ["blur"] = Array(frames.BlurChoices, item => new JsonObject { ["id"] = item.Id, ["blur"] = item.Blurred, ["reason"] = item.Reason }) };
            if (frames.CoverChoice is { } cover) choices["cover"] = new JsonObject { ["id"] = cover.Id, ["reason"] = cover.Reason, ["fallback"] = cover.Fallback };
            json["frames"] = choices;
        }
        return json;
    }

    /// <summary>Reads a stored plan of version 1 to 4 and upgrades it: version 1 has no corrections, the original look, no speed,
    /// no stated reasons, no length and no flags; versions 1 and 2 have no tone; versions 1 to 3 have no frame choices. Any other
    /// version or shape is refused.</summary>
    public static ClipAutopilotPlan FromJson(JsonObject json)
    {
        try
        {
            var version = json["version"]!.GetValue<int>();
            if (version is < 1 or > CurrentVersion) throw new JsonException("Unknown plan version");
            static string S(JsonNode? node) => node!.GetValue<string>();
            static int I(JsonNode? node) => node!.GetValue<int>();
            static IEnumerable<JsonNode> Items(JsonNode? node) => node!.AsArray().Select(item => item!);
            var captions = json["captions"]!;
            var look = json["look"];
            return new ClipAutopilotPlan
            {
                StartWord = I(json["startWord"]), EndWord = I(json["endWord"]), Title = S(json["title"]), Hook = S(json["hook"]),
                Cuts = Items(json["cuts"]).Select(item => new Cut(I(item["startWord"]), I(item["endWord"]), ClipAutopilotWire.CutKind(S(item["kind"])) ?? throw new JsonException(), S(item["reason"]))).ToArray(),
                PauseCuts = Items(json["pauseCuts"]).Select(item => new PauseCut(I(item["afterWord"]), S(item["reason"]))).ToArray(),
                Corrections = json["corrections"] is null ? [] : Items(json["corrections"]).Select(item => new Correction(I(item["word"]), S(item["heard"]), S(item["text"]), S(item["reason"]))).ToArray(),
                Rewrites = Items(json["rewrites"]).Select(item => new Rewrite(I(item["startWord"]), I(item["endWord"]), S(item["text"]), S(item["reason"]))).ToArray(),
                CaptionChoice = new(S(captions["styleId"]), new(S(captions["font"]!["family"]), I(captions["font"]!["weight"])),
                    ClipAutopilotWire.CaptionCase(S(captions["case"])) ?? throw new JsonException(), I(captions["wordsPerCaption"]), captions["reason"] is null ? "" : S(captions["reason"])),
                ClipLookChoice = look is null ? Look.Original : new(ClipAutopilotWire.Look(S(look["id"])) ?? throw new JsonException(), look["reason"] is null ? "" : S(look["reason"])),
                SpeedChoice = json["speed"] is { } speed ? new(speed["rate"]!.GetValue<double>(), S(speed["reason"])) : null,
                MusicChoices = Items(json["music"]).Select(item => new Music(S(item["title"]), S(item["mood"]), S(item["prompt"]), S(item["reason"]), item["underVoiceDb"]!.GetValue<double>())).ToArray(),
                MusicPick = json["musicPick"] is { } pick ? pick.GetValue<int>() : null,
                Zooms = Items(json["zooms"]).Select(item => new Zoom(I(item["word"]), I(item["untilWord"]), item["scale"]!.GetValue<double>(), S(item["reason"]))).ToArray(),
                PostText = S(json["postText"]), Score = I(json["score"]), Verdict = ClipAutopilotWire.Verdict(S(json["verdict"])) ?? throw new JsonException(),
                ScoreReason = S(json["scoreReason"]), LengthReason = json["lengthReason"] is null ? "" : S(json["lengthReason"]),
                Seconds = json["seconds"]?.GetValue<double>() ?? 0,
                Questions = Items(json["questions"]).Select(item => new Question(S(item["question"]), S(item["answer"]), Items(item["options"]).Select(option => option.GetValue<string>()).ToArray())).ToArray(),
                Repairs = json["repairs"] is null ? [] : Items(json["repairs"]).Select(item => new Repair(S(item["field"]), S(item["action"]) switch { "dropped" => true, "repaired" => false, _ => throw new JsonException() }, S(item["detail"]))).ToArray(),
                Flags = json["flags"] is null ? [] : Items(json["flags"]).Select(item => new Flag(S(item["kind"]), S(item["detail"]))).ToArray(),
                ToneChoice = json["tone"] is { } tone ? new(S(tone["id"]), S(tone["title"]), S(tone["summary"])) : null,
                Frames = json["frames"] is { } frames ? new(Items(frames["blur"]).Select(item => new FrameChoices.Blur(S(item["id"]), item["blur"]!.GetValue<bool>(), S(item["reason"]))).ToArray(),
                    frames["cover"] is { } cover ? new FrameChoices.Cover(S(cover["id"]), S(cover["reason"]), cover["fallback"]?.GetValue<bool>() ?? false) : null) : null
            };
        }
        catch (Exception exception) when (exception is InvalidOperationException or NullReferenceException or FormatException or JsonException)
        {
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "The plan could not be read.");
        }
    }
}

/// <summary>A moment the first stage of a series picked (ai.md §16.3).</summary>
public sealed record ClipAutopilotMoment(int StartWord, int EndWord, string Title, string Idea, int Score, ClipAutopilotVerdict Verdict,
    string ScoreReason, string CaptionStyle, string CaptionReason)
{
    /// <summary>A Find Clips suggestion as a moment of Claude mode's series (<see cref="ClipAutopilotRequest.Moments"/>): its span, title
    /// and reason, the score it was given and no caption style, which each clip's plan picks.</summary>
    public static ClipAutopilotMoment Found(WordSpan span, string title, string reason, int score) =>
        new(span.Start, span.End, title, reason, score, ClipAutopilotWire.Implied(score), "", "", "");
}

/// <summary>A whole video made into a series, or the plans of a <c>clips</c> request: ranked best first, never overlapping.</summary>
public sealed record ClipAutopilotSeries(IReadOnlyList<ClipAutopilotPlan> Plans, IReadOnlyList<ClipAutopilotMoment> Moments, IReadOnlyList<ClipAutopilotPlan.Repair> Repairs)
{
    /// <summary>One plan, no moments, no repairs.</summary>
    public ClipAutopilotSeries(IReadOnlyList<ClipAutopilotPlan> plans) : this(plans, [], []) { }
}
