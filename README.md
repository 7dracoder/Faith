# Faith

**Your world, your way.**

[![Faith checks](https://github.com/7dracoder/Faith/actions/workflows/ci.yml/badge.svg)](https://github.com/7dracoder/Faith/actions/workflows/ci.yml)

Faith is an iPhone app for blind and low-vision people. There is one screen, and the whole screen is the button: **hold anywhere and speak.**

- Say an object, like “where’s my mug”, and Faith finds it with the camera, then guides you to it with sound that comes from the object’s direction.
- Say a ticket request, like “book a train to Boston tomorrow”, and a calm voice agent reads you live options and prices from real provider websites for flights, trains, buses, cinemas, and events.

Faith can’t pay for tickets. Choosing a live option saves the trip and the provider’s link so you can finish booking there. Only if live results fail does it offer fictional practice tickets, and it says so. No payment, real booking, or admission is ever issued by Faith.

The object finder uses ARKit, LiDAR depth when available, AirPods head tracking, haptics, and recorded voice lines. Faith only sends pictures after you ask, plus the object-memory snapshots below, which are announced once and can be turned off by voice. Pictures go through Faith’s backend to a vision model, so no provider key lives on the phone.

## How it works

**Hold to talk.** Hold anywhere, speak, let go. Objects go to the finder; anything about tickets, trips, showtimes, or preferences goes to the booking agent.

**Finding an object**

1. Hold and say the object, like “where did I leave my keys”. Let go.
2. If Faith has seen it, it says so, for example “I last saw your keys on the kitchen counter, 3 minutes ago.” If that spot was measured since the camera last started, it then guides you there; otherwise it still looks with the camera.
3. If it can’t guide from memory, the camera view is sent as soon as you let go (asking is the consent), and Faith says “Item found, navigating” or “Item not found, please turn”.
4. Follow the sound and the vibration: the phone taps about once a second when you’re far away, faster and stronger as you get closer, and a soft double tap means you’re facing away. When the phone is held at the object (within about 25 cm for half a second), Faith rings a bright chime, vibrates, says “Found it”, and goes back to the hold-to-talk screen. You can also say “found”, or use the VoiceOver Magic Tap.

**Object memory.** While the finder is open and the camera is tracking, Faith takes a snapshot every few seconds, but only when the view has changed (you moved or turned) or about 30 seconds have passed. The pictures stay on the phone: the last 200, for at most 24 hours, excluded from iCloud backup. Each snapshot goes once to the vision model to list the objects in it, and is not stored on the server. Only object names, a short place description, the time, and the AR position go to SurrealDB, keyed by a hash of your session. A copy also stays on the phone, so it works offline. Faith announces this once on first launch. Say **“stop remembering”** or **“start remembering”** to turn it off or on, and **“forget what you’ve seen”** to delete the pictures and every remembered object. Capture never runs on the booking screen or in the background.

**Booking a ticket**

1. Hold and say what you want (“book”, “ticket”, “train”, “flight”, “bus”, “movie”, “concert”…). Faith says “Booking assistant” and switches to the mint **Booking** screen; just talk.
2. It says “Checking live times, this takes about a minute”, then reads real options one at a time: provider, time, and price. Sources: Google Flights (flights), Wanderu (trains, including Amtrak), Greyhound with Wanderu as backup (buses), Fandango (cinema showtimes; prices usually not shown), and Eventbrite (events).
3. **Hold the screen for 1.5 seconds to choose** an option, or **double tap to hear another**. Faith saves it as your trip and says “I saved this trip. Faith can’t pay for tickets yet, so I’ve kept the provider link to finish booking.” An **Open provider** button and VoiceOver action then open that site. Saying “yes” or “no” also works, but the app itself checks that *your own words* clearly say yes; the agent cannot choose on its own.
   If live times fail, Faith says “I couldn’t get live times, here’s a practice option” and offers a fictional practice ticket instead, booked the same way and clearly marked as not valid for travel.
4. Ask “how accessible is it really?” and it summarizes the provider’s public accessibility page. That summary is unverified.
5. Say “remember that I live in Boston and need step-free access” and it saves those preferences for next time. It only saves when you ask or say yes, and “forget my preferences” deletes them.
6. Ask it to find an object and it switches to the finder.

VoiceOver: double-tap and hold to talk or to book. Rotor actions include **Stop/Start remembering objects**, **Forget what you’ve seen**, **Choose it** (or **Book practice ticket**), **Hear another option**, **Open provider to finish booking**, and **End conversation**. Every spoken state also appears as large on-screen text.

## Sponsors and how Faith uses them

| Sponsor | What it does in Faith |
| --- | --- |
| **ElevenLabs** | The booking voice agent: a private Conversational AI agent (Sarah voice, slowed and steady for a calm tone) whose client tools run inside the app against Faith’s backend. The backend issues short-lived conversation tokens, so the app never holds the API key. The finder’s recorded voice lines are also ElevenLabs, generated by `scripts/make_voice_clips.py`. |
| **Baseten** | Object location: `moonshotai/Kimi-K3` vision on Baseten’s OpenAI-compatible API returns a bounding box for the frame sent when you ask, and lists the objects (with a short place description) in each object-memory snapshot. Reasoning is off so answers come back in seconds; pictures are never stored. |
| **Daytona** | Hosts the backend in a long-lived sandbox with a public preview URL (`scripts/daytona_host.py`), and runs the test suite in a throwaway cloud sandbox (`scripts/daytona_checks.py`). |
| **SurrealDB** | Stores a minimal copy of each demo booking, the agent’s preference memory (home city, step-free, audio description, companion seat, usual party size), and object memory (object names, place descriptions, times, AR positions; never pictures), each keyed by a hash of the session, never the raw token. |
| **Anchor Browser** | Read-only cloud browser tasks on fixed, allowlisted sites: real train, bus, and cinema times and prices, and providers’ public accessibility pages. It never logs in, fills personal details, or buys. |
| **Arize** | OpenTelemetry traces of each operation (search, quote, booking, vision, lookups) with no user text, audio, images, preferences, or identity. |
| **AWS Bedrock** | Optional fallback for vision and ticket intent. Not configured in the current deployment. |

## Setup

You need Python 3.12+, Xcode 26 with XcodeGen, and an iPhone on iOS 17+ for the camera.

1. **Backend keys.** `cp backend/.env.example backend/.env` and fill in what you have. It is gitignored; never commit it.
   - ElevenLabs: `ELEVENLABS_API_KEY` (and `ELEVENLABS_AGENT_ID`, written by step 2)
   - Baseten: `BASETEN_API_KEY`, `BASETEN_VISION_MODEL=moonshotai/Kimi-K3`
   - SurrealDB: `SURREAL_URL`, `SURREAL_NAMESPACE`, `SURREAL_DATABASE`, `SURREAL_USERNAME`, `SURREAL_PASSWORD` (a database-level user)
   - Anchor: `ANCHOR_API_KEY`
   - Arize: `ARIZE_API_KEY`, `ARIZE_SPACE_ID`, `ARIZE_PROJECT_NAME`
   - Daytona: `DAYTONA_API_KEY`, `DAYTONA_API_URL`
   - Bedrock (optional): `AWS_DEFAULT_REGION`, `BEDROCK_MODEL_ID`, `BEDROCK_VISION_MODEL_ID` with server-side AWS credentials
2. **Install and create the agent.**
   ```sh
   python3 -m venv .venv
   .venv/bin/python -m pip install -r backend/requirements.txt
   .venv/bin/python scripts/elevenlabs_agent.py      # creates or updates the agent and its tools
   .venv/bin/python scripts/make_voice_clips.py      # optional: regenerate the finder's voice lines
   ```
3. **Run the backend.** Either host it on Daytona:
   ```sh
   SSL_CERT_FILE=$(.venv/bin/python -c 'import certifi; print(certifi.where())') .venv/bin/python scripts/daytona_host.py
   ```
   which prints the public URL (secrets go in as sandbox environment variables, never as files; the sandbox stops after 60 idle minutes), or run it locally with `.venv/bin/python -m uvicorn app.main:app --app-dir backend --host 0.0.0.0 --port 8000`.
4. **Build the app.** Copy `ios/Config/Local.xcconfig.example` to `ios/Config/Local.xcconfig` (gitignored), set `FAITH_API_URL` to the Daytona URL (or your Mac’s LAN address) and `DEVELOPMENT_TEAM` to your Apple team, then:
   ```sh
   xcodegen generate
   open Faith.xcodeproj    # choose your iPhone and Run
   ```
   On the phone, enable Developer Mode and trust the developer certificate the first time.

## Checks

```sh
.venv/bin/python -m pytest -q backend/tests
.venv/bin/python scripts/evaluate.py
xcodebuild -scheme Faith -destination 'id=<your iPhone UDID>' -allowProvisioningUpdates test
SSL_CERT_FILE=$(.venv/bin/python -c 'import certifi; print(certifi.where())') .venv/bin/python scripts/daytona_checks.py
```

Backend tests mock every provider. iOS unit tests use the finder’s mock camera and audio, so they also pass while the phone is attached.

## Troubleshooting

- **Launch Faith from the home screen.** AR tracking may not start (“The camera is still starting…” forever) while the app is launched from Xcode or `devicectl`, with a debugger or live console attached. Install the build, unplug the iPhone, and open Faith from the home screen. Likely contributors are the attached debugger, Xcode’s Metal/GPU validation in debug runs, and console log mirroring (`OS_ACTIVITY_DT_MODE`); collect device logs afterwards (`log collect --device`) rather than live-attaching.
- If tracking is still stuck when launched normally, check that Apple’s Measure app works, then restart the iPhone.

## Limitations

- Faith can’t buy tickets. Live options and accessibility summaries are AI readings of public websites: unverified, possibly out of date, and never bought through Faith. Practice tickets are fictional. Ticketmaster, SeatGeek, AMC, and Amtrak’s own site showed the cloud browser nothing, so they aren’t used.
- Object guidance is experimental. It is not obstacle detection or a safe route, objects may have moved, and the vision model can be wrong.
- The camera, depth, spatial audio, head tracking, and the voice agent’s audio still need testing on a real iPhone with blind participants.
- Rate limits and sessions are single-process demo guards, not production accounts or billing controls.

See [architecture](docs/ARCHITECTURE.md), [integrations](docs/INTEGRATIONS.md), [object safety](docs/OBJECTS.md), and [verification](docs/VERIFICATION.md).
