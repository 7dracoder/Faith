# Faith development

Faith is an accessible ticket-booking app with a SwiftUI client, a browser demo, and a FastAPI booking API.

- Keep user-visible feedback available as text. Voice, sound, vibration, and motion are optional enhancements.
- Motion may change focus but must never confirm or purchase. Typed, dictated, or AI-generated requests only prepare a search.
- All current inventory is fictional. Always retain demo and non-admission notices until a real supplier integration is implemented and independently verified.
- Server-generated quotes own prices and expire. Confirmation must require explicit acknowledgement and remain idempotent.
- Test session ownership, duplicate confirmation, cancellation, pricing, expiry, and every ticket category when changing booking behavior.
- Never commit environment files, AWS tokens, provider keys, local databases, or generated Xcode projects. Never embed service secrets in clients.
- Do not send raw text, motion, audio, access preferences, session tokens, or identity to traces. Optional integrations must have honest disabled/failure states.
- Run backend tests and local synthetic evaluations. Run browser flow and accessibility checks for interface changes. Build and test iOS when Xcode is available; report unavailable checks accurately.
