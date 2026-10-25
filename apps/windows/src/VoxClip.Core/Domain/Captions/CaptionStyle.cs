using System.Text.Json;
using System.Text.Json.Serialization;

namespace VoxClip.Core.Domain.Captions;

/// <summary>CaptionFont model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionFont
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionFont(
        string file = "",
        string family = "",
        int weight = default,
        bool italic = false,
        double sizeSh = default,
        CaptionFontSizeRefValue sizeRef = CaptionFontSizeRefValue.ShortEdge,
        double sizeScale = 1,
        double letterSpacingEm = 0,
        double? wordSpacingEm = null,
        double lineHeightEm = 1.2,
        CaptionFontFeatures? features = null,
        IReadOnlyList<string>? fallbackFiles = null)
    {
        File = file;
        Family = family;
        Weight = weight;
        Italic = italic;
        SizeSh = sizeSh;
        SizeRef = sizeRef;
        SizeScale = sizeScale;
        LetterSpacingEm = letterSpacingEm;
        WordSpacingEm = wordSpacingEm;
        LineHeightEm = lineHeightEm;
        Features = features ?? new();
        FallbackFiles = fallbackFiles ?? [];
    }

    /// <summary>file; captions §2.</summary>
    [JsonPropertyName("file")]
    [JsonRequired]
    public string File { get; init; } = string.Empty;

    /// <summary>Informational; must equal the manifest family of &#x27;file&#x27;.</summary>
    [JsonPropertyName("family")]
    [JsonRequired]
    public string Family { get; init; } = string.Empty;

    /// <summary>Informational; must equal the manifest nominal weight of &#x27;file&#x27;.</summary>
    [JsonPropertyName("weight")]
    [JsonRequired]
    public int Weight { get; init; }

    /// <summary>Informational; must equal the manifest value.</summary>
    [JsonPropertyName("italic")]
    public bool Italic { get; init; } = false;

    /// <summary>Font size as a fraction of the reference length (sizeRef).</summary>
    [JsonPropertyName("sizeSh")]
    [JsonRequired]
    public double SizeSh { get; init; }

    /// <summary>sizeRef; captions §2.</summary>
    [JsonPropertyName("sizeRef")]
    public CaptionFontSizeRefValue SizeRef { get; init; } = CaptionFontSizeRefValue.ShortEdge;

    /// <summary>Multiplier on sizeSh. Built-in styles leave it at 1; the Size control writes it through the project&#x27;s overrides patch.</summary>
    [JsonPropertyName("sizeScale")]
    public double SizeScale { get; init; } = 1;

    /// <summary>letterSpacingEm; captions §2.</summary>
    [JsonPropertyName("letterSpacingEm")]
    public double LetterSpacingEm { get; init; } = 0;

    /// <summary>Gap between words in em. When absent the gap is the font&#x27;s space advance plus letter spacing.</summary>
    [JsonPropertyName("wordSpacingEm")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? WordSpacingEm { get; init; }

    /// <summary>lineHeightEm; captions §2.</summary>
    [JsonPropertyName("lineHeightEm")]
    public double LineHeightEm { get; init; } = 1.2;

    /// <summary>features; captions §2.</summary>
    [JsonPropertyName("features")]
    public CaptionFontFeatures Features { get; init; } = new();

    /// <summary>Tried in order after the primary file and before Noto Sans.</summary>
    [JsonPropertyName("fallbackFiles")]
    public IReadOnlyList<string> FallbackFiles { get; init; } = [];

}

/// <summary>CaptionText model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionText
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionText(
        CaptionTextTransformValue transform = CaptionTextTransformValue.None,
        CaptionTextPunctuationValue punctuation = CaptionTextPunctuationValue.Keep,
        bool userOverridable = true)
    {
        Transform = transform;
        Punctuation = punctuation;
        UserOverridable = userOverridable;
    }

    /// <summary>transform; captions §2.</summary>
    [JsonPropertyName("transform")]
    public CaptionTextTransformValue Transform { get; init; } = CaptionTextTransformValue.None;

    /// <summary>punctuation; captions §2.</summary>
    [JsonPropertyName("punctuation")]
    public CaptionTextPunctuationValue Punctuation { get; init; } = CaptionTextPunctuationValue.Keep;

    /// <summary>Whether the user may change transform and punctuation.</summary>
    [JsonPropertyName("userOverridable")]
    public bool UserOverridable { get; init; } = true;

}

