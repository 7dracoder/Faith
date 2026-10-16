# Faith

<img src="web/assets/faith.svg" alt="Faith" width="64" height="64">

**Your world, your way.**

[![Faith checks](https://github.com/7dracoder/Faith/actions/workflows/ci.yml/badge.svg)](https://github.com/7dracoder/Faith/actions/workflows/ci.yml)

Accessible journeys and experiences, through the senses and controls that work for you.

Faith is an accessible ticket-booking prototype for blind and low-vision people, deaf and hard-of-hearing people, nonspeaking people, and anyone who prefers a different way to interact. Search flights, trains, buses, cinema, and events through one consistent flow.

The demo includes search, access filters, transparent group prices, an expiring review, explicit confirmation, a persistent ticket wallet, text-ticket export, and cancellation. All inventory is fictional. No payment, real booking, admission, seat, or access service is issued.

## Try it locally

From this repository:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r backend/requirements.txt
.venv/bin/python -m uvicorn app.main:app --app-dir backend --host 127.0.0.1 --port 8000
```

Open [Faith](http://127.0.0.1:8000). The responsive web demo works without cloud keys. Its companion SwiftUI app uses the same API.

Try “Two train tickets to Boston tomorrow under $150”, choose **Make a plan**, review the populated fields, and choose **Find tickets**. Select an option, acknowledge the demo notice, and save it. The ticket appears under **My tickets**, where you can download a text version or cancel it.

## Ways to interact

- Text, touch, keyboard, screen readers, and system switch controls use the same standard form controls.
- Optional speech input produces editable text and never submits or confirms a booking automatically.
- Spoken summaries, visual status messages, larger text, stronger contrast, and reduced motion can be selected in Access studio.
- Optional device tilt moves focus between results. It cannot select an offer or confirm a ticket. Motion stops when the app goes into the background.
- Haptics are optional and always paired with text. Browser support varies; iOS uses system haptics.

The web speech recognizer may use the browser vendor’s cloud service; the native app requests on-device recognition and offers text when unavailable. No camera, location, disability diagnosis, real name, or card details are needed. Sensor functionality requires compatible hardware and permissions. Accessibility features need participant testing; automated checks are not an accessibility certification.

## iOS

Requires Xcode with the iOS SDK, XcodeGen, and iOS 17+. Generate the project from `project.yml`:

```sh
xcodegen generate
xcodebuild -scheme Faith -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The simulator connects to `http://127.0.0.1:8000`. For a physical phone, copy `ios/Config/Local.xcconfig.example` to the ignored `ios/Config/Local.xcconfig`, set your signing team and backend address, and serve the backend on your private network. Use HTTPS for a hosted backend. Test microphone, haptics, VoiceOver, Dynamic Type, switch controls, and tilt on real devices. No cloud credentials belong in the iOS bundle.

## Services

| Service | Implemented role | Default |
| --- | --- | --- |
| AWS Bedrock | Extract structured search intent through Converse; schema-validated and unable to book or set prices | Disabled; local parser works |
| Arize AX / Phoenix | Opt-in operation spans and synthetic intent evaluation; no request text or access preferences in spans | Disabled until runtime configuration |
| SurrealDB | Optional minimal ticket read model; primary demo transactions remain in SQLite | Disabled |
| Anchor Browser | Operator-only research on a configured public provider access page; unverified information, no checkout integration | Disabled |
| Daytona | Explicitly invoked, isolated synthetic test runner with an upload allowlist and sandbox cleanup | Disabled |

See [integration setup](docs/INTEGRATIONS.md), [architecture and API](docs/ARCHITECTURE.md), and [verification](docs/VERIFICATION.md). Cloud adapters have mocked contract tests; configuring one does not mean its live service has been verified.

To enable Bedrock, copy `backend/.env.example` to the ignored `backend/.env`, set `FAITH_AI_PROVIDER=bedrock`, `AWS_DEFAULT_REGION=us-west-2`, and an enabled `BEDROCK_MODEL_ID`. Use AWS SSO/role credentials through the SDK credential chain. Credit eligibility, balance, permissions, model access, and expiry are account-specific. Never commit credentials or include them in client applications.

## Checks

```sh
.venv/bin/python -m pytest -q backend/tests
.venv/bin/python scripts/evaluate.py
node --check web/app.js
npm ci
npx playwright install chromium
npm test
```

SQLite is suitable for this single-service demo. Production needs real provider inventory and fulfillment APIs, identity and recovery, durable order processing, verified access details, payments/refunds, retention/deletion controls, provider terms, and accessibility testing with participants. There is no universal “any ticket” supplier: the five categories currently share the demo contract; each live category needs a supplier adapter.
