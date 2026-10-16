# ElevenLabs: the finder's voice lines

The finder speaks 15 short status lines. They are generated **once** with ElevenLabs and
shipped as audio files in `ios/Faith/Finder/Voice/Clips/`. At runtime the app only plays files:

- no ElevenLabs call, no latency and no Wi-Fi needed during a search,
- no API key inside the app,
- the whole set is 755 characters of text, paid once. Asking again costs nothing.

"Previously found N minutes ago" would need live text to speech for every possible N. Instead N is
rounded to one of 11 buckets (`VoicePrompt.minuteBuckets`), so a fixed clip covers each case.

## Which ElevenLabs API, and how to pick it yourself

ElevenLabs has several APIs. We need exactly one:

| API | What it does | Billed by | Do we need it? |
|---|---|---|---|
| **Text to Speech**, "Create speech": `POST /v1/text-to-speech/{voice_id}` | Text in, one audio file out | Characters of text | **Yes.** 15 requests, once. |
| Text to Speech streaming / WebSocket | Same, audio arrives while it is generated | Characters | No. Only worth it for long or changing text. |
| Agents (conversational AI) | A live voice agent that listens and answers | Minutes of conversation | No. The finder never holds a conversation, and this is the expensive one. |
| Speech to Text | Audio in, transcript out | Audio duration | No. The phone's own recognizer does this for free (`VoiceCommandListener`). |
| Voices: `GET /v2/voices` | Lists the voices your account can use | Free | Only to choose a voice (`--list-voices`). |

How to check this for a new need: open the API reference at https://elevenlabs.io/docs/api-reference
and find the section that matches the direction of the data (text to audio = Text to Speech, audio
to text = Speech to Text, back-and-forth = Agents). Then look at what it is billed by. If the text
is known in advance, generate it once and ship the file, like here.

Pages used for this setup:
- Create speech: https://elevenlabs.io/docs/api-reference/text-to-speech/convert
- Models: https://elevenlabs.io/docs/models
- List voices: https://elevenlabs.io/docs/api-reference/voices/search
- API keys: https://elevenlabs.io/docs/api-reference/authentication

## Generate the clips

1. **Create an API key** in the ElevenLabs app (Developers, then API Keys). When creating it you can
   restrict which endpoints it may use and set a credit limit: allow Text to Speech (and reading
   voices, for `--list-voices`), and a limit of 2,000 credits is plenty.

2. **Give the key to the script**, without committing it. Either for one command:
   ```bash
   ELEVENLABS_API_KEY=sk_... python3 scripts/make_voice_clips.py --dry-run
   ```
   or put one line in `.env` at the repo root (`.env` is gitignored):
   ```
   ELEVENLABS_API_KEY=sk_...
   ```

3. **Preview** what will be sent. Nothing is sent or charged:
   ```bash
   python3 scripts/make_voice_clips.py --dry-run
   ```

4. **Optional: choose a voice.** All clips must share one voice.
   ```bash
   python3 scripts/make_voice_clips.py --list-voices
   ```
   The default is `EXAVITQu4vr4xnSDxMaL` ("Sarah", one of ElevenLabs' standard female voices), which is
   what the shipped clips use. To use another, add `--voice <voice_id>` in the next step.
   `--list-voices` needs a key that is allowed to read voices; a key restricted to Text to Speech
   answers 401. Voice IDs can also be copied from the Voices page of the ElevenLabs app.

5. **Generate.**
   ```bash
   python3 scripts/make_voice_clips.py
   ```
   It writes the 15 `.wav` files (mono, 24 kHz, silence trimmed, peak at -1 dBFS) and skips any that
   already exist.

6. **Listen, then build.**
   ```bash
   afplay ios/Faith/Finder/Voice/Clips/voice_found_navigating.wav
   xcodegen generate
   ```
   `VoicePromptPlayerTests.testEveryVoiceClipLoadsFromTheBundle` passes once all 15 are there.

7. **Commit the `.wav` files, not the key.**

## Changing things later

- One line sounds wrong: `python3 scripts/make_voice_clips.py --only voice_okay --force`
- A different voice: `python3 scripts/make_voice_clips.py --voice <voice_id> --force` (redoes all 15,
  755 characters again).
- Better quality at about twice the price per character: `--model eleven_multilingual_v2` or
  `--model eleven_v4`. The default `eleven_flash_v2_5` is the cheapest; the script spells numbers
  out ("fifteen minutes") because the Flash models do not read digits reliably.
- New wording or a new line: the texts live in `voice_lines()` in `scripts/make_voice_clips.py`, the
  clip names in `VoicePrompt` (`ios/Faith/Finder/Contracts/Models.swift`).

## The lines

| Clip | Text |
|---|---|
| `voice_not_found_turn` | Item not found, please turn. |
| `voice_found_navigating` | Item found, navigating. |
| `voice_navigating` | Navigating. |
| `voice_okay` | Okay. |
| `voice_previously_found_0m` | Item was previously found less than a minute ago. Want to navigate? |
| `voice_previously_found_1m` | Item was previously found one minute ago. Want to navigate? |
| `voice_previously_found_Nm`, N = 2, 3, 5, 10, 15, 20, 30, 45 | Item was previously found N minutes ago. Want to navigate? |
| `voice_previously_found_60m` | Item was previously found about an hour ago. Want to navigate? |

## How the app uses them

`VoicePromptPlayer` (`ios/Faith/Finder/Voice/VoicePromptPlayer.swift`) implements `VoicePromptPlaying`: it
loads the clips at start, plays one centered over the audio module's session, turns the cue down to
30% while it plays, and returns when the line ends. A missing clip is logged and skipped.
