"""Host the Faith API in a long-lived Daytona sandbox behind a public preview URL. Opt-in only.

Usage: python scripts/daytona_host.py [--stop | --delete]
"""
import io
import os
import shlex
import sys
import time
import tomllib
import zipfile
from pathlib import Path

NAME = "faith-host"
PORT = 8000
SESSION = "faith-api"
ENV_KEYS = ["ELEVENLABS_API_KEY", "ELEVENLABS_AGENT_ID", "ELEVENLABS_VOICE_ID", "ELEVENLABS_MODEL_ID",
            "BASETEN_API_KEY", "BASETEN_VISION_MODEL", "ANCHOR_API_KEY", "AWS_DEFAULT_REGION", "FAITH_AI_PROVIDER"]
ENV_PREFIXES = ("ARIZE_", "SURREAL_")


def main():
    from dotenv import dotenv_values, load_dotenv
    root = Path(__file__).resolve().parents[1]
    load_dotenv(root / "backend/.env")
    if not os.getenv("DAYTONA_API_KEY"):
        raise SystemExit("Set DAYTONA_API_KEY in your runtime environment first.")
    import httpx
    from daytona import CreateSandboxFromSnapshotParams, Daytona, DaytonaNotFoundError, SessionExecuteRequest
    daytona = Daytona()
    try:
        sandbox = daytona.get(NAME)
    except DaytonaNotFoundError:
        sandbox = None
    if "--stop" in sys.argv or "--delete" in sys.argv:
        if sandbox is None:
            print("No sandbox named", NAME)
        elif "--delete" in sys.argv:
            daytona.delete(sandbox, wait=True)
            print("Deleted", NAME)
        else:
            daytona.stop(sandbox)
            print("Stopped", NAME)
        return

    # Secrets travel as sandbox env vars only; .env itself is never uploaded.
    values = dotenv_values(root / "backend/.env")
    env = {k: v for k, v in values.items() if v and (k in ENV_KEYS or k.startswith(ENV_PREFIXES))}
    env.update({"FAITH_SECURE_COOKIES": "true", "FAITH_DATABASE_PATH": "/home/daytona/faith-data/faith.sqlite3"})
    if sandbox is None:
        # Public preview: the API has its own session auth and rate limits, and the app must not hold a Daytona token.
        sandbox = daytona.create(CreateSandboxFromSnapshotParams(
            name=NAME, labels={"app": "faith", "purpose": "host"}, env_vars=env, public=True, auto_stop_interval=60))
    else:
        if sandbox.state != "started":
            daytona.start(sandbox)
        sandbox.update_env(env)
        sandbox.set_public(True)
        sandbox.set_autostop_interval(60)

    archive = io.BytesIO()
    # Explicit allowlist prevents .env, local DBs, and caches leaving the machine.
    files = [root / "backend/requirements.txt"]
    files.extend(path for path in (root / "backend/app").rglob("*.py") if path.is_file())
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
        for path in files:
            zipped.write(path, path.relative_to(root))
    sandbox.fs.upload_file(archive.getvalue(), "/tmp/faith-host.zip")
    extras = tomllib.loads((root / "backend/pyproject.toml").read_text())["project"]["optional-dependencies"]["integrations"]
    # A venv keeps the image's preinstalled OpenTelemetry packages from mixing with ours.
    for command in ["rm -rf /home/daytona/faith && mkdir -p /home/daytona/faith-data",
                    "python -c \"import zipfile; zipfile.ZipFile('/tmp/faith-host.zip').extractall('/home/daytona/faith')\"",
                    "test -x venv/bin/python || python -m venv venv",
                    "venv/bin/python -m pip install -q -r faith/backend/requirements.txt "
                    + shlex.join(d for d in extras if not d.startswith("daytona"))]:
        result = sandbox.process.exec(command, cwd="/home/daytona", timeout=300)
        if result.exit_code != 0:
            raise SystemExit(f"Sandbox setup failed: {command.split()[0:3]}")

    sandbox.process.exec("pkill -f 'uvicorn app.main:app' || true", timeout=30)
    try:
        sandbox.process.delete_session(SESSION)
    except Exception:
        pass
    sandbox.process.create_session(SESSION)
    sandbox.process.execute_session_command(SESSION, SessionExecuteRequest(
        command=f"cd /home/daytona/faith && /home/daytona/venv/bin/python -m uvicorn app.main:app --app-dir backend --host 0.0.0.0 --port {PORT}",
        run_async=True))

    url = sandbox.get_preview_link(PORT).url.rstrip("/")
    print("URL:", url)
    health = None
    for _ in range(30):
        try:
            health = httpx.get(url + "/health", timeout=10)
            if health.status_code == 200:
                break
        except httpx.HTTPError:
            pass
        time.sleep(2)
    print("GET /health:", health.status_code if health is not None else "unreachable")
    capabilities = httpx.get(url + "/api/capabilities", timeout=10)
    print("GET /api/capabilities:", capabilities.status_code,
          {k: v for k, v in capabilities.json().items() if isinstance(v, bool)} if capabilities.status_code == 200 else "")


if __name__ == "__main__":
    main()
