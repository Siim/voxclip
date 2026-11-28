using System.Globalization;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

/// <summary>Claude's look for one clip (looks spec §9.6), held per clip for the session and never stored in the project.</summary>
/// <param name="LookId">The look of shared/looks/clip-looks.json.</param>
/// <param name="Amount">Claude's amount.</param>
/// <param name="Reason">Claude's one sentence.</param>
/// <param name="Alternatives">Up to two other looks, marked ✦ in Suggested.</param>
/// <param name="Fix">The measured Fix Claude applied with it; null when the clip's own Fix was kept.</param>
public sealed record PictureClaudePick(string LookId, int Amount, string Reason, IReadOnlyList<string> Alternatives, ClipColorFix? Fix = null);

/// <summary>The thirteen Fine-tune sliders (looks spec §5.1), in panel order.</summary>
public enum PictureControl { Exposure, Temperature, Tint, Brightness, Contrast, Highlights, Shadows, Vibrance, Saturation, Warmth, Fade, Vignette, Grain }

/// <summary>Fine-tune's four groups.</summary>
public enum PictureGroupId { Fix, Light, Color, Effects }

/// <summary>What a tile click did: nothing, a "Change look" step, or (the applied, unedited tile again) focus to Amount.</summary>
public enum PictureApplyOutcome { None, Applied, FocusAmount }

/// <summary>Whether the paused frame could be read for tiles and previews (looks spec §7.7).</summary>
public enum PictureStillState { Ready, Offline, Unreadable }

/// <summary>What the page needs to run Picture: the looks file, Auto's measurement and the remembered Fine-tune fold.</summary>
/// <param name="Looks">shared/looks/clip-looks.json.</param>
public sealed record PicturePanelServices(ClipLookLibrary Looks)
{
    /// <summary>Auto's Fix measured on the clip's frames (<see cref="ClipColorFix.Measure"/>); null when they can't be read. Null uses
    /// the editor's frame pass.</summary>
    public Func<string, CancellationToken, Task<ClipColorFix?>>? Measure { get; init; }
    /// <summary>The remembered fold (<see cref="PicturePanelModel.FineTuneSetting"/>).</summary>
    public bool FineTuneOpen { get; init; }
    /// <summary>Stores the fold's state when the user opens or closes it.</summary>
    public Action<bool>? RememberFineTune { get; init; }
}

/// <summary>One slider row: its value, range, the look's own value (the tick), the text beside it and what Narrator reads.</summary>
public sealed record PictureSlider(PictureControl Control, string Label, int Value, int Minimum, int Maximum, int LookValue, string ValueText,
    string Spoken, string? Help, string? Reason)
{
    /// <summary>The slider can be changed.</summary>
    public bool IsEnabled => Reason is null;
}

/// <summary>A Fine-tune group: its heading (Fix carries a note), its sliders and its Reset.</summary>
public sealed record PictureGroup(PictureGroupId Id, string Heading, string? Note, IReadOnlyList<PictureSlider> Sliders, string ResetName, string? ResetReason)
{
    /// <summary>"Fix, stays when you change look".</summary>
    public string SpokenHeading => Note is null ? Heading : Heading + ", " + Note;
}

/// <summary>A category chip: Suggested, All, or a category of the looks file.</summary>
public sealed record PictureChip(string Id, string Label, bool Selected);

/// <summary>One look's tile.</summary>
public sealed record PictureTile(ClipLookPreset Look, string CategoryLabel, bool Applied, bool Edited, bool Claude, bool Pick, int Amount)
{
    /// <summary>"Warm Print, Film look".</summary>
    public string Name => Look.Label + ", " + CategoryLabel + " look";
    /// <summary>Narrator's item status.</summary>
    public string Status => Applied ? Edited ? "Selected, edited" : Amount < 100 ? $"Selected, amount {Amount.ToString(CultureInfo.InvariantCulture)} percent" : "Selected"
        : Pick ? "Claude's pick" : Claude ? "Claude's alternative" : "";
    /// <summary>The one-line look.</summary>
    public string Help => Look.Line;
    /// <summary>The label under the tile; high contrast spells out "edited" where the dashed ring would show it.</summary>
    public string Label(bool highContrast) => highContrast && Edited ? Look.Label + ", edited" : Look.Label;
}

/// <summary>What the paused viewer shows instead of the clip's own colour: a hovered look, Compare's As filmed, or a dragged value.</summary>
/// <param name="Colour">The clip's controls with the colour to show.</param>
/// <param name="Badge">"Preview · Golden Hour", "As filmed", or null for a drag.</param>
public sealed record PicturePreview(ProjectClipControls Colour, string? Badge);

/// <summary>The line about Claude's look: "Claude chose …" while it holds, "Claude's pick: …" with Use it after a hand change.</summary>
public sealed record PictureClaudeLine(string Text, string Detail, bool CanUse);

