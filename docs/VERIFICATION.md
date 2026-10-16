# Faith verification

## Verified on October 16, 2026

- 44 backend tests passed, including mocked Bedrock, SurrealDB password/token authentication, Anchor, Arize, and ElevenLabs contracts; speech consent/session/write protection, size bounds, sanitized failures, no retries, and per-session/global rate limits.
- 9 browser tests passed in Chromium, including the full booking/cancellation flow, keyboard and mobile layout, contrast checks, network retry, simulated tilt/background shutdown, no-sensor fallback, and speech consent/transcript/no-autoplay/failure states. Synthetic sensor events do not verify physical hardware.
- Automated WCAG A/AA checks reported no violations on the tested home and review states. This covers only the checked rules and states.
- Local synthetic intent evaluation passed 5 of 5 cases.
- XcodeGen generated the Faith project; the iOS app and native test bundle compiled successfully with Xcode 27.1 for a generic iOS simulator destination.
- All 3 native unit tests executed successfully locally, first on iOS 27.1 and then on the available iPhone 18 Pro/iOS 27.0 simulator after the speech changes. A normally signed simulator run manually verified eight loaded offers, server-priced review, disabled confirmation before acknowledgement, demo save, wallet restoration after relaunch, cancellation, and visible no-motion fallback. An initial unsigned run lost its Keychain session; rebuilding with normal simulator signing resolved that test-environment issue. This is an iOS app running on the Mac, not a verified native macOS release. Hardware sensor and participant testing remain pending.
- ElevenLabs generated MP3 audio for a short synthetic Faith message through the live adapter. A native simulator run also generated a fictional page summary through the app API, displayed the submitted text with separate Play/Stop controls, and cleared audio on Stop. Automated speech tests use mocks and do not consume credits. Physical audio intelligibility/hearing tests, live account availability, and provider retention remain account-specific.
- Anchor and Daytona authenticated read-only API checks returned HTTP 200. Arize accepted a synthetic span; the running app’s ticket search and five synthetic intent evaluations also used the configured AX exporter. No real user information was attached.
- A free `faith` SurrealDB Cloud instance was deployed after explicit approval. Studio first displayed provisioning, then navigated to its database workspace; that page rendered blank through refreshes. Application connection verification remains pending retrieval of the endpoint and account-owner credential setup. No readiness or database-authentication success is claimed.
- No Anchor browser workload or Daytona sandbox was created during these connection checks. AWS credit eligibility/balance and real ticket suppliers were not exercised.
- Current application source, filenames, assets, docs, and workflows were checked for previous product/event/team references and none remain. Faith was published to `7dracoder/Faith` with a fresh initial commit, without importing previous project history or contributors. Local recovery history was retained privately.

## Automated scope

Backend tests cover all five categories; conjunctive access filters; whole-group budgets including fees; server-owned prices; rejection of extra price fields; explicit demo acknowledgement; quote expiry; duplicate and concurrent confirmations; idempotency conflicts; session ownership; cookie-write protection; cancellation retries; persistence across restart; native bearer flow; intent extraction/fallback; and mocked external adapter contracts.

Browser tests exercise the rendered interface through search, review, acknowledgement, confirmation, wallet, download, cancellation, and empty results. They check responsive overflow, keyboard entry, dialog focus, preference persistence, and automated accessibility rules. Run against the actual FastAPI server through the provided Playwright configuration.

Synthetic intent evaluation checks all five categories and group/budget extraction. Bedrock is opt-in and must be checked using a model available in your account.

## Physical-device and participant checks still required

- VoiceOver and TalkBack: complete a booking, hear total/fees/demo status, close dialogs, revisit and cancel.
- Nonspeaking interaction: complete every task by text, touch, external keyboard, and system switch controls.
- Deaf/hard-of-hearing interaction: complete every task with audio off; verify all statuses and errors remain visible.
- Dynamic Type, large browser text, 200–400% zoom, increased contrast, reduced motion, and landscape/iPad layouts.
- Core Motion and browser orientation: explicit permission, initial calibration, recenter gating, permission denial, background stop, no automatic activation.
- Haptics: supported iPhone/Android hardware, unsupported browsers, disabled setting, and visible equivalents.
- Dictation: denied permission, missing on-device speech model, mic unavailable, stop, backgrounding, partial transcripts, and editable result.
- Test with blind, deaf, nonspeaking, and multiply disabled participants. Avoid assuming one access mode fits everyone.

## Release boundaries

The current demo has no verified suppliers, account identity/recovery, live payments, real tickets, production retention/deletion UI, or provider guarantees. Optional integrations have mocked contracts; live connectivity and billing/credits require operator setup. Native build/type checking requires an installed Xcode/iOS SDK. Swift syntax checking alone does not establish a successful iOS build.
