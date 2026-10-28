"""Loading styles: schema defaults (spec 2.2), aspect overrides and user overrides (spec 2.4)."""
import copy
import os

from .util import STYLES, load_json

SCHEMA = None

# Absent optional objects (spec 2.2). 'stroke' and 'box' stay absent (no stroke, no box).
ABSENT = {
    "shadows": [],
    "words": {},
    "reveal": {"unit": "page", "maxCharsPerSec": 30},
    "animation": {},
    "emphasis": {"source": "none", "maxPerPage": 1, "minScore": 0, "scale": 1},
    "emoji": {"enabled": False, "source": "rule", "placement": "above-page", "sizeEm": 1.2, "gapEm": 0.15, "maxPerPage": 1},
    "effects": {},
    "aspects": {},
    "text": {"transform": "none", "punctuation": "keep", "userOverridable": True},
}


def schema():
    global SCHEMA
    if SCHEMA is None:
        SCHEMA = load_json(os.path.join(STYLES, "schema.json"))
    return SCHEMA


def deref(node):
    while "$ref" in node:
        path = node["$ref"]
        assert path.startswith("#/")
        target = schema()
        for part in path[2:].split("/"):
            target = target[part]
        node = target
    return node


def apply_defaults(node, inst):
    node = deref(node)
    if "oneOf" in node and isinstance(inst, dict):
        for branch in node["oneOf"]:
            b = deref(branch)
            if b.get("properties", {}).get("type", {}).get("const") == inst.get("type"):
                apply_defaults(b, inst)
        return
    if isinstance(inst, dict):
        for key, sub in node.get("properties", {}).items():
            subd = sub if "default" in sub else deref(sub)
            if key not in inst and "default" in subd:
                inst[key] = copy.deepcopy(subd["default"])
            if key in inst:
                apply_defaults(sub, inst[key])
    elif isinstance(inst, list) and "items" in node:
        for item in inst:
            apply_defaults(node["items"], item)


def load_style(style_id):
    """The style file as written (no defaults applied)."""
    return load_json(os.path.join(STYLES, "styles", style_id + ".json"))


def with_defaults(style):
    st = copy.deepcopy(style)
    for key, value in ABSENT.items():
        if key not in st:
            st[key] = copy.deepcopy(value)
    apply_defaults(schema(), st)
    return st


def aspect_class(width, height):
    """Spec 5.1: integer comparisons only."""
    if 10 * width < 9 * height:
        return "portrait"
    if 9 * width > 10 * height:
        return "landscape"
    return "square"


def preset_of(width, height):
    """Spec 2.4: the export aspect preset whose ratio the frame has exactly, else None (source)."""
    if 16 * width == 9 * height:
        return "9:16"
    if 9 * width == 16 * height:
        return "16:9"
    if width == height:
        return "1:1"
    return None


NOT_PATCHABLE = {"$schema", "schemaVersion", "id", "name", "description", "order", "tags", "aspects", "preview"}


def merge_patch(target, patch):
    """RFC 7396 JSON merge patch."""
    if not isinstance(patch, dict):
        return copy.deepcopy(patch)
    out = copy.deepcopy(target) if isinstance(target, dict) else {}
    for key, value in patch.items():
        if value is None:
            out.pop(key, None)
        else:
            out[key] = merge_patch(out.get(key), value)
    return out


def resolve(style, captions, width, height):
    """Effective style for one output frame (spec 2.4): aspect override, user patch, defaults, position."""
    captions = captions or {}
    cls = aspect_class(width, height)
    s1 = copy.deepcopy(style)
    asp = s1.get("aspects", {}).get(cls, {})
    if "sizeSh" in asp:
        s1["font"]["sizeSh"] = asp["sizeSh"]
    for k in ("x", "y"):
        if k in asp:
            s1["position"][k] = asp[k]
    for k in ("maxLineWidthW", "maxWords"):
        if k in asp:
            s1["layout"][k] = asp[k]
    patch = copy.deepcopy(captions.get("overrides") or {})
    bad = sorted(set(patch) & NOT_PATCHABLE)
    if bad:
        raise ValueError("overrides may not patch " + ", ".join(bad))
    if not style.get("text", {}).get("userOverridable", True) and isinstance(patch.get("text"), dict):
        for k in ("transform", "punctuation"):
            patch["text"].pop(k, None)
    merged = merge_patch(s1, patch)
    try:
        from jsonschema import Draft202012Validator
        errors = list(Draft202012Validator(schema()).iter_errors(merged))
        if errors:
            raise ValueError("patched style is invalid: " + errors[0].message)
    except ImportError:
        pass
    st = with_defaults(merged)
    preset = preset_of(width, height)
    pos = captions.get("positionByAspect", {}).get(preset) if preset else None
    if pos is None:
        pos = captions.get("position")
    if pos is not None and st["position"]["userDraggable"]:
        st["position"]["x"] = pos["x"]
        st["position"]["y"] = pos["y"]
    st["_sizeScale"] = st["font"]["sizeScale"]
    st["_aspect"] = cls
    st["_preset"] = preset
    from .contrast import resolve as resolve_contrast
    return resolve_contrast(st)


def color(style, value):
    """Resolve a colour token to (r, g, b, a) bytes (spec 2.3)."""
    if value.startswith("$accent"):
        base = style["accent"]
        alpha = value.split("/", 1)[1] if "/" in value else "FF"
        value = base + alpha
    v = value.lstrip("#")
    if len(v) == 6:
        v += "FF"
    return tuple(int(v[i:i + 2], 16) for i in (0, 2, 4, 6))
