"""Text normalisation (spec section 3). Uses shared/caption-styles/casemap.json for case mapping.

Only graphemes() needs the third-party `regex` package (UAX #29 clusters); everything else is standard library, so
gen_gallery.py can use it without one.
"""
import os
import re
import unicodedata

from .util import STYLES, load_json

# Unicode White_Space property (spec 3.2).
WHITESPACE = {0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000}
WHITESPACE.update(range(0x2000, 0x200B))

KEEP_ALWAYS = {ord(c) for c in "%#@&"}
JOINERS = {0x27, 0x2019, 0x2D, 0x2010, 0x2011, 0x2013, 0x2014, 0x2E, 0x2F, 0xB7}
NUMERIC_SEPARATORS = {0x2C, 0x3A}
SIGNS = {0x2D, 0x2013}

CLOSERS = "\"'”’)\\]»"
SENTENCE_END = re.compile("[.!?…。！？][" + CLOSERS + "]*$")
CLAUSE_END = re.compile("[,;:—–][" + CLOSERS + "]*$")

IGNORABLE = {0x200C, 0x200D} | set(range(0xFE00, 0xFE10))


def category(cp):
    return unicodedata.category(chr(cp))


def is_alnum(cp):
    return cp is not None and category(cp)[0] in "LN"


def is_digit(cp):
    return cp is not None and category(cp) == "Nd"


class CaseMap:
    def __init__(self):
        doc = load_json(os.path.join(STYLES, "casemap.json"))
        self.upper = {a: b for a, b in doc["upper"]}
        self.lower = {a: b for a, b in doc["lower"]}
        self.rules = doc["rules"]

    def apply(self, cps, transform, lang):
        if transform == "none":
            return list(cps)
        table = self.upper if transform == "uppercase" else self.lower
        special = {}
        for r in self.rules:
            if r["transform"] != transform:
                continue
            if r["languages"] == "*" or lang in r["languages"]:
                special[r["from"][0]] = r["to"]
        out = []
        for cp in cps:
            if cp in special:
                out.extend(special[cp])
            else:
                out.append(table.get(cp, cp))
        return out


CASEMAP = None


def casemap():
    global CASEMAP
    if CASEMAP is None:
        CASEMAP = CaseMap()
    return CASEMAP


def collapse_whitespace(s):
    out, pending = [], False
    for ch in s:
        if ord(ch) in WHITESPACE:
            pending = bool(out)
            continue
        if pending:
            out.append(" ")
            pending = False
        out.append(ch)
    return "".join(out)


def strip_punctuation(cps):
    out = []
    n = len(cps)
    for i, cp in enumerate(cps):
        if category(cp)[0] != "P":
            out.append(cp)
            continue
        prev = cps[i - 1] if i > 0 else None
        nxt = cps[i + 1] if i + 1 < n else None
        if cp in KEEP_ALWAYS:
            out.append(cp)
        elif cp in JOINERS and is_alnum(prev) and is_alnum(nxt):
            out.append(cp)
        elif cp in NUMERIC_SEPARATORS and is_digit(prev) and is_digit(nxt):
            out.append(cp)
        elif cp in SIGNS and i == 0 and is_digit(nxt):
            out.append(cp)
    return out


def is_abbreviation(s):
    """Two or more letters, each followed by a full stop (U.S., e.g.)."""
    return len(s) >= 4 and len(s) % 2 == 0 and all(category(ord(c))[0] == "L" for c in s[::2]) and set(s[1::2]) == {"."}


def normalize(raw, punctuation, transform, lang):
    """Steps 1-6 of spec 3.1. Returns the display text ('' means the word is not captioned)."""
    s = unicodedata.normalize("NFC", raw)
    s = collapse_whitespace(s)
    cps = [ord(c) for c in s]
    if punctuation == "strip-keep-numeric" and not is_abbreviation(s):
        cps = strip_punctuation(cps)
    cps = casemap().apply(cps, transform, lang)
    s = unicodedata.normalize("NFC", "".join(chr(c) for c in cps))
    return collapse_whitespace(s)


def source_text(raw):
    return collapse_whitespace(unicodedata.normalize("NFC", raw))


def ends_sentence(raw):
    s = source_text(raw)
    return bool(SENTENCE_END.search(s)) and not is_abbreviation(s)


def ends_clause(raw):
    return bool(CLAUSE_END.search(source_text(raw)))


def matching_key(text, lang):
    """Key for stopwords and emoji keywords (spec 3.6): lowercase via casemap, drop every P* scalar."""
    cps = [ord(c) for c in unicodedata.normalize("NFC", text)]
    cps = casemap().apply(cps, "lowercase", lang)
    return "".join(chr(c) for c in cps if category(c)[0] != "P" and c not in WHITESPACE)


def graphemes(s):
    import regex  # third-party: \X extended grapheme clusters (UAX #29)

    return regex.findall(r"\X", s)
