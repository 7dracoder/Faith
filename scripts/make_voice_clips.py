#!/usr/bin/env python3
"""Generate the finder's 4 voice lines with ElevenLabs. Standard library only.

    python3 scripts/make_voice_clips.py --dry-run        # list the lines and their cost, send nothing
    python3 scripts/make_voice_clips.py --list-voices    # voices your key can use
    python3 scripts/make_voice_clips.py                  # generate what is missing
    python3 scripts/make_voice_clips.py --only voice_navigating --force   # redo one line

Writes ios/Faith/Finder/Voice/Clips/<clipName>.wav: mono, silence trimmed, peak at -1 dBFS.
Clips that already exist are skipped, so running it again costs nothing.

The API key is read from the ELEVENLABS_API_KEY environment variable, or from a line
ELEVENLABS_API_KEY=... in the gitignored .env at the repo root. It is only used by this
script: commit the .wav files, never the key. Full instructions: ios/Faith/Finder/Voice/ELEVENLABS.md

The clip names must match VoicePrompt.allClipNames in ios/Faith/Finder/Contracts/Models.swift
(VoicePromptPlayerTests fails if a clip is missing).
"""
import argparse
import array
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import wave

API_BASE = "https://api.elevenlabs.io"
REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CLIPS_DIR = os.path.join(REPO_ROOT, "ios", "Faith", "Finder", "Voice", "Clips")

# One voice and one group of settings for every clip, so they sound like one speaker.
DEFAULT_VOICE_ID = "EXAVITQu4vr4xnSDxMaL"  # "Sarah", one of ElevenLabs' standard female voices
DEFAULT_MODEL_ID = "eleven_flash_v2_5"     # lowest price per character; see ELEVENLABS.md for others
SAMPLE_RATE = 24000                        # pcm_24000: raw 16-bit mono, available on every plan
VOICE_SETTINGS = {
    "stability": 0.5,
    "similarity_boost": 0.75,
    "style": 0,
    "use_speaker_boost": True,
    "speed": 1.0,
}
SEED = 2026

PEAK = 0.891            # -1 dBFS
SILENCE = 0.02          # below 2% of the loudest sample counts as silence
LEAD_IN_SECONDS = 0.005
TAIL_SECONDS = 0.06
FADE_SECONDS = 0.005


def voice_lines():
    """(clip name, text sent to ElevenLabs), in playback order."""
    lines = [
        ("voice_searching", "Searching."),
        ("voice_not_found_turn", "Item not found, please turn."),
        ("voice_found_navigating", "Item found, navigating."),
        ("voice_navigating", "Navigating."),
    ]
    return lines


def read_api_key():
    key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    if key:
        return key
    env_path = os.path.join(REPO_ROOT, ".env")
    if os.path.exists(env_path):
        with open(env_path, encoding="utf-8") as env_file:
            for line in env_file:
                name, _, value = line.strip().partition("=")
                if name.strip() == "ELEVENLABS_API_KEY":
                    return value.strip().strip("\"'")
    return ""


