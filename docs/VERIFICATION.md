# Faith verification

## Verified on October 16, 2026

- 35 backend tests passed, including mocked Bedrock, SurrealDB password/token authentication, Anchor, and Arize contracts.
- 6 browser tests passed in Chromium, including the full booking/cancellation flow, keyboard and mobile layout, contrast checks, network retry, and simulated tilt/background shutdown.
- Automated WCAG A/AA checks reported no violations on the tested home and review states. This covers only the checked rules and states.
- Local synthetic intent evaluation passed 5 of 5 cases.
- XcodeGen generated the Faith project; the iOS app and native test bundle compiled successfully with Xcode 27.1 for a generic iOS simulator destination.
- Native tests were not executed because no iOS simulator runtime/device is installed. Hardware sensor and participant testing remain pending.
- Anchor and Daytona authenticated read-only API checks returned HTTP 200. Arize accepted a synthetic span; the running app’s ticket search and five synthetic intent evaluations also used the configured AX exporter. No real user information was attached.
- A free `faith` SurrealDB Cloud instance was deployed after explicit approval. Studio first displayed provisioning, then navigated to its database workspace; that page rendered blank through refreshes. Application connection verification remains pending retrieval of the endpoint and account-owner credential setup. No readiness or database-authentication success is claimed.
- No Anchor browser workload or Daytona sandbox was created during these connection checks. AWS credit eligibility/balance and real ticket suppliers were not exercised.
- Current application source, filenames, assets, docs, and workflows were checked for previous product/event/team references and none remain. Repository commit history and remote hosting metadata were preserved.

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
