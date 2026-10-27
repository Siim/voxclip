#!/usr/bin/env python3
"""Build shared/data/share-text.json and shared/fixtures/share/cases.json.

    python3 -I shared/fixtures/share/generate_share_cases.py /tmp/voxclip-unicode-15.1.0/emoji-data.txt

The argument is a local copy of Unicode 15.1 emoji-data.txt. When no file exists at that path, the
generator downloads it once from EMOJI_DATA_URL and stores it there. Either way the bytes must match
EMOJI_DATA_SHA256. Standard library only; two runs write identical bytes.

This file is the reference implementation of the share-text rules in doc/publishing.md section 2.1
and doc/spec/voice-lab.md section 11.3. Swift and C# Core replay every case in cases.json.
"""
import hashlib
import json
import os
import random
import sys
import unicodedata
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DATA_OUT = os.path.join(REPO, "shared", "data", "share-text.json")
CASES_OUT = os.path.join(HERE, "cases.json")

UNICODE_VERSION = "15.1.0"
EMOJI_DATA_URL = "https://www.unicode.org/Public/15.1.0/ucd/emoji/emoji-data.txt"
EMOJI_DATA_SHA256 = "d7aef489c8fe4c14f09ea5695200277c6b93ac82ac60845cdd2161b0d6835cc1"

X_RULES = {
    "maxWeightedTweetLength": 280,
    "scale": 100,
    "defaultWeight": 200,
    "transformedURLLength": 23,
    "ranges": [
        {"start": 0, "end": 4351, "weight": 100},
        {"start": 8192, "end": 8205, "weight": 100},
        {"start": 8208, "end": 8223, "weight": 100},
        {"start": 8242, "end": 8247, "weight": 100},
    ],
}
LINKEDIN_MAX = 3000
VOXCONVO_MAX = 2048
ELLIPSIS = "…"
TRAILING = ".,:;!?'\"’”)]}>…"
TLDS = sorted(["com", "net", "org", "io", "ai", "app", "dev", "co", "me", "tv", "gg", "ly", "xyz", "info", "eu",
               "ee", "fi", "se", "no", "dk", "de", "uk", "fr", "es", "it", "nl", "pl", "lv", "lt"])
SCHEMES = ("http://", "https://")
# Unicode White_Space (PropList.txt), unchanged since Unicode 6.3; doc/spec/captions.md uses the same set.
WHITE_SPACE = frozenset([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, *range(0x2000, 0x200B),
                         0x2028, 0x2029, 0x202F, 0x205F, 0x3000])
SENTENCE_END = ".?!…"
DEFAULT_CAPTION_WORDS = 40
# Grapheme_Cluster_Break=Prepend in Unicode 15.1 (UAX #29). Only the prepend-space cases use one (U+0600).
PREPEND = frozenset([0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F, 0x0890, 0x0891, 0x08E2,
                     0x0D4E, 0x110BD, 0x110CD, 0x111C2, 0x111C3, 0x1193F, 0x11941, 0x11A3A, *range(0x11A84, 0x11A8A),
                     0x11D46, 0x11F02])


def read_emoji_data(path):
    if not os.path.exists(path):
        with urllib.request.urlopen(EMOJI_DATA_URL, timeout=60) as response:
            fetched = response.read()
        if hashlib.sha256(fetched).hexdigest() != EMOJI_DATA_SHA256:
            raise SystemExit("downloaded emoji-data.txt does not match EMOJI_DATA_SHA256")
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "wb") as f:
            f.write(fetched)
    data = open(path, "rb").read()
    if hashlib.sha256(data).hexdigest() != EMOJI_DATA_SHA256:
        raise SystemExit("%s is not Unicode %s emoji-data.txt (sha256 mismatch)" % (path, UNICODE_VERSION))
    properties = {}
    for line in data.decode("utf-8").splitlines():
        body = line.split("#", 1)[0].strip()
        if not body:
            continue
        points, name = [part.strip() for part in body.split(";")]
        first, _, last = points.partition("..")
        properties.setdefault(name, []).append((int(first, 16), int(last or first, 16)))
    return properties


def merged(ranges):
    out = []
    for first, last in sorted(ranges):
        if out and first <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], last)
        else:
            out.append([first, last])
    return out


def points(ranges):
    return frozenset(cp for first, last in ranges for cp in range(first, last + 1))


EMOJI_RANGES, EMOJI_PRESENTATION, EXTENDED_PICTOGRAPHIC, EMOJI_MODIFIER = [], frozenset(), frozenset(), frozenset()


def load_tables(path):
    global EMOJI_RANGES, EMOJI_PRESENTATION, EXTENDED_PICTOGRAPHIC, EMOJI_MODIFIER
    properties = read_emoji_data(path)
    EMOJI_RANGES = merged(properties["Emoji_Presentation"])
    EMOJI_PRESENTATION = points(EMOJI_RANGES)
    EXTENDED_PICTOGRAPHIC = points(properties["Extended_Pictographic"])
    EMOJI_MODIFIER = points(properties["Emoji_Modifier"])


