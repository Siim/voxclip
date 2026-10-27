#!/usr/bin/env python3
"""Generate the sidebar key-word colour vectors beside cards.json; design §5.4.3."""
import json
from pathlib import Path


def rgb(value):
    return [int(value[index:index + 2], 16) for index in (1, 3, 5)]


def luminance(color):
    channels = [channel / 255 for channel in color]
    linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
              for value in channels]
    return sum(weight * value for weight, value in zip((0.2126, 0.7152, 0.0722), linear))


def main():
    inputs = [
        ("paper-on-stage", "#F3F0E7", "#000000", "#F3F0E7"),
        ("box-highlight-on-stage", "#7C3AED", "#000000", "#B793F5"),
        ("half-up-channels", "#050F19", "#000000", "#767B81"),
        ("black-on-stage", "#000000", "#000000", "#737373"),
        ("white-on-stage", "#FFFFFF", "#000000", "#FFFFFF"),
        ("black-on-white", "#000000", "#FFFFFF", "#000000"),
        ("white-on-white-one-mix-only", "#FFFFFF", "#FFFFFF", "#FFFFFF"),
        ("just-below-minimum", "#747474", "#000000", "#B3B3B3"),
        ("just-above-minimum", "#757575", "#000000", "#757575"),
        ("gray-on-dark-preview", "#757575", "#3A3C45", "#B3B3B3"),
        ("paper-on-dark-preview", "#F3F0E7", "#3A3C45", "#F3F0E7"),
    ]
    cases = []
    for name, box_hex, background_hex, expected_hex in inputs:
        box, background = rgb(box_hex), rgb(background_hex)
        lighter, darker = sorted((luminance(box), luminance(background)), reverse=True)
        expected = box if (lighter + 0.05) / (darker + 0.05) >= 4.5 else [
            (channel * 55 + 255 * 45 + 50) // 100 for channel in box]
        assert expected == rgb(expected_hex), name
        cases.append(dict(id=name, box=box, background=background, expected=expected))
    target = Path(__file__).resolve().parents[2] / "shared/fixtures/captions/card-colors.json"
    target.write_text(json.dumps(dict(fixture="voxclip-caption-card-colors/1", cases=cases), indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(cases)} sidebar colour cases")


if __name__ == "__main__":
    main()
