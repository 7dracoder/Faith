# Faith development

Faith is a blind-first iPhone app: hold anywhere and speak. Object requests go to the object finder (ARKit, spatial audio, AirPods head tracking); ticket requests go to an ElevenLabs voice agent whose tools run in the app against the Faith backend. There is no web client.

- Every spoken or audio state also has visible text and a VoiceOver label or action.
- Motion must never confirm or purchase. A booking is confirmed only by a 1.5 s hold on the quote screen or by the user's own spoken yes after the quote (checked in the app, never trusted from the agent alone). A double tap rejects the quote.
- Preserve object remembrance alongside ticketing. Camera/world coordinates must never cross AR session generations. Clear targets and memory when tracking is reset, interrupted, backgrounded, or the object area is left. Never invent metric distances or use fixed-depth fallback points for guidance.
- Object guidance is experimental, not obstacle detection or a safe route. Require explicit acceptance for recalled spots, user confirmation of found objects, and per-frame consent before cloud recognition. No camera/spatial telemetry or automatic image uploads.
- Preference memory holds only home city, step-free, audio description, companion seat, and usual party size, saved only when the user asks or agrees, keyed by a hash of the session. Never store objects, frames, or location there. Real-time and accessibility lookups are read-only and never bookable.
- All current inventory is fictional. Always retain demo and non-admission notices until a real supplier integration is implemented and independently verified.
- Server-generated quotes own prices and expire. Confirmation must require explicit acknowledgement and remain idempotent.
- Test session ownership, duplicate confirmation, cancellation, pricing, expiry, and every ticket category when changing booking behavior.
- Never commit environment files, AWS tokens, provider keys, local databases, or generated Xcode projects. Never embed service secrets in clients.
- Do not send raw text, motion, audio, access preferences, session tokens, or identity to traces. Optional integrations must have honest disabled/failure states.
- Run backend tests and local synthetic evaluations. Build and test iOS when Xcode is available; report unavailable checks accurately.
