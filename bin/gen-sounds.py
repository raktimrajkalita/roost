#!/usr/bin/env python3
"""
Synthesize Roost's original metallic-shine chimes (no dependencies, no samples).

Additive synthesis: a struck bell built from inharmonic partials, plus a blooming
shimmer of detuned high partials for the "shine". Everything here is generated
from math, so it's royalty-free and yours to ship.

Usage:
    python3 gen-sounds.py [output_dir]
Defaults to ~/.claude-notch/sounds
"""
import math, struct, wave, os, sys

SR = 44100
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude-notch/sounds")
GAIN = 0.5   # overall level (0..1). Lower = quieter.
os.makedirs(OUT, exist_ok=True)


def render(path, partials, dur, drive=0.0):
    """partials: list of (freq_hz, amp, decay, delay_s, bloom_s)."""
    n = int(SR * dur)
    samples, peak = [], 1e-9
    for i in range(n):
        t = i / SR
        s = 0.0
        for p in partials:
            f, amp, decay = p[0], p[1], p[2]
            delay = p[3] if len(p) > 3 else 0.0
            bloom = p[4] if len(p) > 4 else 0.004
            lt = t - delay
            if lt < 0:
                continue
            env = math.exp(-lt * decay)
            if bloom > 0 and lt < bloom:
                env *= (lt / bloom)
            s += amp * env * math.sin(2 * math.pi * f * lt)
        if drive:
            s = math.tanh(s * (1 + drive)) / math.tanh(1 + drive)
        samples.append(s)
        peak = max(peak, abs(s))
    g = (GAIN * 0.82) / peak
    buf = bytearray()
    for s in samples:
        buf += struct.pack('<h', int(max(-1.0, min(1.0, s * g)) * 32767))
    with wave.open(path, 'w') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(bytes(buf))
    print("wrote", path)


# DONE - metallic shine: struck bell + blooming detuned high shimmer
base = 880.0  # A5
done = [
    (base * 1.00, 1.00, 5.0, 0.0, 0.003),
    (base * 2.00, 0.50, 6.5, 0.0, 0.003),
    (base * 2.76, 0.40, 8.0, 0.0, 0.003),
    (base * 3.76, 0.28, 9.5, 0.0, 0.003),
    (base * 5.40, 0.20, 6.0, 0.02, 0.06),
    (base * 5.43, 0.18, 6.0, 0.03, 0.07),
    (base * 7.20, 0.15, 6.5, 0.04, 0.08),
    (base * 8.93, 0.13, 7.0, 0.05, 0.09),
    (base * 8.99, 0.12, 7.0, 0.06, 0.10),
    (base * 11.8, 0.09, 8.0, 0.07, 0.10),
    (base * 15.2, 0.06, 9.0, 0.09, 0.12),
]
render(os.path.join(OUT, "done.wav"), done, dur=1.5, drive=0.12)

# WAITING - softer, lower "needs you" shimmer
w1 = 587.33  # D5
waiting = [
    (w1 * 1.00, 0.9, 7.0, 0.0, 0.004),
    (w1 * 1.50, 0.5, 8.0, 0.0, 0.004),
    (w1 * 2.76, 0.22, 10.0, 0.02, 0.05),
    (w1 * 4.10, 0.16, 10.0, 0.04, 0.07),
    (w1 * 4.13, 0.15, 10.0, 0.05, 0.08),
]
render(os.path.join(OUT, "waiting.wav"), waiting, dur=0.7, drive=0.06)
