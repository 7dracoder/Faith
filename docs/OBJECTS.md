# Faith object finding

## Using it

1. Hold anywhere and say the object, like “where did I leave my keys”. Let go.
2. Faith looks in object memory first (the phone’s copy, then the backend’s). If found it says, for example, “I last saw your keys on the kitchen counter, 3 minutes ago.” If the position was measured in the current AR session it says “Navigating” and guides you there; otherwise the words are all it can honestly give.
3. If memory has nothing, the view captured when you let go is sent right away (asking is the consent). Faith says “Searching”, then “Item found, navigating” or “Item not found, please turn”.
4. The sound comes from the object’s direction and pulses faster as you face it. AirPods head tracking steers it when available. Say “found” when you have it.

## Object memory

- While the finder is open, the camera is tracking normally, and no request is running, Faith takes a snapshot at most every 5 seconds, and only when the phone moved 0.5 m, turned 25°, or 30 seconds passed.
- The JPEG and its AR camera pose are saved in Application Support (excluded from backup). The phone keeps the newest 200 for at most 24 hours.
- `POST /api/objects/scan` sends the picture to Baseten Kimi-K3, which lists everyday objects with boxes and a short place description. People, faces and documents are excluded, and confidence below 0.65 is dropped. The backend does not store or log the picture. Limits: 20 per session per minute, 600 per hour overall.
- The phone places each box in the AR world from the snapshot's own pose. It keeps label, place, time and position, and sends them to `POST /api/objects/memory` (SurrealDB, keyed by a hash of the session). There they keep the newest sighting per object for 7 days.
- Spoken controls: “stop remembering”, “start remembering” (persisted), and “forget what you’ve seen”, which deletes the pictures, the phone’s memory, and the SurrealDB record. The first launch announces the feature once.
- Capture never runs on the booking screen or in the background.

## How the position is found

The snapshot carries its own camera pose, intrinsics, and depth (LiDAR when available). The vision model returns only a 2D box in the upright image. The phone maps the box centre into the camera’s sensor space and finds the world point with valid depth, or by raycasting onto an already detected surface from the saved pose. If neither works, there is no target: Faith never invents a distance or uses a fixed-depth fallback.

## Boundaries

- Faith only sends pictures after you ask, plus the memory snapshots above, which are announced once and can be turned off by voice. The backend never stores, logs, mirrors, or traces pictures; traces carry only counts.
- AR positions are only used for guidance within the AR session that measured them. A new session starts when the camera restarts, tracking resets, or the app returns from the booking screen or background. Older sightings are spoken, not guided to. Late results from an old AR session are discarded.
- No camera or spatial telemetry is sent anywhere.
- Guidance is experimental. It is not obstacle detection, a safe route, or a cane or guide-dog replacement. Objects may have moved and the model can be wrong. Do not test near stairs, streets, or other hazards.

## Tests

Unit tests cover image-to-sensor mapping, ray and depth maths, head-rotation and listener-pose maths, the cue, memory matching and sentences, the capture policy, the on-phone picture store (limits, backup exclusion, forget), memory-first answers, auto-send, voice memory commands, and routing between objects and bookings. Backend tests mock the vision provider and SurrealDB and cover scans storing nothing, hashed memory records, recall, delete, rate limits, schema bounds, low confidence, limits, and failures without echoing the image. Real-device accuracy, audio, and head tracking still need testing on an iPhone with blind participants.
