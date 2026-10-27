"""Caption card text (doc/design.md section 5.4.2): the words a media stand-in shows when there is no frame.

The input is the scope's caption copy (editing spec 7.6), already planned; tools/captions/card_plans.mjs
computes it with the editing fixture generator's reference planner. Nothing here measures or renders: the
apps draw the card with their own caption renderer, and the fit (section 5.4.3) runs there.
"""
import os
import re

from . import text as tx
from .style import resolve
from .util import FONTS, load_json

MAX_WORDS = 4  # words per card page, whatever the style allows (section 5.4.2)
SURFACES = (("homeTile", 2, True), ("headerChip", 1, True), ("sidebar", 2, False), ("clipRow", 2, False))
FILLER = re.compile(r"\A(?:[Uu][Mm]+|[Uu][Hh]+|[Ee][Rr][Mm]+|[Hh][Mm][Mm]+)[,.!?]?\Z")  # editing spec 4.11
NONE = {"source": "none", "words": [], "keyIndex": 0}


class Coverage:
    """Glyph coverage from shared/fonts/fonts.json, the font cascade of captions spec 4.4 without shaping."""

    def __init__(self):
        manifest = load_json(os.path.join(FONTS, "fonts.json"))
        self.fonts = {f["file"]: f for f in manifest["fonts"]}
        self.fallbacks = [(f["weight"], f["file"]) for f in manifest["fallback"]["files"]]

    def covers(self, file, cp):
        return any(a <= cp <= b for a, b in self.fonts[file]["coverage"])

    def noto_for(self, weight):
        best = None
        for w, f in self.fallbacks:
            d = abs(w - weight)
            if best is None or d < best[0] or (d == best[0] and w > best[1]):
                best = (d, w, f)
        return best[2]

    def kept(self, text, style):
        """The text without the grapheme clusters no bundled font covers ('' when nothing is left)."""
        primary = style["font"]["file"]
        cascade = [primary] + list(style["font"]["fallbackFiles"]) + [self.noto_for(self.fonts[primary]["weight"])]
        out = []
        for cluster in tx.graphemes(text):
            cps = [ord(c) for c in cluster]
            core = [c for c in cps if c not in tx.IGNORABLE]
            if not core:
                continue
            chosen = next((f for f in cascade if all(self.covers(f, c) for c in core)), None)
            if chosen is None:
                chosen = next((f for f in cascade if self.covers(f, core[0])), None)
            if chosen is None:
                continue
            out.append("".join(chr(c) for c in cps if c in tx.IGNORABLE or self.covers(chosen, c)))
        return "".join(out)


def language(tag):
    """Primary subtag, lower-cased (captions spec 3.1)."""
    return (tag or "und").split("-")[0].lower()


def export_frame(project):
    """The project's export frame (architecture 4.1), which picks the style's aspect overrides."""
    aspect = project["export"]["aspect"]
    if aspect == "16:9":
        return 1920, 1080
    if aspect == "9:16":
        return 1080, 1920
    if aspect == "1:1":
        return 1080, 1080
    video = project["media"]["source"].get("video")
    if not video:
        return 1920, 1080
    w, h = video["width"], video["height"]
    if video["rotationDegrees"] in (90, 270):
        w, h = h, w
    scale = min(1, 1920 / max(w, h))
    return max(2, int(w * scale / 2 + 0.5) * 2), max(2, int(h * scale / 2 + 0.5) * 2)


def resolved_style(style, project):
    width, height = export_frame(project)
    try:
        return resolve(style, project["captions"], width, height)
    except ValueError:  # a rejected patch shows the style unpatched (captions spec 2.4)
        return resolve(style, None, width, height)


def group(words, layout):
    """Captions spec 6.1 paging without the fit test (the fit runs when the card is drawn, section 5.4.3)."""
    pages, cur = [], []
    for w in words:
        if cur:
            prev, first = cur[-1], cur[0]
            new_page = (len(cur) >= layout["maxWords"]
                        or (layout["breakOnSentence"] and tx.ends_sentence(prev["raw"]))
                        or (layout["breakOnComma"] and len(cur) >= 2 and tx.ends_clause(prev["raw"]))
                        or (layout["breakOnGapSec"] is not None and w["start"] - prev["end"] >= layout["breakOnGapSec"])
                        or (layout["maxPageSec"] is not None and w["end"] - first["start"] > layout["maxPageSec"]))
            if new_page:
                pages.append(cur)
                cur = []
        cur.append(w)
    if cur:
        pages.append(cur)
    return pages


