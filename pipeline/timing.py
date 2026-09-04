"""Deriving a constant frame rate that can represent a camera's real cadence.

Split out of finish.sh so it can be unit-tested. The bug that prompted it only appears
over a long clip, which makes it expensive to catch any other way: a 190-frame slice
looked perfect while the full 1480-frame render drifted by a millisecond.
"""
from fractions import Fraction

# Denominator limit for snapping a measured rate to a rational. 1001 covers the NTSC
# family (30000/1001, 24000/1001 and friends) without being loose enough to invent a
# relationship that is not there.
MAX_DENOMINATOR = 1001

# A measured rate this far from its rational form is not rounding noise, it is a
# different rate, and snapping would silently change the timing.
SNAP_TOLERANCE = 0.01


def base_rate(gaps):
    """The frame rate whose period divides every gap, as an exact Fraction.

    `gaps` are the source's inter-frame intervals in seconds, as read from ffprobe -
    which prints six decimal places, so a true 1/15 gap arrives as 0.066666 and 1/gap
    comes out as 15.000150002 rather than 15.

    Feeding that to ffmpeg's -r is not harmless. Every frame is then 1/15.000150002 of
    a second instead of 1/15, and the error accumulates: over the 1556 frames of the
    full clip it reached 1.037ms, growing linearly from the start (r = 1.000 against
    frame index). Snapping to the nearest rational removes it entirely, while leaving
    genuinely non-integer rates like 15000/1001 alone.
    """
    if not len(gaps):
        raise ValueError("no gaps to derive a rate from")
    shortest = min(gaps)
    if shortest <= 0:
        raise ValueError(f"shortest gap must be positive, got {shortest}")

    measured = 1.0 / shortest
    snapped = Fraction(measured).limit_denominator(MAX_DENOMINATOR)
    if abs(float(snapped) - measured) > SNAP_TOLERANCE:
        # Nothing simple is close by; keep what was measured rather than distort it.
        return Fraction(measured).limit_denominator(1000000)
    return snapped


def repeats(gaps, terminal, rate):
    """How many frames at `rate` each source frame should occupy.

    Returns (counts, worst_error_in_frames). The caller decides what to do with the
    error: a source whose gaps are not whole multiples of one frame period cannot be
    represented exactly at a constant rate, and should be refused rather than rounded.
    """
    r = float(rate)
    spans = list(gaps) + [terminal]
    counts = [max(1, round(s * r)) for s in spans]
    worst = max(abs(s * r - round(s * r)) for s in spans)
    return counts, worst