# --- Text primitives -------------------------------------------------------------------------

def nfc(text):
    return unicodedata.normalize("NFC", text)


def white(ch):
    return ord(ch) in WHITE_SPACE


def trim_end(text):
    end = len(text)
    while end > 0 and white(text[end - 1]):
        end -= 1
    return text[:end]


def trim_start(text):
    start = 0
    while start < len(text) and white(text[start]):
        start += 1
    return text[start:]


def raw(text):
    """NFC, every White_Space run collapsed to one U+0020, ends trimmed (Swift ShareDisclosure.raw, C# CaptionTextRules.Raw)."""
    out, pending = [], False
    for ch in nfc(text):
        if white(ch):
            pending = bool(out)
            continue
        if pending:
            out.append(" ")
            pending = False
        out.append(ch)
    return "".join(out)


def utf16_length(text):
    return len(text.encode("utf-16-le")) // 2


# --- Extended grapheme clusters (UAX #29, the rules the fixture repertoire needs) ---------------

def grapheme_class(cp):
    if cp == 0x0D:
        return "CR"
    if cp == 0x0A:
        return "LF"
    if cp == 0x200D:
        return "ZWJ"
    if 0x1F1E6 <= cp <= 0x1F1FF:
        return "RI"
    if cp in PREPEND:
        return "Prepend"
    if 0x1100 <= cp <= 0x115F or 0xA960 <= cp <= 0xA97C:
        return "L"
    if 0x1160 <= cp <= 0x11A7 or 0xD7B0 <= cp <= 0xD7C6:
        return "V"
    if 0x11A8 <= cp <= 0x11FF or 0xD7CB <= cp <= 0xD7FB:
        return "T"
    if 0xAC00 <= cp <= 0xD7A3:
        return "LV" if (cp - 0xAC00) % 28 == 0 else "LVT"
    if cp in EMOJI_MODIFIER or cp == 0x200C or 0xE0020 <= cp <= 0xE007F or 0xFF9E <= cp <= 0xFF9F:
        return "Extend"
    category = unicodedata.category(chr(cp))
    if category in ("Mn", "Me"):
        return "Extend"
    if category in ("Cc", "Cf", "Zl", "Zp", "Cs"):
        return "Control"
    if category == "Mc" or cp in (0x0E33, 0x0EB3):
        return "SpacingMark"
    if cp in EXTENDED_PICTOGRAPHIC:
        return "ExtPict"
    return "Other"


def clusters(text):
    out, current, previous = [], "", None
    regional, pictographic, pictographic_zwj = 0, False, False
    for ch in text:
        kind = grapheme_class(ord(ch))
        if previous is None:
            joined = False
        elif previous == "CR" and kind == "LF":
            joined = True
        elif previous in ("Control", "CR", "LF") or kind in ("Control", "CR", "LF"):
            joined = False
        elif previous == "L" and kind in ("L", "V", "LV", "LVT"):
            joined = True
        elif previous in ("LV", "V") and kind in ("V", "T"):
            joined = True
        elif previous in ("LVT", "T") and kind == "T":
            joined = True
        elif kind in ("Extend", "ZWJ", "SpacingMark"):
            joined = True
        elif previous == "Prepend":
            joined = True
        elif previous == "ZWJ" and kind == "ExtPict" and pictographic_zwj:
            joined = True
        elif previous == "RI" and kind == "RI" and regional % 2 == 1:
            joined = True
        else:
            joined = False
        if joined:
            current += ch
        else:
            if current:
                out.append(current)
            current = ch
        regional = regional + 1 if kind == "RI" else 0
        if kind == "ExtPict":
            pictographic, pictographic_zwj = True, False
        elif kind == "Extend" and pictographic:
            pictographic_zwj = False
        elif kind == "ZWJ" and pictographic:
            pictographic, pictographic_zwj = False, True
        else:
            pictographic, pictographic_zwj = False, False
        previous = kind
    if current:
        out.append(current)
    return out


def cluster_runs(text):
    """Run-length list of [scalars per cluster, count] for the NFC text."""
    runs = []
    for cluster in clusters(nfc(text)):
        if runs and runs[-1][0] == len(cluster):
            runs[-1][1] += 1
        else:
            runs.append([len(cluster), 1])
    return runs


# --- Share-text rules (doc/publishing.md section 2.1) ------------------------------------------

def ascii_alnum(ch):
    return "a" <= ch <= "z" or "A" <= ch <= "Z" or "0" <= ch <= "9"


def ascii_lower(text):
    return "".join(chr(ord(ch) + 32) if "A" <= ch <= "Z" else ch for ch in text)


def has_scheme(s, p, end):
    return any(end - p >= len(scheme) and ascii_lower(s[p:p + len(scheme)]) == scheme for scheme in SCHEMES)


