# Faith integrations

All keys live only in the gitignored `backend/.env` (or as Daytona sandbox environment variables). The iPhone app holds no provider keys. Every integration has an honest disabled state in `/api/capabilities` and a failure message that never includes provider details.

## ElevenLabs

`scripts/elevenlabs_agent.py` creates or updates the private agent (Sarah voice, `eleven_flash_v2`, steady and slightly slow) and its nine client tools, and writes `ELEVENLABS_AGENT_ID` to `backend/.env`. Re-run it after changing the prompt or tools. `POST /api/agent/session` returns a short-lived conversation token (30 per hour overall, 10 per session). The finder’s recorded lines come from `scripts/make_voice_clips.py`, generated once and shipped as audio files.

## Baseten

Set `BASETEN_API_KEY` and `BASETEN_VISION_MODEL=moonshotai/Kimi-K3`. `POST /api/objects/locate` sends the JPEG captured when the user asks as a data URL to Baseten’s OpenAI-compatible API, with reasoning off (`chat_template_kwargs.thinking=false`) so answers return in a few seconds. The response must be a strict 2D box; confidence below 0.65 counts as not found. Frames are never stored, logged, mirrored, or traced. Limits: 4 per session per minute, 20 per hour, 2 at a time. `POST /api/objects/scan` (object memory) uses the same model to list visible objects with a short place description, drops people and low-confidence items, stores nothing, and has its own limits: 20 per session per minute, 600 per hour, 2 at a time.

## SurrealDB

Set `SURREAL_URL`, `SURREAL_NAMESPACE`, `SURREAL_DATABASE`, `SURREAL_USERNAME`, `SURREAL_PASSWORD` for a database-level user (or `SURREAL_TOKEN`). Faith writes:

- `ticket:<reference>`: category, status, total, demo flag, time. Best-effort, 3-second timeout; SQLite stays authoritative.
- `preference:<sha256 of session>`: home city, step-free, audio description, companion seat, usual party size, updated time. Only what the user asked to remember; never objects, frames, or location. The raw session token is never stored.

Without `SURREAL_URL`, preference endpoints return 503 and nothing is saved.

## Anchor Browser

Set `ANCHOR_API_KEY`. Two read-only uses, both on fixed sites chosen by category (the request can never supply a URL):

- `POST /api/real-search`: real times and prices from Amtrak (train), Greyhound (bus), or AMC (cinema). Flights and events are declined. The task may use the site’s public search but must not log in, enter personal or payment details, add to cart, or buy. Cached 30 minutes; 3 per session per 10 minutes, 12 per hour. Results are unverified.
- `POST /api/access-info`: a summary of the provider’s public accessibility page. Cached 6 hours.

Prompt rules are not a sandbox, so neither result can ever become a bookable offer.

## Arize

Set `ARIZE_API_KEY`, `ARIZE_SPACE_ID`, `ARIZE_PROJECT_NAME`. Spans name the operation and provider only (for example `faith.real_search`, `category=train`); they never include user text, audio, images, preferences, sessions, or identity.

## Daytona

Set `DAYTONA_API_KEY` and `DAYTONA_API_URL`.

- `scripts/daytona_host.py` hosts the backend in a reusable sandbox named `faith-host` with a public preview URL and a 60-minute idle stop. Only allowlisted source files are uploaded; secrets are passed as sandbox environment variables. `--stop` and `--delete` manage it.
- `scripts/daytona_checks.py` runs the backend tests and evaluation in a throwaway sandbox with no provider credentials, then deletes it.

## AWS Bedrock (optional)

`BEDROCK_VISION_MODEL_ID` is a fallback vision model and `BEDROCK_MODEL_ID` parses typed ticket requests. Both need server-side AWS credentials. Not configured in the current deployment.
