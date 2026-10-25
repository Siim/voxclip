#!/usr/bin/env python3
"""Compare caption overlay renders with the metrics of doc/spec/captions.md section 16.5.

    python3 -I tools/captions/compare_overlays.py A.png B.png [--frame W H --a-crop X Y --b-crop X Y] [--diff out.png]
    python3 -I tools/captions/compare_overlays.py --dirs DIR_A DIR_B [--diff-dir DIR]

Images are straight-alpha 8-bit RGBA PNGs. A cropped golden is placed back into the frame at its crop
origin (from golden/<case>.json) before comparing. With --dirs every PNG present in both trees is
compared (paths relative to each root; crops are read from a sibling <case>.json when present).
Exit status 1 if any comparison fails. Needs numpy; nothing else outside the standard library.
"""
import argparse
import json
import os
import struct
import sys
import zlib

import numpy as np

MEAN_MAX = 4.5
SHARE_OVER_32_MAX = 0.02
OVER_32_FLOOR = 96
MAX_DIFF = 128
SSIM_MIN = 0.98
SSIM_SKIP_MAX = 2


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(path + ": not a PNG")
    pos, idat, width = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError(path + ": only 8-bit RGB/RGBA non-interlaced PNGs are supported")
            channels = 4 if ctype == 6 else 3
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    raw = zlib.decompress(b"".join(idat))
    stride = width * channels
    out = np.zeros((height, stride), dtype=np.uint8)
    prev = np.zeros(stride, dtype=np.int32)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = np.frombuffer(raw, dtype=np.uint8, count=stride, offset=y * (stride + 1) + 1).astype(np.int32)
        if f == 0:
            cur = line.copy()
        elif f == 1:
            cur = (np.cumsum(line.reshape(width, channels), axis=0) & 255).reshape(stride).astype(np.int32)
        elif f == 2:
            cur = (line + prev) & 255
        elif f in (3, 4):
            L = line.reshape(width, channels)
            P = prev.reshape(width, channels)
            C = np.zeros((width, channels), dtype=np.int32)
            a = np.zeros(channels, dtype=np.int32)
            for x in range(width):
                b = P[x]
                if f == 3:
                    p = (a + b) >> 1
                else:
                    c = P[x - 1] if x > 0 else np.zeros(channels, dtype=np.int32)
                    pa, pb, pc = np.abs(b - c), np.abs(a - c), np.abs(a + b - 2 * c)
                    p = np.where((pa <= pb) & (pa <= pc), a, np.where(pb <= pc, b, c))
                a = (L[x] + p) & 255
                C[x] = a
            cur = C.reshape(stride)
        else:
            raise ValueError(path + ": bad filter")
        out[y] = cur
        prev = cur
    img = out.reshape(height, width, channels)
    if channels == 3:
        img = np.concatenate([img, np.full((height, width, 1), 255, np.uint8)], axis=2)
    return img


def write_png(path, rgba):
    h, w, _ = rgba.shape
    raw = b"".join(b"\x00" + rgba[y].tobytes() for y in range(h))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def premultiply(img):
    a = img[..., 3:4].astype(np.int64)
    rgb = img[..., :3].astype(np.int64)
    p = (2 * rgb * a + 255) // 510  # round half up of c*a/255
    return np.concatenate([p, a], axis=2)


def place(img, frame, origin):
    if frame is None:
        return img
    w, h = frame
    out = np.zeros((h, w, 4), dtype=np.uint8)
    x, y = origin
    out[y:y + img.shape[0], x:x + img.shape[1]] = img
    return out


def gaussian_window(size=11, sigma=1.5):
    r = size // 2
    g = np.exp(-(np.arange(-r, r + 1) ** 2) / (2 * sigma * sigma))
    g /= g.sum()
    return g


def filter_valid(x, g):
    k = len(g)
    rows = sum(g[i] * x[:, i:x.shape[1] - k + 1 + i] for i in range(k))
    return sum(g[i] * rows[i:rows.shape[0] - k + 1 + i, :] for i in range(k))


def ssim_alpha(a, b, box):
    x0, y0, x1, y1 = box
    A = a[y0:y1, x0:x1].astype(np.float64)
    B = b[y0:y1, x0:x1].astype(np.float64)
    if A.shape[0] < 11 or A.shape[1] < 11:
        pad = ((0, max(0, 11 - A.shape[0])), (0, max(0, 11 - A.shape[1])))
        A, B = np.pad(A, pad), np.pad(B, pad)
    g = gaussian_window()
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    mu_a, mu_b = filter_valid(A, g), filter_valid(B, g)
    saa = filter_valid(A * A, g) - mu_a * mu_a
    sbb = filter_valid(B * B, g) - mu_b * mu_b
    sab = filter_valid(A * B, g) - mu_a * mu_b
    m = ((2 * mu_a * mu_b + c1) * (2 * sab + c2)) / ((mu_a ** 2 + mu_b ** 2 + c1) * (saa + sbb + c2))
    return float(m.mean())