def label(text):
    return bool(text) and ascii_alnum(text[0]) and ascii_alnum(text[-1]) and all(ascii_alnum(ch) or ch == "-" for ch in text)


def host_url(s, p, end):
    # The host is ASCII letters, digits, '-' and '.'; any other scalar before ':', '/' or the end fails it.
    k = p
    while k < end and (ascii_alnum(s[k]) or s[k] in "-."):
        k += 1
    if k < end and s[k] not in ":/":
        return False
    labels = s[p:k].split(".")
    if len(labels) < 2 or not all(label(part) for part in labels) or ascii_lower(labels[-1]) not in TLDS:
        return False
    if k < end and s[k] == ":":
        k += 1
        digits = k
        while k < end and "0" <= s[k] <= "9":
            k += 1
        if k == digits:
            return False
    return k == end or s[k] == "/"


def url_spans(s):
    spans, start = [], 0
    while start < len(s):
        if white(s[start]):
            start += 1
            continue
        following = start
        while following < len(s) and not white(s[following]):
            following += 1
        end = following
        while end > start and s[end - 1] in TRAILING:
            end -= 1
        for p in range(start, end):
            # Neither a scheme nor a bare host may follow an ASCII letter or digit.
            before = s[p - 1] if p > start else None
            if before is not None and ascii_alnum(before):
                continue
            if has_scheme(s, p, end) or (ascii_alnum(s[p]) and before not in ("@", ".", "-", "/") and host_url(s, p, end)):
                spans.append((p, end))
                break
        start = following
    return spans


def emoji_scalar(cp):
    return cp in EMOJI_PRESENTATION or cp in (0xFE0F, 0x20E3) or 0x1F1E6 <= cp <= 0x1F1FF


def scalar_weight(cp):
    for item in X_RULES["ranges"]:
        if item["start"] <= cp <= item["end"]:
            return item["weight"]
    return X_RULES["defaultWeight"]


def x_total(text):
    """The X weight before the division by scale."""
    s = nfc(text)
    total, position = 0, 0
    for start, end in url_spans(s) + [(len(s), len(s))]:
        for cluster in clusters(s[position:start]):
            if any(emoji_scalar(ord(ch)) for ch in cluster):
                total += X_RULES["defaultWeight"]
            else:
                total += sum(scalar_weight(ord(ch)) for ch in cluster)
        if end > start:
            total += X_RULES["transformedURLLength"] * X_RULES["scale"]
        position = end
    return total


def x_weight(text):
    return x_total(text) // X_RULES["scale"]


def stands_alone(ch):
    """What x_first_word_cut needs of the ellipsis and trailing punctuation, which it weighs scalar by scalar.

    ASCII or General Punctuation, so NFC never composes it with the scalar before it, and BMP; not White_Space or emoji;
    and its own grapheme cluster after a letter, an emoji ZWJ sequence and a virama, so it never joins an emoji cluster.
    """
    return ((ord(ch) < 0x80 or 0x2000 <= ord(ch) <= 0x206F) and not white(ch) and not emoji_scalar(ord(ch))
            and len(clusters("a" + ch + "a")) == 3 and len(clusters(chr(0x1F642) + chr(0x200D) + ch)) == 2
            and len(clusters(chr(0x0915) + chr(0x094D) + ch)) == 2)


def url_starts(s, first, end):
    """For every end e in first + 1..end, the start of the URL url_spans finds in the run s[first:e], or -1.

    One pass instead of one scan per end. A start is valid for some ends inside its host or port and, from one end on,
    for every later end; host runs of different starts do not overlap. The first valid start wins, as in url_spans.
    """
    starts = [-1] * (end + 1)
    settled = end + 1  # every end from here on has its start
    longest_tld = max(len(tld) for tld in TLDS)

    def mark(e, p):
        if e < settled and starts[e] < 0:
            starts[e] = p

    for p in range(first, end):
        if p > first and ascii_alnum(s[p - 1]):
            continue
        if p + 1 >= settled:
            break
        always = end + 1  # p is valid for every end from here on
        for scheme in SCHEMES:
            if end - p >= len(scheme) and ascii_lower(s[p:p + len(scheme)]) == scheme:
                always = p + len(scheme)
        if ascii_alnum(s[p]) and not (p > first and s[p - 1] in "@.-/"):
            dots, labels_ok, label_start, k = 0, True, p, p

            def host(e):
                return (dots > 0 and labels_ok and e > label_start and ascii_alnum(s[label_start]) and ascii_alnum(s[e - 1])
                        and e - label_start <= longest_tld and ascii_lower(s[label_start:e]) in TLDS)

            while k < end and (ascii_alnum(s[k]) or s[k] in "-."):
                if s[k] == ".":
                    labels_ok = labels_ok and k > label_start and ascii_alnum(s[label_start]) and ascii_alnum(s[k - 1])
                    dots, label_start = dots + 1, k + 1
                k += 1
                if host(k):
                    mark(k, p)
            if host(k) and k < end and s[k] == "/":
                always = min(always, k + 1)
            elif host(k) and k < end and s[k] == ":":
                g = k + 1
                while g < end and "0" <= s[g] <= "9":
                    g += 1
                for e in range(k + 2, g + 1):
                    mark(e, p)
                if k + 1 < g < end and s[g] == "/":
                    always = min(always, g + 1)
        for e in range(always, settled):
            mark(e, p)
        settled = min(settled, always)
    return starts


