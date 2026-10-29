import math


def choose_threshold(impostor, own):
    if len(impostor) < 200 or len(own) < 50:
        raise ValueError("Calibration needs at least 200 impostor and 50 same-speaker pairs")
    if not all(math.isfinite(score) and -1.000001 <= score <= 1.000001 for score in impostor + own):
        raise ValueError("Invalid cosine score")
    candidates = sorted({0.0, 1.0, *[math.nextafter(float(score), math.inf) for score in impostor + own if 0 <= score < 1]})
    curve = [[threshold, sum(score >= threshold for score in impostor) / len(impostor), sum(score >= threshold for score in own) / len(own)] for threshold in candidates]
    eligible = [point for point in curve if point[1] <= 0.01 and point[2] >= 0.95]
    return (eligible[0] if eligible else None), curve
