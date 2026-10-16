#!/usr/bin/env python3
"""Synthesize the bright bell played when the user reaches the object. Standard library only.

    python3 scripts/make_found_chime.py

Writes ios/Faith/Finder/Resources/Sounds/earcon_found.wav: 48 kHz mono, about 1.2 s, peak at -1 dBFS.
"""
import array
import math
import os
import wave

RATE = 48000
SECONDS = 1.2
FUNDAMENTAL = 1568.0  # G6: bright, but not piercing on the phone speaker
# Inharmonic bell partials: (frequency ratio, level, decay time in seconds).
PARTIALS = [(1.0, 1.0, 0.55), (2.0, 0.45, 0.35), (2.76, 0.3, 0.25), (5.40, 0.12, 0.12), (8.93, 0.06, 0.07)]
ATTACK = 0.004
PEAK = 0.891

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ios", "Faith", "Finder", "Resources",
                   "Sounds", "earcon_found.wav")


def main():
    count = int(RATE * SECONDS)
    samples = []
    for index in range(count):
        t = index / RATE
        value = 0.0
        for ratio, level, decay in PARTIALS:
            # A slight detuned pair per partial gives the shimmer of a struck bell.
            frequency = FUNDAMENTAL * ratio
            value += level * math.exp(-t / decay) * 0.5 * (
                math.sin(2 * math.pi * frequency * t) + math.sin(2 * math.pi * (frequency + 2.5) * t))
        value *= min(1.0, t / ATTACK)
        tail = SECONDS - t
        value *= min(1.0, tail / 0.05)
        samples.append(value)
    loudest = max(abs(value) for value in samples)
    pcm = array.array("h", (int(round(value / loudest * PEAK * 32767)) for value in samples))
    with wave.open(os.path.normpath(OUT), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(RATE)
        wav_file.writeframes(pcm.tobytes())
    print("wrote", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