def x_first_word_cut(body, first, word_end, ends, tail):
    """Composer rule 5 for X in one pass: the cut the literal scan picks, weighed from prefix sums.

    The cut b > first keeps body[:b], then the ellipsis and the tail. Its NFC text, URL spans and clusters are body's,
    except in the run that holds the cut: that run's URL, if any, starts at url_starts(...)[e] for its stripped end e.
    URL starts are ASCII alphanumerics and b is a cluster boundary, so no piece of the cut splits an emoji cluster, and
    trailing punctuation and the ellipsis stand alone. So every piece weighs the sum of per-scalar weights (each scalar
    of a non-emoji cluster, defaultWeight on an emoji cluster's first scalar), and the ellipsis and the tail weigh
    x_total(ELLIPSIS + tail). The cuts are tried in the literal scan's order with the same result, so it picks the
    same cut.
    """
    scale, limit, url = X_RULES["scale"], X_RULES["maxWeightedTweetLength"], X_RULES["transformedURLLength"] * X_RULES["scale"]
    prefix = [0]
    for cluster in clusters(body[:word_end]):
        emoji = any(emoji_scalar(ord(ch)) for ch in cluster)
        for index, ch in enumerate(cluster):
            prefix.append(prefix[-1] + ((X_RULES["defaultWeight"] if index == 0 else 0) if emoji else scalar_weight(ord(ch))))
    starts = url_starts(body, first, word_end)
    stripped = list(range(word_end + 1))
    for x in range(first + 1, word_end + 1):
        if body[x - 1] in TRAILING:
            stripped[x] = stripped[x - 1]
    base = x_total(ELLIPSIS + tail)
    for b in reversed(ends):
        if b <= first:
            return b if base // scale <= limit else None
        e = stripped[b]
        p = starts[e] if e > first else -1
        total = base + (prefix[p] + url + prefix[b] - prefix[e] if p >= 0 else prefix[b])
        if total // scale <= limit:
            return b
    return None


def is_present(caption, line):
    return raw(line) in raw(caption)


def field_text(saved, line):
    """voice-lab.md section 11.3: the line after a blank line, the text cut to fit share.captions' 3,000 scalars."""
    if line is None or is_present(saved, line):
        return saved
    return fit(trim_end(saved), line, "linkedIn")


def last_span(s, line):
    """The last occurrence of the line in NFC text s, with White_Space runs compared as equal."""
    needle = raw(line)
    if not needle:
        return None
    collapsed, spans, index = [], [], 0
    while index < len(s):
        end = index + 1
        if white(s[index]):
            while end < len(s) and white(s[end]):
                end += 1
            collapsed.append(" ")
        else:
            collapsed.append(s[index])
        spans.append((index, end))
        index = end
    found = "".join(collapsed).rfind(needle)
    if found < 0:
        return None
    return spans[found][0], spans[found + len(needle) - 1][1]


def measure_and_limit(destination):
    """X weight, UTF-16 length or scalar count with its limit; "linkedIn" also bounds the caption field (section 11.3)."""
    if destination == "x":
        return x_weight, X_RULES["maxWeightedTweetLength"]
    if destination == "voxConvo":
        return utf16_length, VOXCONVO_MAX
    return len, LINKEDIN_MAX


def composer_text(caption, destination, line, rules=None):
    if destination == "linkedIn":
        return caption
    measure, limit = measure_and_limit(destination)
    if measure(caption) <= limit:
        return caption
    body, kept = nfc(caption), None
    span = last_span(body, line) if line is not None else None
    if span:
        left, right = trim_end(body[:span[0]]), trim_start(body[span[1]:])
        body = left + "\n\n" + right if left and right else left + right
        kept = line
    return fit(trim_end(body), kept, destination, rules)