/// <summary>CaptionLayout model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionLayout
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionLayout(
        int maxWords = default,
        int maxLines = default,
        double maxLineWidthW = default,
        CaptionLayoutBalanceValue balance = CaptionLayoutBalanceValue.Balanced,
        double minShrink = 0.5,
        bool breakOnSentence = true,
        bool breakOnComma = false,
        double? breakOnGapSec = 0.6,
        double? maxPageSec = null,
        double holdGapSec = 0.5,
        double minPageSec = 0.3,
        CaptionLayoutAlignValue align = CaptionLayoutAlignValue.Center,
        double lineGapEm = 0)
    {
        MaxWords = maxWords;
        MaxLines = maxLines;
        MaxLineWidthW = maxLineWidthW;
        Balance = balance;
        MinShrink = minShrink;
        BreakOnSentence = breakOnSentence;
        BreakOnComma = breakOnComma;
        BreakOnGapSec = breakOnGapSec;
        MaxPageSec = maxPageSec;
        HoldGapSec = holdGapSec;
        MinPageSec = minPageSec;
        Align = align;
        LineGapEm = lineGapEm;
    }

    /// <summary>maxWords; captions §2.</summary>
    [JsonPropertyName("maxWords")]
    [JsonRequired]
    public int MaxWords { get; init; }

    /// <summary>maxLines; captions §2.</summary>
    [JsonPropertyName("maxLines")]
    [JsonRequired]
    public int MaxLines { get; init; }

    /// <summary>Maximum line advance width as a fraction of the frame width (further limited by the safe area).</summary>
    [JsonPropertyName("maxLineWidthW")]
    [JsonRequired]
    public double MaxLineWidthW { get; init; }

    /// <summary>balance; captions §2.</summary>
    [JsonPropertyName("balance")]
    public CaptionLayoutBalanceValue Balance { get; init; } = CaptionLayoutBalanceValue.Balanced;

    /// <summary>minShrink; captions §2.</summary>
    [JsonPropertyName("minShrink")]
    public double MinShrink { get; init; } = 0.5;

    /// <summary>breakOnSentence; captions §2.</summary>
    [JsonPropertyName("breakOnSentence")]
    public bool BreakOnSentence { get; init; } = true;

    /// <summary>breakOnComma; captions §2.</summary>
    [JsonPropertyName("breakOnComma")]
    public bool BreakOnComma { get; init; } = false;

    /// <summary>null disables gap breaks.</summary>
    [JsonPropertyName("breakOnGapSec")]
    public double? BreakOnGapSec { get; init; } = 0.6;

    /// <summary>null means no limit.</summary>
    [JsonPropertyName("maxPageSec")]
    public double? MaxPageSec { get; init; }

    /// <summary>holdGapSec; captions §2.</summary>
    [JsonPropertyName("holdGapSec")]
    public double HoldGapSec { get; init; } = 0.5;

    /// <summary>minPageSec; captions §2.</summary>
    [JsonPropertyName("minPageSec")]
    public double MinPageSec { get; init; } = 0.3;

    /// <summary>align; captions §2.</summary>
    [JsonPropertyName("align")]
    public CaptionLayoutAlignValue Align { get; init; } = CaptionLayoutAlignValue.Center;

    /// <summary>Extra space between line boxes.</summary>
    [JsonPropertyName("lineGapEm")]
    public double LineGapEm { get; init; } = 0;

}

/// <summary>CaptionStylePosition model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionStylePosition
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionStylePosition(
        double x = default,
        double y = default,
        CaptionStylePositionAnchorXValue anchorX = CaptionStylePositionAnchorXValue.Center,
        CaptionStylePositionAnchorYValue anchorY = CaptionStylePositionAnchorYValue.Center,
        bool userDraggable = true)
    {
        X = x;
        Y = y;
        AnchorX = anchorX;
        AnchorY = anchorY;
        UserDraggable = userDraggable;
    }

    /// <summary>x; captions §2.</summary>
    [JsonPropertyName("x")]
    [JsonRequired]
    public double X { get; init; }

    /// <summary>y; captions §2.</summary>
    [JsonPropertyName("y")]
    [JsonRequired]
    public double Y { get; init; }

    /// <summary>anchorX; captions §2.</summary>
    [JsonPropertyName("anchorX")]
    public CaptionStylePositionAnchorXValue AnchorX { get; init; } = CaptionStylePositionAnchorXValue.Center;

    /// <summary>anchorY; captions §2.</summary>
    [JsonPropertyName("anchorY")]
    public CaptionStylePositionAnchorYValue AnchorY { get; init; } = CaptionStylePositionAnchorYValue.Center;

    /// <summary>userDraggable; captions §2.</summary>
    [JsonPropertyName("userDraggable")]
    public bool UserDraggable { get; init; } = true;

}