def request(method, path, api_key, payload=None):
    data = None
    headers = {"xi-api-key": api_key}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    call = urllib.request.Request(API_BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(call, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        sys.exit("ElevenLabs answered {} for {} {}:\n{}".format(error.code, method, path, body))
    except urllib.error.URLError as error:
        sys.exit("Could not reach ElevenLabs: {}".format(error.reason))


def list_voices(api_key):
    raw = request("GET", "/v2/voices?page_size=100", api_key)
    voices = json.loads(raw.decode("utf-8")).get("voices", [])
    for voice in voices:
        labels = voice.get("labels") or {}
        details = ", ".join(str(value) for value in labels.values())
        print("{}  {:<24} {:<12} {}".format(
            voice.get("voice_id", ""), voice.get("name", ""), voice.get("category", ""), details))
    print("\n{} voices. Use one with: --voice <voice_id> --force (all clips must share one voice).".format(len(voices)))


def synthesize(text, voice_id, model_id, api_key):
    """Returns the line as 16-bit mono samples at SAMPLE_RATE."""
    query = urllib.parse.urlencode({"output_format": "pcm_{}".format(SAMPLE_RATE)})
    path = "/v1/text-to-speech/{}?{}".format(urllib.parse.quote(voice_id), query)
    payload = {
        "text": text,
        "model_id": model_id,
        "voice_settings": VOICE_SETTINGS,
        "seed": SEED,
    }
    raw = request("POST", path, api_key, payload)
    samples = array.array("h")
    samples.frombytes(raw[: len(raw) - (len(raw) % 2)])
    if sys.byteorder == "big":
        samples.byteswap()   # the API sends little-endian
    return samples


def polish(samples):
    """Trims silence (latency matters), sets the peak to -1 dBFS, and fades the edges."""
    loudest = max((abs(sample) for sample in samples), default=0)
    if loudest == 0:
        sys.exit("ElevenLabs returned silence.")
    threshold = loudest * SILENCE

    first = 0
    while abs(samples[first]) < threshold:
        first += 1
    last = len(samples) - 1
    while abs(samples[last]) < threshold:
        last -= 1

    start = max(0, first - int(LEAD_IN_SECONDS * SAMPLE_RATE))
    end = min(len(samples), last + 1 + int(TAIL_SECONDS * SAMPLE_RATE))
    gain = (PEAK * 32767.0) / loudest
    trimmed = [sample * gain for sample in samples[start:end]]

    fade = min(int(FADE_SECONDS * SAMPLE_RATE), len(trimmed) // 2)
    for index in range(fade):
        factor = index / float(fade)
        trimmed[index] *= factor
        trimmed[len(trimmed) - 1 - index] *= factor

    return array.array("h", (int(round(value)) for value in trimmed))


def write_wav(path, samples):
    if sys.byteorder == "big":
        samples = array.array("h", samples)
        samples.byteswap()
    with wave.open(path, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(SAMPLE_RATE)
        wav_file.writeframes(samples.tobytes())


def main():
    parser = argparse.ArgumentParser(description="Generate the finder's voice lines with ElevenLabs.")
    parser.add_argument("--dry-run", action="store_true", help="list the lines and their cost, send nothing")
    parser.add_argument("--list-voices", action="store_true", help="list the voices your key can use")
    parser.add_argument("--voice", default=os.environ.get("ELEVENLABS_VOICE_ID", DEFAULT_VOICE_ID))
    parser.add_argument("--model", default=os.environ.get("ELEVENLABS_MODEL_ID", DEFAULT_MODEL_ID))
    parser.add_argument("--only", action="append", default=[], metavar="CLIP", help="only this clip name (repeatable)")
    parser.add_argument("--force", action="store_true", help="regenerate clips that already exist")
    arguments = parser.parse_args()

    if arguments.list_voices:
        api_key = read_api_key()
        if not api_key:
            sys.exit("No API key. Set ELEVENLABS_API_KEY or add it to .env (see ios/Faith/Finder/Voice/ELEVENLABS.md).")
        list_voices(api_key)
        return

    lines = voice_lines()
    names = [name for name, _ in lines]
    for wanted in arguments.only:
        if wanted not in names:
            sys.exit("Unknown clip {}. Clips: {}".format(wanted, ", ".join(names)))

    todo = []
    for name, text in lines:
        if arguments.only and name not in arguments.only:
            continue
        path = os.path.join(CLIPS_DIR, name + ".wav")
        exists = os.path.exists(path)
        if exists and not arguments.force:
            print("have   {:<30} {}".format(name, text))
            continue
        todo.append((name, text, path))
        print("{}  {:<30} {}".format("redo " if exists else "make ", name, text))

    characters = sum(len(text) for _, text, _ in todo)
    print("\n{} of {} clips to generate, {} characters, voice {}, model {}.".format(
        len(todo), len(lines), characters, arguments.voice, arguments.model))

    if arguments.dry_run:
        return

    api_key = read_api_key()
    if not api_key:
        sys.exit("No API key. Set ELEVENLABS_API_KEY or add it to .env (see ios/Faith/Finder/Voice/ELEVENLABS.md).")

    os.makedirs(CLIPS_DIR, exist_ok=True)
    for name, text, path in todo:
        samples = polish(synthesize(text, arguments.voice, arguments.model, api_key))
        write_wav(path, samples)
        print("wrote  {:<30} {:.2f} s".format(name + ".wav", len(samples) / float(SAMPLE_RATE)))

    if todo:
        print("\nListen: afplay ios/Faith/Finder/Voice/Clips/voice_found_navigating.wav")
        print("Then xcodegen generate, build, and commit the .wav files (not the key).")


if __name__ == "__main__":
    main()