def fit(body, line, destination, rules=None):
    """Composer rules 3 to 6: the body and, after a blank line, the line; the body is cut until the text fits.

    The scans are literal: every candidate, longest first, measured whole. Swift and C# bisect the same candidates;
    for X they weigh the first-word cuts in one pass (x_first_word_cut), checked here against the literal scan.
    `rules`, when given, gets the composer rule that made the text: 3, 4, 5, or 6 for the line or ellipsis alone.
    """
    measure, limit = measure_and_limit(destination)

    def made(rule, text):
        if rules is not None:
            rules.append(rule)
        return text

    def fits(text):
        return measure(text) <= limit

    tail = "\n\n" + line if line is not None else ""
    whole = body + tail if body else (line or "")
    if fits(whole):
        return made(3, whole)
    boundaries, offset = {0}, 0
    for cluster in clusters(body):
        offset += len(cluster)
        boundaries.add(offset)
    first = 0
    while first < len(body) and white(body[first]):
        first += 1
    for i in range(len(body) - 1, first, -1):
        if white(body[i]):
            kept = trim_end(body[:i])
            # A Prepend scalar joins the space after it: never keep one without the other.
            if len(kept) not in boundaries:
                continue
            candidate = kept + ELLIPSIS + tail
            if fits(candidate):
                return made(4, candidate)
    word_end = first
    while word_end < len(body) and not white(body[word_end]):
        word_end += 1
    ends = sorted(b for b in boundaries if b < word_end)
    found = next((b for b in reversed(ends) if fits(trim_end(body[:b]) + ELLIPSIS + tail)), None)
    if destination == "x":
        assert x_first_word_cut(body, first, word_end, ends, tail) == found, ascii(body)
    if found is not None:
        return made(5, trim_end(body[:found]) + ELLIPSIS + tail)
    return made(6, line if line is not None else ELLIPSIS)


def default_caption(title, words):
    sentence, ended = [], False
    for word in words[:DEFAULT_CAPTION_WORDS]:
        sentence.append(word)
        if word and word[-1] in SENTENCE_END:
            ended = True
            break
    first = " ".join(sentence) + ("" if ended or not sentence else ELLIPSIS)
    return "\n\n".join(part for part in (title or "", first) if part)


def estonian(language):
    return language is not None and language.split("-")[0].lower() == "et"


# --- Disclosure lines (doc/spec/voice-lab.md section 11.3, as VoiceLabDisclosurePlan.postText builds them) ---

SENTENCES = {
    "tts": ("Some words in this video were re-voiced with an AI copy of my own voice.",
            "Mõned sõnad selles videos on loetud minu enda hääle tehisintellekti-koopiaga."),
    "voiceChangerOwn": ("The voice in this video was converted with AI into a copy of my own voice.",
                        "Selle video hääl on tehisintellektiga muudetud minu enda hääle koopiaks."),
    "voiceChangerStock": ("The voice in this video was changed with AI.",
                          "Selle video häält on muudetud tehisintellektiga."),
    "lipsync": ("Lip movements in parts of it were generated with AI.",
                "Osa huulte liikumisest on loodud tehisintellektiga."),
}
COMBINATIONS = [
    ["tts"], ["voiceChangerOwn"], ["voiceChangerStock"],
    ["tts", "lipsync"], ["voiceChangerOwn", "lipsync"], ["voiceChangerStock", "lipsync"],
    ["tts", "voiceChangerOwn"], ["tts", "voiceChangerStock", "lipsync"],
]
LINES = {"+".join(kinds): {"en": " ".join(SENTENCES[k][0] for k in kinds), "et": " ".join(SENTENCES[k][1] for k in kinds)}
         for kinds in COMBINATIONS}
TTS_EN, TTS_ET = LINES["tts"]["en"], LINES["tts"]["et"]


# --- Cases ---------------------------------------------------------------------------------------

EN_BODY = ("Galley, not timeline. Like reading a galley before a press run, you cut by words "
           "and keep the rhythm of the take.")
ET_BODY = ("Tõnis lõikab videot sõnade kaupa ja hoiab kõne rütmi. "
           "Ööbik laulab üle õue, kui päev hakkab looja minema.")
DECOMPOSED = {"õ": "õ", "ä": "ä", "ö": "ö", "ü": "ü",
              "Ö": "Ö"}


def decompose(text):
    return "".join(DECOMPOSED.get(ch, ch) for ch in text)


def paragraphs(body, count):
    return " ".join([body] * count)


def padded(prefix, weight):
    """prefix + "x" padding to an exact X weight."""
    text = prefix + "x" * (weight - x_weight(prefix))
    assert x_weight(text) == weight, (prefix, weight)
    return text