/// <summary>CaptionAspectOverride model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionAspectOverride
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionAspectOverride(
        double? sizeSh = null,
        double? x = null,
        double? y = null,
        double? maxLineWidthW = null,
        int? maxWords = null)
    {
        SizeSh = sizeSh;
        X = x;
        Y = y;
        MaxLineWidthW = maxLineWidthW;
        MaxWords = maxWords;
    }

    /// <summary>sizeSh; captions §2.</summary>
    [JsonPropertyName("sizeSh")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? SizeSh { get; init; }

    /// <summary>x; captions §2.</summary>
    [JsonPropertyName("x")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? X { get; init; }

    /// <summary>y; captions §2.</summary>
    [JsonPropertyName("y")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Y { get; init; }

    /// <summary>maxLineWidthW; captions §2.</summary>
    [JsonPropertyName("maxLineWidthW")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? MaxLineWidthW { get; init; }

    /// <summary>maxWords; captions §2.</summary>
    [JsonPropertyName("maxWords")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? MaxWords { get; init; }

}

/// <summary>CaptionAspects model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionAspects
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionAspects(
        CaptionAspectOverride? portrait = null,
        CaptionAspectOverride? square = null,
        CaptionAspectOverride? landscape = null)
    {
        Portrait = portrait;
        Square = square;
        Landscape = landscape;
    }

    /// <summary>portrait; captions §2.</summary>
    [JsonPropertyName("portrait")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionAspectOverride? Portrait { get; init; }

    /// <summary>square; captions §2.</summary>
    [JsonPropertyName("square")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionAspectOverride? Square { get; init; }

    /// <summary>landscape; captions §2.</summary>
    [JsonPropertyName("landscape")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionAspectOverride? Landscape { get; init; }

}

/// <summary>CaptionStroke model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionStroke
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionStroke(
        double widthEm = default,
        string color = "")
    {
        WidthEm = widthEm;
        Color = color;
    }

    /// <summary>Full stroke line width (SVG stroke-width), centred on the outline and drawn under the fill, so widthEm/2 shows outside the glyph.</summary>
    [JsonPropertyName("widthEm")]
    [JsonRequired]
    public double WidthEm { get; init; }

    /// <summary>color; captions §2.</summary>
    [JsonPropertyName("color")]
    [JsonRequired]
    public string Color { get; init; } = string.Empty;

}

/// <summary>CaptionShadow model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionShadow
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionShadow(
        double dxEm = default,
        double dyEm = default,
        double sigmaEm = default,
        string color = "")
    {
        DxEm = dxEm;
        DyEm = dyEm;
        SigmaEm = sigmaEm;
        Color = color;
    }

    /// <summary>dxEm; captions §2.</summary>
    [JsonPropertyName("dxEm")]
    [JsonRequired]
    public double DxEm { get; init; }

    /// <summary>dyEm; captions §2.</summary>
    [JsonPropertyName("dyEm")]
    [JsonRequired]
    public double DyEm { get; init; }

    /// <summary>Gaussian standard deviation in em; 0 is a hard shadow.</summary>
    [JsonPropertyName("sigmaEm")]
    [JsonRequired]
    public double SigmaEm { get; init; }

    /// <summary>color; captions §2.</summary>
    [JsonPropertyName("color")]
    [JsonRequired]
    public string Color { get; init; } = string.Empty;

}

/// <summary>CaptionBoxShape model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionBoxShape
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionBoxShape(
        double paddingXEm = 0.4,
        double paddingYEm = 0.15,
        double radiusEm = 0.2,
        bool pill = false,
        double borderWidthEm = 0)
    {
        PaddingXEm = paddingXEm;
        PaddingYEm = paddingYEm;
        RadiusEm = radiusEm;
        Pill = pill;
        BorderWidthEm = borderWidthEm;
    }

    /// <summary>paddingXEm; captions §2.</summary>
    [JsonPropertyName("paddingXEm")]
    public double PaddingXEm { get; init; } = 0.4;

    /// <summary>paddingYEm; captions §2.</summary>
    [JsonPropertyName("paddingYEm")]
    public double PaddingYEm { get; init; } = 0.15;

    /// <summary>radiusEm; captions §2.</summary>
    [JsonPropertyName("radiusEm")]
    public double RadiusEm { get; init; } = 0.2;

    /// <summary>pill; captions §2.</summary>
    [JsonPropertyName("pill")]
    public bool Pill { get; init; } = false;

    /// <summary>borderWidthEm; captions §2.</summary>
    [JsonPropertyName("borderWidthEm")]
    public double BorderWidthEm { get; init; } = 0;

}

/// <summary>CaptionBox model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionBox
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionBox(
        CaptionBoxScopeValue scope = default,
        string color = "",
        double paddingXEm = 0.4,
        double paddingYEm = 0.15,
        double radiusEm = 0.2,
        bool pill = false,
        double borderWidthEm = 0,
        string? borderColor = null)
    {
        Scope = scope;
        Color = color;
        PaddingXEm = paddingXEm;
        PaddingYEm = paddingYEm;
        RadiusEm = radiusEm;
        Pill = pill;
        BorderWidthEm = borderWidthEm;
        BorderColor = borderColor;
    }

    /// <summary>scope; captions §2.</summary>
    [JsonPropertyName("scope")]
    [JsonRequired]
    public CaptionBoxScopeValue Scope { get; init; }

    /// <summary>color; captions §2.</summary>
    [JsonPropertyName("color")]
    [JsonRequired]
    public string Color { get; init; } = string.Empty;

    /// <summary>paddingXEm; captions §2.</summary>
    [JsonPropertyName("paddingXEm")]
    public double PaddingXEm { get; init; } = 0.4;

    /// <summary>paddingYEm; captions §2.</summary>
    [JsonPropertyName("paddingYEm")]
    public double PaddingYEm { get; init; } = 0.15;

    /// <summary>radiusEm; captions §2.</summary>
    [JsonPropertyName("radiusEm")]
    public double RadiusEm { get; init; } = 0.2;

    /// <summary>pill; captions §2.</summary>
    [JsonPropertyName("pill")]
    public bool Pill { get; init; } = false;

    /// <summary>borderWidthEm; captions §2.</summary>
    [JsonPropertyName("borderWidthEm")]
    public double BorderWidthEm { get; init; } = 0;

    /// <summary>borderColor; captions §2.</summary>
    [JsonPropertyName("borderColor")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BorderColor { get; init; }

}

/// <summary>CaptionWordBox model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionWordBox
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionWordBox(
        string color = "",
        double paddingXEm = 0.4,
        double paddingYEm = 0.15,
        double radiusEm = 0.2,
        bool pill = false,
        double borderWidthEm = 0,
        string? borderColor = null)
    {
        Color = color;
        PaddingXEm = paddingXEm;
        PaddingYEm = paddingYEm;
        RadiusEm = radiusEm;
        Pill = pill;
        BorderWidthEm = borderWidthEm;
        BorderColor = borderColor;
    }

    /// <summary>color; captions §2.</summary>
    [JsonPropertyName("color")]
    [JsonRequired]
    public string Color { get; init; } = string.Empty;

    /// <summary>paddingXEm; captions §2.</summary>
    [JsonPropertyName("paddingXEm")]
    public double PaddingXEm { get; init; } = 0.4;

    /// <summary>paddingYEm; captions §2.</summary>
    [JsonPropertyName("paddingYEm")]
    public double PaddingYEm { get; init; } = 0.15;

    /// <summary>radiusEm; captions §2.</summary>
    [JsonPropertyName("radiusEm")]
    public double RadiusEm { get; init; } = 0.2;

    /// <summary>pill; captions §2.</summary>
    [JsonPropertyName("pill")]
    public bool Pill { get; init; } = false;

    /// <summary>borderWidthEm; captions §2.</summary>
    [JsonPropertyName("borderWidthEm")]
    public double BorderWidthEm { get; init; } = 0;

    /// <summary>borderColor; captions §2.</summary>
    [JsonPropertyName("borderColor")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BorderColor { get; init; }

}

/// <summary>CaptionWordState model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionWordState
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionWordState(
        CaptionPaint? fill = null,
        double? opacity = null,
        double? scale = null,
        string? strokeColor = null,
        bool? hideStroke = null,
        CaptionWordBox? box = null)
    {
        Fill = fill;
        Opacity = opacity;
        Scale = scale;
        StrokeColor = strokeColor;
        HideStroke = hideStroke;
        Box = box;
    }

    /// <summary>fill; captions §2.</summary>
    [JsonPropertyName("fill")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionPaint? Fill { get; init; }

    /// <summary>opacity; captions §2.</summary>
    [JsonPropertyName("opacity")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Opacity { get; init; }

    /// <summary>Drawn about the word centre; never changes layout.</summary>
    [JsonPropertyName("scale")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Scale { get; init; }

    /// <summary>strokeColor; captions §2.</summary>
    [JsonPropertyName("strokeColor")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? StrokeColor { get; init; }

    /// <summary>hideStroke; captions §2.</summary>
    [JsonPropertyName("hideStroke")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? HideStroke { get; init; }

    /// <summary>box; captions §2.</summary>
    [JsonPropertyName("box")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionWordBox? Box { get; init; }

}

/// <summary>CaptionWordStates model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionWordStates
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionWordStates(
        CaptionWordState? past = null,
        CaptionWordState? active = null,
        CaptionWordState? future = null)
    {
        Past = past;
        Active = active;
        Future = future;
    }

    /// <summary>past; captions §2.</summary>
    [JsonPropertyName("past")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionWordState? Past { get; init; }

    /// <summary>active; captions §2.</summary>
    [JsonPropertyName("active")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionWordState? Active { get; init; }

    /// <summary>future; captions §2.</summary>
    [JsonPropertyName("future")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionWordState? Future { get; init; }

}

/// <summary>CaptionReveal model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionReveal
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionReveal(
        CaptionRevealUnitValue unit = CaptionRevealUnitValue.Page,
        double maxCharsPerSec = 30,
        CaptionRevealCursor? cursor = null)
    {
        Unit = unit;
        MaxCharsPerSec = maxCharsPerSec;
        Cursor = cursor;
    }

    /// <summary>unit; captions §2.</summary>
    [JsonPropertyName("unit")]
    public CaptionRevealUnitValue Unit { get; init; } = CaptionRevealUnitValue.Page;

    /// <summary>maxCharsPerSec; captions §2.</summary>
    [JsonPropertyName("maxCharsPerSec")]
    public double MaxCharsPerSec { get; init; } = 30;

    /// <summary>cursor; captions §2.</summary>
    [JsonPropertyName("cursor")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionRevealCursor? Cursor { get; init; }

}

/// <summary>CaptionAnimationSpec model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionAnimationSpec
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionAnimationSpec(
        CaptionAnimationSpecTypeValue type = default,
        double durationSec = default,
        CaptionAnimationSpecEasingValue easing = CaptionAnimationSpecEasingValue.EaseOutCubic,
        double fromScale = 0.8,
        double fromOffsetEm = 0.4,
        double overshoot = 1.70158)
    {
        Type = type;
        DurationSec = durationSec;
        Easing = easing;
        FromScale = fromScale;
        FromOffsetEm = fromOffsetEm;
        Overshoot = overshoot;
    }

    /// <summary>type; captions §2.</summary>
    [JsonPropertyName("type")]
    [JsonRequired]
    public CaptionAnimationSpecTypeValue Type { get; init; }

    /// <summary>durationSec; captions §2.</summary>
    [JsonPropertyName("durationSec")]
    [JsonRequired]
    public double DurationSec { get; init; }

    /// <summary>easing; captions §2.</summary>
    [JsonPropertyName("easing")]
    public CaptionAnimationSpecEasingValue Easing { get; init; } = CaptionAnimationSpecEasingValue.EaseOutCubic;

    /// <summary>fromScale; captions §2.</summary>
    [JsonPropertyName("fromScale")]
    public double FromScale { get; init; } = 0.8;

    /// <summary>fromOffsetEm; captions §2.</summary>
    [JsonPropertyName("fromOffsetEm")]
    public double FromOffsetEm { get; init; } = 0.4;

    /// <summary>overshoot; captions §2.</summary>
    [JsonPropertyName("overshoot")]
    public double Overshoot { get; init; } = 1.70158;

}

/// <summary>CaptionAnimation model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionAnimation
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionAnimation(
        CaptionAnimationSpec? pageIn = null,
        CaptionAnimationSpec? pageOut = null,
        CaptionAnimationSpec? wordIn = null,
        CaptionAnimationSpec? activeIn = null)
    {
        PageIn = pageIn;
        PageOut = pageOut;
        WordIn = wordIn;
        ActiveIn = activeIn;
    }

    /// <summary>pageIn; captions §2.</summary>
    [JsonPropertyName("pageIn")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionAnimationSpec? PageIn { get; init; }

    /// <summary>pageOut; captions §2.</summary>
    [JsonPropertyName("pageOut")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionAnimationSpec? PageOut { get; init; }

    /// <summary>wordIn; captions §2.</summary>
    [JsonPropertyName("wordIn")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionAnimationSpec? WordIn { get; init; }

    /// <summary>activeIn; captions §2.</summary>
    [JsonPropertyName("activeIn")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionAnimationSpec? ActiveIn { get; init; }

}

/// <summary>CaptionEmphasis model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionEmphasis
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionEmphasis(
        CaptionEmphasisSourceValue source = CaptionEmphasisSourceValue.None,
        int maxPerPage = 1,
        double minScore = 0,
        CaptionPaint? fill = null,
        IReadOnlyList<string>? palette = null,
        string? fontFile = null,
        double scale = 1)
    {
        Source = source;
        MaxPerPage = maxPerPage;
        MinScore = minScore;
        Fill = fill;
        Palette = palette;
        FontFile = fontFile;
        Scale = scale;
    }

    /// <summary>v1 apps treat &#x27;llm&#x27; as &#x27;rule&#x27;.</summary>
    [JsonPropertyName("source")]
    public CaptionEmphasisSourceValue Source { get; init; } = CaptionEmphasisSourceValue.None;

    /// <summary>maxPerPage; captions §2.</summary>
    [JsonPropertyName("maxPerPage")]
    public int MaxPerPage { get; init; } = 1;

    /// <summary>minScore; captions §2.</summary>
    [JsonPropertyName("minScore")]
    public double MinScore { get; init; } = 0;

    /// <summary>fill; captions §2.</summary>
    [JsonPropertyName("fill")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionPaint? Fill { get; init; }

    /// <summary>Cycled over emphasised words in caption order; overrides fill.</summary>
    [JsonPropertyName("palette")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<string>? Palette { get; init; }

    /// <summary>fontFile; captions §2.</summary>
    [JsonPropertyName("fontFile")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? FontFile { get; init; }

    /// <summary>Changes layout width and drawing size.</summary>
    [JsonPropertyName("scale")]
    public double Scale { get; init; } = 1;

}

/// <summary>CaptionEmoji model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionEmoji
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionEmoji(
        bool enabled = false,
        CaptionEmojiSourceValue source = CaptionEmojiSourceValue.Rule,
        string placement = "above-page",
        double sizeEm = 1.2,
        double gapEm = 0.15,
        int maxPerPage = 1)
    {
        Enabled = enabled;
        Source = source;
        Placement = placement;
        SizeEm = sizeEm;
        GapEm = gapEm;
        MaxPerPage = maxPerPage;
    }

    /// <summary>enabled; captions §2.</summary>
    [JsonPropertyName("enabled")]
    public bool Enabled { get; init; } = false;

    /// <summary>Manual picks always apply; v1 apps treat &#x27;llm&#x27; as &#x27;rule&#x27;.</summary>
    [JsonPropertyName("source")]
    public CaptionEmojiSourceValue Source { get; init; } = CaptionEmojiSourceValue.Rule;

    /// <summary>placement; captions §2.</summary>
    [JsonPropertyName("placement")]
    public string Placement { get; init; } = "above-page";

    /// <summary>sizeEm; captions §2.</summary>
    [JsonPropertyName("sizeEm")]
    public double SizeEm { get; init; } = 1.2;

    /// <summary>gapEm; captions §2.</summary>
    [JsonPropertyName("gapEm")]
    public double GapEm { get; init; } = 0.15;

    /// <summary>maxPerPage; captions §2.</summary>
    [JsonPropertyName("maxPerPage")]
    public int MaxPerPage { get; init; } = 1;

}

/// <summary>CaptionEffects model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionEffects
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionEffects(
        CaptionEffectsRgbSplit? rgbSplit = null,
        CaptionEffectsJitter? jitter = null)
    {
        RgbSplit = rgbSplit;
        Jitter = jitter;
    }

    /// <summary>rgbSplit; captions §2.</summary>
    [JsonPropertyName("rgbSplit")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionEffectsRgbSplit? RgbSplit { get; init; }

    /// <summary>jitter; captions §2.</summary>
    [JsonPropertyName("jitter")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionEffectsJitter? Jitter { get; init; }

}

/// <summary>CaptionPreview model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionPreview
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionPreview(
        string text = "",
        int activeWord = 0,
        double progress = 1,
        string background = "#3A3C45")
    {
        Text = text;
        ActiveWord = activeWord;
        Progress = progress;
        Background = background;
    }

    /// <summary>Sample words (space separated) used when no transcript phrase is available.</summary>
    [JsonPropertyName("text")]
    [JsonRequired]
    public string Text { get; init; } = string.Empty;

    /// <summary>activeWord; captions §2.</summary>
    [JsonPropertyName("activeWord")]
    public int ActiveWord { get; init; } = 0;

    /// <summary>progress; captions §2.</summary>
    [JsonPropertyName("progress")]
    public double Progress { get; init; } = 1;

    /// <summary>background; captions §2.</summary>
    [JsonPropertyName("background")]
    public string Background { get; init; } = "#3A3C45";

}

/// <summary>A data-driven caption style. Semantics, defaults and the rendering algorithm are normative in doc/spec/captions.md. Every &#x27;default&#x27; below is part of the contract: a renderer must behave as if the default value were written in the file. A project stores a style id plus an RFC 7396 merge patch over this object (captions spec section 2.4).; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionStyle
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionStyle(
        string? schema = null,
        int schemaVersion = 1,
        string id = "",
        string name = "",
        string description = "",
        int order = 500,
        IReadOnlyList<string>? tags = null,
        string? accent = null,
        CaptionFont? font = null,
        CaptionText? text = null,
        CaptionLayout? layout = null,
        CaptionStylePosition? position = null,
        CaptionAspects? aspects = null,
        CaptionPaint? fill = null,
        CaptionStroke? stroke = null,
        IReadOnlyList<CaptionShadow>? shadows = null,
        CaptionBox? box = null,
        CaptionWordStates? words = null,
        CaptionReveal? reveal = null,
        CaptionAnimation? animation = null,
        CaptionEmphasis? emphasis = null,
        CaptionEmoji? emoji = null,
        CaptionEffects? effects = null,
        CaptionPreview? preview = null)
    {
        Schema = schema;
        SchemaVersion = schemaVersion;
        Id = id;
        Name = name;
        Description = description;
        Order = order;
        Tags = tags ?? [];
        Accent = accent;
        Font = font ?? new();
        Text = text ?? new();
        Layout = layout ?? new();
        Position = position ?? new();
        Aspects = aspects;
        Fill = fill ?? new SolidPaint("#FFFFFF");
        Stroke = stroke;
        Shadows = shadows ?? [];
        Box = box;
        Words = words;
        Reveal = reveal;
        Animation = animation;
        Emphasis = emphasis;
        Emoji = emoji;
        Effects = effects;
        Preview = preview ?? new();
    }

    /// <summary>$schema; captions §2.</summary>
    [JsonPropertyName("$schema")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Schema { get; init; }

    /// <summary>schemaVersion; captions §2.</summary>
    [JsonPropertyName("schemaVersion")]
    [JsonRequired]
    public int SchemaVersion { get; init; } = 1;

    /// <summary>Stable identifier. Equals the file name without .json. Stored in project files.</summary>
    [JsonPropertyName("id")]
    [JsonRequired]
    public string Id { get; init; } = string.Empty;

    /// <summary>Gallery tile label (sentence case).</summary>
    [JsonPropertyName("name")]
    [JsonRequired]
    public string Name { get; init; } = string.Empty;

    /// <summary>One sentence used as the accessibility label of the tile.</summary>
    [JsonPropertyName("description")]
    [JsonRequired]
    public string Description { get; init; } = string.Empty;

    /// <summary>Gallery order, ascending; ties by id.</summary>
    [JsonPropertyName("order")]
    public int Order { get; init; } = 500;

    /// <summary>tags; captions §2.</summary>
    [JsonPropertyName("tags")]
    public IReadOnlyList<string> Tags { get; init; } = [];

    /// <summary>Default value of the $accent colour token. The Colour control replaces it through the project overrides patch. Styles without an accent show no colour swatches.</summary>
    [JsonPropertyName("accent")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Accent { get; init; }

    /// <summary>font; captions §2.</summary>
    [JsonPropertyName("font")]
    [JsonRequired]
    public CaptionFont Font { get; init; } = new();

    /// <summary>text; captions §2.</summary>
    [JsonPropertyName("text")]
    [JsonRequired]
    public CaptionText Text { get; init; } = new();

    /// <summary>layout; captions §2.</summary>
    [JsonPropertyName("layout")]
    [JsonRequired]
    public CaptionLayout Layout { get; init; } = new();

    /// <summary>position; captions §2.</summary>
    [JsonPropertyName("position")]
    [JsonRequired]
    public CaptionStylePosition Position { get; init; } = new();

    /// <summary>aspects; captions §2.</summary>
    [JsonPropertyName("aspects")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionAspects? Aspects { get; init; }

    /// <summary>fill; captions §2.</summary>
    [JsonPropertyName("fill")]
    [JsonRequired]
    public CaptionPaint Fill { get; init; } = new SolidPaint("#FFFFFF");

    /// <summary>stroke; captions §2.</summary>
    [JsonPropertyName("stroke")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionStroke? Stroke { get; init; }

    /// <summary>shadows; captions §2.</summary>
    [JsonPropertyName("shadows")]
    public IReadOnlyList<CaptionShadow> Shadows { get; init; } = [];

    /// <summary>box; captions §2.</summary>
    [JsonPropertyName("box")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionBox? Box { get; init; }

    /// <summary>words; captions §2.</summary>
    [JsonPropertyName("words")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionWordStates? Words { get; init; }

    /// <summary>reveal; captions §2.</summary>
    [JsonPropertyName("reveal")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionReveal? Reveal { get; init; }

    /// <summary>animation; captions §2.</summary>
    [JsonPropertyName("animation")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionAnimation? Animation { get; init; }

    /// <summary>emphasis; captions §2.</summary>
    [JsonPropertyName("emphasis")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionEmphasis? Emphasis { get; init; }

    /// <summary>emoji; captions §2.</summary>
    [JsonPropertyName("emoji")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionEmoji? Emoji { get; init; }

    /// <summary>effects; captions §2.</summary>
    [JsonPropertyName("effects")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CaptionEffects? Effects { get; init; }

    /// <summary>preview; captions §2.</summary>
    [JsonPropertyName("preview")]
    [JsonRequired]
    public CaptionPreview Preview { get; init; } = new();

}

/// <summary>CaptionFontFeatures model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionFontFeatures
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionFontFeatures(
        bool kern = true,
        bool liga = true,
        bool calt = true)
    {
        Kern = kern;
        Liga = liga;
        Calt = calt;
    }

    /// <summary>kern; captions §2.</summary>
    [JsonPropertyName("kern")]
    public bool Kern { get; init; } = true;

    /// <summary>liga; captions §2.</summary>
    [JsonPropertyName("liga")]
    public bool Liga { get; init; } = true;

    /// <summary>calt; captions §2.</summary>
    [JsonPropertyName("calt")]
    public bool Calt { get; init; } = true;

}

/// <summary>CaptionRevealCursor model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionRevealCursor
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionRevealCursor(
        double widthEm = default,
        string color = "",
        double blinkHz = 2)
    {
        WidthEm = widthEm;
        Color = color;
        BlinkHz = blinkHz;
    }

    /// <summary>widthEm; captions §2.</summary>
    [JsonPropertyName("widthEm")]
    [JsonRequired]
    public double WidthEm { get; init; }

    /// <summary>color; captions §2.</summary>
    [JsonPropertyName("color")]
    [JsonRequired]
    public string Color { get; init; } = string.Empty;

    /// <summary>blinkHz; captions §2.</summary>
    [JsonPropertyName("blinkHz")]
    public double BlinkHz { get; init; } = 2;

}

/// <summary>CaptionEffectsRgbSplit model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionEffectsRgbSplit
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionEffectsRgbSplit(
        double offsetEm = default,
        string leftColor = "",
        string rightColor = "")
    {
        OffsetEm = offsetEm;
        LeftColor = leftColor;
        RightColor = rightColor;
    }

    /// <summary>offsetEm; captions §2.</summary>
    [JsonPropertyName("offsetEm")]
    [JsonRequired]
    public double OffsetEm { get; init; }

    /// <summary>leftColor; captions §2.</summary>
    [JsonPropertyName("leftColor")]
    [JsonRequired]
    public string LeftColor { get; init; } = string.Empty;

    /// <summary>rightColor; captions §2.</summary>
    [JsonPropertyName("rightColor")]
    [JsonRequired]
    public string RightColor { get; init; } = string.Empty;

}

/// <summary>CaptionEffectsJitter model; captions §2 and shared/caption-styles/schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record CaptionEffectsJitter
{
    /// <summary>Apply schema defaults explicitly before source-generated deserialization; captions §2.2.</summary>
    [JsonConstructor]
    public CaptionEffectsJitter(
        double amplitudeEm = default,
        double rateHz = default,
        long seed = default)
    {
        AmplitudeEm = amplitudeEm;
        RateHz = rateHz;
        Seed = seed;
    }

    /// <summary>amplitudeEm; captions §2.</summary>
    [JsonPropertyName("amplitudeEm")]
    [JsonRequired]
    public double AmplitudeEm { get; init; }

    /// <summary>rateHz; captions §2.</summary>
    [JsonPropertyName("rateHz")]
    [JsonRequired]
    public double RateHz { get; init; }

    /// <summary>seed; captions §2.</summary>
    [JsonPropertyName("seed")]
    [JsonRequired]
    public long Seed { get; init; }

}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionFontSizeRefValue>))]
public enum CaptionFontSizeRefValue
{
    /// <summary>shortEdge</summary>
    [JsonStringEnumMemberName("shortEdge")] ShortEdge,
    /// <summary>height</summary>
    [JsonStringEnumMemberName("height")] Height,
    /// <summary>width</summary>
    [JsonStringEnumMemberName("width")] Width,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionTextTransformValue>))]
public enum CaptionTextTransformValue
{
    /// <summary>none</summary>
    [JsonStringEnumMemberName("none")] None,
    /// <summary>uppercase</summary>
    [JsonStringEnumMemberName("uppercase")] Uppercase,
    /// <summary>lowercase</summary>
    [JsonStringEnumMemberName("lowercase")] Lowercase,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionTextPunctuationValue>))]
public enum CaptionTextPunctuationValue
{
    /// <summary>keep</summary>
    [JsonStringEnumMemberName("keep")] Keep,
    /// <summary>strip-keep-numeric</summary>
    [JsonStringEnumMemberName("strip-keep-numeric")] StripKeepNumeric,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionLayoutBalanceValue>))]
public enum CaptionLayoutBalanceValue
{
    /// <summary>greedy</summary>
    [JsonStringEnumMemberName("greedy")] Greedy,
    /// <summary>balanced</summary>
    [JsonStringEnumMemberName("balanced")] Balanced,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionLayoutAlignValue>))]
public enum CaptionLayoutAlignValue
{
    /// <summary>center</summary>
    [JsonStringEnumMemberName("center")] Center,
    /// <summary>left</summary>
    [JsonStringEnumMemberName("left")] Left,
    /// <summary>right</summary>
    [JsonStringEnumMemberName("right")] Right,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionStylePositionAnchorXValue>))]
public enum CaptionStylePositionAnchorXValue
{
    /// <summary>center</summary>
    [JsonStringEnumMemberName("center")] Center,
    /// <summary>left</summary>
    [JsonStringEnumMemberName("left")] Left,
    /// <summary>right</summary>
    [JsonStringEnumMemberName("right")] Right,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionStylePositionAnchorYValue>))]
public enum CaptionStylePositionAnchorYValue
{
    /// <summary>center</summary>
    [JsonStringEnumMemberName("center")] Center,
    /// <summary>top</summary>
    [JsonStringEnumMemberName("top")] Top,
    /// <summary>bottom</summary>
    [JsonStringEnumMemberName("bottom")] Bottom,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionBoxScopeValue>))]
public enum CaptionBoxScopeValue
{
    /// <summary>page</summary>
    [JsonStringEnumMemberName("page")] Page,
    /// <summary>line</summary>
    [JsonStringEnumMemberName("line")] Line,
    /// <summary>word</summary>
    [JsonStringEnumMemberName("word")] Word,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionRevealUnitValue>))]
public enum CaptionRevealUnitValue
{
    /// <summary>page</summary>
    [JsonStringEnumMemberName("page")] Page,
    /// <summary>word</summary>
    [JsonStringEnumMemberName("word")] Word,
    /// <summary>char</summary>
    [JsonStringEnumMemberName("char")] Char,
    /// <summary>wipe</summary>
    [JsonStringEnumMemberName("wipe")] Wipe,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionAnimationSpecTypeValue>))]
public enum CaptionAnimationSpecTypeValue
{
    /// <summary>none</summary>
    [JsonStringEnumMemberName("none")] None,
    /// <summary>fade</summary>
    [JsonStringEnumMemberName("fade")] Fade,
    /// <summary>pop</summary>
    [JsonStringEnumMemberName("pop")] Pop,
    /// <summary>zoom</summary>
    [JsonStringEnumMemberName("zoom")] Zoom,
    /// <summary>slide-up</summary>
    [JsonStringEnumMemberName("slide-up")] SlideUp,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionAnimationSpecEasingValue>))]
public enum CaptionAnimationSpecEasingValue
{
    /// <summary>linear</summary>
    [JsonStringEnumMemberName("linear")] Linear,
    /// <summary>easeOutCubic</summary>
    [JsonStringEnumMemberName("easeOutCubic")] EaseOutCubic,
    /// <summary>easeInOutCubic</summary>
    [JsonStringEnumMemberName("easeInOutCubic")] EaseInOutCubic,
    /// <summary>easeOutBack</summary>
    [JsonStringEnumMemberName("easeOutBack")] EaseOutBack,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionEmphasisSourceValue>))]
public enum CaptionEmphasisSourceValue
{
    /// <summary>none</summary>
    [JsonStringEnumMemberName("none")] None,
    /// <summary>rule</summary>
    [JsonStringEnumMemberName("rule")] Rule,
    /// <summary>manual</summary>
    [JsonStringEnumMemberName("manual")] Manual,
    /// <summary>llm</summary>
    [JsonStringEnumMemberName("llm")] Llm,
}