def key_index(words):
    """The first number, otherwise the first word that is not weak, otherwise the first word."""
    for i, w in enumerate(words):
        if any(tx.is_digit(ord(c)) for c in w["display"]):
            return i
    for i, w in enumerate(words):
        if not w["weak"]:
            return i
    return 0


def dropping_last_word(words):
    """The fit's next shorter card: the last word goes, then any weak words before it, keeping one word."""
    if len(words) <= 1:
        return None
    out = words[:-1]
    while len(out) > 1 and out[-1]["weak"]:
        out = out[:-1]
    return out


def card(project, captions, style, words_visible, coverage, stopwords):
    """design.md 5.4.2. `captions` is the scope's caption copy, or None when the project has no transcript."""
    transcript = project.get("transcript")
    if transcript is None or captions is None:
        return dict(NONE), None
    st = resolved_style(style, project)
    lang = language(transcript.get("language"))
    punctuation, transform = st["text"]["punctuation"], st["text"]["transform"]

    def entry(id_, text, start, end):
        display = coverage.kept(tx.normalize(text, punctuation, transform, lang), st)
        if not display:
            return None
        return {"id": id_, "text": text, "raw": tx.source_text(text), "display": display, "start": start, "end": end}

    words = [e for e in (entry(w["id"], w["text"], w["start"], w["end"]) for w in captions) if e]
    if not words:
        return dict(NONE), st
    layout = dict(st["layout"], maxWords=min(st["layout"]["maxWords"], MAX_WORDS))
    source = "transcript"
    if not words_visible:
        source = "title"
        tokens = [t for t in tx.source_text(project.get("title") or "").split(" ") if t]
        words = [e for e in (entry("title-%d" % i, t, 0.0, 0.0) for i, t in enumerate(tokens)) if e]
        if not words:
            return dict(NONE), st
        layout.update(breakOnGapSec=None, maxPageSec=None)  # a title has no timing
    stops = stopwords.get(lang)
    for w in words:
        w["weak"] = stops is not None and bool(FILLER.match(w["text"]) or tx.matching_key(w["display"], lang) in stops)
    if stops is not None:
        lead = 0
        while lead < len(words) and FILLER.match(words[lead]["text"]):
            lead += 1
        if lead < len(words):
            words = words[lead:]
    pages = group(words, layout)
    page = pages[0]
    if stops is not None:
        page = next((p for p in pages if any(not w["weak"] for w in p)), pages[0])
        while len(page) > 1 and page[-1]["weak"]:
            page = page[:-1]
    return {"source": source, "words": page, "keyIndex": key_index(page)}, st


def draws_at_last_word(st):
    """A style whose reveal hides the words after the active one is drawn at its last word."""
    return st["reveal"]["unit"] in ("word", "char")


def hold_gap(st):
    """The resolved style's hold after a page's last word; 0 when there is no card."""
    return st["layout"]["holdGapSec"] if st else 0.0


STATUSES = ("none", "loading", "missing", "unreadable", "transcribing", "demo", "audioOnly")


def stand_in(status, has_frame, holding, has_words):
    """design.md 5.4.1 precedence over the 5.4.4 states: "frame", "card" or "black". A card without words draws only
    the style's backdrop. Missing, unreadable, demo and audio-only media never show a frame; elsewhere a frame wins,
    the first 300 ms hold shows black (5.4.5), and a transcription with no frame yet shows the style's backdrop."""
    if status in ("missing", "unreadable", "demo", "audioOnly"):
        return "card" if has_words else "black"
    if has_frame:
        return "frame"
    if holding:
        return "black"
    return "card" if has_words or status == "transcribing" else "black"


def layout_words(words, key):
    """The card as a caption state at a fixed moment, like a gallery tile (captions spec 15.3)."""
    return [{"id": w["id"], "text": w["text"], "start": 0.4 * i, "end": 0.4 * i + 0.35, "emphasis": i == key}
            for i, w in enumerate(words)]


def timing(words, key, at_last, hold):
    """The track duration and the drawn moment (section 5.4.2). The card is drawn inside its anchor word, at
    0.35 x 0.98 into it as a gallery tile is (captions spec 15.3): a page is visible on [start, last end + hold),
    and Bold and Highlight hold nothing. A reveal style anchors on its last word and is drawn at that word's end
    when the page holds after it, so a long Typewriter word shows its last character too."""
    if not words:
        return 0.0, 0.0
    anchor = len(words) - 1 if at_last else key
    return 0.4 * len(words) + 0.5, 0.4 * anchor + (0.35 if at_last and hold > 0 else 0.35 * 0.98)
