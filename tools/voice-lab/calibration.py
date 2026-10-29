import math
import bisect

FAR_LIMIT = 0.005
OWN_LIMIT = 0.95
MARGIN_FLOOR = 0.002


def conditions_pass(conditions):
    return bool(conditions) and all(item.get("impostorPairs", 0) >= 200 and item.get("sameSpeakerPairs", 0) >= 50
                                    and math.isfinite(item["falseAcceptRate"]) and 0 <= item["falseAcceptRate"] <= FAR_LIMIT
                                    and math.isfinite(item["sameSpeakerPassRate"]) and OWN_LIMIT <= item["sameSpeakerPassRate"] <= 1
                                    for item in conditions)


def rates(impostor, own, threshold):
    impostor, own = sorted(impostor), sorted(own)
    return [(len(impostor) - bisect.bisect_left(impostor, threshold)) / len(impostor),
            (len(own) - bisect.bisect_left(own, threshold)) / len(own)]


def choose_threshold(impostor, own, runtime_drift=0):
    if len(impostor) < 200 or len(own) < 50:
        raise ValueError("Calibration needs at least 200 impostor and 50 same-speaker pairs")
    if not all(math.isfinite(score) and -1.000001 <= score <= 1.000001 for score in impostor + own):
        raise ValueError("Invalid cosine score")
    if not math.isfinite(runtime_drift) or runtime_drift < 0:
        raise ValueError("Invalid runtime drift")
    margin = max(MARGIN_FLOOR, runtime_drift)
    threshold = max(0, max(impostor) + margin)
    candidates = sorted({0.0, 1.0, threshold, *[index / 1000 for index in range(1001)]})
    curve = [[candidate, *rates(impostor, own, candidate)] for candidate in candidates]
    point = [threshold, *rates(impostor, own, threshold)]
    eligible = 0 <= threshold <= 1 and point[1] <= FAR_LIMIT and point[2] >= OWN_LIMIT
    return (point if eligible else None), curve