/// <summary>A timed Ask Claude look over this clip (ai.md §18.5), which replaces the clip's base look for its stretch.</summary>
public sealed record PictureTimedLook(string Id, string Text, double Start);

/// <summary>The Picture tab's state (looks spec §3, mockup frame 4), the twin of the Mac <c>ClipLookControls</c>: the look row,
/// Amount, Compare, the category chips and tiles, the Fine-tune groups and their resets, Auto and Claude's pick, with every disabled
/// reason of §10. Each change is one undo step through the editor's replace; hover, Compare, the chip and the fold are view state.</summary>
public sealed class PicturePanelModel(EditorViewModel editor)
{
    /// <summary>The Suggested chip.</summary>
    public const string Suggested = "suggested";
    /// <summary>The All chip.</summary>
    public const string All = "all";
    /// <summary>The remembered fold's settings key.</summary>
    public const string FineTuneSetting = "ui.pictureFineTuneOpen";
    /// <summary>Amount's accessible name.</summary>
    public const string AmountName = "Look amount";
    /// <summary>Amount's accessible help.</summary>
    public const string AmountHelp = "Blends the look over the clip; the fix stays";
    /// <summary>Compare's accessible name.</summary>
    public const string CompareName = "Compare with as filmed";
    /// <summary>The tile's help while playing.</summary>
    public const string PauseToPreview = "Pause to preview on the viewer";
    private const string Original = "original";
    private const string Minus = "−";

    /// <summary>Suggested's starters, after As filmed, Claude's looks and the current look (looks spec §3.2).</summary>
    public static IReadOnlyList<string> Starters { get; } = ["naturalBoost", "softSkin", "warm", "goldenHour", "warmPrint", "softBW", "cleanPop"];

    private static readonly (PictureControl Control, string Label, PictureGroupId Group)[] Table =
    [
        (PictureControl.Exposure, "Exposure", PictureGroupId.Fix), (PictureControl.Temperature, "Temperature", PictureGroupId.Fix),
        (PictureControl.Tint, "Tint", PictureGroupId.Fix), (PictureControl.Brightness, "Brightness", PictureGroupId.Light),
        (PictureControl.Contrast, "Contrast", PictureGroupId.Light), (PictureControl.Highlights, "Highlights", PictureGroupId.Light),
        (PictureControl.Shadows, "Shadows", PictureGroupId.Light), (PictureControl.Vibrance, "Vibrance", PictureGroupId.Color),
        (PictureControl.Saturation, "Saturation", PictureGroupId.Color), (PictureControl.Warmth, "Warmth", PictureGroupId.Color),
        (PictureControl.Fade, "Fade", PictureGroupId.Effects), (PictureControl.Vignette, "Vignette", PictureGroupId.Effects),
        (PictureControl.Grain, "Grain", PictureGroupId.Effects),
    ];

    private readonly Dictionary<string, PictureClaudePick> picks = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ClipColorFix?> measured = new(StringComparer.Ordinal);
    private readonly HashSet<string> measuring = new(StringComparer.Ordinal);
    private PicturePanelServices? services;
    private bool fineTuneRemembered;
    private string? foldClosedFor;

    /// <summary>The page's services; null shows the tab without looks.</summary>
    public PicturePanelServices? Services
    {
        get => services;
        set { services = value; fineTuneRemembered = value?.FineTuneOpen ?? false; Notify(); }
    }

    /// <summary>The chip shown, remembered for the window (view state).</summary>
    public string Category { get; private set; } = Suggested;
    /// <summary>The preview plays; hover previews wait for a pause.</summary>
    public bool Playing { get; private set; }
    /// <summary>Compare is held.</summary>
    public bool Comparing { get; private set; }
    /// <summary>What the paused viewer shows instead of the clip's colour; null for the clip itself.</summary>
    public PicturePreview? Preview { get; private set; }
    /// <summary>Whether the paused frame could be read.</summary>
    public PictureStillState StillState { get; private set; }
    /// <summary>The last measurement's task, for the page and tests to wait on.</summary>
    public Task Measuring { get; private set; } = Task.CompletedTask;

    /// <summary>Anything the tab shows changed (the project changes through the editor's own event).</summary>
    public event EventHandler? Changed;
    /// <summary>The viewer's preview changed.</summary>
    public event EventHandler? PreviewChanged;
    /// <summary>A change to read out ("Look Warm Print", "Vibrance plus 20").</summary>
    public event EventHandler<string>? Announced;
    /// <summary>▶ on a timed look: the page plays from this source second.</summary>
    public event EventHandler<double>? PlayRequested;

    private ClipLookLibrary? Looks => services?.Looks;

    /// <summary>The open clip; null on Full Take.</summary>
    public string? ClipId => editor.Project.Edits.ActiveClipId;

    /// <summary>The source has a picture, so the tab shows.</summary>
    public bool IsAvailable => editor.Project.Media.Source.Video is not null;

