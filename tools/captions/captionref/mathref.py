"""Deterministic drawing math shared by both renderers (spec sections 12 and 13)."""
import math

from .util import round_half_up

KAPPA = 0.5522847498


def gaussian_kernel(sigma):
    """Spec 13.2, sigma < 2 px: exact kernel, radius ceil(3 sigma), normalised."""
    r = math.ceil(3 * sigma)
    w = [math.exp(-(k * k) / (2 * sigma * sigma)) for k in range(-r, r + 1)]
    s = sum(w)
    return r, [x / s for x in w]


def box_size(sigma):
    """Spec 13.2, sigma >= 2 px: SVG 1.1 feGaussianBlur box size."""
    return math.floor(sigma * 3 * math.sqrt(2 * math.pi) / 4 + 0.5)


def box_pass(row, lo, hi):
    """One box pass: out[x] = round_half_up(sum(row[x+lo .. x+hi]) / d), zeros outside the row."""
    n = len(row)
    d = hi - lo + 1
    out = []
    for x in range(n):
        s = 0
        for k in range(x + lo, x + hi + 1):
            if 0 <= k < n:
                s += row[k]
        out.append((2 * s + d) // (2 * d))
    return out


def box_passes(d):
    if d % 2 == 1:
        h = d // 2
        return [(-h, h), (-h, h), (-h, h)]
    h = d // 2
    return [(-h, h - 1), (-h + 1, h), (-h, h)]


def blur_1d(row, sigma):
    """Blur one row of 8-bit mask values (the horizontal half of spec 13.2)."""
    if sigma <= 0:
        return list(row)
    if sigma < 2:
        r, w = gaussian_kernel(sigma)
        n = len(row)
        out = []
        for x in range(n):
            acc = 0.0
            for i, k in enumerate(range(-r, r + 1)):
                if 0 <= x + k < n:
                    acc += w[i] * row[x + k]
            out.append(min(255, max(0, round_half_up(acc))))
        return out
    for lo, hi in box_passes(box_size(sigma)):
        row = box_pass(row, lo, hi)
    return row


def rounded_rect_path(x, y, w, h, r):
    """Spec 12.1: clockwise in y-down coordinates, four cubic quarter arcs."""
    r = min(r, w / 2, h / 2)
    if r <= 0:
        return [["M", x, y], ["L", x + w, y], ["L", x + w, y + h], ["L", x, y + h], ["Z"]]
    k = KAPPA * r
    return [
        ["M", x + r, y],
        ["L", x + w - r, y],
        ["C", x + w - r + k, y, x + w, y + r - k, x + w, y + r],
        ["L", x + w, y + h - r],
        ["C", x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h],
        ["L", x + r, y + h],
        ["C", x + r - k, y + h, x, y + h - r + k, x, y + h - r],
        ["L", x, y + r],
        ["C", x, y + r - k, x + r - k, y, x + r, y],
        ["Z"],
    ]


def gradient_points(x, y, w, h, angle_deg):
    """Spec 10.4: CSS linear-gradient geometry with 0 deg = left to right, 90 deg = top to bottom."""
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    half = (w / 2) * abs(dx) + (h / 2) * abs(dy)
    cx, cy = x + w / 2, y + h / 2
    return [cx - dx * half, cy - dy * half], [cx + dx * half, cy + dy * half]
