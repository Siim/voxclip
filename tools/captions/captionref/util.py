import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SHARED = os.path.join(REPO, "shared")
FONTS = os.path.join(SHARED, "fonts")
STYLES = os.path.join(SHARED, "caption-styles")
FIXTURES = os.path.join(SHARED, "fixtures", "captions")


def round_half_up(x):
    """Spec section 1.3: floor(x) + 1 when the fraction is >= 0.5. Not floor(x + 0.5)."""
    f = math.floor(x)
    return int(f + 1) if x - f >= 0.5 else int(f)


def clamp(x, lo, hi):
    return lo if x < lo else hi if x > hi else x


def r3(x):
    return float("%.3f" % x) + 0.0


def r6(x):
    return float("%.6f" % x) + 0.0


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def dumps(value, indent=0, width=110):
    """Compact pretty printer: a value that fits in `width` columns stays on one line."""
    flat = json.dumps(value, ensure_ascii=False, separators=(", ", ": "))
    if len(flat) + indent <= width or not isinstance(value, (dict, list)) or not value:
        return flat
    pad = " " * (indent + 1)
    if isinstance(value, dict):
        items = ["%s%s: %s" % (pad, json.dumps(k, ensure_ascii=False), dumps(v, indent + 1, width)) for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + " " * indent + "}"
    items = [pad + dumps(v, indent + 1, width) for v in value]
    return "[\n" + ",\n".join(items) + "\n" + " " * indent + "]"


def write_json(path, doc):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(dumps(doc))
        f.write("\n")