    /// <summary>The open clip's controls.</summary>
    public ProjectClipControls? Controls => ClipControlsProject.Controls(ClipId, editor.Project);

    /// <summary>Why nothing in the tab can change the look (looks spec §10); null when it can.</summary>
    public string? Blocked => ClipId is null ? "Open a clip to choose its look."
        : !IsAvailable ? "This recording has no picture to color."
        : Looks is null ? "VoxClip couldn't read its looks."
        : editor.IsRelinking ? "Confirm the video to change the look."
        : editor.IsReadOnly ? "Locate the video to change the look."
        : null;

    private ClipLookMatch? Match => Controls is { } controls && Looks is { } looks ? looks.Match(controls) : null;

    /// <summary>The look values come from a preset (applied or edited) other than As filmed.</summary>
    private ClipLookPreset? Origin => Match is { Look.Id: not Original } match ? match.Look : null;

    private static int AmountOf(ProjectClipControls controls) => controls.ColorGrade?.Amount ?? 100;

    private static bool LookNeutral(ProjectClipControls controls) => controls.Look == ClipLook.Original && controls.ColorAdjustments is null &&
        (controls.ColorGrade?.LookValues ?? ClipColorGrade.Neutral) == ClipColorGrade.Neutral;

    private static bool ColourNeutral(ProjectClipControls controls) =>
        controls.Look == ClipLook.Original && controls.ColorAdjustments is null && controls.ColorGrade is null;

    // MARK: The look row

    /// <summary>"Warm Print", "Warm Print, edited", "Custom" or "As filmed", without the amount.</summary>
    public string LookName => Controls is { } controls && Looks is { } looks && looks.Match(controls) is not { Look.Id: Original, Edited: false }
        ? looks.Name(controls) : "As filmed";

    /// <summary>"Warm Print · 70%", "Warm Print, edited · 70%", "Custom" or "As filmed" (looks spec §3.1).</summary>
    public string LookText => LookName == "As filmed" || Controls is not { } controls || AmountOf(controls) >= 100
        ? LookName : LookName + " · " + AmountOf(controls).ToString(CultureInfo.InvariantCulture) + "%";

    // MARK: Amount

    /// <summary>The look's amount, 0–100.</summary>
    public int Amount => Controls is { } controls ? AmountOf(controls) : 100;
    /// <summary>"70%".</summary>
    public string AmountText => Amount.ToString(CultureInfo.InvariantCulture) + "%";
    /// <summary>"70 percent".</summary>
    public string AmountSpoken => Amount.ToString(CultureInfo.InvariantCulture) + " percent";
    /// <summary>Why Amount can't change; null when it can.</summary>
    public string? AmountReason => Blocked ?? (Controls is { } controls && LookNeutral(controls) ? "As filmed has no look to blend" : null);

    /// <summary>Sets the amount as one "Change look amount" step; false when nothing changed.</summary>
    public bool SetAmount(int amount)
    {
        if (AmountReason is not null || Controls is not { } controls) return false;
        var value = Math.Clamp(amount, 0, 100);
        if (!Commit(WithAmount(controls, value), "Change look amount")) return false;
        Announce("Amount " + value.ToString(CultureInfo.InvariantCulture) + " percent");
        return true;
    }

    /// <summary>Shows a dragged amount on the paused viewer; the release calls <see cref="SetAmount"/>.</summary>
    public bool PreviewAmount(int amount) =>
        AmountReason is null && Controls is { } controls && Show(new(WithAmount(controls, Math.Clamp(amount, 0, 100)), null), false);

    private ProjectClipControls WithAmount(ProjectClipControls controls, int amount)
    {
        var grade = controls.ColorGrade ?? ClipColorGrade.Neutral;
        return controls with { ColorGrade = grade with { Amount = amount, Preset = grade.Preset ?? Origin?.Id } };
    }