/// <summary>Allowed schema values; captions §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CaptionEmojiSourceValue>))]
public enum CaptionEmojiSourceValue
{
    /// <summary>rule</summary>
    [JsonStringEnumMemberName("rule")] Rule,
    /// <summary>manual</summary>
    [JsonStringEnumMemberName("manual")] Manual,
    /// <summary>llm</summary>
    [JsonStringEnumMemberName("llm")] Llm,
}

/// <summary>Solid or linear paint union; captions §2 and §13.</summary>
[JsonPolymorphic(TypeDiscriminatorPropertyName = "type")]
[JsonDerivedType(typeof(SolidPaint), "solid")]
[JsonDerivedType(typeof(LinearPaint), "linear")]
public abstract record CaptionPaint;

/// <summary>Solid sRGB fill; captions §13.</summary>
public sealed record SolidPaint(string Color) : CaptionPaint;

/// <summary>Linear sRGB gradient; captions §13.</summary>
public sealed record LinearPaint(double AngleDeg, IReadOnlyList<GradientStop> Stops, GradientSpace Space = GradientSpace.Line) : CaptionPaint;

/// <summary>Opaque gradient stop; captions §13.</summary>
public sealed record GradientStop(double Offset, string Color);

/// <summary>Gradient coordinate space; captions §13.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<GradientSpace>))]
public enum GradientSpace
{
    /// <summary>Word rectangle.</summary>
    [JsonStringEnumMemberName("word")] Word,
    /// <summary>Line rectangle.</summary>
    [JsonStringEnumMemberName("line")] Line,
    /// <summary>Page rectangle.</summary>
    [JsonStringEnumMemberName("page")] Page
}
