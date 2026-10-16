# Faith integration setup

Everything runs without cloud keys. `backend/.env.example` describes runtime settings. Keep credentials only in ignored environment files, a secret manager, AWS SSO, or workload roles. Use new credentials when earlier values were exposed. Tests never invoke paid services.

## AWS Bedrock

Set `FAITH_AI_PROVIDER=bedrock`, `AWS_DEFAULT_REGION=us-west-2`, and `BEDROCK_MODEL_ID` to a model or inference profile available to your account. The SDK resolves credentials using its standard chain. Temporary credentials require the matching session token and expire; prefer SSO for development and an IAM role in deployment. Restrict invocation permission to the selected model/profile.

`backend/app/assistant.py` sends the current search, schema, and typed/dictated text to Converse. It validates the response with Pydantic, disallows additional fields, and falls back to the deterministic parser if the provider fails. AI has no booking, browser, payment, filesystem, or pricing tool. Availability always comes from the catalog. Test the structured fields before enabling a new model. Do not assume AWS credits cover a model: verify the particular credit program and account billing first.

Run `python scripts/evaluate.py --bedrock` only when you intend to make paid calls. Without `--bedrock`, evaluations stay local. [Converse documentation](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html).

## ElevenLabs · Speak or show

Set `ELEVENLABS_API_KEY` only in the ignored `backend/.env` or a server secret manager. Configure a permitted `ELEVENLABS_VOICE_ID` (the template uses the official example voice) and `ELEVENLABS_MODEL_ID` (default `eleven_multilingual_v2`), then restart the backend. Keys never enter web or iOS bundles. The existing `httpx` dependency handles the documented [text-to-speech API](https://elevenlabs.io/docs/api-reference/text-to-speech/convert).

In either client, open Access studio → Speak or show. Type a message or choose **Use current page summary**, review it, explicitly agree to send it to ElevenLabs, and choose **Generate ElevenLabs audio**. Press Play separately; generation never autoplays or books anything. The generated message has an exact visible transcript. Changing the text clears the old audio and consent; closing/backgrounding stops playback and cancels pending client work. Cancelling the client does not guarantee an already submitted provider job or its cost can be cancelled. **Read message with device voice** works independently of the cloud service. No microphone, voice cloning, identity verification, live captioning, or sign-language translation is involved.

Only the submitted text is sent to ElevenLabs—not booking identifiers, session tokens, raw audio, sensor values, or access preferences. Text and generated audio are not stored by Faith or attached to traces; memory-only audio is discarded on clear/close/background. The provider's normal retention/history policy applies: do not claim zero retention. Its `enable_logging=false` option requires an eligible enterprise account and is not enabled here. Avoid sensitive details and use fictional messages during development.

The endpoint requires a session and normal browser write protection plus `consent=true`, rejects extra fields and messages over 600 characters, buffers at most 2 MB of MP3, times out after 30 seconds, and does not retry paid generation. A single-process guard permits 4 attempts per session/minute, 30 total attempts/hour, at most 10,000 characters/hour, and 2 concurrent calls. Failed calls count toward the guard. This resets on restart and is not sufficient for a public production deployment: add authenticated users, distributed quotas, request-body limits, provider-side key/spend restrictions, and billing alerts before exposure. The app binds to localhost by default.

## Arize AX and Phoenix

For Arize AX, install the integration dependencies and set `ARIZE_API_KEY`, `ARIZE_SPACE_ID`, and `ARIZE_PROJECT_NAME=faith`. Both the key and Space ID are required. The AX adapter uses the standard OpenTelemetry SDK and HTTPS OTLP exporter at `https://otlp.arize.com/v1/traces`, with the documented Arize authentication headers and project resource attributes. No console exporter or automatic instrumentors are enabled. This also avoids a compatibility error in `arize-otel` 0.14.1’s diagnostic-header handling with OpenTelemetry 1.45.1. AX takes precedence when both AX and Phoenix are configured. An AX API key is not interchangeable with a Phoenix Cloud key.

`python scripts/check_integrations.py` performs authenticated read-only Anchor/Daytona checks and exports one synthetic Arize connection-check span. It prints status only, never response bodies or keys. It does not create browser sessions or sandboxes. Configure SurrealDB separately from a deployed database’s endpoint and dedicated credentials.

For Phoenix, install `python -m pip install -e 'backend[integrations]'`. Set `PHOENIX_COLLECTOR_ENDPOINT` to your collector, optionally `PHOENIX_API_KEY`, then restart. Registration is explicit and automatic instrumentors are disabled. Operation spans contain only operation/provider/category names, counts, demo state, and synthetic correctness scores. No prompts, request text, session tokens, accessibility preferences, motion values, raw audio, or exception bodies are attached. Inspect exported traces in your deployment before using real user data.

`python scripts/evaluate.py` evaluates five synthetic intent cases and emits scores to the collector when configured. This is a deterministic regression corpus, not a human usability or accessibility assessment. [Phoenix tracing](https://arize.com/docs/phoenix/tracing/how-to-tracing/setup-tracing/instrument).

## SurrealDB

Set `SURREAL_URL` to the connection URL displayed for the deployed instance, `SURREAL_NAMESPACE=faith`, `SURREAL_DATABASE=booking`, and credentials for a dedicated database identity. Use an existing `SURREAL_TOKEN` or `SURREAL_USERNAME`/`SURREAL_PASSWORD` in the ignored runtime file. Creating a new database login/password must be completed by the account owner in Studio. Use a secured deployment with restrictive table permissions. The optional read model upserts a `ticket` record keyed by booking reference and includes category, status, total, creation time, and the demo marker. It excludes session tokens and access preferences. SQLite owns the transaction. Mirror failure does not create a duplicate or undo a confirmed ticket.

The read model is best-effort, with a three-second timeout. It has no durable outbox or reconciliation yet and should not be used as the authoritative production order store. [Python SDK](https://surrealdb.com/docs/languages/python).

## Anchor Browser

Set `ANCHOR_API_KEY`, `FAITH_PROVIDER_URL` to a public HTTPS access-information page you control/approve, and a long random `FAITH_INTEGRATION_TOKEN`. Only an operator using the matching `X-Faith-Integration-Token` header can call `/api/research`. The server controls the URL; the request cannot supply arbitrary URLs. No user account credentials, payment information, or browser login state are sent.

The adapter invokes `/v1/tools/perform-web-task` with an eight-step budget, a read-only research prompt, and no human intervention. Prompt restrictions are not a network or action sandbox: operator configuration and provider controls still matter. Results are explicitly unverified and never become bookable offers or guaranteed access features. Timeout/failure returns an error; checkout is not attempted. This integration is separate from the public booking flow. [Anchor API](https://docs.anchorbrowser.io/api-reference/ai-tools/perform-web-task).

## Daytona

Install the optional integration dependencies, set `DAYTONA_API_KEY` and `DAYTONA_API_URL=https://app.daytona.io/api` in the runtime environment or ignored `backend/.env`, and explicitly run `python scripts/daytona_checks.py`. The runner uploads only an allowlist of application source, synthetic tests, browser assets, and dependency manifests. It omits environment files, Git history, databases, and recordings. It creates a labeled sandbox with a five-minute idle stop and ten-minute TTL, installs dependencies, runs booking tests and local evaluations, then deletes the sandbox in `finally` and waits for deletion. No AWS/provider credentials are forwarded. This consumes Daytona resources and downloads packages only when the script is invoked. [Daytona process execution](https://www.daytona.io/docs/en/process-code-execution/).