def compare(img_a, img_b):
    """Returns (passed, metrics) per spec 16.5. Both images are full-frame straight RGBA uint8."""
    if img_a.shape != img_b.shape:
        return False, {"error": "size %s != %s" % (img_a.shape, img_b.shape)}
    A, B = premultiply(img_a), premultiply(img_b)
    region = (A[..., 3] > 0) | (B[..., 3] > 0)
    in_a, in_b = (A[..., 3] > 0).any(), (B[..., 3] > 0).any()
    if not in_a and not in_b:
        return True, {"empty": True}
    if in_a != in_b:
        return False, {"error": "one image is empty"}
    d = np.abs(A - B)
    n = int(region.sum())
    mean = float(d[region].sum()) / (4 * n)
    over_px = int((d[region].max(axis=1) > 32).sum())
    over = float(over_px) / n
    mx = int(d.max())
    ys, xs = np.nonzero(region)
    h, w = region.shape
    box = (max(0, xs.min() - 8), max(0, ys.min() - 8), min(w, xs.max() + 9), min(h, ys.max() + 9))
    s = ssim_alpha(A[..., 3], B[..., 3], box)
    metrics = {"mean": round(mean, 4), "shareOver32": round(over, 5), "max": mx, "ssimAlpha": round(s, 5), "pixels": n}
    ok = (mean <= MEAN_MAX and over_px <= max(SHARE_OVER_32_MAX * n, OVER_32_FLOOR) and mx <= MAX_DIFF
          and (s >= SSIM_MIN or mx <= SSIM_SKIP_MAX))
    return ok, metrics


def diff_image(img_a, img_b):
    d = np.abs(premultiply(img_a) - premultiply(img_b))[..., :4]
    rgb = np.clip(d[..., :3].max(axis=2, keepdims=True).repeat(3, axis=2) * 4, 0, 255)
    rgb = np.maximum(rgb, np.clip(d[..., 3:4].repeat(3, axis=2) * 4, 0, 255))
    return np.concatenate([rgb, np.full(rgb.shape[:2] + (1,), 255)], axis=2).astype(np.uint8)


def crop_index(root, rel):
    case = os.path.dirname(rel)
    path = os.path.join(root, case + ".json")
    if not os.path.exists(path):
        return None, None
    doc = json.load(open(path, encoding="utf-8"))
    name = os.path.basename(rel)
    for item in doc.get("images", []):
        if item["file"] == name:
            c = item["crop"]
            return (item["frame"]["width"], item["frame"]["height"]), (c["x"], c["y"])
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", nargs="?")
    ap.add_argument("b", nargs="?")
    ap.add_argument("--dirs", nargs=2)
    ap.add_argument("--frame", nargs=2, type=int)
    ap.add_argument("--a-crop", nargs=2, type=int, default=(0, 0))
    ap.add_argument("--b-crop", nargs=2, type=int, default=(0, 0))
    ap.add_argument("--diff")
    ap.add_argument("--diff-dir")
    args = ap.parse_args()
    pairs, missing = [], []
    if args.dirs:
        ra, rb = args.dirs

        def pngs(root):
            out = set()
            for dirpath, _, files in os.walk(root):
                for f in files:
                    if f.endswith(".png") and not f.endswith(".diff.png"):
                        out.add(os.path.relpath(os.path.join(dirpath, f), root))
            return out

        in_a, in_b = pngs(ra), pngs(rb)
        missing = sorted(in_a ^ in_b)
        for rel in sorted(in_a & in_b):
            pairs.append((rel, os.path.join(ra, rel), os.path.join(rb, rel)))
    elif args.a and args.b:
        pairs.append((os.path.basename(args.a), args.a, args.b))
    else:
        ap.error("give two PNGs or --dirs")
    failures = len(missing)
    for rel in missing:
        print("FAIL %s {\"error\": \"present on one side only\"}" % rel)
    for rel, pa, pb in pairs:
        ia, ib = read_png(pa), read_png(pb)
        if args.dirs:
            fa, oa = crop_index(args.dirs[0], rel)
            fb, ob = crop_index(args.dirs[1], rel)
            frame = fa or fb
            ia = place(ia, frame, oa or (0, 0)) if frame else ia
            ib = place(ib, frame, ob or (0, 0)) if frame else ib
        elif args.frame:
            ia = place(ia, args.frame, args.a_crop)
            ib = place(ib, args.frame, args.b_crop)
        ok, metrics = compare(ia, ib)
        print("%s %s %s" % ("PASS" if ok else "FAIL", rel, json.dumps(metrics)))
        if not ok:
            failures += 1
            target = args.diff or (os.path.join(args.diff_dir, rel.replace(".png", ".diff.png")) if args.diff_dir else None)
            if target and ia.shape == ib.shape:
                os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
                write_png(target, diff_image(ia, ib))
    print("%d compared, %d failed" % (len(pairs), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