def case_list():
    cases = []

    def add(name, text, line=None):
        cases.append((name, text, line))

    add("ascii-acceptance", "Galley, not timeline\n\nLike reading a galley before a press run.")
    add("estonian-url-emoji-acceptance", "Tõnis \U0001F642 https://voxconvo.com")
    add("estonian-nfc", ET_BODY)
    add("estonian-decomposed", decompose(ET_BODY))
    add("cjk-weight-2", "東京で会いましょう。 Tallinn")
    add("thai-weight-1", "สวัสดีครับ น้ำ")
    add("weight-range-boundaries",
        "aჿbᄀ c῾d e f​g‌h‍i‎j‏k‐l‟m†"
        "n‱o′p‷q‸r")
    add("url-trailing-punctuation",
        "Read https://voxconvo.com/clips/42?ref=x). Then (see HTTPS://VoxConvo.com/a). "
        "And “https://voxconvo.com”! Also http://voxconvo.com…")
    add("bare-domain",
        "Find us at voxconvo.com, VoxConvo.EE/download and www.voxconvo.com:8080/x. Not e.g. or a.b or yes.")
    add("email-not-url", "Write to hello@voxconvo.com or me@mail.voxconvo.ee, or see voxconvo.com.")
    add("scheme-inside-word", "foohttps://voxconvo.com and xhttp://voxconvo.com are words, not links.")
    add("emoji-zwj-family", "Family \U0001F468‍\U0001F469‍\U0001F467‍\U0001F466 time")
    add("emoji-skin-tones", "Thumbs \U0001F44D\U0001F3FD and waves \U0001F44B\U0001F3FF \U0001F3FD")
    add("emoji-keycaps", "Press 1️⃣ or #⃣ now")
    add("emoji-flag", "Tere \U0001F1EA\U0001F1EA!")
    add("heart-with-and-without-fe0f", "❤ and ❤️")
    long_url = "https://voxconvo.com/" + "a" * 400
    add("long-url-counts-23", "Read this " + long_url + " today")
    mixed = "Launch day \U0001F680 at https://voxconvo.com — 東京 and Tallinn. "
    filler = " ".join(["word"] * 40) + " "
    add("fits-exactly-280", padded(mixed + filler, 280))
    add("over-by-one-281", padded(mixed + filler, 281))
    add("paragraph-breaks-kept", paragraphs(EN_BODY, 2) + "\n\n" + paragraphs(EN_BODY, 2) + "\n" + EN_BODY)
    add("long-first-word", "a" * 276 + "q́̂" + "b" * 1821 + " tail words.")
    add("voxconvo-2048-exact", "a" * 2046 + "\U0001F600")
    add("voxconvo-astral-straddles-2048", "a" * 2047 + "\U0001F600 tail")
    add("voxconvo-nfc-fits", " ".join([decompose("õ" * 10)] * 100))
    add("cut-after-url", " ".join(["go"] * 84) + " voxconvo.com/a " + " ".join(["next"] * 60))
    body = "Galley, not timeline\n\n" + paragraphs(EN_BODY, 3)
    add("line-at-end-fits", "Galley, not timeline\n\n" + EN_BODY + "\n\n" + TTS_EN, TTS_EN)
    add("line-at-end", body + "\n\n" + TTS_EN, TTS_EN)
    add("line-in-middle", "Galley, not timeline\n\n" + TTS_EN + "\n\n" + paragraphs(EN_BODY, 3), TTS_EN)
    add("line-missing", body, TTS_EN)
    add("line-edited", body + "\n\nSome words in this video were re-voiced with AI.", TTS_EN)
    add("line-whitespace-variant", body + "\n\nSome words in this video\nwere re-voiced  with an AI copy of my own voice.", TTS_EN)
    add("line-twice", TTS_EN + " " + paragraphs(EN_BODY, 3) + " " + TTS_EN + " Thanks.", TTS_EN)
    add("line-only-text", TTS_EN, TTS_EN)
    # 282 with the line between wide gaps; moving it to the end with blank lines saves 4, so nothing is cut.
    add("line-moved-fits", padded("Galley, not timeline\n\n\n\n" + TTS_EN + "\n\n\n\n" + EN_BODY + " ", 282), TTS_EN)
    for key, texts in LINES.items():
        add("line-%s-en" % key, "Galley, not timeline\n\n" + paragraphs(EN_BODY, 3) + "\n\n" + texts["en"], texts["en"])
        add("line-%s-et" % key, "Galley, mitte ajajoon\n\n" + paragraphs(ET_BODY, 3) + "\n\n" + texts["et"], texts["et"])
    add("voxconvo-line-at-end-en", paragraphs(EN_BODY, 22) + "\n\n" + TTS_EN, TTS_EN)
    add("voxconvo-line-in-middle-et", paragraphs(ET_BODY, 10) + "\n\n" + TTS_ET + "\n\n" + paragraphs(ET_BODY, 12), TTS_ET)
    # A precomposed LV syllable and a trailing jamo T compose in NFC (Unicode 3.12): U+AC00 U+11A8 is U+AC01.
    lv_t = ("\uAC00\u11A8" * 10 + " ") * 19
    add("hangul-lv-t", lv_t + "\uC720\u11BD" * 3)
    add("hangul-lv-t-line", lv_t + "\n\n\uAC00\u11A8\uC720\u11BD", "\uAC01\uC736")
    # U+0600 (Prepend) and the space after it are one grapheme cluster, so no cut keeps U+0600 without its space.
    add("prepend-space", "go " * 91 + "\u0600 " + "next " * 10)
    add("prepend-two-spaces", "go " * 91 + "\u0600  " + "next " * 10)
    # Without White_Space only the first-word fallback cuts; a '.' lets a URL come and go as the cut grows.
    add("space-free-japanese-brands", "今日はVoxClipで動画を編集しました。YouTubeとXに投稿！" * 6)
    add("space-free-underscores", "_a" * 200)
    add("url-prefix-first-word", "a" * 300 + ".comx tail")
    # A saved caption of 2,990 scalars: with the line it would pass share.captions' 3,000, so fieldText cuts it.
    saved = ("Tere \U0001F642 " + paragraphs(ET_BODY, 30))[:2990]
    assert len(saved) == 2990 and not white(saved[-1])
    add("field-text-cap", saved, TTS_ET)
    # One long first word for X: URLs that come and go as the cut grows (x_first_word_cut against the literal scan).
    add("word-transient-tld", "x" * 270 + "voxconvo.com" + "q" * 30)
    add("word-many-transients", "a.co_" * 70)
    add("word-port", "日本" * 60 + "_voxconvo.com:8080x" + "日" * 30)
    add("word-port-path-trailing", "日本" * 60 + "_voxconvo.com:8080/x" + ")" * 20)
    add("word-scheme-too-heavy", "見て" * 70 + "HTTPS://voxconvo.com/" + "a" * 20)
    add("word-url-trailing-run", "見て" * 60 + "https://voxconvo.com/a" + ")" * 40)
    add("word-url-at-start", "voxconvo.com/" + "a" * 10 + ")" * 300)
    add("word-email", "日本" * 70 + "me@voxconvo.com" + "x" * 5)
    add("word-dots", "a." * 150)
    add("word-data-url", "data:" + "A" * 300)
    add("word-time", "今日は12:30に" + "投稿" * 80)
    add("word-emoji-prepend-url", "\U0001F642" * 100 + "\U0001F1EA\U0001F1EA" * 10 + "\U0001F44D\U0001F3FD" * 10
        + "\u0600https://voxconvo.com/x" + ")" * 30)
    # Leading White_Space before the long word: its first scalar U+0301 joins the space before it in one cluster, so the
    # first word starts inside a cluster, or U+0301 is a cluster of its own after CR LF.
    add("word-leading-white", "\r\n \u0301" + "日本" * 70 + "www.voxconvo.com" + "x" * 3)
    add("word-leading-mark", "\r\n\u0301" + "日本" * 70 + "www.voxconvo.com" + "x" * 3)
    add("word-line-tail", "日本" * 75 + "voxconvo.com" + "x" * 3 + "\n\n" + TTS_EN, TTS_EN)
    # A first word of one U+0301 on a space, before CR LF: rule 4 cuts after it and keeps the space, which is in its cluster.
    add("mark-on-space-first-word", " \u0301\r\n" + "日本" * 70 + "www.voxconvo.com" + "x" * 3)
    return cases


