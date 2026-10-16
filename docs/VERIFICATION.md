# Faith verification

## October 16, 2026

Automated:

- 110 backend tests pass locally and in a Daytona test sandbox: booking flow and idempotency, every category, session ownership, the agent token endpoint, preference memory (mocked SurrealDB: hashed session key, no raw token stored, per-session isolation, rejects location and object fields, honest failures), object memory (scans store nothing and never echo the image, people and low-confidence objects dropped, per-session scan limit, hashed record holding only labels, places, times, and positions, rejects pictures and free text, forget), live search (every category, fixed provider hosts, structured options cleaned and capped, prices that aren't amounts dropped, fallback to the next provider, Anchor browser closed after each task, cache and rate limits, honest failure), saved trips (only options from the session's own search, hashed key, never paid), real-time search (mocked Anchor: fixed sites, flights and events declined, no user URLs, cache, rate limits, read-only prompt), accessibility lookups, Baseten vision (data URL, reasoning off, strict boxes), and security headers.
- Synthetic intent evaluation: 5 of 5.
- 218 iOS unit tests pass on a physical iPhone 17, including haptic guidance pulses (faster and stronger when closer, a soft double tap when facing away), a live find when memory has no position from this session, reaching the object (chime, “Found it”, back to the hold-to-talk screen; brushing past doesn’t count), live option decoding and provider links, routing between objects and bookings, sending the view as soon as the user lets go, answering from object memory (guidance only within the same AR session), periodic memory snapshots and their on-phone picture limit, “stop/start remembering” and “forget what you’ve seen”, spoken-yes and save-consent checks, preference encoding, and the finder’s geometry, audio, memory, and voice tests.

Live, against real services from the development Mac:

- ElevenLabs: agent updated with eleven client tools (including `search_live_tickets` with a 120-second timeout, `choose_live_option`, `save_trip`, and `check_venue_accessibility`), conversation tokens issued through the backend.
- Baseten Kimi-K3: found a mug in a test photo with a correct box in about 6 to 8 seconds; correctly reported keys as not visible.
- Baseten Kimi-K3 object scan: listed 9 objects with place descriptions from a desk photo in about 10 seconds.
- SurrealDB Cloud: booking mirror written and read back; preferences saved, read, and forgotten; object memory stored, recalled by name, and forgotten.
- Anchor live search, through the backend's own code: Google Flights, New York to Chicago, 5 flights with prices in 27 s; Wanderu, Boston to New York, 2 Amtrak trains with prices in 31 s; Greyhound, New York to Philadelphia, 5 buses with prices in 34 s; Fandango, Chicago, 5 showtimes in 68 s (no prices shown); Eventbrite, Boston, 3 events with prices in 65 s. Ticketmaster, SeatGeek, Songkick, Google events, AMC, and Amtrak’s own site returned no results and are not used.
- Through the Cloudflare tunnel: a live Boston to New York bus search (33 s), then saving the first option as a trip in SurrealDB Cloud and reading it back; an invented option ID was refused.

Live, on the Daytona-hosted backend:

- `/health`, `/api/capabilities`, conversation tokens, and demo bookings work.
- Object location, preference memory, the SurrealDB mirror, and Anchor lookups fail there because the sandbox cannot open connections to Baseten, SurrealDB Cloud, or Anchor (ElevenLabs, Arize, and PyPI are reachable). This matches Daytona’s restricted network access on lower account tiers. Until the Daytona organization has full internet access, point the app at a backend running on the Mac for those features.

## Still required on a real iPhone

- Camera capture, image orientation, depth and surface placement, spatial audio, AirPods head tracking, and haptics.
- The hand-off of audio between the voice agent and the finder.
- Hold, double-tap, and VoiceOver gestures with blind and low-vision participants.
