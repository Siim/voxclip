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
    background = color(style, box)
    tokens = [paint["color"]] if paint["type"] == "solid" else [stop["color"] for stop in paint["stops"]]
    if all(ratio(color(style, token), background) >= 4.5 for token in tokens):
        return paint
    chosen = "#000000" if ratio((0, 0, 0), background) >= ratio((255, 255, 255), background) else "#FFFFFF"
    return {"type": "solid", "color": chosen}
