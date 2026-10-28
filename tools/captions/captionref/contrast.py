"""Caption box text contrast, captions section 2.3; sRGB WCAG relative luminance."""

from .style import color

SWATCHES = {"yellow": "#FFE14D", "green": "#4BE38A", "cyan": "#5CE1FF",
            "pink": "#FF6FAE", "paper": "#F3F0E7", "white": "#FFFFFF"}


def luminance(rgb):
    channels = [channel / 255 for channel in rgb[:3]]
    linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
              for value in channels]
    return sum(weight * value for weight, value in zip((0.2126, 0.7152, 0.0722), linear))


def ratio(foreground, background):
    front, back = luminance(foreground), luminance(background)
    return (max(front, back) + 0.05) / (min(front, back) + 0.05)


def text(paint, box, style):
    if paint["type"] != "solid":
        return paint
    background = color(style, box)
    if ratio(color(style, paint["color"]), background) >= 4.5:
        return paint
    chosen = "#000000" if ratio((0, 0, 0), background) >= ratio((255, 255, 255), background) else "#FFFFFF"
    return {"type": "solid", "color": chosen}


def resolve(style):
    original = style["fill"]
    box = style.get("box", {}).get("color")
    if box:
        style["fill"] = text(original, box, style)
    for appearance in style.get("words", {}).values():
        background = appearance.get("box", {}).get("color", box)
        paint = appearance.get("fill", original)
        resolved = text(paint, background, style) if background else paint
        if "fill" in appearance or resolved != style["fill"]:
            appearance["fill"] = resolved
    return style
