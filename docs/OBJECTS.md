# Faith object finding

## Using it

1. Hold anywhere and say the object, like “where’s my mug”. Let go.
2. Faith captures one view and asks “Send this view to find it?” Hold the screen or say yes to send it; double tap or say no to drop it. The offer expires after 30 seconds.
3. Faith says “Searching”, then either “Item found, navigating” and starts the guidance sound, or “Item not found, please turn”.
4. The sound comes from the object’s direction and pulses faster as you face it. AirPods head tracking steers it when available. Say “found” when you have it.
5. If the object isn’t in view but was seen earlier this session, Faith offers the last-known spot and waits for yes or no.

## How the position is found

The snapshot carries its own camera pose, intrinsics, and depth (LiDAR when available). The vision model returns only a 2D box in the upright image. The phone maps the box centre into the camera’s sensor space and finds the world point with valid depth, or by raycasting onto an already detected surface from the saved pose. If neither works, there is no target: Faith never invents a distance or uses a fixed-depth fallback.

## Boundaries

- Only the one frame you approve leaves the phone, sent to Faith’s backend and on to Baseten. Faith does not store, log, mirror, or trace frames or object names.
- Positions, last-seen memories, and pending frames stay on the phone. They are cleared when tracking resets or is interrupted, when you leave the finder or start a booking, and when the app is backgrounded. Late results from an old AR session are discarded.
- No camera or spatial telemetry is sent anywhere.
- Guidance is experimental. It is not obstacle detection, a safe route, or a cane or guide-dog replacement. Objects may have moved and the model can be wrong. Do not test near stairs, streets, or other hazards.

## Tests

Unit tests cover image-to-sensor mapping, ray and depth maths, head-rotation and listener-pose maths, the cue, memory matching, the consent step (send, decline, expiry, cancel), recalled-spot offers, and routing between objects and bookings. Backend tests mock the vision provider and cover consent, schema bounds, low confidence, limits, and failures without echoing the image. Real-device accuracy, audio, and head tracking still need testing on an iPhone with blind participants.