def default_caption_cases():
    sentence = ["Like", "reading", "a", "galley", "before", "a", "press", "run.", "Then", "more."]
    forty_five = ["w%d" % n for n in range(1, 46)]
    fortieth_ends = ["w%d" % n for n in range(1, 40)] + ["end!", "after"]
    items = [
        ("clip-first-sentence", "Galley, not timeline", sentence),
        ("full-take-first-sentence", None, sentence),
        ("forty-word-cap", "Clip 2", forty_five),
        ("fortieth-word-ends-sentence", "Clip 3", fortieth_ends),
        ("short-without-sentence-end", "Clip 4", ["so", "we", "went"]),
        ("question", None, ["Why", "cut?", "Because."]),
        ("exclamation", "Hook", ["Stop!", "Listen."]),
        ("ellipsis-word", "Pause", ["Well…", "then"]),
        ("corrected-estonian", "Tõnis", ["Ööbik", "laulab", "üle", "õue."]),
        ("empty-title", "", ["Hello", "there."]),
        ("no-words", "Clip 5", []),
        ("nothing", None, []),
    ]
    return [{"name": name, "title": title, "words": words, "expected": default_caption(title, words)}
            for name, title, words in items]


def language_cases():
    codes = ["et", "et-EE", "ET", "Et-ee", "eto", "est", "en", "en-ET", "", None]
    return [{"code": code, "estonian": estonian(code)} for code in codes]


def build_case(name, text, line):
    case = {
        "name": name,
        "text": text,
        "line": line,
        "clusters": cluster_runs(text),
        "xWeight": x_weight(text),
        "linkedInLength": len(text),
        "voxConvoLength": utf16_length(text),
    }
    if line is not None:
        case["present"] = is_present(text, line)
        case["fieldText"] = field_text(text, line)
    case["composerX"] = composer_text(text, "x", line)
    case["composerVoxConvo"] = composer_text(text, "voxConvo", line)
    return case


# --- Output --------------------------------------------------------------------------------------