    /// <summary>"70%", "70" or "70 %" as an amount; null for anything else.</summary>
    public static int? ParseAmount(string text) =>
        int.TryParse(text.Replace("%", "", StringComparison.Ordinal).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? Math.Clamp(value, 0, 100) : null;

    // MARK: Compare and previews

    /// <summary>Why the viewer can't preview here; null when it can.</summary>
    private string? PreviewBlocked => ClipId is null || !IsAvailable ? Blocked
        : editor.IsReadOnly || StillState == PictureStillState.Offline ? "Previews need the source video. Looks still apply when it's back." : null;

    /// <summary>The line above the grid when previews can't use this frame (looks spec §7.7); null otherwise.</summary>
    public string? PreviewNote => PreviewBlocked is { } blocked && ClipId is not null && IsAvailable ? blocked
        : StillState == PictureStillState.Unreadable ? "Showing looks on a sample picture: this frame couldn't be read." : null;

    /// <summary>Why Compare is unavailable; null when it can show As filmed.</summary>
    public string? CompareReason => PreviewBlocked ?? (Controls is { } controls && ColourNeutral(controls) ? "Nothing to compare: the clip is as filmed" : null);

    /// <summary>"Showing as filmed" or "Showing Warm Print, edited", Compare's toggle value.</summary>
    public string CompareStatus => Comparing ? "Showing as filmed" : "Showing " + LookName;

    /// <summary>Why hovering a tile doesn't preview: the reason above, or <see cref="PauseToPreview"/> while playing.</summary>
    public string? HoverReason => PreviewBlocked ?? (Playing ? PauseToPreview : null);

    /// <summary>Holds Compare: the viewer shows As filmed, without the Fix, the look or the effects.</summary>
    public bool BeginCompare()
    {
        if (CompareReason is not null || Controls is not { } controls) return false;
        Comparing = true;
        Show(new(new ClipColorState().Applied(controls), "As filmed"), true);
        return true;
    }

    /// <summary>Releases Compare.</summary>
    public void EndCompare()
    {
        if (!Comparing) return;
        Comparing = false;
        Show(null, true);
    }

    /// <summary>Narrator's toggle and the palette's command; returns whether Compare now shows.</summary>
    public bool ToggleCompare()
    {
        if (Comparing) { EndCompare(); return false; }
        return BeginCompare();
    }

    /// <summary>Previews a look at 100% with the clip's Fix on the paused viewer (looks spec §3.4); false while playing or offline.</summary>
    public bool PreviewLook(string id)
    {
        if (HoverReason is not null || Comparing || Controls is not { } controls || Looks?.Look(id) is not { } look) return false;
        return Show(new(controls.WithLook(look), "Preview · " + look.Label), false);
    }

    /// <summary>Shows a dragged slider value on the paused viewer; the release calls <see cref="SetValue"/>.</summary>
    public bool PreviewValue(PictureControl control, int value) =>
        Blocked is null && Reason(control) is null && Controls is { } controls && Show(new(With(controls, control, value), null), false);

    /// <summary>Ends a hover or drag preview (the pointer left the grid, Escape, or playback started); Compare stays.</summary>
    public void EndPreview()
    {
        if (!Comparing && Preview is not null) Show(null, false);
    }

    /// <summary>Playback started or stopped: a start ends hover previews and Compare.</summary>
    public void SetPlaying(bool playing)
    {
        if (Playing == playing) return;
        Playing = playing;
        if (playing) { Comparing = false; Show(null, true); }
        Notify();
    }

    /// <summary>The page read, or couldn't read, the paused frame.</summary>
    public void SetStillState(PictureStillState state)
    {
        if (StillState == state) return;
        StillState = state;
        if (state == PictureStillState.Offline) { Comparing = false; Show(null, true); }
        Notify();
    }

    private bool Show(PicturePreview? preview, bool force)
    {
        if (!force && Comparing) return false;
        Preview = preview;
        PreviewChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    // MARK: Chips and tiles

    /// <summary>Suggested, All and the file's categories.</summary>
    public IReadOnlyList<PictureChip> Chips => new[] { (Suggested, "Suggested"), (All, "All") }
        .Concat((Looks?.Categories ?? []).Select(category => (category.Id, category.Label)))
        .Select(chip => new PictureChip(chip.Item1, chip.Item2, chip.Item1 == Category)).ToArray();

    /// <summary>Shows another chip's tiles (view state, no step).</summary>
    public void SelectCategory(string id)
    {
        if (Category == id || !Chips.Any(chip => chip.Id == id)) return;
        Category = id;
        Notify();
    }

    /// <summary>"Looks, Film".</summary>
    public string TilesName => "Looks, " + Chips.First(chip => chip.Selected).Label;
    /// <summary>"5 looks".</summary>
    public string TilesStatus => Tiles.Count == 1 ? "1 look" : Tiles.Count.ToString(CultureInfo.InvariantCulture) + " looks";

    /// <summary>The chosen chip's tiles.</summary>
    public IReadOnlyList<PictureTile> Tiles
    {
        get
        {
            if (Looks is not { } looks) return [];
            var shown = Category switch
            {
                Suggested => SuggestedLooks(looks),
                All => looks.Visible,
                _ => looks.Visible.Where(look => look.Category == Category).ToArray(),
            };
            var match = Match;
            var pick = Pick;
            var amount = Controls is { } controls ? AmountOf(controls) : 100;
            var labels = looks.Categories.ToDictionary(category => category.Id, category => category.Label, StringComparer.Ordinal);
            return shown.Select(look =>
            {
                var applied = match?.Look.Id == look.Id;
                var claude = pick is not null && (pick.LookId == look.Id || pick.Alternatives.Take(2).Contains(look.Id));
                return new PictureTile(look, labels.GetValueOrDefault(look.Category, look.Category), applied, applied && match!.Edited, claude,
                    pick?.LookId == look.Id, applied ? amount : 100);
            }).ToArray();
        }
    }

    private IReadOnlyList<ClipLookPreset> SuggestedLooks(ClipLookLibrary looks)
    {
        var ids = new List<string> { Original };
        if (Pick is { } pick) { ids.Add(pick.LookId); ids.AddRange(pick.Alternatives.Take(2)); }
        var current = Match?.Look.Id;
        if (current is not null) ids.Add(current);
        ids.AddRange(Starters);
        return ids.Distinct(StringComparer.Ordinal).Select(looks.Look).OfType<ClipLookPreset>()
            .Where(look => !look.Hidden || look.Id == current).Take(8).ToArray();
    }

    /// <summary>A tile's square of a <paramref name="width"/> × <paramref name="height"/> still before the grade: the largest square in the
    /// middle of the frame (looks spec §7.3; Windows doesn't map the face anchor into the output frame yet).</summary>
    public static RectD TileSquare(int width, int height)
    {
        var side = Math.Min(width, height);
        return new((width - side) / 2, (height - side) / 2, side, side);
    }

    /// <summary>The colour a tile and its hover preview show: the look at 100% with the clip's Fix (looks spec §7.4).</summary>
    public ProjectClipControls? TileColour(ClipLookPreset look) => Controls?.WithLook(look);

    /// <summary>A click on a tile (looks spec §3.2): the look at 100% as "Change look"; the applied, unedited tile again moves focus to
    /// Amount; an edited applied tile gets the look's values back and keeps Amount and the Fix.</summary>
    public PictureApplyOutcome Apply(string id)
    {
        if (Blocked is not null || Controls is not { } controls || Looks?.Look(id) is not { } look) return PictureApplyOutcome.None;
        var match = Match;
        if (match?.Look.Id == id && !match.Edited) return id == Original ? PictureApplyOutcome.None : PictureApplyOutcome.FocusAmount;
        if (!Commit(controls.WithLook(look, match?.Look.Id == id ? AmountOf(controls) : 100), "Change look")) return PictureApplyOutcome.None;
        Announce("Look " + look.Label);
        return PictureApplyOutcome.Applied;
    }

    // MARK: Fine-tune

    /// <summary>The fold is open: as remembered, or by itself for a Custom or edited look until the user closes it for this clip.</summary>
    public bool FineTuneOpen => fineTuneRemembered || (OpensItself && foldClosedFor != ClipId);

    /// <summary>A Custom or edited look opens the fold without changing the remembered state.</summary>
    private bool OpensItself => Controls is not null && Match is null or { Edited: true };

    /// <summary>Opens or closes the fold and remembers it per app (view state); closing a fold that opened itself keeps it closed for
    /// this clip.</summary>
    public void ToggleFineTune()
    {
        var open = !FineTuneOpen;
        fineTuneRemembered = open;
        foldClosedFor = !open && OpensItself ? ClipId : null;
        services?.RememberFineTune?.Invoke(open);
        Notify();
    }

    /// <summary>The four groups and their sliders.</summary>
    public IReadOnlyList<PictureGroup> Groups
    {
        get
        {
            var controls = Controls;
            return Enum.GetValues<PictureGroupId>().Select(id =>
            {
                var sliders = Table.Where(row => row.Group == id).Select(row => Slider(row.Control, row.Label, controls)).ToArray();
                var (heading, note) = id switch
                {
                    PictureGroupId.Fix => ("Fix", "stays when you change look"), PictureGroupId.Light => ("Light", (string?)null),
                    PictureGroupId.Color => ("Color", null), _ => ("Effects", null),
                };
                var reset = Blocked ?? (sliders.All(slider => slider.Value == slider.LookValue) ? "Nothing to reset" : null);
                return new PictureGroup(id, heading, note, sliders, "Reset " + heading.ToLowerInvariant(), reset);
            }).ToArray();
        }
    }

    private PictureSlider Slider(PictureControl control, string label, ProjectClipControls? controls)
    {
        var value = controls is null ? 0 : Value(controls, control);
        var look = LookValue(control);
        var origin = Origin;
        return new(control, label, value, Minimum(control), 100, look, ValueText(control, value), Spoken(control, value),
            origin is null ? null : origin.Label + "'s value: " + ValueText(control, look), Reason(control));
    }

    private string? Reason(PictureControl control) => Blocked ??
        (control is PictureControl.Vibrance or PictureControl.Saturation && Controls?.Look == ClipLook.Bw ? "No effect on black and white" : null);

    private static int Minimum(PictureControl control) => control is PictureControl.Fade or PictureControl.Vignette or PictureControl.Grain ? 0 : -100;

    private static int Value(ProjectClipControls controls, PictureControl control)
    {
        var grade = controls.ColorGrade ?? ClipColorGrade.Neutral;
        var adjustments = controls.ColorAdjustments;
        return Value(grade, adjustments, control);
    }

    private static int Value(ClipColorGrade grade, ClipColorAdjustments? adjustments, PictureControl control) => control switch
    {
        PictureControl.Exposure => grade.Exposure, PictureControl.Temperature => grade.Temperature, PictureControl.Tint => grade.Tint,
        PictureControl.Brightness => adjustments?.Brightness ?? 0, PictureControl.Contrast => adjustments?.Contrast ?? 0,
        PictureControl.Highlights => grade.Highlights, PictureControl.Shadows => grade.Shadows, PictureControl.Vibrance => grade.Vibrance,
        PictureControl.Saturation => adjustments?.Saturation ?? 0, PictureControl.Warmth => adjustments?.Warmth ?? 0,
        PictureControl.Fade => grade.Fade, PictureControl.Vignette => grade.Vignette, _ => grade.Grain,
    };

    /// <summary>The look's own value of a control (the tick), 0 without a preset origin; the Fix is never a look's.</summary>
    private int LookValue(PictureControl control) => Origin is { } look && control is not (PictureControl.Exposure or PictureControl.Temperature or PictureControl.Tint)
        ? Value(look.Grade, look.Adjustments, control) : 0;

    private ProjectClipControls With(ProjectClipControls controls, PictureControl control, int value)
    {
        value = Math.Clamp(value, Minimum(control), 100);
        if (control is PictureControl.Brightness or PictureControl.Contrast or PictureControl.Saturation or PictureControl.Warmth)
        {
            var old = controls.ColorAdjustments ?? new(0, 0, 0, 0);
            var adjustments = control switch
            {
                PictureControl.Brightness => old with { Brightness = value }, PictureControl.Contrast => old with { Contrast = value },
                PictureControl.Saturation => old with { Saturation = value }, _ => old with { Warmth = value },
            };
            var grade = controls.ColorGrade is { } current ? current with { Preset = current.Preset ?? Origin?.Id } : null;
            return controls with { ColorAdjustments = adjustments == new ClipColorAdjustments(0, 0, 0, 0) ? null : adjustments, ColorGrade = grade };
        }
        var before = controls.ColorGrade ?? ClipColorGrade.Neutral;
        var fix = control is PictureControl.Exposure or PictureControl.Temperature or PictureControl.Tint;
        var next = control switch
        {
            PictureControl.Exposure => before with { Exposure = value }, PictureControl.Temperature => before with { Temperature = value },
            PictureControl.Tint => before with { Tint = value }, PictureControl.Highlights => before with { Highlights = value },
            PictureControl.Shadows => before with { Shadows = value }, PictureControl.Vibrance => before with { Vibrance = value },
            PictureControl.Fade => before with { Fade = value }, PictureControl.Vignette => before with { Vignette = value },
            _ => before with { Grain = value },
        };
        return controls with { ColorGrade = fix ? next : next with { Preset = next.Preset ?? Origin?.Id } };
    }

    /// <summary>Sets one slider as one "Change {name}" step; false when it is disabled or already there.</summary>
    public bool SetValue(PictureControl control, int value)
    {
        if (Reason(control) is not null || Controls is not { } controls) return false;
        var label = Table.Single(row => row.Control == control).Label;
        var clamped = Math.Clamp(value, Minimum(control), 100);
        if (!Commit(With(controls, control, clamped), "Change " + label.ToLowerInvariant())) return false;
        Announce(label + " " + Spoken(control, clamped));
        return true;
    }

    /// <summary>Double-click or Delete: the slider back to the look's value, or 0 without a preset origin.</summary>
    public bool ResetValue(PictureControl control) => SetValue(control, LookValue(control));

    /// <summary>A group's Reset: "Reset fix" (to 0) or the group back to the look's values.</summary>
    public bool ResetGroup(PictureGroupId id)
    {
        var group = Groups.Single(item => item.Id == id);
        if (group.ResetReason is not null || Controls is not { } controls) return false;
        var next = group.Sliders.Aggregate(controls, (current, slider) => With(current, slider.Control, slider.LookValue));
        if (!Commit(next, group.ResetName)) return false;
        Announce(group.ResetName);
        return true;
    }

    /// <summary>"+0.40 EV", "+20", "−15", "0", and the effects' unsigned "20".</summary>
    public static string ValueText(PictureControl control, int value)
    {
        if (control == PictureControl.Exposure)
            return (value > 0 ? "+" : value < 0 ? Minus : "") + (Math.Abs(value) / 50.0).ToString("0.00", CultureInfo.InvariantCulture) + " EV";
        var digits = Math.Abs(value).ToString(CultureInfo.InvariantCulture);
        return Minimum(control) == 0 || value == 0 ? digits : (value > 0 ? "+" : Minus) + digits;
    }

    /// <summary>"plus 20", "minus 15", "0"; exposure in EV ("plus 0.4").</summary>
    public static string Spoken(PictureControl control, int value)
    {
        var magnitude = control == PictureControl.Exposure
            ? (Math.Abs(value) / 50.0).ToString("0.##", CultureInfo.InvariantCulture) : Math.Abs(value).ToString(CultureInfo.InvariantCulture);
        return value > 0 && Minimum(control) < 0 ? "plus " + magnitude : value < 0 ? "minus " + magnitude : magnitude;
    }

    /// <summary>A typed value ("+20", "−15", "+0.40 EV" for exposure); null when it isn't a number.</summary>
    public static int? Parse(PictureControl control, string text)
    {
        var clean = text.Replace(Minus, "-", StringComparison.Ordinal).Replace("EV", "", StringComparison.OrdinalIgnoreCase).Trim();
        if (!double.TryParse(clean, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) || !double.IsFinite(number)) return null;
        var points = control == PictureControl.Exposure ? number * 50 : number;
        return (int)Math.Clamp(Math.Round(points, MidpointRounding.AwayFromZero), Minimum(control), 100);
    }

    // MARK: Toning, Back to, Clear

    /// <summary>"Toning from Warm Print" (or "Toning") while the grade has a curve or split tone; null otherwise.</summary>
    public string? ToningText => Controls?.ColorGrade is { } grade && (grade.Curve is not null || grade.SplitTone is not null)
        ? Origin is { } look ? "Toning from " + look.Label : "Toning" : null;

    /// <summary>Clears the curve and split tone as "Remove toning".</summary>
    public bool RemoveToning()
    {
        if (Blocked is not null || ToningText is null || Controls is not { ColorGrade: { } grade } controls) return false;
        return Commit(controls with { ColorGrade = grade with { Curve = null, SplitTone = null, Preset = grade.Preset ?? Origin?.Id } }, "Remove toning");
    }

    /// <summary>"Back to Warm Print" when the clip's look has a preset origin; null hides it.</summary>
    public string? BackToLabel => Origin is { } look ? "Back to " + look.Label : null;

    /// <summary>"Matches Warm Print" while nothing differs from it.</summary>
    public string? BackToReason => Blocked ?? (Origin is { } look && Match is { Edited: false } ? "Matches " + look.Label : null);

    /// <summary>Every value but the Fix back to the preset, Amount kept, as "Back to {look}".</summary>
    public bool BackTo()
    {
        if (BackToReason is not null || Origin is not { } look || Controls is not { } controls) return false;
        return Commit(controls.WithLook(look, AmountOf(controls)), "Back to " + look.Label);
    }

    /// <summary>Why Clear all color can't run.</summary>
    public string? ClearReason => Blocked ?? (Controls is { } controls && ColourNeutral(controls) ? "Nothing to clear" : null);

    /// <summary>As filmed with no adjustments or grade, the Fix included, as "Clear color".</summary>
    public bool Clear()
    {
        if (ClearReason is not null || Controls is not { } controls) return false;
        if (!Commit(new ClipColorState().Applied(controls), "Clear color")) return false;
        Announce("Look As filmed");
        return true;
    }

    // MARK: Auto

    /// <summary>Measures the open clip's Fix once per clip (free, on this PC); the panel calls it when it shows.</summary>
    public void Opened()
    {
        if (ClipId is not { } clip || Blocked is not null || measured.ContainsKey(clip) || !measuring.Add(clip)) return;
        var measure = services?.Measure ?? editor.MeasurePictureFixAsync;
        Measuring = Run();
        Notify();

        async Task Run()
        {
            ClipColorFix? fix = null;
            try { fix = await measure(clip, CancellationToken.None).ConfigureAwait(true); }
            catch (Exception exception) when (exception is not OutOfMemoryException) { fix = null; }
            measuring.Remove(clip);
            measured[clip] = fix;
            Notify();
        }
    }

    /// <summary>Why Auto can't run (looks spec §10); null when it can.</summary>
    public string? AutoReason
    {
        get
        {
            if (Blocked is { } blocked) return blocked;
            if (ClipId is not { } clip || !measured.TryGetValue(clip, out var fix)) return "Measuring the picture…";
            if (fix is not { } value) return "VoxClip couldn't read this video's frames";
            if (value.IsNeutral) return "The light and color already look even";
            return Controls?.ColorGrade?.Fix == value ? "Fix matches the measurement" : null;
        }
    }

    /// <summary>Sets Exposure, Temperature and Tint from the measurement as "Fix light and color".</summary>
    public bool Auto()
    {
        if (AutoReason is not null || Controls is not { } controls || measured[ClipId!] is not { } fix) return false;
        var grade = (controls.ColorGrade ?? ClipColorGrade.Neutral).WithFix(fix);
        if (!Commit(controls with { ColorGrade = grade }, "Fix light and color")) return false;
        Announce("Fix light and color: " + SpokenFix(fix));
        return true;
    }

    /// <summary>"exposure plus 0.4, temperature minus 18".</summary>
    public static string SpokenFix(ClipColorFix fix) => string.Join(", ", new[]
    {
        (PictureControl.Exposure, fix.Exposure), (PictureControl.Temperature, fix.Temperature), (PictureControl.Tint, fix.Tint),
    }.Where(item => item.Item2 != 0).Select(item => item.Item1.ToString().ToLowerInvariant() + " " + Spoken(item.Item1, item.Item2)));

    // MARK: Claude

    /// <summary>Claude's look for the open clip this session.</summary>
    public PictureClaudePick? Pick => ClipId is { } clip ? picks.GetValueOrDefault(clip) : null;

    /// <summary>Make it postable chose a look for <paramref name="clipId"/>.</summary>
    public void NoteClaudePick(string clipId, PictureClaudePick pick)
    {
        picks[clipId] = pick;
        Notify();
    }

    /// <summary>"Claude chose Warm Print · 70%" with the reason (and the Fix it applied) while it holds; after a hand change
    /// "Claude's pick: Warm Print · 70%" with Use it. Null without a pick.</summary>
    public PictureClaudeLine? ClaudeLine
    {
        get
        {
            if (Pick is not { } pick || Looks?.Look(pick.LookId) is not { } look || Controls is not { } controls) return null;
            var amount = look.Id == Original ? 100 : pick.Amount;
            var name = amount < 100 ? look.Label + " · " + amount.ToString(CultureInfo.InvariantCulture) + "%" : look.Label;
            var holds = Match is { Edited: false } match && match.Look.Id == look.Id && AmountOf(controls) == amount;
            if (!holds) return new("Claude's pick: " + name, pick.Reason, Blocked is null);
            var fix = pick.Fix is { } applied && applied.Summary() is { Length: > 0 } summary ? "Fix: " + summary : null;
            return new("Claude chose " + name, string.Join(" · ", new[] { pick.Reason, fix }.Where(text => !string.IsNullOrEmpty(text))), false);
        }
    }

    /// <summary>Use it: Claude's look, amount and Fix again, as "Use Claude's look".</summary>
    public bool UseClaudeLook()
    {
        if (ClaudeLine is not { CanUse: true } || Pick is not { } pick || ClipId is not { } clip || Looks is not { } looks) return false;
        Project next;
        try { next = ClipControlsProject.SettingLookPreset(pick.LookId, pick.Amount, pick.Fix, clip, editor.Project, looks); }
        catch (VoxClipException) { return false; }
        if (!editor.ReplaceProject(next, "Use Claude's look")) return false;
        EndPreview();
        Announce("Look " + looks.Look(pick.LookId)!.Label);
        return true;
    }

    // MARK: Timed looks

    /// <summary>Ask Claude's timed looks over the open clip.</summary>
    public IReadOnlyList<PictureTimedLook> TimedLooks
    {
        get
        {
            if (ClipId is not { } clip) return [];
            IReadOnlyList<ClipEffect> effects;
            try { effects = ClipEffects.Rendered(editor.Project, clip); }
            catch (VoxClipException) { return []; }
            return effects.Where(effect => effect.Kind == "colourLook" && (effect.ClipId is null || effect.ClipId == clip)).Select(effect =>
            {
                var label = Looks?.Look(effect.Look ?? "")?.Label ?? "look";
                return new PictureTimedLook(effect.Id, $"A timed {label} from Ask Claude replaces this look at {editor.MakeItClipTime(effect.Start, clip)}–{editor.MakeItClipTime(effect.End, clip)}",
                    effect.Start);
            }).ToArray();
        }
    }

    /// <summary>▶ on a timed look.</summary>
    public void PlayTimedLook(PictureTimedLook timed) => PlayRequested?.Invoke(this, timed.Start);

    /// <summary>Removes a timed look as "Remove timed look".</summary>
    public bool RemoveTimedLook(PictureTimedLook timed) =>
        Blocked is null && ClipPicture.RemovingEffect(timed.Id, editor.Project) is { } next && editor.ReplaceProject(next, "Remove timed look");

    // MARK: Steps

    private bool Commit(ProjectClipControls next, string name)
    {
        if (next.ColorGrade is { IsNeutral: true }) next = next with { ColorGrade = null };
        if (Controls is not { } controls || ClipColorState.Of(next) == ClipColorState.Of(controls)) return false;
        Project project;
        try { project = ClipControlsProject.Setting(next, editor.Project); }
        catch (VoxClipException) { return false; }
        if (!editor.ReplaceProject(project, name)) return false;
        if (!Comparing) Show(null, false);
        return true;
    }

    private void Announce(string text) => Announced?.Invoke(this, text);

    private void Notify() => Changed?.Invoke(this, EventArgs.Empty);
}
