# Voice

Two halves: hearing the user (on the phone, free) and talking back (recorded ElevenLabs lines).

```
hold push-to-talk, say "where's my mug", release
   -> VoiceCommandListener (on-device speech) returns the transcript
   -> coordinator: snapshot, locator (vision model), place
   -> a recorded voice line says how it went, then the beeping starts
```

## Hearing: `VoiceCommandListener` + `AppleSpeechBackend`

`SFSpeechRecognizer` on its own `AVAudioEngine` input tap, on-device when the phone supports it.
Release returns the final wording, or the best partial after 1 s. The microphone closes by itself 6 s
after the press. The recognizer is primed with the known objects, "found" / "calibrate", and the
yes / no answers to "want to navigate?".

## Talking: `VoicePromptPlayer`

Plays the 15 pre-recorded `VoicePrompt` lines from `Voice/Clips/`. **How the clips are made, which
ElevenLabs API is used and why: [ELEVENLABS.md](ELEVENLABS.md).** No ElevenLabs call and no API key at runtime.

The cue is turned down to 30% while a line plays (`CueDucking`, implemented by `SpatialAudioEngine`),
`play` returns when the line ends, and a new line cuts off the current one.

## Who says the lines, and when

The full flow is the coordinator's: found, not found, and "previously found N
minutes ago, want to navigate?" with a spoken yes / no. When that lands, the wiring is one line in
`AppEnvironment`:

```swift
let voicePrompts: VoicePromptPlaying = VoicePromptPlayer.make(audio: audio) ?? MockVoicePromptPlayer()
```

`make` returns nil for mock audio, so all-mocks builds keep the mock.

Until then, `AnnouncingLocator` is a stopgap that plays two of the lines around the locator:
"Item found, navigating." before the beeping and "Item not found, please turn." on `.objectNotFound`.
It is on only when `announcements` is listed in `FINDER_REAL_SERVICES`. **Remove it when the
coordinator flow merges** (its `wrapIfEnabled` line in `AppEnvironment`, the `announcements` name,
and the file), or both would speak.

## Switching it on

In the gitignored `ios/Config/Local.xcconfig`:

```
FINDER_REAL_SERVICES = perception locator audio headTracking voice announcements
```

- `voice` needs `audio`: the Audio module owns the audio session and enables the microphone. Device only.
- `locator` needs `GEMINI_API_KEY` in `Secrets.xcconfig`. Without it the mock locator answers: it
  "finds" everything except a request containing "unicorn", which is a quick way to hear the not-found line.

## Testing on the phone

- The status line shows `Listening…`, then `Locating "<what was heard>"…`, so a wrong transcript is visible at once.
- Console categories: `VoiceListener`, `SpeechBackend`, `VoicePrompt`.
- Ask for an object on the table ("Item found, navigating.", then beeping). Ask for a "unicorn", or
  turn away with the real locator ("Item not found, please turn.").
- Check: the lines come through the AirPods, and during a round the cue gets quieter under a line and comes back.