def dump(value, level=0):
    pad = "  " * level
    if isinstance(value, dict):
        items = ",\n".join("%s  %s: %s" % (pad, json.dumps(key), dump(item, level + 1)) for key, item in value.items())
        return "{\n%s\n%s}" % (items, pad) if value else "{}"
    if isinstance(value, list) and any(isinstance(item, dict) for item in value):
        items = ",\n".join("%s  %s" % (pad, dump(item, level + 1)) for item in value)
        return "[\n%s\n%s]" % (items, pad)
    return json.dumps(value, ensure_ascii=True, separators=(", ", ": "))


def write(path, document):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(dump(document) + "\n")


def check_examples():
    # doc/publishing.md section 2.3 and the fixture boundaries this generator relies on.
    assert x_weight("Tõnis \U0001F642 https://voxconvo.com") == 32
    assert utf16_length("a" * 2046 + "\U0001F600") == VOXCONVO_MAX
    assert utf16_length("a" * 2047 + "\U0001F600") == VOXCONVO_MAX + 1
    assert all(emoji_scalar(cp) for cp in (0x1F642, 0x1F600, 0x1F680, 0x1F1EA, 0xFE0F, 0x20E3))
    assert not emoji_scalar(0x2764)
    for case in case_list():
        for ch in nfc(case[1]):
            assert unicodedata.category(ch) != "Cn", (case[0], hex(ord(ch)))
    # x_first_word_cut's precondition: the ellipsis is trailing punctuation and every trailing scalar stands alone.
    assert len(ELLIPSIS) == 1 and ELLIPSIS in TRAILING and all(stands_alone(ch) for ch in TRAILING)


def check_first_word_cuts():
    """Random X first words, so fit compares x_first_word_cut with the literal scan beyond the fixture cases."""
    pool = ["日本", "語", "a", "co", "com", "ee", ".", ":", "/", "https://", "HTTP://", "voxconvo", "-", "@",
            "_", "8080", ")", "!", "\u2026", "\u201D", "\U0001F642", "\U0001F1EA\U0001F1EA", "\U0001F44D\U0001F3FD",
            "\u0600", "\u0301", "x", "1.0", ".com", ":443/", "www."]
    rng = random.Random(15)
    for _ in range(60):
        word, length = "", rng.choice([150, 220, 300])
        while len(word) < length:
            word += rng.choice(pool)
        line = rng.choice([None, TTS_EN])
        composer_text(rng.choice(["", " ", "\n"]) + word + ("\n\n" + line if line else ""), "x", line)


def check_case_rules():
    """Each word-* case is cut inside its first word for X (composer rule 5), as its name says, and
    mark-on-space-first-word is cut by rule 4."""
    for name, text, line in case_list():
        if name.startswith("word-") or name == "mark-on-space-first-word":
            rules = []
            composer_text(text, "x", line, rules)
            assert rules == ([4] if name == "mark-on-space-first-word" else [5]), (name, rules)


def main():
    check_examples()
    check_first_word_cuts()
    check_case_rules()
    data = {
        "shareTextVersion": 1,
        "description": "Share-text rules of doc/publishing.md section 2.1: the twitter-text v3 weights, URL and "
                       "emoji rules, destination limits and the ellipsis. Generated by "
                       "shared/fixtures/share/generate_share_cases.py; do not edit by hand.",
        "x": X_RULES,
        "linkedIn": {"maxLength": LINKEDIN_MAX, "unit": "unicodeScalar"},
        "voxConvo": {"maxLength": VOXCONVO_MAX, "unit": "utf16CodeUnit"},
        "ellipsis": ELLIPSIS,
        "url": {"trailingPunctuation": TRAILING, "tlds": TLDS},
        "emoji": {
            "property": "Emoji_Presentation",
            "unicodeVersion": UNICODE_VERSION,
            "source": EMOJI_DATA_URL,
            "sourceSha256": EMOJI_DATA_SHA256,
            "license": "Unicode-3.0",
            "copyright": "Copyright © 1991-2024 Unicode, Inc. Derived from the Unicode Character Database "
                         "(emoji-data.txt) under the Unicode License v3; the full notice is in THIRD_PARTY_NOTICES.md.",
            "ranges": EMOJI_RANGES,
        },
    }
    cases = [build_case(*item) for item in case_list()]
    fixture = {
        "fixtureVersion": 1,
        "description": "Share-text cases for doc/publishing.md section 2.1 and doc/spec/voice-lab.md section 11.3. "
                       "Generated by generate_share_cases.py from shared/data/share-text.json rules; do not edit by hand.",
        "lines": LINES,
        "languages": language_cases(),
        "defaultCaptions": default_caption_cases(),
        "cases": cases,
    }
    write(DATA_OUT, data)
    write(CASES_OUT, fixture)
    print("wrote", os.path.relpath(DATA_OUT, REPO), len(EMOJI_RANGES), "emoji ranges;",
          os.path.relpath(CASES_OUT, REPO), len(cases), "cases,", len(fixture["defaultCaptions"]), "default captions,",
          len(fixture["languages"]), "languages")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    load_tables(sys.argv[1])
    main()
